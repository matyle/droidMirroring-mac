import Foundation
import os

public enum AppGroup {
  public static let identifier = "group.com.droidmirroring.app.shared"

  public static var containerURL: URL? {
    FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
  }
}

/// Shared logger for the entire app and its packages.
/// Use in Console.app with subsystem `com.droidmirroring.app` or:
/// `log show --predicate 'subsystem=="com.droidmirroring.app"' --last 10m`
public let dmLogger = Logger(subsystem: "com.droidmirroring.app", category: "app")

public enum DroidMirroringError: Error, Sendable {
  case unimplemented(String)
  case deviceNotFound(String)
  case adbProtocol(String)
  case scrcpyProtocol(String)
  case decoder(String)
  case fileTransfer(String)
}

extension DroidMirroringError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case .unimplemented(let msg): return "Unimplemented: \(msg)"
    case .deviceNotFound(let msg): return "Device not found: \(msg)"
    case .adbProtocol(let msg): return "ADB protocol error: \(msg)"
    case .scrcpyProtocol(let msg): return "Scrcpy protocol error: \(msg)"
    case .decoder(let msg): return "Decoder error: \(msg)"
    case .fileTransfer(let msg): return "File transfer error: \(msg)"
    }
  }
}
