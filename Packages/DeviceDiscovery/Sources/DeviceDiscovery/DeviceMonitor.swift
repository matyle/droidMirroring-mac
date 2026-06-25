import Foundation
import Combine
import ADBKit
import SharedModels

@MainActor
public final class DeviceMonitor: ObservableObject {
  @Published public private(set) var devices: [Device] = []
  @Published public private(set) var lastError: String?

  private let adb: ADBClient
  private let adbBinary: URL?
  private var trackTask: Task<Void, Never>?
  /// Per-serial cache of SDK/manufacturer/model gathered via `getprop`. Skip
  /// re-querying every time host:track-devices pings us; props are static for
  /// the device's session.
  private var propsCache: [String: (sdk: Int, manufacturer: String)] = [:]

  public init(adb: ADBClient = ADBClient(), adbBinary: URL? = nil) {
    self.adb = adb
    self.adbBinary = adbBinary
  }

  public func start() {
    guard trackTask == nil else { return }
    bootstrapServer()
    trackTask = Task { [weak self] in
      await self?.trackLoop()
    }
  }

  public func stop() {
    trackTask?.cancel()
    trackTask = nil
  }

  /// Ensure an `adb` server is running on 127.0.0.1:5037. Without it, host:* commands
  /// fail with "cannot connect to daemon".
  private func bootstrapServer() {
    guard let binary = adbBinary else { return }
    let process = Process()
    process.executableURL = binary
    process.arguments = ["start-server"]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    do {
      try process.run()
      process.waitUntilExit()
    } catch {
      lastError = "adb start-server: \(error)"
    }
  }

  /// `host:track-devices` keeps the connection open and pushes a fresh device list
  /// every time the daemon's view changes (USB plug, Wi-Fi pair, auth change).
  private func trackLoop() async {
    while !Task.isCancelled {
      do {
        try await trackOnce()
      } catch {
        await MainActor.run { self.lastError = "\(error)" }
        try? await Task.sleep(nanoseconds: 1_500_000_000)
      }
    }
  }

  private func trackOnce() async throws {
    let conn = ADBConnection()
    try await conn.open()
    try await conn.sendCommand("host:track-devices-l")
    while !Task.isCancelled {
      let payload = try await conn.readLengthPrefixedString()
      let parsed = payload.split(separator: "\n").compactMap(ADBClient.parseDeviceLine)
      let enriched = await enrich(parsed)
      await MainActor.run {
        self.devices = enriched
        self.lastError = nil
      }
    }
    await conn.close()
  }

  /// Kill any scrcpy server processes left over from a previous crash / hard
  /// quit of this app. Each leaked process holds a virtual display open on
  /// the device until reboot.
  public func sweepStaleScrcpyServers() async {
    let online = await MainActor.run { self.devices.filter { $0.state == .online } }
    for device in online {
      _ = try? await adb.shell(
        "pkill -f 'scrcpy.Server' || true; pkill -f 'scrcpy.CleanUp' || true",
        serial: device.id
      )
    }
  }

  /// Backfill SDK + manufacturer for each online device. `host:track-devices-l`
  /// only reports id/model/transport — Fusion gating needs the SDK level too.
  private func enrich(_ devices: [Device]) async -> [Device] {
    var result: [Device] = []
    for device in devices {
      if device.state != .online {
        result.append(device); continue
      }
      let cached = await MainActor.run { self.propsCache[device.id] }
      if let cached {
        var d = device
        d.androidSDK = cached.sdk
        d.manufacturer = cached.manufacturer
        result.append(d)
        continue
      }
      let props = (try? await adb.shell(
        "getprop ro.build.version.sdk; getprop ro.product.manufacturer",
        serial: device.id
      )) ?? ""
      let lines = props.split(separator: "\n").map {
        $0.trimmingCharacters(in: .whitespacesAndNewlines)
      }
      let sdk = lines.first.flatMap { Int($0) } ?? 0
      let manufacturer = lines.count > 1 ? lines[1] : ""
      var d = device
      d.androidSDK = sdk
      d.manufacturer = manufacturer
      if sdk > 0 {
        await MainActor.run {
          self.propsCache[device.id] = (sdk: sdk, manufacturer: manufacturer)
        }
      }
      result.append(d)
    }
    return result
  }
}
