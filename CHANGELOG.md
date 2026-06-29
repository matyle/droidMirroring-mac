# Changelog

All notable changes to DroidMirroring will be documented in this file.

## [v1.2.0] - 2026-06-29

### Added
- **中文本地化**：全部 UI 文本支持简体中文，系统语言为中文时自动显示
- **… 菜单悬停弹出**：菜单栏和镜像窗口中的 `…` 按钮支持鼠标悬停自动弹出
- **⌘. 快捷键**：在镜像窗口中按 `⌘.` 快速打开/关闭 More 操作面板
- 英文本地化（en）备用

### Changed
- 菜单栏 `…` 按钮由 Menu 改为 Popover，悬停 300ms 弹出
- 镜像窗口悬浮栏 `…` 按钮悬停 250ms 自动弹出 More 面板
- More 面板按钮文字支持本地化
- 设备数量显示正确处理单复数

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
