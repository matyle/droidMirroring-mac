import Foundation
import FileProvider
import ADBKit
import SharedModels

/// Streams a single directory's contents to Finder. One enumerator per open folder.
final class DirectoryEnumerator: NSObject, NSFileProviderEnumerator {
  private let remotePath: String
  private let serial: String
  private let adb: ADBClient

  /// `remotePath == ""` means the synthetic root container — emit the DeviceRoot entries.
  init(remotePath: String, serial: String, adb: ADBClient) {
    self.remotePath = remotePath
    self.serial = serial
    self.adb = adb
  }

  func invalidate() {}

  func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
    Task {
      do {
        let items = try await fetch()
        observer.didEnumerate(items)
        observer.finishEnumerating(upTo: nil)
      } catch {
        observer.finishEnumeratingWithError(error)
      }
    }
  }

  func enumerateChanges(for observer: NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor) {
    // M3 ship without change tracking — Finder will fall back to re-enumerating
    // when the user clicks Refresh. Wire onDeviceFilesystemChange in a later iteration.
    observer.finishEnumeratingChanges(upTo: anchor, moreComing: false)
  }

  // MARK: fetch

  private func fetch() async throws -> [NSFileProviderItem] {
    if remotePath.isEmpty {
      return rootItems()
    }
    let conn = try await adb.openSyncTransport(serial: serial)
    let session = SyncSession(connection: conn)
    defer { Task { try? await session.quit() } }
    let entries = try await session.list(remotePath)
    return entries
      .filter { !FileProviderConfig.shouldFilter(filename: $0.name) }
      .map { e in
        let childPath = remotePath.hasSuffix("/") ? "\(remotePath)\(e.name)" : "\(remotePath)/\(e.name)"
        return DroidMirroringItem(entry: e, remotePath: childPath, parent: remotePath, serial: serial)
      }
  }

  /// Synthetic top-level entries — one virtual folder per `DeviceRoot`.
  /// We fabricate `SyncEntry`s for them so they render with the right capabilities.
  private func rootItems() -> [NSFileProviderItem] {
    DeviceRoot.allCases.compactMap { root -> NSFileProviderItem? in
      // Apps root is a placeholder for M3 — implementation comes later.
      guard root != .apps else { return nil }
      let entry = SyncEntry(
        mode: 0o040755,
        size: 0,
        mtime: UInt32(Date().timeIntervalSince1970),
        name: root.displayName
      )
      return DroidMirroringItem(
        entry: entry,
        remotePath: root.remoteAnchor,
        parent: nil,
        serial: serial
      )
    }
  }
}
