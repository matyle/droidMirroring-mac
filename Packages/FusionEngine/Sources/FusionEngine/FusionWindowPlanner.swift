import Foundation
import ScrcpyClient
import SharedModels

/// Plans macOS NSWindow layout for fusion-mode Android apps.
/// Each Android freeform window maps 1:1 to a macOS window with its own scrcpy stream
/// when newDisplay is set (scrcpy 2.7+ virtual display).
public struct FusionWindowSpec: Sendable {
  public let appPackage: String
  public let displayId: Int
  public let frame: CGRect
  public let scrcpyOptions: ScrcpyOptions
}

public actor FusionWindowPlanner {
  public init() {}

  public func plan(for apps: [String], mode: DesktopMode) async throws -> [FusionWindowSpec] {
    throw DroidMirroringError.unimplemented("FusionWindowPlanner.plan — M4: per-app virtual display + frame layout")
  }
}
