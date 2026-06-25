import Foundation
import AppKit
import ADBKit
import SharedModels

/// One device's files browser state. Holds the current directory listing,
/// breadcrumb path, transfer queue + progress, and the worker that talks ADB sync.
@MainActor
final class FilesViewModel: ObservableObject {
  @Published var currentPath: String
  @Published var entries: [SyncEntry] = []
  @Published var isLoading = false
  @Published var lastError: String?
  @Published var transfer: TransferState?
  @Published var installState: InstallState?

  // MARK: install state

  struct InstallState: Equatable {
    var filename: String
    var phase: Phase
    enum Phase: Equatable {
      case installing
      case succeeded(packageName: String?)
      case failed(message: String)
    }
  }

  // MARK: transfer state

  struct TransferState: Equatable {
    enum Kind: Equatable { case download, upload }
    let kind: Kind
    var queue: [String]                   // names of files queued (display only)
    var currentIndex: Int                 // 0-based index of file being transferred
    var currentName: String
    var currentBytes: UInt64
    var currentTotal: UInt64              // 0 if unknown
    var totalBytes: UInt64                // sum across whole batch
    var transferredTotal: UInt64
    var cancelled: Bool

    var fractionDone: Double {
      currentTotal == 0 ? 0 : min(1.0, Double(currentBytes) / Double(currentTotal))
    }
    var batchFraction: Double {
      totalBytes == 0 ? 0 : min(1.0, Double(transferredTotal + currentBytes) / Double(totalBytes))
    }
  }

  let device: Device
  private let adb = ADBClient()
  private let cache: SyncCache?
  private var cancelFlag = false

  init(device: Device, initialPath: String = "/sdcard") {
    self.device = device
    self.currentPath = initialPath
    self.cache = try? SyncCache(url: SyncCache.defaultURL(forSerial: device.id))
  }

  /// Quick-jump shortcuts shown in the sidebar. Mirrors common Android paths.
  static let shortcuts: [Shortcut] = [
    Shortcut(name: "Internal Storage", path: "/sdcard", systemImage: "internaldrive"),
    Shortcut(name: "Pictures",         path: "/sdcard/Pictures", systemImage: "photo.on.rectangle"),
    Shortcut(name: "DCIM",             path: "/sdcard/DCIM", systemImage: "camera"),
    Shortcut(name: "Downloads",        path: "/sdcard/Download", systemImage: "arrow.down.circle"),
    Shortcut(name: "Movies",           path: "/sdcard/Movies", systemImage: "film"),
    Shortcut(name: "Music",            path: "/sdcard/Music", systemImage: "music.note"),
    Shortcut(name: "Documents",        path: "/sdcard/Documents", systemImage: "doc"),
  ]

  struct Shortcut: Identifiable, Hashable {
    let name: String
    let path: String
    let systemImage: String
    var id: String { path }
  }

  // MARK: paths

  var pathComponents: [String] {
    currentPath.split(separator: "/").map(String.init)
  }

  var localDownloadRoot: URL {
    let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
      ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
    return downloads.appendingPathComponent("DroidMirroring").appendingPathComponent(device.id)
  }

  private func joinRemote(_ base: String, _ child: String) -> String {
    base.hasSuffix("/") ? "\(base)\(child)" : "\(base)/\(child)"
  }

  // MARK: navigation

  func load() async {
    let path = currentPath

    // 1. Serve cache instantly (if any).
    if let cache, let snapshot = await cache.snapshot(forDirectory: path) {
      entries = sort(snapshot.entries)
      isLoading = false
    } else {
      isLoading = true
    }
    lastError = nil

    // 2. Always revalidate in the background — Android-side filesystem can change
    // outside our control, and the SQLite cache should converge with reality.
    do {
      let conn = try await adb.openSyncTransport(serial: device.id)
      let session = SyncSession(connection: conn)
      let raw = try await session.list(path)
      try? await session.quit()

      // Only commit if the user hasn't navigated away while the request was
      // in flight — otherwise we'd race-overwrite the new directory's listing.
      guard currentPath == path else { return }
      entries = sort(raw)
      await cache?.replace(directory: path, with: raw)
    } catch {
      lastError = "\(error)"
      if entries.isEmpty { entries = [] }
    }
    isLoading = false
  }

  private func sort(_ raw: [SyncEntry]) -> [SyncEntry] {
    raw.sorted { lhs, rhs in
      if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
      return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
    }
  }

