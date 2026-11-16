import XCTest
@testable import MacUpdaterCore

/// Answers both dry runs with fixed results, or throws the error given for one of them.
private struct FakeBrewDryRuns: CleanupBrewQuerying {
    var cleanup: [CleanupBrewCleanupItem] = []
    var autoremove: [String] = []
    var cleanupError: Error?
    var autoremoveError: Error?

    func usesInstalled(formula: String) async throws -> [String] { [] }

    func cleanupDryRun(package: String?) async throws -> [CleanupBrewCleanupItem] {
        if let cleanupError { throw cleanupError }
        return cleanup
    }

    func autoremoveDryRun() async throws -> [String] {
        if let autoremoveError { throw autoremoveError }
        return autoremove
    }
}

private struct DryRunFailure: Error {}

private struct ExpectedPackage: Equatable {
    let kind: CleanupHomebrewPackage.Kind
    let name: String

    init(_ kind: CleanupHomebrewPackage.Kind, _ name: String) {
        self.kind = kind
        self.name = name
    }
}

final class CleanupHomebrewDetectorTests: XCTestCase {
    private static let now = Date(timeIntervalSince1970: 1_794_297_600)
    private static let day: TimeInterval = 24 * 60 * 60
    private static let downloadHash = String(repeating: "5b2c", count: 16)

    private var tmp: CleanupTempHome!
    private var prefix: URL!
    private var fileSystem: CleanupFileSystem!
    private var processes: [CleanupProcess] = []

    override func setUpWithError() throws {
        tmp = try CleanupTempHome()
        prefix = tmp.url("opt/homebrew")
        fileSystem = GuardedCleanupFileSystem(
            base: LiveCleanupFileSystem(trash: { _ in }),
            guard: ProtectedLocationGuard(home: tmp.home, mounts: FixedMountTable(["/"]))
        )
        processes = []
    }

    private func detector(_ brew: FakeBrewDryRuns, brewPrefix: URL?) -> CleanupHomebrewDetector {
        CleanupHomebrewDetector(
            brew: brew, fileSystem: fileSystem,
            inspector: FakeProcessInspector(processes: processes, bootTime: Date(timeIntervalSince1970: 0)),
            brewPrefix: brewPrefix, now: Self.now
        )
    }

    private func scan(_ brew: FakeBrewDryRuns) async -> (findings: [CleanupFinding], notes: [CleanupDetectorNote]) {
        await detector(brew, brewPrefix: prefix).scan()
    }

    /// A version directory under the prefix holding one file, last modified `age` before `now`.
    /// The date is set after the contents, because writing inside a directory moves its date.
    @discardableResult
    private func version(_ relative: String, age: TimeInterval = 30 * day, file: String = "bin/tool") throws -> URL {
        try tmp.file("opt/homebrew/\(relative)/\(file)", size: 4096, executable: true)
        let url = prefix.appending(path: relative, directoryHint: .isDirectory)
        try setModified(url, Self.now.addingTimeInterval(-age))
        return url
    }

    private func setModified(_ url: URL, _ date: Date) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    private func underPrefix(_ relative: String) -> URL {
        prefix.appending(path: relative, directoryHint: .notDirectory)
    }

    private func item(_ url: URL, _ size: Int64?) -> CleanupBrewCleanupItem {
        CleanupBrewCleanupItem(path: url, size: size)
    }

    private static func hasBrewAction(_ finding: CleanupFinding) -> Bool {
        if case .brew = finding.action { return true }
        return false
    }

    func testCleanHomebrewYieldsNoFindings() async throws {
        try version("Cellar/node/23.0.0")
        try version("Caskroom/firefox/120.0")
        try tmp.directory("opt/homebrew/Caskroom/firefox/.metadata/120.0")

        let result = await scan(FakeBrewDryRuns())

        XCTAssertEqual(result.findings, [])
        XCTAssertEqual(result.notes, [])
    }

