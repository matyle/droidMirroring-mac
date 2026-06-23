# DroidMirroring for macOS

Mirror your Android device screen to Mac natively. Low latency, full control.

![Platform](https://img.shields.io/badge/platform-macOS%2015%2B-blue)
![License](https://img.shields.io/badge/license-MIT-green)
![Universal](https://img.shields.io/badge/arch-Universal%20%28ARM64%20%2B%20x86__64%29-lightgrey)

[中文版文档 →](README_zh.md)

---

<p align="center">
  <img src="https://via.placeholder.com/800x450/1a1a2e/ffffff?text=🎬+Video+Demo+Coming+Soon" alt="Demo Video" width="800">
</p>

<p align="center">
  <img src="https://github.com/matyle/picx-images-hosting/raw/master/iShot_2026-06-23_11.13.36.5j4v6e0b6k.webp" width="48%" alt="Waiting for device">
  <img src="https://github.com/matyle/picx-images-hosting/raw/master/iShot_2026-06-23_11.14.05.7w7hnle4df.webp" width="48%" alt="Mirror mode">
</p>

<p align="center">
  <img src="https://github.com/matyle/picx-images-hosting/raw/master/iShot_2026-06-23_11.14.22.2h8z55yyzv.webp" width="48%" alt="Mirror window">
  <img src="https://github.com/matyle/picx-images-hosting/raw/master/iShot_2026-06-23_11.14.36.7snvpvl1o5.webp" width="48%" alt="Settings">
</p>

<p align="center">
  <img src="https://github.com/matyle/picx-images-hosting/raw/master/iShot_2026-06-23_11.14.56.232jeaqo58.webp" width="48%" alt="Desktop mode">
  <img src="https://github.com/matyle/picx-images-hosting/raw/master/iShot_2026-06-23_11.17.49.73um5uxml4.webp" width="48%" alt="File manager">
</p>

---

## Features

- 📱 **Real-time Mirroring** — Low-latency screen mirroring via scrcpy
- 🖥️ **Desktop Mode** — Run Android desktop on Mac (Android 14+)
- 📁 **File Manager** — Browse and transfer files via ADB
- ⌨️ **Keyboard & Mouse** — Full Mac input support
- 📡 **USB & Wi-Fi** — Wired or wireless connection
- 🎬 **Screen Recording** — Record device screen directly
- 🔀 **Universal Binary** — Native support for Apple Silicon & Intel Mac

## Download

| Version | Architecture | Download |
|---------|-------------|----------|
| Latest | **Universal** (ARM64 + x86_64) | [📦 DroidMirroring-universal.dmg](https://github.com/matyle/droidMirroring-mac/releases/latest) |

> Requires macOS 15.0 (Sequoia) or later.

## First Launch

> ⚠️ **Important:** Since the app is not notarized, macOS will block it on first launch. You need to manually allow it:
>
> 1. Double-click the app — you'll see a warning that it cannot be opened
> 2. Open **System Settings → Privacy & Security**
> 3. Scroll down and click **"Open Anyway"**
> 4. Confirm in the dialog

![Security warning](https://github.com/matyle/picx-images-hosting/raw/master/iShot_2026-06-23_14.14.50.92qsw7j4ek.webp)

![Open Anyway](https://github.com/matyle/picx-images-hosting/raw/master/iShot_2026-06-23_14.15.07.3nsads3z0u.webp)

## Quick Start

### USB Connection

1. **Enable USB Debugging** on your Android device:
   - Settings → About phone → Tap "Build number" 7 times
   - Settings → Developer options → Enable "USB debugging"
2. Connect via USB cable
3. Tap "Allow" on the device when prompted

### Wi-Fi Pairing

1. Click **"Pair over Wi-Fi"** on the main screen
2. Follow the pairing code prompt
3. Ensure both devices are on the same network

## FAQ

<details>
<summary><b>Device not detected?</b></summary>

- Make sure USB debugging is enabled
- Try a different USB cable
- Run `adb devices` in Terminal to verify connection
</details>

<details>
<summary><b>Mirroring is laggy?</b></summary>

- Use USB connection instead of Wi-Fi
- Lower the device screen resolution
</details>

## License

MIT License

## Support

- Bug reports & feedback: [Issues](https://github.com/matyle/droidMirroring-mac/issues)
