import AppKit
import SwiftUI
import CoreVideo
import CoreMedia
import FusionEngine
import MirrorEngine
import ScrcpyClient

/// One macOS window per Android freeform app. Borderless-ish look (transparent
/// titlebar, hidden title text); the toolbar exposes only window-scoped actions
/// (Pin, Screenshot, Record) — Back/Home/Recents belong to the device, not to
/// a single app's projected window.
@MainActor
final class FusionAppWindowController: NSWindowController, NSToolbarDelegate {
  let renderer: MetalFrameRenderer
  let eventView: MirrorEventView
  let recorder = ScreenRecorder()
  let appLabel: String

  private(set) var fusion: FusionSession?
  private var hasSetInitialFrame = false
  private var currentDeviceSize: CGSize = .zero
  private var isPinned = false
  private var isRecording = false
  private let statusModel = FusionStatusModel()

  init(appLabel: String) throws {
    let renderer = try MetalFrameRenderer()
    self.renderer = renderer
    self.eventView = MirrorEventView(layer: renderer.layer)
    self.appLabel = appLabel

    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1600, height: 900),
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered,
      defer: false
    )
    window.title = appLabel
    // Keep the normal opaque titlebar/toolbar — transparent titlebar leaves the
    // toolbar buttons floating over the Android desktop content; on a white
    // background (e.g. Samsung home) the SF Symbols become invisible.
    window.toolbarStyle = .unified

    // Composite the Metal mirror + a status footer in one vertical stack so the
    // window has a visible bottom edge against white Android wallpapers and
    // surfaces device/connection info at a glance.
    let host = FusionWindowContent(
      mirror: eventView,
      status: statusModel
    )
    window.contentView = NSHostingView(rootView: host)

    window.center()
    super.init(window: window)

    let toolbar = NSToolbar(identifier: "com.droidmirroring.app.fusion.toolbar")
    toolbar.delegate = self
    toolbar.displayMode = .iconOnly
    toolbar.allowsUserCustomization = false
    window.toolbar = toolbar

    renderer.onDimensionsChanged = { [weak self] size in
      Task { @MainActor in self?.applyDimensions(size) }
    }
    renderer.onFrame = { [weak self] buffer, pts in
      self?.recorder.append(pixelBuffer: buffer, pts: pts)
    }
  }

  required init?(coder: NSCoder) { fatalError() }

  override func close() {
    Task {
      if recorder.isRecording {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
          recorder.stop { _ in cont.resume() }
        }
      }
      if let fusion {
        await fusion.mirrorSession.stop()
      }
    }
    super.close()
  }

  func attach(_ session: FusionSession) async {
    self.fusion = session
    guard let writer = await session.mirrorSession.control else { return }
    let initialSize = CGSize(
      width: Int(await session.mirrorSession.dimensions.width),
      height: Int(await session.mirrorSession.dimensions.height)
    )
    let deviceName = await session.mirrorSession.deviceName
    let displayId = session.virtualDisplayId
    await MainActor.run {
      self.eventView.controlSink = { msg in
        Task { try? await writer.send(msg) }
      }
      self.statusModel.deviceName = deviceName
      self.statusModel.displayId = displayId
      self.statusModel.resolution = "\(Int(initialSize.width))×\(Int(initialSize.height))"
      self.applyDimensions(initialSize)
    }
  }

  // MARK: NSToolbarDelegate

  private enum ToolbarID {
    static let screenshot = NSToolbarItem.Identifier("droidmirroring.fusion.screenshot")
    static let record     = NSToolbarItem.Identifier("droidmirroring.fusion.record")
    static let pin        = NSToolbarItem.Identifier("droidmirroring.fusion.pin")
  }

  func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
    [.flexibleSpace, ToolbarID.screenshot, ToolbarID.record, ToolbarID.pin, .flexibleSpace]
  }

  func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
    toolbarDefaultItemIdentifiers(toolbar) + [.space]
  }

  func toolbar(_ toolbar: NSToolbar,
               itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
               willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
    switch itemIdentifier {
    case ToolbarID.screenshot: return makeItem(itemIdentifier, label: "Screenshot", symbol: "camera", action: #selector(takeScreenshot))
    case ToolbarID.record:     return makeItem(itemIdentifier, label: "Record", symbol: "record.circle", action: #selector(toggleRecord))
    case ToolbarID.pin:        return makeItem(itemIdentifier, label: "Pin", symbol: "pin", action: #selector(togglePin))
    default: return nil
    }
  }

  private func makeItem(_ id: NSToolbarItem.Identifier, label: String, symbol: String, action: Selector) -> NSToolbarItem {
    let item = NSToolbarItem(itemIdentifier: id)
    item.label = label
    item.paletteLabel = label
    item.toolTip = label
    item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
    item.target = self
    item.action = action
    item.isBordered = true
    return item
  }

  // MARK: toolbar actions

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
          self?.window?.toolbar?.validateVisibleItems()
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
        window?.toolbar?.validateVisibleItems()
      } catch {
        showAlert(error)
      }
    }
  }

  @objc private func togglePin() {
    isPinned.toggle()
    window?.level = isPinned ? .floating : .normal
    window?.toolbar?.validateVisibleItems()
  }

  // MARK: window adapt

  private func applyDimensions(_ size: CGSize) {
    guard size.width > 0, size.height > 0 else { return }
    currentDeviceSize = size
    eventView.deviceDimensions = size
    statusModel.resolution = "\(Int(size.width))×\(Int(size.height))"
    guard let window = self.window else { return }
    // The footer is ~26pt tall, so the *content* aspect = mirror aspect, plus a
    // fixed bottom strip. We don't lock contentAspectRatio here because that
    // would force the whole stack to mirror-only aspect; let the user resize
    // freely and the footer stays at its natural height.

    if !hasSetInitialFrame {
      hasSetInitialFrame = true
      setInitialFrame(deviceSize: size, window: window)
    }
  }

  private func setInitialFrame(deviceSize: CGSize, window: NSWindow) {
    let screenVisible = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
    // Scale device's long edge to ~85% of the screen's long edge — gives a
    // generous, almost-fullscreen window without bumping into the menu bar.
    let isLandscape = deviceSize.width >= deviceSize.height
    let screenLong = max(screenVisible.width, screenVisible.height)
    let targetLong = screenLong * 0.85
    let deviceLong = isLandscape ? deviceSize.width : deviceSize.height
    let scale = targetLong / deviceLong
    let contentSize = CGSize(width: deviceSize.width * scale, height: deviceSize.height * scale)
    let frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: contentSize))
    var positioned = frame
    positioned.origin = CGPoint(
      x: screenVisible.midX - frame.width / 2,
      y: screenVisible.midY - frame.height / 2
    )
    window.setFrame(positioned, display: true)
  }

  // MARK: helpers

  private func pictureRoot() -> URL {
    let base = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
      ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures")
    let dir = base.appendingPathComponent("DroidMirroring").appendingPathComponent(appLabel)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }

  private func movieRoot() -> URL {
    let base = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
      ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies")
    let dir = base.appendingPathComponent("DroidMirroring").appendingPathComponent(appLabel)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }

  private func showAlert(_ error: Error) {
    let alert = NSAlert(error: error)
    if let window { alert.beginSheetModal(for: window) }
    else { alert.runModal() }
  }
}