    func testCleanupItemsAreGroupedPerPackageWithItsOwnCommand() async throws {
        let oldKeg = try version("Cellar/node/22.1.0")
        try version("Cellar/node/23.0.0")
        let download = tmp.url(
            "Library/Caches/Homebrew/downloads/\(Self.downloadHash)--node--22.1.0.arm64_sequoia.bottle.tar.gz"
        )
        let log = tmp.url("Library/Logs/Homebrew/node")
        let brew = FakeBrewDryRuns(cleanup: [
            item(oldKeg, 60_000_000), item(download, 20_000_000), item(log, 4096),
        ])

        let result = await scan(brew)

        XCTAssertEqual(result.findings.count, 2, "the log is removed only by a global `brew cleanup`: \(result.findings)")
        let finding = try XCTUnwrap(result.findings.first)
        XCTAssertEqual(finding.detector, .homebrew)
        XCTAssertEqual(finding.action, .brew(.cleanup("node")))
        XCTAssertEqual(finding.size, 80_000_000)
        XCTAssertEqual(finding.status, .unused)
        XCTAssertEqual(finding.reason, .homebrewLeftovers(items: 2))
        XCTAssertEqual(finding.risk, .low)
        XCTAssertEqual(finding.bucket, .needsDecision)
        let packageDirectory = underPrefix("Cellar/node")
        XCTAssertEqual(finding.path.path, packageDirectory.path)
        XCTAssertEqual(finding.identity, try fileSystem.entry(at: packageDirectory)?.identity)
        let logFinding = try XCTUnwrap(result.findings.last)
        XCTAssertEqual(logFinding.path, log)
        XCTAssertEqual(logFinding.status, .info)
        XCTAssertEqual(logFinding.action, .none)
        for finding in result.findings {
            if case .brew(.cleanup(let name)) = finding.action {
                XCTAssertTrue(CleanupHomebrewNames.isValid(name), "a cleanup without a package is global: \(name)")
            }
            if case .command(let text) = finding.action {
                XCTAssertFalse(text.contains("brew"), "Homebrew runs only as a per-package action: \(text)")
            }
        }
    }

    /// `brew cleanup -- <name>` runs only the formula's and cask's own clean-up; old logs and
    /// `<version>.reinstall` kegs go only with a global `brew cleanup`, which Wega never runs.
    /// Offering the package's command for them would leave a row no removal can clear.
    func testLogsAndReinstallKegsOnlyAGlobalCleanupRemovesAreInformationOnly() async throws {
        try version("Cellar/node/23.0.0")
        let reinstallKeg = try version("Cellar/node/23.0.0.reinstall")
        let log = tmp.url("Library/Logs/Homebrew/node")

        let onlyLog = await scan(FakeBrewDryRuns(cleanup: [item(log, 4096)]))
        let onlyReinstall = await scan(FakeBrewDryRuns(cleanup: [item(reinstallKeg, 8192)]))

        for (result, path) in [(onlyLog, log), (onlyReinstall, reinstallKeg)] {
            XCTAssertFalse(
                result.findings.contains { $0.action == .brew(.cleanup("node")) },
                "\(path.lastPathComponent) is not the package's leftover: \(result.findings.map(\.action))"
            )
            let leftover = try XCTUnwrap(result.findings.first { $0.path.path == path.path }, path.path)
            XCTAssertEqual(leftover.status, .info)
            XCTAssertEqual(leftover.action, .none)
            XCTAssertEqual(leftover.reason, .homebrewLeftovers(items: 1))
        }
    }

    func testRecentlyUpgradedPackageIsExcludedUntilSevenDaysPass() async throws {
        let oldKeg = try version("Cellar/node/22.1.0", age: 40 * Self.day)
        try version("Cellar/node/23.0.0", age: 2 * Self.day)
        let modified = Self.now.addingTimeInterval(-2 * Self.day)

        let result = await scan(FakeBrewDryRuns(cleanup: [item(oldKeg, 60_000_000)]))

        let finding = try XCTUnwrap(result.findings.first)
        XCTAssertEqual(result.findings.count, 1)
        XCTAssertEqual(finding.status, .recentUpgrade(until: modified.addingTimeInterval(7 * Self.day)))
        XCTAssertEqual(finding.reason, .recentlyUpgraded)
        XCTAssertEqual(finding.bucket, .excluded)
    }

