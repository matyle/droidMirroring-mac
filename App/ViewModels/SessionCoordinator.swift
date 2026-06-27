import Foundation
import AppKit
import ADBKit
import ScrcpyClient
import MirrorEngine
import FusionEngine
import SharedModels
import os

private let log = Logger(subsystem: "com.droidmirroring.app", category: "coordinator")

/// Top-level glue between UI and engines. Owned by `DroidMirroringApp`.
///
/// Per-device state machine:
///   1. User picks a device → `startMirror`
///   2. We pick the largest active physical display (folded outer / unfolded inner)
///      and launch a scrcpy session pinned to its display_id
///   3. A 1.5s poll watches for fold/unfold; on change we tear the session down and
///      relaunch on the new display_id. The mirror window stays open and just
///      re-receives the new size via `onDimensionsChanged` → auto-resize.
@MainActor
final class SessionCoordinator: ObservableObject {
  static let shared = SessionCoordinator()

  /// Best-effort synchronous cleanup invoked from the AppDelegate's
  /// `applicationShouldTerminate`. Stops every live mirror / fusion / files
  /// window in parallel so scrcpy-server's `cleanup=true` hook fires before we
  /// die, releasing any virtual displays on the device.
  func shutdownEverything() async {
    await withTaskGroup(of: Void.self) { group in
      for (_, controller) in mirrorWindows {
        group.addTask { await controller.session.stop() }
      }
      for (_, controller) in fusionWindows {
        group.addTask {
          if let f = await controller.fusion { await f.mirrorSession.stop() }
        }
      }
      for (serial, token) in freeformTokens {
        if let activator = freeformActivators[serial] {
          group.addTask { await activator.deactivate(token) }
        }
      }
    }
    mirrorWindows.removeAll()
    fusionWindows.removeAll()
    freeformTokens.removeAll()
    freeformActivators.removeAll()
  }

  private let adb = ADBClient()
  private var mirrorWindows: [String: MirrorWindowController] = [:]
  private var filesWindows: [String: FilesWindowController] = [:]
  /// One window per (deviceSerial, packageName).
  private var fusionWindows: [String: FusionAppWindowController] = [:]
  /// Each device gets one FreeformActivator + its restoration token; we activate
  /// lazily on first Fusion launch and deactivate when no more Fusion windows remain.
  private var freeformActivators: [String: FreeformActivator] = [:]
  private var freeformTokens: [String: ActivationToken] = [:]
  /// Samsung foldables remap LogicalDisplay 0 to whichever panel is active,
  /// so tracking the id alone misses fold/unfold transitions. We also remember
  /// dims and rotation; bump scrcpy when any of them change.
  private var activePanel: [String: (id: Int, width: Int, height: Int, rotation: Int)] = [:]
  private var pollTasks: [String: Task<Void, Never>] = [:]

  /// Serials we've already auto-opened in this app session. Cleared on quit.
  /// Prevents re-opening Mirror when the user explicitly closed it.
  private var autoMirroredSerials: Set<String> = []

  /// Phone-shaped "no device connected" placeholder shown when there's
  /// nothing to mirror. Owned here so it can be opened/closed in lockstep
  /// with the real Mirror windows.
  private var waitingController: WaitingMirrorWindowController?

  /// True iff any Mirror / Files / Desktop window for any device is alive.
  /// Used by the launch-time sweep so it doesn't pkill our own scrcpy-server.
  var hasActiveSession: Bool {
    !mirrorWindows.isEmpty || !fusionWindows.isEmpty
  }

