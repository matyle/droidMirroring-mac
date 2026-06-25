import SwiftUI
import ADBKit
import DeviceDiscovery
import FusionEngine
import SharedModels

struct MainView: View {
  @EnvironmentObject var monitor: DeviceMonitor
  @State private var showingPairingSheet = false

  var body: some View {
    Group {
      if monitor.devices.contains(where: { $0.state == .online }) {
        ConnectedDevicesView(devices: monitor.devices.filter { $0.state == .online })
      } else {
        WaitingForDeviceView(showingPairing: $showingPairingSheet)
      }
    }
    .frame(minWidth: 500, idealWidth: 600, minHeight: 420, idealHeight: 520)
    .sheet(isPresented: $showingPairingSheet) {
      PairingSheet(wireless: ResourceLocator.wirelessClient())
    }
  }
}

// MARK: empty state

private struct WaitingForDeviceView: View {
  @Binding var showingPairing: Bool
  @State private var showingUSBHelp = false

  var body: some View {
    VStack(spacing: 22) {
      Spacer()

      ZStack {
        Circle()
          .fill(Color.accentColor.opacity(0.12))
          .frame(width: 130, height: 130)
        Image(systemName: "iphone.gen3")
          .font(.system(size: 64, weight: .light))
          .foregroundStyle(.tint)
          .symbolEffect(.pulse, options: .repeat(.continuous))
      }

      VStack(spacing: 8) {
        Text("Waiting for an Android device")
          .font(.title2.weight(.semibold))
        Text("Connect via USB or pair wirelessly to get started.")
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
          .padding(.horizontal, 40)
      }

      VStack(spacing: 12) {
        // USB connection guide
        VStack(spacing: 8) {
          Label("Enable USB Debugging", systemImage: "terminal")
            .font(.headline)
          VStack(spacing: 4) {
            Text("Settings → About phone → Tap \"Build number\" 7 times")
            Text("Then Settings → Developer options → Turn on \"USB debugging\"")
          }
          .font(.caption)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 32)

        HStack(spacing: 12) {
          Button {
            showingUSBHelp = true
          } label: {
            Label("USB Guide", systemImage: "cable.connector")
          }
          .controlSize(.large)

          Button {
            showingPairing = true
          } label: {
            Label("Pair over Wi-Fi", systemImage: "wifi.router")
          }
          .controlSize(.large)
          .buttonStyle(.borderedProminent)
        }
      }
      .padding(.top, 4)

      Spacer()

      Text("Open the menu bar icon for settings · ⌘Q to quit")
        .font(.caption)
        .foregroundStyle(.tertiary)
        .padding(.bottom, 12)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(.background)
    .alert("How to enable USB Debugging", isPresented: $showingUSBHelp) {
      Button("OK", role: .cancel) {}
    } message: {
      Text("1. Open Settings on your Android device\n2. Go to \"About phone\"\n3. Tap \"Build number\" 7 times to unlock Developer options\n4. Go back to Settings → \"Developer options\"\n5. Turn on \"USB debugging\"\n6. Connect your device via USB cable\n7. When prompted, tap \"Allow\" on your device")
    }
  }
}

// MARK: connected — minimal "ready" panel; user just closes this and uses Mirror

private struct ConnectedDevicesView: View {
  let devices: [Device]

  var body: some View {
    VStack(spacing: 14) {
      Spacer()

      Image(systemName: "checkmark.circle.fill")
        .font(.system(size: 56))
        .foregroundStyle(.green)

      Text(devices.count == 1 ? "Device ready" : "\(devices.count) devices ready")
        .font(.title3.weight(.semibold))

      VStack(spacing: 6) {
        ForEach(devices) { device in
          ConnectedDeviceRow(device: device)
        }
      }
      .padding(.horizontal, 24)

      Spacer()

      Text("Mirror windows open automatically.\nUse the menu bar icon for settings.")
        .font(.caption)
        .foregroundStyle(.tertiary)
        .multilineTextAlignment(.center)
        .padding(.bottom, 16)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

private struct ConnectedDeviceRow: View {
  let device: Device

  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: device.transport == .wifi ? "wifi" : "cable.connector")
        .foregroundStyle(.secondary)
      VStack(alignment: .leading, spacing: 1) {
        Text(device.model.isEmpty ? device.id : device.model)
          .font(.callout.weight(.medium))
        Text("\(device.manufacturer.isEmpty ? "Android" : device.manufacturer) · SDK \(device.androidSDK)")
          .font(.caption2.monospaced())
          .foregroundStyle(.secondary)
      }
      Spacer()
      Button("Mirror") {
        Task { await SessionCoordinator.shared.startMirror(for: device) }
      }
      Button("Files") {
        SessionCoordinator.shared.openFiles(for: device)
      }
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 8)
    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
  }
}

private struct DeviceDashboard: View {
  let device: Device

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        DashboardHeader(device: device)
        ActionGrid(device: device)
      }
      .padding(32)
    }
  }
}

