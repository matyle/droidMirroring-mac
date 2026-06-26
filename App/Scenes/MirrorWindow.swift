import AppKit
import CoreVideo
import CoreMedia
import MirrorEngine
import ScrcpyClient
import SharedModels
import SwiftUI

/// Free-standing mirror window. One per device.
@MainActor
final class MirrorWindowController: NSWindowController {
  let renderer: MetalFrameRenderer
  let session: MirrorSession
  let eventView: MirrorEventView
  let recorder = ScreenRecorder()
  private var overlayBar: MirrorOverlayBar?

  private var currentDeviceSize: CGSize = .zero
  private var hasSetInitialFrame = false
  private var isPinned = false
  private var isRecording = false
  private var isClipboardSyncing = true     // default ON, AndroMeld-style
  private var isScreenOff = false
  /// "mac" | "phone" | "none" — persisted in UserDefaults
  private var audioOutput: String {
    get { UserDefaults.standard.string(forKey: "mirror.audioOutput") ?? "mac" }
    set { UserDefaults.standard.set(newValue, forKey: "mirror.audioOutput") }
  }
  private var clipboardBridge: ClipboardBridge?
  private let deviceDisplayName: String

  // iPhone-Mirroring-style chrome auto-hide.
  private var chromeRevealed = false
  private var chromeHideTimer: Timer?
  private var mouseMonitor: Any?
  private static let bezelInset: CGFloat = 8
  private static let bezelCornerRadius: CGFloat = 34
  private static let innerCornerRadius: CGFloat = 26
  /// Empty strip above the phone bezel — gives traffic lights and the overlay
  /// HUD their own real estate so they don't crowd the Android status bar.
  private static let chromeStrip: CGFloat = 32

  /// Set by SessionCoordinator after the controller is created.
  var deviceSerial: String?

