import Foundation
import ADBKit
import SharedModels

/// Toggles Android 14+ system-wide freeform settings on the device so that any
/// `am start --display <virtualId>` lands in a resizable freeform task.
///
/// We snapshot the original values before mutating so deactivate() can put the
/// device back exactly how we found it — important on user-owned hardware.
public actor FreeformActivator {
  /// Settings we touch. Order matters only for readability; activation is idempotent.
  private static let managedKeys: [String] = [
    "enable_freeform_support",
    "force_resizable_activities",
    "enable_taskbar",
  ]

  private let adb: ADBClient

  public init(adb: ADBClient) {
    self.adb = adb
  }

  public func activate(serial: String) async throws -> ActivationToken {
    let sdk = try await readSDK(serial: serial)
    guard sdk >= 34 else {
      throw DroidMirroringError.unimplemented("FreeformActivator requires Android 14+ (SDK 34); device reports SDK \(sdk)")
    }

    var snapshot: [String: String] = [:]
    for key in Self.managedKeys {
      snapshot[key] = try await readGlobal(serial: serial, key: key)
    }
    for key in Self.managedKeys {
      try await writeGlobal(serial: serial, key: key, value: "1")
    }
    return ActivationToken(serial: serial, restoreSnapshot: snapshot)
  }

  public func deactivate(_ token: ActivationToken) async {
    for key in Self.managedKeys {
      let original = token.restoreSnapshot[key] ?? "null"
      // "null" means the setting was previously unset — `settings delete` restores that.
      if original == "null" || original.isEmpty {
        _ = try? await adb.shell("settings delete global \(key)", serial: token.serial)
      } else {
        _ = try? await adb.shell("settings put global \(key) \(original)", serial: token.serial)
      }
    }
  }

  // MARK: helpers

  private func readSDK(serial: String) async throws -> Int {
    let out = try await adb.shell("getprop ro.build.version.sdk", serial: serial)
    return Int(out.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
  }

  private func readGlobal(serial: String, key: String) async throws -> String {
    let raw = try await adb.shell("settings get global \(key)", serial: serial)
    return raw.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func writeGlobal(serial: String, key: String, value: String) async throws {
    _ = try await adb.shell("settings put global \(key) \(value)", serial: serial)
  }
}

public struct ActivationToken: Sendable {
  public let serial: String
  public let restoreSnapshot: [String: String]

  public init(serial: String, restoreSnapshot: [String: String]) {
    self.serial = serial
    self.restoreSnapshot = restoreSnapshot
  }
}
