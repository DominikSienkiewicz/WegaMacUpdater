import XCTest
@testable import MacUpdaterCore

private final class InMemoryReportIO: ScanSnapshotIO {
    var data: Data?

    func read() throws -> Data? { data }

    func write(_ data: Data) throws { self.data = data }
}

final class CleanupReportTests: XCTestCase {
    private let plainHome = URL(filePath: "/Users/wega", directoryHint: .isDirectory)
    /// Its `file://` spelling (`/Users/Wega%20Test`) differs from its path spelling.
    private let spacedHome = URL(filePath: "/Users/Wega Test", directoryHint: .isDirectory)

    /// One finding per kind of path the report carries: URLs in `path`, `realpath` and actions,
    /// path text in reasons, instructions, processes, `PATH` entries and `skippedProtected`.
    private func sampleReport(home: URL, arguments: [String] = []) -> CleanupReport {
        func url(_ relative: String) -> URL { home.appending(path: relative, directoryHint: .notDirectory) }
        let old = url(".local/share/claude/versions/2.1.318")
        let fnm = url(".local/state/fnm_multishells")
        let process = CleanupProcess(pid: 4242, name: "claude", executablePath: old.path, arguments: arguments)
        let findings = [
            CleanupFinding(
                detector: .pathDuplicates, tool: "claude", path: url("opt/homebrew/bin/claude"),
                realpath: url("opt/homebrew/Caskroom/claude-code/2.1.311/claude"), source: .homebrewCask(token: "claude-code"),
                version: "2.1.311", size: 300_000_000, status: .shadowed, reason: .shadowedBy(path: url(".local/bin/claude").path),
                action: .brew(.uninstallCask("claude-code")), risk: .low, bucket: .safe,
                identity: CleanupFileIdentity(device: 1, inode: 11)
            ),
            CleanupFinding(
                detector: .pathDuplicates, tool: "ollama", path: url("usr/local/bin/ollama"),
                realpath: url("Applications/Ollama.app/Contents/Resources/ollama"), source: .appBundle(name: "Ollama"),
                version: nil, size: nil, status: .shadowed, reason: .shadowedBy(path: url("opt/homebrew/bin/ollama").path),
                action: .instruction(.removeAppLinkWithAdminRights(link: url("usr/local/bin/ollama").path)), risk: .low,
                bucket: .needsDecision, identity: CleanupFileIdentity(device: 1, inode: 12)
            ),
            CleanupFinding(
                detector: .versionDirectories, tool: "claude", path: old, realpath: old,
                source: .nativeVersionDirectory(tool: "claude"), version: "2.1.318", size: 208_000_000,
                status: .inUse([process]), reason: .olderVersion(current: "2.1.325"), action: .trash([old]), risk: .high,
                bucket: .needsDecision, identity: CleanupFileIdentity(device: 1, inode: 13)
            ),
            CleanupFinding(
                detector: .shellState, tool: "fnm", path: fnm, realpath: nil, source: nil, version: nil, size: 2_048,
                status: .stale, reason: .staleSinceBoot(count: 2),
                action: .trashBatch(parent: fnm, entries: [
                    fnm.appending(component: "1_1794211200000", directoryHint: .notDirectory),
                    fnm.appending(component: "2_1794297599000_ab12", directoryHint: .notDirectory),
                ]),
                risk: .low, bucket: .safe, identity: CleanupFileIdentity(device: 1, inode: 14)
            ),
        ]
        let path = CleanupPathSnapshot(
            entries: [url(".local/bin").path, "/opt/homebrew/bin", url("Downloads/bin").path], ignoredEntries: ["~/bin"],
            shell: "zsh", capturedAt: Date(timeIntervalSince1970: 1_794_000_000), isApproximate: false
        )
        return CleanupReport(
            createdAt: Date(timeIntervalSince1970: 1_794_300_000), path: path, findings: findings,
            notes: [CleanupDetectorNote(detector: .homebrew, kind: .homebrewUnavailable)],
            skippedProtected: [url("Downloads/bin").path]
        )
    }

    private func statusLabel(_ status: CleanupStatus) -> String {
        switch status {
        case .shadowed: "PRZESŁONIĘTY"
        case .inUse: "W UŻYCIU"
        case .stale: "NIEAKTUALNY"
        default: "INNY"
        }
    }

    private func reasonLabel(_ reason: CleanupReason) -> String {
        switch reason {
        case .shadowedBy(let path): "za \(path)"
        case .olderVersion(let current): "starsza niż \(current)"
        case .staleSinceBoot(let count): "\(count) sprzed startu"
        default: "inny"
        }
    }