  init(deviceName: String) throws {
    let renderer = try MetalFrameRenderer()
    self.renderer = renderer
    self.eventView = MirrorEventView(layer: renderer.layer)
    self.session = MirrorSession { pixelBuffer, pts in
      renderer.render(pixelBuffer: pixelBuffer)
    }
    self.deviceDisplayName = deviceName.isEmpty ? "Mirror" : deviceName

    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 360, height: 720),
      styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
      backing: .buffered,
      defer: false
    )
    // iPhone-Mirroring look: clear background, transparent titlebar with no
    // title text, soft drop shadow follows the rounded phone-bezel content.
    window.title = ""
    window.titleVisibility = .hidden
    window.titlebarAppearsTransparent = true
    window.titlebarSeparatorStyle = .none
    window.isMovableByWindowBackground = true
    window.backgroundColor = .clear
    window.isOpaque = false
    window.hasShadow = true
    window.toolbarStyle = .unified
    window.contentAspectRatio = NSSize(width: 9, height: 16)

    // Wrap the Metal eventView in a rounded black phone-shell view.
    // Putting the inner-rounded mask on a *parent* NSView (instead of the
    // Metal layer itself) gives a clean clip — CAMetalLayer's own
    // cornerRadius/masksToBounds is flaky during resize animations.
    let screenClip = NSView()
    screenClip.wantsLayer = true
    screenClip.layer?.cornerRadius = Self.innerCornerRadius
    screenClip.layer?.cornerCurve = .continuous
    screenClip.layer?.masksToBounds = true
    screenClip.layer?.backgroundColor = NSColor.black.cgColor
    screenClip.addSubview(eventView)
    eventView.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      eventView.leadingAnchor.constraint(equalTo: screenClip.leadingAnchor),
      eventView.trailingAnchor.constraint(equalTo: screenClip.trailingAnchor),
      eventView.topAnchor.constraint(equalTo: screenClip.topAnchor),
      eventView.bottomAnchor.constraint(equalTo: screenClip.bottomAnchor),
    ])
    let bezel = PhoneBezelView(
      content: screenClip,
      inset: Self.bezelInset,
      cornerRadius: Self.bezelCornerRadius
    )

    // Container that hosts both the phone bezel and the chrome strip above it.
    // Window background stays clear, so only the bezel (and overlay) cast a
    // shadow — the chrome strip is invisible until the HUD bar fades in.
    let container = NSView()
    container.wantsLayer = true
    container.layer?.backgroundColor = NSColor.clear.cgColor
    container.addSubview(bezel)
    bezel.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      bezel.leadingAnchor.constraint(equalTo: container.leadingAnchor),
      bezel.trailingAnchor.constraint(equalTo: container.trailingAnchor),
      bezel.bottomAnchor.constraint(equalTo: container.bottomAnchor),
      bezel.topAnchor.constraint(equalTo: container.topAnchor, constant: Self.chromeStrip),
    ])

    window.contentView = container
    window.center()
    super.init(window: window)

    // Custom HUD-style overlay bar in the chrome strip above the bezel.
    // Floats next to (not over) the device content.
    let overlay = MirrorOverlayBar(
      onFiles:   { [weak self] in self?.openFiles() },
      onDesktop: { [weak self] in self?.openDesktop() },
      onMore:    { [weak self] anchor in self?.showMoreMenu(anchor: anchor) }
    )
    self.overlayBar = overlay
    container.addSubview(overlay)
    overlay.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      overlay.centerXAnchor.constraint(equalTo: container.centerXAnchor),
      overlay.topAnchor.constraint(equalTo: container.topAnchor, constant: 2),
    ])

    renderer.onDimensionsChanged = { [weak self] size in
      Task { @MainActor in self?.applyDimensions(size) }
    }
    renderer.onFrame = { [weak self] buffer, pts in
      // Off the main thread — append synchronously into the recorder.
      self?.recorder.append(pixelBuffer: buffer, pts: pts)
    }

    // Hide all chrome by default; cursor near the top edge fades it back in.
    DispatchQueue.main.async { [weak self] in
      self?.setChrome(revealed: false, animated: false)
      window.invalidateShadow()
    }
    let mask: NSEvent.EventTypeMask = [
      .mouseMoved, .leftMouseDown, .rightMouseDown, .otherMouseDown,
      .leftMouseDragged, .scrollWheel,
    ]
    mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
      if let self, event.window === self.window {
        Task { @MainActor in self.handleMouseMoved(event) }
      }
      return event
    }
  }

  required init?(coder: NSCoder) { fatalError() }

  override func close() {
    if let monitor = mouseMonitor {
      NSEvent.removeMonitor(monitor)
      mouseMonitor = nil
    }
    chromeHideTimer?.invalidate()
    chromeHideTimer = nil
    clipboardBridge?.stop()
    clipboardBridge = nil
    Task {
      if recorder.isRecording {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
          recorder.stop { _ in cont.resume() }
        }
      }
      // Restore screen power before tearing down so we don't leave the device
      // dark after disconnect. Use KEYCODE_POWER for compatibility.
      if isScreenOff, let writer = await session.control {
        try? await writer.send(.keycode(26, action: .down))  // KEYCODE_POWER down
        try? await writer.send(.keycode(26, action: .up))    // KEYCODE_POWER up
      }
      await session.stop()
    }
    super.close()
  }

  // MARK: bind

  func bindControl() async {
    guard let writer = await session.control else { return }
    let reader = await session.deviceMessageReader
    let initialSize = CGSize(
      width: Int(await session.dimensions.width),
      height: Int(await session.dimensions.height)
    )

    // Apply user preferences from Settings → Mirror.
    let defaults = UserDefaults.standard
    let clipboardOn = defaults.object(forKey: "mirror.clipboardSync") as? Bool ?? true
    // Default ON — saves the phone from rendering its own panel + the mirror
    // simultaneously, which is the dominant heat source.
    let autoScreenOff = defaults.object(forKey: "mirror.autoScreenOff") as? Bool ?? true

    await MainActor.run {
      self.isClipboardSyncing = clipboardOn
      self.eventView.controlSink = { msg in
        Task { try? await writer.send(msg) }
      }
      if let reader {
        let bridge = ClipboardBridge(writer: writer, reader: reader)
        bridge.enabled = clipboardOn
        bridge.start()
        self.clipboardBridge = bridge
      }
      self.applyDimensions(initialSize)
      self.window?.toolbar?.validateVisibleItems()
    }

    // Privacy preference — black out the device panel right after the first
    // frame so we don't surprise the user by displaying their lock screen.
    // Use KEYCODE_POWER for true screen off (not just brightness=0).
    if autoScreenOff {
      try? await writer.send(.keycode(26, action: .down))  // KEYCODE_POWER down
      try? await writer.send(.keycode(26, action: .up))    // KEYCODE_POWER up
      await MainActor.run {
        self.isScreenOff = true
        self.window?.toolbar?.validateVisibleItems()
      }
    }
  }

  // MARK: actions (wired from MirrorOverlayBar / window menu / keyboard)

  @objc private func takeScreenshot() {
    guard let buffer = renderer.lastPixelBuffer else { return }
    let dir = pictureRoot()
    let stamp = ISO8601DateFormatter().string(from: Date())
      .replacingOccurrences(of: ":", with: "-")
    let url = dir.appendingPathComponent("Screenshot-\(stamp).png")
    do {
      try Screenshotter.savePNG(pixelBuffer: buffer, to: url)
      NSWorkspace.shared.activateFileViewerSelecting([url])
    } catch {
      showAlert(error)
    }
  }

  @objc private func toggleRecord() {
    if recorder.isRecording {
      recorder.stop { [weak self] url in
        Task { @MainActor in
          self?.isRecording = false
          if let url { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        }
      }
    } else {
      guard currentDeviceSize.width > 0 else { return }
      let dir = movieRoot()
      let stamp = ISO8601DateFormatter().string(from: Date())
        .replacingOccurrences(of: ":", with: "-")
      let url = dir.appendingPathComponent("Recording-\(stamp).mp4")
      do {
        try recorder.start(outputURL: url, size: currentDeviceSize)
        isRecording = true
          } catch {
        showAlert(error)
      }
    }
  }

  @objc private func togglePin() {
    isPinned.toggle()
    window?.level = isPinned ? .floating : .normal
  }

  @objc private func wakeDevice() {
    // Use KEYCODE_POWER to properly wake the device screen
    Task {
      if let writer = await session.control {
        try? await writer.send(.keycode(26, action: .down))  // KEYCODE_POWER down
        try? await writer.send(.keycode(26, action: .up))    // KEYCODE_POWER up
      }
    }
    isScreenOff = false
    window?.toolbar?.validateVisibleItems()
  }

  @objc private func sendBack() {
    Task {
      if let writer = await session.control {
        try? await writer.send(.backOrScreenOn(action: .down))
        try? await writer.send(.backOrScreenOn(action: .up))
      }
    }
  }

  @objc private func sendHome() {
    sendKey(action: .down, code: 3)   // KEYCODE_HOME
    sendKey(action: .up, code: 3)
  }

  @objc private func sendRecents() {
    sendKey(action: .down, code: 187) // KEYCODE_APP_SWITCH
    sendKey(action: .up, code: 187)
  }

  @objc private func rotateDevice() {
    Task {
      if let writer = await session.control {
        try? await writer.send(.rotateDevice())
      }
    }
  }

  @objc private func toggleClipboardSync() {
    isClipboardSyncing.toggle()
    clipboardBridge?.enabled = isClipboardSyncing
  }

  /// Cycle audio output: mac → phone → none → mac
  @objc private func cycleAudioOutput() {
    let next: String
    switch audioOutput {
    case "mac":   next = "phone"
    case "phone": next = "none"
    default:      next = "mac"
    }
    audioOutput = next
  }

  @objc private func toggleScreenOff() {
    isScreenOff.toggle()
    Task {
      if let writer = await session.control {
        // Use KEYCODE_POWER for true screen on/off
        try? await writer.send(.keycode(26, action: .down))
        try? await writer.send(.keycode(26, action: .up))
      }
    }
  }

  @objc private func openFiles() {
    guard let serial = deviceSerial else { return }
    let device = Device(id: serial, model: session.deviceName, state: .online)
    SessionCoordinator.shared.openFiles(for: device)
  }

  @objc private func openDesktop() {
    guard let serial = deviceSerial else { return }
    let device = Device(id: serial, model: session.deviceName, androidSDK: 34, state: .online)
    Task { await SessionCoordinator.shared.openDesktop(for: device) }
  }

  private func sendKey(action: KeyEventAction, code: Int32) {
    Task {
      if let writer = await session.control {
        try? await writer.send(.keycode(code, action: action))
      }
    }
  }

  // MARK: more menu — every action that didn't make it onto the HUD bar

  private weak var morePopover: NSPopover?

  private func showMoreMenu(anchor: NSView) {
    if let existing = morePopover, existing.isShown {
      existing.performClose(nil)
      return
    }
    let popover = NSPopover()
    popover.behavior = .transient
    popover.delegate = self

    let dismiss: () -> Void = { [weak popover] in popover?.performClose(nil) }
    let panel = MoreActionsPanel(
      state: MoreActionsPanel.State(
        isRecording: isRecording,
        isClipboardSyncing: isClipboardSyncing,
        isScreenOff: isScreenOff,
        isPinned: isPinned,
        audioOutput: audioOutput
      ),
      onBack:       { [weak self] in dismiss(); self?.sendBack() },
      onHome:       { [weak self] in dismiss(); self?.sendHome() },
      onRecents:    { [weak self] in dismiss(); self?.sendRecents() },
      onScreenshot: { [weak self] in dismiss(); self?.takeScreenshot() },
      onRecord:     { [weak self] in dismiss(); self?.toggleRecord() },
      onRotate:     { [weak self] in dismiss(); self?.rotateDevice() },
      onClipboard:  { [weak self] in dismiss(); self?.toggleClipboardSync() },
      onScreenOff:  { [weak self] in dismiss(); self?.toggleScreenOff() },
      onWake:       { [weak self] in dismiss(); self?.wakeDevice() },
      onPin:        { [weak self] in dismiss(); self?.togglePin() },
      onCycleAudio: { [weak self] in dismiss(); self?.cycleAudioOutput() }
    )
    let hosting = NSHostingController(rootView: panel)
    popover.contentViewController = hosting
    popover.contentSize = hosting.view.fittingSize
    morePopover = popover

    // Keep chrome alive while popover is up (popoverDidClose re-arms hide).
    setChrome(revealed: true)
    chromeHideTimer?.invalidate()
    chromeHideTimer = nil
    popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
  }

  // MARK: chrome reveal — iPhone-Mirroring style

  private func handleMouseMoved(_ event: NSEvent) {
    guard let window = self.window else { return }
    let loc = event.locationInWindow
    let h = window.frame.height
    // Top ~80pt reveals chrome immediately; anywhere else inside the window
    // just keeps the existing hide timer running.
    if loc.y > h - 80 {
      setChrome(revealed: true)
    }
    scheduleHideChrome()
  }

  private func setChrome(revealed: Bool, animated: Bool = true) {
    chromeHideTimer?.invalidate()
    chromeHideTimer = nil
    if chromeRevealed == revealed { return }
    chromeRevealed = revealed
    guard let window else { return }
    let alpha: CGFloat = revealed ? 1.0 : 0.0
    let buttons: [NSButton?] = [
      window.standardWindowButton(.closeButton),
      window.standardWindowButton(.miniaturizeButton),
      window.standardWindowButton(.zoomButton),
    ]
    if animated {
      NSAnimationContext.runAnimationGroup { ctx in
        ctx.duration = 0.18
        buttons.forEach { $0?.animator().alphaValue = alpha }
        overlayBar?.animator().alphaValue = alpha
      }
    } else {
      buttons.forEach { $0?.alphaValue = alpha }
      overlayBar?.alphaValue = alpha
    }
  }

  private func scheduleHideChrome() {
    // Don't fight the More popover — let popoverDidClose restart the timer.
    if let popover = morePopover, popover.isShown { return }
    chromeHideTimer?.invalidate()
    // Stays visible 2s after the last cursor activity. Any mouseMoved /
    // mouseDown / scroll resets this timer (see mouseMonitor in init), so as
    // long as the user is interacting, chrome stays put.
    chromeHideTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { [weak self] _ in
      Task { @MainActor in self?.setChrome(revealed: false) }
    }
  }

  // MARK: window adapt

  private func applyDimensions(_ size: CGSize) {
    guard size.width > 0, size.height > 0 else { return }
    let changed = currentDeviceSize != size
    currentDeviceSize = size
    eventView.deviceDimensions = size

    guard let window = self.window else { return }
    // contentAspectRatio is set on the *window content rect*, which is the
    // device area + 2*bezelInset on each side + chromeStrip at the top.
    let aspect = aspectRatio(for: size)
    window.contentAspectRatio = aspect

    if !hasSetInitialFrame {
      hasSetInitialFrame = true
      setInitialFrame(deviceSize: size, window: window)
      return
    }
    guard changed else { return }

    let oldFrame = window.frame
    let oldContent = window.contentRect(forFrameRect: oldFrame).size
    let oldArea = max(1, oldContent.width * oldContent.height)
    let scale = sqrt(oldArea / (aspect.width * aspect.height))
    let newContent = CGSize(width: aspect.width * scale, height: aspect.height * scale)
    let newFrame = window.frameRect(forContentRect: NSRect(origin: .zero, size: newContent))
    var finalFrame = newFrame
    finalFrame.origin = CGPoint(
      x: oldFrame.midX - finalFrame.width / 2,
      y: oldFrame.midY - finalFrame.height / 2
    )
    // `animate: true` makes NSWindow interpolate the frame, but during that
    // animation the rounded-bezel mask and the titlebar layer fall briefly
    // out of sync — you see a black square flash. Instant resize avoids it.
    window.setFrame(finalFrame, display: true, animate: false)
    window.invalidateShadow()
  }

  private func setInitialFrame(deviceSize: CGSize, window: NSWindow) {
    let screenVisible = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
    let target = min(screenVisible.width, screenVisible.height) * 0.6
    let inset = Self.bezelInset
    let chrome = Self.chromeStrip
    let scale: CGFloat = (deviceSize.height >= deviceSize.width)
      ? (target - chrome - 2 * inset) / deviceSize.height
      : (target - 2 * inset) / deviceSize.width
    let contentSize = CGSize(
      width:  deviceSize.width  * scale + 2 * inset,
      height: deviceSize.height * scale + chrome + 2 * inset
    )
    let frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: contentSize))
    var positioned = frame
    positioned.origin = CGPoint(
      x: screenVisible.midX - frame.width / 2,
      y: screenVisible.midY - frame.height / 2
    )
    window.setFrame(positioned, display: true)
  }

  private func aspectRatio(for deviceSize: CGSize) -> NSSize {
    NSSize(
      width:  deviceSize.width  + 2 * Self.bezelInset,
      height: deviceSize.height + Self.chromeStrip + 2 * Self.bezelInset
    )
  }

  // MARK: helpers

  private func pictureRoot() -> URL {
    let base = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
      ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures")
    let dir = base.appendingPathComponent("DroidMirroring").appendingPathComponent(deviceDisplayName)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }

  private func movieRoot() -> URL {
    let base = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
      ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies")
    let dir = base.appendingPathComponent("DroidMirroring").appendingPathComponent(deviceDisplayName)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }

  private func showAlert(_ error: Error) {
    let alert = NSAlert(error: error)
    if let window { alert.beginSheetModal(for: window) }
    else { alert.runModal() }
  }
}

