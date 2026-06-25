import Foundation
import SharedModels

/// One Android logical display as reported by `dumpsys SurfaceFlinger --display-id`
/// + `cmd display get-displays`. Only the bits we need for picking the active panel.
public struct DisplayInfo: Sendable, Equatable {
  public enum State: String, Sendable {
    case on = "ON"
    case doze = "DOZE"
    case dozeSuspend = "DOZE_SUSPEND"
    case onSuspend = "ON_SUSPEND"
    case off = "OFF"
    case unknown = "UNKNOWN"

    public var isActive: Bool { self != .off && self != .unknown }

    /// Higher = more "user is here right now". Used by pickActiveDisplay to break ties
    /// on foldable devices when both panels are momentarily live during a transition.
    public var rank: Int {
      switch self {
      case .on:           return 100
      case .onSuspend:    return 80
      case .doze:         return 50
      case .dozeSuspend:  return 30
      case .off, .unknown: return 0
      }
    }
  }

  public let id: Int           // logical display id (what scrcpy --display-id expects)
  public let width: Int        // physical pixels
  public let height: Int       // physical pixels
  public let state: State
  public let isInternal: Bool
  /// Current device rotation, in 90° steps (0=natural, 1=90 CW, 2=180, 3=270).
  /// scrcpy locks its encoder canvas to the orientation at launch time, so we
  /// relaunch when this changes.
  public let rotation: Int

  public var area: Int { width * height }

  public init(id: Int, width: Int, height: Int, state: State, isInternal: Bool, rotation: Int = 0) {
    self.id = id
    self.width = width
    self.height = height
    self.state = state
    self.isInternal = isInternal
    self.rotation = rotation
  }
}

public extension ADBClient {
  /// Enumerate physical/built-in displays on the device. Skips virtual displays
  /// (scrcpy's own VirtualDisplay shows up here too — we filter them out).
  ///
  /// Uses `dumpsys window` rather than `dumpsys display` because:
  ///   1. ~5 KB vs ~400 KB — far less prone to shell-stream truncation.
  ///   2. Each line atomically carries id + current size + current rotation:
  ///        `  Display{#0 state=ON size=2520x1080 ROTATION_90}:`
  ///      which sidesteps the device-vs-logical bridging mess in dumpsys display.
  func physicalDisplays(serial: String) async throws -> [DisplayInfo] {
    let raw = try await shell("dumpsys window", serial: serial)
    return DisplayInfoParser.parseWindowDump(raw)
  }

  /// Pick the best display to mirror.
  ///
  /// Foldables briefly have BOTH panels active during the unfold animation, so a naive
  /// "largest active" picker bounces. Use a strict state ranking instead:
  ///   ON  >  ON_SUSPEND  >  DOZE  >  DOZE_SUSPEND  >  OFF/UNKNOWN
  /// Ties within the same state break by area (largest first) — that gives us the
  /// inner panel on unfold and the cover on fold.
  func pickActiveDisplay(serial: String) async throws -> DisplayInfo? {
    let displays = try await physicalDisplays(serial: serial)
    if displays.isEmpty { return nil }
    let ranked = displays.sorted { a, b in
      if a.state.rank != b.state.rank { return a.state.rank > b.state.rank }
      return a.area > b.area
    }
    return ranked.first
  }
}

/// Parser kept separate for testability. `dumpsys display` has shifted shape
/// across Android versions; this version targets Android 14-16 specifically.
///
/// Android 16 layout (the one that broke our previous parser):
///
///   Display Devices: size=N
///     DisplayDeviceInfo{"...": uniqueId="local:1234", W x H, ..., state ON, ..., type INTERNAL, ...}
///     DisplayDeviceInfo{"...": uniqueId="local:5678", W x H, ..., state OFF, ..., type INTERNAL, ...}
///     DisplayDeviceInfo{"scrcpy": uniqueId="virtual:...", ..., type VIRTUAL, ...}
///
///   Logical Displays: size=N
///     Display 0:
///       mDisplayId=0
///       mPrimaryDisplayDevice=Built-in Screen(local:5678)
///       mBaseDisplayInfo=DisplayInfo{..., real 1080 x 2520, ...}
///
/// State lives on `DisplayDeviceInfo`, dims+logical-id on `LogicalDisplay`. We
/// bridge them via the device's `uniqueId`.
enum DisplayInfoParser {
  private struct DeviceState {
    let width: Int
    let height: Int
    let state: DisplayInfo.State
    let isInternal: Bool
    let isVirtual: Bool
    let rotation: Int
  }

