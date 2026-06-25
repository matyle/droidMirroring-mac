import Foundation
import ADBKit
import SharedModels

public struct InstalledApp: Sendable, Hashable, Identifiable {
  public let packageName: String
  public let label: String
  public let iconPNG: Data?

  public var id: String { packageName }

  public init(packageName: String, label: String, iconPNG: Data? = nil) {
    self.packageName = packageName
    self.label = label
    self.iconPNG = iconPNG
  }
}

/// Lists third-party apps installed on the device. Label fetch is best-effort:
/// `dumpsys` output varies wildly across OEMs, so we fall back to the package
/// name when we can't find anything reliable.
public actor AppCatalog {
  private let adb: ADBClient

  public init(adb: ADBClient) {
    self.adb = adb
  }

  /// Fast path: one shell call for the full list, no per-package metadata.
  /// We previously called `dumpsys package <pkg>` per app to fetch the human
  /// label — but on Android 16 / Samsung that's ~300 ms per call and produces
  /// 100 KB of output, which both takes 30+ seconds AND occasionally trips the
  /// adb stream's `ENOMSG` short-read. Showing the package name only is the
  /// right default; we'll add a background label fetcher once that's fast.
  public func listInstalled(serial: String) async throws -> [InstalledApp] {
    let raw = try await adb.shell("pm list packages -3", serial: serial)
    return raw
      .split(whereSeparator: { $0 == "\n" || $0 == "\r" })
      .compactMap { line -> String? in
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("package:") else { return nil }
        return String(trimmed.dropFirst("package:".count))
      }
      .sorted()
      .map { InstalledApp(packageName: $0, label: Self.prettify($0), iconPNG: nil) }
  }

  /// Best-effort label fallback from a package name: take the last segment and
  /// title-case it. `com.android.chrome` → `Chrome`.
  static func prettify(_ packageName: String) -> String {
    let parts = packageName.split(separator: ".")
    guard let last = parts.last else { return packageName }
    let s = String(last)
    return s.prefix(1).uppercased() + s.dropFirst()
  }
}
