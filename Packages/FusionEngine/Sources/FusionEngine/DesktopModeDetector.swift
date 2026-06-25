import Foundation
import ADBKit
import SharedModels

public enum DesktopMode: Sendable, Equatable {
  case samsungDeX
  case androidFreeform
  case unsupported
}

/// Decides which "fusion" path to take per device.
/// Priority: Samsung DeX → Android 14+ freeform → unsupported (fallback to plain mirror).
public actor DesktopModeDetector {
  private let adb: ADBClient

  public init(adb: ADBClient) {
    self.adb = adb
  }

  public func detect(_ device: Device) async throws -> DesktopMode {
    if device.isSamsung {
      // M4: verify DeX availability via `pm list packages com.sec.android.desktopmode`
      return .samsungDeX
    }
    if device.supportsFreeform {
      return .androidFreeform
    }
    return .unsupported
  }
}

public actor FusionActivator {
  private let adb: ADBClient

  public init(adb: ADBClient) {
    self.adb = adb
  }

  public func activateDeX(serial: String) async throws {
    throw DroidMirroringError.unimplemented("FusionActivator.activateDeX — M4 sends DeX intent, waits for secondary display")
  }

  public func activateFreeform(serial: String) async throws {
    // M4 implementation outline:
    //   adb shell settings put global enable_freeform_support 1
    //   adb shell settings put global force_resizable_activities 1
    //   adb shell settings put global force_desktop_mode_on 1
    throw DroidMirroringError.unimplemented("FusionActivator.activateFreeform — M4")
  }

  public func deactivate(serial: String) async throws {
    throw DroidMirroringError.unimplemented("FusionActivator.deactivate — M4 restores original settings")
  }
}
