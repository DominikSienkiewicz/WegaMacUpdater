import XCTest
import LocalAuthentication
@testable import MacUpdaterCore

final class TouchIDSudoConfiguratorTests: XCTestCase {

    // MARK: - State parser

    func testStateIsEnabledWhenSudoLocalContainsActivePamTidLine() {
        let contents = """
        # sudo_local: local config
        auth       sufficient     pam_tid.so
        """
        let state = TouchIDSudoConfigurator.state(
            sudoLocalContents: contents,
            pamModuleExists: true,
            biometryAvailable: true
        )
        XCTAssertEqual(state, .enabled)
    }

    func testStateIsAvailableWhenPamTidLineIsCommentedOut() {
        let contents = """
        # sudo_local: local config file which survives system update and is included for sudo
        # uncomment following line to enable Touch ID for sudo
        #auth       sufficient     pam_tid.so
        """
        let state = TouchIDSudoConfigurator.state(
            sudoLocalContents: contents,
            pamModuleExists: true,
            biometryAvailable: true
        )
        XCTAssertEqual(state, .available)
    }

    func testStateIsAvailableWhenSudoLocalDoesNotExist() {
        let state = TouchIDSudoConfigurator.state(
            sudoLocalContents: nil,
            pamModuleExists: true,
            biometryAvailable: true
        )
        XCTAssertEqual(state, .available)
    }

    func testStateIsNotSupportedWhenPamModuleMissing() {
        let state = TouchIDSudoConfigurator.state(
            sudoLocalContents: nil,
            pamModuleExists: false,
            biometryAvailable: true
        )
        XCTAssertEqual(state, .notSupported)
    }

    func testStateIsNotSupportedWhenBiometryUnavailable() {
        let state = TouchIDSudoConfigurator.state(
            sudoLocalContents: nil,
            pamModuleExists: true,
            biometryAvailable: false
        )
        XCTAssertEqual(state, .notSupported)
    }

    // pam_tid must be sufficient *before* the default include line, otherwise
    // sudo will already have failed on the password prompt by the time it
    // reaches the biometry check. Whitespace before the directive is fine —
    // a leading `#` is the only thing that disables it.
    func testStateIgnoresLineWithIndentedComment() {
        let contents = "   #auth       sufficient     pam_tid.so"
        let state = TouchIDSudoConfigurator.state(
            sudoLocalContents: contents,
            pamModuleExists: true,
            biometryAvailable: true
        )
        XCTAssertEqual(state, .available)
    }

    func testStateAcceptsLeadingWhitespaceOnActiveDirective() {
        let contents = "    auth sufficient pam_tid.so"
        let state = TouchIDSudoConfigurator.state(
            sudoLocalContents: contents,
            pamModuleExists: true,
            biometryAvailable: true
        )
        XCTAssertEqual(state, .enabled)
    }

    // MARK: - Shell command builder

    func testEnableCommandWritesPamTidLineToSudoLocal() {
        let cmd = TouchIDSudoConfigurator.enableShellCommand
        XCTAssertTrue(cmd.contains("/etc/pam.d/sudo_local"), "Command must target sudo_local: \(cmd)")
        XCTAssertTrue(cmd.contains("pam_tid.so"), "Command must reference pam_tid.so: \(cmd)")
        // Must NOT touch /etc/pam.d/sudo directly (that file gets overwritten by macOS updates).
        XCTAssertFalse(cmd.contains("/etc/pam.d/sudo "), "Command must not modify /etc/pam.d/sudo directly")
        XCTAssertFalse(cmd.hasSuffix("/etc/pam.d/sudo"), "Command must not modify /etc/pam.d/sudo directly")
    }

    // MARK: - Biometry availability

    func testBiometryAvailableWhenLAContextCanEvaluate() {
        XCTAssertTrue(TouchIDSudoConfigurator.biometryAvailable(
            canEvaluate: true,
            laErrorCode: nil,
            sensorPresent: false
        ))
    }

    func testBiometryAvailableWhenBiometryNotEnrolled() {
        // Hardware is present, the user just hasn't registered a finger.
        XCTAssertTrue(TouchIDSudoConfigurator.biometryAvailable(
            canEvaluate: false,
            laErrorCode: LAError.biometryNotEnrolled.rawValue,
            sensorPresent: false
        ))
    }

    func testBiometryAvailableWhenBiometryLockout() {
        XCTAssertTrue(TouchIDSudoConfigurator.biometryAvailable(
            canEvaluate: false,
            laErrorCode: LAError.biometryLockout.rawValue,
            sensorPresent: false
        ))
    }

    // Regression test: on a Touch-ID-capable Mac, `LAContext` reports
    // `biometryNotAvailable` whenever biometrics are only *transiently*
    // unusable for the calling process — lid shut (clamshell), just after
    // boot, screen-lock grace window. The previous implementation treated
    // that as "no Touch ID" and hid the entire sudo+Touch ID card, leaving
    // the user no way to enable it. The physical sensor is still there, so
    // the feature must remain available.
    func testBiometryAvailableFallsBackToSensorWhenLAContextReportsNotAvailable() {
        XCTAssertTrue(TouchIDSudoConfigurator.biometryAvailable(
            canEvaluate: false,
            laErrorCode: LAError.biometryNotAvailable.rawValue,
            sensorPresent: true
        ))
    }

    // Same inconclusive `LAContext` answer, but no sensor in IOKit → the Mac
    // genuinely has no Touch ID, so the feature stays hidden.
    func testBiometryUnavailableWhenLAContextNotAvailableAndNoSensor() {
        XCTAssertFalse(TouchIDSudoConfigurator.biometryAvailable(
            canEvaluate: false,
            laErrorCode: LAError.biometryNotAvailable.rawValue,
            sensorPresent: false
        ))
    }

    // `canEvaluatePolicy` can return false with no error at all — still
    // inconclusive about the hardware, so the sensor probe must decide.
    func testBiometryAvailableFallsBackToSensorWhenLAContextErrorIsNil() {
        XCTAssertTrue(TouchIDSudoConfigurator.biometryAvailable(
            canEvaluate: false,
            laErrorCode: nil,
            sensorPresent: true
        ))
    }
}
