import XCTest
@testable import ADBKit

final class ADBConnectionTests: XCTestCase {
  func test_frame_hostVersion() {
    let frame = ADBConnection.frame("host:version")
    XCTAssertEqual(String(data: frame, encoding: .ascii), "000chost:version")
  }

  func test_frame_emptyCommand() {
    XCTAssertEqual(String(data: ADBConnection.frame(""), encoding: .ascii), "0000")
  }

  func test_frame_longCommand() {
    let cmd = String(repeating: "a", count: 0x1234)
    let frame = ADBConnection.frame(cmd)
    XCTAssertEqual(String(data: frame.prefix(4), encoding: .ascii), "1234")
    XCTAssertEqual(frame.count, 4 + 0x1234)
  }
}