// MARK: NSPopoverDelegate — re-arm chrome hide once More popover closes

extension MirrorWindowController: NSPopoverDelegate {
  func popoverDidClose(_ notification: Notification) {
    scheduleHideChrome()
  }
}

// MARK: MoreActionsPanel — SwiftUI grid shown by the ⋯ button

struct MoreActionsPanel: View {
  struct State {
    var isRecording: Bool
    var isClipboardSyncing: Bool
    var isScreenOff: Bool
    var isPinned: Bool
    var audioOutput: String  // "mac" | "phone" | "none"
  }

  let state: State
  let onBack: () -> Void
  let onHome: () -> Void
  let onRecents: () -> Void
  let onScreenshot: () -> Void
  let onRecord: () -> Void
  let onRotate: () -> Void
  let onClipboard: () -> Void
  let onScreenOff: () -> Void
  let onWake: () -> Void
  let onPin: () -> Void
  let onCycleAudio: () -> Void

  var audioLabel: String {
    switch state.audioOutput {
    case "mac":   return "Mac"
    case "phone": return "Phone"
    default:      return "Mute"
    }
  }

  var audioSymbol: String {
    switch state.audioOutput {
    case "mac":   return "speaker.wave.3.fill"
    case "phone": return "iphone.gen2"
    default:      return "speaker.slash.fill"
    }
  }

