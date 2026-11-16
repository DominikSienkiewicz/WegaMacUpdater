import XCTest
@testable import MacUpdaterCore

private struct ScriptedBrew: CleanupBrewQuerying {
    var uses: [String: [String]] = [:]
    var error: Error?

    func usesInstalled(formula: String) async throws -> [String] {
        if let error { throw error }
        return uses[formula] ?? []
    }
}

private struct BrewFailure: Error {}

final class CleanupDuplicateFindingsTests: XCTestCase {
    private var tmp: CleanupTempHome!
    private var brewPrefix: URL!
    private var processes: [CleanupProcess] = []

    override func setUpWithError() throws {
        tmp = try CleanupTempHome()
        brewPrefix = tmp.url("opt/homebrew")
        processes = []
    }

    private func builder(_ brew: ScriptedBrew = ScriptedBrew()) -> CleanupDuplicateFindings {
        let guarded = GuardedCleanupFileSystem(
            base: LiveCleanupFileSystem(trash: { _ in }),
            guard: ProtectedLocationGuard(home: tmp.home, mounts: FixedMountTable(["/"]))
        )
        return CleanupDuplicateFindings(
            brew: brew,
            inspector: FakeProcessInspector(processes: processes, bootTime: Date(timeIntervalSince1970: 0)),
            fileSystem: guarded, brewPrefix: brewPrefix, home: tmp.home
        )
    }

    private func copy(
        _ path: URL, real: URL? = nil, source: CleanupSource, version: String? = nil, role: CleanupCopyRole, index: Int
    ) -> CleanupCopy {
        CleanupCopy(
            path: path, realpath: real ?? path, pathIndex: index, source: source, version: version,
            identity: CleanupFileIdentity(device: 1, inode: UInt64(index + 1)), role: role
        )
    }

    private func scan(_ name: String, _ copies: [CleanupCopy]) -> CleanupPathScan {
        CleanupPathScan(groups: [CleanupToolGroup(name: name, copies: copies)], skippedProtected: [], missingDirectories: [])
    }

    private func shadowed(
        source: CleanupSource, version: String? = "2.1.311", activeVersion: String? = "2.1.325", real: URL? = nil
    ) -> CleanupPathScan {
        let active = copy(
            tmp.url(".local/bin/tool"), source: .standalone, version: activeVersion, role: .active, index: 0
        )
        let other = copy(tmp.url("bin2/tool"), real: real, source: source, version: version, role: .shadowed, index: 1)
        return scan("tool", [active, other])
    }

    private func shadowedFinding(_ result: (findings: [CleanupFinding], notes: [CleanupDetectorNote])) throws -> CleanupFinding {
        try XCTUnwrap(result.findings.first { $0.status != .active })
    }

    func testShadowedCaskGetsUninstallCaskAndIsSafeWhenOlder() async throws {
        let real = try tmp.file("opt/homebrew/Caskroom/claude-code/2.1.311/claude", size: 4096, executable: true)
        let result = await builder().build(shadowed(source: .homebrewCask(token: "claude-code"), real: real))

        let finding = try shadowedFinding(result)
        XCTAssertEqual(finding.action, .brew(.uninstallCask("claude-code")))
        XCTAssertEqual(finding.bucket, .safe)
        XCTAssertEqual(finding.status, .shadowed)
        XCTAssertEqual(finding.reason, .shadowedBy(path: tmp.url(".local/bin/tool").path))
        XCTAssertGreaterThan(try XCTUnwrap(finding.size), 0)
        XCTAssertEqual(finding.detector, .pathDuplicates)
        XCTAssertEqual(finding.tool, "tool")
    }

    func testShadowedFormulaWithoutDependentsGetsUninstallFormula() async throws {
        let real = try tmp.file("opt/homebrew/Cellar/gh/2.104.0/bin/gh", executable: true)
        let result = await builder().build(shadowed(source: .homebrewFormula(name: "gh"), version: "2.104.0", activeVersion: nil, real: real))

        let finding = try shadowedFinding(result)
        XCTAssertEqual(finding.action, .brew(.uninstallFormula("gh")))
        XCTAssertEqual(finding.bucket, .needsDecision)
    }

