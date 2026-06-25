# Modules

One catalog row per code unit. SPM packages first, then App + Helpers +
Extensions. Public types are listed verbatim; private types are not.

## SPM packages

### `SharedModels`
**Path:** `Packages/SharedModels/`
**Depends on:** Foundation, FileProvider
**What it owns:** Vocabulary types that every target needs. Pure value types
plus a few constants. Has no runtime behavior — never opens a socket, never
reads a file.

| Public type | File | Notes |
|---|---|---|
| `Device` (struct) | Device.swift | adb serial + model + transport + state + sdk |
| `Device.Transport` / `Device.State` | Device.swift | enums |
| `AppGroup` (enum, namespace) | AppGroup.swift | `identifier = "group.com.droidmirroring.app.shared"`, `containerURL` |
| `DroidMirroringError` (enum) | AppGroup.swift | Every typed error in the project |
| `FileProviderConfig` (enum, namespace) | FileProviderConfig.swift | Domain identifier helpers, dotfile filter |
| `DeviceRoot` (enum) | FileProviderConfig.swift | `storage` / `sdCard` / `apps` synthetic top-level entries |

### `ADBKit`
**Path:** `Packages/ADBKit/`
**Depends on:** SharedModels, Foundation, Network
**What it owns:** Native Swift implementation of the adb wire protocol —
host service, transport switching, sync sub-protocol, plus a shellout-based
wrapper for Wireless ADB pairing. Also parses `dumpsys display` for foldable
display selection.

| Public type | File | Notes |
|---|---|---|
| `ADBConnection` (actor) | ADBConnection.swift | One TCP socket to adb server; raw I/O + length-prefixed command framing |
| `ADBClient` (actor) | ADBClient.swift | High-level API: `serverVersion`, `listDevices`, `shell`, `forward`, `reverse`, `openSyncTransport` |
| `ADBClient.Config` | ADBClient.swift | server host + port |
| `SyncCommand` (enum) | SyncProtocol.swift | STAT / LIST / SEND / RECV / DATA / DONE / OKAY / FAIL / DENT / QUIT |
| `SyncEntry` (struct) | SyncProtocol.swift | mode + size + mtime + name |
| `SyncSession` (actor) | SyncProtocol.swift | `list` / `stat` / `recv` / `send` / `quit` |
| `ADBWirelessClient` (actor) | ADBWirelessClient.swift | `pair` / `connect` / `disconnect` over bundled adb |
| `ADBWirelessClient.WirelessError` | ADBWirelessClient.swift | typed pairing failures |
| `DisplayInfo` (struct) | DisplayInfo.swift | one parsed LogicalDisplay |
| `DisplayInfo.State` (enum) | DisplayInfo.swift | ON / DOZE / DOZE_SUSPEND / ON_SUSPEND / OFF / UNKNOWN + rank |
| `ADBClient.physicalDisplays(serial:)` | DisplayInfo.swift | uses `dumpsys window` (≈5KB; was `dumpsys display` 400KB which tripped POSIX 96 ENOMSG) |
| `ADBClient.pickActiveDisplay(serial:)` | DisplayInfo.swift | rank-then-area picker |
| `SyncCache` (actor) | SyncCache.swift | SQLite-backed listing cache (per-device); `snapshot` / `replace` / `invalidate` / `clearAll` |
| `ADBInstaller` (actor) | ADBInstall.swift | `.apk` (`adb install -r`) and `.xapk` (unzip → `adb install-multiple`); parses `INSTALL_FAILED_*` into typed `InstallError` |

Also exports an executable target `sync-smoke` (`Sources/SyncSmoke/main.swift`).

### `ScrcpyClient`
**Path:** `Packages/ScrcpyClient/`
**Depends on:** ADBKit, SharedModels, Foundation, Network
**What it owns:** scrcpy-server launch sequence, video / audio / control
socket plumbing, framing, options builder, control-message serialization. Does
NOT decode video — that's MirrorEngine.

