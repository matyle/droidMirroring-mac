import XCTest
import ADBKit
import ScrcpyClient
import SharedModels
@testable import FusionEngine

/// Smoke build-only: verifies the new public surface compiles and the simple
/// value types initialize. No device interaction.
final class FusionEngineSmokeTests: XCTestCase {
  func testInstalledAppValueType() {
    let app = InstalledApp(packageName: "com.android.chrome", label: "Chrome", iconPNG: nil)
    XCTAssertEqual(app.id, "com.android.chrome")
    XCTAssertEqual(app.label, "Chrome")
  }

  func testActivationTokenValueType() {
    let token = ActivationToken(
      serial: "ABC123",
      restoreSnapshot: ["enable_freeform_support": "0"]
    )
    XCTAssertEqual(token.serial, "ABC123")
    XCTAssertEqual(token.restoreSnapshot["enable_freeform_support"], "0")
  }

  func testActorsConstruct() {
    let adb = ADBClient()
    _ = FreeformActivator(adb: adb)
    _ = AppCatalog(adb: adb)
    _ = FusionLauncher(
      adb: adb,
      scrcpyResources: ScrcpyServerLauncher.Resources(
        serverJar: URL(fileURLWithPath: "/tmp/no.jar"),
        adbBinary: nil
      )
    )
  }
}
