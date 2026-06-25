import Foundation
import SharedModels

/// High-level API on top of `ADBConnection`.
///
/// Every call opens a fresh connection: the adb server's protocol is single-shot,
/// so reusing connections across services would require state-tracking we don't need.
public actor ADBClient {
  public struct Config: Sendable {
    public var serverHost: String
    public var serverPort: Int
    public init(serverHost: String = "127.0.0.1", serverPort: Int = 5037) {
      self.serverHost = serverHost
      self.serverPort = serverPort
    }
  }

  public let config: Config

  public init(config: Config = .init()) {
    self.config = config
  }

  // MARK: host services

  public func serverVersion() async throws -> Int {
    let conn = ADBConnection(host: config.serverHost, port: config.serverPort)
    try await conn.open()
    defer { Task { await conn.close() } }
    try await conn.sendCommand("host:version")
    let hex = try await conn.readLengthPrefixedString()
    return Int(hex, radix: 16) ?? 0
  }

  public func listDevices() async throws -> [Device] {
    let conn = ADBConnection(host: config.serverHost, port: config.serverPort)
    try await conn.open()
    defer { Task { await conn.close() } }
    try await conn.sendCommand("host:devices-l")
    let body = try await conn.readLengthPrefixedString()
    return body.split(separator: "\n").compactMap(Self.parseDeviceLine)
  }

  // MARK: device-scoped services

  /// `host:transport:<serial>` switches the connection to the device. After this,
  /// the next `sendCommand` runs on-device (shell:, sync:, framebuffer:, …).
  private func attach(to serial: String) async throws -> ADBConnection {
    let conn = ADBConnection(host: config.serverHost, port: config.serverPort)
    try await conn.open()
    try await conn.sendCommand("host:transport:\(serial)")
    return conn
  }

  public func shell(_ command: String, serial: String) async throws -> String {
    let conn = try await attach(to: serial)
    defer { Task { await conn.close() } }
    try await conn.sendCommand("shell:\(command)")
    let data = try await conn.readToEOF()
    return String(data: data, encoding: .utf8) ?? ""
  }

  public func forward(localPort: Int, remoteUnixSocket: String, serial: String) async throws {
    let conn = ADBConnection(host: config.serverHost, port: config.serverPort)
    try await conn.open()
    defer { Task { await conn.close() } }
    try await conn.sendCommand("host-serial:\(serial):forward:tcp:\(localPort);localabstract:\(remoteUnixSocket)")
    // host service replies with a second OKAY after the first; consume it.
    _ = try? await conn.readExact(4)
  }

  public func reverse(remoteUnixSocket: String, localPort: Int, serial: String) async throws {
    let conn = try await attach(to: serial)
    defer { Task { await conn.close() } }
    try await conn.sendCommand("reverse:forward:localabstract:\(remoteUnixSocket);tcp:\(localPort)")
    _ = try? await conn.readExact(4)
  }

  public func removeReverse(remoteUnixSocket: String, serial: String) async throws {
    let conn = try await attach(to: serial)
    defer { Task { await conn.close() } }
    try await conn.sendCommand("reverse:killforward:localabstract:\(remoteUnixSocket)")
  }

  public func push(localPath: URL, remotePath: String, serial: String) async throws {
    throw DroidMirroringError.unimplemented("ADBClient.push — implement via SyncSession.send in M3")
  }

  public func pull(remotePath: String, localPath: URL, serial: String) async throws {
    throw DroidMirroringError.unimplemented("ADBClient.pull — implement via SyncSession.recv in M3")
  }

  // MARK: sync session

  /// Open a sync transport bound to `serial`. The returned ADBConnection has already
  /// sent `sync:` and is positioned at the start of the sync sub-protocol.
  public func openSyncTransport(serial: String) async throws -> ADBConnection {
    let conn = try await attach(to: serial)
    try await conn.sendCommand("sync:")
    return conn
  }

  // MARK: parsing

  /// Parse one line of `host:devices-l` output into a Device.
  /// Example: `R5CTC0ABCDE       device usb:0-1.2 product:e1q model:SM_S921B device:e1q transport_id:3`
  public static func parseDeviceLine(_ line: Substring) -> Device? {
    let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
    guard parts.count >= 2 else { return nil }
    let serial = parts[0]
    let stateRaw = parts[1]
    let state: Device.State
    switch stateRaw {
    case "device": state = .online
    case "offline": state = .offline
    case "unauthorized": state = .unauthorized
    case "recovery": state = .recovery
    default: state = .offline
    }
    var model = ""
    var transport: Device.Transport = .unknown
    for token in parts.dropFirst(2) {
      if token.hasPrefix("model:") {
        model = String(token.dropFirst("model:".count)).replacingOccurrences(of: "_", with: " ")
      } else if token.hasPrefix("usb:") {
        transport = .usb
      } else if token.contains(":") == false && token.contains(".") {
        // ip-style serial — e.g. 192.168.1.5:5555
        transport = .wifi
      }
    }
    if transport == .unknown && serial.contains(":") {
      transport = .wifi
    } else if transport == .unknown {
      transport = .usb
    }
    return Device(id: serial, model: model, transport: transport, state: state)
  }
}
