import Foundation
import ADBKit
import ScrcpyClient
import MirrorEngine
import SharedModels
import CoreVideo
import CoreMedia

public struct FusionSession: Sendable {
  public let packageName: String
  public let virtualDisplayId: Int
  public let mirrorSession: MirrorSession

  public init(packageName: String, virtualDisplayId: Int, mirrorSession: MirrorSession) {
    self.packageName = packageName
    self.virtualDisplayId = virtualDisplayId
    self.mirrorSession = mirrorSession
  }
}

/// Launches a single Android app into its own scrcpy virtual display.
///
/// Implementation note — display-id sniffing: the launcher currently drains
/// scrcpy stdout into stdout with no way for a third party to hook the stream,
/// so we don't try to parse "Virtual display ID: <N>" from there. Instead we
/// snapshot `dumpsys display` virtual-display ids before/after the scrcpy
/// session starts and take the difference. The set diff is robust against
/// OEM-specific dumpsys format variations because we only need numeric ids.
public actor FusionLauncher {
  private let adb: ADBClient
  private let scrcpyResources: ScrcpyServerLauncher.Resources

  public init(adb: ADBClient, scrcpyResources: ScrcpyServerLauncher.Resources) {
    self.adb = adb
    self.scrcpyResources = scrcpyResources
  }

  /// Open a landscape virtual display and stream it to `frameSink`. Does NOT
  /// force-launch any particular app — the device's own home/launcher (Samsung
  /// DeX launcher, Pixel taskbar, AOSP system UI) takes over the display. Use
  /// this for "Desktop Mode" where the user wants a full Android desktop.
  public func openDesktop(
    serial: String,
    size: CGSize,
    dpi: Int,
    frameSink: @escaping MirrorSession.FrameSink
  ) async throws -> FusionSession {
    try await launchVirtualDisplay(
      packageName: nil,
      serial: serial,
      size: size,
      dpi: dpi,
      frameSink: frameSink
    )
  }

  /// Open a virtual display AND force-launch `packageName` on it. Used by
  /// (future) Fusion Mode where each Android app should land in its own
  /// Mac window. OEM launchers (Samsung DeX, Pixel desktop) may still claim
  /// the display first — we don't yet suppress them.
  public func launch(
    packageName: String,
    serial: String,
    size: CGSize,
    dpi: Int,
    frameSink: @escaping MirrorSession.FrameSink
  ) async throws -> FusionSession {
    try await launchVirtualDisplay(
      packageName: packageName,
      serial: serial,
      size: size,
      dpi: dpi,
      frameSink: frameSink
    )
  }

  // MARK: shared path

  private func launchVirtualDisplay(
    packageName: String?,
    serial: String,
    size: CGSize,
    dpi: Int,
    frameSink: @escaping MirrorSession.FrameSink
  ) async throws -> FusionSession {
    let beforeIds = try await virtualDisplayIds(serial: serial)

    let w = Int(size.width.rounded())
    let h = Int(size.height.rounded())
    let options = ScrcpyOptions(
      videoCodec: "h264",
      audioEnabled: false,
      controlEnabled: true,
      newDisplay: "\(w)x\(h)/\(dpi)"
    )

    let launcher = ScrcpyServerLauncher(adb: adb, serial: serial, resources: scrcpyResources)
    let session = MirrorSession(frameSink: frameSink)
    try await session.start(launcher: launcher, options: options)

    let displayId = try await resolveNewDisplayId(serial: serial, before: beforeIds)
    if let packageName {
      try await startApp(serial: serial, packageName: packageName, displayId: displayId)
    }

    return FusionSession(
      packageName: packageName ?? "desktop",
      virtualDisplayId: displayId,
      mirrorSession: session
    )
  }

  // MARK: display-id discovery

  /// Snapshot every display id currently known to WindowManager. We diff before
  /// vs after `scrcpy --new-display` to discover the freshly created id; built-in
  /// panels appear in both sets and cancel out.
  ///
  /// Uses `dumpsys window` (≈5 KB, atomic) instead of `dumpsys display` (≈400 KB,
  /// trips the adb shell stream's POSIX 96 ENOMSG short-read fairly often).
  /// Format: `  Display{#<id> state=<S> size=<W>x<H> ROTATION_<N>}:`
  private func virtualDisplayIds(serial: String) async throws -> Set<Int> {
    let raw = try await adb.shell("dumpsys window", serial: serial)
    var ids: Set<Int> = []
    for line in raw.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
      let s = String(line)
      guard let range = s.range(of: "Display{#") else { continue }
      let tail = s[range.upperBound...]
      let digits = tail.prefix(while: { $0.isNumber })
      if let id = Int(digits) { ids.insert(id) }
    }
    return ids
  }

  private func resolveNewDisplayId(serial: String, before: Set<Int>) async throws -> Int {
    // scrcpy creates the virtual display asynchronously; give it a few tries.
    for _ in 0..<10 {
      try? await Task.sleep(nanoseconds: 300_000_000)
      let after = try await virtualDisplayIds(serial: serial)
      let added = after.subtracting(before)
      if let id = added.max() {
        return id
      }
    }
    throw DroidMirroringError.scrcpyProtocol("FusionLauncher: could not detect new virtual display id from dumpsys")
  }

  private func extractInt(_ line: String, after prefix: String) -> Int? {
    guard let range = line.range(of: prefix) else { return nil }
    let tail = line[range.upperBound...]
    var digits = ""
    for ch in tail {
      if ch.isNumber {
        digits.append(ch)
      } else {
        break
      }
    }
    return Int(digits)
  }

  // MARK: app start

  /// Push the target app's launcher activity onto the virtual display.
  ///
  /// On Android 14+ (especially Samsung's Z Fold/Z Flip) `monkey --display` is
  /// unreliable — it often ignores the flag and re-launches on display 0. The
  /// supported path is `am start -W --display <id> -n <component>`, but we
  /// need to know the component first. So:
  ///   1. `cmd package resolve-activity --brief <pkg>` → "<pkg>/<activity>"
  ///   2. `am start -W --display <id> -n <component>`
  ///   3. Fallback to monkey for ancient devices.
  private func startApp(serial: String, packageName: String, displayId: Int) async throws {
    if let component = try? await resolveLauncherActivity(serial: serial, packageName: packageName) {
      // --activity-clear-task + --activity-new-task force the requested app to
      // claim the task stack root on the target display, instead of stacking on
      // top of whatever the OEM launcher (Samsung One UI desktop, Pixel
      // taskbar, ...) might have already opened there.
      let cmd = """
      am start -W --display \(displayId) \
      --activity-clear-task --activity-new-task \
      -n \(component)
      """
      let out = try await adb.shell(cmd, serial: serial)
      // `am start` returns nonzero in stdout text like "Error type 3" rather than
      // a process exit code over the ADB shell; sanity-check the output.
      if !out.contains("Error") && !out.contains("Exception") {
        return
      }
    }
    let cmd = "monkey --pct-syskeys 0 -p \(packageName) --display \(displayId) 1"
    _ = try await adb.shell(cmd, serial: serial)
  }

  private func resolveLauncherActivity(serial: String, packageName: String) async throws -> String? {
    let raw = try await adb.shell(
      "cmd package resolve-activity --brief \(packageName)",
      serial: serial
    )
    // Output is two lines: first the package summary, second the component.
    for line in raw.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
      let s = line.trimmingCharacters(in: .whitespaces)
      if s.hasPrefix("\(packageName)/") {
        return s
      }
    }
    return nil
  }
}
