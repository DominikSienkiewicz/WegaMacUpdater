import AppKit
import SwiftUI
import XCTest
import MacUpdaterCore
@testable import WegaMacUpdater

@MainActor
final class CleanupToolsReviewTests: XCTestCase {
    private let home = URL(filePath: "/Users/test", directoryHint: .isDirectory)
    private func finding(_ detector: CleanupDetectorID, _ tool: String, _ path: String, source: CleanupSource? = nil,
                         reason: CleanupReason, status: CleanupStatus, action: CleanupAction = .none) -> CleanupFinding {
        let url = URL(filePath: path, directoryHint: .notDirectory)
        return CleanupFinding(detector: detector, tool: tool, path: url, realpath: url, source: source,
                              version: detector == .gradle ? "8.7" : nil, size: [.gradle: 130_000_000, .homebrew: 24_000_000][detector],
                              status: status, reason: reason,
                              action: action, risk: .low, bucket: action == .none ? .excluded : .needsDecision, identity: nil)
    }

    private var findings: [CleanupFinding] {
        [
            finding(.pathDuplicates, "git", "/opt/homebrew/bin/git", source: .homebrewFormula(name: "git"), reason: .currentVersion, status: .active),
            finding(.pathDuplicates, "git", "/usr/bin/git", source: .system, reason: .systemCopy, status: .expected),
            finding(.homebrew, "wget", "/cache/wget", reason: .homebrewLeftovers(items: 1), status: .unused, action: .brew(.cleanup("wget"))),
            finding(.gradle, "gradle", "/cache/gradle", reason: .unusedGradleDistribution, status: .unused, action: .trash([URL(filePath: "/cache/gradle")])),
        ]
    }

    private func review(approximate: Bool = true, notes: [CleanupDetectorNote] = [], query: String = "", inspected: String? = nil) -> CleanupToolsReview {
        let path = CleanupPathSnapshot(entries: ["/opt/homebrew/bin", "/usr/bin"], ignoredEntries: [], shell: nil, capturedAt: nil, isApproximate: approximate)
        let report = CleanupReport(createdAt: .now, path: path, findings: findings, notes: notes, skippedProtected: [])
        return CleanupToolsReview(report: report, home: home, mapEnabled: false, search: query, inspectedTool: inspected)
    }

    func testCardsExposeEvidenceAndRouteEachActionToItsFinding() throws {
        try withLanguage(.pl) {
            let all = review()
            XCTAssertEqual(all.headline, "3 wyniki do przejrzenia")
            XCTAssertEqual(all.cards.map(\.kind), [.duplicates, .homebrew, .gradle])
            let git = try XCTUnwrap(all.cards.first)
            XCTAssertEqual(git.group.rows.map(\.title), ["/opt/homebrew/bin/git", "/usr/bin/git"])
            XCTAssertTrue(git.group.checkShellOrder)
            XCTAssertNil(git.quickAction)
            XCTAssertEqual(all.cards.map { $0.quickAction?.findingID }, [nil, findings[2].id, findings[3].id])
            XCTAssertEqual(all.cards.map { $0.quickAction?.button }, [nil, .brewCleanup, .trash])
            XCTAssertEqual(Set(all.cards.map(\.id)).count, all.cards.count)
            let match = review(query: "/usr/bin/git")
            XCTAssertEqual(match.cards.map(\.id), [git.id])
            XCTAssertEqual(match.cards.first?.group.rows.count, 2)
            XCTAssertEqual(match.headline, all.headline)
            let checked = review(approximate: false, inspected: "git")
            XCTAssertEqual(checked.cards.first?.id, git.id)
            XCTAssertEqual(checked.cards.first?.group.checkShellOrder, false)
            XCTAssertEqual(checked.cards.first?.subtitle, "Pierwsza w ścieżce Terminala: Kopia z Homebrew")
            XCTAssertEqual(checked.count, 2)
        }
    }

    func testIncompleteSectionsRemainSeparateFromCheckedAreasAndMapSettingApplies() {
        let review = review(notes: [.init(detector: .runtimeVersions, kind: .noProjectRoots), .init(detector: .tccMap, kind: .tccUnreadable)])
        XCTAssertTrue(review.scope.map(\.id).contains(.gradle))
        XCTAssertTrue(review.scope.map(\.id).contains(.pathHygiene))
        XCTAssertFalse(review.checked.map(\.id).contains(.gradle))
        XCTAssertEqual(review.warnings, [CleanupPresentation.noteText(.init(detector: .runtimeVersions, kind: .noProjectRoots))])
    }

