# Roadmap

| Milestone | Status | Goal |
|---|---|---|
| **M1 Scaffold** | ✅ done | Xcode workspace + SPM packages + fetch scripts + skeleton sources |
| **M2 Mirror MVP** | ✅ done | scrcpy-server protocol + VideoToolbox decode + Metal render + input + audio + foldable handling + toolbar |
| **M3 Files** | ✅ done (in-app) / 🅿 parked (Finder) | Native ADB sync protocol + Files browser UI + folder ops + APK install. FileProviderExtension code complete but disabled awaiting signing. |
| **M4 Desktop Mode** | ✅ done | scrcpy virtual display + AOSP freeform toggle + landscape window with status footer. Per-app *Fusion* still planned. |
| **M5 Polish + distribution** | ⏳ partial | Open-source repo (LICENSE / docs / templates) shipped. DMG / notarization / Sparkle / MAS variant still ahead. |

## Detailed status

### M1 — Scaffold (done)

- [x] `project.yml` + `xcodegen generate` workflow
- [x] Six SPM packages with public APIs sketched
- [x] `scripts/bootstrap.sh`, `scripts/fetch-scrcpy-server.sh`, `scripts/fetch-adb.sh`
- [x] App entry, MainView, MenuBarExtra, Settings, Helpers (stub), Extensions (stub)
- [x] App Group + entitlements wired up
- [x] LICENSE bundling for scrcpy / adb in `App/Resources/Licenses/`
- [x] `scripts/clean.sh` (3 modes)
- [x] `scripts/generate-icon.swift` + AppIcon v1

### M2 — Mirror MVP (done)

Wire protocol:
- [x] adb host service framing (`ADBConnection`)
- [x] `host:version`, `host:devices-l`, `host:transport`, `host:track-devices-l`
- [x] `shell:`, `reverse:forward`, `reverse:killforward`
- [x] scrcpy launch sequence (`ScrcpyServerLauncher`)
- [x] Video framing parse (`VideoStream`)
- [x] Audio framing parse (`AudioStream`)
- [x] Control message serialization (`ControlMessage`, `ControlSocketWriter`)
- [x] Device message reader (`DeviceMessage`, `DeviceMessageReader`) — clipboard / ackClipboard / uhidOutput

Decode + render:
- [x] `NALU` Annex-B helpers + HEVC / AVC NAL type extraction
- [x] `VTDecoder` for H.264 and H.265 with parameter-set ingest
- [x] `MetalFrameRenderer` zero-copy NV12 → BGRA via IOSurface
- [x] `MirrorSession` receive loop + state machine + audio loop
- [x] `AudioRenderer` Opus/AAC/FLAC/raw → AVAudioEngine (non-interleaved Float32 stereo)
- [x] `ScreenRecorder` + `Screenshotter`

UI / Toolbar v2:
- [x] Device dashboard with Mirror / Desktop / Fusion / Files action buttons
- [x] `MirrorWindow` NSWindowController + `MirrorEventView` NSEvent bridge
- [x] `MirrorKeyMap` macOS → Android keycode mapping
- [x] Pairing sheet for Wireless ADB (QR / 6-digit / manual IP)
- [x] Toolbar: Back / Home / Recents / Screenshot / Record / Rotate / Screen Off / Wake / Pin / Clipboard Sync
- [x] Bidirectional clipboard sync (`ClipboardBridge`) with hash dedup
- [x] Settings panel: Video / Privacy (auto-screen-off) / Clipboard

Foldable handling:
- [x] `dumpsys window` parser (`DisplayInfo.parseWindowDump`)
- [x] State-rank picker (`pickActiveDisplay`)
- [x] 1s polling + session relaunch on (id, width, height, rotation) change
- [x] `Cmd+R` manual refresh
- [x] IME reset on stop (Samsung Android 16 workaround)

CLI smoke:
- [x] `sync-smoke` — sync sub-protocol against a real device
- [x] `scrcpy-smoke` — full launch + first 5 frames

### M3 — Files (in-app ✅ / Finder 🅿)

Sync protocol:
- [x] `SyncSession.list` / `stat` / `recv` / `send` / `quit`
- [x] Little-endian framing
- [x] Atomic temp-file write on RECV
- [x] 64 KiB chunking on SEND, mtime in DONE
- [x] FAIL error surface

