import Foundation
import SharedModels

/// Wire-format messages sent FROM client TO scrcpy-server.
/// Reference: scrcpy/server/src/main/java/com/genymobile/scrcpy/ControlMessage.java
public enum ControlMessageType: UInt8, Sendable {
  case injectKeycode = 0
  case injectText = 1
  case injectTouchEvent = 2
  case injectScrollEvent = 3
  case backOrScreenOn = 4
  case expandNotificationPanel = 5
  case expandSettingsPanel = 6
  case collapsePanels = 7
  case getClipboard = 8
  case setClipboard = 9
  case setScreenPowerMode = 10
  case rotateDevice = 11
  case uhidCreate = 12
  case uhidInput = 13
  case openHardKeyboardSettings = 14
  case startApp = 15
  case resetVideo = 16
}

/// Android `KeyEvent` action codes.
public enum KeyEventAction: UInt8, Sendable {
  case down = 0
  case up = 1
}

/// Android `MotionEvent` action codes (touch).
public enum TouchAction: UInt8, Sendable {
  case down = 0
  case up = 1
  case move = 2
  case cancel = 3
  case outside = 4
  case pointerDown = 5      // (action & 0xff) — but for primary pointer, use down
  case pointerUp = 6
  case hoverMove = 7
  case scroll = 8
  case hoverEnter = 9
  case hoverExit = 10
  case buttonPress = 11
  case buttonRelease = 12
}

/// Android `MotionEvent` button bit masks.
public struct MotionButton: OptionSet, Sendable {
  public let rawValue: UInt32
  public init(rawValue: UInt32) { self.rawValue = rawValue }
  public static let primary   = MotionButton(rawValue: 1 << 0)
  public static let secondary = MotionButton(rawValue: 1 << 1)
  public static let tertiary  = MotionButton(rawValue: 1 << 2)
  public static let back      = MotionButton(rawValue: 1 << 3)
  public static let forward   = MotionButton(rawValue: 1 << 4)
}

public struct ControlMessage: Sendable {
  public let type: ControlMessageType
  public let payload: Data

  public func serialize() -> Data {
    var data = Data([type.rawValue])
    data.append(payload)
    return data
  }
}

// MARK: builders

public extension ControlMessage {
  /// Inject a touch event. Coordinates are in DEVICE pixels.
  /// `pointerId` lets the server tell fingers apart on multi-touch (0 = primary).
  static func touch(
    action: TouchAction,
    x: Int32, y: Int32,
    screenWidth: UInt16, screenHeight: UInt16,
    pressure: Double = 1.0,
    pointerId: UInt64 = 0xFFFF_FFFF_FFFF_FFFF,
    actionButton: MotionButton = .primary,
    buttons: MotionButton = []
  ) -> ControlMessage {
    var p = Data()
    p.appendByte(action.rawValue)
    p.appendBE(UInt64: pointerId)
    p.appendBE(UInt32: UInt32(bitPattern: x))
    p.appendBE(UInt32: UInt32(bitPattern: y))
    p.appendBE(UInt16: screenWidth)
    p.appendBE(UInt16: screenHeight)
    let pressureFP = UInt16(max(0, min(1, pressure)) * Double(UInt16.max))
    p.appendBE(UInt16: pressureFP)
    p.appendBE(UInt32: actionButton.rawValue)
    p.appendBE(UInt32: buttons.rawValue)
    return ControlMessage(type: .injectTouchEvent, payload: p)
  }

  /// Inject a scroll-wheel event at the given device-pixel coords.
  /// hscroll / vscroll are normalized [-1, 1] (server multiplies by a per-device factor).
  static func scroll(
    x: Int32, y: Int32,
    screenWidth: UInt16, screenHeight: UInt16,
    hscroll: Double, vscroll: Double,
    buttons: MotionButton = []
  ) -> ControlMessage {
    var p = Data()
    p.appendBE(UInt32: UInt32(bitPattern: x))
    p.appendBE(UInt32: UInt32(bitPattern: y))
    p.appendBE(UInt16: screenWidth)
    p.appendBE(UInt16: screenHeight)
    let h = Int16(max(-1, min(1, hscroll)) * Double(Int16.max))
    let v = Int16(max(-1, min(1, vscroll)) * Double(Int16.max))
    p.appendBE(Int16: h)
    p.appendBE(Int16: v)
    p.appendBE(UInt32: buttons.rawValue)
    return ControlMessage(type: .injectScrollEvent, payload: p)
  }

