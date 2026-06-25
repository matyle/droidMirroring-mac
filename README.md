# DroidMirroring

![License](https://img.shields.io/badge/license-Apache--2.0-blue.svg)
![Platform](https://img.shields.io/badge/macOS-15%2B-success.svg)

A native macOS workstation for your Android device. Mirror the phone in a
real Cocoa window, browse its files like Finder, drop APKs to install,
project an Android desktop onto a virtual display, and sync the clipboard
both ways — all in pure Swift 6 over the scrcpy + ADB wire protocols,
with no `scrcpy` CLI in the process tree.

## Screenshots

[Screenshot — TODO]

## Features

| Area | What |
|---|---|
| Mirror | scrcpy 3.1 H.264/H.265 → VideoToolbox → Metal NV12, foldable + rotation auto-relaunch, audio playback, Cmd+R force re-pick, IME reset on close, Privacy auto-screen-off, Pin window |
| Toolbar | Back / Home / Recents · Screenshot (PNG) · Record (mp4) · Rotate · Screen Off/On · Wake · Pin · Clipboard Sync |
| Clipboard | Two-way sync between NSPasteboard and the device clipboard (loop-safe, dedup by hash) |
| Files | Native ADB sync wire protocol, drag-drop upload + APK / XAPK install, batched download with per-file + per-batch progress, mkdir, rename, delete, SQLite metadata cache for instant backtrack |
| Desktop Mode | scrcpy `--new-display` 2560×1440 @ 160 dpi virtual display, AOSP freeform auto-enable + restore, one borderless Mac window per device |
| Connection | USB and Wireless ADB (Bonjour browse + pair-by-code), stale-server sweep on launch, graceful shutdown via NSApplicationDelegate |
| Open source | Apache-2.0, no telemetry, no bundled analytics |

## Quick start

```sh
brew install xcodegen
./scripts/bootstrap.sh          # fetch scrcpy-server.jar + adb, resolve SPM
xcodegen generate
open DroidMirroring.xcodeproj
```

Hit ⌘R in Xcode. Full instructions: [docs/BUILDING.md](docs/BUILDING.md).

## Layout

```
App/         主 App (SwiftUI + AppKit) — Scenes / ViewModels / Resources
Helpers/     ScreenMirroring / FusionMode / ContinueOn — LSUIElement helpers
Extensions/  FileProviderExt (Finder) + ThumbnailExt (Quick Look for APK)
Packages/    SPM 本地包: ADBKit / ScrcpyClient / MirrorEngine /
             FusionEngine / DeviceDiscovery / SharedModels
scripts/     bootstrap.sh / fetch-{adb,scrcpy-server}.sh /
             clean.sh / generate-icon.swift
docs/        ARCHITECTURE / PROTOCOL / MODULES / BUILDING /
             TROUBLESHOOTING / ROADMAP / CREDITS / XCODE-SETUP
```

## Documentation

| Doc | What |
|---|---|
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | Block diagram, modules, process model, data flow, concurrency |
| [docs/PROTOCOL.md](docs/PROTOCOL.md) | adb host service, adb sync, scrcpy video / audio / control + DeviceMessage, Wireless ADB |
| [docs/MODULES.md](docs/MODULES.md) | Per-package public-API catalog |
| [docs/BUILDING.md](docs/BUILDING.md) | Prereqs, bootstrap, xcodebuild, smoke tests, clean modes, icon generation |
| [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) | Real bugs hit during M2/M3 and their fixes |
| [docs/ROADMAP.md](docs/ROADMAP.md) | M1–M5 with checkmarks and parked items |
| [docs/XCODE-SETUP.md](docs/XCODE-SETUP.md) | XcodeGen flow + signing + App Group |
| [docs/CREDITS.md](docs/CREDITS.md) | Upstream open-source acknowledgements |

## Status

Alpha. Mirror (M2) and most of Files (M3) shipped. Desktop Mode is the first
slice of Fusion (M4). Fusion proper (one app per window) and notarized
distribution still ahead. See [docs/ROADMAP.md](docs/ROADMAP.md) for the
checkbox view.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Bug reports and PRs welcome via
<https://github.com/matyle/MacDros>.

## License

Apache-2.0. See [LICENSE](LICENSE). Upstream attributions in
[docs/CREDITS.md](docs/CREDITS.md).