    func testFormulaWithDependentsIsExcludedAsDependency() async throws {
        let real = try tmp.file("opt/homebrew/Cellar/python@3.15/3.15.0/bin/python3", executable: true)
        let dependents = ["mlx", "mlx-c", "nmap", "ollama"]
        let brew = ScriptedBrew(uses: ["python@3.15": dependents])
        let result = await builder(brew).build(shadowed(source: .homebrewFormula(name: "python@3.15"), version: "3.15.0", real: real))

        let finding = try shadowedFinding(result)
        XCTAssertEqual(finding.status, .dependency(dependents))
        XCTAssertEqual(finding.reason, .requiredBy(dependents))
        XCTAssertEqual(finding.action, .none)
        XCTAssertEqual(finding.bucket, .excluded)
    }

    func testAppProvidedLinkGetsAdminInstruction() async throws {
        let result = await builder().build(shadowed(source: .appBundle(name: "Ollama")))

        let finding = try shadowedFinding(result)
        XCTAssertEqual(finding.action, .instruction(.removeAppLinkWithAdminRights(link: tmp.url("bin2/tool").path)))
    }

    func testExpectedSystemCopyHasNoActionAndNoSize() async throws {
        let system = copy(URL(filePath: "/usr/bin/tool", directoryHint: .notDirectory), source: .system, role: .expected, index: 1)
        let active = copy(tmp.url(".local/bin/tool"), source: .standalone, role: .active, index: 0)
        let result = await builder().build(scan("tool", [active, system]))

        let finding = try XCTUnwrap(result.findings.first { $0.status == .expected })
        XCTAssertEqual(finding.action, .none)
        XCTAssertEqual(finding.reason, .systemCopy)
        XCTAssertEqual(finding.bucket, .excluded)
        XCTAssertNil(finding.size)
        let activeFinding = try XCTUnwrap(result.findings.first { $0.status == .active })
        XCTAssertEqual(activeFinding.reason, .currentVersion)
        XCTAssertEqual(activeFinding.action, .none)
    }

    func testBrokenLinkHasNoAction() async throws {
        let broken = copy(tmp.url("bin2/tool"), real: nil, source: .standalone, role: .brokenLink, index: 1)
        let active = copy(tmp.url(".local/bin/tool"), source: .standalone, role: .active, index: 0)
        let result = await builder().build(scan("tool", [active, broken]))

        let finding = try XCTUnwrap(result.findings.first { $0.status == .brokenLink })
        XCTAssertEqual(finding.reason, .brokenLink)
        XCTAssertEqual(finding.action, .none)
        XCTAssertEqual(finding.bucket, .excluded)
    }

    func testMissingHomebrewDegradesToANote() async throws {
        let real = try tmp.file("opt/homebrew/Cellar/gh/2.104.0/bin/gh", executable: true)
        let result = await builder(ScriptedBrew(error: BrewServiceError.brewNotFound))
            .build(shadowed(source: .homebrewFormula(name: "gh"), version: "2.104.0", real: real))

        XCTAssertEqual(result.notes, [CleanupDetectorNote(detector: .homebrew, kind: .homebrewUnavailable)])
        let finding = try shadowedFinding(result)
        XCTAssertEqual(finding.status, .shadowed)
        XCTAssertEqual(finding.action, .none)
        XCTAssertEqual(result.findings.count, 2)
    }

    func testOtherBrewErrorIsOneFailedNote() async throws {
        let real = try tmp.file("opt/homebrew/Cellar/gh/2.104.0/bin/gh", executable: true)
        let result = await builder(ScriptedBrew(error: BrewFailure()))
            .build(shadowed(source: .homebrewFormula(name: "gh"), version: "2.104.0", real: real))

        XCTAssertEqual(result.notes, [CleanupDetectorNote(detector: .homebrew, kind: .failed)])
        XCTAssertEqual(try shadowedFinding(result).action, .none)
    }