  /// Inject an Android keycode (see android.view.KeyEvent.KEYCODE_*).
  static func keycode(
    _ keycode: Int32,
    action: KeyEventAction,
    repeatCount: UInt32 = 0,
    metaState: UInt32 = 0
  ) -> ControlMessage {
    var p = Data()
    p.appendByte(action.rawValue)
    p.appendBE(UInt32: UInt32(bitPattern: keycode))
    p.appendBE(UInt32: repeatCount)
    p.appendBE(UInt32: metaState)
    return ControlMessage(type: .injectKeycode, payload: p)
  }

  /// Inject a UTF-8 text run (works around the Android IME for ASCII input).
  static func text(_ string: String) -> ControlMessage {
    var p = Data()
    let bytes = Data(string.utf8)
    p.appendBE(UInt32: UInt32(bytes.count))
    p.append(bytes)
    return ControlMessage(type: .injectText, payload: p)
  }

  /// BACK key when screen on, POWER when screen off.
  static func backOrScreenOn(action: KeyEventAction) -> ControlMessage {
    ControlMessage(type: .backOrScreenOn, payload: Data([action.rawValue]))
  }

  /// Ask the device to push its current clipboard back via DEVICE_CLIPBOARD.
  /// `copyKey` 0=none, 1=copy, 2=cut — triggers the IME's copy/cut action.
  static func getClipboard(copyKey: UInt8 = 0) -> ControlMessage {
    ControlMessage(type: .getClipboard, payload: Data([copyKey]))
  }

  /// Push text into the device clipboard. `paste=true` makes Android auto-paste
  /// into the focused field (handy for password fills); usually false.
  /// `sequence` is echoed back in `ackClipboard` so we know it landed.
  static func setClipboard(text: String, sequence: UInt64 = 0, paste: Bool = false) -> ControlMessage {
    var p = Data()
    p.appendBE(UInt64: sequence)
    p.appendByte(paste ? 1 : 0)
    let bytes = Data(text.utf8)
    p.appendBE(UInt32: UInt32(bytes.count))
    p.append(bytes)
    return ControlMessage(type: .setClipboard, payload: p)
  }

  /// Rotate the device screen 90° clockwise.
  static func rotateDevice() -> ControlMessage {
    ControlMessage(type: .rotateDevice, payload: Data())
  }

  /// Toggle device screen power. `mode` 0=off, 2=normal. With mode=0 you keep
  /// mirroring an actively-rendering display while the panel stays dark.
  static func setScreenPowerMode(_ mode: UInt8) -> ControlMessage {
    ControlMessage(type: .setScreenPowerMode, payload: Data([mode]))
  }
}

// MARK: big-endian helpers

private extension Data {
  mutating func appendByte(_ v: UInt8) { append(v) }

  mutating func appendBE(UInt16 v: UInt16) {
    var be = v.bigEndian
    Swift.withUnsafeBytes(of: &be) { append(contentsOf: $0) }
  }
  mutating func appendBE(UInt32 v: UInt32) {
    var be = v.bigEndian
    Swift.withUnsafeBytes(of: &be) { append(contentsOf: $0) }
  }
  mutating func appendBE(UInt64 v: UInt64) {
    var be = v.bigEndian
    Swift.withUnsafeBytes(of: &be) { append(contentsOf: $0) }
  }
  mutating func appendBE(Int16 v: Int16) {
    var be = v.bigEndian
    Swift.withUnsafeBytes(of: &be) { append(contentsOf: $0) }
  }
}