    func testAutoremoveCandidatesAreNeedsDecisionUninstalls() async throws {
        try version("Cellar/libfoo/1.0")

        let result = await scan(FakeBrewDryRuns(autoremove: ["libfoo"]))

        XCTAssertEqual(result.findings.count, 1)
        let finding = try XCTUnwrap(result.findings.first)
        XCTAssertEqual(finding.action, .brew(.uninstallFormula("libfoo")))
        XCTAssertEqual(finding.bucket, .needsDecision)
        XCTAssertEqual(finding.reason, .installedOnlyAsDependency)
        XCTAssertEqual(finding.risk, .medium)
        XCTAssertEqual(finding.status, .unused)
        XCTAssertEqual(finding.path.path, underPrefix("Cellar/libfoo").path)
        XCTAssertEqual(finding.size, try fileSystem.allocatedSize(of: underPrefix("Cellar/libfoo")))
    }

    func testAutoremoveCandidateSupersedesItsCleanupGroup() async throws {
        let oldKeg = try version("Cellar/libfoo/1.0")
        try version("Cellar/libfoo/2.0")
        try version("Cellar/libbar/1.0")
        try version("Cellar/libbar/2.0")
        let download = tmp.url("Library/Caches/Homebrew/downloads/\(Self.downloadHash)--libfoo--1.0.bottle.tar.gz")
        let brew = FakeBrewDryRuns(
            cleanup: [item(oldKeg, 4096), item(download, 1024)], autoremove: ["someone/tap/libfoo", "libbar"]
        )

        let result = await scan(brew)

        XCTAssertEqual(
            result.findings.map(\.action),
            [.brew(.uninstallFormula("someone/tap/libfoo")), .brew(.uninstallFormula("libbar"))],
            "the uninstall replaces the cleanup group and the kept-version note: \(result.findings.map(\.reason))"
        )
        let libfoo = underPrefix("Cellar/libfoo")
        let forLibfoo = result.findings.filter { $0.path.path == libfoo.path }
        XCTAssertEqual(forLibfoo.count, 1)
        XCTAssertEqual(forLibfoo.first?.size, try fileSystem.allocatedSize(of: libfoo))
    }

