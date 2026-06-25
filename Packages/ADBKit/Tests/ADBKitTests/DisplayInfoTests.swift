import XCTest
@testable import ADBKit

final class DisplayInfoTests: XCTestCase {
  func test_parse_android16_zFoldUnfolded() {
    // Real-shape Android 16 dump: state is on Display Devices section (top),
    // logical id + uniqueId reference on Logical Displays section (later).
    let dump = """
    Display Devices: size=3
      DisplayDeviceInfo{"Built-in Screen": uniqueId="local:INNER", 1968 x 2184, state ON, type INTERNAL}
      DisplayDeviceInfo{"Built-in Screen": uniqueId="local:OUTER", 1080 x 2520, state OFF, type INTERNAL}
      DisplayDeviceInfo{"scrcpy": uniqueId="virtual:scrcpy,99", 1968 x 2184, state DOZE, type VIRTUAL}
    Logical Displays: size=3
      Display 0:
        mDisplayId=0
        mPrimaryDisplayDevice=Built-in Screen(local:INNER)
      Display 1:
        mDisplayId=1
        mPrimaryDisplayDevice=Built-in Screen(local:OUTER)
      Display 99:
        mDisplayId=99
        mPrimaryDisplayDevice=scrcpy(virtual:scrcpy,99)
    """
    let infos = DisplayInfoParser.parse(dump)
    XCTAssertEqual(infos.count, 2)
    XCTAssertEqual(infos.map(\.id), [0, 1])
    XCTAssertEqual(infos[0].width, 1968)
    XCTAssertEqual(infos[0].state, .on)
    XCTAssertEqual(infos[1].width, 1080)
    XCTAssertEqual(infos[1].state, .off)
  }

  func test_parse_android16_zFoldFolded() {
    let dump = """
    Display Devices:
      DisplayDeviceInfo{"Built-in Screen": uniqueId="local:INNER", 1968 x 2184, state OFF, type INTERNAL}
      DisplayDeviceInfo{"Built-in Screen": uniqueId="local:OUTER", 1080 x 2520, state DOZE, type INTERNAL}
    Logical Displays:
      Display 0:
        mDisplayId=0
        mPrimaryDisplayDevice=Built-in Screen(local:INNER)
      Display 1:
        mDisplayId=1
        mPrimaryDisplayDevice=Built-in Screen(local:OUTER)
    """
    let infos = DisplayInfoParser.parse(dump)
    XCTAssertEqual(infos.map(\.id), [0, 1])
    XCTAssertEqual(infos[0].state, .off)
    XCTAssertEqual(infos[1].state, .doze)
  }

  // MARK: parseWindowDump — the new path used at runtime

  func test_parseWindowDump_zFold_landscapeUnfolded() {
    // Real Z Fold 7 / Android 16 `dumpsys window` excerpt while unfolded and
    // rotated to landscape. Display 0 is the active inner panel rotated 270°.
    let dump = """
      Display{#0 state=ON size=2184x1968 ROTATION_270}:
      Display{#1 state=OFF size=1080x2520 ROTATION_0}:
      Display{#56 state=DOZE size=1080x2520 ROTATION_0}:
    """
    let infos = DisplayInfoParser.parseWindowDump(dump)
    XCTAssertEqual(infos.count, 2)
    XCTAssertEqual(infos[0].id, 0)
    XCTAssertEqual(infos[0].width, 2184)
    XCTAssertEqual(infos[0].height, 1968)
    XCTAssertEqual(infos[0].rotation, 3)
    XCTAssertEqual(infos[0].state, .on)
    XCTAssertEqual(infos[1].id, 1)
    XCTAssertEqual(infos[1].state, .off)
  }

  func test_parseWindowDump_landscapeOuter() {
    // Folded, outer panel landscape.
    let dump = "  Display{#0 state=ON size=2520x1080 ROTATION_90}:"
    let infos = DisplayInfoParser.parseWindowDump(dump)
    XCTAssertEqual(infos.count, 1)
    XCTAssertEqual(infos[0].rotation, 1)
    XCTAssertEqual(infos[0].width, 2520)
  }

  func test_parseWindowDump_skipsVirtualDisplay() {
    let dump = """
      Display{#0 state=ON size=1080x2520 ROTATION_0}:
      Display{#56 state=DOZE size=1080x2520 ROTATION_0}:
    """
    XCTAssertEqual(DisplayInfoParser.parseWindowDump(dump).map(\.id), [0])
  }

  func test_parse_ignoresNoisyDisplayIdVariants() {
    // dumpsys sprinkles `mDisplayId=: 0` and `mDisplayId= 0` deeper in the file
    // (state machine debug spam). The strict matcher should skip those.
    let dump = """
    Display Devices:
      DisplayDeviceInfo{"X": uniqueId="local:A", 100 x 200, state ON, type INTERNAL}
      DisplayDeviceInfo{"Y": uniqueId="local:B", 300 x 400, state OFF, type INTERNAL}
    Logical Displays:
      mDisplayId=0
      mPrimaryDisplayDevice=X(local:A)
      mDisplayId=: 0
      mDisplayId= 5
      mDisplayId=99
      mPrimaryDisplayDevice=Y(local:B)
    """
    let infos = DisplayInfoParser.parse(dump)
    XCTAssertEqual(infos.map(\.id), [0, 99])
  }

  func test_state_isActive() {
    XCTAssertTrue(DisplayInfo.State.on.isActive)
    XCTAssertTrue(DisplayInfo.State.doze.isActive)
    XCTAssertFalse(DisplayInfo.State.off.isActive)
    XCTAssertFalse(DisplayInfo.State.unknown.isActive)
  }
}
