import XCTest
@testable import ScrcpyClient

final class ScrcpyOptionsTests: XCTestCase {
  func test_serverArgs_default() {
    let args = ScrcpyOptions().serverArgs(scid: "abc12345")
    XCTAssertTrue(args.contains("scid=abc12345"))
    XCTAssertTrue(args.contains("video_codec=h265"))
    XCTAssertTrue(args.contains("audio=true"))
    XCTAssertTrue(args.contains("control=true"))
    XCTAssertFalse(args.contains(where: { $0.hasPrefix("max_size=") }))
    XCTAssertFalse(args.contains(where: { $0.hasPrefix("new_display=") }))
  }

  func test_serverArgs_fusionFreeform() {
    let opts = ScrcpyOptions(audioEnabled: false, maxSize: 1080, newDisplay: "1920x1080/180")
    let args = opts.serverArgs(scid: "deadbeef")
    XCTAssertTrue(args.contains("audio=false"))
    XCTAssertTrue(args.contains("max_size=1080"))
    XCTAssertTrue(args.contains("new_display=1920x1080/180"))
  }
}
