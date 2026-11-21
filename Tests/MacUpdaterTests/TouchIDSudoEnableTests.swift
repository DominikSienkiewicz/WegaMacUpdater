import Foundation
import Testing
@testable import WegaHelperKit

/// What turning Touch ID for `sudo` on plans for the bytes it read, and how its result travels to
/// the app. The operation itself is in `TouchIDSudoEnablerTests`.
@Suite("Turning on Touch ID for sudo: plan and wire")
struct TouchIDSudoEnableTests {
    let wega = TouchIDSudoConfigurator.pamDirective

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
