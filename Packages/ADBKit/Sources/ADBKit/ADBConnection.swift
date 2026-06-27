import Foundation
import Network
import SharedModels

/// Low-level connection to the local adb server (default 127.0.0.1:5037).
///
/// Wire protocol (see https://android.googlesource.com/platform/system/core/+/master/adb/protocol.txt):
///   command  : 4 ASCII hex digits = payload length, followed by payload bytes
///   response : "OKAY" on success, or "FAIL" + 4-hex-length + ASCII error string
///
/// After `host:transport:<serial>` (or `host:transport-usb`/`host:transport-local`),
/// the connection is bound to the device. Subsequent commands like `shell:…` or `sync:`
/// run on that device. After `sync:`, the connection switches to the sync sub-protocol
/// (binary frames, see `SyncProtocol.swift`).
public actor ADBConnection {
  private let nw: NWConnection
  private var open = false

  public init(host: String = "127.0.0.1", port: Int = 5037) {
    let endpointPort = NWEndpoint.Port(rawValue: UInt16(port))!
    let endpointHost = NWEndpoint.Host(host)
    let params: NWParameters = .tcp
    if let tcpOpts = params.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
      tcpOpts.noDelay = true
      tcpOpts.enableKeepalive = true
    }
    self.nw = NWConnection(host: endpointHost, port: endpointPort, using: params)
  }

  // MARK: lifecycle

  public func open() async throws {
    guard !open else { return }
    try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
      nw.stateUpdateHandler = { [weak nw] state in
        switch state {
        case .ready:
          nw?.stateUpdateHandler = nil
          cont.resume()
        case .failed(let err), .waiting(let err):
          nw?.stateUpdateHandler = nil
          cont.resume(throwing: err)
        case .cancelled:
          nw?.stateUpdateHandler = nil
          cont.resume(throwing: DroidMirroringError.adbProtocol("connection cancelled before ready"))
        default:
          break
        }
      }
      nw.start(queue: .global(qos: .userInitiated))
    }
    open = true
  }

  public func close() async {
    nw.cancel()
    open = false
  }

  // MARK: raw I/O

  /// Read exactly `count` bytes. Throws if the peer closes early.
  public func readExact(_ count: Int) async throws -> Data {
    guard count > 0 else { return Data() }
    return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
      nw.receive(minimumIncompleteLength: count, maximumLength: count) { data, _, isComplete, error in
        // ENOMSG (errno 96) fires on wireless ADB when the device-side shell
        // stream closes mid-read. Treat it like an early EOF rather than
        // propagating a cryptic "No message available on STREAM" to the user.
        if let error, !Self.isENOMSG(error) {
          cont.resume(throwing: error); return
        }
        if let data, data.count == count {
          cont.resume(returning: data)
          return
        }
        let got = data?.count ?? 0
        if error != nil || isComplete {
          cont.resume(throwing: DroidMirroringError.adbProtocol("eof while reading \(count) bytes (got \(got))"))
          return
        }
        cont.resume(throwing: DroidMirroringError.adbProtocol("short read: got \(got) of \(count)"))
      }
    }
  }

  /// Read whatever bytes are available, up to `maxLength`. Returns empty `Data` on clean EOF.
  public func readAvailable(maxLength: Int = 64 * 1024) async throws -> Data {
    try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
      nw.receive(minimumIncompleteLength: 1, maximumLength: maxLength) { data, _, _, error in
        // ENOMSG on wireless ADB → treat as empty read (stream drained).
        if let error, !Self.isENOMSG(error) {
          cont.resume(throwing: error); return
        }
        cont.resume(returning: data ?? Data())
      }
    }
  }

  /// Read until the peer closes, accumulating everything. Used for short shell command output.
  public func readToEOF() async throws -> Data {
    var acc = Data()
    while true {
      let chunk = try await readAvailableOrEOF()
      if chunk.isEmpty { return acc }
      acc.append(chunk)
    }
  }

  private func readAvailableOrEOF() async throws -> Data {
    try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
      nw.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
        // ENOMSG (errno 96, macOS): "No message available on STREAM".
        // On wireless ADB connections the adb server proxies the device-side
        // shell over TCP; when the device daemon closes the stream, Network
        // .framework occasionally surfaces ENOMSG instead of a clean FIN.
        // This is a benign end-of-stream condition — treat it as EOF so
        // `dumpsys window`, `pm list packages`, etc. don't blow up.
        if let error, !Self.isENOMSG(error) {
          cont.resume(throwing: error); return
        }
        if let data, !data.isEmpty {
          cont.resume(returning: data); return
        }
        if isComplete || error != nil {
          cont.resume(returning: Data())
          return
        }
        cont.resume(returning: Data())
      }
    }
  }

  /// True if `error` is POSIX errno 96 (ENOMSG — "No message of desired type").
  ///
  /// This surfaces on wireless ADB (adb WiFi / `adb connect <ip>:<port>`) when
  /// the device-side adb daemon tears down the shell pseudo-tty after a command
  /// finishes. The adb TCP proxy relays the close as an ENOMSG rather than a
  /// clean TCP FIN, depending on timing and OS version (macOS 14/15, iOS 17+).
  /// The value 96 is the Darwin errno; on Linux ENOMSG is 91 — but this code
  /// only runs on macOS so 96 is correct.
  private static func isENOMSG(_ error: Error) -> Bool {
    let ns = error as NSError
    return ns.domain == NSPOSIXErrorDomain && ns.code == 96
  }

  public func write(_ data: Data) async throws {
    try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
      nw.send(content: data, completion: .contentProcessed { error in
        if let error { cont.resume(throwing: error) } else { cont.resume() }
      })
    }
  }

  // MARK: framed command

  /// Send a length-prefixed adb command and expect OKAY. Throws with the FAIL message otherwise.
  public func sendCommand(_ command: String) async throws {
    let framed = Self.frame(command)
    try await write(framed)
    let status = try await readExact(4)
    guard let s = String(data: status, encoding: .ascii) else {
      throw DroidMirroringError.adbProtocol("invalid status reply: \(status as NSData)")
    }
    switch s {
    case "OKAY":
      return
    case "FAIL":
      let lenBytes = try await readExact(4)
      let len = Int(String(data: lenBytes, encoding: .ascii) ?? "0", radix: 16) ?? 0
      let msg = try await readExact(len)
      throw DroidMirroringError.adbProtocol("FAIL: \(String(data: msg, encoding: .utf8) ?? "<bin>")")
    default:
      throw DroidMirroringError.adbProtocol("unexpected status: \(s)")
    }
  }

  /// Read a length-prefixed payload (4 hex digits + bytes). Used by `host:version`, `host:devices`, …
  public func readLengthPrefixedString() async throws -> String {
    let lenBytes = try await readExact(4)
    let len = Int(String(data: lenBytes, encoding: .ascii) ?? "0", radix: 16) ?? 0
    let payload = try await readExact(len)
    return String(data: payload, encoding: .utf8) ?? ""
  }

  /// Build a 4-hex-length + ASCII command frame.
  public static func frame(_ command: String) -> Data {
    let payload = Data(command.utf8)
    let header = String(format: "%04x", payload.count)
    var data = Data(header.utf8)
    data.append(payload)
    return data
  }
}
