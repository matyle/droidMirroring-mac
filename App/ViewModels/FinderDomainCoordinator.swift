import Foundation
import Combine
import FileProvider
import AppKit
import DeviceDiscovery
import SharedModels

/// Bridges DeviceMonitor → NSFileProviderManager: every online device gets a
/// Finder sidebar entry; when it disconnects we remove the domain.
///
/// FileProvider stores nothing of value for offline devices, so we don't try
/// to be clever about persistence — a clean add/remove on each device transition.
@MainActor
final class FinderDomainCoordinator: ObservableObject {
  static let shared = FinderDomainCoordinator()

  private var cancellable: AnyCancellable?
  private var registered: Set<String> = []     // serials currently registered

  func start(monitor: DeviceMonitor) {
    cancellable = monitor.$devices
      .removeDuplicates()
      .sink { [weak self] devices in
        Task { @MainActor in self?.reconcile(devices: devices) }
      }
  }

  func stop() {
    cancellable?.cancel()
    cancellable = nil
    Task { await removeAll() }
  }

  private func reconcile(devices: [Device]) {
    let online = devices.filter { $0.state == .online }
    let onlineSerials = Set(online.map(\.id))
    let toAdd = online.filter { !registered.contains($0.id) }
    let toRemove = registered.subtracting(onlineSerials)

    for device in toAdd {
      Task { await add(device) }
    }
    for serial in toRemove {
      Task { await remove(serial: serial) }
    }
  }

  private func add(_ device: Device) async {
    let id = FileProviderConfig.domainIdentifier(forSerial: device.id)
    let display = device.model.isEmpty ? device.id : device.model
    let domain = NSFileProviderDomain(identifier: id, displayName: display)
    do {
      try await NSFileProviderManager.add(domain)
      registered.insert(device.id)
      print("[finder] added domain \(id.rawValue) (\(display))")
    } catch {
      print("[finder] add domain failed: \(error)")
    }
  }

  private func remove(serial: String) async {
    let id = FileProviderConfig.domainIdentifier(forSerial: serial)
    let domain = NSFileProviderDomain(identifier: id, displayName: serial)
    do {
      try await NSFileProviderManager.remove(domain)
      registered.remove(serial)
      print("[finder] removed domain \(id.rawValue)")
    } catch {
      print("[finder] remove domain failed: \(error)")
    }
  }

  private func removeAll() async {
    for serial in registered { await remove(serial: serial) }
  }

  /// Reveal the device's Finder folder in a new Finder window.
  func openInFinder(device: Device) async {
    let id = FileProviderConfig.domainIdentifier(forSerial: device.id)
    do {
      let manager = NSFileProviderManager(for: NSFileProviderDomain(identifier: id, displayName: device.model))
      guard let manager else { return }
      let url = try await manager.getUserVisibleURL(for: .rootContainer)
      NSWorkspace.shared.activateFileViewerSelecting([url])
    } catch {
      NSAlert(error: error).runModal()
    }
  }
}
