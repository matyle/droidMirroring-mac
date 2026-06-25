import Foundation
import SharedModels

/// Pair / connect / disconnect operations for Android 11+ Wireless ADB.
///
/// Implemented by shelling out to the bundled `adb` binary — these flows
/// use TLS + SPAKE2 cryptography that's impractical to re-implement.
public actor ADBWirelessClient {
  public enum WirelessError: Error, Sendable, Equatable {
    case missingMDNS              // no _adb-tls-* services on this network
    case pairingTimeout           // device didn't respond to the code
    case pairingInvalidCode       // wrong 6-digit code
    case pairingSwitchFailed      // device rejected the pairing
    case connectUnverified        // device known but key not trusted
    case addressInvalid(String)   // malformed ip:port
    case adbMissing               // bundled adb not found
    case adb(stderr: String)      // anything else from adb
  }

  private let adbBinary: URL

  public init(adbBinary: URL) {
    self.adbBinary = adbBinary
  }

  /// `adb pair <host>:<port> <6-digit-code>`.
  /// Returns when adb reports success; throws WirelessError otherwise.
  public func pair(host: String, port: Int, code: String) async throws {
    try validate(host: host, port: port)
    guard code.count == 6, code.allSatisfy(\.isNumber) else {
      throw WirelessError.pairingInvalidCode
    }
    print("[wireless] adb pair \(host):\(port) <code>")
    let result = try await runAdb(["pair", "\(host):\(port)", code], timeout: 20)
    print("[wireless] pair exit=\(result.status) stdout=\(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) stderr=\(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
    if result.status != 0 || result.stdout.lowercased().contains("failed") {
      throw classifyPairing(stdout: result.stdout, stderr: result.stderr)
    }
  }

  /// `adb connect <host>:<port>`.
  public func connect(host: String, port: Int) async throws {
    try validate(host: host, port: port)
    print("[wireless] adb connect \(host):\(port)")
    let result = try await runAdb(["connect", "\(host):\(port)"], timeout: 10)
    print("[wireless] connect exit=\(result.status) stdout=\(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) stderr=\(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
    let combined = (result.stdout + result.stderr).lowercased()
    if combined.contains("failed") || combined.contains("cannot") {
      throw classifyConnect(text: combined)
    }
  }

  /// `adb disconnect <host>:<port>`. Best-effort.
  public func disconnect(host: String, port: Int) async throws {
    try validate(host: host, port: port)
    _ = try await runAdb(["disconnect", "\(host):\(port)"], timeout: 5)
  }

  // MARK: helpers

  private func validate(host: String, port: Int) throws {
    guard !host.isEmpty else { throw WirelessError.addressInvalid("host empty") }
    guard (1...65_535).contains(port) else { throw WirelessError.addressInvalid("port \(port) out of range") }
  }

  private struct AdbResult {
    let status: Int32
    let stdout: String
    let stderr: String
  }

  private func runAdb(_ args: [String], timeout: TimeInterval) async throws -> AdbResult {
    guard FileManager.default.fileExists(atPath: adbBinary.path) else {
      throw WirelessError.adbMissing
    }
    let process = Process()
    process.executableURL = adbBinary
    process.arguments = args
    let outPipe = Pipe()
    let errPipe = Pipe()
    process.standardOutput = outPipe
    process.standardError = errPipe

    try process.run()

    // Kill the process if it overruns; pairing in particular can hang waiting on user input.
    let killer = Task { @Sendable in
      try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
      if process.isRunning { process.terminate() }
    }

    return try await withCheckedThrowingContinuation { cont in
      DispatchQueue.global(qos: .userInitiated).async {
        process.waitUntilExit()
        killer.cancel()
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        cont.resume(returning: AdbResult(
          status: process.terminationStatus,
          stdout: String(data: outData, encoding: .utf8) ?? "",
          stderr: String(data: errData, encoding: .utf8) ?? ""
        ))
      }
    }
  }

  private func classifyPairing(stdout: String, stderr: String) -> WirelessError {
    let text = (stdout + stderr).lowercased()
    if text.contains("connection refused") || text.contains("timeout") || text.contains("timed out") {
      return .pairingTimeout
    }
    if text.contains("wrong password") || text.contains("invalid") {
      return .pairingInvalidCode
    }
    if text.contains("not found") || text.contains("cannot resolve") {
      return .missingMDNS
    }
    return .pairingSwitchFailed
  }

  private func classifyConnect(text: String) -> WirelessError {
    if text.contains("missing port") || text.contains("malformed") {
      return .addressInvalid(text)
    }
    if text.contains("not authorized") || text.contains("unverified") || text.contains("not trusted") {
      return .connectUnverified
    }
    if text.contains("connection refused") || text.contains("no route") || text.contains("timeout") {
      return .pairingTimeout
    }
    return .adb(stderr: text)
  }
}