In-app Files UI:
- [x] `FilesViewModel` with breadcrumb, list, shortcuts (Pictures / DCIM / Downloads / …)
- [x] `FilesWindow` NSWindowController + sortable Table
- [x] Download to `~/Downloads/DroidMirroring/<serial>/`
- [x] Upload via drag-and-drop (files + folders)
- [x] Folder-level batch download with per-file + per-batch progress and cancel
- [x] Delete via `adb shell rm -rf`
- [x] **New Folder** + **Rename** via toolbar / right-click
- [x] **APK / XAPK install** on drop (`ADBInstaller`)
- [x] **SQLite metadata cache** (`SyncCache`) — instant backtrack, invalidated on mutations

FileProvider extension (parked on signing):
- [x] `FileProviderExtension` (`item`, `enumerator`, `fetchContents`, `createItem`, `modifyItem`, `deleteItem`)
- [x] `DirectoryEnumerator` with synthetic DeviceRoot entries
- [x] `DroidMirroringItem` adapter (capabilities, version, contentType)
- [x] `FinderDomainCoordinator` add/remove on device transitions
- [x] `.DS_Store` / `._*` filtering on createItem
- [ ] **Parked: signing.** Domain registration -2001/-2014 under ad-hoc.
- [ ] ThumbnailExt for APK / XAPK quick-look
- [ ] Change tracking (`enumerateChanges` currently no-ops)
- [ ] Synthetic "Apps" root (currently filtered out)

### M4 — Desktop / Fusion (Desktop ✅ / Fusion ⏳)

Desktop Mode (shipped):
- [x] `FreeformActivator` — toggle freeform settings with snapshot/restore
- [x] `FusionLauncher.openDesktop` — 2560×1440 @ 160 dpi virtual display
- [x] `AppCatalog.listInstalled` — fast `pm list packages -3` path
- [x] `FusionAppWindowController` — NSWindow with status footer (device · resolution · display id)
- [x] Virtual-display-id discovery via `dumpsys window` set diff
- [x] AppDelegate lifecycle: graceful shutdown releases displays
- [x] Boot-time `pkill scrcpy.Server` sweep

Fusion (per-app windows — research phase):
- [ ] Suppress OEM desktop launcher on the virtual display so the picked app
  doesn't get fronted by Samsung One UI desktop / Pixel taskbar
- [ ] `DesktopModeDetector.detect` real implementation (Samsung DeX path)
- [ ] `FusionActivator.activateDeX` — Samsung-private intent route
- [ ] `FusionWindowPlanner` per-app layout
- [ ] Global menu bar list of active fusion windows

### M5 — Polish + distribution (partial)

Open source housekeeping (shipped):
- [x] Apache-2.0 LICENSE
- [x] CONTRIBUTING.md / CODE_OF_CONDUCT.md / SECURITY.md
- [x] `.github/ISSUE_TEMPLATE/` + `PULL_REQUEST_TEMPLATE.md`
- [x] README rewrite with feature matrix + badges
- [x] docs/ refresh for everything shipped this cycle

Distribution (planned):
- [ ] Localization: zh-Hans + en first
- [ ] About panel with bundled LICENSE files
- [ ] `scripts/build-dmg.sh` with `create-dmg` + `notarytool`
- [ ] Sparkle 2.x auto-update with EdDSA signatures
- [ ] `project-mas.yml` for the MAS variant (USB layer rewritten in-process)
- [ ] App Sandbox audit pass
- [ ] Crash reporting hookup

## Parked items

- **Per-app Fusion windows** — the hard part is preventing the OEM desktop
  launcher from claiming the virtual display before our `am start --display`
  intent lands. Probably needs `VIRTUAL_DISPLAY_FLAG_OWN_CONTENT_ONLY` on
  the scrcpy side, which means a scrcpy-server fork.
- **FileProvider signing** — needs paid Apple Developer Team ID. Code is
  done; uncomment one line in `App/droidMirroringApp.swift` once signing is set up.
- **Folder rotation polish** — fold/unfold session relaunch flashes a brief
  black frame. Cross-fade by keeping the last decoded buffer rendered until
  the first new keyframe arrives.
- **`ADBClient.push` / `pull`** — currently throw `DroidMirroringError.unimplemented`.
  All real upload/download goes through `SyncSession` directly.
- **Image thumbnails in Files** — would use `QLThumbnailGenerator` against
  the SQLite cache. Estimated half a day.
- **Drag-out from Files to macOS Desktop** — currently only drag-in works.
- **Multi-device parallel UI** — architecture already supports it (one
  controller per serial). UI just needs a sidebar refresh.
