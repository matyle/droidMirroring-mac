import AppKit
import SwiftUI

/// "No device" placeholder window — shaped like the real Mirror window
/// (same phone bezel, same chrome strip), but with a SwiftUI placeholder
/// hosted inside the screen area. Lives at app launch until a device
/// connects, then SessionCoordinator swaps it out for a real Mirror.
@MainActor
final class WaitingMirrorWindowController: NSWindowController {
  private static let bezelInset: CGFloat = 8
  private static let bezelCornerRadius: CGFloat = 34
  private static let innerCornerRadius: CGFloat = 26
  private static let chromeStrip: CGFloat = 32

  init() {
    // Use a wider default aspect so the window doesn't look too narrow.
    // 9:16 is closer to a typical tablet/landscape phone ratio.
    let defaultDevice = CGSize(width: 1080, height: 1920)
    let screenVisible = NSScreen.main?.visibleFrame ?? .zero
    let target = min(screenVisible.width, screenVisible.height) * 0.6
    let scale = (target - Self.chromeStrip - 2 * Self.bezelInset) / defaultDevice.height
    let contentSize = CGSize(
      width:  defaultDevice.width  * scale + 2 * Self.bezelInset,
      height: defaultDevice.height * scale + Self.chromeStrip + 2 * Self.bezelInset
    )
    let aspect = NSSize(
      width:  defaultDevice.width  + 2 * Self.bezelInset,
      height: defaultDevice.height + Self.chromeStrip + 2 * Self.bezelInset
    )

    let window = NSWindow(
      contentRect: NSRect(origin: .zero, size: contentSize),
      styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
      backing: .buffered,
      defer: false
    )
    window.title = ""
    window.titleVisibility = .hidden
    window.titlebarAppearsTransparent = true
    window.titlebarSeparatorStyle = .none
    window.isMovableByWindowBackground = true
    window.backgroundColor = .clear
    window.isOpaque = false
    window.hasShadow = true
    window.contentAspectRatio = aspect

    // Hide all traffic lights (close, minimize, zoom)
    [.closeButton, .miniaturizeButton, .zoomButton].forEach {
      window.standardWindowButton($0)?.isHidden = true
    }

    let hosting = NSHostingController(rootView: WaitingPlaceholderView())
    hosting.view.wantsLayer = true

    let screenClip = NSView()
    screenClip.wantsLayer = true
    screenClip.layer?.cornerRadius = Self.innerCornerRadius
    screenClip.layer?.cornerCurve = .continuous
    screenClip.layer?.masksToBounds = true
    screenClip.layer?.backgroundColor = NSColor.black.cgColor
    screenClip.addSubview(hosting.view)
    hosting.view.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      hosting.view.leadingAnchor.constraint(equalTo: screenClip.leadingAnchor),
      hosting.view.trailingAnchor.constraint(equalTo: screenClip.trailingAnchor),
      hosting.view.topAnchor.constraint(equalTo: screenClip.topAnchor),
      hosting.view.bottomAnchor.constraint(equalTo: screenClip.bottomAnchor),
    ])

    let bezel = PhoneBezelView(
      content: screenClip,
      inset: Self.bezelInset,
      cornerRadius: Self.bezelCornerRadius
    )

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

    // Hide traffic lights on the chrome strip — there's nothing actionable on
    // this window besides the close button. Leave close enabled so users
    // can dismiss; minimize/zoom buttons removed.
    [.miniaturizeButton, .zoomButton].forEach {
      window.standardWindowButton($0)?.isHidden = true
    }
  }

  required init?(coder: NSCoder) { fatalError() }
}

/// Inner SwiftUI placeholder — drawn inside the phone bezel's "screen".
struct WaitingPlaceholderView: View {
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    ZStack {
      LinearGradient(
        colors: [Color(white: 0.18), Color(white: 0.10)],
        startPoint: .top, endPoint: .bottom
      )
      VStack(spacing: 22) {
        Image(systemName: "iphone.gen3")
          .font(.system(size: 56, weight: .light))
          .symbolRenderingMode(.hierarchical)
          .foregroundStyle(.blue)
          .shadow(color: .blue.opacity(0.35), radius: 12)

        VStack(spacing: 6) {
          Text("No Device Connected")
            .font(.title3.weight(.semibold))
            .foregroundStyle(.white)
          Text("Plug in via USB, or pair a wireless\ndevice to start mirroring.")
            .font(.subheadline)
            .multilineTextAlignment(.center)
            .foregroundStyle(.white.opacity(0.65))
            .fixedSize(horizontal: false, vertical: true)
        }

        Button {
          NSApp.activate(ignoringOtherApps: true)
          openWindow(id: WindowID.pairing)
        } label: {
          Text("Add Wireless Device…")
            .fontWeight(.semibold)
            .padding(.horizontal, 6)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .tint(.blue)
      }
      .padding(.horizontal, 28)
    }
  }
}