    func testSystemCopyCanLeadAndOlderInstallationsRemainSeparateFromCopies() throws {
        let path = CleanupPathSnapshot(entries: ["/usr/bin", "/opt/homebrew/bin"], ignoredEntries: [], shell: "zsh", capturedAt: .now, isApproximate: false)
        let old = finding(.versionDirectories, "git", "/cache/git/1.0", reason: .olderVersion(current: "2.0"), status: .unused, action: .trash([URL(filePath: "/cache/git/1.0")]))
        let report = CleanupReport(createdAt: .now, path: path, findings: findings + [old], notes: [], skippedProtected: [])
        try withLanguage(.pl) {
            let review = CleanupToolsReview(report: report, home: home, mapEnabled: false, search: "", inspectedTool: "git")
            let copies = try XCTUnwrap(review.cards.first { $0.group.rows.count > 1 })
            XCTAssertEqual(copies.subtitle, "Pierwsza w ścieżce Terminala: Kopia systemowa")
            XCTAssertEqual(copies.group.rows.count, 2)
            XCTAssertTrue(review.cards.contains { $0.quickAction?.findingID == old.id })
        }
    }

    func testHealthyEmptyMapAndBrokenLinksAreNotUnverifiedCopyPairs() throws {
        let link = finding(.pathDuplicates, "git", "/missing/bin/git", source: .standalone, reason: .brokenLink,
                           status: .brokenLink, action: .command("unlink /missing/bin/git"))
        let path = CleanupPathSnapshot(entries: ["/missing/bin", "/usr/bin"], ignoredEntries: [], shell: nil, capturedAt: nil, isApproximate: true)
        let report = CleanupReport(createdAt: .now, path: path, findings: [link, findings[1]], notes: [.init(detector: .tccMap, kind: .tccMapEmpty)], skippedProtected: [])
        let review = CleanupToolsReview(report: report, home: home, mapEnabled: true, search: "", inspectedTool: nil)
        XCTAssertTrue(review.warnings.isEmpty)
        XCTAssertEqual(review.mapAccessReminder, CleanupPresentation.mapAccessReminder)
        XCTAssertEqual(try XCTUnwrap(review.cards.first).group.checkShellOrder, false)
        XCTAssertTrue(review.scope.contains { $0.id == .filesAndFolders && !$0.section.notes.isEmpty })
    }

    func testExpandingOneNativeCardAddsOnlyItsDetailsToTheList() throws {
        let cards = review().cards
        let first = try XCTUnwrap(cards.first)
        let actions = CleanupFindingActions(canAct: true, copiedCommand: nil, onRemove: { _ in }, onCopy: { _ in },
                                           onKeep: { _ in }, onUninstallApp: { _ in }, onReviewAppCopies: { _ in }, onCheckPath: { _ in })
        func host(_ cards: [CleanupToolsReview.Card], expanded: String?) -> NSView {
            NSHostingView(rootView: VStack(spacing: 12) {
                ForEach(cards) { card in
                    CleanupToolCard(card: card, searching: false, actions: actions, expanded: .constant(card.id == expanded))
                }
            }.frame(width: 640).padding(12))
        }
        let collapsed = host(cards, expanded: nil).fittingSize
        let view = host(cards, expanded: first.id)
        let expanded = view.fittingSize
        let oneCardGrowth = host([first], expanded: first.id).fittingSize.height - host([first], expanded: nil).fittingSize.height
        XCTAssertGreaterThan(oneCardGrowth, 30)
        XCTAssertEqual(expanded.width, collapsed.width)
        XCTAssertEqual(expanded.height - collapsed.height, oneCardGrowth, accuracy: 2)
    }

    func testResultCountInBothLanguages() {
        withLanguage(.pl) {
            XCTAssertEqual([1, 3, 12, 22].map { trp("%@ wyników do przejrzenia", $0) },
                           ["1 wynik do przejrzenia", "3 wyniki do przejrzenia", "12 wyników do przejrzenia", "22 wyniki do przejrzenia"])
        }
        withLanguage(.en) {
            XCTAssertEqual(review().headline, "3 results to review")
            XCTAssertEqual(review().cards.first?.title, "git was found in two locations")
        }
    }
}
