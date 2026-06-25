import FileProvider
import Foundation
import ADBKit
import SharedModels

final class FileProviderExtension: NSObject, NSFileProviderReplicatedExtension {
  let domain: NSFileProviderDomain
  let serial: String
  let adb: ADBClient

  required init(domain: NSFileProviderDomain) {
    self.domain = domain
    self.serial = FileProviderConfig.serial(fromDomain: domain.identifier) ?? domain.identifier.rawValue
    self.adb = ADBClient()
    super.init()
  }

  func invalidate() {}

  // MARK: item

  func item(
    for identifier: NSFileProviderItemIdentifier,
    request: NSFileProviderRequest,
    completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void
  ) -> Progress {
    let progress = Progress(totalUnitCount: 1)
    Task {
      defer { progress.completedUnitCount = 1 }
      if identifier == .rootContainer {
        completionHandler(rootItemStub(), nil)
        return
      }
      let remotePath = identifier.rawValue
      let parent = (remotePath as NSString).deletingLastPathComponent
      do {
        let conn = try await self.adb.openSyncTransport(serial: self.serial)
        let session = SyncSession(connection: conn)
        let entry = try await session.stat(remotePath)
        try? await session.quit()
        let item = DroidMirroringItem(
          entry: entry,
          remotePath: remotePath,
          parent: parent.isEmpty ? nil : parent,
          serial: self.serial
        )
        completionHandler(item, nil)
      } catch {
        completionHandler(nil, error)
      }
    }
    return progress
  }

  /// The root container doesn't really exist on the device, but FileProvider
  /// requires us to return *something* for `.rootContainer`.
  private func rootItemStub() -> NSFileProviderItem {
    let entry = SyncEntry(mode: 0o040755, size: 0, mtime: UInt32(Date().timeIntervalSince1970), name: domain.displayName)
    return DroidMirroringItem(entry: entry, remotePath: "", parent: nil, serial: serial)
  }

  // MARK: enumerator

  func enumerator(
    for containerItemIdentifier: NSFileProviderItemIdentifier,
    request: NSFileProviderRequest
  ) throws -> NSFileProviderEnumerator {
    let remotePath = (containerItemIdentifier == .rootContainer) ? "" : containerItemIdentifier.rawValue
    return DirectoryEnumerator(remotePath: remotePath, serial: serial, adb: adb)
  }

  // MARK: fetchContents

