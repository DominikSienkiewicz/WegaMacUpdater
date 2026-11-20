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

    /// The PATH-active formula copy the user did not keep, as the scan saw it.
    func notKeptFormula(keeping kept: URL) throws -> CleanupFinding {
        let identity = try XCTUnwrap(fileSystem.entry(at: formulaLink)).identity
        return CleanupFinding(
            detector: .pathDuplicates, tool: "ollama", path: formulaLink, realpath: nil,
            source: .homebrewFormula(name: "ollama"), version: "0.40.16", size: nil, status: .active,
            reason: .keptInstead(path: kept.path), action: .brew(.uninstallFormula("ollama")),
            risk: .low, bucket: .needsDecision, identity: identity
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
