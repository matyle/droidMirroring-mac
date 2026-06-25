import Foundation
import SQLite3
import SharedModels

/// On-disk LRU-ish cache of `SyncSession.list` results. Lets the file browser
/// re-show a directory instantly on backtrack while a background refresh
/// reconciles anything that changed.
///
/// Implementation notes:
/// - Uses the C `sqlite3` API (ships with macOS — no SPM dep).
/// - One database per device, lives at
///   `~/Library/Caches/com.droidmirroring.app.DroidMirroring/<serial>/cache.db`.
/// - All access is serialized through this actor; SQLite connection is held for
///   the actor's lifetime.
public actor SyncCache {
  public struct Snapshot: Sendable {
    public let entries: [SyncEntry]
    public let fetchedAt: Date
    public var ageSeconds: TimeInterval { Date().timeIntervalSince(fetchedAt) }
  }

  public let url: URL
  /// Cache entries older than this are still served but marked stale.
  public var staleAfter: TimeInterval = 30

  private nonisolated(unsafe) var db: OpaquePointer?

  public init(url: URL) throws {
    self.url = url
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
    let rc = sqlite3_open_v2(url.path, &db, flags, nil)
    guard rc == SQLITE_OK, let db else {
      throw DroidMirroringError.fileTransfer("SyncCache: sqlite open failed rc=\(rc)")
    }
    try Self.applySchema(db: db)
  }

  deinit {
    if let db { sqlite3_close_v2(db) }
  }

  // MARK: schema

  private static func applySchema(db: OpaquePointer) throws {
    let stmts = [
      "PRAGMA journal_mode = WAL;",
      "PRAGMA synchronous = NORMAL;",
      "PRAGMA user_version = 1;",
      """
      CREATE TABLE IF NOT EXISTS entries (
        parent_path TEXT NOT NULL,
        name        TEXT NOT NULL,
        mode        INTEGER NOT NULL,
        size        INTEGER NOT NULL,
        mtime       INTEGER NOT NULL,
        fetched_at  INTEGER NOT NULL,
        PRIMARY KEY (parent_path, name)
      );
      """,
      "CREATE INDEX IF NOT EXISTS entries_parent_fetched ON entries(parent_path, fetched_at);",
    ]
    for sql in stmts {
      var err: UnsafeMutablePointer<Int8>?
      let rc = sqlite3_exec(db, sql, nil, nil, &err)
      if rc != SQLITE_OK {
        let msg = err.map { String(cString: $0) } ?? "?"
        if let err { sqlite3_free(err) }
        throw DroidMirroringError.fileTransfer("SyncCache schema: \(msg)")
      }
    }
  }

  // MARK: reads

  public func snapshot(forDirectory path: String) -> Snapshot? {
    guard let db else { return nil }
    let sql = """
      SELECT name, mode, size, mtime, fetched_at FROM entries
      WHERE parent_path = ?
      ORDER BY name;
      """
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
    defer { sqlite3_finalize(stmt) }
    sqlite3_bind_text(stmt, 1, path, -1, Self.transientPtr)

    var entries: [SyncEntry] = []
    var newestFetched: Int64 = 0
    while sqlite3_step(stmt) == SQLITE_ROW {
      let namePtr = sqlite3_column_text(stmt, 0)
      let name = namePtr.flatMap { String(cString: $0) } ?? ""
      let mode = UInt32(sqlite3_column_int64(stmt, 1))
      let size = UInt32(sqlite3_column_int64(stmt, 2))
      let mtime = UInt32(sqlite3_column_int64(stmt, 3))
      let fetched = sqlite3_column_int64(stmt, 4)
      newestFetched = max(newestFetched, fetched)
      entries.append(SyncEntry(mode: mode, size: size, mtime: mtime, name: name))
    }
    if entries.isEmpty { return nil }
    return Snapshot(entries: entries, fetchedAt: Date(timeIntervalSince1970: TimeInterval(newestFetched)))
  }

  // MARK: writes

  public func replace(directory path: String, with entries: [SyncEntry]) {
    guard let db else { return }
    let now = Int64(Date().timeIntervalSince1970)
    sqlite3_exec(db, "BEGIN IMMEDIATE;", nil, nil, nil)
    defer { sqlite3_exec(db, "COMMIT;", nil, nil, nil) }

    var delStmt: OpaquePointer?
    if sqlite3_prepare_v2(db, "DELETE FROM entries WHERE parent_path = ?;", -1, &delStmt, nil) == SQLITE_OK {
      sqlite3_bind_text(delStmt, 1, path, -1, Self.transientPtr)
      sqlite3_step(delStmt)
    }
    sqlite3_finalize(delStmt)

    let insertSQL = """
      INSERT INTO entries (parent_path, name, mode, size, mtime, fetched_at)
      VALUES (?, ?, ?, ?, ?, ?);
      """
    var insStmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, insertSQL, -1, &insStmt, nil) == SQLITE_OK else { return }
    defer { sqlite3_finalize(insStmt) }
    for e in entries {
      sqlite3_reset(insStmt)
      sqlite3_clear_bindings(insStmt)
      sqlite3_bind_text(insStmt, 1, path, -1, Self.transientPtr)
      sqlite3_bind_text(insStmt, 2, e.name, -1, Self.transientPtr)
      sqlite3_bind_int64(insStmt, 3, Int64(e.mode))
      sqlite3_bind_int64(insStmt, 4, Int64(e.size))
      sqlite3_bind_int64(insStmt, 5, Int64(e.mtime))
      sqlite3_bind_int64(insStmt, 6, now)
      sqlite3_step(insStmt)
    }
  }

  public func invalidate(directory path: String) {
    guard let db else { return }
    var stmt: OpaquePointer?
    if sqlite3_prepare_v2(db, "DELETE FROM entries WHERE parent_path = ?;", -1, &stmt, nil) == SQLITE_OK {
      sqlite3_bind_text(stmt, 1, path, -1, Self.transientPtr)
      sqlite3_step(stmt)
    }
    sqlite3_finalize(stmt)
  }

  public func clearAll() {
    guard let db else { return }
    sqlite3_exec(db, "DELETE FROM entries;", nil, nil, nil)
  }

  // MARK: helpers

  /// SQLite's SQLITE_TRANSIENT (-1) tells it to copy the bound text. The C
  /// macro isn't bridged to Swift, so we recreate it.
  private static let transientPtr = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
}

// MARK: convenience

public extension SyncCache {
  /// Default on-disk location for a given device serial.
  static func defaultURL(forSerial serial: String) -> URL {
    let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
      ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches")
    return caches
      .appendingPathComponent("com.droidmirroring.app.DroidMirroring")
      .appendingPathComponent(serial)
      .appendingPathComponent("cache.db")
  }
}
