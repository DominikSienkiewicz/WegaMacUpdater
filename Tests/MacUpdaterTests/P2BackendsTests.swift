import Testing
import Foundation
@testable import MacUpdaterCore

@Suite("P2Backends")
struct P2BackendsTests {

    // MARK: SEC-06 — path-traversal guard

    @Test func bundleIDSafetyRejectsTraversal() {
        #expect(MigrationPlanner.isSafeBundleID("com.apple.Safari") == true)
        #expect(MigrationPlanner.isSafeBundleID("../../tmp/x") == false)
        #expect(MigrationPlanner.isSafeBundleID("a/b") == false)
        #expect(MigrationPlanner.isSafeBundleID("") == false)
    }

    @Test func leftoverCandidatesEmptyForUnsafeBundleID() {
        let home = URL(fileURLWithPath: "/Users/test")
        #expect(MigrationPlanner.libraryLeftoverCandidates(bundleId: "../../etc", home: home).isEmpty)
        #expect(!MigrationPlanner.libraryLeftoverCandidates(bundleId: "com.x.app", home: home).isEmpty)
    }

    // MARK: FEAT-04 — Team ID ledger

    @Test func teamIDClassify() {
        #expect(TeamIDLedger.classify(stored: nil, new: "AAA") == .firstSeen(teamID: "AAA"))
        #expect(TeamIDLedger.classify(stored: "AAA", new: "AAA") == .unchanged(teamID: "AAA"))
        #expect(TeamIDLedger.classify(stored: "AAA", new: "BBB") == .changed(old: "AAA", new: "BBB"))
    }

    @Test func teamIDLedgerRecordRoundTrip() throws {
        let defaults = try #require(UserDefaults(suiteName: "wega-test-\(UUID().uuidString)"))
        let ledger = TeamIDLedger(defaults: defaults)
        #expect(ledger.record(bundleID: "com.x", teamID: "AAA") == .firstSeen(teamID: "AAA"))
        #expect(ledger.record(bundleID: "com.x", teamID: "AAA") == .unchanged(teamID: "AAA"))
        #expect(ledger.record(bundleID: "com.x", teamID: "BBB") == .changed(old: "AAA", new: "BBB"))
        #expect(ledger.teamID(forBundleID: "com.x") == "BBB")
    }

    // MARK: FEAT-05 — clonefile snapshot (Darwin/APFS)

    @Test func cloneAndRestoreRoundTrip() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wega-snap-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let original = root.appendingPathComponent("App")
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: true)
        try Data("v1".utf8).write(to: original.appendingPathComponent("payload"))

        let snapshot = root.appendingPathComponent("App.bak")
        try BundleSnapshot.clone(original, to: snapshot)
        #expect(FileManager.default.fileExists(atPath: snapshot.appendingPathComponent("payload").path))

        // "bad upgrade" mutates the original, then we restore the clone.
        try Data("v2-bad".utf8).write(to: original.appendingPathComponent("payload"))
        try BundleSnapshot.restore(snapshot: snapshot, to: original)
        let restored = try String(contentsOf: original.appendingPathComponent("payload"), encoding: .utf8)
        #expect(restored == "v1")
    }

    // MARK: FEAT-06 — release-notes heuristic

    @Test func heuristicFlagsSecurityNotes() {
        #expect(ReleaseNotesTriage.heuristic("Fixes CVE-2026-1234 in the parser").isLikelySecurityFix)
        #expect(ReleaseNotesTriage.heuristic("Patched a sandbox escape").isLikelySecurityFix)
        #expect(ReleaseNotesTriage.heuristic("Added dark mode and faster startup").isLikelySecurityFix == false)
    }

    // MARK: FEAT-07 — download gate

    @Test func downloadGatePolicy() {
        let smallSize: Int64 = 5 * 1024 * 1024
        let bigSize: Int64 = 500 * 1024 * 1024

        // Small downloads always pass, even on a hotspot.
        #expect(DownloadGate.decide(sizeBytes: smallSize,
                                    network: .init(isExpensive: true, isConstrained: false),
                                    power: .plugged) == .allow)
        // Large + metered → postpone.
        if case .postpone = DownloadGate.decide(sizeBytes: bigSize,
                                                network: .init(isExpensive: true, isConstrained: false),
                                                power: .plugged) {} else { Issue.record("expected postpone on metered") }
        // Large + thermal throttle → postpone.
        if case .postpone = DownloadGate.decide(sizeBytes: bigSize,
                                                network: .unrestricted,
                                                power: .init(onBattery: false, batteryFraction: nil, thermalSerious: true)) {} else { Issue.record("expected postpone on thermal") }
        // Large + good conditions → allow.
        #expect(DownloadGate.decide(sizeBytes: bigSize, network: .unrestricted, power: .plugged) == .allow)
        // Large + low battery → postpone.
        if case .postpone = DownloadGate.decide(sizeBytes: bigSize,
                                                network: .unrestricted,
                                                power: .init(onBattery: true, batteryFraction: 0.1, thermalSerious: false)) {} else { Issue.record("expected postpone on low battery") }
    }

    // MARK: SEC-08 — auth headers (no-token path)

    @Test func githubAuthHeadersAlwaysHaveAccept() {
        #expect(GitHubAuth.headers()["Accept"] == "application/vnd.github+json")
    }
}
