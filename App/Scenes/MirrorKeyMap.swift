import AppKit
import Carbon.HIToolbox

/// Map macOS key events → Android KeyEvent keycodes and meta state.
/// Covers the common navigation / modifier set; printable characters fall back to
/// `INJECT_TEXT` in MirrorEventView.
enum MirrorKeyMap {
  /// Android KeyEvent.META_* flags.
  enum Meta: UInt32 {
    case shift   = 0x0000_0001
    case alt     = 0x0000_0002
    case ctrl    = 0x0000_1000
    case meta    = 0x0001_0000   // Command on mac → Meta on Android
    case fn      = 0x0000_0008
  }

  static func metaState(for event: NSEvent) -> UInt32 {
    var state: UInt32 = 0
    let f = event.modifierFlags
    if f.contains(.shift)   { state |= Meta.shift.rawValue }
    if f.contains(.option)  { state |= Meta.alt.rawValue }
    if f.contains(.control) { state |= Meta.ctrl.rawValue }
    if f.contains(.command) { state |= Meta.meta.rawValue }
    if f.contains(.function){ state |= Meta.fn.rawValue }
    return state
  }

  /// Returns the Android keycode (KEYCODE_*) for navigation / system keys.
  /// Returns nil for printable characters — caller should fall back to INJECT_TEXT.
  static func androidKeycode(for event: NSEvent) -> Int32? {
    switch Int(event.keyCode) {
    case kVK_Return, kVK_ANSI_KeypadEnter: return 66   // KEYCODE_ENTER
    case kVK_Tab:           return 61                  // KEYCODE_TAB
    case kVK_Delete:        return 67                  // KEYCODE_DEL (backspace)
    case kVK_ForwardDelete: return 112                 // KEYCODE_FORWARD_DEL
    case kVK_Escape:        return 111                 // KEYCODE_ESCAPE
    case kVK_LeftArrow:     return 21                  // KEYCODE_DPAD_LEFT
    case kVK_RightArrow:    return 22                  // KEYCODE_DPAD_RIGHT
    case kVK_UpArrow:       return 19                  // KEYCODE_DPAD_UP
    case kVK_DownArrow:     return 20                  // KEYCODE_DPAD_DOWN
    case kVK_Space:         return 62                  // KEYCODE_SPACE
    case kVK_Home:          return 122                 // KEYCODE_MOVE_HOME
    case kVK_End:           return 123                 // KEYCODE_MOVE_END
    case kVK_PageUp:        return 92                  // KEYCODE_PAGE_UP
    case kVK_PageDown:      return 93                  // KEYCODE_PAGE_DOWN
    default: return nil
    }
  }
}
