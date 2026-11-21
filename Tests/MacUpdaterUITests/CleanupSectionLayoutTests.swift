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
}
