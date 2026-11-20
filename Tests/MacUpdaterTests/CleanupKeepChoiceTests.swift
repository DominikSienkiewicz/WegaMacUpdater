import XCTest
@testable import MacUpdaterCore

final class CleanupKeepChoiceTests: XCTestCase {
    private let ollamaFormula = "/opt/homebrew/bin/ollama"
    private let ollamaLink = "/usr/local/bin/ollama"
    private let ollamaApp = "/Applications/Ollama.app"

    private func candidate(
        tool: String, path: String, realpath: String? = nil, source: CleanupSource, version: String? = nil,
        role: CleanupCopyRole, status: CleanupStatus? = nil, removal: CleanupAction = .none, size: Int64? = nil,
        dependents: [String] = [], processes: [CleanupProcess] = []
    ) -> CleanupFinding {
        CleanupFinding(
            detector: .pathDuplicates, tool: tool, path: URL(filePath: path), realpath: realpath.map { URL(filePath: $0) },
            source: source, version: version, size: 1, status: status ?? (role == .active ? .active : .shadowed),
            reason: .protectedLocation, action: .none, risk: .medium, bucket: .excluded,
            identity: nil,
            candidate: CleanupCandidate(
                pathRole: role, removal: removal, removalSize: size, dependents: dependents, processes: processes,
                keep: .undecided, takesOver: nil
            )
        )
    }

    private func plain(tool: String, path: String, status: CleanupStatus, source: CleanupSource) -> CleanupFinding {
        CleanupFinding(
            detector: .pathDuplicates, tool: tool, path: URL(filePath: path), realpath: nil, source: source,
            version: nil, size: nil, status: status, reason: .systemCopy, action: .none, risk: .low, bucket: .excluded,
            identity: nil
        )
    }

    private func ollamaGroup() -> [CleanupFinding] {
        [
            candidate(
                tool: "ollama", path: ollamaFormula, realpath: "/opt/homebrew/Cellar/ollama/0.40.16/bin/ollama",
                source: .homebrewFormula(name: "ollama"), version: "0.40.16", role: .active,
                removal: .brew(.uninstallFormula("ollama")), size: 70_000_000
            ),
            candidate(
                tool: "ollama", path: ollamaLink, realpath: "\(ollamaApp)/Contents/Resources/ollama",
                source: .appBundle(name: "Ollama"), version: "0.40.14", role: .shadowed,
                removal: .uninstallApp(name: "Ollama", bundle: URL(filePath: ollamaApp))
            ),
        ]
    }

    private func resolve(
        _ findings: [CleanupFinding], _ choices: [String: CleanupKeptCopy] = [:], approximate: Bool = false
    ) -> [CleanupFinding] {
        CleanupKeepChoice.resolve(findings, choices: choices, pathIsApproximate: approximate)
    }

    private func report(_ findings: [CleanupFinding], approximate: Bool) -> CleanupReport {
        CleanupReport(
            createdAt: Date(timeIntervalSince1970: 0),
            path: CleanupPathSnapshot(entries: [], ignoredEntries: [], shell: nil, capturedAt: nil, isApproximate: approximate),
            findings: findings, notes: [], skippedProtected: []
        )
    }

    private let chooseLink = ["ollama": CleanupKeptCopy(path: "/usr/local/bin/ollama", source: .appBundle(name: "Ollama"))]

    func testDefaultKeepsThePathActiveCopy() {
        let result = resolve(ollamaGroup())
        XCTAssertEqual(result[0].candidate?.keep, .kept)
        XCTAssertEqual(result[0].reason, .currentVersion)
        XCTAssertEqual(result[0].bucket, .excluded)
        XCTAssertEqual(result[1].candidate?.keep, .notKept(keptPath: ollamaFormula))
        XCTAssertEqual(result[1].reason, .shadowedBy(path: ollamaFormula))
        XCTAssertEqual(result[1].action, .uninstallApp(name: "Ollama", bundle: URL(filePath: ollamaApp)))
        XCTAssertEqual(result[1].bucket, .needsDecision)
        XCTAssertNil(result[1].size)
    }