  var body: some View {
    VStack(spacing: 8) {
      HStack(spacing: 8) {
        Tile(symbol: "chevron.backward", label: "Back",    action: onBack)
        Tile(symbol: "circle",           label: "Home",    action: onHome)
        Tile(symbol: "square.stack",     label: "Recents", action: onRecents)
      }
      HStack(spacing: 8) {
        Tile(symbol: "camera",                          label: "Capture", action: onScreenshot)
        Tile(symbol: state.isRecording ? "stop.circle.fill" : "record.circle",
             label: state.isRecording ? "Stop" : "Record",
             tint: state.isRecording ? .red : nil,
             action: onRecord)
        Tile(symbol: "rotate.right",                    label: "Rotate",  action: onRotate)
      }
      HStack(spacing: 8) {
        Tile(symbol: state.isClipboardSyncing ? "doc.on.clipboard.fill" : "doc.on.clipboard",
             label: "Clipboard",
             tint: state.isClipboardSyncing ? .accentColor : nil,
             action: onClipboard)
        Tile(symbol: state.isScreenOff ? "moon.fill" : "moon",
             label: state.isScreenOff ? "Wake" : "Sleep",
             tint: state.isScreenOff ? .yellow : nil,
             action: onScreenOff)
        Tile(symbol: audioSymbol, label: audioLabel, action: onCycleAudio)
      }
      HStack(spacing: 8) {
        Tile(symbol: "power", label: "Power", action: onWake)
        Tile(symbol: state.isPinned ? "pin.fill" : "pin",
             label: "Pin",
             tint: state.isPinned ? .accentColor : nil,
             action: onPin)
      }
    }
    .padding(12)
    .frame(width: 280)
  }
}