  /// Drop the cached listing for a path. Called after mutations (upload, delete,
  /// rename) so the next `load()` always goes back to the device.
  private func invalidate(_ path: String) async {
    await cache?.invalidate(directory: path)
  }

  func enter(_ entry: SyncEntry) async {
    guard entry.isDirectory else { return }
    currentPath = joinRemote(currentPath, entry.name)
    await load()
  }

  func goUp() async {
    guard currentPath != "/" else { return }
    let parent = (currentPath as NSString).deletingLastPathComponent
    currentPath = parent.isEmpty ? "/" : parent
    await load()
  }

  func go(to absolutePath: String) async {
    currentPath = absolutePath.isEmpty ? "/" : absolutePath
    await load()
  }

  // MARK: download (single entry — file or folder)

  func download(_ entries: [SyncEntry]) async {
    cancelFlag = false
    do {
      try FileManager.default.createDirectory(at: localDownloadRoot, withIntermediateDirectories: true)
    } catch {
      lastError = "Create local dir failed: \(error)"
      return
    }

    // Flatten the selection: walk any folder remotely, collect a flat list of files
    // plus the directory entries (so we can mkdir locally in the right order).
    var queue: [DownloadItem] = []
    var totalBytes: UInt64 = 0
    do {
      let walkConn = try await adb.openSyncTransport(serial: device.id)
      let walkSession = SyncSession(connection: walkConn)
      for entry in entries {
        let remote = joinRemote(currentPath, entry.name)
        if entry.isDirectory {
          queue.append(.dir(relative: entry.name, remote: remote))
          let sub = try await walkSession.listRecursive(remote)
          for (rel, e) in sub {
            let childRemote = "\(remote)/\(rel)"
            let childRelative = "\(entry.name)/\(rel)"
            if e.isDirectory {
              queue.append(.dir(relative: childRelative, remote: childRemote))
            } else if e.isFile {
              queue.append(.file(relative: childRelative, remote: childRemote, size: UInt64(e.size)))
              totalBytes += UInt64(e.size)
            }
          }
        } else if entry.isFile {
          queue.append(.file(relative: entry.name, remote: remote, size: UInt64(entry.size)))
          totalBytes += UInt64(entry.size)
        }
      }
      try? await walkSession.quit()
    } catch {
      lastError = "Walk failed: \(error)"
      return
    }

    let fileCount = queue.filter { if case .file = $0 { return true } else { return false } }.count
    let fileNames = queue.compactMap { item -> String? in
      if case .file(let rel, _, _) = item { return rel } else { return nil }
    }

    transfer = TransferState(
      kind: .download,
      queue: fileNames,
      currentIndex: 0,
      currentName: "",
      currentBytes: 0,
      currentTotal: 0,
      totalBytes: totalBytes,
      transferredTotal: 0,
      cancelled: false
    )
    defer { transfer = nil }

    var index = 0
    do {
      let conn = try await adb.openSyncTransport(serial: device.id)
      let session = SyncSession(connection: conn)
      for item in queue {
        if cancelFlag { transfer?.cancelled = true; break }
        switch item {
        case .dir(let relative, _):
          let localDir = localDownloadRoot.appendingPathComponent(relative)
          try FileManager.default.createDirectory(at: localDir, withIntermediateDirectories: true)
        case .file(let relative, let remote, let size):
          let localFile = localDownloadRoot.appendingPathComponent(relative)
          try FileManager.default.createDirectory(
            at: localFile.deletingLastPathComponent(), withIntermediateDirectories: true)
          transfer?.currentIndex = index
          transfer?.currentName = relative
          transfer?.currentTotal = size
          transfer?.currentBytes = 0
          try await session.recv(remote, into: localFile, total: size) { [weak self] bytes, _ in
            Task { @MainActor in
              guard let self else { return }
              self.transfer?.currentBytes = bytes
            }
          }
          transfer?.transferredTotal += size
          index += 1
        }
      }
      try? await session.quit()
    } catch {
      lastError = "Download failed: \(error)"
      return
    }

    // Reveal in Finder when done (only the first selected item, à la Safari downloads).
    if let first = entries.first {
      let revealURL = localDownloadRoot.appendingPathComponent(first.name)
      NSWorkspace.shared.activateFileViewerSelecting([revealURL])
    }
    _ = fileCount  // silence unused if no files transferred
  }

