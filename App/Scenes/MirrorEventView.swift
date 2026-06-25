import AppKit
import ScrcpyClient

/// NSView that owns the Metal layer AND captures pointer/key events for the mirror session.
/// Coordinates are translated from view-local points to device pixels and sent on
/// the scrcpy control socket via `controlSink`.
final class MirrorEventView: NSView {
  /// Closure that ships a ControlMessage. Set by MirrorWindowController once the
  /// session's control writer is ready.
  var controlSink: ((ControlMessage) -> Void)?

  /// Device dimensions in pixels (width, height). Updated when the renderer reports
  /// a new pixel-buffer size (rotation / foldable unfold).
  var deviceDimensions: CGSize = .zero

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
    // Android KEYCODE_*. Mapped from the small set of common keys; the rest
    // falls through to inject_text below.
    if let keycode = MirrorKeyMap.androidKeycode(for: event) {
      controlSink?(.keycode(keycode, action: .down, metaState: MirrorKeyMap.metaState(for: event)))
      return
    }
    if let chars = event.charactersIgnoringModifiers, !chars.isEmpty {
      controlSink?(.text(chars))
    }
  }

  override func keyUp(with event: NSEvent) {
    if let keycode = MirrorKeyMap.androidKeycode(for: event) {
      controlSink?(.keycode(keycode, action: .up, metaState: MirrorKeyMap.metaState(for: event)))
    }
  }

  override func flagsChanged(with event: NSEvent) {
    // Modifier-only changes are reported through flagsChanged. Skip for now — TODO M2.2.
  }
}
