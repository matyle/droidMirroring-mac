import XCTest
@testable import MirrorEngine

final class NALUTests: XCTestCase {
  func test_split_fourByteStartCode_singleNAL() {
    let data = Data([0, 0, 0, 1, 0x42, 0x01, 0x02])
    let nalus = NALU.split(annexB: data)
    XCTAssertEqual(nalus, [Data([0x42, 0x01, 0x02])])
  }

  func test_split_mixedStartCodes_twoNALs() {
    // VPS then SPS, with 4-byte then 3-byte start codes
    let data = Data([0, 0, 0, 1, 0x40, 0x01, 0, 0, 1, 0x42, 0x02])
    let nalus = NALU.split(annexB: data)
    XCTAssertEqual(nalus.count, 2)
    XCTAssertEqual(nalus[0], Data([0x40, 0x01]))
    XCTAssertEqual(nalus[1], Data([0x42, 0x02]))
  }

  func test_annexBToAVCC_addsLengthPrefix() {
    let data = Data([0, 0, 0, 1, 0xAA, 0xBB, 0xCC])
    let avcc = NALU.annexBToAVCC(data)
    XCTAssertEqual(avcc, Data([0, 0, 0, 3, 0xAA, 0xBB, 0xCC]))
  }

  func test_hevcType() {
    // HEVC VPS_NUT (32): byte = 0x40 → (0x40 >> 1) & 0x3F = 0x20 = 32 ✓
    XCTAssertEqual(NALU.hevcType(of: Data([0x40, 0x01])), 32)
    // SPS_NUT (33): byte = 0x42 → (0x42 >> 1) & 0x3F = 0x21 = 33 ✓
    XCTAssertEqual(NALU.hevcType(of: Data([0x42, 0x01])), 33)
  }

  func test_avcType() {
    // SPS = 7: byte 0x67 → 0x67 & 0x1F = 7 ✓
    XCTAssertEqual(NALU.avcType(of: Data([0x67])), 7)
    // PPS = 8: byte 0x68 → 0x68 & 0x1F = 8 ✓
    XCTAssertEqual(NALU.avcType(of: Data([0x68])), 8)
  }
}
