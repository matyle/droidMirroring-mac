import XCTest
@testable import ADBKit
import SharedModels

final class ADBClientTests: XCTestCase {
  func test_parseDeviceLine_usb_online() {
    let line: Substring = "R5CTC0ABCDE       device usb:0-1.2 product:e1q model:SM_S921B device:e1q transport_id:3"[...]
    let dev = ADBClient.parseDeviceLine(line)
    XCTAssertEqual(dev?.id, "R5CTC0ABCDE")
    XCTAssertEqual(dev?.state, .online)
    XCTAssertEqual(dev?.transport, .usb)
    XCTAssertEqual(dev?.model, "SM S921B")
  }

  func test_parseDeviceLine_wifi() {
    let line: Substring = "192.168.1.42:5555 device product:pixel_8 model:Pixel_8 device:husky transport_id:1"[...]
    let dev = ADBClient.parseDeviceLine(line)
    XCTAssertEqual(dev?.id, "192.168.1.42:5555")
    XCTAssertEqual(dev?.transport, .wifi)
    XCTAssertEqual(dev?.state, .online)
  }

  func test_parseDeviceLine_unauthorized() {
    let line: Substring = "abcd1234 unauthorized usb:0-1"[...]
    XCTAssertEqual(ADBClient.parseDeviceLine(line)?.state, .unauthorized)
  }

  func test_parseDeviceLine_garbage_returnsNil() {
    XCTAssertNil(ADBClient.parseDeviceLine(""[...]))
    XCTAssertNil(ADBClient.parseDeviceLine("singletoken"[...]))
  }
}