| Public type | File | Notes |
|---|---|---|
| `ScrcpyServerVersion.current` | ScrcpyServerLauncher.swift | pinned to "3.1" |
| `ScrcpyOptions` (struct) | ScrcpyServerLauncher.swift | bitrate, fps, codec, displayId, newDisplay |
| `ScrcpyServerLauncher` (actor) | ScrcpyServerLauncher.swift | full launch flow, returns `Sockets` |
| `ScrcpyServerLauncher.Sockets` | ScrcpyServerLauncher.swift | video / audio? / control? + device name + W/H |
| `ScrcpyServerLauncher.Resources` | ScrcpyServerLauncher.swift | path to .jar + path to bundled adb |
| `SocketAcceptor` (actor) | SocketAcceptor.swift | NWListener on loopback that yields next() connection |
| `VideoFrame` (struct) | VideoStream.swift | pts + flags + Annex-B payload |
| `VideoStream` (actor) | VideoStream.swift | reads 12-byte header + payload off NWConnection |
| `AudioCodec` (enum) | AudioStream.swift | opus / aac / flac / raw — parses FourCC |
| `AudioFrame` (struct) | AudioStream.swift | mirror of VideoFrame |
| `AudioStream` (actor) | AudioStream.swift | readCodecHeader → nextFrame loop |
| `ControlMessageType` (enum) | ControlMessage.swift | wire type byte |
| `KeyEventAction` / `TouchAction` / `MotionButton` | ControlMessage.swift | Android-side codes |
| `ControlMessage` (struct) | ControlMessage.swift | builders: `.touch` / `.scroll` / `.keycode` / `.text` / `.backOrScreenOn` / `.getClipboard` / `.setClipboard` / `.rotateDevice` / `.setScreenPowerMode` |
| `ControlSocketWriter` (actor) | ControlSocketWriter.swift | serializes ControlMessages onto control NWConnection |
| `DeviceMessageType` (enum) | DeviceMessage.swift | wire type byte (clipboard / ackClipboard / uhidOutput) |
| `DeviceMessage` (enum) | DeviceMessage.swift | `.clipboard(text:)` / `.ackClipboard(sequence:)` / `.uhidOutput(id:data:)` / `.unknown(type:)` |
| `DeviceMessageReader` (actor) | DeviceMessage.swift | reads device → client frames; exposes `AsyncStream<DeviceMessage>` |

Also exports an executable `scrcpy-smoke` (`Sources/ScrcpySmoke/main.swift`).

### `MirrorEngine`
**Path:** `Packages/MirrorEngine/`
**Depends on:** ScrcpyClient, SharedModels, VideoToolbox, CoreMedia, CoreVideo, Metal, MetalKit
**What it owns:** Hardware H.264 / H.265 decode via VideoToolbox, zero-copy
Metal render path (CVPixelBuffer → IOSurface texture → CAMetalLayer), and
`MirrorSession` glue that wires VideoStream → VTDecoder → renderer callback.

| Public type | File | Notes |
|---|---|---|
| `NALU` (enum, namespace) | NALU.swift | `split(annexB:)`, `annexBToAVCC`, `hevcType(of:)`, `avcType(of:)` |
| `NALU.HEVCType` / `NALU.AVCType` | NALU.swift | parameter-set NAL constants |
| `VTDecoder` (final class, @unchecked Sendable) | VTDecoder.swift | feed config → SPS/VPS/PPS, feed picture → decoded frame |
| `VTDecoder.Codec` | VTDecoder.swift | `.h264` / `.h265` |
| `MetalFrameRenderer` (final class) | MetalFrameRenderer.swift | NV12 → BGRA shader, BT.709 |
| `MirrorSession` (final class) | MirrorSession.swift | owns receive loop + audio loop + control writer + `DeviceMessageReader` |
| `MirrorSession.State` (enum) | MirrorSession.swift | idle / starting / streaming / stopping / stopped / failed |
| `AudioRenderer` (final class) | AudioRenderer.swift | Opus/AAC/FLAC/raw → AVAudioEngine. Non-interleaved Float32 stereo @ 48kHz; uses `AudioBufferList.allocate(maximumBuffers: 2)` (heap, never stack) |
| `ScreenRecorder` (final class) | ScreenRecorder.swift | `AVAssetWriter` mp4 sink fed from `MetalFrameRenderer.onFrame`; H.264 @ 8 Mbps |
| `Screenshotter` (enum) | ScreenRecorder.swift | one-shot CVPixelBuffer → PNG via CIContext + CGImageDestination |

