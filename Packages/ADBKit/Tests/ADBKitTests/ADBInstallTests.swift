import XCTest
@testable import ADBKit

final class ADBInstallTests: XCTestCase {
  func test_parse_success_plain() {
    let outcome = ADBInstaller.parseInstallOutput("Success\n")
    XCTAssertEqual(outcome, .success(packageName: nil))
  }

  func test_parse_success_with_pkgPrefix() {
    let raw = "pkg: /data/local/tmp/com.example.app.apk\nSuccess\n"
    let outcome = ADBInstaller.parseInstallOutput(raw)
    XCTAssertEqual(outcome, .success(packageName: "/data/local/tmp/com.example.app.apk"))
  }

  func test_parse_versionDowngrade() {
    let raw = "Failure [INSTALL_FAILED_VERSION_DOWNGRADE]\n"
    let outcome = ADBInstaller.parseInstallOutput(raw)
    XCTAssertEqual(outcome, .failure(.versionDowngrade))
  }

  func test_parse_alreadyExists() {
    let raw = "adb: failed to install: INSTALL_FAILED_ALREADY_EXISTS\n"
    let outcome = ADBInstaller.parseInstallOutput(raw)
    XCTAssertEqual(outcome, .failure(.alreadyInstalled))
  }

  func test_parse_incompatibleGeneric() {
    let raw = "Failure [INSTALL_FAILED_OLDER_SDK]\n"
    let outcome = ADBInstaller.parseInstallOutput(raw)
    XCTAssertEqual(outcome, .failure(.incompatible("INSTALL_FAILED_OLDER_SDK")))
  }

  func test_parse_unknownFailureFallsBackToStderr() {
    let raw = "some unexpected error text\n"
    let outcome = ADBInstaller.parseInstallOutput(raw)
    if case .failure(.adbStderr(let msg)) = outcome {
      XCTAssertTrue(msg.contains("unexpected error"))
    } else {
      XCTFail("expected adbStderr, got \(outcome)")
    }
  }
}