    func testChoosingTheShadowedCopyMovesTheRemovalToTheActiveCopy() {
        let result = resolve(ollamaGroup(), chooseLink)
        XCTAssertEqual(result[0].action, .brew(.uninstallFormula("ollama")))
        XCTAssertEqual(result[0].reason, .keptInstead(path: ollamaLink))
        XCTAssertEqual(result[0].bucket, .needsDecision)
        XCTAssertEqual(result[0].size, 70_000_000)
        XCTAssertEqual(result[0].candidate?.takesOver, ollamaLink)
        XCTAssertEqual(result[0].status, .active)
        XCTAssertEqual(result[1].candidate?.keep, .kept)
        XCTAssertEqual(result[1].reason, .keptByChoice)
    }

    func testStatusesAndIDsDoNotDependOnTheChoice() {
        let first = resolve(ollamaGroup())
        let second = resolve(ollamaGroup(), chooseLink)
        XCTAssertEqual(first.map(\.id), second.map(\.id))
        XCTAssertEqual(first.map(\.status), second.map(\.status))
    }

    func testApproximatePathWithoutChoiceIsUndecided() {
        let result = resolve(resolve(ollamaGroup(), chooseLink), approximate: true)
        for finding in result {
            XCTAssertEqual(finding.candidate?.keep, .undecided)
            XCTAssertEqual(finding.reason, .noCopyKept)
            XCTAssertEqual(finding.action, .none)
            XCTAssertEqual(finding.bucket, .excluded)
        }
        XCTAssertEqual(
            CleanupKeepChoice.apply([:], to: report(ollamaGroup(), approximate: true)).totals,
            CleanupTotals(safe: 0, needsDecision: 0)
        )
    }

    func testApproximatePathWithRememberedChoiceOffersRemovalWithoutTakeover() {
        let result = resolve(ollamaGroup(), chooseLink, approximate: true)
        XCTAssertEqual(result[0].candidate?.keep, .notKept(keptPath: ollamaLink))
        XCTAssertEqual(result[0].reason, .keptInstead(path: ollamaLink))
        XCTAssertEqual(result[0].bucket, .needsDecision)
        XCTAssertEqual(result[0].action, .brew(.uninstallFormula("ollama")))
        XCTAssertNil(result[0].candidate?.takesOver)
        XCTAssertEqual(result[1].candidate?.keep, .kept)
    }

    func testChoiceWithTheRightPathButAnotherSourceFallsBackToTheDefault() {
        let otherSource = ["ollama": CleanupKeptCopy(path: ollamaLink, source: .homebrewFormula(name: "ollama"))]
        let result = resolve(ollamaGroup(), otherSource)
        XCTAssertEqual(result[0].candidate?.keep, .kept)
        XCTAssertEqual(result[1].candidate?.keep, .notKept(keptPath: ollamaFormula))
        XCTAssertEqual(resolve(ollamaGroup(), otherSource, approximate: true).map(\.candidate?.keep), [.undecided, .undecided])
    }

    func testResolvingAResolvedGroupAgainDependsOnlyOnTheLastChoice() {
        let process = CleanupProcess(pid: 1, name: "ollama", executablePath: ollamaFormula, arguments: [])
        var findings = ollamaGroup()
        findings[0] = candidate(
            tool: "ollama", path: ollamaFormula, source: .homebrewFormula(name: "ollama"), version: "0.40.16",
            role: .active, removal: .brew(.uninstallFormula("ollama")), size: 70_000_000, processes: [process]
        )
        XCTAssertEqual(resolve(resolve(findings, chooseLink), [:]), resolve(findings, [:]))
        XCTAssertEqual(resolve(resolve(findings, [:]), chooseLink), resolve(findings, chooseLink))
        XCTAssertEqual(
            resolve(resolve(findings, chooseLink), [:], approximate: true), resolve(findings, [:], approximate: true)
        )
        XCTAssertEqual(resolve(findings)[0].risk, .high)
        XCTAssertEqual(resolve(findings)[1].risk, .low)
        XCTAssertEqual(resolve(findings, approximate: true)[0].risk, .high)
    }