    func testFindingIdsAreUnique() async throws {
        let nodeKeg = try version("Cellar/node/22.1.0")
        try version("Cellar/node/23.0.0")
        let dockerKeg = try version("Cellar/docker/1.0")
        try version("Cellar/docker/2.0")
        let dockerCask = try version("Caskroom/docker/4.0")
        try version("Caskroom/docker/4.1")
        let libfooKeg = try version("Cellar/libfoo/1.0")
        try version("Cellar/libfoo/2.0")
        try version("Cellar/pinned/1.0")
        try version("Cellar/pinned/2.0")
        let brew = FakeBrewDryRuns(
            cleanup: [
                item(nodeKeg, 100), item(tmp.url("Library/Logs/Homebrew/node"), 10),
                item(dockerKeg, 200), item(dockerCask, 300), item(libfooKeg, 400),
                item(tmp.url("Library/Caches/Homebrew/api/formula.jws.json"), 50),
            ],
            autoremove: ["libfoo", "someone/tap/libfoo", "../libfoo"]
        )

        let result = await scan(brew)

        let ids = result.findings.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "duplicate finding ids: \(ids.sorted())")
        XCTAssertTrue(result.findings.contains { $0.path.path == underPrefix("Caskroom/docker").path })
        XCTAssertTrue(result.findings.contains { $0.reason == .homebrewKeptVersions(count: 2) })
    }

    func testAutoremoveCandidateInUseIsMarked() async throws {
        try version("Cellar/libfoo/1.0", file: "bin/foo")
        let running = CleanupProcess(
            pid: 77, name: "foo", executablePath: underPrefix("Cellar/libfoo/1.0/bin/foo").path, arguments: ["foo"]
        )
        processes = [running]

        let result = await scan(FakeBrewDryRuns(autoremove: ["libfoo"]))

        let finding = try XCTUnwrap(result.findings.first)
        XCTAssertEqual(finding.status, .inUse([running]))
        XCTAssertEqual(finding.bucket, .needsDecision)
    }

    func testUnsafeNamesNeverReachAnAction() async throws {
        try version("Cellar/-rf/0.9")
        let unsafeKeg = try version("Cellar/-rf/1.0")
        let brew = FakeBrewDryRuns(cleanup: [item(unsafeKeg, 1024)], autoremove: ["-rf", "../../etc"])

        let result = await scan(brew)

        XCTAssertTrue(
            result.findings.contains { $0.path.path == unsafeKeg.path && $0.action == .none },
            "the unsafe keg is still reported, without an action: \(result.findings)"
        )
        XCTAssertEqual(result.findings.count, 3, "the cleanup group names `-rf`, so its two kegs are not kept versions too")
        XCTAssertFalse(result.findings.contains(where: Self.hasBrewAction), "\(result.findings.map(\.action))")
    }

    func testCacheEntriesWithoutAPackageAreInformationOnly() async throws {
        let api = tmp.url("Library/Caches/Homebrew/api/formula.jws.json")

        let result = await scan(FakeBrewDryRuns(cleanup: [item(api, 2_000_000)]))

        XCTAssertEqual(result.findings.count, 1)
        let finding = try XCTUnwrap(result.findings.first)
        XCTAssertEqual(finding.path, api)
        XCTAssertEqual(finding.status, .info)
        XCTAssertEqual(finding.action, .none)
        XCTAssertEqual(finding.bucket, .excluded)
        XCTAssertEqual(finding.size, 2_000_000)
    }

    func testOldVersionInUseIsMarked() async throws {
        let oldKeg = try version("Cellar/node/22.1.0", file: "bin/node")
        try version("Cellar/node/23.0.0", file: "bin/node")
        let brew = FakeBrewDryRuns(cleanup: [item(oldKeg, 60_000_000)])
        let oldNode = CleanupProcess(
            pid: 42, name: "node", executablePath: underPrefix("Cellar/node/22.1.0/bin/node").path, arguments: ["node"]
        )
        let currentNode = CleanupProcess(
            pid: 43, name: "node", executablePath: underPrefix("Cellar/node/23.0.0/bin/node").path, arguments: ["node"]
        )

        processes = [oldNode]
        let oldScan = await scan(brew)
        processes = [currentNode]
        let currentScan = await scan(brew)

        let usingOld = try XCTUnwrap(oldScan.findings.first)
        let usingCurrent = try XCTUnwrap(currentScan.findings.first)

        XCTAssertEqual(usingOld.status, .inUse([oldNode]))
        XCTAssertEqual(usingOld.bucket, .needsDecision)
        XCTAssertEqual(usingCurrent.status, .unused)
    }

    func testDryRunFailureLeavesANote() async throws {
        try version("Cellar/pinned/1.0")
        try version("Cellar/pinned/2.0")
        let oldKeg = try version("Cellar/node/22.1.0")
        try version("Cellar/node/23.0.0")
        let note = CleanupDetectorNote(detector: .homebrew, kind: .dryRunFailed)

        let bothFail = await scan(FakeBrewDryRuns(cleanupError: DryRunFailure(), autoremoveError: DryRunFailure()))
        let autoremoveFails = await scan(FakeBrewDryRuns(
            cleanup: [item(oldKeg, 60_000_000)], autoremove: ["libfoo"], autoremoveError: DryRunFailure()
        ))

        XCTAssertEqual(bothFail.notes, [note])
        XCTAssertEqual(bothFail.findings, [], "kept versions cannot be told from leftovers without the dry run")
        XCTAssertEqual(autoremoveFails.notes, [note])
        XCTAssertEqual(
            autoremoveFails.findings.map(\.reason), [.homebrewLeftovers(items: 1), .homebrewKeptVersions(count: 2)],
            "the cleanup dry run still answered, so its packages and the kept versions are reported"
        )
    }

    func testAMacWithoutHomebrewNeedsNoExplanation() async throws {
        let oldKeg = try version("Cellar/node/22.1.0")
        try version("Cellar/node/23.0.0")

        let noPrefix = await detector(FakeBrewDryRuns(cleanup: [item(oldKeg, 1)]), brewPrefix: nil).scan()
        let cleanupMissing = await scan(FakeBrewDryRuns(cleanupError: BrewServiceError.brewNotFound))
        let autoremoveMissing = await scan(FakeBrewDryRuns(
            cleanup: [item(oldKeg, 1)], autoremoveError: BrewServiceError.brewNotFound
        ))

        for result in [noPrefix, cleanupMissing, autoremoveMissing] {
            XCTAssertEqual(result.findings, [])
            XCTAssertEqual(result.notes, [])
        }
    }

    func testKeptVersionsAreReported() async throws {
        try version("Cellar/pinned/1.0")
        try version("Cellar/pinned/2.0")

        let result = await scan(FakeBrewDryRuns())

        XCTAssertEqual(result.findings.count, 1)
        let finding = try XCTUnwrap(result.findings.first)
        XCTAssertEqual(finding.status, .info)
        XCTAssertEqual(finding.reason, .homebrewKeptVersions(count: 2))
        XCTAssertEqual(finding.action, .none)
        XCTAssertEqual(finding.bucket, .excluded)
        XCTAssertEqual(finding.path.path, underPrefix("Cellar/pinned").path)
    }

    func testKeptCaskVersionsDoNotCountTheMetadataFolder() async throws {
        try version("Caskroom/updater/1.0")
        try version("Caskroom/updater/2.0")
        try tmp.directory("opt/homebrew/Caskroom/updater/.metadata/2.0")

        let result = await scan(FakeBrewDryRuns())

        XCTAssertEqual(result.findings.map(\.reason), [.homebrewKeptVersions(count: 2)])
        XCTAssertEqual(result.findings.first?.source, .homebrewCask(token: "updater"))
    }

    func testLastInstallIsTheNewestVersionIgnoringMetadata() throws {
        try version("Caskroom/updater/1.0", age: 30 * Self.day)
        try version("Caskroom/updater/2.0", age: 10 * Self.day)
        try tmp.directory("opt/homebrew/Caskroom/updater/.metadata/2.0")

        let last = CleanupHomebrewDetector.lastInstall(in: underPrefix("Caskroom/updater"), fileSystem: fileSystem)

        XCTAssertEqual(last, Self.now.addingTimeInterval(-10 * Self.day))
    }

    func testPackageNamesAreReadFromHomebrewLayouts() {
        let cache = "/Users/someone/Library/Caches/Homebrew"
        let expected: [(path: String, package: ExpectedPackage?)] = [
            ("/opt/homebrew/Cellar/node/22.1.0", ExpectedPackage(.formula, "node")),
            ("/opt/homebrew/Caskroom/firefox/120.0", ExpectedPackage(.cask, "firefox")),
            (
                "\(cache)/downloads/\(Self.downloadHash)--python@3.12--3.12.1.arm64_sequoia.bottle.tar.gz",
                ExpectedPackage(.cache, "python@3.12")
            ),
            ("\(cache)/node--22.1.0.arm64_sequoia.bottle.tar.gz", ExpectedPackage(.cache, "node")),
            ("\(cache)/node_bottle_manifest--22.1.0", ExpectedPackage(.cache, "node")),
            ("\(cache)/Cask/firefox--120.0.dmg", ExpectedPackage(.cache, "firefox")),
            ("/Users/someone/Library/Logs/Homebrew/node", nil),
            ("/opt/homebrew/Cellar/node/23.0.0.reinstall", nil),
            ("\(cache)/downloads/\(Self.downloadHash)--firefox-120.0.dmg", nil),
            ("\(cache)/downloads/not-a-hash--node--22.1.0.bottle.tar.gz", nil),
            ("\(cache)/api/formula.jws.json", nil),
            ("\(cache)/portable-ruby-3.3.0.arm64_big_sur.bottle.tar.gz", nil),
            ("\(cache)/--22.1.0", nil),
            ("/opt/homebrew/Cellar", nil),
        ]

        for (path, package) in expected {
            let read = CleanupHomebrewPackage.name(of: URL(filePath: path, directoryHint: .notDirectory))
            XCTAssertEqual(read.map { ExpectedPackage($0.kind, $0.name) }, package, path)
        }
    }
}
