# DroidMirroring for macOS

将 Android 设备屏幕镜像到 Mac 上的原生应用。

![Platform](https://img.shields.io/badge/platform-macOS%2014%2B-blue)
![License](https://img.shields.io/badge/license-MIT-green)

## 功能特性

- 📱 **实时镜像** - 低延迟将 Android 屏幕镜像到 Mac
- 🖥️ **桌面模式** - 在 Mac 上运行 Android 桌面（Android 14+）
- 📁 **文件管理** - 通过 ADB 浏览和传输设备文件
- ⌨️ **键盘鼠标** - 直接使用 Mac 键盘和鼠标控制设备
- 📡 **无线连接** - 支持 USB 和 Wi-Fi 无线连接
- 🎬 **屏幕录制** - 直接录制设备屏幕

## 系统要求

- macOS 14.0 (Sonoma) 或更高版本
- Apple Silicon (M1/M2/M3) 或 Intel Mac
- Android 设备（需要开启 USB 调试）

## 安装

从 [Releases](https://github.com/matyle/droidMirroring-mac/releases) 页面下载最新的 `.dmg` 文件，拖入 Applications 文件夹即可。

## 快速开始

### USB 连接

1. 在 Android 设备上开启 **USB 调试**：
   - 设置 → 关于手机 → 连续点击"版本号"7次
   - 设置 → 开发者选项 → 开启"USB调试"
2. 使用 USB 线连接 Mac
3. 在 Android 上点击"允许"授权

### Wi-Fi 无线连接

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

## 许可证

MIT License
