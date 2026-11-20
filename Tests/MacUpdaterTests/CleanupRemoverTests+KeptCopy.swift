import XCTest
@testable import MacUpdaterCore

/// Records every Homebrew query and removal; no formula has dependents.
private final class KeptCopyBrew: CleanupBrewQuerying, CleanupBrewRemoving, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []

    var calls: [String] { lock.withLock { recorded } }

    func usesInstalled(formula: String) async throws -> [String] {
        record("uses \(formula)")
        return []
    }

    func cleanupDryRun(package: String?) async throws -> [CleanupBrewCleanupItem] { [] }
    func autoremoveDryRun() async throws -> [String] { [] }
    func uninstallCask(token: String) async throws { record("uninstall --cask \(token)") }
    func uninstallFormula(name: String) async throws { record("uninstall \(name)") }
    func cleanupPackage(name: String) async throws { record("cleanup \(name)") }

    private func record(_ call: String) {
        lock.withLock { recorded.append(call) }
    }
}

/// A temporary home with the Homebrew `ollama` formula linked at `opt/homebrew/bin/ollama`.
private struct KeptCopyHome {
    let home: CleanupTempHome
    let trash = RecordingTrash()
    let fileSystem: CleanupFileSystem
    let brew = KeptCopyBrew()
    let formulaLink: URL

    init() throws {
        home = try CleanupTempHome()
        let trash = trash
        fileSystem = GuardedCleanupFileSystem(
            base: LiveCleanupFileSystem(trash: { trash.record($0) }),
            guard: ProtectedLocationGuard(home: home.home, mounts: FixedMountTable(["/"]))
        )
        let formula = try home.file("opt/homebrew/Cellar/ollama/0.40.16/bin/ollama", size: 64, executable: true)
        formulaLink = try home.symlink("opt/homebrew/bin/ollama", to: formula.path)
    }

    var remover: CleanupRemover {
        CleanupRemover(
            fileSystem: fileSystem, inspector: FakeProcessInspector(processes: [], bootTime: Date(timeIntervalSince1970: 0)),
            brewQuery: brew, brewRemoval: brew, coordinator: OperationCoordinator(), home: home.home,
            today: { Date(timeIntervalSince1970: 0) }
        )
    }

    /// The PATH-active formula copy the user did not keep, as the scan saw it; `candidateKeep`
    /// adds the candidate record a resolved D1 finding carries.
    func notKeptFormula(keeping kept: URL, candidateKeep: CleanupKeep? = nil) throws -> CleanupFinding {
        let identity = try XCTUnwrap(fileSystem.entry(at: formulaLink)).identity
        return CleanupFinding(
            detector: .pathDuplicates, tool: "ollama", path: formulaLink, realpath: nil,
            source: .homebrewFormula(name: "ollama"), version: "0.40.16", size: nil, status: .active,
            reason: .keptInstead(path: kept.path), action: .brew(.uninstallFormula("ollama")),
            risk: .low, bucket: .needsDecision, identity: identity,
            candidate: candidateKeep.map {
                CleanupCandidate(
                    pathRole: .active, removal: .brew(.uninstallFormula("ollama")), removalSize: nil, dependents: [],
                    processes: [], keep: $0
                )
            }
        )
    }
}

// MARK: - A not-kept copy goes only while the kept copy works (kept out of CleanupRemoverTests.swift for SwiftLint file_length)

extension CleanupRemoverTests {
    func testNotKeptActiveFormulaIsRemovedWhileTheKeptCopyWorks() async throws {
        let setup = try KeptCopyHome()
        let app = try setup.home.file("Applications/Ollama.app/Contents/Resources/ollama", size: 16, executable: true)
        let kept = try setup.home.symlink("usr/local/bin/ollama", to: app.path)
        let finding = try setup.notKeptFormula(keeping: kept)

        let outcome = await setup.remover.execute(CleanupRemovalIntent(finding: finding, inUseAcknowledged: false))

        XCTAssertEqual(outcome, .removed)
        XCTAssertEqual(setup.brew.calls, ["uses ollama", "uninstall ollama"])
    }