  func fetchContents(
    for itemIdentifier: NSFileProviderItemIdentifier,
    version requestedVersion: NSFileProviderItemVersion?,
    request: NSFileProviderRequest,
    completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void
  ) -> Progress {
    let progress = Progress(totalUnitCount: 1)
    let remotePath = itemIdentifier.rawValue
    Task {
      defer { progress.completedUnitCount = 1 }
      do {
        let conn = try await self.adb.openSyncTransport(serial: self.serial)
        let session = SyncSession(connection: conn)
        let entry = try await session.stat(remotePath)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("droidmirroring-fp-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let local = dir.appendingPathComponent((remotePath as NSString).lastPathComponent)
        // Reuse the same sync session for stat + recv (saves a round-trip).
        try await session.recv(remotePath, into: local)
        try? await session.quit()
        let parent = (remotePath as NSString).deletingLastPathComponent
        let item = DroidMirroringItem(
          entry: entry,
          remotePath: remotePath,
          parent: parent.isEmpty ? nil : parent,
          serial: self.serial
        )
        completionHandler(local, item, nil)
      } catch {
        completionHandler(nil, nil, error)
      }
    }
    return progress
  }

  // MARK: createItem

  func createItem(
    basedOn itemTemplate: NSFileProviderItem,
    fields: NSFileProviderItemFields,
    contents url: URL?,
    options: NSFileProviderCreateItemOptions = [],
    request: NSFileProviderRequest,
    completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void
  ) -> Progress {
    let progress = Progress(totalUnitCount: 1)
    let filename = itemTemplate.filename
    // Drop macOS shell droppings before they hit the device.
    if FileProviderConfig.shouldFilter(filename: filename) {
      progress.completedUnitCount = 1
      completionHandler(nil, [], false, NSError(domain: NSFileProviderErrorDomain,
                                                code: NSFileProviderError.noSuchItem.rawValue))
      return progress
    }
    let parentId = itemTemplate.parentItemIdentifier
    let parentPath = (parentId == .rootContainer) ? "" : parentId.rawValue
    let remotePath = parentPath.isEmpty ? "/\(filename)" : "\(parentPath)/\(filename)"

    Task {
      defer { progress.completedUnitCount = 1 }
      do {
        let conn = try await self.adb.openSyncTransport(serial: self.serial)
        let session = SyncSession(connection: conn)
        if itemTemplate.contentType == .folder {
          // adb sync has no "create empty dir" — use shell mkdir -p in a fresh transport.
          try? await session.quit()
          _ = try await self.adb.shell("mkdir -p '\(remotePath.replacingOccurrences(of: "'", with: "'\\''"))'", serial: self.serial)
        } else if let url {
          try await session.send(url, to: remotePath)
          try? await session.quit()
        } else {
          // Empty file: create on disk, push.
          let empty = FileManager.default.temporaryDirectory.appendingPathComponent("empty-\(UUID().uuidString)")
          FileManager.default.createFile(atPath: empty.path, contents: nil)
          try await session.send(empty, to: remotePath)
          try? FileManager.default.removeItem(at: empty)
          try? await session.quit()
        }

        // Re-stat to get the real mode/mtime that landed.
        let conn2 = try await self.adb.openSyncTransport(serial: self.serial)
        let session2 = SyncSession(connection: conn2)
        let entry = try await session2.stat(remotePath)
        try? await session2.quit()
        let item = DroidMirroringItem(
          entry: entry,
          remotePath: remotePath,
          parent: parentPath.isEmpty ? nil : parentPath,
          serial: self.serial
        )
        completionHandler(item, [], false, nil)
      } catch {
        completionHandler(nil, [], false, error)
      }
    }
    return progress
  }

  // MARK: modifyItem

  func modifyItem(
    _ item: NSFileProviderItem,
    baseVersion version: NSFileProviderItemVersion,
    changedFields: NSFileProviderItemFields,
    contents newContents: URL?,
    options: NSFileProviderModifyItemOptions = [],
    request: NSFileProviderRequest,
    completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void
  ) -> Progress {
    let progress = Progress(totalUnitCount: 1)
    let remotePath = item.itemIdentifier.rawValue
    Task {
      defer { progress.completedUnitCount = 1 }
      do {
        let conn = try await self.adb.openSyncTransport(serial: self.serial)
        let session = SyncSession(connection: conn)
        if let url = newContents {
          try await session.send(url, to: remotePath)
        }
        let entry = try await session.stat(remotePath)
        try? await session.quit()
        let parent = (remotePath as NSString).deletingLastPathComponent
        let updated = DroidMirroringItem(
          entry: entry,
          remotePath: remotePath,
          parent: parent.isEmpty ? nil : parent,
          serial: self.serial
        )
        completionHandler(updated, [], false, nil)
      } catch {
        completionHandler(nil, [], false, error)
      }
    }
    return progress
  }

  // MARK: deleteItem

  func deleteItem(
    identifier: NSFileProviderItemIdentifier,
    baseVersion version: NSFileProviderItemVersion,
    options: NSFileProviderDeleteItemOptions = [],
    request: NSFileProviderRequest,
    completionHandler: @escaping (Error?) -> Void
  ) -> Progress {
    let progress = Progress(totalUnitCount: 1)
    let path = identifier.rawValue.replacingOccurrences(of: "'", with: "'\\''")
    Task {
      defer { progress.completedUnitCount = 1 }
      do {
        _ = try await self.adb.shell("rm -rf '\(path)'", serial: self.serial)
        completionHandler(nil)
      } catch {
        completionHandler(error)
      }
    }
    return progress
  }
}
