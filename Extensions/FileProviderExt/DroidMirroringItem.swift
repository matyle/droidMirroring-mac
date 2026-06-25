import Foundation
import FileProvider
import UniformTypeIdentifiers
import ADBKit
import SharedModels

/// One Android filesystem entry exposed to Finder. Built from a `SyncEntry` plus
/// the device-relative remote path we use as the stable item identifier.
final class DroidMirroringItem: NSObject, NSFileProviderItem {
  let entry: SyncEntry
  let remotePath: String
  let parentRemotePath: String?
  let serial: String

  init(entry: SyncEntry, remotePath: String, parent: String?, serial: String) {
    self.entry = entry
    self.remotePath = remotePath
    self.parentRemotePath = parent
    self.serial = serial
    super.init()
  }

  // MARK: NSFileProviderItem

  var itemIdentifier: NSFileProviderItemIdentifier {
    NSFileProviderItemIdentifier(rawValue: remotePath)
  }

  var parentItemIdentifier: NSFileProviderItemIdentifier {
    guard let parent = parentRemotePath else { return .rootContainer }
    return NSFileProviderItemIdentifier(rawValue: parent)
  }

  var filename: String { entry.name }

  var contentType: UTType {
    if entry.isDirectory { return .folder }
    if entry.isSymlink   { return .symbolicLink }
    let ext = (entry.name as NSString).pathExtension
    if !ext.isEmpty, let t = UTType(filenameExtension: ext) { return t }
    return .data
  }

  /// Version bumps when the file changes — FileProvider uses this to know
  /// whether the cached pulled copy is stale.
  var itemVersion: NSFileProviderItemVersion {
    var contentBytes = Data()
    contentBytes.append(contentsOf: withUnsafeBytes(of: entry.mtime.bigEndian) { Array($0) })
    contentBytes.append(contentsOf: withUnsafeBytes(of: entry.size.bigEndian)  { Array($0) })
    var metaBytes = Data()
    metaBytes.append(contentsOf: withUnsafeBytes(of: entry.mode.bigEndian) { Array($0) })
    return NSFileProviderItemVersion(contentVersion: contentBytes, metadataVersion: metaBytes)
  }

  var documentSize: NSNumber? {
    entry.isDirectory ? nil : NSNumber(value: entry.size)
  }

  var capabilities: NSFileProviderItemCapabilities {
    if entry.isDirectory {
      return [.allowsReading, .allowsAddingSubItems, .allowsContentEnumerating, .allowsDeleting, .allowsRenaming]
    }
    return [.allowsReading, .allowsWriting, .allowsDeleting, .allowsRenaming]
  }

  var contentModificationDate: Date? {
    Date(timeIntervalSince1970: TimeInterval(entry.mtime))
  }

  var creationDate: Date? { contentModificationDate }
}