  /// Called from the App on every DeviceMonitor publish. Opens Mirror for the
  /// first online device we haven't already auto-mirrored this session,
  /// provided the user hasn't disabled the auto-mirror preference.
  /// Also tears down Mirror/Files for devices that just disappeared, and
  /// toggles the "no device connected" placeholder window.
  func autoMirrorIfNeeded(devices: [Device]) {
    let online = devices.filter { $0.state == .online }
    let onlineSerials = Set(online.map(\.id))

    // Reap zombies — when USB is unplugged the device drops out of the publish
    // list, but our Mirror controller still holds a frozen frame. Close it so
    // the Waiting placeholder can take over.
    for serial in Array(mirrorWindows.keys) where !onlineSerials.contains(serial) {
      log.notice("device \(serial) gone — closing Mirror")
      mirrorWindows[serial]?.close()
      mirrorWindows.removeValue(forKey: serial)
      pollTasks[serial]?.cancel()
      pollTasks.removeValue(forKey: serial)
      activePanel.removeValue(forKey: serial)
      autoMirroredSerials.remove(serial)
    }
    for serial in Array(filesWindows.keys) where !onlineSerials.contains(serial) {
      filesWindows[serial]?.close()
      filesWindows.removeValue(forKey: serial)
    }

    syncWaitingWindow(hasOnlineDevice: !online.isEmpty)

    let autoEnabled = UserDefaults.standard.object(forKey: "mirror.autoOnConnect") as? Bool ?? true
    guard autoEnabled else { return }
    for device in online {
      if mirrorWindows[device.id] != nil { continue }
      if autoMirroredSerials.contains(device.id) { continue }
      autoMirroredSerials.insert(device.id)
      Task { await startMirror(for: device) }
      break    // one at a time; user can open more from the menubar
    }
  }

  /// Shows the placeholder when no device is connected; hides it when a
  /// real Mirror is about to take over the foreground. Safe to call repeatedly.
  func syncWaitingWindow(hasOnlineDevice: Bool) {
    let had = waitingController != nil
    log.notice("syncWaiting hasOnlineDevice=\(hasOnlineDevice) hadWaiting=\(had) mirrorCount=\(self.mirrorWindows.count)")
    if hasOnlineDevice || !mirrorWindows.isEmpty {
      // CRITICAL: if any Mirror is up, the Waiting placeholder is by
      // definition stale — close it. Without this, a Combine publish that
      // briefly drops the device list would re-summon Waiting on top of
      // a live Mirror, giving the "two windows" symptom.
      if let wc = waitingController {
        wc.window?.orderOut(nil)
        wc.close()
        waitingController = nil
      }
    } else {
      if waitingController == nil {
        let wc = WaitingMirrorWindowController()
        waitingController = wc
        wc.showWindow(nil)
      } else {
        waitingController?.window?.makeKeyAndOrderFront(nil)
      }
    }
  }

  func startMirror(for device: Device) async {
    if let existing = mirrorWindows[device.id] {
      existing.window?.makeKeyAndOrderFront(nil)
      return
    }
    let pick = try? await adb.pickActiveDisplay(serial: device.id)
    let displayId = pick?.id ?? 0
    activePanel[device.id] = (
      id: displayId,
      width: pick?.width ?? 0,
      height: pick?.height ?? 0,
      rotation: pick?.rotation ?? 0
    )
    do {
      let controller = try MirrorWindowController(deviceName: device.model.isEmpty ? device.id : device.model)
      controller.deviceSerial = device.id
      mirrorWindows[device.id] = controller
      controller.showWindow(nil)
      try await launchSession(for: device, displayId: displayId, into: controller)
      startActiveDisplayPolling(for: device)
    } catch {
      // If launch failed due to a bad display_id, clear the cache and retry with display 0.
      let errDesc = error.localizedDescription
      if errDesc.contains("display") || errDesc.contains("short read") || errDesc.contains("scrcpy") {
        log.error("launch failed for \(device.id): \(error). Retrying with displayId=0...")
        activePanel.removeValue(forKey: device.id)
        mirrorWindows[device.id]?.close()
        mirrorWindows.removeValue(forKey: device.id)
        // Retry
        do {
          let controller = try MirrorWindowController(deviceName: device.model.isEmpty ? device.id : device.model)
          controller.deviceSerial = device.id
          mirrorWindows[device.id] = controller
          try await launchSession(for: device, displayId: 0, into: controller)
          startActiveDisplayPolling(for: device)
          return
        } catch {
          // Second failure — show detailed alert
        }
      }

      let detailMsg = """
        Device: \(device.model.isEmpty ? device.id : device.model)
        SDK: \(device.androidSDK)
        State: \(device.state.rawValue)
        Transport: \(device.transport.rawValue)

        If you see a protocol error, try:
        1. Go to Settings → Advanced
        2. Click "Clean up old scrcpy-server"
        3. Reconnect the device

        Error: \(error.localizedDescription)
        """
      let alert = NSAlert()
      alert.messageText = "Failed to start Mirror"
      alert.informativeText = detailMsg
      alert.addButton(withTitle: "OK")
      alert.runModal()
      mirrorWindows[device.id]?.close()
      mirrorWindows[device.id] = nil
    }
  }

