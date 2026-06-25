# Xcode setup

`.xcodeproj` is **not** checked in — it's regenerated from `project.yml` via
[XcodeGen](https://github.com/yonaskolb/XcodeGen) so that diffs stay readable.

## 一次性

```sh
brew install xcodegen
```

## 每次拉新代码

```sh
./scripts/bootstrap.sh   # 拉 scrcpy-server.jar / adb
xcodegen generate        # 重新生成 DroidMirroring.xcodeproj
open DroidMirroring.xcodeproj
```

## targets

| Target | Bundle ID | Type |
|---|---|---|
| `DroidMirroring` | `com.droidmirroring.app.DroidMirroring` | App (SwiftUI) |
| `ScreenMirroringHelper` | `com.droidmirroring.app.DroidMirroring.ScreenMirroring` | LSUIElement App |
| `FusionModeHelper` | `com.droidmirroring.app.DroidMirroring.FusionMode` | LSUIElement App |
| `ContinueOnHelper` | `com.droidmirroring.app.DroidMirroring.ContinueOn` | LSUIElement App |
| `FileProviderExt` | `com.droidmirroring.app.DroidMirroring.FileProvider` | NSExtension (fileprovider-nonui) |
| `ThumbnailExt` | `com.droidmirroring.app.DroidMirroring.Thumbnail` | NSExtension (quicklook.thumbnail) |

## 签名

DEBUG 用 Personal Team 就行；Release 需在 `project.yml` 把 `DEVELOPMENT_TEAM`
填上 Apple Developer Team ID。FileProvider extension 必须 hardened runtime + sandbox。

## App Group

所有 target 共用 `group.com.droidmirroring.app.shared` —— App / Helpers / Extensions
通过 `AppGroup.containerURL`（在 `SharedModels`）读写设备列表 + token。

## DMG 打包

M5 阶段加 `scripts/build-dmg.sh`，调用 `create-dmg` + `notarytool submit`。
MAS 版另起 `project-mas.yml`，砍 FusionModeHelper 与 USB entitlement。