private struct Tile: View {
  let symbol: String
  let label: String
  var tint: Color? = nil
  let action: () -> Void

  @State private var hovering = false

  var body: some View {
    Button(action: action) {
      VStack(spacing: 4) {
        Image(systemName: symbol)
          .font(.system(size: 18, weight: .medium))
          .foregroundStyle(tint ?? .primary)
          .frame(width: 44, height: 44)
          .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
              .fill(hovering ? Color.primary.opacity(0.18) : Color.primary.opacity(0.08))
          )
        Text(label)
          .font(.system(size: 10))
          .foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { hovering = $0 }
  }
}

// MARK: MirrorOverlayBar — floating HUD-style control strip

/// Small blurred pill that floats on the top bezel strip. Hosts the
/// inter-mode actions (Files / Desktop). Designed to feel like iPhone
/// Mirroring's tab strip — fades in/out with the rest of the window chrome.
final class MirrorOverlayBar: NSView {
  private let onFiles: () -> Void
  private let onDesktop: () -> Void
  private let onMore: (NSView) -> Void

  init(onFiles: @escaping () -> Void,
       onDesktop: @escaping () -> Void,
       onMore: @escaping (NSView) -> Void) {
    self.onFiles = onFiles
    self.onDesktop = onDesktop
    self.onMore = onMore
    super.init(frame: .zero)
    wantsLayer = true
    layer?.cornerCurve = .continuous

    // Solid dark bar — no glass effect. Completely invisible when alpha=0.
    let barBg = NSView()
    barBg.wantsLayer = true
    barBg.layer?.backgroundColor = NSColor(white: 0.0, alpha: 0.85).cgColor
    barBg.layer?.cornerRadius = 12
    barBg.layer?.cornerCurve = .continuous
    addSubview(barBg)
    barBg.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      barBg.leadingAnchor.constraint(equalTo: leadingAnchor),
      barBg.trailingAnchor.constraint(equalTo: trailingAnchor),
      barBg.topAnchor.constraint(equalTo: topAnchor),
      barBg.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])