    private func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    func testTildeReplacesOnlyWholeComponents() {
        let home = URL(filePath: "/Users/dom", directoryHint: .isDirectory)

        XCTAssertEqual(CleanupReportRenderer.tildePath("/Users/dom/x", home: home), "~/x")
        XCTAssertEqual(CleanupReportRenderer.tildePath("/Users/dominik/x", home: home), "/Users/dominik/x")
        XCTAssertEqual(CleanupReportRenderer.tildePath("/Users/dom", home: home), "~")
        XCTAssertEqual(CleanupReportRenderer.tildePath("/Users/dom/", home: home), "~")
        XCTAssertEqual(CleanupReportRenderer.tildePath("/opt/Users/dom/x", home: home), "/opt/Users/dom/x")
        XCTAssertEqual(CleanupReportRenderer.tildePath("/Users/dom/\u{301}x", home: home), "~/\u{301}x", "a slash before a combining mark still splits")
        XCTAssertEqual(CleanupReportRenderer.tildePath("/Users/dom\u{301}/x", home: home), "/Users/dom\u{301}/x")
        XCTAssertEqual(CleanupReportRenderer.tildePath("Users/dom/x", home: home), "Users/dom/x")
    }

    func testJSONHasSchemaVersionAndNoHomePath() throws {
        for home in [plainHome, spacedHome] {
            let data = try CleanupReportRenderer.json(sampleReport(home: home), home: home)
            let json = String(decoding: data, as: UTF8.self)

            XCTAssertTrue(json.contains("\"schemaVersion\":1"), json)
            XCTAssertFalse(json.contains(home.path), "path spelling of \(home.path)")
            XCTAssertFalse(json.contains(String(home.absoluteString.dropLast())), "file URL spelling of \(home.path)")
            XCTAssertTrue(json.contains("\"file://~/opt/homebrew/bin/claude\""), json)
            XCTAssertTrue(json.contains("\"D1:shadowed:~/opt/homebrew/bin/claude\""), json)
            XCTAssertTrue(json.contains("\"~/Downloads/bin\""), json)
            XCTAssertTrue(json.contains("\"/opt/homebrew/bin\""), "paths outside the home stay as they are")
            XCTAssertNoThrow(try JSONSerialization.jsonObject(with: data))
        }
    }

    func testJSONNeverCarriesProcessArguments() throws {
        let old = plainHome.appending(path: ".local/share/claude/versions/2.1.318", directoryHint: .notDirectory).path
        let report = sampleReport(home: plainHome, arguments: [old, "--token=abc"])

        let json = String(decoding: try CleanupReportRenderer.json(report, home: plainHome), as: UTF8.self)
        let text = CleanupReportRenderer.text(
            report, home: plainHome, reasonText: { String(describing: $0) }, statusText: { String(describing: $0) }
        )

        XCTAssertTrue(json.contains("\"pid\":4242"), json)
        XCTAssertFalse(json.contains("abc"), json)
        XCTAssertTrue(text.contains("claude (PID 4242)"), text)
        XCTAssertFalse(text.contains("abc"), text)
        XCTAssertFalse(text.contains(plainHome.path), "closures only ever see ~ paths: \(text)")
    }

    func testTextHasOneLinePerFinding() {
        let report = sampleReport(home: plainHome)

        let text = CleanupReportRenderer.text(report, home: plainHome, reasonText: reasonLabel, statusText: statusLabel)

        XCTAssertEqual(text, [
            "D1 | PRZESŁONIĘTY | ~/opt/homebrew/bin/claude | \(size(300_000_000)) | brew uninstall --cask -- claude-code | za ~/.local/bin/claude",
            "D1 | PRZESŁONIĘTY | ~/usr/local/bin/ollama | - | instruction remove-app-link-with-admin-rights ~/usr/local/bin/ollama | za ~/opt/homebrew/bin/ollama",
            "D3 | W UŻYCIU | ~/.local/share/claude/versions/2.1.318 | \(size(208_000_000)) | trash ~/.local/share/claude/versions/2.1.318 | starsza niż 2.1.325 | claude (PID 4242)",
            "D8 | NIEAKTUALNY | ~/.local/state/fnm_multishells | \(size(2_048)) | trash-batch ~/.local/state/fnm_multishells (2) | 2 sprzed startu",
        ].map { $0 + "\n" }.joined())
    }