### `DeviceDiscovery`
**Path:** `Packages/DeviceDiscovery/`
**Depends on:** ADBKit, SharedModels, Combine, Network
**What it owns:** Two MainActor `ObservableObject`s the UI binds to.

| Public type | File | Notes |
|---|---|---|
| `DeviceMonitor` | DeviceMonitor.swift | runs `host:track-devices-l`, publishes `[Device]` |
| `WirelessEndpoint` (struct) | WirelessBrowser.swift | one resolved Bonjour endpoint |
| `WirelessEndpoint.Kind` | WirelessBrowser.swift | adb / tlsConnect / tlsPairing |
| `WirelessBrowser` | WirelessBrowser.swift | three NWBrowsers; `pairingCandidates` / `connectableDevices` |

### `FusionEngine`
**Path:** `Packages/FusionEngine/`
**Depends on:** ADBKit, ScrcpyClient, MirrorEngine, SharedModels
**What it owns:** Desktop mode (M4 partial) — opens an Android desktop on a
scrcpy `--new-display` virtual display, with AOSP-freeform toggle/restore and
a package catalog. Per-app windowed "Fusion" mode proper is still planned.

| Public type | File | Notes |
|---|---|---|
| `DesktopMode` (enum) | DesktopModeDetector.swift | samsungDeX / androidFreeform / unsupported — used by detection only |
| `DesktopModeDetector` (actor) | DesktopModeDetector.swift | `detect(_: Device)` — priority-based |
| `FusionActivator` (actor) | DesktopModeDetector.swift | DeX path stubs (throw `.unimplemented`) |
| `FreeformActivator` (actor) | FreeformActivator.swift | toggles `enable_freeform_support` / `force_resizable_activities` / `enable_taskbar` with snapshot+restore |
| `ActivationToken` (struct) | FreeformActivator.swift | restore snapshot returned by `activate` |
| `AppCatalog` (actor) | AppCatalog.swift | `pm list packages -3` → fast list (was 100× slower with per-app `dumpsys`) |
| `InstalledApp` (struct) | AppCatalog.swift | package + best-effort label + iconPNG slot |
| `FusionLauncher` (actor) | FusionLauncher.swift | `openDesktop` (no app) and `launch(packageName:)` (`am start -W --display N --activity-clear-task --activity-new-task`); virtual-display id discovered via `dumpsys window` diff |
| `FusionSession` (struct) | FusionLauncher.swift | packageName + virtualDisplayId + MirrorSession |
| `FusionWindowSpec` (struct) | FusionWindowPlanner.swift | package + displayId + frame + options |
| `FusionWindowPlanner` (actor) | FusionWindowPlanner.swift | stub — reserved for per-app multi-window planner |

---

## App + non-package targets

### `DroidMirroring` (main App)
**Path:** `App/`
**Bundle id:** `com.droidmirroring.app.DroidMirroring`