    func testSameHomebrewPackageIsNeverRemovedForTheKeptCopy() {
        let source = CleanupSource.homebrewFormula(name: "python@3.15")
        let removal = CleanupAction.brew(.uninstallFormula("python@3.15"))
        let findings = [
            candidate(tool: "python3", path: "/opt/homebrew/bin/python3", source: source, role: .active, removal: removal),
            candidate(tool: "python3", path: "/usr/local/bin/python3", source: source, role: .shadowed, removal: removal),
        ]
        XCTAssertEqual(resolve(findings)[1].action, .none)
    }

    func testFormulaWithDependentsIsBlockedEvenWhenPathActive() {
        let findings = [
            candidate(
                tool: "mlx", path: "/opt/homebrew/bin/mlx", source: .homebrewFormula(name: "mlx"), role: .active,
                removal: .brew(.uninstallFormula("mlx")), dependents: ["mlx"]
            ),
            candidate(tool: "mlx", path: "/usr/local/bin/mlx", source: .standalone, role: .shadowed, removal: .trash([URL(filePath: "/usr/local/bin/mlx")])),
        ]
        let result = resolve(findings, ["mlx": CleanupKeptCopy(path: "/usr/local/bin/mlx", source: .standalone)])
        XCTAssertEqual(result[0].reason, .requiredBy(["mlx"]))
        XCTAssertEqual(result[0].action, .none)
        XCTAssertEqual(result[0].bucket, .excluded)
        XCTAssertEqual(result[0].status, .active)
    }

    func testDependentsDoNotChangeTheReasonOfAKeptOrUndecidedActiveCopy() {
        let findings = [
            candidate(
                tool: "mlx", path: "/opt/homebrew/bin/mlx", source: .homebrewFormula(name: "mlx"), role: .active,
                status: .active, removal: .brew(.uninstallFormula("mlx")), dependents: ["mlx"]
            ),
            candidate(
                tool: "mlx", path: "/usr/local/bin/mlx", source: .homebrewFormula(name: "mlx-lm"), role: .shadowed,
                status: .dependency(["mlx-vlm"]), removal: .brew(.uninstallFormula("mlx-lm")), dependents: ["mlx-vlm"]
            ),
        ]
        XCTAssertEqual(resolve(findings)[0].reason, .currentVersion)
        XCTAssertEqual(resolve(findings, approximate: true)[0].reason, .noCopyKept)
        let keepShadowed = ["mlx": CleanupKeptCopy(path: "/usr/local/bin/mlx", source: .homebrewFormula(name: "mlx-lm"))]
        XCTAssertEqual(resolve(findings, keepShadowed)[1].reason, .requiredBy(["mlx-vlm"]))
        XCTAssertEqual(resolve(findings, approximate: true)[1].reason, .requiredBy(["mlx-vlm"]))
    }

    func testInUseActiveCopyIsHighRiskNeedsDecision() {
        let process = CleanupProcess(pid: 1, name: "ollama", executablePath: ollamaFormula, arguments: [])
        var findings = ollamaGroup()
        findings[0] = candidate(
            tool: "ollama", path: ollamaFormula, source: .homebrewFormula(name: "ollama"), version: "0.40.16",
            role: .active, removal: .brew(.uninstallFormula("ollama")), processes: [process]
        )
        let result = resolve(findings, chooseLink)
        XCTAssertEqual(result[0].risk, .high)
        XCTAssertEqual(result[0].bucket, .needsDecision)
        XCTAssertEqual(result[0].status, .active)
    }

