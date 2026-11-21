import Foundation
import Testing
@testable import WegaHelperKit

/// Who may turn Touch ID for `sudo` off, which files the helper touches, and how the result
/// travels to the app. The transaction itself is in `TouchIDSudoDisableTransactionTests`.
@Suite("Turning off Touch ID for sudo: gates and wire")
struct TouchIDSudoDisableTests {

    // MARK: - Who may ask

    @Test func onlyTheAdministratorAtTheConsoleMayAsk() {
        typealias Caller = TouchIDSudoDisabler.Caller
        #expect(TouchIDSudoDisabler.refusal(caller: Caller(uid: 501, consoleUserUID: nil, isAdministrator: true)) == .noConsoleUser)
        #expect(TouchIDSudoDisabler.refusal(caller: Caller(uid: 502, consoleUserUID: 501, isAdministrator: true)) == .callerNotConsoleUser)
        #expect(TouchIDSudoDisabler.refusal(caller: Caller(uid: 501, consoleUserUID: 501, isAdministrator: false)) == .callerNotAdministrator)
        #expect(TouchIDSudoDisabler.refusal(caller: Caller(uid: 501, consoleUserUID: 501, isAdministrator: true)) == nil)
    }

    // MARK: - The directory and the file

    @Test func thePolicyDirectoryMustBeRootsAlone() {
        func facts(owner: UInt32 = 0, mode: UInt16 = 0o755, directory: Bool = true, acl: PAMAccessControlState = .absent) -> PAMPolicyDirectoryFacts {
            PAMPolicyDirectoryFacts(isDirectory: directory, ownerUID: owner, permissions: mode, accessControl: acl)
        }
        #expect(TouchIDSudoDisabler.refusal(directory: facts()) == nil)
        #expect(TouchIDSudoDisabler.refusal(directory: facts(mode: 0o700)) == nil)
        for unsafe in [facts(mode: 0o775), facts(mode: 0o757), facts(owner: 501), facts(directory: false),
                       facts(acl: .present), facts(acl: .unreadable)] {
            #expect(TouchIDSudoDisabler.refusal(directory: unsafe) == .unsafeOwnership, "\(unsafe)")
        }
    }

    @Test func theFileMustBeRootsRegularSmallAndUnwritableByOthers() {
        func facts(regular: Bool = true, links: UInt32 = 1, owner: UInt32 = 0, mode: UInt16 = 0o644,
                   acl: PAMAccessControlState = .absent, size: Int64 = 200) -> PAMPolicyFileFacts {
            PAMPolicyFileFacts(isRegularFile: regular, identity: PAMFileIdentity(device: 1, inode: 1), linkCount: links,
                               ownerUID: owner, groupID: 0, permissions: mode, accessControl: acl, size: size,
                               modifiedNanoseconds: 0)
        }
        for safe in [facts(), facts(mode: 0o444), facts(mode: 0o600), facts(mode: 0o640), facts(size: 65_536)] {
            #expect(TouchIDSudoDisabler.refusal(file: safe) == nil, "\(safe)")
        }
        #expect(TouchIDSudoDisabler.refusal(file: facts(links: 2)) == nil, "a second name is logged, not refused (H22)")
        #expect(TouchIDSudoDisabler.refusal(file: facts(regular: false)) == .notRegularFile)
        for unsafe in [facts(owner: 501), facts(mode: 0o664), facts(mode: 0o646), facts(mode: 0o666),
                       facts(acl: .present), facts(acl: .unreadable)] {
            #expect(TouchIDSudoDisabler.refusal(file: unsafe) == .unsafeOwnership, "\(unsafe)")
        }
        #expect(TouchIDSudoDisabler.refusal(file: facts(size: 65_537)) == .tooLarge)
    }

    // MARK: - Wire

    @Test func everyResultRoundTripsOverTheWire() {
        let all: [TouchIDSudoDisableResult] = [
            .removed(lines: 1), .removed(lines: 3), .nothingToRemove, .restoredAfterFailure,
            .rollbackFailed(backupPath: "/etc/pam.d/.sudo_local.wega-swap-0A1B2C3D-0000-4000-8000-00000000000F"),
        ] + TouchIDSudoDisableRefusal.allCases.map { .refused($0) }
        for result in all {
            #expect(TouchIDSudoDisableResult(wireCode: result.wireCode, detail: result.wireDetail) == result, "\(result)")
        }
        #expect(TouchIDSudoDisableRefusal.allCases.map(\.rawValue) == Array(stride(from: -1, through: -11, by: -1)))
        #expect(TouchIDSudoDisableResult.removed(lines: 2).wireCode == 2)
        #expect(TouchIDSudoDisableResult.nothingToRemove.wireCode == 0)
        #expect(TouchIDSudoDisableResult.restoredAfterFailure.wireCode == -20)
        #expect(TouchIDSudoDisableResult.rollbackFailed(backupPath: "/etc/pam.d/.sudo_local.wega-x").wireCode == -21)
        #expect(TouchIDSudoDisableResult.refused(.unsafeOwnership).wireDetail == nil)
    }

