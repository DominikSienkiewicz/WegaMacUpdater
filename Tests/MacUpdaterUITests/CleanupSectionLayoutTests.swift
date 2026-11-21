import XCTest
import MacUpdaterCore
@testable import WegaMacUpdater

@MainActor
final class CleanupSectionLayoutTests: XCTestCase {
    private typealias Row = CleanupPresentation.Row

    private let home = URL(filePath: "/Users/cleanup-test", directoryHint: .isDirectory)

    private struct Sample {
        var detector: CleanupDetectorID = .pathDuplicates
        let path: String
        var source: CleanupSource?
        var status: CleanupStatus = .expected
        var action: CleanupAction = .none
        var keep: CleanupKeep?
    }

    private func finding(_ sample: Sample) -> CleanupFinding {
        let url = URL(filePath: sample.path, directoryHint: .notDirectory)
        var bucket = CleanupBucket.needsDecision
        if case .none = sample.action { bucket = .excluded }
        return CleanupFinding(
            detector: sample.detector, tool: url.lastPathComponent, path: url, realpath: url, source: sample.source,
            version: nil, size: nil, status: sample.status, reason: .systemCopy, action: sample.action, risk: .low,
            bucket: bucket, identity: CleanupFileIdentity(device: 1, inode: 42),
            candidate: sample.keep.map {
                CleanupCandidate(
                    pathRole: .shadowed, removal: sample.action, removalSize: nil, dependents: [], processes: [], keep: $0
                )
            }
        )
    }

    private func rows(of findings: [CleanupFinding], kind: CleanupPresentation.Section.Kind) throws -> [Row] {
        let report = CleanupReport(
            createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            path: CleanupPathSnapshot(
                entries: ["/usr/bin"], ignoredEntries: [], shell: "zsh", capturedAt: nil, isApproximate: false
            ),
            findings: findings, notes: [], skippedProtected: []
        )
        let sections = CleanupPresentation.sections(report, home: home)
        return try XCTUnwrap(sections.first { $0.kind == kind }).rows
    }

    private var shadowedCask: CleanupFinding {
        finding(Sample(
            path: "/opt/homebrew/bin/claude", source: .homebrewCask(token: "claude-code"), status: .shadowed,
            action: .brew(.uninstallCask("claude-code"))
        ))
    }

    private var activeGit: CleanupFinding {
        finding(Sample(path: "/opt/homebrew/bin/git", source: .homebrewFormula(name: "git"), status: .active))
    }

    private var systemGit: CleanupFinding {
        finding(Sample(path: "/usr/bin/git", source: .system))
    }

    private var deadPathEntry: CleanupFinding {
        finding(Sample(
            detector: .pathHygiene, path: "/Users/cleanup-test/old/bin", status: .deadEntry,
            action: .instruction(.editShellFiles(entry: "~/old/bin", locations: []))
        ))
    }

    func testRowsSayWhetherTheyNeedAction() throws {
        let undecided = finding(Sample(
            path: "/usr/local/bin/ollama", source: .standalone, status: .shadowed, keep: .undecided
        ))
        let kept = finding(Sample(path: "/usr/local/bin/pnpm", source: .standalone, status: .active, keep: .kept))

        try withLanguage(.pl) {
            let duplicates = try rows(
                of: [shadowedCask, activeGit, systemGit, undecided, kept], kind: .duplicates
            )
            let actionable = Dictionary(uniqueKeysWithValues: duplicates.map { ($0.title, $0.isActionable) })

            XCTAssertEqual(actionable["/opt/homebrew/bin/claude"], true)
            XCTAssertEqual(actionable["/opt/homebrew/bin/git"], false)
            XCTAssertEqual(actionable["/usr/bin/git"], false)
            XCTAssertEqual(actionable["/usr/local/bin/ollama"], true)
            XCTAssertEqual(actionable["/usr/local/bin/pnpm"], false)
            XCTAssertEqual(try rows(of: [deadPathEntry], kind: .pathHygiene).map(\.isActionable), [true])
        }
    }