// MARK: SwiftUI content + status model

@MainActor
final class FusionStatusModel: ObservableObject {
  @Published var deviceName: String = ""
  @Published var displayId: Int = -1
  @Published var resolution: String = ""
}

/// Vertical stack: Metal mirror view on top, a thin status footer at the bottom.
/// The footer pins the visible bottom edge of the window so it doesn't get lost
/// against a light-themed Android desktop.
private struct FusionWindowContent: View {
  let mirror: NSView
  @ObservedObject var status: FusionStatusModel

  var body: some View {
    VStack(spacing: 0) {
      MirrorViewHost(view: mirror)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      Divider()
      HStack(spacing: 8) {
        Image(systemName: "display").foregroundStyle(.tint)
        Text(status.deviceName.isEmpty ? "Android" : status.deviceName)
          .font(.caption.weight(.medium))
        Text("·").foregroundStyle(.tertiary)
        Text(status.resolution).font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
        if status.displayId >= 0 {
          Text("·").foregroundStyle(.tertiary)
          Text("display #\(status.displayId)").font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        Spacer()
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 6)
      .background(.background.secondary)
    }
  }
}

private struct MirrorViewHost: NSViewRepresentable {
  let view: NSView
  func makeNSView(context: Context) -> NSView { view }
  func updateNSView(_ nsView: NSView, context: Context) {}
}

extension FusionAppWindowController: NSToolbarItemValidation {
  func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
    if item.itemIdentifier.rawValue == "droidmirroring.fusion.record" {
      item.image = NSImage(
        systemSymbolName: isRecording ? "stop.circle.fill" : "record.circle",
        accessibilityDescription: isRecording ? "Stop Recording" : "Record"
      )
    }
    if item.itemIdentifier.rawValue == "droidmirroring.fusion.pin" {
      item.image = NSImage(
        systemSymbolName: isPinned ? "pin.fill" : "pin",
        accessibilityDescription: isPinned ? "Unpin Window" : "Pin Window"
      )
    }
    return true
  }
}
