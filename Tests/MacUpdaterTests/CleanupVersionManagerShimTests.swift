import XCTest
@testable import MacUpdaterCore

private struct NoDependentsBrew: CleanupBrewQuerying {
    func usesInstalled(formula: String) async throws -> [String] { [] }
    func cleanupDryRun(package: String?) async throws -> [CleanupBrewCleanupItem] { [] }
    func autoremoveDryRun() async throws -> [String] { [] }
}

/// A version manager's shim (`~/.local/share/mise/shims/node`, `~/.pyenv/shims/python3`) runs the
/// version the manager selects. It is not a copy of the tool: the mise shim resolves to the `mise`
/// binary itself, so "its" Homebrew package is the manager.
final class CleanupVersionManagerShimTests: XCTestCase {
    private var tmp: CleanupTempHome!
    private var brewPrefix: URL!

    override func setUpWithError() throws {
        tmp = try CleanupTempHome()
        brewPrefix = tmp.url("opt/homebrew")
    }

    private func findings(path directories: [String]) async -> [CleanupFinding] {
        let guarded = GuardedCleanupFileSystem(
            base: LiveCleanupFileSystem(trash: { _ in }),
            guard: ProtectedLocationGuard(home: tmp.home, mounts: FixedMountTable(["/"]))
        )
        let classifier = CleanupSourceClassifier(
            home: tmp.home, brewPrefix: brewPrefix, systemPrefixes: [tmp.url("usr/bin").path]
        )
        let snapshot = CleanupPathSnapshot(
            entries: directories.map { tmp.url($0).path }, ignoredEntries: [], shell: nil, capturedAt: nil,
            isApproximate: false
        )
        let scan = CleanupPathDuplicateDetector(fileSystem: guarded, classifier: classifier).scan(snapshot)
        let builder = CleanupDuplicateFindings(
            brew: NoDependentsBrew(),
            inspector: FakeProcessInspector(processes: [], bootTime: Date(timeIntervalSince1970: 0)),
            fileSystem: guarded, brewPrefix: brewPrefix, home: tmp.home, pathIsApproximate: false
        )
        return await builder.build(scan).findings
    }

    private func finding(at relative: String, in findings: [CleanupFinding]) throws -> CleanupFinding {
        let path = tmp.url(relative).path
        return try XCTUnwrap(findings.first { $0.path.path == path }, "no finding for \(relative)")
    }

    private func assertIsShim(
        _ shim: CleanupFinding, of manager: CleanupVersionManager, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(shim.status, .expected, file: file, line: line)
        XCTAssertEqual(shim.source, .versionManager(manager), file: file, line: line)
        XCTAssertEqual(shim.action, .none, file: file, line: line)
        XCTAssertNil(shim.candidate, "a shim is neither a copy to keep nor one to remove", file: file, line: line)
        XCTAssertNil(shim.size, file: file, line: line)
        XCTAssertEqual(shim.bucket, .excluded, file: file, line: line)
    }

    /// The owner's scan of 2026-11-21: `mise activate` puts the install first, the shims directory
    /// follows, and each of 36 shims offered `brew uninstall mise` with the 244 MB of mise.
    func testMiseShimBehindTheInstallOffersNothingToRemove() async throws {
        let mise = try tmp.file("opt/homebrew/Cellar/mise/2026.11.12/bin/mise", size: 4096, executable: true)
        try tmp.symlink(".local/share/mise/shims/node", to: mise.path)
        try tmp.file(".local/share/mise/installs/node/24.22.3/bin/node", size: 4096, executable: true)

        let result = await findings(path: [".local/share/mise/installs/node/24.22.3/bin", ".local/share/mise/shims"])

        assertIsShim(try finding(at: ".local/share/mise/shims/node", in: result), of: .mise)
        let install = try finding(at: ".local/share/mise/installs/node/24.22.3/bin/node", in: result)
        XCTAssertEqual(install.status, .active)
        XCTAssertNil(install.candidate, "with the shim set aside the install has no rival to choose between")
        XCTAssertFalse(result.contains { $0.action == .brew(.uninstallFormula("mise")) })
        XCTAssertEqual(CleanupTotals.sum(result), CleanupTotals(safe: 0, needsDecision: 0))
    }

    /// `pyenv init` puts the shims first. Terminal runs the shim, and the copy behind it may be the
    /// version the manager falls back to as `system`, so nothing behind the shim is offered either.
    func testPyenvShimAheadOfHomebrewHoldsPathAndNothingBehindItIsOffered() async throws {
        try tmp.file(".pyenv/shims/python3", text: "#!/usr/bin/env bash\nexec pyenv exec python3 \"$@\"\n", executable: true)
        let formula = try tmp.file("opt/homebrew/Cellar/python@3.13/3.13.1/bin/python3", size: 4096, executable: true)
        try tmp.symlink("opt/homebrew/bin/python3", to: formula.path)

        let result = await findings(path: [".pyenv/shims", "opt/homebrew/bin"])

        assertIsShim(try finding(at: ".pyenv/shims/python3", in: result), of: .pyenv)
        let behind = try finding(at: "opt/homebrew/bin/python3", in: result)
        XCTAssertEqual(behind.status, .shadowed)
        XCTAssertEqual(behind.reason, .shadowedBy(path: tmp.url(".pyenv/shims/python3").path))
        XCTAssertEqual(behind.action, .none)
        XCTAssertNil(behind.candidate)
        XCTAssertEqual(behind.bucket, .excluded)
        XCTAssertFalse(result.contains { $0.status == .active }, "the shim, not the Homebrew copy, is what Terminal runs")
    }

    func testAsdfShimAheadOfHomebrewIsAShim() async throws {
        try tmp.file(".asdf/shims/node", text: "#!/usr/bin/env bash\nexec asdf exec node \"$@\"\n", executable: true)
        let formula = try tmp.file("opt/homebrew/Cellar/node/24.1.0/bin/node", size: 4096, executable: true)
        try tmp.symlink("opt/homebrew/bin/node", to: formula.path)

        let result = await findings(path: [".asdf/shims", "opt/homebrew/bin"])

        assertIsShim(try finding(at: ".asdf/shims/node", in: result), of: .asdf)
        XCTAssertEqual(try finding(at: "opt/homebrew/bin/node", in: result).action, .none)
    }
}
