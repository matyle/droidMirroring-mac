# Architecture

DroidMirroring is a sandboxed macOS app that turns an Android device into a first-class
workstation peripheral: screen mirroring, Finder file access, and (planned)
multi-window Fusion mode. It is built on top of upstream
[scrcpy](https://github.com/Genymobile/scrcpy) but talks to it directly over its
wire protocol — no `scrcpy` CLI is ever spawned.

## Block diagram

```
+------------------------------------------------------+
|                  DroidMirroring.app (main)                  |
|                                                      |
|   SwiftUI UI ─► SessionCoordinator ─► MirrorWindow   |
|        │              │                              |
|        ▼              ▼                              |
|   DeviceMonitor   ScrcpyServerLauncher               |
|        │              │                              |
|        └──── ADBClient (actor) ────┐                 |
+--------------------------------------|---------------+
                                       │
                          TCP 127.0.0.1:5037
                                       │
                         +-------------┴-------------+
                         |       adb server          |
                         |   (Google platform-tools) |
                         +-------------┬-------------+
                                       │ USB / Wi-Fi
                         +-------------┴-------------+
                         |     Android device        |
                         |  (scrcpy-server.jar in    |
                         |   app_process; ADB sync)  |
                         +---------------------------+
```

The macOS app never speaks USB or TLS itself — it speaks the **adb host
protocol** over loopback TCP to the bundled `adb` server, which in turn
multiplexes transports.

## Targets and processes

| Target | Type | Process model | Owns |
|---|---|---|---|
| `DroidMirroring` | App (SwiftUI) | Foreground GUI | Main window, mirror windows, files browser, device discovery |
| `ScreenMirroringHelper` | LSUIElement App | Background, no Dock | (M2.x stub) hosts mirror NSWindows so closing main app keeps mirror alive |
| `FusionModeHelper` | LSUIElement App | Background, no Dock | (M4 stub) per-app NSWindow host for freeform/DeX |
| `ContinueOnHelper` | LSUIElement App | Background, no Dock | (M5 stub) clipboard / URL handoff |
| `FileProviderExt` | NSExtension (`fileprovider-nonui`) | Sandboxed per-domain | Finder sidebar entry per device, sync-protocol I/O |
| `ThumbnailExt` | NSExtension (`quicklook.thumbnail`) | Sandboxed per-call | APK / XAPK quick-look thumbnails |

The three helpers are LSUIElement=true binaries; they run as accessory apps
under the main App's bundle (`Contents/Helpers/`). The two extensions live
under `Contents/PlugIns/`. All targets share the `group.com.droidmirroring.app.shared`
App Group container.

## SPM packages

Six SPM packages live under `Packages/`. Each is a self-contained library with
its own `Package.swift` and tests.

| Package | What it owns |
|---|---|
| `SharedModels` | `Device`, `AppGroup`, `DroidMirroringError`, `FileProviderConfig`, `DeviceRoot` — vocabulary shared across every target |
| `ADBKit` | adb wire protocol (host service, sync sub-protocol), `ADBClient` / `ADBConnection` / `SyncSession`, `ADBWirelessClient` for pairing, `DisplayInfo` parser for dumpsys |
| `ScrcpyClient` | scrcpy-server launcher, video / audio / control sockets, framing, options builder |
| `MirrorEngine` | VideoToolbox H.264/H.265 decoder, Metal NV12 renderer, NALU helpers, `MirrorSession` glue |
| `DeviceDiscovery` | adb `host:track-devices` watcher + Bonjour browser for `_adb-tls-*._tcp` |
| `FusionEngine` | (M4) DeX / freeform detector + per-window planner stubs |

ADBKit also ships an executable `sync-smoke`; ScrcpyClient ships
`scrcpy-smoke`. Both are run-on-real-device integration probes.

## Data flow

### Mirror

```
User clicks "Mirror"
   → SessionCoordinator.startMirror(device)
   → ADBClient.pickActiveDisplay(serial)          [dumpsys display]
   → MirrorWindowController.showWindow            [opens NSWindow + CAMetalLayer]
   → ScrcpyServerLauncher.launch(options)
       ├─ adb push scrcpy-server.jar /data/local/tmp/
       ├─ adb reverse localabstract:scrcpy_<scid> tcp:<localPort>
       ├─ shell: CLASSPATH=... app_process / com.genymobile.scrcpy.Server ...
       └─ accept video / audio / control sockets on loopback
   → MirrorSession runs receive loop
       VideoStream.nextFrame  →  VTDecoder.feed  →  MetalFrameRenderer.render
   → SessionCoordinator polls dumpsys window every 1.0s;
     on (id, width, height, rotation) change the session is torn down and
     relaunched. ⌘R is the manual escape hatch.
```

User input flows the opposite way: `MirrorEventView` translates `NSEvent`s into
`ControlMessage`s, which the `ControlSocketWriter` actor serializes onto the
control socket. The same socket is also read from by `DeviceMessageReader`
(NWConnection is full-duplex) — server-pushed `DeviceMessage.clipboard`
frames feed `ClipboardBridge`, which writes them to `NSPasteboard`.

Mac → device clipboard sync runs the inverse direction: a 0.5 s
`NSPasteboard.changeCount` poll, hashed against the last value we received
from the device, then a `ControlMessage.setClipboard` write. Hash dedup
prevents the two sides from ping-ponging.

Audio runs in parallel on a separate task: `AudioStream.nextFrame` →
`AudioRenderer.feed` decodes Opus/AAC/FLAC via `AudioConverter` and
schedules buffers on an `AVAudioPlayerNode`.

Recording and screenshots both tap `MetalFrameRenderer.onFrame` (called once
per decoded CVPixelBuffer). `ScreenRecorder` appends to an `AVAssetWriter`
mp4 sink; `Screenshotter` resolves the latest `lastPixelBuffer` to a PNG.

### Files

```
User clicks "Files"
   → SessionCoordinator.openFiles(device)
   → FilesWindowController shows FilesView(FilesViewModel)
   → FilesViewModel.load()
        ADBClient.openSyncTransport(serial)
        SyncSession.list("/sdcard")  →  [SyncEntry]
   → User double-clicks a directory   →  SyncSession.list(newPath)
   → User clicks Download             →  SyncSession.recv(path, into: localURL)
   → User drags a file in             →  SyncSession.send(localURL, to: path)
```

`FinderDomainCoordinator` is the parallel path: when signing is configured it
registers one `NSFileProviderDomain` per online device, and the
`FileProviderExt` runs all the same `SyncSession` calls inside its sandbox to
back the Finder sidebar entry.

### Desktop Mode

```
User clicks "Desktop"   (requires Android 14+)
   → SessionCoordinator.openDesktop(device)
   → FreeformActivator.activate(serial)
       ├─ snapshot existing values via `settings get global ...`
       └─ `settings put global enable_freeform_support 1`, etc.
   → FusionLauncher.openDesktop(size: 2560×1440, dpi: 160)
       ├─ snapshot existing virtual display ids via dumpsys window
       ├─ ScrcpyServerLauncher.launch(newDisplay: "2560x1440/160")
       └─ diff dumpsys window to discover the new id
   → FusionAppWindowController hosts the mirror + a SwiftUI status footer
     (device · resolution · display id) so the window edge stays visible
     against light Android wallpapers.
```

On window close the cleanup is the inverse — kill scrcpy (releases the
virtual display via `cleanup=true`), and once the *last* fusion window for
a device closes, `FreeformActivator.deactivate(token)` restores the
snapshotted settings.

### Fusion (planned — per-app windows)

The Desktop path above lets the OEM launcher (Samsung One UI / Pixel
taskbar / AOSP) own the virtual display. True Fusion is one Mac window
per Android app with no launcher in between — `FusionLauncher.launch(packageName:)`
already attempts `am start -W --display <id> --activity-clear-task --activity-new-task`
but the OEM launcher races to claim the display first. Resolving this
likely requires a scrcpy-server fork that sets
`VIRTUAL_DISPLAY_FLAG_OWN_CONTENT_ONLY`.

## Concurrency model

Swift 6, `SWIFT_STRICT_CONCURRENCY=complete`.

| Actor | Guards |
|---|---|
| `ADBConnection` | One TCP socket; serialized reads/writes |
| `ADBClient` | Connection factory + parse helpers (stateless on the wire — every call opens a fresh `ADBConnection`) |
| `SyncSession` | The sync-mode connection bound to a device; serialized frame I/O |
| `ADBWirelessClient` | Bundled-adb shellouts for pair/connect/disconnect |
| `ScrcpyServerLauncher` | Per-session state: scid, shell `ADBConnection`, `SocketAcceptor` |
| `SocketAcceptor` | NWListener + connection queue + waiters |
| `VideoStream` / `AudioStream` | Read cursor on one NWConnection |
| `ControlSocketWriter` | Write cursor on the control NWConnection |
| `DesktopModeDetector` / `FusionActivator` / `FusionWindowPlanner` | (M4) |

The UI layer is `@MainActor`:
- `DeviceMonitor` (Combine `@Published` device list)
- `WirelessBrowser` (Bonjour endpoints)
- `SessionCoordinator` (window lifecycle)
- `FilesViewModel`, `FinderDomainCoordinator`

`MirrorSession` and `VTDecoder` are `@unchecked Sendable` final classes —
their state is touched only from one detached receive task and the
VideoToolbox callback queue, but Swift can't prove it.

## App Group: `group.com.droidmirroring.app.shared`

Declared in every target's entitlements. Used for:
- `FileProviderConfig` constants (`domainPrefix`, filtered filenames) live in
  `SharedModels` so the App and the extension agree on identifiers.
- Future: `AppGroup.containerURL` will host the device-list + token cache so
  helpers and extensions don't have to re-discover.

Today the extension is signed-disabled (see TROUBLESHOOTING.md) so the App
Group only matters at runtime once a real Developer Team ID is wired in.

## File map

- Main App: `App/droidMirroringApp.swift`, `App/Scenes/*`, `App/ViewModels/*`
- Helpers: `Helpers/{ScreenMirroring,FusionMode,ContinueOn}/main.swift`
- Extensions: `Extensions/{FileProviderExt,ThumbnailExt}/`
- Packages: `Packages/<Name>/Sources/<Name>/*.swift`
- Build glue: `project.yml` (XcodeGen), `scripts/bootstrap.sh`
- Bundled binaries: `App/Resources/scrcpy-server*.jar`, `App/Resources/adb`
