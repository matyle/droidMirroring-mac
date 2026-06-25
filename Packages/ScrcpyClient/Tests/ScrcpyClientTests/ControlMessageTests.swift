import XCTest
@testable import ScrcpyClient

final class ControlMessageTests: XCTestCase {
  func test_serialize_prefixesTypeByte() {
    let msg = ControlMessage(type: .backOrScreenOn, payload: Data())
    XCTAssertEqual(msg.serialize().first, ControlMessageType.backOrScreenOn.rawValue)
  }
}
