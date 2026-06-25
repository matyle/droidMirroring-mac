import SwiftUI
import AppKit
import CoreImage.CIFilterBuiltins
import ADBKit
import DeviceDiscovery

/// Three-mode wireless ADB pairing sheet.
/// Mirrors AndroMeld's flow: QR / 6-digit code / manual IP.
struct PairingSheet: View {
  @Environment(\.dismiss) private var dismiss
  @StateObject private var browser = WirelessBrowser()
  @State private var mode: Mode = .pairingCode
  @State private var statusMessage: String?
  @State private var statusIsError = false
  @State private var working = false

  let wireless: ADBWirelessClient

  enum Mode: String, CaseIterable, Identifiable {
    case qr = "QR Code"
    case pairingCode = "Pairing Code"
    case manualIP = "Manual IP"
    var id: String { rawValue }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
      Picker("", selection: $mode) {
        ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .padding(.horizontal, 24)
      .padding(.bottom, 16)

      Group {
        switch mode {
        case .qr:          QRPane(browser: browser, wireless: wireless, status: bindStatus, working: $working)
        case .pairingCode: PairingCodePane(browser: browser, wireless: wireless, status: bindStatus, working: $working)
        case .manualIP:    ManualIPPane(wireless: wireless, status: bindStatus, working: $working)
        }
      }
      .padding(.horizontal, 24)
      .frame(minHeight: 320)

      footer
    }
    .frame(width: 560)
    .onAppear { browser.start() }
    .onDisappear { browser.stop() }
  }

