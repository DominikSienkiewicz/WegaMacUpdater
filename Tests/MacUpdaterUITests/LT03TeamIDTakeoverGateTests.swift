import Foundation
import Testing
import MacUpdaterCore
@testable import WegaMacUpdater

/// LT-03 — the production wiring of the Team ID branch. `CaskMatchScorer` could always take
/// two publisher identities, but `MigrationStore` passed neither, so the branch that exists
/// precisely to stop a wrong `brew install --cask --force` never ran outside unit tests.
/// These tests pin the supply at the call site that overwrites the user's app.
@Suite("LT-03 Team ID gate on automatic takeover")
@MainActor
struct LT03TeamIDTakeoverGateTests {
    private func packageRoot(file: String = #filePath) -> URL {
        URL(fileURLWithPath: file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func source(_ relativePath: String) throws -> String {
        try String(contentsOf: packageRoot().appendingPathComponent(relativePath), encoding: .utf8)
    }

    private func figma() -> ApplicationInfo {
        // "Figma" ↔ token "figma" is an exact normalized token match: on names alone it
        // scores `.high` and the takeover runs unattended (see P1BackendsTests).
        ApplicationInfo(
            path: URL(fileURLWithPath: "/Applications/Figma.app"),
            name: "Figma",
            bundleIdentifier: "com.figma.Desktop",
            version: "1.0",
            installDate: nil,
            updateDate: nil,
            isManagedByBrew: false,
            caskToken: "figma"
        )
    }

    /// The behaviour the card asks for: the installed bundle is signed by a publisher the
    /// ledger never recorded for this cask, so the automatic takeover is refused — even
    /// though the names match exactly. The guard runs before any workspace inspection, so a
    /// refusal never even queries the running applications.
    @Test func aPublisherMismatchBlocksTheAutomaticTakeover() async {
        let inspector = RecordingInspector()
        let store = MigrationStore(
            runningApplicationInspector: inspector,
            publisherCorrelator: CaskPublisherCorrelator(
                expectedTeamIDForCask: { _ in "T8RA8NEUTP" },
                installedTeamIDForApp: { _ in "IMPOSTOR99" }
            )
        )

        await store.migrate(figma(), model: AppViewModel(), onWegaState: nil)

        #expect(store.errorMessage != nil,
                "LT-03: a publisher mismatch must tell the user why the takeover stopped")
        #expect(store.errorMessage?.contains("IMPOSTOR99") == true,
                "LT-03: the message must name the publisher actually found on disk")
        #expect(store.errorMessage?.contains("T8RA8NEUTP") == true,
                "LT-03: the message must name the publisher expected for the cask")
        #expect(store.migrating == nil,
                "LT-03: a blocked takeover must not stay marked in-flight")
        #expect(store.migrated.isEmpty,
                "LT-03: a blocked takeover must not record the token as adopted")
        #expect(inspector.callCount == 0,
                "LT-03: the veto must precede execution — not even the workspace is queried")
    }

    /// The ledger knowing nothing about this cask must change nothing: no publisher signal,
    /// no correlation, the pre-LT-03 name heuristics decide — and the signature is never read.
    @Test func anUnknownCaskPublisherLeavesTheNameHeuristicsUntouched() async {
        let reads = ReadCounter()
        let store = MigrationStore(
            runningApplicationInspector: RecordingInspector(),
            publisherCorrelator: CaskPublisherCorrelator(
                expectedTeamIDForCask: { _ in nil },
                installedTeamIDForApp: { _ in
                    reads.record()
                    return "T8RA8NEUTP"
                }
            )
        )
        // "VS Code" ↔ "visual-studio-code" is fuzzy only ⇒ `.low` ⇒ blocked, as before LT-03.
        let app = ApplicationInfo(
            path: URL(fileURLWithPath: "/Applications/VS Code.app"),
            name: "VS Code",
            bundleIdentifier: "com.microsoft.VSCode",
            version: "1.0",
            installDate: nil,
            updateDate: nil,
            isManagedByBrew: false,
            caskToken: "visual-studio-code"
        )

        await store.migrate(app, model: AppViewModel(), onWegaState: nil)

        #expect(store.errorMessage != nil)
        #expect(store.migrating == nil)
        #expect(reads.count == 0,
                "LT-03 must not read a code signature when there is no recorded cask publisher")
    }

    /// The scan-time pass that feeds the confidence badge, so the row never signature-checks
    /// during a SwiftUI body evaluation.
    @Test func theScanPassCorrelatesOnlyCandidatesWithARecordedCaskPublisher() async {
        let correlator = CaskPublisherCorrelator(
            expectedTeamIDForCask: { $0 == "figma" ? "T8RA8NEUTP" : nil },
            installedTeamIDForApp: { _ in "T8RA8NEUTP" }
        )
        let other = ApplicationInfo(
            path: URL(fileURLWithPath: "/Applications/Other.app"),
            name: "Other",
            bundleIdentifier: "com.example.Other",
            version: "1.0",
            installDate: nil,
            updateDate: nil,
            isManagedByBrew: false,
            caskToken: "other"
        )
        let matched = figma()

        let correlations = await MigrationStore.publisherCorrelations(
            for: [matched, other],
            using: correlator
        )

        #expect(correlations[matched.id]?.caskExpectedTeamID == "T8RA8NEUTP")
        #expect(correlations[other.id] == nil)
    }

    /// The correlation must reach the scorer, not merely exist. Source-level, like the
    /// REL-08 wiring assertions: an argument that stops being passed is exactly the silent
    /// regression that made this branch dead in the first place.
    @Test func theTakeoverGateFeedsThePublisherSignalIntoTheScorer() throws {
        let text = try source("Sources/MacUpdater/MigrationStore.swift")
        #expect(text.contains("installedAppTeamID: correlation.installedAppTeamID"),
                "LT-03: the takeover gate must pass the installed bundle's Team ID to the scorer")
        #expect(text.contains("caskExpectedTeamID: correlation.caskExpectedTeamID"),
                "LT-03: the takeover gate must pass the cask's recorded Team ID to the scorer")
    }
}

@MainActor
private final class RecordingInspector: RunningApplicationInspecting {
    private(set) var callCount = 0

    func runningApplications() -> [RunningApplicationTarget] {
        callCount += 1
        return []
    }
}

private final class ReadCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var reads = 0

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return reads
    }

    func record() {
        lock.lock(); defer { lock.unlock() }
        reads += 1
    }
}
