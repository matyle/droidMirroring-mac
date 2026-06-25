import Foundation
import FileProvider

/// Stable identifiers shared between the main App and FileProviderExt.
public enum FileProviderConfig {
  /// One Finder sidebar entry per Android device.
  /// `domainIdentifier` == device serial, prefixed so we can tell ours apart in
  /// `NSFileProviderManager.getDomainsWithCompletionHandler`.
  public static let domainPrefix = "com.droidmirroring.app.device."

  public static func domainIdentifier(forSerial serial: String) -> NSFileProviderDomainIdentifier {
    NSFileProviderDomainIdentifier(rawValue: "\(domainPrefix)\(serial)")
  }

  public static func serial(fromDomain id: NSFileProviderDomainIdentifier) -> String? {
    let raw = id.rawValue
    guard raw.hasPrefix(domainPrefix) else { return nil }
    return String(raw.dropFirst(domainPrefix.count))
  }

  /// Filenames the macOS shell scatters everywhere — we filter them in createItem
  /// so they never reach the Android side.
  public static let filteredFilenames: Set<String> = [
    ".DS_Store",
    ".Spotlight-V100",
    ".Trashes",
    ".fseventsd",
    ".TemporaryItems",
    ".DocumentRevisions-V100",
    ".apdisk",
  ]

  public static func shouldFilter(filename: String) -> Bool {
    if filteredFilenames.contains(filename) { return true }
    if filename.hasPrefix("._") { return true }     // AppleDouble companion files
    return false
  }
}

/// The three "root" folders we expose for each device. Mirrors AndroMeld's layout.
public enum DeviceRoot: String, CaseIterable, Sendable, Codable {
  case storage  = "storage"   // /sdcard — main user storage
  case sdCard   = "sdcard"    // /storage/<UUID> — physical SD card (only if present)
  case apps     = "apps"      // synthetic — installed-app APK list

  public var displayName: String {
    switch self {
    case .storage: return "Internal Storage"
    case .sdCard:  return "SD Card"
    case .apps:    return "Apps"
    }
  }

  public var remoteAnchor: String {
    switch self {
    case .storage: return "/sdcard"
    case .sdCard:  return "/storage"
    case .apps:    return "(virtual)"
    }
  }
}