  func openFiles(for device: Device) {
    if let existing = filesWindows[device.id] {
      existing.window?.makeKeyAndOrderFront(nil)
      return
    }
    let controller = FilesWindowController(device: device)
    filesWindows[device.id] = controller
    controller.showWindow(nil)
    NotificationCenter.default.addObserver(
      forName: NSWindow.willCloseNotification,
      object: controller.window,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor [weak self] in
        self?.filesWindows.removeValue(forKey: device.id)
      }
    }
  }

  // MARK: fusion mode

  func appCatalog() -> AppCatalog {
    AppCatalog(adb: adb)
  }

  /// Open a single Android desktop on a virtual display, no specific app forced.
  /// Used by the "Desktop Mode" button — the device shows whatever its launcher
  /// (Samsung DeX / Pixel / AOSP) puts on a secondary display.
  func openDesktop(
    for device: Device,
    size: CGSize = CGSize(width: 2560, height: 1440),
    dpi: Int = 160
  ) async {
    let pseudoApp = InstalledApp(packageName: "desktop", label: "Desktop", iconPNG: nil)
    let key = fusionKey(serial: device.id, packageName: pseudoApp.packageName)
    if let existing = fusionWindows[key] {
      existing.window?.makeKeyAndOrderFront(nil)
      return
    }
    do {
      let activator = freeformActivators[device.id] ?? FreeformActivator(adb: adb)
      freeformActivators[device.id] = activator
      if freeformTokens[device.id] == nil {
        freeformTokens[device.id] = try await activator.activate(serial: device.id)
      }

      let controller = try FusionAppWindowController(appLabel: "Desktop — \(device.model.isEmpty ? device.id : device.model)")
      fusionWindows[key] = controller
      controller.showWindow(nil)

      let renderer = controller.renderer
      let resources = try ResourceLocator.scrcpyResources()
      let launcher = FusionLauncher(adb: adb, scrcpyResources: resources)
      let session = try await launcher.openDesktop(
        serial: device.id,
        size: size,
        dpi: dpi,
        frameSink: { pixelBuffer, _ in
          renderer.render(pixelBuffer: pixelBuffer)
        }
      )
      await controller.attach(session)

      NotificationCenter.default.addObserver(
        forName: NSWindow.willCloseNotification,
        object: controller.window,
        queue: .main
      ) { [weak self] _ in
        Task { @MainActor in
          await self?.fusionWindowDidClose(deviceSerial: device.id, packageName: pseudoApp.packageName)
        }
      }
    } catch {
      NSAlert(error: error).runModal()
      fusionWindows[key]?.close()
      fusionWindows[key] = nil
    }
  }

  /// Launch one Android app into its own borderless window. Activates the
  /// device-wide freeform settings on first launch per-session; the snapshot
  /// is restored when the last Fusion window for that device closes.
  func launchFusionApp(
    for device: Device,
    app: InstalledApp,
    // DeX-style desktop: 1440p landscape at ~10" tablet density. Comfortable
    // size for a Mac monitor, leaves room for several app windows within Android.
    size: CGSize = CGSize(width: 2560, height: 1440),
    dpi: Int = 160
  ) async {
    let key = fusionKey(serial: device.id, packageName: app.packageName)
    if let existing = fusionWindows[key] {
      existing.window?.makeKeyAndOrderFront(nil)
      return
    }
    do {
      let activator = freeformActivators[device.id] ?? FreeformActivator(adb: adb)
      freeformActivators[device.id] = activator
      if freeformTokens[device.id] == nil {
        freeformTokens[device.id] = try await activator.activate(serial: device.id)
      }

      let controller = try FusionAppWindowController(appLabel: app.label)
      fusionWindows[key] = controller
      controller.showWindow(nil)

      let renderer = controller.renderer
      let resources = try ResourceLocator.scrcpyResources()
      let launcher = FusionLauncher(adb: adb, scrcpyResources: resources)
      let session = try await launcher.launch(
        packageName: app.packageName,
        serial: device.id,
        size: size,
        dpi: dpi,
        frameSink: { pixelBuffer, _ in
          renderer.render(pixelBuffer: pixelBuffer)
        }
      )
      await controller.attach(session)

      NotificationCenter.default.addObserver(
        forName: NSWindow.willCloseNotification,
        object: controller.window,
        queue: .main
      ) { [weak self] _ in
        Task { @MainActor in
          await self?.fusionWindowDidClose(deviceSerial: device.id, packageName: app.packageName)
        }
      }
    } catch {
      NSAlert(error: error).runModal()
      fusionWindows[key]?.close()
      fusionWindows[key] = nil
    }
  }

  private func fusionWindowDidClose(deviceSerial: String, packageName: String) async {
    let key = fusionKey(serial: deviceSerial, packageName: packageName)
    fusionWindows.removeValue(forKey: key)
    // When the last Fusion window for this device closes, restore the global settings.
    let stillOpen = fusionWindows.keys.contains { $0.hasPrefix(deviceSerial + "|") }
    if !stillOpen,
       let token = freeformTokens.removeValue(forKey: deviceSerial),
       let activator = freeformActivators[deviceSerial] {
      await activator.deactivate(token)
    }
  }

  private func fusionKey(serial: String, packageName: String) -> String {
    "\(serial)|\(packageName)"
  }

  func stopMirror(for device: Device) async {
    pollTasks[device.id]?.cancel()
    pollTasks.removeValue(forKey: device.id)
    activePanel.removeValue(forKey: device.id)

    // If there are Fusion windows for this device, close them too so freeform
    // settings get properly restored.
    let fusionKeys = fusionWindows.keys.filter { $0.hasPrefix(device.id + "|") }
    for key in fusionKeys {
      fusionWindows[key]?.close()
      fusionWindows[key] = nil
    }

    // Restore freeform settings before tearing down the mirror session.
    if let token = freeformTokens.removeValue(forKey: device.id),
       let activator = freeformActivators[device.id] {
      await activator.deactivate(token)
    }

    guard let controller = mirrorWindows[device.id] else { return }
    await controller.session.stop()
    controller.close()
    mirrorWindows.removeValue(forKey: device.id)
  }

  // MARK: launch / relaunch

  private func launchSession(
    for device: Device,
    displayId: Int,
    into controller: MirrorWindowController
  ) async throws {
    let resources = try ResourceLocator.scrcpyResources()
    let launcher = ScrcpyServerLauncher(adb: adb, serial: device.id, resources: resources)

    // Pull video knobs from Settings so the user can dial heat ↔ smoothness.
    // Defaults match ScrcpyOptions: 4 Mbps / 30 fps / h265 — gentle on the
    // device's hardware encoder, which is the dominant heat source.
    let defaults = UserDefaults.standard
    let codec = (defaults.string(forKey: "mirror.codec") ?? "h265")
    let bitrateMbps = (defaults.object(forKey: "mirror.bitrate") as? Int) ?? 4
    let maxFps = (defaults.object(forKey: "mirror.maxFps") as? Int) ?? 30
    let audioOutput = defaults.string(forKey: "mirror.audioOutput") ?? "mac"

    let options = ScrcpyOptions(
      videoBitRate: bitrateMbps * 1_000_000,
      maxFps: maxFps,
      videoCodec: codec,
      audioCodec: "opus",
      audioEnabled: audioOutput == "mac",
      controlEnabled: true,
      displayId: displayId
    )
    try await controller.session.start(launcher: launcher, options: options)
    await controller.bindControl()
  }

  /// Tear down and re-launch the scrcpy session for `serial` without closing
  /// the mirror window.  Used when a runtime setting (audio output mode)
  /// changes and requires a new server-side configuration.  The controller's
  /// `isRestarting` flag is set by the caller so `bindControl()` can skip
  /// one-shot initialisation (auto-screen-off, audio mute, clipboard reset).
  func restartMirror(for serial: String) async {
    guard let controller = mirrorWindows[serial] else { return }
    pollTasks[serial]?.cancel()
    pollTasks[serial] = nil
    let displayId = activePanel[serial]?.id ?? 0

    let device = Device(
      id: serial,
      model: await controller.session.deviceName,
      state: .online
    )

    await controller.session.stop()

    do {
      try await launchSession(for: device, displayId: displayId, into: controller)
      startActiveDisplayPolling(for: device)
      log.notice("session restarted for \(serial)")
    } catch {
      log.error("restart failed for \(serial): \(error)")
      controller.isRestarting = false
      controller.close()
      mirrorWindows.removeValue(forKey: serial)
      activePanel.removeValue(forKey: serial)
    }
  }

  // MARK: fold/unfold polling

  private func startActiveDisplayPolling(for device: Device) {
    pollTasks[device.id]?.cancel()
    log.notice("starting display poll for \(device.id)")
    pollTasks[device.id] = Task { [weak self] in
      guard let self else { return }
      var tick = 0
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        guard !Task.isCancelled else { return }
        tick += 1
        await self.checkActiveDisplay(for: device, tick: tick)
      }
      log.notice("poll task ended for \(device.id)")
    }
  }

  /// Manually trigger a re-pick — wired to Cmd+R from the mirror window. Also
  /// useful as a fallback if our poller fails to catch a fold/rotation event.
  func refreshActiveDisplay(for device: Device) async {
    log.notice("manual refresh for \(device.id)")
    await checkActiveDisplay(for: device, tick: -1, force: true)
  }

  private func checkActiveDisplay(for device: Device, tick: Int, force: Bool = false) async {
    guard let controller = mirrorWindows[device.id] else {
      log.notice("tick \(tick): no controller — stopping poll")
      return
    }
    let displays: [DisplayInfo]
    do {
      displays = try await adb.physicalDisplays(serial: device.id)
    } catch {
      log.error("tick \(tick): physicalDisplays error: \(error)")
      return
    }
    let ranked = displays.sorted { a, b in
      if a.state.rank != b.state.rank { return a.state.rank > b.state.rank }
      return a.area > b.area
    }
    let current = activePanel[device.id]
    guard let pick = ranked.first else { return }

    // Trigger a relaunch when ANY of (id, width, height, rotation) changes:
    // - id/dims: fold/unfold on foldables, external display attach
    // - rotation: portrait↔landscape within the same physical panel
    let changed = force
      || current == nil
      || current?.id != pick.id
      || current?.width != pick.width
      || current?.height != pick.height
      || current?.rotation != pick.rotation
    guard changed else { return }
    log.notice("PANEL CHANGED -> id=\(pick.id) \(pick.width)x\(pick.height) rot=\(pick.rotation)")
    activePanel[device.id] = (id: pick.id, width: pick.width, height: pick.height, rotation: pick.rotation)
    await controller.session.stop()
    do {
      try await launchSession(for: device, displayId: pick.id, into: controller)
      log.notice("relaunch OK id=\(pick.id) \(pick.width)x\(pick.height)")
    } catch {
      log.error("relaunch failed: \(error)")
    }
  }

  // MARK: troubleshooting

  /// Force-remove leftover scrcpy-server jars from all connected devices.
  func cleanupScrcpyServers() async throws {
    let devices = try await adb.listDevices()
    let online = devices.filter { $0.state == .online }
    guard !online.isEmpty else {
      throw DroidMirroringError.deviceNotFound("No online devices found")
    }
    for device in online {
      try await adb.shell("rm -f /data/local/tmp/scrcpy-server*.jar", serial: device.id)
      log.notice("cleaned scrcpy-server on \(device.id)")
    }
  }
}

enum ResourceLocator {
  static func scrcpyResources() throws -> ScrcpyServerLauncher.Resources {
    let bundle = Bundle.main
    guard let jar = bundle.url(forResource: "scrcpy-server", withExtension: "jar")
            ?? bundle.url(forResource: "scrcpy-server-v\(ScrcpyServerVersion.current)", withExtension: "jar")
    else {
      throw DroidMirroringError.scrcpyProtocol("scrcpy-server.jar not bundled — run scripts/fetch-scrcpy-server.sh")
    }
    let adb = bundle.url(forResource: "adb", withExtension: nil) ?? URL(fileURLWithPath: "/usr/local/bin/adb")
    return .init(serverJar: jar, adbBinary: adb)
  }

  static func wirelessClient() -> ADBWirelessClient {
    let adb = Bundle.main.url(forResource: "adb", withExtension: nil) ?? URL(fileURLWithPath: "/usr/local/bin/adb")
    return ADBWirelessClient(adbBinary: adb)
  }
}
