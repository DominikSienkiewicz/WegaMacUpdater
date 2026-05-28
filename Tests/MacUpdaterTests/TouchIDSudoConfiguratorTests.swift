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

    // Regression: on macOS Sequoia, `osascript ... with administrator
    // privileges` running `/bin/mv /var/folders/.../tmp.XXXX
    // /etc/pam.d/sudo_local` fails with "Operation not permitted" even as
    // root — the kernel/TCC blocks rename(2) into /etc/pam.d/ from a temp
    // file on /var/folders. open(2)+write(2) via tee is on a different
    // policy path and succeeds. So the enable command must NOT use `mv` to
    // land the final file at /etc/pam.d/sudo_local; it must write in place
    // (tee or `>` redirection to the destination).
    func testEnableCommandDoesNotRenameAcrossIntoPamDirectory() {
        let cmd = TouchIDSudoConfigurator.enableShellCommand
        XCTAssertFalse(
            cmd.range(of: #"mv[^']*/etc/pam\.d/sudo_local"#, options: .regularExpression) != nil,
            "Command must not use `mv` to land the file at /etc/pam.d/sudo_local — rename(2) from /var/folders is blocked on Sequoia. Use tee or `>` redirection instead. Got: \(cmd)"
        )
    }

    func testEnableCommandWritesFinalFileViaTee() {
        let cmd = TouchIDSudoConfigurator.enableShellCommand
        // tee with /etc/pam.d/sudo_local as the destination — accepts any
        // intervening flags/whitespace, but requires the path follows tee.
        let hasTee = cmd.range(
            of: #"/usr/bin/tee[^|<]*?/etc/pam\.d/sudo_local"#,
            options: .regularExpression
        ) != nil
        XCTAssertTrue(hasTee,
                      "Command must invoke `/usr/bin/tee /etc/pam.d/sudo_local` to write the file in place: \(cmd)")
    }

    // MARK: - Manual enable fallback (TCC blocks GUI-elevated writes to /etc/pam.d/)

    // Even with `tee` (write-in-place, no rename), macOS Sequoia returns
    // "Operation not permitted" when an osascript-elevated child of an
    // unentitled GUI app writes to /etc/pam.d/sudo_local — the restriction
    // is at the TCC layer, not POSIX. The UI must recognise this and
    // surface a Terminal-friendly one-liner the user can paste themselves
    // (Terminal.app is its own TCC principal and gets prompted/granted on
    // first use), rather than show a raw cryptic stderr.
    func testClassifyOperationNotPermittedAsPermissionDenied() {
        let stderr = "0:638: execution error: tee: /etc/pam.d/sudo_local: Operation not permitted (1)"
        let outcome = TouchIDSudoEnableOutcome.classify(exitCode: 1, stderr: stderr)
        XCTAssertEqual(outcome, .permissionDenied)
    }

    func testClassifyUserCancelledAsCancelled() {
        // osascript exits with -128 / "User canceled." when the auth dialog
        // is dismissed; not a real failure, no error UI.
        let outcome = TouchIDSudoEnableOutcome.classify(
            exitCode: 1,
            stderr: "User canceled."
        )
        XCTAssertEqual(outcome, .cancelledByUser)
    }

    func testClassifySuccessOnExitZero() {
        XCTAssertEqual(
            TouchIDSudoEnableOutcome.classify(exitCode: 0, stderr: ""),
            .success
        )
    }

    func testClassifyUnknownErrorPreservesStderr() {
        let outcome = TouchIDSudoEnableOutcome.classify(
            exitCode: 1,
            stderr: "  unexpected: disk full  \n"
        )
        XCTAssertEqual(outcome, .otherError("unexpected: disk full"))
    }

    func testManualEnableTerminalCommandIsCopyPasteableOneLiner() {
        let cmd = TouchIDSudoConfigurator.manualEnableTerminalCommand
        XCTAssertFalse(cmd.contains("\n"),
                       "Must be a single line so it pastes cleanly into Terminal. Got: \(cmd)")
        XCTAssertTrue(cmd.contains("sudo"),
                      "Must request elevation explicitly: \(cmd)")
        XCTAssertTrue(cmd.contains("pam_tid.so"),
                      "Must install the pam_tid directive: \(cmd)")
        XCTAssertTrue(cmd.contains("/etc/pam.d/sudo_local"),
                      "Must target sudo_local, not sudo: \(cmd)")
        // Idempotency: re-running the manual command must not double-append
        // the pam_tid line. The simplest way is `grep -q … || echo … | sudo tee -a`.
        XCTAssertTrue(cmd.contains("grep"),
                      "Manual command must be idempotent (grep-guard before append): \(cmd)")
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