    /// An npm command names the shadowed copy's prefix, which can lie in the home folder; both
    /// exports write it with `~`, and the persisted form restores the exact command.
    func testHomePathsInsideACommandAreWrittenWithTilde() throws {
        let prefix = plainHome.appending(path: ".local/share/fnm/node-versions/v22.11.0/installation", directoryHint: .isDirectory)
        let tool = prefix.appending(path: "bin/tsc", directoryHint: .notDirectory)
        let command = "npm uninstall -g --prefix \(prefix.path) typescript"
        let report = CleanupReport(
            createdAt: Date(timeIntervalSince1970: 1_794_300_000), path: sampleReport(home: plainHome).path,
            findings: [CleanupFinding(
                detector: .pathDuplicates, tool: "tsc", path: tool, realpath: tool, source: .packageManager(.npm),
                version: nil, size: nil, status: .shadowed, reason: .shadowedBy(path: "/opt/homebrew/bin/tsc"),
                action: .command(command), risk: .low, bucket: .needsDecision,
                identity: CleanupFileIdentity(device: 1, inode: 21)
            )],
            notes: [], skippedProtected: []
        )

        let text = CleanupReportRenderer.text(report, home: plainHome, reasonText: reasonLabel, statusText: statusLabel)
        let json = String(decoding: try CleanupReportRenderer.json(report, home: plainHome), as: UTF8.self)

        XCTAssertTrue(text.contains("npm uninstall -g --prefix ~/.local/share/fnm/node-versions/v22.11.0/installation typescript"), text)
        XCTAssertFalse(text.contains(plainHome.path), text)
        XCTAssertFalse(json.contains(plainHome.path), json)
        let restored = try CleanupReportRenderer.report(fromJSON: Data(json.utf8), home: plainHome)
        XCTAssertEqual(restored.findings.first?.action, .command(command))
    }

    func testHomeBeforeASpaceInACommandIsAbbreviatedAndRestored() throws {
        let shortHome = URL(filePath: "/Users/t", directoryHint: .isDirectory)
        let tool = shortHome.appending(path: "bin/tsc", directoryHint: .notDirectory)
        let command = "npm uninstall -g --prefix /Users/t pkg /Users/tom"
        let report = CleanupReport(
            createdAt: Date(timeIntervalSince1970: 1_794_300_000), path: sampleReport(home: shortHome).path,
            findings: [CleanupFinding(
                detector: .pathDuplicates, tool: "tsc", path: tool, realpath: tool, source: .packageManager(.npm),
                version: nil, size: nil, status: .shadowed, reason: .shadowedBy(path: "/opt/homebrew/bin/tsc"),
                action: .command(command), risk: .low, bucket: .needsDecision,
                identity: CleanupFileIdentity(device: 1, inode: 22)
            )],
            notes: [], skippedProtected: []
        )

        let json = String(decoding: try CleanupReportRenderer.json(report, home: shortHome), as: UTF8.self)

        XCTAssertTrue(json.contains("--prefix ~ pkg"), json)
        XCTAssertFalse(json.contains("/Users/t pkg"), json)
        XCTAssertTrue(json.contains("/Users/tom"), "a longer name is not the home: \(json)")
        let restored = try CleanupReportRenderer.report(fromJSON: Data(json.utf8), home: shortHome)
        XCTAssertEqual(restored.findings.first?.action, .command(command))
        let io = InMemoryReportIO()
        let file = CleanupReportFile(home: shortHome, io: io)
        try file.save(report)
        XCTAssertEqual(try XCTUnwrap(file.load()).findings.first?.action, .command(command))
    }

    func testTextSpellsBrewCommandsTheSharedWay() {
        let link = plainHome.appending(path: "opt/homebrew/bin/gh", directoryHint: .notDirectory)
        let formula = CleanupFinding(
            detector: .pathDuplicates, tool: "gh", path: link, realpath: link, source: .homebrewFormula(name: "gh"),
            version: "2.104.0", size: nil, status: .shadowed, reason: .shadowedBy(path: "/usr/local/bin/gh"),
            action: .brew(.uninstallFormula("gh")), risk: .low, bucket: .needsDecision,
            identity: CleanupFileIdentity(device: 1, inode: 31)
        )
        let sample = sampleReport(home: plainHome)
        let report = CleanupReport(
            createdAt: sample.createdAt, path: sample.path, findings: [formula] + sample.findings,
            notes: [], skippedProtected: []
        )

        let lines = CleanupReportRenderer.text(report, home: plainHome, reasonText: reasonLabel, statusText: statusLabel)
            .components(separatedBy: "\n")

        XCTAssertEqual(lines[0].components(separatedBy: " | ")[4], CleanupActionText.command(for: .uninstallFormula("gh")))
        XCTAssertEqual(lines[1].components(separatedBy: " | ")[4], CleanupActionText.command(for: .uninstallCask("claude-code")))
    }

