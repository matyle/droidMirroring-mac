# DroidMirroring for macOS

将 Android 设备屏幕镜像到 Mac 上的原生应用。低延迟，全控制。

![Platform](https://img.shields.io/badge/platform-macOS%2015%2B-blue)
![License](https://img.shields.io/badge/license-Apache--2.0-green)
![Universal](https://img.shields.io/badge/arch-通用二进制%20%28ARM64%20%2B%20x86__64%29-lightgrey)
![Swift](https://img.shields.io/badge/Swift%206-F05138?logo=swift&logoColor=white)
![Downloads](https://img.shields.io/github/downloads/matyle/droidMirroring-mac/total?color=orange&logo=github)
![Last Release](https://img.shields.io/github/v/release/matyle/droidMirroring-mac?include_prereleases&logo=github)

[English README →](README.md)

---

<p align="center">
  <img src="https://github.com/matyle/picx-images-hosting/raw/master/iShot_2026-06-23_16.11.49.4xv7k7mpkq.png" width="48%" alt="等待设备">
  <img src="https://github.com/matyle/picx-images-hosting/raw/master/iShot_2026-06-23_16.04.36.9rk2gbyho4.png" width="48%" alt="镜像模式">
</p>

<p align="center">
  <img src="https://github.com/matyle/picx-images-hosting/raw/master/iShot_2026-06-23_15.53.05.7ehfz47j7r.webp" width="48%" alt="桌面模式">
  <img src="https://github.com/matyle/picx-images-hosting/raw/master/iShot_2026-06-23_11.14.36.7snvpvl1o5.webp" width="48%" alt="设置">
</p>

<p align="center">
  <img src="https://github.com/matyle/picx-images-hosting/raw/master/iShot_2026-06-23_11.17.49.73um5uxml4.webp" width="48%" alt="文件管理">
</p>

---

## 功能特性

- 📱 **实时镜像** — 通过 scrcpy 实现低延迟屏幕镜像
- 🖥️ **桌面模式** — 在 Mac 上运行 Android 桌面（需 Android 14+）
- 📁 **文件管理** — 通过 ADB 浏览和传输文件
- ⌨️ **键盘鼠标** — 完整的 Mac 输入支持
- 📡 **USB 和 Wi-Fi** — 有线或无线连接
- 🎬 **屏幕录制** — 直接录制设备屏幕
- 🔀 **通用二进制** — 原生支持 Apple Silicon 和 Intel Mac

## 下载

| 版本 | 架构 | 下载 |
|------|------|------|
| 最新 | **通用** (ARM64 + x86_64) | [📦 DroidMirroring-universal.dmg](https://github.com/matyle/droidMirroring-mac/releases/latest) |

> 需要 macOS 15.0 (Sequoia) 或更高版本。

## 首次运行

> ⚠️ **重要提示：** 由于应用未公证，macOS 会在首次打开时拦截。你需要手动允许：
>
> 1. 双击应用 — 会看到无法打开的警告
> 2. 打开 **系统设置 → 隐私与安全性**
> 3. 向下滚动，点击 **"仍要打开"**
> 4. 在弹出对话框中确认

![安全警告](https://github.com/matyle/picx-images-hosting/raw/master/iShot_2026-06-23_14.14.50.92qsw7j4ek.webp)

![仍要打开](https://github.com/matyle/picx-images-hosting/raw/master/iShot_2026-06-23_14.15.07.3nsads3z0u.webp)

## 快速开始

### USB 连接

1. 在 Android 设备上开启 **USB 调试**：
   - 设置 → 关于手机 → 连续点击"版本号"7次
   - 设置 → 开发者选项 → 开启"USB调试"
2. 使用 USB 线连接 Mac
3. 在 Android 上点击"允许"授权

### Wi-Fi 无线配对

1. 点击主界面 **"Pair over Wi-Fi"** 按钮
2. 按照提示输入配对码
3. 确保 Mac 和 Android 在同一网络

## 常见问题

<details>
<summary><b>检测不到设备？</b></summary>

- 确认 USB 调试已开启
- 尝试更换 USB 数据线
- 在终端运行 `adb devices` 检查连接状态
</details>

<details>
<summary><b>镜像画面卡顿？</b></summary>

- 无线连接时尝试改用 USB 连接
- 降低设备屏幕分辨率
</details>

<details>
<summary><b>无法操控手机（鼠标/键盘无效）？</b></summary>

- **小米/红米/POCO 用户：** 必须在开发者选项中开启 **"USB 调试（安全设置）"**，除了普通的"USB 调试"外。这个权限允许 ADB 模拟点击和键盘输入。不开启的话，镜像可以正常显示但无法点击和打字。
- 有线和无线连接都需要开启此项。
- 开启后重新连接设备再试。
</details>

## 致谢

本项目使用了以下开源软件：

- [scrcpy](https://github.com/Genymobile/scrcpy) by Genymobile — Apache License 2.0
- [adb (Android Debug Bridge)](https://developer.android.com/tools/adb) by Google — Apache License 2.0

scrcpy-server.jar 基于 Apache License 2.0 协议分发。

## 许可证

Apache-2.0 License — 详见 [LICENSE](LICENSE)

## 支持

- 问题反馈 & 建议：[Issues](https://github.com/matyle/droidMirroring-mac/issues)
- 在 X 上关注：[@tan_maty](https://x.com/tan_maty)