    func testProcessesDecideTheBucketOfAnOlderNotKeptFormula() {
        let process = CleanupProcess(pid: 2, name: "tool", executablePath: "/opt/homebrew/bin/tool", arguments: [])
        func group(processes: [CleanupProcess]) -> [CleanupFinding] {
            [
                candidate(
                    tool: "tool", path: "/Users/me/.local/bin/tool", source: .standalone, version: "2.0.0", role: .active,
                    removal: .trash([URL(filePath: "/Users/me/.local/bin/tool")])
                ),
                candidate(
                    tool: "tool", path: "/opt/homebrew/bin/tool", source: .homebrewFormula(name: "tool"), version: "1.9.0",
                    role: .shadowed, status: .shadowed, removal: .brew(.uninstallFormula("tool")), processes: processes
                ),
            ]
        }
        XCTAssertEqual(resolve(group(processes: [process]))[1].bucket, .needsDecision)
        XCTAssertEqual(resolve(group(processes: []))[1].bucket, .safe)
    }

    func testAppKeptInAnotherGroupGetsTheLinkInstructionInstead() {
        let docker = URL(filePath: "/Applications/Docker.app")
        let findings = [
            candidate(
                tool: "kubectl", path: "/opt/homebrew/bin/kubectl", source: .homebrewFormula(name: "kubernetes-cli"),
                version: "1.30.0", role: .active, removal: .brew(.uninstallFormula("kubernetes-cli"))
            ),
            candidate(
                tool: "kubectl", path: "/usr/local/bin/kubectl", realpath: "/Applications/Docker.app/Contents/Resources/bin/kubectl",
                source: .appBundle(name: "Docker"), version: "1.29.0", role: .shadowed,
                removal: .uninstallApp(name: "Docker", bundle: docker)
            ),
            candidate(
                tool: "docker", path: "/usr/local/bin/docker", realpath: "/Applications/Docker.app/Contents/Resources/bin/docker",
                source: .appBundle(name: "Docker"), version: "27.0.0", role: .active,
                removal: .uninstallApp(name: "Docker", bundle: docker)
            ),
        ]
        let result = resolve(findings)
        XCTAssertEqual(result[1].action, .instruction(.removeAppLinkWithAdminRights(link: "/usr/local/bin/kubectl")))
    }

    func testNotKeptCopyFromTheKeptCopysOwnAppGetsTheLinkInstruction() {
        let app = "/Applications/Postgres.app"
        let bundle = URL(filePath: app, directoryHint: .isDirectory)
        let latest = "\(app)/Contents/Versions/latest/bin/psql"
        let old = "\(app)/Contents/Versions/14/bin/psql"
        let findings = [
            candidate(
                tool: "psql", path: latest, realpath: "\(app)/Contents/Versions/17/bin/psql", source: .appBundle(name: "Postgres"),
                version: "17.0", role: .active, removal: .uninstallApp(name: "Postgres", bundle: bundle)
            ),
            candidate(
                tool: "psql", path: old, realpath: old, source: .appBundle(name: "Postgres"), version: "14.0",
                role: .shadowed, removal: .uninstallApp(name: "Postgres", bundle: bundle)
            ),
        ]
        XCTAssertEqual(resolve(findings)[1].action, .instruction(.removeAppLinkWithAdminRights(link: old)))
    }

