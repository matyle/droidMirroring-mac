import SwiftUI

struct SettingsView: View {
  var body: some View {
    TabView {
      GeneralSettings()
        .tabItem { Label("General", systemImage: "gearshape") }
      MirrorSettings()
        .tabItem { Label("Mirror", systemImage: "rectangle.on.rectangle") }
      AdvancedSettings()
        .tabItem { Label("Advanced", systemImage: "wrench.and.screwdriver") }
    }
    .padding(20)
  }
}

private struct GeneralSettings: View {
  @AppStorage("launchAtLogin") private var launchAtLogin = false
  @AppStorage("showMenuBarIcon") private var showMenuBarIcon = true
  @AppStorage("mirror.autoOnConnect") private var autoMirror = true

  var body: some View {
    Form {
      Section("Startup") {
        Toggle("Launch at login", isOn: $launchAtLogin)
        Toggle("Show menu bar icon", isOn: $showMenuBarIcon)
      }
      Section("Behavior") {
        Toggle("Open Mirror automatically when a device connects", isOn: $autoMirror)
        Text("iPhone-Mirroring-style: skip the picker and jump straight to the mirror window for the first online device per session.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }
}

private struct MirrorSettings: View {
  @AppStorage("mirror.codec") private var codec = "h265"
  @AppStorage("mirror.bitrate") private var bitrate = 4
  @AppStorage("mirror.maxFps") private var maxFps = 30
  @AppStorage("mirror.autoScreenOff") private var autoScreenOff = true
  @AppStorage("mirror.clipboardSync") private var clipboardSync = true

  var body: some View {
    Form {
      Section("Video") {
        Picker("Codec", selection: $codec) {
          Text("H.265").tag("h265")
          Text("H.264").tag("h264")
          Text("AV1").tag("av1")
        }
        Stepper("Bitrate: \(bitrate) Mbps", value: $bitrate, in: 1...50)
        Stepper("Max FPS: \(maxFps)", value: $maxFps, in: 15...120, step: 5)
        Text("Lower bitrate / FPS = less heat. For 90/120Hz devices, increase FPS for smoother motion. Defaults (4 Mbps / 30 fps) are tuned for thermals.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Section("Privacy") {
        Toggle("Turn off device screen on mirror start", isOn: $autoScreenOff)
        Text("Keeps the phone display dark while you work on the Mac. The toolbar 🌙 button toggles it manually any time.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Section("Clipboard") {
        Toggle("Sync clipboard with device", isOn: $clipboardSync)
        Text("Two-way sync between macOS pasteboard and the Android clipboard.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }
}

private struct AdvancedSettings: View {
  @AppStorage("adb.path") private var adbPath = ""
  @State private var cleaning = false
  @State private var cleanResult: String = ""

  var body: some View {
    Form {
      TextField("Custom adb path", text: $adbPath, prompt: Text("Leave empty to use bundled adb"))

      Section("Troubleshooting") {
        VStack(alignment: .leading, spacing: 6) {
          Button {
            cleanResult = ""
            cleaning = true
            Task {
              do {
                try await SessionCoordinator.shared.cleanupScrcpyServers()
                cleanResult = "✅ Cleaned up old scrcpy-server files from all connected devices."
              } catch {
                cleanResult = "❌ Failed: \(error.localizedDescription)"
              }
              cleaning = false
            }
          } label: {
            Label(cleaning ? "Cleaning…" : "Clean up old scrcpy-server on devices",
                  systemImage: cleaning ? "arrow.triangle.2.circlepath" : "trash")
          }
          .disabled(cleaning)

          if !cleanResult.isEmpty {
            Text(cleanResult)
              .font(.caption.monospaced())
              .foregroundStyle(cleanResult.hasPrefix("✅") ? .green : .red)
              .padding(.top, 2)
          }
        }
        Text("Use this if Mirror fails to connect with a protocol error. Removes leftover scrcpy-server jars from the device.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }
}