    @Test func anUnknownCodeIsNotAResult() {
        for code in [-99, -12, -19, -22, Int.min] {
            #expect(TouchIDSudoDisableResult(wireCode: code, detail: nil) == nil, "\(code)")
        }
    }

    /// The app never shows a path outside the policy directory, or more than one name inside it.
    @Test func theRollbackPathMustBeOneSwapNameInThePolicyDirectory() {
        let refused: [String?] = [
            "/tmp/x", "/etc/pam.d/sudo_local", "/etc/pam.d/.sudo_local.wega-../x", "/etc/pam.d/.sudo_local.wega-",
            nil, "/etc/pam.d/.sudo_local.wega-a/b", "/etc/pam.d/.sudo_local.wega-a.b", "/etc/pam.d/.sudo_local.wega-é",
            "/private/etc/pam.d/.sudo_local.wega-swap", "/etc/pam.d/.sudo_local.wega-" + String(repeating: "a", count: 65),
            " /etc/pam.d/.sudo_local.wega-swap",
        ]
        for detail in refused {
            #expect(TouchIDSudoDisableResult(wireCode: -21, detail: detail) == nil, "\(String(describing: detail))")
        }
        let longest = "/etc/pam.d/.sudo_local.wega-" + String(repeating: "a", count: 64)
        #expect(TouchIDSudoDisableResult(wireCode: -21, detail: longest) == .rollbackFailed(backupPath: longest))
    }

    /// Security re-check: the name the helper really reports for −21 is one the app accepts.
    @Test func theLiveSwapNameIsAcceptedByTheApp() throws {
        let name = TouchIDSudoDisabler.makeSwapName()
        #expect(name.hasPrefix(TouchIDSudoDisabler.swapNamePrefix + "swap-"))
        #expect(UUID(uuidString: String(name.dropFirst((TouchIDSudoDisabler.swapNamePrefix + "swap-").count))) != nil)
        #expect(name != TouchIDSudoDisabler.makeSwapName(), "a fresh name per call")
        let path = TouchIDSudoDisabler.reportedPath(of: name)
        #expect(path == "/etc/pam.d/" + name)
        #expect(TouchIDSudoDisableResult(wireCode: -21, detail: path) == .rollbackFailed(backupPath: path))
    }

    /// Nothing from the file can reach the daemon's log: the report carries no byte of it.
    @Test func theReportHoldsNoContentOfTheFile() {
        let report = TouchIDSudoDisableReport(result: .nothingToRemove)
        let labels = Mirror(reflecting: report).children.compactMap(\.label)
        #expect(labels == ["result", "failedStep", "fallbackPolicyPath", "linkCount", "leftBehindPath"])
    }

    // MARK: - Fallback policy paths

    @Test func theFallbackPathsAreOpenPAMsLaterPolicyFiles() {
        #expect(TouchIDSudoDisabler.fallbackPolicyPaths == [
            "/etc/pam.conf", "/usr/local/etc/pam.d/sudo_local", "/usr/local/etc/pam.conf", "/usr/share/pam.d/sudo_local",
        ])
    }

    // MARK: - Readback

    @Test func theReadbackMustBeThePlanAndMeanNothingActive() {
        let wega = TouchIDSudoConfigurator.pamDirective
        let original = Data(("# c\n" + wega + "\n").utf8)
        let expected = Data("# c\n".utf8)
        #expect(TouchIDSudoDisabler.readbackIsAcceptable(expected, expected: expected, original: original))
        #expect(!TouchIDSudoDisabler.readbackIsAcceptable(Data("# d\n".utf8), expected: expected, original: original),
                "foreign bytes")
        let active = Data("auth required pam_deny.so\n".utf8)
        #expect(!TouchIDSudoDisabler.readbackIsAcceptable(active, expected: active, original: Data(("auth required pam_deny.so\n" + wega + "\n").utf8)),
                "(f) an active line left")
        let stillThere = Data((wega + "\n").utf8)
        #expect(!TouchIDSudoDisabler.readbackIsAcceptable(stillThere, expected: stillThere, original: stillThere),
                "(c) the directive is still there")
        #expect(!TouchIDSudoDisabler.readbackIsAcceptable(Data(), expected: Data(), original: original),
                "(a) a comment line went missing")
    }
}
