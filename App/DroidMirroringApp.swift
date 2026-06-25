import SwiftUI
import AppKit
import Combine
import os
import DeviceDiscovery
import SharedModels

@main
struct DroidMirroringApp: App {
  init() {
    setvbuf(stdout, nil, _IONBF, 0)   // log to /tmp/droidmirroring.log without buffering
    setvbuf(stderr, nil, _IONBF, 0)
  }

  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

  /// App version string from Info.plist
  private var appVersion: String {
    Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
  }

  var body: some Scene {
    // No main window. Mirror is THE product, opened automatically when a
    // device shows up. Everything else flows through the menu bar.

    MenuBarExtra("macDros", systemImage: "iphone.gen3") {
      MenuBarContent()
        .environmentObject(appDelegate.monitor)
    }
    .menuBarExtraStyle(.window)
    .commands {
      CommandGroup(replacing: .newItem) {}
      CommandGroup(after: .toolbar) {
        Button("Refresh Active Display") {
          guard let win = NSApp.keyWindow,
                let controller = win.windowController as? MirrorWindowController,
                let serial = controller.deviceSerial
          else { return }
          let monitor = appDelegate.monitor
          Task {
            let device = monitor.devices.first(where: { $0.id == serial })
              ?? Device(id: serial, state: .online)
            await SessionCoordinator.shared.refreshActiveDisplay(for: device)
          }
        }
        .keyboardShortcut("r", modifiers: [.command])
      }

      // About menu
      CommandGroup(after: .appInfo) {
        Button("Check for Updates…") {
          NSWorkspace.shared.open(URL(string: "https://github.com/matyle/droidMirroring-mac/releases/latest")!)
        }
        Divider()
        Button("Official Website") {
          if let url = URL(string: "https://droidmirroring.pages.dev") {
            NSWorkspace.shared.open(url)
          }
        }
        Button("GitHub Repository") {
          if let url = URL(string: "https://github.com/matyle/droidMirroring-mac") {
            NSWorkspace.shared.open(url)
          }
        }
        Divider()
        Button("DroidMirroring \(appVersion)") {
          NSApp.orderFrontStandardAboutPanel(options: [
            NSApplication.AboutPanelOptionKey.applicationIcon: NSApp.applicationIconImage as Any,
            NSApplication.AboutPanelOptionKey.applicationName: "DroidMirroring",
            NSApplication.AboutPanelOptionKey.applicationVersion: appVersion,
            NSApplication.AboutPanelOptionKey.version: "Built with Swift 6",
          ])
        }
      }
    }

    Settings {
      SettingsView()
        .environmentObject(appDelegate.monitor)
        .frame(width: 520, height: 420)
    }

    // Pairing UI lives in a Window so it can be summoned by id from the
    // menu bar or the Dock-icon-reopen handler. Suppressed on launch so a
    // first run doesn't pop unexpected chrome — discovered devices land in
    // Mirror first.
    Window("Pair a wireless device", id: WindowID.pairing) {
      PairingWindow(wireless: ResourceLocator.wirelessClient())
        .frame(minWidth: 560, minHeight: 420)
    }
    .windowResizability(.contentSize)
    .defaultLaunchBehavior(.suppressed)
  }
}

/// Window identifiers kept centralised — SwiftUI's `Window` id matching is
/// string-based and easy to drift out of sync with imperative open/close code.
enum WindowID {
  static let pairing = "droidmirroring.pairing"
}

/// Lifecycle owner now that there is no Window scene to hang `.onAppear` off.
/// Holds the singleton `DeviceMonitor`, wires Combine → SessionCoordinator
/// auto-mirror, and intercepts Quit + Dock-icon-reopen.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
  let monitor: DeviceMonitor = DeviceMonitor(
    adbBinary: Bundle.main.url(forResource: "adb", withExtension: nil)
  )
  private var deviceCancellable: AnyCancellable?

  func applicationDidFinishLaunching(_ notification: Notification) {
    // Keep a Dock icon — without it, users have no visible signal that the
    // app is running until they spot the menu bar item. The Dock icon also
    // gives us a proper "click to reopen" target.
    NSApp.setActivationPolicy(.regular)

    monitor.start()
    Task { [monitor] in
      try? await Task.sleep(nanoseconds: 1_500_000_000)
      // CRITICAL: only sweep if we haven't already auto-mirrored. Otherwise
      // we'd pkill the scrcpy-server we just launched — symptoms are dead
      // touch input and frozen IME in the new Mirror window.
      guard !SessionCoordinator.shared.hasActiveSession else { return }
      await monitor.sweepStaleScrcpyServers()
    }

    deviceCancellable = monitor.$devices
      .removeDuplicates()
      .sink { devices in
        Task { @MainActor in
          SessionCoordinator.shared.autoMirrorIfNeeded(devices: devices)
        }
      }
  }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    Task { @MainActor in
      await SessionCoordinator.shared.shutdownEverything()
      NSApp.reply(toApplicationShouldTerminate: true)
    }
    return .terminateLater
  }

  /// Dock icon clicked while nothing is on screen. We have three live
  /// possibilities:
  ///   - device online → open Mirror for it
  ///   - no device online → open the Pair Wireless Device window
  ///   - mirror window exists but is minimised → bring it forward
  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
    if hasVisibleWindows { return true }

    // First: surface an existing minimised Mirror or Files window if any.
    if let mirror = NSApp.windows.first(where: { $0.windowController is MirrorWindowController }) {
      NSApp.activate(ignoringOtherApps: true)
      mirror.makeKeyAndOrderFront(nil)
      return true
    }

    // Online device with no window → re-open Mirror for it.
    if let device = monitor.devices.first(where: { $0.state == .online }) {
      Task { @MainActor in await SessionCoordinator.shared.startMirror(for: device) }
      return true
    }

    // Nothing connected → surface the phone-shaped "no device" placeholder.
    NSApp.activate(ignoringOtherApps: true)
    SessionCoordinator.shared.syncWaitingWindow(hasOnlineDevice: false)
    return true
  }

  @objc func openPairing(_ sender: Any?) {
    // Routed via the responder chain so MenuBarContent / PairingWindow can
    // bind to it via @Environment(\.openWindow).
  }
}
