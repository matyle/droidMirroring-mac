import Foundation
import ADBKit
import SharedModels

@main
struct SyncSmoke {
  static func main() async {
    setvbuf(stdout, nil, _IONBF, 0)
    do {
      try await run()
      print("\nSYNC SMOKE PASSED")
    } catch {
      print("\nSYNC SMOKE FAILED: \(error)")
      exit(1)
    }
  }

  static func run() async throws {
    let adb = ADBClient()
    let devices = try await adb.listDevices()
    guard let device = devices.first(where: { $0.state == .online }) else {
      throw DroidMirroringError.deviceNotFound("no online device (have: \(devices))")
    }
    print("==> Device: \(device.id) (\(device.model))")

    // 1. open sync
    let conn = try await adb.openSyncTransport(serial: device.id)
    let session = SyncSession(connection: conn)

    // 2. LIST /sdcard
    print("==> LIST /sdcard …")
    let entries = try await session.list("/sdcard")
    print("    \(entries.count) entries")
    for e in entries.prefix(8) {
      let kind = e.isDirectory ? "DIR " : (e.isSymlink ? "LINK" : "FILE")
      print("    \(kind)  \(String(format: "%9d", e.size))  \(e.name)")
    }
    if entries.count > 8 { print("    … (+\(entries.count - 8) more)") }

    // 3. STAT one file
    guard let firstFile = entries.first(where: { $0.isFile }) else {
      print("==> no plain file in /sdcard to pull — skipping STAT/RECV")
      try await session.quit()
      return
    }
    let path = "/sdcard/\(firstFile.name)"
    print("==> STAT \(path) …")
    let st = try await session.stat(path)
    print("    mode=\(String(format: "%o", st.mode)) size=\(st.size) mtime=\(st.mtime)")
    guard st.mode != 0 else {
      print("==> STAT returned 0 (file not accessible) — skipping RECV")
      try await session.quit()
      return
    }

    // 4. RECV (only if small enough — avoid pulling 4GB videos in a smoke test)
    let maxRecvBytes: UInt32 = 5 * 1024 * 1024
    if st.size <= maxRecvBytes {
      let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("sync-smoke-\(firstFile.name)")
      print("==> RECV \(path) -> \(tmp.path) (\(st.size) bytes) …")
      try await session.recv(path, into: tmp)
      let pulledSize = (try? FileManager.default.attributesOfItem(atPath: tmp.path)[.size] as? UInt64) ?? 0
      print("    pulled \(pulledSize) bytes (expected \(st.size))")
      if pulledSize != UInt64(st.size) {
        throw DroidMirroringError.fileTransfer("size mismatch: got \(pulledSize), expected \(st.size)")
      }
      try? FileManager.default.removeItem(at: tmp)
    } else {
      print("==> \(firstFile.name) is \(st.size) bytes — too big, skipping RECV")
    }

    try await session.quit()
    print("==> QUIT")
  }
}