    func testReportFileRoundTrips() throws {
        let io = InMemoryReportIO()
        let file = CleanupReportFile(home: plainHome, io: io)
        let report = sampleReport(home: plainHome)

        XCTAssertNil(file.load())
        try file.save(report)

        XCTAssertEqual(file.load(), report)
        XCTAssertEqual(io.data, try CleanupReportRenderer.json(report, home: plainHome), "the stored file is the ~ export")
    }

    func testReportFileRestoresAbsolutePaths() throws {
        let io = InMemoryReportIO()
        let file = CleanupReportFile(home: spacedHome, io: io)
        let report = sampleReport(home: spacedHome)

        try file.save(report)
        let loaded = try XCTUnwrap(file.load())

        XCTAssertEqual(loaded.findings.map(\.path), report.findings.map(\.path))
        XCTAssertEqual(loaded.findings.map(\.realpath), report.findings.map(\.realpath))
        XCTAssertEqual(loaded.findings.map(\.action), report.findings.map(\.action))
        XCTAssertEqual(loaded.findings.map(\.reason), report.findings.map(\.reason))
        XCTAssertEqual(loaded.findings.map(\.id), report.findings.map(\.id))
        XCTAssertEqual(loaded.skippedProtected, report.skippedProtected)
        XCTAssertEqual(loaded.path, report.path, "a literal ~ entry stays literal")
        XCTAssertTrue(loaded.findings.allSatisfy(\.path.isFileURL))
    }

    func testCorruptOrOtherSchemaFileLoadsAsNil() throws {
        let io = InMemoryReportIO()
        let file = CleanupReportFile(home: plainHome, io: io)
        io.data = Data("not json".utf8)
        XCTAssertNil(file.load())

        let current = String(decoding: try CleanupReportRenderer.json(sampleReport(home: plainHome), home: plainHome), as: UTF8.self)
        XCTAssertTrue(current.contains("\"schemaVersion\":1"))
        io.data = Data(current.replacingOccurrences(of: "\"schemaVersion\":1", with: "\"schemaVersion\":2").utf8)
        XCTAssertNil(file.load())
    }

    func testDefaultFileLivesInApplicationSupport() {
        XCTAssertTrue(CleanupReportFile.defaultFileURL.path.hasSuffix("/Library/Application Support/WegaMacUpdater/cleanup-report.json"))
    }

    private func leftoverReport(status: CleanupStatus, action: CleanupAction, home: URL) -> CleanupReport {
        let directory = home.appending(path: ".nvm/versions/node/v20.1.0", directoryHint: .isDirectory)
        return CleanupReport(
            createdAt: Date(timeIntervalSince1970: 1_794_300_000), path: sampleReport(home: home).path,
            findings: [CleanupFinding(
                detector: .runtimeVersions, tool: "node", path: directory, realpath: directory, source: nil,
                version: "20.1.0", size: 1_024, status: status, reason: .requiredByProjects, action: action,
                risk: .low, bucket: .excluded, identity: CleanupFileIdentity(device: 1, inode: 41)
            )],
            notes: [], skippedProtected: []
        )
    }

    func testPinnedPathsAreWrittenWithTildeInBothExportsAndRoundTrip() throws {
        let pin = plainHome.appending(path: "Dev/app/.nvmrc", directoryHint: .notDirectory).path
        let report = leftoverReport(status: .pinned(by: [pin]), action: .none, home: plainHome)

        let json = String(decoding: try CleanupReportRenderer.json(report, home: plainHome), as: UTF8.self)
        let text = CleanupReportRenderer.text(report, home: plainHome, reasonText: reasonLabel, statusText: statusLabel)

        XCTAssertTrue(json.contains("~/Dev/app/.nvmrc"), json)
        XCTAssertFalse(json.contains(plainHome.path), json)
        XCTAssertTrue(text.contains("~/Dev/app/.nvmrc"), text)
        XCTAssertFalse(text.contains(plainHome.path), text)
        let io = InMemoryReportIO()
        let file = CleanupReportFile(home: plainHome, io: io)
        try file.save(report)
        XCTAssertEqual(file.load()?.findings.first?.status, .pinned(by: [pin]))
    }

    func testTextSpellsTheBrewCleanupCommand() {
        let report = leftoverReport(status: .unused, action: .brew(.cleanup("node")), home: plainHome)

        let text = CleanupReportRenderer.text(report, home: plainHome, reasonText: reasonLabel, statusText: statusLabel)

        XCTAssertTrue(text.contains("brew cleanup -- node"), text)
        XCTAssertEqual(CleanupActionText.command(for: .cleanup("node")), "brew cleanup -- node")
    }
}