| Group | Files | Role |
|---|---|---|
| Entry | `droidMirroringApp.swift` | `@main`, scene graph, `DeviceMonitor` lifetime |
| Scenes | `Scenes/MainView.swift` | NavigationSplitView + DeviceDashboard |
|  | `Scenes/MirrorWindow.swift` | NSWindowController hosting CAMetalLayer |
|  | `Scenes/MirrorEventView.swift` | NSView that translates NSEvents → ControlMessage |
|  | `Scenes/MirrorKeyMap.swift` | mac keycode → Android keycode table |
|  | `Scenes/FilesWindow.swift` | NSWindowController for the files browser |
|  | `Scenes/SettingsView.swift` | Settings scene |
|  | `Scenes/MenuBarContent.swift` | MenuBarExtra contents |
|  | `Scenes/PairingSheet.swift` | Wireless pair-by-code sheet |
| ViewModels | `ViewModels/SessionCoordinator.swift` | mirror/files window lifecycle + fold polling |
|  | `ViewModels/FilesViewModel.swift` | per-device files-window state machine |
|  | `ViewModels/FinderDomainCoordinator.swift` | adds/removes NSFileProviderDomain per online device |
| Resources | `Resources/Assets.xcassets`, `Resources/scrcpy-server*.jar`, `Resources/adb`, `Resources/Licenses/` | bundled binaries + LICENSE files |
| Entitlements | `DroidMirroring.entitlements` | sandbox + network + USB + app-group |

### Helpers (`LSUIElement=true` accessory apps)

| Target | Path | Bundle id | State |
|---|---|---|---|
| `ScreenMirroringHelper` | `Helpers/ScreenMirroring/main.swift` | `com.droidmirroring.app.DroidMirroring.ScreenMirroring` | M2.x stub — empty NSApplication.run loop |
| `FusionModeHelper` | `Helpers/FusionMode/main.swift` | `com.droidmirroring.app.DroidMirroring.FusionMode` | M4 stub |
| `ContinueOnHelper` | `Helpers/ContinueOn/main.swift` | `com.droidmirroring.app.DroidMirroring.ContinueOn` | M5 stub |

All three are embedded in `DroidMirroring.app/Contents/Helpers/`.

### Extensions

| Target | Path | Bundle id | Extension point |
|---|---|---|---|
| `FileProviderExt` | `Extensions/FileProviderExt/` | `com.droidmirroring.app.DroidMirroring.FileProvider` | `com.apple.fileprovider-nonui` |
| `ThumbnailExt` | `Extensions/ThumbnailExt/` | `com.droidmirroring.app.DroidMirroring.Thumbnail` | `com.apple.quicklook.thumbnail` |

`FileProviderExt` source:
- `FileProviderExtension.swift` — `NSFileProviderReplicatedExtension`
  implementation: `item`, `enumerator`, `fetchContents`, `createItem`,
  `modifyItem`, `deleteItem`. Every method ultimately delegates to
  `ADBClient.openSyncTransport` + `SyncSession`.
- `DirectoryEnumerator.swift` — implements `NSFileProviderEnumerator` for one
  open folder.
- `DroidMirroringItem.swift` — `NSFileProviderItem` adapter around a `SyncEntry`.

Built with `SWIFT_STRICT_CONCURRENCY=minimal` to dodge sandbox + actor friction
in the FileProvider host. **Disabled by default in DEBUG** — registration of
`NSFileProviderDomain` requires a real Apple Developer Team ID (see
TROUBLESHOOTING.md).

`ThumbnailExt` is a placeholder for M3.x APK / XAPK thumbnailing.

---

## Tests

- `Packages/ADBKit/Tests/ADBKitTests/`: `ADBConnectionTests`,
  `ADBClientTests`, `SyncProtocolTests`, `DisplayInfoTests`
- `Packages/ScrcpyClient/Tests/ScrcpyClientTests/`: `ScrcpyOptionsTests`,
  `AudioCodecTests`, `ControlMessageTests`
- `Packages/MirrorEngine/Tests/MirrorEngineTests/`: `NALUTests`

Smoke executables (require a real online device, not run in CI):

- `swift run --package-path Packages/ADBKit sync-smoke`
- `swift run --package-path Packages/ScrcpyClient scrcpy-smoke <jar> <adb> [serial]`