    func testDuplicateRowsCarryTheirOrigin() throws {
        let miseShim = finding(Sample(
            path: "/Users/cleanup-test/.local/share/mise/shims/java", source: .versionManager(.mise)
        ))
        let versionDirectory = finding(Sample(
            detector: .versionDirectories, path: "/Users/cleanup-test/.local/share/claude/versions/2.1.322",
            source: .nativeVersionDirectory(tool: "claude"), status: .unused
        ))

        try withLanguage(.pl) {
            let duplicates = try rows(of: [activeGit, miseShim], kind: .duplicates)

            XCTAssertEqual(
                duplicates.first { $0.title == "/opt/homebrew/bin/git" }?.origin,
                Row.Origin(source: "formuła Homebrew git", directory: "/opt/homebrew/bin")
            )
            XCTAssertEqual(
                duplicates.first { $0.title.hasSuffix("shims/java") }?.origin,
                Row.Origin(source: "menedżer wersji mise", directory: "~/.local/share/mise/shims")
            )
            XCTAssertNil(try rows(of: [versionDirectory], kind: .runtimes).first?.origin)
        }
    }

    func testLinkedEntryDetailKeepsOriginAndAction() throws {
        try withLanguage(.pl) {
            let row = try XCTUnwrap(try rows(of: [shadowedCask], kind: .duplicates).first)
            XCTAssertNotNil(row.origin)
            XCTAssertTrue(row.isActionable)

            let extended = row.appendingDetail("x")

            XCTAssertEqual(extended.origin, row.origin)
            XCTAssertTrue(extended.isActionable)
        }
    }

    // MARK: - Layout

    private typealias Group = CleanupPresentation.ToolGroup
    private typealias Origin = Row.Origin

    private func keepRow(tool: String?, title: String, keep: CleanupPresentation.KeepControl) -> Row {
        Row(
            findingID: title, groupHeader: tool, bucket: .excluded, status: "oczekiwana", title: title, detail: "",
            sizeText: nil, button: nil, note: "zostaje", keep: keep, isActionable: false, origin: nil
        )
    }

    private func row(tool: String?, title: String, origin: Origin? = nil, actionable: Bool = false, detail: String = "") -> Row {
        Row(
            findingID: title, groupHeader: tool, bucket: .excluded, status: "oczekiwana", title: title, detail: detail,
            sizeText: nil, button: nil, note: actionable ? "kopiuj" : "tylko informacja", keep: nil,
            isActionable: actionable, origin: origin
        )
    }

    private func section(_ rows: [Row]) -> CleanupPresentation.Section {
        CleanupPresentation.Section(kind: .duplicates, title: "Wiele kopii", notes: [], rows: rows)
    }

    private let mise = "menedżer wersji mise"
    private let installs = "~/.local/share/mise/installs/java/temurin-27/bin"

    private func javaTool(_ name: String) -> [Row] {
        [
            row(tool: name, title: "\(installs)/\(name)", origin: Origin(source: mise, directory: installs)),
            row(tool: nil, title: "~/.local/share/mise/shims/\(name)", origin: Origin(source: mise, directory: "~/.local/share/mise/shims")),
            row(tool: nil, title: "/usr/bin/\(name)", origin: Origin(source: "kopia systemowa", directory: "/usr/bin")),
        ]
    }

    func testActionableToolsComeFirstAndTheRestIsQuiet() throws {
        let gh = [row(tool: "gh", title: "/opt/homebrew/bin/gh", actionable: true), row(tool: nil, title: "/usr/local/bin/gh")]
        let git = [row(tool: "git", title: "/usr/bin/git", origin: Origin(source: "a", directory: "/usr/bin"))]
        let jq = [row(tool: "jq", title: "/usr/bin/jq", origin: Origin(source: "b", directory: "/usr/bin"))]

        try withLanguage(.pl) {
            let layout = try XCTUnwrap(CleanupPresentation.layout(of: section(git + gh + jq), search: ""))

            XCTAssertEqual(layout.shown.map(\.name), ["gh"])
            XCTAssertEqual(layout.shown.first?.rows, gh)
            XCTAssertEqual(layout.quiet, [.tool(Group(name: "git", rows: git)), .tool(Group(name: "jq", rows: jq))])
            XCTAssertEqual(layout.actionCount, 1)
            XCTAssertEqual(layout.headerNote, "1 do zrobienia")
            XCTAssertEqual(layout.quietTitle, "Bez akcji: 2 narzędzia")
        }
    }

