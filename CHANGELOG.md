# Changelog

All notable changes to DroidMirroring will be documented in this file.

## [v0.2.5] - 2026-06-24

### Added
- CHANGELOG.md for tracking release changes
- Automated release notes extraction from CHANGELOG

## [v0.2.4] - 2026-06-24

### Fixed
- Screen wake now uses `setScreenPowerMode(2)` instead of KEYCODE_POWER for proper screen control
- Device screen is truly off when mirroring starts (no rendering, saves battery)

### Added
- Max FPS support up to 120fps for high refresh rate devices (90Hz/120Hz)
- Updated settings description to mention high refresh rate support

## [v0.2.3] - 2026-06-24

### Fixed
- WiFi pairing fails on networks with IPv6 enabled
- mDNS discovery now filters out IPv6 addresses (adb pair/connect only supports IPv4)

## [v0.2.2] - 2026-06-24

### Fixed
- App version in "About" now matches GitHub Release version
- Settings window not opening from menu bar
- Added Official Website and GitHub Repository links to About menu

## [v0.2.1] - 2026-06-24

### Added
- About menu with version display
- Check for Updates link to GitHub Releases
- Official Website and GitHub Repository links
- Versioned DMG filename (e.g., `DroidMirroring-v0.2.1-universal.dmg`)

## [v0.2.0] - 2026-06-24

### Added
- Unified Logging (os.Logger) for all debug output
- Users can view logs via Console.app: `log show --predicate 'subsystem=="com.droidmirroring.app"'`
- Auto-retry with displayId=0 when launch fails (handles fold/rotation display cache issues)
- Improved error messages with device info and troubleshooting tips

## [v0.1.0] - 2026-06-23

### Initial Release
- Real-time screen mirroring via scrcpy (H.265/VideoToolbox)
- Desktop Mode (Samsung DeX, Android 14+ freeform)
- File Manager with image thumbnails
- USB and Wi-Fi (Android 11+) connection
- Screen recording
- Universal Binary (Apple Silicon + Intel)
- Phone-bezel window design with auto-hiding chrome
- Two-way clipboard sync
- Settings for codec, bitrate, FPS, screen off
