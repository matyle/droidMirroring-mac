import AppKit
import ScrcpyClient

/// NSView that owns the Metal layer AND captures pointer/key events for the mirror session.
/// Coordinates are translated from view-local points to device pixels and sent on
/// the scrcpy control socket via `controlSink`.
///
/// Conforms to `NSTextInputClient` to support IME input (Chinese, Japanese, etc.).
final class MirrorEventView: NSView, NSTextInputClient {
  /// Closure that ships a ControlMessage. Set by MirrorWindowController once the
  /// session's control writer is ready.
  var controlSink: ((ControlMessage) -> Void)?

  /// Device dimensions in pixels (width, height). Updated when the renderer reports
  /// a new pixel-buffer size (rotation / foldable unfold).
  var deviceDimensions: CGSize = .zero

  // MARK: - NSTextInputClient (IME support)

  /// Current IME composition text (marked text). Sent to Android as a single
  /// `inject_text` when the user confirms the composition (e.g. presses Enter
  /// or clicks a candidate).
  private var markedText: NSMutableAttributedString?

  private var _currentFrame: NSRect = .zero

  func selectedRange() -> NSRange {
    guard let markedText else { return NSRange(location: 0, length: 0) }
    return NSRange(location: markedText.length, length: 0)
  }

  func markedRange() -> NSRange {
    guard let text = markedText, text.length > 0 else { return NSRange() }
    return NSRange(location: 0, length: text.length)
  }

  func hasMarkedText() -> Bool {
    markedText?.length ?? 0 > 0
  }