    func testToolsFromOnePlaceShareAnOriginLine() throws {
        let rows = ["java", "javac", "jar"].flatMap(javaTool)

        try withLanguage(.pl) {
            let layout = try XCTUnwrap(CleanupPresentation.layout(of: section(rows), search: ""))

            XCTAssertEqual(layout.quiet.count, 1)
            guard case .origin(let line)? = layout.quiet.first else { return XCTFail("expected an origin line") }
            XCTAssertEqual(line.tools.map(\.name), ["java", "javac", "jar"])
            XCTAssertEqual(line.title, "3 polecenia · \(mise) · \(installs)")
            XCTAssertEqual(
                line.companions, "też: ~/.local/share/mise/shims (\(mise)), /usr/bin (kopia systemowa)"
            )
            XCTAssertEqual(layout.quietTitle, "Bez akcji: 3 narzędzia")
        }
    }

    func testALoneToolKeepsItsRows() throws {
        let rows = javaTool("java")

        try withLanguage(.pl) {
            let layout = try XCTUnwrap(CleanupPresentation.layout(of: section(rows), search: ""))

            XCTAssertEqual(layout.quiet, [.tool(Group(name: "java", rows: rows))])
        }
    }

    func testASectionWithNothingToDoSaysSo() throws {
        let info = [row(tool: "git", title: "/usr/bin/git")]

        try withLanguage(.pl) {
            let quiet = try XCTUnwrap(CleanupPresentation.layout(of: section(info), search: ""))
            let empty = try XCTUnwrap(CleanupPresentation.layout(of: section([]), search: ""))

            XCTAssertEqual(quiet.shown, [])
            XCTAssertEqual(quiet.actionCount, 0)
            XCTAssertEqual(quiet.headerNote, "nic do zrobienia")
            XCTAssertEqual(empty.quiet, [])
            XCTAssertNil(empty.quietTitle)
            XCTAssertNil(empty.headerNote)
        }
    }

    func testASectionWhoseRowsAllNeedActionHasNoQuietGroup() throws {
        let rows = [row(tool: "gh", title: "/opt/homebrew/bin/gh", actionable: true)]

        try withLanguage(.pl) {
            let layout = try XCTUnwrap(CleanupPresentation.layout(of: section(rows), search: ""))

            XCTAssertEqual(layout.quiet, [])
            XCTAssertNil(layout.quietTitle)
        }
    }

    func testRowsOfASectionWithoutToolsCountAsItems() throws {
        let rows = [row(tool: nil, title: "~/a"), row(tool: nil, title: "~/b")]

        try withLanguage(.pl) {
            let layout = try XCTUnwrap(CleanupPresentation.layout(of: section(rows), search: ""))

            XCTAssertEqual(layout.quiet.count, 2)
            XCTAssertEqual(layout.quietTitle, "Bez akcji: 2 pozycje")
        }
    }

    func testPolishPluralFormsForTheQuietGroup() throws {
        func quietTitle(count: Int) throws -> String? {
            let rows = (0..<count).map { row(tool: "t\($0)", title: "/usr/bin/t\($0)") }
            return try XCTUnwrap(CleanupPresentation.layout(of: section(rows), search: "")).quietTitle
        }

        try withLanguage(.pl) {
            XCTAssertEqual(try [1, 5, 12, 22].map(quietTitle), [
                "Bez akcji: 1 narzędzie", "Bez akcji: 5 narzędzi", "Bez akcji: 12 narzędzi", "Bez akcji: 22 narzędzia",
            ])
        }
        try withLanguage(.en) {
            XCTAssertEqual(try [1, 2].map(quietTitle), ["No action: 1 tool", "No action: 2 tools"])
        }
    }

