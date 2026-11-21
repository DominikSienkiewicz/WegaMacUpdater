import Foundation
import Testing
@testable import WegaHelperKit

/// What turning Touch ID for `sudo` on plans for the bytes it read, and how its result travels to
/// the app. The operation itself is in `TouchIDSudoEnablerTests`.
@Suite("Turning on Touch ID for sudo: plan and wire")
struct TouchIDSudoEnableTests {
    let wega = TouchIDSudoConfigurator.pamDirective
    let template = "# sudo_local: local config file which survives system update and is included for sudo\n"
        + "# uncomment following line to enable Touch ID for sudo\n"
        + "#auth       sufficient     pam_tid.so\n"

    // MARK: - Plan

    private func plan(_ text: String) -> TouchIDSudoEnablePlan {
        TouchIDSudoConfigurator.contentsEnablingTouchID(current: Data(text.utf8))
    }

    @Test func theDirectiveIsAddedToTheBytesReadAndToNothingElse() {
        #expect(plan("") == .write(Data((wega + "\n").utf8)), "no file and no template: the directive alone")
        #expect(plan(template) == .write(Data((template + wega + "\n").utf8)), "Apple's template keeps its commented line")
        #expect(plan("# a") == .write(Data(("# a\n" + wega + "\n").utf8)), "an unterminated last line gets its newline first")
        #expect(plan("# a\r\n") == .write(Data(("# a\r\n" + wega + "\n").utf8)), "a line ending in CR LF already ends in a newline")
    }

    /// The same loose detection as the card's state: any active `auth … sufficient … pam_tid.so`.
    @Test func anActiveTouchIDLineIsAlreadyEnabled() {
        for text in [wega + "\n", wega, "auth sufficient pam_tid.so\n", "  auth\tsufficient   pam_tid.so # c\n",
                     template + "auth sufficient pam_tid.so\n", "auth required pam_opendirectory.so\n" + wega + "\n"] {
            #expect(plan(text) == .alreadyEnabled, "\(text.debugDescription)")
        }
        #expect(plan("#auth sufficient pam_tid.so\n") != .alreadyEnabled, "a comment does not enable it")
    }

    @Test func aWrittenPlanIsEnabledTheNextTime() throws {
        guard case .write(let contents) = plan(template) else {
            Issue.record("the template must be written")
            return
        }
        #expect(TouchIDSudoConfigurator.contentsEnablingTouchID(current: contents) == .alreadyEnabled)
    }

    /// [O13]: a file that is not UTF-8 or holds a NUL was replaced with the template; now it is refused.
    @Test func bytesThatAreNotUTF8OrHoldANulAreRefused() {
        for bytes in [Data([0xFF, 0x0A]), Data("# a\n".utf8) + Data([0x00]) + Data("\n".utf8), Data([0xC3])] {
            #expect(TouchIDSudoConfigurator.contentsEnablingTouchID(current: bytes) == .refused(.unreadable), "\(Array(bytes))")
        }
    }

    /// A plan the helper could not read back, and turning Touch ID off would refuse, is not written.
    @Test func aPlanLargerThanTheLimitIsRefused() {
        let fits = String(repeating: "#", count: TouchIDSudoDisabler.maximumSize - wega.utf8.count - 2)
        #expect(plan(fits) == .write(Data((fits + "\n" + wega + "\n").utf8)), "exactly the limit")
        #expect(plan(fits + "#") == .refused(.tooLarge))
    }

    // MARK: - Wire

    @Test func everyResultRoundTripsOverTheWire() {
        let all: [TouchIDSudoEnableResult] = [
            .enabled, .alreadyEnabled, .restoredAfterFailure, .rollbackFailed(backupPath: nil),
            .rollbackFailed(backupPath: "/etc/pam.d/.sudo_local.wega-backup-0A1B2C3D-0000-4000-8000-00000000000F"),
        ] + TouchIDSudoEnableRefusal.allCases.map { .refused($0) }
        for result in all {
            #expect(TouchIDSudoEnableResult(wireCode: result.wireCode, detail: result.wireDetail) == result, "\(result)")
        }
        #expect(TouchIDSudoEnableResult.enabled.wireCode == 1)
        #expect(TouchIDSudoEnableResult.alreadyEnabled.wireCode == 0)
        #expect(TouchIDSudoEnableResult.restoredAfterFailure.wireCode == -20)
        #expect(TouchIDSudoEnableResult.rollbackFailed(backupPath: nil).wireCode == -21)
        #expect(TouchIDSudoEnableResult.rollbackFailed(backupPath: nil).wireDetail == nil)
        #expect(TouchIDSudoEnableResult.refused(.unsafeOwnership).wireDetail == nil)
    }