    func testNotKeptCopyIsRefusedWhenTheKeptCopyIsGone() async throws {
        let setup = try KeptCopyHome()
        let finding = try setup.notKeptFormula(keeping: setup.home.url("usr/local/bin/ollama"))

        let outcome = await setup.remover.execute(CleanupRemovalIntent(finding: finding, inUseAcknowledged: true))

        XCTAssertEqual(outcome, .changedSinceScan)
        XCTAssertEqual(setup.brew.calls, [], "no brew call once the kept copy is gone")
        XCTAssertEqual(setup.trash.urls, [])
    }

    /// A candidate copy offers a removal only against a kept copy; without a kept path in its
    /// reason (a persisted or hand-made finding) the remover refuses instead of trusting the action.
    func testCandidateCopyWithoutAKeptPathIsRefused() async throws {
        let setup = try KeptCopyHome()
        let file = try setup.home.file("bin2/tool", size: 16, executable: true)
        let finding = CleanupFinding(
            detector: .pathDuplicates, tool: "tool", path: file, realpath: file, source: .standalone, version: nil,
            size: 16, status: .shadowed, reason: .noCopyKept, action: .trash([file]), risk: .low, bucket: .needsDecision,
            identity: try XCTUnwrap(setup.fileSystem.entry(at: file)).identity,
            candidate: CleanupCandidate(
                pathRole: .shadowed, removal: .trash([file]), removalSize: 16, dependents: [], processes: [], keep: .undecided
            )
        )

        let outcome = await setup.remover.execute(CleanupRemovalIntent(finding: finding, inUseAcknowledged: true))

        XCTAssertEqual(outcome, .changedSinceScan)
        XCTAssertEqual(setup.trash.urls, [])
    }

    func testCandidateWhoseKeptPathDisagreesWithItsReasonIsRefused() async throws {
        let setup = try KeptCopyHome()
        let app = try setup.home.file("Applications/Ollama.app/Contents/Resources/ollama", size: 16, executable: true)
        let kept = try setup.home.symlink("usr/local/bin/ollama", to: app.path)
        let other = setup.home.url("Users/other/bin/ollama").path

        for keep in [CleanupKeep.notKept(keptPath: other), .kept, .undecided] {
            let finding = try setup.notKeptFormula(keeping: kept, candidateKeep: keep)
            let outcome = await setup.remover.execute(CleanupRemovalIntent(finding: finding, inUseAcknowledged: true))
            XCTAssertEqual(outcome, .changedSinceScan, "\(keep)")
        }
        XCTAssertEqual(setup.brew.calls, [])

        let agreeing = try setup.notKeptFormula(keeping: kept, candidateKeep: .notKept(keptPath: kept.path))
        let outcome = await setup.remover.execute(CleanupRemovalIntent(finding: agreeing, inUseAcknowledged: false))
        XCTAssertEqual(outcome, .removed)
    }

    /// `brew uninstall ollama` removes every version, so a kept copy that now resolves into
    /// `Cellar/ollama` would go with it.
    func testNotKeptCopyIsRefusedWhenTheKeptCopyLivesInTheRemovedPackage() async throws {
        let setup = try KeptCopyHome()
        let newer = try setup.home.file("opt/homebrew/Cellar/ollama/0.41.0/bin/ollama", size: 16, executable: true)
        let kept = try setup.home.symlink("usr/local/bin/ollama", to: newer.path)
        let finding = try setup.notKeptFormula(keeping: kept)

        let outcome = await setup.remover.execute(CleanupRemovalIntent(finding: finding, inUseAcknowledged: true))

        XCTAssertEqual(outcome, .changedSinceScan)
        XCTAssertEqual(setup.brew.calls, [])
        XCTAssertEqual(setup.trash.urls, [])
    }
}