    func testLoneAppCopyStillProtectsItsAppUnderApproximatePath() {
        let docker = URL(filePath: "/Applications/Docker.app", directoryHint: .isDirectory)
        let lone = CleanupFinding(
            detector: .pathDuplicates, tool: "docker", path: URL(filePath: "/usr/local/bin/docker"),
            realpath: URL(filePath: "/Applications/Docker.app/Contents/Resources/bin/docker"), source: .appBundle(name: "Docker"),
            version: "27.0.0", size: nil, status: .active, reason: .currentVersion, action: .none, risk: .low,
            bucket: .excluded, identity: nil
        )
        let findings = [
            lone,
            plain(tool: "docker", path: "/usr/bin/docker", status: .expected, source: .system),
            candidate(
                tool: "kubectl", path: "/opt/homebrew/bin/kubectl", source: .homebrewFormula(name: "kubernetes-cli"),
                version: "1.30.0", role: .active, removal: .brew(.uninstallFormula("kubernetes-cli"))
            ),
            candidate(
                tool: "kubectl", path: "/usr/local/bin/kubectl", realpath: "/Applications/Docker.app/Contents/Resources/bin/kubectl",
                source: .appBundle(name: "Docker"), version: "1.29.0", role: .shadowed,
                removal: .uninstallApp(name: "Docker", bundle: docker)
            ),
        ]
        let choice = ["kubectl": CleanupKeptCopy(path: "/opt/homebrew/bin/kubectl", source: .homebrewFormula(name: "kubernetes-cli"))]
        let result = resolve(findings, choice, approximate: true)
        XCTAssertEqual(result[3].action, .instruction(.removeAppLinkWithAdminRights(link: "/usr/local/bin/kubectl")))
        XCTAssertEqual(result[0], lone)
    }

    func testTakeoverNamesTheFirstRemainingCopyInPathOrder() {
        let findings = [
            candidate(
                tool: "jq", path: "/Users/me/.local/bin/jq", source: .standalone, role: .active,
                removal: .trash([URL(filePath: "/Users/me/.local/bin/jq")])
            ),
            plain(tool: "jq", path: "/usr/bin/jq", status: .expected, source: .system),
            candidate(
                tool: "jq", path: "/opt/homebrew/bin/jq", source: .homebrewFormula(name: "jq"), role: .shadowed,
                removal: .brew(.uninstallFormula("jq"))
            ),
        ]
        let choice = ["jq": CleanupKeptCopy(path: "/opt/homebrew/bin/jq", source: .homebrewFormula(name: "jq"))]
        let result = resolve(findings, choice)
        XCTAssertEqual(result[0].candidate?.takesOver, "/usr/bin/jq")
        XCTAssertEqual(result[1].status, .expected)
        XCTAssertEqual(result[1].reason, .systemCopy)
    }

    func testOlderNotKeptHomebrewCopyIsSafe() {
        let findings = [
            candidate(
                tool: "tool", path: "/Users/me/.local/bin/tool", source: .standalone, version: "2.0.0", role: .active,
                removal: .trash([URL(filePath: "/Users/me/.local/bin/tool")])
            ),
            candidate(
                tool: "tool", path: "/opt/homebrew/bin/tool", source: .homebrewFormula(name: "tool"), version: "1.9.0",
                role: .shadowed, removal: .brew(.uninstallFormula("tool")), size: 5
            ),
        ]
        let result = resolve(findings)
        XCTAssertEqual(result[1].bucket, .safe)
        XCTAssertEqual(result[1].size, 5)
    }

    func testValidChoicesDropsPathsAndSourcesThatNoLongerMatch() {
        let scanned = [
            candidate(
                tool: "Tool", path: "/Users/me/.local/bin/tool", source: .versionManager(.uv), role: .active,
                removal: .instruction(.removeWithCreatingTool)
            ),
        ]
        let choices = [
            "tool": CleanupKeptCopy(path: "/Users/me/.local/bin/tool", source: .packageManager(.pipx)),
            "gone": CleanupKeptCopy(path: "/Users/me/.local/bin/gone", source: .standalone),
        ]
        let rep = report(scanned, approximate: false)
        XCTAssertTrue(CleanupKeepChoice.validChoices(choices, in: rep).isEmpty)
        let exact = ["tool": CleanupKeptCopy(path: "/Users/me/.local/bin/tool", source: .versionManager(.uv))]
        XCTAssertEqual(CleanupKeepChoice.validChoices(exact, in: rep), exact)
    }