  private enum DownloadItem {
    case dir(relative: String, remote: String)
    case file(relative: String, remote: String, size: UInt64)
  }

  // MARK: upload (file OR folder)

  func upload(localURLs: [URL]) async {
    cancelFlag = false
    var queue: [UploadItem] = []
    var totalBytes: UInt64 = 0
    for url in localURLs {
      var isDir: ObjCBool = false
      guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
      let name = url.lastPathComponent
      if isDir.boolValue {
        queue.append(.dir(relative: name, remote: joinRemote(currentPath, name)))
        let walked = Self.walkLocal(root: url, namePrefix: name)
        for (rel, childURL, isChildDir, size) in walked {
          let remote = joinRemote(currentPath, rel)
          if isChildDir {
            queue.append(.dir(relative: rel, remote: remote))
          } else {
            queue.append(.file(local: childURL, relative: rel, remote: remote, size: size))
            totalBytes += size
          }
        }
      } else {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64) ?? 0
        queue.append(.file(local: url, relative: name, remote: joinRemote(currentPath, name), size: size))
        totalBytes += size
      }
    }

    let fileNames = queue.compactMap { item -> String? in
      if case .file(_, let rel, _, _) = item { return rel } else { return nil }
    }

    transfer = TransferState(
      kind: .upload,
      queue: fileNames,
      currentIndex: 0,
      currentName: "",
      currentBytes: 0,
      currentTotal: 0,
      totalBytes: totalBytes,
      transferredTotal: 0,
      cancelled: false
    )
    defer { transfer = nil }