  private var header: some View {
    HStack {
      VStack(alignment: .leading, spacing: 2) {
        Text("Add Wireless Device")
          .font(.title2.bold())
        Text("On your Android device: Settings → Developer options → Wireless debugging")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer()
      Button(action: { dismiss() }) { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
        .buttonStyle(.plain)
    }
    .padding(24)
  }

  private var footer: some View {
    HStack(spacing: 8) {
      if let msg = statusMessage {
        Image(systemName: statusIsError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
          .foregroundStyle(statusIsError ? .red : .green)
        Text(msg).font(.callout).foregroundStyle(.secondary)
      }
      Spacer()
      if working { ProgressView().scaleEffect(0.6) }
      Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
    }
    .padding(16)
    .background(.thickMaterial)
  }

  private var bindStatus: (String?, Bool) -> Void {
    { msg, isError in
      statusMessage = msg
      statusIsError = isError
    }
  }
}

// MARK: QR pane

private struct QRPane: View {
  @ObservedObject var browser: WirelessBrowser
  let wireless: ADBWirelessClient
  let status: (String?, Bool) -> Void
  @Binding var working: Bool

  @State private var sessionName = "DroidMirroring-\(Int.random(in: 1000...9999))"
  @State private var sessionPassword = String(format: "%06d", Int.random(in: 0..<1_000_000))
  @State private var pairingTriggered = false

  /// Android's pairing QR payload format: `WIFI:T:ADB;S:<name>;P:<password>;;`
  private var qrPayload: String {
    "WIFI:T:ADB;S:\(sessionName);P:\(sessionPassword);;"
  }

  var body: some View {
    HStack(alignment: .top, spacing: 24) {
      qrImage
        .interpolation(.none)
        .resizable()
        .scaledToFit()
        .frame(width: 220, height: 220)
        .padding(8)
        .background(.white, in: RoundedRectangle(cornerRadius: 8))

      VStack(alignment: .leading, spacing: 12) {
        Step(n: 1, text: "On Android, tap **Pair device with QR code** in Wireless debugging.")
        Step(n: 2, text: "Point the camera at this QR code.")
        Step(n: 3, text: "DroidMirroring auto-pairs as soon as the device appears.")
        if working { ProgressView("Pairing…").progressViewStyle(.linear) }
        Spacer()
        Button("Regenerate") {
          sessionName = "DroidMirroring-\(Int.random(in: 1000...9999))"
          sessionPassword = String(format: "%06d", Int.random(in: 0..<1_000_000))
          pairingTriggered = false
        }
        .font(.caption)
        .disabled(working)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .onChange(of: browser.pairingCandidates) { _, candidates in
      guard !pairingTriggered, !working else { return }
      // Android publishes the pair service with our `S:` name (taken from the QR).
      guard let match = candidates.first(where: { $0.serviceName == sessionName }) else { return }
      pairingTriggered = true
      autoPair(with: match)
    }
  }

  private func autoPair(with endpoint: WirelessEndpoint) {
    working = true
    status("Found \(endpoint.serviceName) — pairing…", false)
    Task {
      defer { Task { @MainActor in working = false } }
      do {
        try await wireless.pair(host: endpoint.host, port: endpoint.port, code: sessionPassword)
        // Right after pair, the device publishes a connect service — connect to it.
        try? await Task.sleep(nanoseconds: 800_000_000)
        if let live = await browser.connectableDevices.first {
          try await wireless.connect(host: live.host, port: live.port)
        }
        await MainActor.run { status("Paired — check the sidebar.", false) }
      } catch let err as ADBWirelessClient.WirelessError {
        await MainActor.run {
          status(humanError(err), true)
          pairingTriggered = false
        }
      } catch {
        await MainActor.run {
          status("\(error)", true)
          pairingTriggered = false
        }
      }
    }
  }

  private var qrImage: Image {
    let context = CIContext()
    let filter = CIFilter.qrCodeGenerator()
    filter.message = Data(qrPayload.utf8)
    filter.correctionLevel = "M"
    guard let output = filter.outputImage,
          let cg = context.createCGImage(output, from: output.extent)
    else { return Image(systemName: "qrcode") }
    let nsImage = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    return Image(nsImage: nsImage)
  }
}

private struct Step: View {
  let n: Int
  let text: String
  var body: some View {
    HStack(alignment: .top, spacing: 8) {
      Text("\(n)")
        .font(.caption.bold())
        .frame(width: 20, height: 20)
        .background(Color.accentColor.opacity(0.15), in: Circle())
      Text(.init(text))
        .font(.callout)
    }
  }
}

// MARK: Pairing-code pane

private struct PairingCodePane: View {
  @ObservedObject var browser: WirelessBrowser
  let wireless: ADBWirelessClient
  let status: (String?, Bool) -> Void
  @Binding var working: Bool

  @State private var selection: WirelessEndpoint.ID?
  @State private var code: String = ""

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Step(n: 1, text: "On Android: **Pair device with pairing code**.")
      Step(n: 2, text: "Pick the device below, type the 6-digit code shown on it.")

      let candidates = browser.pairingCandidates
      if candidates.isEmpty {
        VStack(spacing: 6) {
          ProgressView().scaleEffect(0.7)
          Text("Searching for devices…").font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 100, alignment: .center)
      } else {
        List(selection: $selection) {
          ForEach(candidates) { ep in
            HStack {
              Image(systemName: "iphone.gen3").foregroundStyle(.tint)
              VStack(alignment: .leading) {
                Text(ep.displayName).font(.callout)
                Text("\(ep.host):\(ep.port)").font(.caption.monospaced()).foregroundStyle(.secondary)
              }
            }
            .tag(ep.id)
          }
        }
        .listStyle(.bordered)
        .frame(minHeight: 120)
      }

      HStack {
        TextField("123456", text: $code)
          .textFieldStyle(.roundedBorder)
          .frame(width: 140)
          .font(.body.monospaced())
          .onChange(of: code) { _, new in
            code = String(new.filter(\.isNumber).prefix(6))
          }
        Button("Pair & Connect") { pair() }
          .disabled(selection == nil || code.count != 6 || working)
          .keyboardShortcut(.defaultAction)
      }
    }
  }

  private func pair() {
    guard let id = selection,
          let endpoint = browser.pairingCandidates.first(where: { $0.id == id })
    else { return }
    working = true
    status(nil, false)
    Task {
      defer { Task { @MainActor in working = false } }
      do {
        try await wireless.pair(host: endpoint.host, port: endpoint.port, code: code)
        // After pairing, find the connect-service for the same device and connect.
        try? await Task.sleep(nanoseconds: 500_000_000)
        if let live = await browser.connectableDevices.first {
          try await wireless.connect(host: live.host, port: live.port)
        }
        await MainActor.run { status("Paired — device should appear in the sidebar.", false) }
      } catch let err as ADBWirelessClient.WirelessError {
        await MainActor.run { status(humanError(err), true) }
      } catch {
        await MainActor.run { status("\(error)", true) }
      }
    }
  }
}

// MARK: Manual IP pane

private struct ManualIPPane: View {
  let wireless: ADBWirelessClient
  let status: (String?, Bool) -> Void
  @Binding var working: Bool

  @State private var host: String = ""
  @State private var port: String = ""
  @State private var pairCode: String = ""

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Step(n: 1, text: "On Android: **Wireless debugging → Pair device with pairing code**. Read off the IP, port, and 6-digit code.")
      Step(n: 2, text: "Type them here — leave code blank if you've already paired this device once.")

      VStack(alignment: .leading, spacing: 10) {
        HStack(spacing: 4) {
          Text("IP").font(.caption).foregroundStyle(.secondary).frame(width: 40, alignment: .leading)
          TextField("192.168.1.42", text: $host).textFieldStyle(.roundedBorder)
          Text(":").foregroundStyle(.secondary)
          TextField("port", text: $port)
            .textFieldStyle(.roundedBorder)
            .frame(width: 90)
            .font(.body.monospaced())
            .onChange(of: port) { _, new in port = String(new.filter(\.isNumber).prefix(5)) }
        }
        HStack(spacing: 4) {
          Text("Code").font(.caption).foregroundStyle(.secondary).frame(width: 40, alignment: .leading)
          TextField("123456 (optional)", text: $pairCode)
            .textFieldStyle(.roundedBorder)
            .frame(width: 180)
            .font(.body.monospaced())
            .onChange(of: pairCode) { _, new in pairCode = String(new.filter(\.isNumber).prefix(6)) }
          Text("required for first-time pairing").font(.caption).foregroundStyle(.secondary)
        }
      }

      HStack {
        Spacer()
        Button(pairCode.isEmpty ? "Connect" : "Pair & Connect") { go() }
          .disabled(host.isEmpty || Int(port) == nil || working || (!pairCode.isEmpty && pairCode.count != 6))
          .keyboardShortcut(.defaultAction)
      }
      Spacer()
    }
  }

  private func go() {
    guard let portNum = Int(port) else {
      status("Port must be a number.", true); return
    }
    working = true
    status(nil, false)
    let needsPair = !pairCode.isEmpty
    let code = pairCode
    Task {
      defer { Task { @MainActor in working = false } }
      do {
        if needsPair {
          try await wireless.pair(host: host, port: portNum, code: code)
          await MainActor.run { status("Paired. Connecting…", false) }
          // Wait a beat for the device to publish the connect service / open the port.
          try? await Task.sleep(nanoseconds: 800_000_000)
          // After pair, the connect port is usually different from the pair port.
          // The user can connect via manual IP again with the main IP:port, or we
          // can leave it paired — adb auto-connects on subsequent discoveries.
          await MainActor.run { status("Paired — enter the main IP:port (different number) to connect.", false) }
        } else {
          try await wireless.connect(host: host, port: portNum)
          await MainActor.run { status("Connected.", false) }
        }
      } catch let err as ADBWirelessClient.WirelessError {
        await MainActor.run { status(humanError(err), true) }
      } catch {
        await MainActor.run { status("\(error)", true) }
      }
    }
  }
}

private func humanError(_ err: ADBWirelessClient.WirelessError) -> String {
  switch err {
  case .missingMDNS:         return "No wireless ADB service found on this network."
  case .pairingTimeout:      return "Pairing timed out — keep the pair screen open on the device."
  case .pairingInvalidCode:  return "Wrong pairing code — try again."
  case .pairingSwitchFailed: return "Device rejected the pairing."
  case .connectUnverified:   return "Device is not authorized — accept the prompt on Android."
  case .addressInvalid(let s): return "Invalid address: \(s)"
  case .adbMissing:          return "Bundled adb is missing — reinstall DroidMirroring."
  case .adb(let s):          return s.isEmpty ? "adb returned an unknown error." : s
  }
}
