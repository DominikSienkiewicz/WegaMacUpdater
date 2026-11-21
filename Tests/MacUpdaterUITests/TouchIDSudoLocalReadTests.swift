import Darwin
import Foundation
@testable import MacUpdaterCore
import Testing

@testable import WegaMacUpdater

/// Z4: before it shows the disable command, the app reads `sudo_local` itself, as the user, and plans
/// the removal with the helper's own rules. The read never follows a link, never blocks on a FIFO,
/// reads only the file `lstat` saw and at most one byte past the helper's limit.
@Suite("Touch ID — the app's own read of sudo_local")
struct TouchIDSudoLocalReadTests {
    typealias Preflight = TouchIDDisablePreflight

    let directive = TouchIDSudoConfigurator.pamDirective + "\n"
    let template = "# sudo_local: local config file which survives system update and is included for sudo\n"
        + "#auth       sufficient     pam_tid.so\n"

    private func withScratch(_ body: (String) throws -> Void) throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("wega-sudo-local-read-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: base) }
        try body(base)
    }

    private func identity(of path: String) throws -> PAMFileIdentity {
        try #require(Preflight.policyFile(at: path).facts).identity
    }

    @Test func aRegularFileIsReadWhole() throws {
        try withScratch { base in
            let path = base + "/sudo_local"
            try Data((template + directive).utf8).write(to: URL(fileURLWithPath: path))
            #expect(try Preflight.readSudoLocal(atPath: path, identity: identity(of: path)) == Data((template + directive).utf8))
        }
    }

    @Test func aLinkIsNeverFollowed() throws {
        try withScratch { base in
            let target = base + "/target"
            try Data(directive.utf8).write(to: URL(fileURLWithPath: target))
            try FileManager.default.createSymbolicLink(atPath: base + "/sudo_local", withDestinationPath: target)
            #expect(try Preflight.readSudoLocal(atPath: base + "/sudo_local", identity: identity(of: target)) == nil,
                    "not even with the identity of the file it points at")
        }
    }

    @Test func aFIFODoesNotBlockAndIsNotRead() throws {
        try withScratch { base in
            let path = base + "/sudo_local"
            #expect(mkfifo(path, 0o644) == 0)
            let seen = try identity(of: path)
            #expect(Preflight.readSudoLocal(atPath: path, identity: seen) == nil)
        }
    }

    @Test func aDirectoryIsNotRead() throws {
        try withScratch { base in
            let path = base + "/sudo_local"
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false)
            let seen = try identity(of: path)
            #expect(Preflight.readSudoLocal(atPath: path, identity: seen) == nil)
        }
    }

    @Test func aFileReplacedAfterTheLookupIsNotRead() throws {
        try withScratch { base in
            let path = base + "/sudo_local"
            try Data(directive.utf8).write(to: URL(fileURLWithPath: path))
            let seen = try identity(of: path)
            try FileManager.default.removeItem(atPath: path)
            try Data(directive.utf8).write(to: URL(fileURLWithPath: base + "/other"))
            try FileManager.default.moveItem(atPath: base + "/other", toPath: path)
            #expect(try identity(of: path) != seen)
            #expect(Preflight.readSudoLocal(atPath: path, identity: seen) == nil)
        }
    }

    @Test func atMostOneBytePastTheHelpersLimitIsRead() throws {
        try withScratch { base in
            let path = base + "/sudo_local"
            try Data(repeating: UInt8(ascii: "#"), count: 70_000).write(to: URL(fileURLWithPath: path))
            let bytes = try #require(try Preflight.readSudoLocal(atPath: path, identity: identity(of: path)))
            #expect(bytes.count == TouchIDSudoDisabler.maximumSize + 1)
            #expect(TouchIDSudoConfigurator.contentsDisablingTouchID(current: bytes) == .refused(.tooLarge))
        }
    }

    // MARK: - The plan

    private func plan(_ bytes: Data?) -> TouchIDSudoDisablePlan? {
        Preflight.evaluate(.init(
            policyDirectory: .unknown, sudoLocal: .unknown, sudoPolicy: .unknown, sudoLocalBytes: bytes,
            localDirectories: [], existingFallbackPaths: [])).removalPlan
    }

    @Test func theRemovalPlanIsTheHelpersOwnOnTheBytesTheAppRead() {
        #expect(plan(Data((template + directive).utf8)) == .remove(lines: 1, contents: Data(template.utf8)))
        #expect(plan(Data(template.utf8)) == .nothingToRemove)
        #expect(plan(Data((directive + "auth       required       pam_deny.so\n").utf8)) == .refused(.otherDirectivesPresent))
        #expect(plan(Data((directive + "# a \\\n").utf8)) == .refused(.lineContinuation))
        #expect(plan(nil) == nil, "nothing read, nothing planned")
        #expect(Preflight.clear.removalPlan == nil)
    }
}