  func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
    nil
  }

  func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

  func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
    window?.convertToScreen(convert(_currentFrame, to: nil)) ?? .zero
  }

  func characterIndex(for point: NSPoint) -> Int { 0 }

  func insertText(_ string: Any, replacementRange: NSRange) {
    // Called when the IME composition is committed.
    // Could be an NSAttributedString or an NSString.
    var textToInsert: String?

    if let attrStr = string as? NSAttributedString {
      textToInsert = attrStr.string
    } else if let str = string as? String {
      textToInsert = str
    }

    guard let textToInsert, !textToInsert.isEmpty else { return }

    // Clear any marked text state
    markedText = nil

    // Send to Android via scrcpy inject_text
    controlSink?(.text(textToInsert))
  }

  func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
    // Called as the user types in an IME composition session.
    // `string` is the current composition (partial or final).
    if let attrStr = string as? NSAttributedString {
      markedText = NSMutableAttributedString(attributedString: attrStr)
    } else if let str = string as? String {
      markedText = NSMutableAttributedString(string: str)
    }
    // We don't send the partial text to Android yet — wait for commit.
    // This prevents garbled half-typed pinyin from appearing on the device.
  }

  func unmarkText() {
    // Called when the IME composition is cancelled (e.g. user presses Esc).
    markedText = nil
  }

  // MARK: - init / focus / cursor

  private var trackingArea: NSTrackingArea?
  private var currentButtons: MotionButton = []

  init(layer hostedLayer: CALayer) {
    super.init(frame: .zero)
    wantsLayer = true
    layer = hostedLayer
  }

  required init?(coder: NSCoder) { fatalError() }

  // MARK: focus / cursor

  override var acceptsFirstResponder: Bool { true }
  override func becomeFirstResponder() -> Bool { true }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
  /// The window has `isMovableByWindowBackground = true` so users can grab
  /// the bezel to move it. Without this override, mouseDown on the mirror
  /// surface would also drag the window — making scroll/swipe gestures inside
  /// the device impossible. The bezel parent doesn't override this, so window
  /// drag still works on the black phone-shell area.
  override var mouseDownCanMoveWindow: Bool { false }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let existing = trackingArea { removeTrackingArea(existing) }
    let area = NSTrackingArea(
      rect: bounds,
      options: [.activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
      owner: self,
      userInfo: nil
    )
    addTrackingArea(area)
    trackingArea = area
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    window?.makeFirstResponder(self)
  }

  // MARK: pointer

  override func mouseDown(with event: NSEvent) {
    currentButtons.insert(.primary)
    sendTouch(.down, event: event)
  }

  override func mouseDragged(with event: NSEvent) {
    sendTouch(.move, event: event)
  }

  override func mouseUp(with event: NSEvent) {
    sendTouch(.up, event: event)
    currentButtons.remove(.primary)
  }

  override func mouseMoved(with event: NSEvent) {
    // hover with no buttons — scrcpy treats this as MOVE with empty buttons
    sendTouch(.hoverMove, event: event)
  }

  override func rightMouseDown(with event: NSEvent) {
    // map right-click to BACK keypress, which is what scrcpy desktop client does
    controlSink?(.backOrScreenOn(action: .down))
  }
  override func rightMouseUp(with event: NSEvent) {
    controlSink?(.backOrScreenOn(action: .up))
  }

  override func scrollWheel(with event: NSEvent) {
    guard let (x, y) = devicePoint(for: event) else { return }
    // NSEvent.scrollingDeltaY is positive when scrolling content UP; on Android, positive vscroll
    // means "scroll content up" too, so leave the sign alone.
    let dx = event.scrollingDeltaX / 50.0
    let dy = event.scrollingDeltaY / 50.0
    controlSink?(.scroll(
      x: x, y: y,
      screenWidth: UInt16(deviceDimensions.width),
      screenHeight: UInt16(deviceDimensions.height),
      hscroll: dx, vscroll: dy,
      buttons: currentButtons
    ))
  }

  private func sendTouch(_ action: TouchAction, event: NSEvent) {
    guard let (x, y) = devicePoint(for: event) else { return }
    let buttons: MotionButton = (action == .hoverMove) ? [] : currentButtons
    controlSink?(.touch(
      action: action,
      x: x, y: y,
      screenWidth: UInt16(deviceDimensions.width),
      screenHeight: UInt16(deviceDimensions.height),
      pressure: action == .up ? 0 : 1,
      buttons: buttons
    ))
  }

  /// Translate a NSEvent's view-local point into device pixel coordinates.
  /// NSView origin is bottom-left; device origin is top-left, so we flip Y.
  private func devicePoint(for event: NSEvent) -> (Int32, Int32)? {
    guard deviceDimensions.width > 0, deviceDimensions.height > 0 else { return nil }
    let p = convert(event.locationInWindow, from: nil)
    let viewW = bounds.width
    let viewH = bounds.height
    guard viewW > 0, viewH > 0 else { return nil }
    let devX = Int32((p.x / viewW) * deviceDimensions.width)
    let devY = Int32(((viewH - p.y) / viewH) * deviceDimensions.height)
    let cx = max(0, min(Int32(deviceDimensions.width) - 1, devX))
    let cy = max(0, min(Int32(deviceDimensions.height) - 1, devY))
    return (cx, cy)
  }

  // MARK: keyboard

  override func keyDown(with event: NSEvent) {
    // Android KEYCODE_* for special keys (Enter, Tab, Backspace, arrows, etc.)
    if let keycode = MirrorKeyMap.androidKeycode(for: event) {
      // If there's pending IME composition, commit it first before sending the keycode
      if let marked = markedText, marked.length > 0 {
        controlSink?(.text(marked.string))
        markedText = nil
      }
      controlSink?(.keycode(keycode, action: .down, metaState: MirrorKeyMap.metaState(for: event)))
      return
    }
    // For regular character keys, let the IME system handle it.
    // This interprets the key event through the NSTextInputClient pipeline,
    // which handles marked text (Chinese pinyin, Japanese kana, etc.)
    interpretKeyEvents([event])
  }

  override func keyUp(with event: NSEvent) {
    if let keycode = MirrorKeyMap.androidKeycode(for: event) {
      controlSink?(.keycode(keycode, action: .up, metaState: MirrorKeyMap.metaState(for: event)))
    }
  }

  override func flagsChanged(with event: NSEvent) {
    // Modifier-only changes are reported through flagsChanged. Skip for now.
  }

  // Forward doCommand(by:) from NSResponder so key equivalents work
  override func doCommand(by selector: Selector) {
    // Handle any pending input selector from the text input system
    if selector == #selector(insertTab(_:)) {
      if let marked = markedText, marked.length > 0 {
        controlSink?(.text(marked.string))
        markedText = nil
      }
      controlSink?(.keycode(61, action: .down))  // KEYCODE_TAB
      controlSink?(.keycode(61, action: .up))
    } else if selector == #selector(insertNewline(_:)) {
      if let marked = markedText, marked.length > 0 {
        controlSink?(.text(marked.string))
        markedText = nil
      }
      controlSink?(.keycode(66, action: .down))  // KEYCODE_ENTER
      controlSink?(.keycode(66, action: .up))
    } else if selector == #selector(deleteBackward(_:)) {
      if let marked = markedText, marked.length > 0 {
        // Remove last character from marked text instead of sending to Android
        let len = marked.length
        if len > 0 {
          marked.deleteCharacters(in: NSRange(location: len - 1, length: 1))
        }
      } else {
        controlSink?(.keycode(67, action: .down))  // KEYCODE_DEL
        controlSink?(.keycode(67, action: .up))
      }
    } else if selector == #selector(cancelOperation(_:)) {
      unmarkText()
    } else if selector == #selector(insertText(_:replacementRange:)) || selector == Selector("paste:") {
      // Let macOS paste handle it — don't forward to Android
    } else {
      super.doCommand(by: selector)
    }
  }
}
