import Foundation
import SharedModels

/// adb sync wire protocol.
///
/// Once the parent connection has sent `sync:` and read OKAY, every subsequent
/// message is framed as:
///   [4-byte ASCII id][4-byte LE u32 length][length bytes payload]
///
/// IMPORTANT: sync sub-protocol uses **little-endian** integers, *not* the ASCII
/// hex framing that the host service uses. Get this wrong and you'll spend an
/// afternoon staring at a hex dump.
///
/// Reference: https://android.googlesource.com/platform/system/core/+/master/adb/SYNC.TXT
public enum SyncCommand: String, Sendable {
  case stat = "STAT"   // stat one path
  case list = "LIST"   // list directory entries
  case send = "SEND"   // upload file
  case recv = "RECV"   // download file
  case data = "DATA"   // chunk of file contents (used within send/recv)
  case done = "DONE"   // end of stream marker (also: last-chunk for SEND with mtime)
  case okay = "OKAY"   // SEND finished ok
  case fail = "FAIL"   // error, followed by message
  case dent = "DENT"   // one LIST entry
  case quit = "QUIT"   // end sync session
}

public struct SyncEntry: Sendable, Equatable {
  public let mode: UInt32
  public let size: UInt32
  public let mtime: UInt32
  public let name: String

  public var isDirectory: Bool { (mode & 0o170000) == 0o040000 }
  public var isFile: Bool { (mode & 0o170000) == 0o100000 }
  public var isSymlink: Bool { (mode & 0o170000) == 0o120000 }

  public init(mode: UInt32, size: UInt32, mtime: UInt32, name: String) {
    self.mode = mode
    self.size = size
    self.mtime = mtime
    self.name = name
  }
}

/// Reports bytes transferred / total during sync recv/send.
/// `total` is nil when we don't know up-front (rare — STAT before recv gives it).
public typealias SyncProgress = @Sendable (_ bytes: UInt64, _ total: UInt64?) -> Void

