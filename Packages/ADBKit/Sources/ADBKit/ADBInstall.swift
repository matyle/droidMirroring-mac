import Foundation
import SharedModels

/// Installs `.apk` / `.xapk` files via the bundled `adb` binary.
///
/// We shell out instead of speaking the wire protocol directly: `adb install`
/// internally uses `cmd package install` over a shell with file streaming
/// semantics that are non-trivial to re-implement.
public actor ADBInstaller {
  public enum InstallError: Error, Sendable, Equatable {
    case adbMissing
    case unsupportedFileType(String)
    case alreadyInstalled
    case versionDowngrade
    case incompatible(String)
    case adbStderr(String)
  }

  /// Result of parsing adb install output.
  enum ParseOutcome: Equatable {
    case success(packageName: String?)
    case failure(InstallError)
  }

  private let adbBinary: URL

  public init(adbBinary: URL) {
    self.adbBinary = adbBinary
  }

  /// Installs an `.apk` or `.xapk`. For `.xapk`, the archive is extracted to a
  /// temp dir and `adb install-multiple` is invoked over the included `.apk`s.
  /// Returns the parsed package name when adb reports one, otherwise `nil`.
  public func install(localURL: URL, serial: String, replace: Bool = true) async throws -> String? {
    guard FileManager.default.fileExists(atPath: adbBinary.path) else {
      throw InstallError.adbMissing
    }
    let ext = localURL.pathExtension.lowercased()
    switch ext {
    case "apk":
      return try await installApk(localURL: localURL, serial: serial, replace: replace)
    case "xapk":
      return try await installXapk(localURL: localURL, serial: serial, replace: replace)
    default:
      throw InstallError.unsupportedFileType(ext)
    }
  }

  // MARK: single-apk

  private func installApk(localURL: URL, serial: String, replace: Bool) async throws -> String? {
    var args: [String] = ["-s", serial, "install"]
    if replace { args.append("-r") }
    args.append(localURL.path)
    let result = try await runAdb(args, timeout: 300)
    return try handle(result: result)
  }

  // MARK: xapk

  private func installXapk(localURL: URL, serial: String, replace: Bool) async throws -> String? {
    let tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("droidmirroring-xapk-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    try await unzip(archive: localURL, into: tempDir)

    let apks = try findApks(in: tempDir)
    guard !apks.isEmpty else {
      throw InstallError.unsupportedFileType("xapk-no-apks")
    }

    var args: [String] = ["-s", serial, "install-multiple"]
    if replace { args.append("-r") }
    args.append(contentsOf: apks.map(\.path))
    let result = try await runAdb(args, timeout: 300)
    return try handle(result: result)
  }

  private func unzip(archive: URL, into directory: URL) async throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
    process.arguments = ["-o", "-q", archive.path, "-d", directory.path]
    let errPipe = Pipe()
    process.standardError = errPipe
    process.standardOutput = Pipe()
    try process.run()
    await withCheckedContinuation { cont in
      DispatchQueue.global(qos: .userInitiated).async {
        process.waitUntilExit()
        cont.resume()
      }
    }
    if process.terminationStatus != 0 {
      let stderr = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
      throw InstallError.adbStderr("unzip failed: \(stderr)")
    }
  }

  private func findApks(in directory: URL) throws -> [URL] {
    guard let enumerator = FileManager.default.enumerator(
      at: directory, includingPropertiesForKeys: [.isRegularFileKey])
    else { return [] }
    var apks: [URL] = []
    for case let url as URL in enumerator
    where url.pathExtension.lowercased() == "apk" {
      apks.append(url)
    }
    // Put `base.apk` first so adb sees it as the primary split.
    apks.sort { lhs, rhs in
      let lhsBase = lhs.lastPathComponent.lowercased() == "base.apk"
      let rhsBase = rhs.lastPathComponent.lowercased() == "base.apk"
      if lhsBase != rhsBase { return lhsBase }
      return lhs.lastPathComponent < rhs.lastPathComponent
    }
    return apks
  }

  // MARK: result handling

  private func handle(result: AdbResult) throws -> String? {
    switch ADBInstaller.parseInstallOutput(result.stdout + "\n" + result.stderr) {
    case .success(let pkg):
      return pkg
    case .failure(let err):
      throw err
    }
  }

  /// Pure parser for adb install output. Exposed for tests.
  static func parseInstallOutput(_ raw: String) -> ParseOutcome {
    let text = raw
    let lower = text.lowercased()

    // `adb install` prints "Success" on its own line on the happy path.
    if lower.range(of: "\nsuccess") != nil
        || lower.hasPrefix("success")
        || lower.contains("\nsuccess\n")
        || lower.trimmingCharacters(in: .whitespacesAndNewlines) == "success" {
      // Try `pkg:` prefix that some adb versions emit.
      if let pkgRange = text.range(of: "pkg:", options: .caseInsensitive) {
        let after = text[pkgRange.upperBound...]
        let pkg = after.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).first
        return .success(packageName: pkg.map(String.init))
      }
      return .success(packageName: nil)
    }

    if lower.contains("install_failed_version_downgrade") {
      return .failure(.versionDowngrade)
    }
    if lower.contains("install_failed_already_exists") {
      return .failure(.alreadyInstalled)
    }
    if let range = lower.range(of: "install_failed_") {
      let code = lower[range.lowerBound...]
        .prefix(while: { $0.isLetter || $0.isNumber || $0 == "_" })
      return .failure(.incompatible(String(code).uppercased()))
    }
    if lower.contains("failure") || lower.contains("error") || lower.contains("failed") {
      return .failure(.adbStderr(text.trimmingCharacters(in: .whitespacesAndNewlines)))
    }
    return .failure(.adbStderr(text.trimmingCharacters(in: .whitespacesAndNewlines)))
  }

  // MARK: process spawning

  private struct AdbResult {
    let status: Int32
    let stdout: String
    let stderr: String
  }

  private func runAdb(_ args: [String], timeout: TimeInterval) async throws -> AdbResult {
    let process = Process()
    process.executableURL = adbBinary
    process.arguments = args
    let outPipe = Pipe()
    let errPipe = Pipe()
    process.standardOutput = outPipe
    process.standardError = errPipe

    try process.run()

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
}