    func testSearchShowsWholeMatchingToolsExpanded() throws {
        let rows = ["java", "javac", "jar"].flatMap(javaTool)
        let all = section(rows)

        try withLanguage(.pl) {
            let byName = try XCTUnwrap(CleanupPresentation.layout(of: all, search: "JAVAC"))
            XCTAssertEqual(byName.shown.map(\.name), ["javac"])
            XCTAssertEqual(byName.shown.first?.rows.count, 3)
            XCTAssertEqual(byName.quiet, [])
            XCTAssertNil(byName.quietTitle)

            let byPath = try XCTUnwrap(CleanupPresentation.layout(of: all, search: "temurin-27"))
            XCTAssertEqual(byPath.shown.count, 3)

            let blank = try XCTUnwrap(CleanupPresentation.layout(of: all, search: "   "))
            XCTAssertEqual(blank, CleanupPresentation.layout(of: all, search: ""))
            XCTAssertEqual(blank.quiet.count, 1)

            XCTAssertNil(CleanupPresentation.layout(of: all, search: "nothing-here"))
        }
    }

    func testSearchMatchesTheDetailText() throws {
        let rows = [row(tool: "git", title: "/usr/bin/git", detail: "aktywna · 2.47.0")]

        withLanguage(.pl) {
            XCTAssertEqual(CleanupPresentation.layout(of: section(rows), search: "2.47")?.shown.map(\.name), ["git"])
        }
    }

    func testSearchKeepsTheSectionsCount() throws {
        let rows = [row(tool: "gh", title: "/opt/homebrew/bin/gh", actionable: true)] + javaTool("java")

        try withLanguage(.pl) {
            let unsearched = try XCTUnwrap(CleanupPresentation.layout(of: section(rows), search: ""))
            let searched = try XCTUnwrap(CleanupPresentation.layout(of: section(rows), search: "java"))

            XCTAssertEqual(searched.headerNote, unsearched.headerNote)
            XCTAssertEqual(searched.actionCount, unsearched.actionCount)
        }
    }

    func testAToolWithAKeepChoiceStaysAmongTheShownOnes() throws {
        let gh = [row(tool: "gh", title: "/opt/homebrew/bin/gh", actionable: true)]
        let keeping = [
            keepRow(tool: "python3", title: "/usr/bin/python3", keep: .kept),
            keepRow(tool: nil, title: "/usr/local/bin/python3", keep: .notKept),
        ]

        try withLanguage(.pl) {
            let layout = try XCTUnwrap(CleanupPresentation.layout(of: section(gh + keeping), search: ""))

            XCTAssertEqual(layout.shown.map(\.name), ["gh", "python3"])
            XCTAssertEqual(layout.quiet, [])
            XCTAssertNil(layout.quietTitle)
            XCTAssertEqual(layout.actionCount, 1)
            XCTAssertEqual(layout.headerNote, "1 do zrobienia")
        }
    }

    func testBrokenLinkWithACopyableUnlinkIsActionable() throws {
        let link = finding(Sample(
            path: "/usr/local/bin/old", source: .standalone, status: .brokenLink,
            action: .command("unlink /usr/local/bin/old")
        ))

        try withLanguage(.pl) {
            let duplicates = try rows(of: [link], kind: .duplicates)

            XCTAssertEqual(duplicates.map(\.isActionable), [true])
            XCTAssertEqual(duplicates.first?.note, "unlink /usr/local/bin/old")
        }
    }

    func testLayoutTextsAreTranslated() throws {
        let rows = [row(tool: "gh", title: "/opt/homebrew/bin/gh", actionable: true)] + ["java", "javac"].flatMap(javaTool)

        try withLanguage(.en) {
            let layout = try XCTUnwrap(CleanupPresentation.layout(of: section(rows), search: ""))
            guard case .origin(let line)? = layout.quiet.first else { return XCTFail("expected an origin line") }

            XCTAssertEqual(layout.headerNote, "1 to do")
            XCTAssertEqual(line.title, "2 commands · \(mise) · \(installs)")
            XCTAssertEqual(line.companions?.hasPrefix("also: "), true)
            XCTAssertEqual(
                try XCTUnwrap(CleanupPresentation.layout(of: section([row(tool: "git", title: "/usr/bin/git")]), search: "")).headerNote,
                "nothing to do"
            )
        }
    }
}