private struct DashboardHeader: View {
  let device: Device

  var body: some View {
    HStack(spacing: 16) {
      Image(systemName: "iphone.gen3")
        .font(.system(size: 56))
        .foregroundStyle(.tint)
      VStack(alignment: .leading, spacing: 4) {
        Text(device.model.isEmpty ? device.id : device.model)
          .font(.title)
        Text("\(device.manufacturer) · Android SDK \(device.androidSDK)")
          .foregroundStyle(.secondary)
        TransportChip(transport: device.transport, state: device.state)
      }
      Spacer()
    }
  }
}

private struct TransportChip: View {
  let transport: Device.Transport
  let state: Device.State

  var body: some View {
    HStack(spacing: 4) {
      Circle()
        .fill(state == .online ? .green : .gray)
        .frame(width: 6, height: 6)
      Text("\(transport.rawValue.uppercased()) · \(state.rawValue)")
        .font(.caption.monospaced())
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 3)
    .background(.thinMaterial, in: Capsule())
  }
}

private struct ActionGrid: View {
  let device: Device
  @State private var desktopUnavailable = false
  @State private var showingFusionSoon = false

  private let actions: [(label: String, icon: String)] = [
    ("Mirror", "rectangle.on.rectangle"),
    ("Desktop", "display"),
    ("Fusion", "macwindow.on.rectangle"),
    ("Files", "folder"),
    ("Screenshot", "camera"),
    ("Record", "record.circle"),
  ]

  var body: some View {
    LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 16)], spacing: 16) {
      ForEach(actions, id: \.label) { action in
        Button {
          handle(action: action.label)
        } label: {
          VStack(spacing: 8) {
            Image(systemName: action.icon)
              .font(.system(size: 28))
            Text(action.label)
              .font(.headline)
          }
          .frame(maxWidth: .infinity, minHeight: 90)
          .padding()
          .background(.background.tertiary, in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
      }
    }
    .alert("Desktop Mode requires Android 14+", isPresented: $desktopUnavailable) {
      Button("OK", role: .cancel) {}
    } message: {
      Text("This device reports Android SDK \(device.androidSDK). Update Android or use Mirror mode instead.")
    }
    .alert("Fusion Mode — coming soon", isPresented: $showingFusionSoon) {
      Button("OK", role: .cancel) {}
    } message: {
      Text("Fusion runs one Android app per macOS window without the device's desktop launcher in between. Today's build can only open a full desktop on a virtual display — use Desktop Mode for that.")
    }
  }

  private func handle(action: String) {
    switch action {
    case "Mirror":
      Task { await SessionCoordinator.shared.startMirror(for: device) }
    case "Files":
      SessionCoordinator.shared.openFiles(for: device)
    case "Desktop":
      if device.supportsFreeform {
        Task { await SessionCoordinator.shared.openDesktop(for: device) }
      } else {
        desktopUnavailable = true
      }
    case "Fusion":
      showingFusionSoon = true
    default:
      break
    }
  }
}

private struct FusionAppPicker: View {
  let device: Device
  @Environment(\.dismiss) private var dismiss
  @State private var apps: [InstalledApp] = []
  @State private var loading = true
  @State private var error: String?
  @State private var search = ""

  private var filtered: [InstalledApp] {
    guard !search.isEmpty else { return apps }
    let needle = search.lowercased()
    return apps.filter { $0.label.lowercased().contains(needle) || $0.packageName.lowercased().contains(needle) }
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        VStack(alignment: .leading, spacing: 2) {
          Text("Desktop Mode").font(.headline)
          Text("Open a landscape Android desktop on a virtual display. Pick an app to focus there first.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
        Button("Cancel") { dismiss() }
      }
      .padding()

      if loading {
        ProgressView("Listing apps…").padding(24)
      } else if let error {
        ContentUnavailableView("Could not list apps", systemImage: "exclamationmark.triangle", description: Text(error))
          .padding(24)
      } else {
        TextField("Search", text: $search)
          .textFieldStyle(.roundedBorder)
          .padding(.horizontal)
        List(filtered) { app in
          Button {
            launch(app)
          } label: {
            VStack(alignment: .leading, spacing: 2) {
              Text(app.label)
              Text(app.packageName).font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
          }
          .buttonStyle(.plain)
        }
      }
    }
    .frame(minWidth: 480, minHeight: 480)
    .task { await load() }
  }

  private func load() async {
    loading = true
    error = nil
    do {
      let catalog = SessionCoordinator.shared.appCatalog()
      apps = try await catalog.listInstalled(serial: device.id)
    } catch {
      self.error = "\(error)"
    }
    loading = false
  }

  private func launch(_ app: InstalledApp) {
    dismiss()
    Task { await SessionCoordinator.shared.launchFusionApp(for: device, app: app) }
  }
}