    /// The same codes as turning Touch ID off, for the same conditions; the three that describe
    /// removing the directive never occur here.
    @Test func theRefusalsShareTheirCodesWithTurningTouchIDOff() {
        #expect(TouchIDSudoEnableRefusal.allCases.map(\.rawValue) == [-1, -2, -3, -4, -5, -6, -7, -10])
        for refusal in TouchIDSudoEnableRefusal.allCases {
            let shared = TouchIDSudoDisableRefusal(rawValue: refusal.rawValue)
            #expect(shared.map { "\($0)" } == "\(refusal)", "\(refusal)")
            #expect(shared.flatMap(TouchIDSudoEnableRefusal.init) == refusal)
        }
        for removalOnly in [TouchIDSudoDisableRefusal.lineContinuation, .fallbackPolicyPresent, .otherDirectivesPresent] {
            #expect(TouchIDSudoEnableRefusal(removalOnly) == nil, "\(removalOnly)")
        }
    }

    @Test func anUnknownCodeIsNotAResult() {
        for code in [2, 3, -8, -9, -11, -12, -19, -22, -99, Int.min, Int.max] {
            #expect(TouchIDSudoEnableResult(wireCode: code, detail: nil) == nil, "\(code)")
        }
    }

    /// RC2-1: only −21 carries a detail. A detail on any other code is a reply this protocol does
    /// not produce, such as a v7 `(false, message)` read as `(0, message)`.
    @Test func aDetailOnAnyCodeButMinus21IsNotAResult() {
        let replies: [(Int, String)] = [
            (1, "x"), (0, "Nie udało się"), (0, "/etc/pam.d/.sudo_local.wega-x"), (-5, ""), (-20, "x"), (-10, "/etc/pam.d/.sudo_local.wega-x"),
        ]
        for (code, detail) in replies {
            #expect(TouchIDSudoEnableResult(wireCode: code, detail: detail) == nil, "\(code) \(detail)")
        }
    }

    /// −21 names one backup in the policy directory, or nothing when there was no previous file.
    @Test func theRollbackPathMustBeOneBackupNameInThePolicyDirectory() {
        for detail in ["/tmp/x", "/etc/pam.d/sudo_local", "/etc/pam.d/.sudo_local.wega-../x", "/etc/pam.d/.sudo_local.wega-",
                       "/private/etc/pam.d/.sudo_local.wega-backup-A", "/etc/pam.d/.sudo_local.wega-a/b"] {
            #expect(TouchIDSudoEnableResult(wireCode: -21, detail: detail) == nil, "\(detail)")
        }
        #expect(TouchIDSudoEnableResult(wireCode: -21, detail: nil) == .rollbackFailed(backupPath: nil))
    }

    /// Security re-check: the backup the live writer makes beside the policy file, reported under
    /// `/etc/pam.d`, is a path the app accepts.
    @Test func theLiveWritersBackupIsAcceptedByTheApp() {
        let target = URL(fileURLWithPath: SystemPaths.pamPolicyDirectory + "/sudo_local")
        let name = SudoLocalTransactionalWriter.backupURL(for: target).lastPathComponent
        let path = TouchIDSudoDisabler.reportedPath(of: name)
        #expect(TouchIDSudoEnableResult(wireCode: -21, detail: path) == .rollbackFailed(backupPath: path))
    }

    /// Nothing from the file can reach the daemon's log: the report carries no byte of it.
    @Test func theReportHoldsNoContentOfTheFile() {
        let labels = Mirror(reflecting: TouchIDSudoEnableReport(result: .enabled)).children.compactMap(\.label)
        #expect(labels == ["result", "failedStep"])
    }
}