    var index = 0
    do {
      let conn = try await adb.openSyncTransport(serial: device.id)
      let session = SyncSession(connection: conn)
      for item in queue {
        if cancelFlag { transfer?.cancelled = true; break }
        switch item {
        case .dir(_, let remote):
          let escaped = remote.replacingOccurrences(of: "'", with: "'\\''")
          // mkdir -p needs a separate shell session — close sync first.
          try? await session.quit()
          _ = try await adb.shell("mkdir -p '\(escaped)'", serial: device.id)
          // Reopen sync.
          let newConn = try await adb.openSyncTransport(serial: device.id)
          // Replace `session` is tricky in an actor-immutable local — workaround:
          _ = newConn  // we'll just continue with the next item using a fresh per-file session
        case .file(let local, let relative, let remote, let size):
          transfer?.currentIndex = index
          transfer?.currentName = relative
          transfer?.currentTotal = size
          transfer?.currentBytes = 0
          // Each file gets its own session — simpler than juggling reopens across dir mkdirs.
          let perFileConn = try await adb.openSyncTransport(serial: device.id)
          let perFileSession = SyncSession(connection: perFileConn)
          try await perFileSession.send(local, to: remote) { [weak self] bytes, _ in
            Task { @MainActor in
              guard let self else { return }
              self.transfer?.currentBytes = bytes
            }
          }
          try? await perFileSession.quit()
          transfer?.transferredTotal += size
          index += 1
        }
      }
      try? await session.quit()
    } catch {
      lastError = "Upload failed: \(error)"
      return
    }
    await invalidate(currentPath)
    await load()
  }

  private enum UploadItem {
    case dir(relative: String, remote: String)
    case file(local: URL, relative: String, remote: String, size: UInt64)
  }

  /// Synchronous local directory walk. FileManager.DirectoryEnumerator's iterator
  /// isn't available from async contexts, so we collect in a sync helper and
  /// hand the array back to the async caller.
  nonisolated private static func walkLocal(
    root: URL, namePrefix: String
  ) -> [(relative: String, url: URL, isDir: Bool, size: UInt64)] {
    guard let walker = FileManager.default.enumerator(
      at: root, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey])
    else { return [] }
    var results: [(String, URL, Bool, UInt64)] = []
    for case let childURL as URL in walker {
      let resourceValues = try? childURL.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
      let rel = namePrefix + "/" + childURL.path.replacingOccurrences(of: root.path + "/", with: "")
      let isDir = resourceValues?.isDirectory == true
      let size = UInt64(resourceValues?.fileSize ?? 0)
      results.append((rel, childURL, isDir, size))
    }
    return results
  }

  // MARK: mkdir

  /// Create a new directory under `currentPath`. Picks a unique name if the
  /// caller didn't supply one (mirrors Finder's "untitled folder N").
  func makeDirectory(named requestedName: String? = nil) async {
    let name = requestedName ?? uniqueFolderName()
    guard !name.isEmpty else { return }
    let remote = joinRemote(currentPath, name)
    let escaped = remote.replacingOccurrences(of: "'", with: "'\\''")
    do {
      let output = try await adb.shell("mkdir '\(escaped)' && echo OK || echo FAIL", serial: device.id)
      guard output.contains("OK") else {
        lastError = "mkdir failed: \(output.trimmingCharacters(in: .whitespacesAndNewlines))"
        return
      }
    } catch {
      lastError = "mkdir failed: \(error)"
      return
    }
    await invalidate(currentPath)
    await load()
  }

  /// "untitled folder", "untitled folder 2", … — picks the first name not in
  /// the current listing.
  private func uniqueFolderName() -> String {
    let existing = Set(entries.map(\.name))
    let base = "untitled folder"
    if !existing.contains(base) { return base }
    for i in 2...9_999 {
      let candidate = "\(base) \(i)"
      if !existing.contains(candidate) { return candidate }
    }
    return base
  }

  // MARK: rename

  func rename(_ entry: SyncEntry, to newName: String) async {
    let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    guard trimmed != entry.name else { return }
    guard !trimmed.contains("/") else {
      lastError = "Name can't contain '/'."
      return
    }
    let source = joinRemote(currentPath, entry.name)
    let destination = joinRemote(currentPath, trimmed)
    let src = source.replacingOccurrences(of: "'", with: "'\\''")
    let dst = destination.replacingOccurrences(of: "'", with: "'\\''")
    do {
      let output = try await adb.shell("mv '\(src)' '\(dst)' && echo OK || echo FAIL", serial: device.id)
      guard output.contains("OK") else {
        lastError = "Rename failed: \(output.trimmingCharacters(in: .whitespacesAndNewlines))"
        return
      }
    } catch {
      lastError = "Rename failed: \(error)"
      return
    }
    await invalidate(currentPath)
    await load()
  }

  // MARK: delete

  func delete(_ entries: [SyncEntry]) async {
    for entry in entries {
      let remote = joinRemote(currentPath, entry.name)
      let escaped = remote.replacingOccurrences(of: "'", with: "'\\''")
      do {
        _ = try await adb.shell("rm -rf '\(escaped)'", serial: device.id)
      } catch {
        lastError = "Delete failed (\(entry.name)): \(error)"
      }
    }
    await invalidate(currentPath)
    await load()
  }

  // MARK: cancel

  func cancelTransfer() {
    cancelFlag = true
  }

  // MARK: install (APK / XAPK)

  /// Installs an APK (or XAPK split bundle) onto the connected device via
  /// `adb install`. UI state transitions through `installState`; the toast
  /// auto-dismisses ~3s after a terminal state.
  func installAPK(_ localURL: URL) async {
    let filename = localURL.lastPathComponent
    installState = InstallState(filename: filename, phase: .installing)

    let adbBinary = Bundle.main.url(forResource: "adb", withExtension: nil)
      ?? URL(fileURLWithPath: "/usr/local/bin/adb")
    let installer = ADBInstaller(adbBinary: adbBinary)

    do {
      let pkg = try await installer.install(localURL: localURL, serial: device.id, replace: true)
      installState = InstallState(filename: filename, phase: .succeeded(packageName: pkg))
    } catch let err as ADBInstaller.InstallError {
      installState = InstallState(filename: filename, phase: .failed(message: humanInstallError(err)))
    } catch {
      installState = InstallState(filename: filename, phase: .failed(message: "\(error)"))
    }

    // Snapshot identity so a follow-up install doesn't accidentally clear a fresher toast.
    let snapshot = installState
    Task { [weak self] in
      try? await Task.sleep(nanoseconds: 3_000_000_000)
      guard let self else { return }
      if self.installState == snapshot {
        self.installState = nil
      }
    }
  }

  private func humanInstallError(_ err: ADBInstaller.InstallError) -> String {
    switch err {
    case .adbMissing:                 return "Bundled adb binary missing"
    case .unsupportedFileType(let s): return "Unsupported file type: .\(s)"
    case .alreadyInstalled:           return "App already installed"
    case .versionDowngrade:           return "Newer version already on device"
    case .incompatible(let code):     return "Install rejected: \(code)"
    case .adbStderr(let s):           return s.isEmpty ? "adb error" : s
    }
  }
}
