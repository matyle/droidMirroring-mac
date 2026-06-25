# Building

## Prerequisites

| Tool | Version | Why |
|---|---|---|
| macOS | 15+ | `SWIFT_VERSION=6.0`, `deploymentTarget=15.0`, modern FileProvider APIs |
| Xcode | 16+ | Swift 6 strict concurrency |
| XcodeGen | latest | `.xcodeproj` is regenerated from `project.yml` |

```sh
brew install xcodegen
```

The repo deliberately does not check in `.xcodeproj` — every change to targets,
build settings, or entitlements happens in `project.yml`.

## First-time setup

```sh
cd /Users/matrix/.config/DroidMirroring

# 1. Fetch scrcpy-server.jar + Google platform-tools adb into App/Resources/.
#    Also resolves SwiftPM for every local package.
./scripts/bootstrap.sh

# 2. Generate the Xcode project.
xcodegen generate

# 3. Open it.
open DroidMirroring.xcodeproj
```

`scripts/bootstrap.sh` calls:
- `scripts/fetch-scrcpy-server.sh` — pulls the pinned scrcpy-server-vX.jar
  release; version lives in `scripts/versions.env`.
- `scripts/fetch-adb.sh` — pulls Google's `platform-tools.zip` and extracts
  `adb` into `App/Resources/adb`.
- `swift package resolve` in every `Packages/*/`.

## Building the App

### Debug

```sh
xcodebuild -project DroidMirroring.xcodeproj \
           -scheme DroidMirroring \
           -configuration Debug \
           -destination 'platform=macOS' \
           build
```

In Xcode just hit ⌘R. The Debug build uses your **Personal Team** for ad-hoc
signing — fine for everything except the FileProvider extension, which is
disabled by default (see TROUBLESHOOTING.md).

### Release

Edit `project.yml` and set `DEVELOPMENT_TEAM` to your Apple Developer Team ID,
then:

```sh
xcodegen generate
xcodebuild -project DroidMirroring.xcodeproj \
           -scheme DroidMirroring \
           -configuration Release \
           build
```

Notarization + DMG packaging (M5) lives in `scripts/build-dmg.sh` (planned).

## CLI smoke tests

These live in two SPM executable targets and require a real online device
visible to `adb devices`. They are the fastest way to validate the wire
protocols outside Xcode.

### sync-smoke

Walks the adb sync sub-protocol against a real device:

```sh
cd Packages/ADBKit
swift run sync-smoke
```

Lists `/sdcard`, stats the first file, pulls it (if ≤ 5 MiB) to a temp file,
verifies size, QUITs. Prints `SYNC SMOKE PASSED` on success.

### scrcpy-smoke

Drives a full scrcpy-server launch (push, reverse, app_process, accept) and
reads 5 frames including a config (SPS/PPS) packet:

```sh
cd Packages/ScrcpyClient
swift run scrcpy-smoke \
    ../../App/Resources/scrcpy-server.jar \
    ../../App/Resources/adb \
    [optional-serial]
```

Prints `SMOKE TEST PASSED` if a config packet is seen and at least 5 frames
arrive within 10 seconds.

## Unit tests

Per package:

```sh
swift test --package-path Packages/ADBKit
swift test --package-path Packages/ScrcpyClient
swift test --package-path Packages/MirrorEngine
```

Or all at once:

```sh
for pkg in Packages/*/; do
  (cd "$pkg" && swift test)
done
```

These tests are pure unit tests — no real device required.

## Disabled by default: FileProviderExt

`Extensions/FileProviderExt` is built into the bundle but never **activates**:

- The main App leaves `FinderDomainCoordinator.shared.start(monitor:)` commented
  out in `App/droidMirroringApp.swift`.
- `NSFileProviderManager.add(domain:)` returns `-2001` / `-2014` under ad-hoc
  signing — Finder rejects the extension unless its bundle is signed with a
  real Apple Developer Team ID.

To enable Finder integration:

1. Set `DEVELOPMENT_TEAM` in `project.yml`.
2. Re-run `xcodegen generate`.
3. Uncomment `FinderDomainCoordinator.shared.start(monitor: monitor)` in
   `App/droidMirroringApp.swift`.
4. Build Release, sign with Developer ID, install in `/Applications`.

## Common workflows

Regenerate the project after editing `project.yml`:

```sh
xcodegen generate && open DroidMirroring.xcodeproj
```

Refresh bundled binaries (when bumping scrcpy or platform-tools):

```sh
$EDITOR scripts/versions.env
./scripts/bootstrap.sh
```

Run only one package's tests:

```sh
swift test --package-path Packages/ADBKit --filter DisplayInfoTests
```

Build the LSUIElement helpers individually:

```sh
xcodebuild -project DroidMirroring.xcodeproj -scheme ScreenMirroringHelper build
xcodebuild -project DroidMirroring.xcodeproj -scheme FusionModeHelper build
xcodebuild -project DroidMirroring.xcodeproj -scheme ContinueOnHelper build
```

(They embed automatically into the main App bundle on a top-level build.)

## Cleaning build artifacts

The SPM `.build/` folders for the six local packages add up to ~900 MB; the
project DerivedData adds another ~115 MB. `scripts/clean.sh` wipes both:

```sh
./scripts/clean.sh             # SPM caches + project DerivedData (default)
./scripts/clean.sh --light     # SPM caches only, leave Xcode cache
./scripts/clean.sh --all       # also drop .xcodeproj + fetched binaries
                               # (next bootstrap re-downloads adb + scrcpy-server)
./scripts/clean.sh --help
```

Everything `clean.sh` removes is regenerable by `swift build`, Xcode,
`xcodegen generate`, or `scripts/bootstrap.sh`.

## Regenerating the app icon

`AppIcon.appiconset` is generated from a Core Graphics drawing — there is no
master `.psd` / `.svg`. Edit the drawing then re-run:

```sh
swift scripts/generate-icon.swift
xcodegen generate
```

The script writes PNGs at 16/32/64/128/256/512/1024 px and the
`Contents.json` manifest into `App/Resources/Assets.xcassets/AppIcon.appiconset/`.
