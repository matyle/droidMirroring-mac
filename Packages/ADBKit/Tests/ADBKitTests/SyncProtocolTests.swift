import XCTest
@testable import ADBKit

final class SyncProtocolTests: XCTestCase {
  func test_syncCommand_rawValues() {
    XCTAssertEqual(SyncCommand.stat.rawValue, "STAT")
    XCTAssertEqual(SyncCommand.recv.rawValue, "RECV")
  }

  func test_syncEntry_modeBits() {
    let dir = SyncEntry(mode: 0o040755, size: 0, mtime: 0, name: "foo")
    let file = SyncEntry(mode: 0o100644, size: 1024, mtime: 0, name: "bar.txt")
    XCTAssertTrue(dir.isDirectory)
    XCTAssertFalse(dir.isFile)
    XCTAssertTrue(file.isFile)
    XCTAssertFalse(file.isDirectory)
  }
}