  static func parse(_ dump: String) -> [DisplayInfo] {
    let lines = dump.components(separatedBy: "\n")
    let states = scanDeviceStates(lines)
    return scanLogicalDisplays(lines, states: states)
  }

  /// Compact parser for `dumpsys window`. Looks for lines of the form:
  ///   `  Display{#<id> state=<STATE> size=<W>x<H> ROTATION_<N>}:`
  /// Filters out virtual scrcpy displays (high ids — usually >= 50 — and they
  /// always have state=DOZE since adb-spawned virtual displays don't fully wake).
  /// The size already accounts for current rotation, but we keep `rotation`
  /// separately so we can detect rotation events even at constant aspect.
  static func parseWindowDump(_ dump: String) -> [DisplayInfo] {
    let lines = dump.components(separatedBy: "\n")
    var results: [DisplayInfo] = []
    var seenIds = Set<Int>()

    // Pattern: Display{#<id> state=<S> size=<W>x<H> ROTATION_<N>}
    let pattern = #"Display\{#(\d+)\s+state=([A-Z_]+)\s+size=(\d+)x(\d+)\s+ROTATION_(\d+)\}"#
    guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }

    for line in lines {
      let ns = line as NSString
      let range = NSRange(location: 0, length: ns.length)
      guard let m = re.firstMatch(in: line, range: range), m.numberOfRanges == 6 else { continue }
      guard let id = Int(ns.substring(with: m.range(at: 1))),
            let w = Int(ns.substring(with: m.range(at: 3))),
            let h = Int(ns.substring(with: m.range(at: 4))),
            let rot = Int(ns.substring(with: m.range(at: 5))),
            !seenIds.contains(id)
      else { continue }
      let stateStr = ns.substring(with: m.range(at: 2))
      let state = DisplayInfo.State(rawValue: stateStr) ?? .unknown

      // scrcpy's virtual display has a large dynamic id (50+, 56, etc). The
      // built-in panels on Samsung Z Fold are always 0 and 1.
      if id >= 50 { continue }
      results.append(DisplayInfo(
        id: id, width: w, height: h,
        state: state, isInternal: true, rotation: rot / 90
      ))
      seenIds.insert(id)
    }
    return results.sorted { $0.id < $1.id }
  }

  /// Pass 1: collect (uniqueId → state) from every `DisplayDeviceInfo{...}` line.
  /// These appear up top in the "Display Devices" section, before any logical
  /// display block.
  private static func scanDeviceStates(_ lines: [String]) -> [String: DeviceState] {
    var map: [String: DeviceState] = [:]
    for line in lines {
      guard line.contains("DisplayDeviceInfo{"),
            let uid = extractUniqueId(line),
            let (w, h) = extractSize(line),
            let state = extractState(line)
      else { continue }
      let isVirtual = line.contains("type VIRTUAL")
      let isInternal = line.contains("type INTERNAL")
      let rotation = extractRotation(line)
      map[uid] = DeviceState(width: w, height: h, state: state, isInternal: isInternal, isVirtual: isVirtual, rotation: rotation)
    }
    return map
  }

  /// `rotation N` token within a DisplayDeviceInfo line. Defaults to 0 if not
  /// found. Bounded to [0, 3].
  private static func extractRotation(_ line: String) -> Int {
    guard let range = line.range(of: "rotation ") else { return 0 }
    let tail = line[range.upperBound...]
    let digits = tail.prefix(while: { $0.isNumber })
    guard let n = Int(digits) else { return 0 }
    return max(0, min(3, n))
  }

  /// Pass 2: walk LogicalDisplay blocks. For each `mDisplayId=N` followed by
  /// `mPrimaryDisplayDevice=...(uid)`, attach the device state we captured.
  /// Falls back to `mBaseDisplayInfo`'s `real W x H` for dims if needed.
  private static func scanLogicalDisplays(_ lines: [String], states: [String: DeviceState]) -> [DisplayInfo] {
    var results: [DisplayInfo] = []
    var seenIds = Set<Int>()
    var pendingId: Int?

    for line in lines {
      if let id = extractStrictDisplayId(line) {
        pendingId = id
        continue
      }
      guard line.contains("mPrimaryDisplayDevice=") else { continue }
      guard let logicalId = pendingId,
            !seenIds.contains(logicalId),
            let uid = extractParenthesizedId(line),
            let device = states[uid]
      else { continue }
      if device.isVirtual { continue }
      results.append(DisplayInfo(
        id: logicalId,
        width: device.width,
        height: device.height,
        state: device.state,
        isInternal: device.isInternal,
        rotation: device.rotation
      ))
      seenIds.insert(logicalId)
    }
    return results
  }

  /// Match `mDisplayId=N` only when the character right after `=` is a digit.
  /// dumpsys prints variants like `mDisplayId=: 0` and `mDisplayId= 0` deeper
  /// in its output that we want to ignore.
  private static func extractStrictDisplayId(_ line: String) -> Int? {
    guard let range = line.range(of: "mDisplayId=") else { return nil }
    let tail = line[range.upperBound...]
    guard let first = tail.first, first.isNumber else { return nil }
    let digits = tail.prefix(while: { $0.isNumber })
    return Int(digits)
  }

  /// `uniqueId="local:4630946872173396372"` → `"local:4630946872173396372"`.
  private static func extractUniqueId(_ line: String) -> String? {
    guard let range = line.range(of: "uniqueId=\"") else { return nil }
    let tail = line[range.upperBound...]
    guard let end = tail.firstIndex(of: "\"") else { return nil }
    return String(tail[..<end])
  }

  /// `mPrimaryDisplayDevice=Built-in Screen(local:4630946872173396372)` → the
  /// parenthesised id. Tolerates any token before the opening paren.
  private static func extractParenthesizedId(_ line: String) -> String? {
    guard let open = line.lastIndex(of: "(") else { return nil }
    let after = line.index(after: open)
    guard let close = line[after...].firstIndex(of: ")") else { return nil }
    return String(line[after..<close])
  }

  private static func extractInt(_ line: String, prefix: String) -> Int? {
    guard let range = line.range(of: prefix) else { return nil }
    let tail = line[range.upperBound...]
    let digits = tail.prefix(while: { $0.isNumber })
    return Int(digits)
  }

  private static func extractSize(_ line: String) -> (Int, Int)? {
    // Match "<w> x <h>" — first occurrence after the opening brace.
    // e.g. ' 1968 x 2184, '
    let pattern = #"(\d+)\s*x\s*(\d+)"#
    guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
    let ns = line as NSString
    guard let m = re.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)),
          m.numberOfRanges == 3,
          let w = Int(ns.substring(with: m.range(at: 1))),
          let h = Int(ns.substring(with: m.range(at: 2)))
    else { return nil }
    return (w, h)
  }

  private static func extractState(_ line: String) -> DisplayInfo.State? {
    // ' state ON,' or ' state DOZE,' etc. Capture the token after ' state '.
    guard let range = line.range(of: " state ") else { return nil }
    let tail = line[range.upperBound...]
    let token = tail.prefix(while: { $0.isLetter || $0 == "_" })
    return DisplayInfo.State(rawValue: String(token))
  }
}