/// High-level sync session bound to one device. Open with
/// `ADBClient.openSyncTransport(serial:)` → wrap in `SyncSession(connection:)`.
public actor SyncSession {
  private let conn: ADBConnection
  private var closed = false

  /// Max chunk size adb supports in a single DATA frame. Larger payloads must be
  /// split. The wire protocol caps this at 64 KiB on older devices; modern adb
  /// uses 1 MiB. Going with 64 KiB is the safe lowest common denominator.
  public static let maxChunk = 64 * 1024

  public init(connection: ADBConnection) {
    self.conn = connection
  }

  // MARK: LIST

  /// Enumerate one directory. Returns all `DENT` entries until the trailing `DONE`.
  /// Empty array == empty directory (server still sends DONE).
  public func list(_ remotePath: String) async throws -> [SyncEntry] {
    try await sendFrame(.list, payload: Data(remotePath.utf8))
    var entries: [SyncEntry] = []
    while true {
      let id = try await readID()
      switch id {
      case .dent:
        let mode = try await readLEUInt32()
        let size = try await readLEUInt32()
        let mtime = try await readLEUInt32()
        let nameLen = try await readLEUInt32()
        let name = try await readUTF8(length: Int(nameLen))
        if name != "." && name != ".." {
          entries.append(SyncEntry(mode: mode, size: size, mtime: mtime, name: name))
        }
      case .done:
        _ = try await conn.readExact(16)  // 16 bytes of trailing zeros
        return entries
      case .fail:
        throw try await readFail()
      default:
        throw DroidMirroringError.adbProtocol("LIST: unexpected id \(id.rawValue)")
      }
    }
  }

  /// Recursive variant — depth-first walk from `remotePath`. Yields every file +
  /// directory under it as `(relativePath, entry)` tuples, where `relativePath`
  /// is relative to the original path (e.g. `"sub/foo.jpg"`).
  ///
  /// Directories are yielded BEFORE their children so callers can `mkdir` first.
  public func listRecursive(_ remotePath: String) async throws -> [(String, SyncEntry)] {
    var results: [(String, SyncEntry)] = []
    try await walk(absolute: remotePath, relative: "", into: &results)
    return results
  }

  private func walk(absolute: String, relative: String, into results: inout [(String, SyncEntry)]) async throws {
    let entries = try await list(absolute)
    for entry in entries {
      let childRel = relative.isEmpty ? entry.name : "\(relative)/\(entry.name)"
      let childAbs = absolute.hasSuffix("/") ? "\(absolute)\(entry.name)" : "\(absolute)/\(entry.name)"
      results.append((childRel, entry))
      if entry.isDirectory {
        try await walk(absolute: childAbs, relative: childRel, into: &results)
      }
    }
  }

  // MARK: STAT

  public func stat(_ remotePath: String) async throws -> SyncEntry {
    try await sendFrame(.stat, payload: Data(remotePath.utf8))
    let id = try await readID()
    guard id == .stat else {
      throw DroidMirroringError.adbProtocol("STAT: unexpected id \(id.rawValue)")
    }
    let mode = try await readLEUInt32()
    let size = try await readLEUInt32()
    let mtime = try await readLEUInt32()
    let name = (remotePath as NSString).lastPathComponent
    return SyncEntry(mode: mode, size: size, mtime: mtime, name: name)
  }

  // MARK: RECV (pull)

  /// Download `remotePath` into `local` (atomic write via temp file then rename).
  /// Throws on protocol error or partial transfer.
  ///
  /// `total` is the expected size (from STAT) — pass it for percentage display.
  /// `progress` fires after every DATA chunk; the closure must be fast (no UI work).
  public func recv(
    _ remotePath: String,
    into local: URL,
    total: UInt64? = nil,
    progress: SyncProgress? = nil
  ) async throws {
    try await sendFrame(.recv, payload: Data(remotePath.utf8))
    let tmp = local.appendingPathExtension("partial-\(UInt64.random(in: 0..<UInt64.max))")
    FileManager.default.createFile(atPath: tmp.path, contents: nil)
    guard let handle = try? FileHandle(forWritingTo: tmp) else {
      throw DroidMirroringError.fileTransfer("cannot open \(tmp.path) for writing")
    }
    defer { try? handle.close() }

    var transferred: UInt64 = 0
    while true {
      let id = try await readID()
      switch id {
      case .data:
        let len = try await readLEUInt32()
        guard len > 0 else { continue }
        let chunk = try await conn.readExact(Int(len))
        try handle.write(contentsOf: chunk)
        transferred += UInt64(chunk.count)
        progress?(transferred, total)
      case .done:
        _ = try await conn.readExact(4)   // DONE has 4 zero bytes (no size field)
        try handle.close()
        if FileManager.default.fileExists(atPath: local.path) {
          try FileManager.default.removeItem(at: local)
        }
        try FileManager.default.moveItem(at: tmp, to: local)
        return
      case .fail:
        try? handle.close()
        try? FileManager.default.removeItem(at: tmp)
        throw try await readFail()
      default:
        try? handle.close()
        try? FileManager.default.removeItem(at: tmp)
        throw DroidMirroringError.adbProtocol("RECV: unexpected id \(id.rawValue)")
      }
    }
  }

  // MARK: SEND (push)

  /// Upload `local` to `remotePath` with given POSIX `mode` (default 0644).
  /// Streams the file in <=64 KiB chunks then closes with DONE + mtime.
  public func send(
    _ local: URL,
    to remotePath: String,
    mode: UInt32 = 0o644,
    progress: SyncProgress? = nil
  ) async throws {
    // SEND header payload: "<path>,<mode-as-decimal>"
    let header = "\(remotePath),\(mode)"
    try await sendFrame(.send, payload: Data(header.utf8))

    guard let handle = try? FileHandle(forReadingFrom: local) else {
      throw DroidMirroringError.fileTransfer("cannot open \(local.path) for reading")
    }
    defer { try? handle.close() }

    let total = (try? FileManager.default.attributesOfItem(atPath: local.path)[.size] as? UInt64)
    var transferred: UInt64 = 0
    while true {
      let chunk = try handle.read(upToCount: Self.maxChunk) ?? Data()
      if chunk.isEmpty { break }
      try await sendFrame(.data, payload: chunk)
      transferred += UInt64(chunk.count)
      progress?(transferred, total)
    }

    // DONE,<mtime>. mtime is encoded in the message's length field.
    let attrs = (try? FileManager.default.attributesOfItem(atPath: local.path)) ?? [:]
    let mtime = UInt32((attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? Date().timeIntervalSince1970)
    var header2 = Data(SyncCommand.done.rawValue.utf8)
    header2.appendLE(UInt32: mtime)
    try await conn.write(header2)

    let reply = try await readID()
    switch reply {
    case .okay:
      _ = try await conn.readExact(4)
    case .fail:
      throw try await readFail()
    default:
      throw DroidMirroringError.adbProtocol("SEND: unexpected reply \(reply.rawValue)")
    }
  }

  // MARK: QUIT

  public func quit() async throws {
    guard !closed else { return }
    try? await sendFrame(.quit, payload: Data())
    closed = true
    await conn.close()
  }

  // MARK: helpers — every sync frame is `id (4 ASCII) + LE u32 length + bytes`

  private func sendFrame(_ id: SyncCommand, payload: Data) async throws {
    var frame = Data(id.rawValue.utf8)
    frame.appendLE(UInt32: UInt32(payload.count))
    frame.append(payload)
    try await conn.write(frame)
  }

  private func readID() async throws -> SyncCommand {
    let raw = try await conn.readExact(4)
    guard let s = String(data: raw, encoding: .ascii),
          let cmd = SyncCommand(rawValue: s) else {
      throw DroidMirroringError.adbProtocol("sync: bad id bytes \(raw as NSData)")
    }
    return cmd
  }

  private func readLEUInt32() async throws -> UInt32 {
    let bytes = try await conn.readExact(4)
    return bytes.withUnsafeBytes { $0.load(as: UInt32.self) }.littleEndian
  }

  private func readUTF8(length: Int) async throws -> String {
    let bytes = try await conn.readExact(length)
    return String(data: bytes, encoding: .utf8) ?? ""
  }

  /// Read FAIL message body (already consumed the 4-byte FAIL id).
  private func readFail() async throws -> Error {
    let len = try await readLEUInt32()
    let msg = try await readUTF8(length: Int(len))
    return DroidMirroringError.adbProtocol("sync FAIL: \(msg)")
  }
}

// MARK: data helpers

internal extension Data {
  mutating func appendLE(UInt32 v: UInt32) {
    var le = v.littleEndian
    Swift.withUnsafeBytes(of: &le) { append(contentsOf: $0) }
  }
}