    let filesBtn = makeButton(symbol: "folder", tooltip: "Files",   action: #selector(filesTapped))
    let desktopBtn = makeButton(symbol: "display", tooltip: "Desktop", action: #selector(desktopTapped))
    let moreBtn = makeButton(symbol: "ellipsis", tooltip: "More", action: #selector(moreTapped))

    let stack = NSStackView(views: [filesBtn, desktopBtn, moreBtn])
    stack.orientation = .horizontal
    stack.spacing = 6
    stack.edgeInsets = NSEdgeInsets(top: 6, left: 12, bottom: 6, right: 12)
    addSubview(stack)
    stack.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: trailingAnchor),
      stack.topAnchor.constraint(equalTo: topAnchor),
      stack.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])
  }

  required init?(coder: NSCoder) { fatalError() }

  private func makeButton(symbol: String, tooltip: String, action: Selector) -> NSButton {
    let config = NSImage.SymbolConfiguration(pointSize: 18, weight: .medium)
    let image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)?
      .withSymbolConfiguration(config) ?? NSImage()
    let button = NSButton(image: image, target: self, action: action)
    button.isBordered = false
    button.bezelStyle = .smallSquare
    button.contentTintColor = .white
    button.toolTip = tooltip
    button.imageScaling = .scaleProportionallyDown
    button.setContentHuggingPriority(.required, for: .horizontal)
    return button
  }

  @objc private func filesTapped() { onFiles() }
  @objc private func desktopTapped() { onDesktop() }
  @objc private func moreTapped(_ sender: NSButton) { onMore(sender) }
}

// MARK: PhoneBezelView — black rounded shell hosting the Metal mirror view

final class PhoneBezelView: NSView {
  init(content: NSView, inset: CGFloat, cornerRadius: CGFloat) {
    super.init(frame: .zero)
    wantsLayer = true
    layer?.backgroundColor = NSColor.black.cgColor
    layer?.cornerRadius = cornerRadius
    layer?.cornerCurve = .continuous
    layer?.masksToBounds = true

    addSubview(content)
    content.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
      content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
      content.topAnchor.constraint(equalTo: topAnchor, constant: inset),
      content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -inset),
    ])
  }

  required init?(coder: NSCoder) { fatalError() }
}
