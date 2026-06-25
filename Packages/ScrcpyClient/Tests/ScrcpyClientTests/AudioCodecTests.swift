import XCTest
@testable import ScrcpyClient

final class AudioCodecTests: XCTestCase {
  func test_parse_known() {
    XCTAssertEqual(AudioCodec.parse(fourCC: fourCC("opus")), .opus)
    XCTAssertEqual(AudioCodec.parse(fourCC: fourCC(" aac")), .aac)
    XCTAssertEqual(AudioCodec.parse(fourCC: fourCC("flac")), .flac)
    XCTAssertEqual(AudioCodec.parse(fourCC: fourCC("raw ")), .raw)
  }

  func test_parse_unknown() {
    XCTAssertNil(AudioCodec.parse(fourCC: 0xDEAD_BEEF as UInt32))
  }

  private func fourCC(_ s: String) -> UInt32 {
    var v: UInt32 = 0
    for byte in s.utf8 { v = (v << 8) | UInt32(byte) }
    return v
  }
}