    func testStandaloneFileGetsTrashWithItsSize() async throws {
        let real = try tmp.file("bin2/tool", size: 8192, executable: true)
        let result = await builder().build(shadowed(source: .standalone, version: nil, activeVersion: nil, real: real))

        let finding = try shadowedFinding(result)
        XCTAssertEqual(finding.action, .trash([tmp.url("bin2/tool")]))
        XCTAssertEqual(finding.bucket, .needsDecision)
        XCTAssertGreaterThan(try XCTUnwrap(finding.size), 0)
    }

    func testStandaloneInsideVersionDirectoryIsLeftToTheCreatingTool() async throws {
        try tmp.file("apps/tool/1.0.0/bin/tool", executable: true)
        let real = try tmp.file("apps/tool/2.0.0/bin/tool", executable: true)
        let result = await builder().build(shadowed(source: .standalone, version: nil, real: real))

        XCTAssertEqual(try shadowedFinding(result).action, .instruction(.removeWithCreatingTool))
    }

    func testPackageManagerCommands() async throws {
        let cases: [String: (source: CleanupSource, action: CleanupAction)] = [
            "lib/node_modules/@scope/pkg/bin/tool": (.packageManager(.npm), .command("npm uninstall -g @scope/pkg")),
            "lib/node_modules/plain/bin/tool": (.packageManager(.npm), .command("npm uninstall -g plain")),
            ".local/pipx/venvs/black/bin/tool": (.packageManager(.pipx), .command("pipx uninstall black")),
            ".cargo/bin/tool": (.packageManager(.cargo), .command("cargo uninstall tool")),
            ".bun/bin/tool": (.packageManager(.bun), .instruction(.removeWithCreatingTool)),
            ".fnm/node/bin/tool": (.versionManager(.fnm), .instruction(.removeWithCreatingTool)),
        ]
        for (relative, expected) in cases {
            let finding = try shadowedFinding(await builder().build(shadowed(source: expected.source, real: tmp.url(relative))))
            XCTAssertEqual(finding.action, expected.action, relative)
        }
    }

    func testUvCommands() async throws {
        let tool = try shadowedFinding(await builder().build(shadowed(
            source: .versionManager(.uv), real: tmp.url(".local/share/uv/tools/ruff/bin/tool")
        )))
        XCTAssertEqual(tool.action, .command("uv tool uninstall ruff"))
        let python = try shadowedFinding(await builder().build(shadowed(
            source: .versionManager(.uv), version: "3.12.4", real: tmp.url(".local/share/uv/python/cpython-3.12.4/bin/tool")
        )))
        XCTAssertEqual(python.action, .command("uv python uninstall 3.12.4"))
    }

    func testAppManagedSystemAndNativeCopiesHaveNoAction() async throws {
        for source in [CleanupSource.appManaged(owner: "X"), .system, .nativeVersionDirectory(tool: "tool")] {
            let finding = try shadowedFinding(await builder().build(shadowed(source: source)))
            XCTAssertEqual(finding.action, .none, "\(source)")
        }
    }

    func testRunningProcessMakesTheCopyInUseAndHighRisk() async throws {
        let real = try tmp.file("bin2/tool", executable: true)
        let process = CleanupProcess(pid: 7, name: "tool", executablePath: real.path, arguments: [])
        processes = [process]
        let result = await builder().build(shadowed(source: .standalone, real: real))

        let finding = try shadowedFinding(result)
        XCTAssertEqual(finding.status, .inUse([process]))
        XCTAssertEqual(finding.risk, .high)
        XCTAssertEqual(finding.bucket, .needsDecision)
    }

    func testNewerShadowedCopyNeedsDecision() async throws {
        let result = await builder().build(shadowed(source: .homebrewCask(token: "c"), version: "3.0.0", activeVersion: "2.0.0", real: tmp.url("opt/homebrew/Caskroom/c/3.0.0/c")))
        XCTAssertEqual(try shadowedFinding(result).bucket, .needsDecision)
    }
}