    /// Entries the real D10 detector writes for both copies of a tool: the shadowed copy's entry
    /// carries its scan-time advice, the active copy's none. The advice then follows the choice.
    func testFilesAndFoldersAdviceFollowsTheKeptCopy() throws {
        let tmp = try CleanupTempHome()
        let shadowedFile = try tmp.file("opt/bin/tool", size: 4, executable: true)
        let activeFile = try tmp.file("home/.local/bin/tool", size: 4, executable: true)
        let active = candidate(
            tool: "tool", path: activeFile.path, source: .standalone, role: .active, removal: .trash([activeFile])
        )
        let shadowed = candidate(
            tool: "tool", path: shadowedFile.path, source: .homebrewFormula(name: "tool"), role: .shadowed,
            removal: .brew(.uninstallFormula("tool"))
        )
        let rows = [activeFile, shadowedFile].map {
            CleanupTCCRow(service: CleanupTCCService.documents.rawValue, client: $0.path, clientType: 1, authValue: 2)
        }
        let detector = CleanupTCCMapDetector(
            database: FakeTCCDatabase(fileURL: tmp.url("TCC.db"), rows: rows),
            fileSystem: LiveCleanupFileSystem(trash: { _ in })
        )
        let entries = try detector.scan(linkingTo: [active, shadowed]).findings
        XCTAssertEqual(entries.map(\.action), [.none, .instruction(.switchOffInFilesAndFolders)])
        let scanned = [active, shadowed] + entries
        let keepShadowed = ["tool": CleanupKeptCopy(path: shadowedFile.path, source: .homebrewFormula(name: "tool"))]
        let keepActive = ["tool": CleanupKeptCopy(path: activeFile.path, source: .standalone)]
        let switchOff = CleanupAction.instruction(.switchOffInFilesAndFolders)

        XCTAssertEqual(resolve(scanned, keepShadowed)[2...].map(\.action), [switchOff, .none])
        XCTAssertEqual(resolve(scanned, keepActive)[2...].map(\.action), [.none, switchOff])
        XCTAssertEqual(resolve(scanned)[2...].map(\.action), [.none, switchOff])
        XCTAssertEqual(resolve(scanned, approximate: true)[2...].map(\.action), [.none, switchOff], "undecided: the scan's advice")
        XCTAssertEqual(resolve(resolve(scanned, keepShadowed), keepActive), resolve(scanned, keepActive))
        XCTAssertEqual(resolve(resolve(scanned, keepShadowed), approximate: true), resolve(scanned, approximate: true))
        for resolved in [resolve(scanned, keepShadowed), resolve(scanned, approximate: true)] {
            XCTAssertEqual(resolved[2...].map(\.reason), entries.map(\.reason), "the link never moves")
            XCTAssertEqual(resolved[2...].map(\.id), entries.map(\.id))
            XCTAssertEqual(resolved[2...].map(\.status), entries.map(\.status))
            XCTAssertEqual(resolved[2...].map(\.bucket), [.excluded, .excluded])
        }
    }

    func testEnclosingAppBundle() {
        XCTAssertEqual(
            CleanupKeepChoice.enclosingAppBundle(of: URL(filePath: "\(ollamaApp)/Contents/Resources/ollama"))?.path, ollamaApp
        )
        XCTAssertNil(CleanupKeepChoice.enclosingAppBundle(of: URL(filePath: "/opt/homebrew/bin/x")))
        XCTAssertNil(CleanupKeepChoice.enclosingAppBundle(of: URL(filePath: "/Volumes/X.app/bin/tool")))
        XCTAssertEqual(
            CleanupKeepChoice.enclosingAppBundle(of: URL(filePath: "/Volumes/X.app/Apps/Y.app/Contents/MacOS/y"))?.path,
            "/Volumes/X.app/Apps/Y.app"
        )
    }
}
