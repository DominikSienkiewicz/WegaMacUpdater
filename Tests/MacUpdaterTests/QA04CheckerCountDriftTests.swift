import Foundation
import Testing
@testable import MacUpdaterCore

/// QA-04 — the README's counts have to come from the code, not from whenever someone last
/// looked.
///
/// The card exists because README claims drifted from the implementation, and the checker
/// count was its very first example: *"Nine checkers" vs 13*. That drift is not a one-off — it
/// reappears every time a checker is added, because nothing connects the number in the prose
/// to the number in `ManualUpdateScanner`. Adding a thirteenth checker and forgetting one
/// sentence is a two-second mistake with no consequence until a reader trusts the sentence.
///
/// So the connection is made here. These read both files and compare, which is the only way
/// a documentation claim can be held to a code fact: `swift build` and `swiftlint` cannot see
/// prose, and `scripts/test-source-paths-guard.sh` covers only `scripts/` and `.github/`.
///
/// Deliberately narrow. This pins the two claims the card names — how many manual checkers run,
/// and which sources hand the update to the app's own updater — and nothing else. A guard that
/// tried to verify every sentence in a 570-line README would fail on rewording and be deleted
/// within a month.
@Suite("QA-04 — README counts track the code")
struct QA04CheckerCountDriftTests {

    /// The prose number and the number of checkers the scanner actually builds.
    ///
    /// Red before the fix: the scanner instantiated 13 checkers while README said *"all nine
    /// manual checkers"* — the exact claim the card cites, still stale four checkers later.
    @Test func readmeStatesTheNumberOfCheckersTheScannerActuallyRuns() throws {
        let built = try instantiatedCheckerNames()

        #expect(built.count >= 9, "sanity: the scanner factory was found and parsed")

        let claimed = try #require(
            try firstMatch(in: readme(), pattern: #"runs all (\d+) manual checkers"#),
            """
            QA-04: README must state the checker count as a digit ("runs all 13 manual checkers"). \
            A spelled-out number is what went stale last time and is what this guard cannot track.
            """
        )

        #expect(Int(claimed) == built.count,
                """
                QA-04: README says \(claimed) manual checkers, ManualUpdateScanner builds \
                \(built.count) (\(built.sorted().joined(separator: ", "))). \
                Update the README sentence in the same change that adds or removes a checker.
                """)
    }

    /// The same drift, one level down: the scanner's own doc comment lists the checkers by
    /// name, and that list had gone stale too — it named nine while the factory built
    /// thirteen, which is where the README's "nine" came from in the first place.
    @Test func theScannerDocCommentListsEveryCheckerItBuilds() throws {
        let built = try instantiatedCheckerNames()
        let header = try slice(scannerSource(), from: "manual-app update checkers", to: "public struct")

        let missing = built.filter { !header.localizedCaseInsensitiveContains(prose(for: $0)) }

        #expect(missing.isEmpty,
                """
                QA-04: ManualUpdateScanner's doc comment does not mention \
                \(missing.sorted().joined(separator: ", ")). \
                The README's stale count was copied from this list — keep them in step.
                """)
    }

    /// Which sources hand the update to the app's own updater. README names them in prose;
    /// `VendorUpdateSource.updateActionKind` decides them. The two drifted apart when Discord,
    /// Signal, Chrome and Obsidian joined `.launchApp` and the sentence was not touched.
    @Test func readmeNamesEverySourceThatRoutesThroughTheAppsOwnUpdater() throws {
        let launchCase = try slice(
            actionSource(),
            from: "case .sparkle,",
            to: "return .launchApp"
        )
        let routed = launchCase
            .split(whereSeparator: { ",:. \n".contains($0) })
            .map(String.init)
            .filter { !$0.isEmpty && $0 != "case" }

        #expect(routed.count >= 8, "sanity: the .launchApp case was found and parsed")

        // Scoped to the parenthetical in the "Act" step, not to the whole README: every one
        // of these names also appears in the priority table, so a document-wide search would
        // pass on a list that is missing four of them — which is exactly the state this test
        // was written to catch.
        let named = try slice(readme(), from: "self-updating apps whose cask lags (", to: ")")

        // Sparkle is described separately in the same sentence ("Sparkle apps prompt inside
        // the app itself"), so it is the one member of the case the list does not repeat.
        let missing = routed
            .filter { $0 != "sparkle" }
            .filter { !named.localizedCaseInsensitiveContains(prose(for: $0)) }

        #expect(missing.isEmpty,
                """
                QA-04: the "Act" step does not name \(missing.sorted().joined(separator: ", ")) among the \
                self-updating apps launched so their own updater takes over, though \
                VendorUpdateSource.updateActionKind sends them to .launchApp.
                """)
    }

    // MARK: Helpers

    /// The checkers the scanner builds, as their type-name stems (`sparkle`, `jetbrains`, …).
    private func instantiatedCheckerNames() throws -> [String] {
        let source = try scannerSource()
        return try matches(in: source, pattern: #"let \w+ = (\w+)UpdateChecker\(\)|let \w+ = (GitHubReleases)Checker\(\)"#)
            .map { $0.lowercased() }
    }

    /// Type stems and prose spellings are not the same word. Only the ones that actually
    /// differ need an entry; everything else matches on its own name.
    private func prose(for checker: String) -> String {
        switch checker {
        case "githubreleases": return "GitHub"
        case "googledrive":    return "Google Drive"
        case "jetbrains":      return "JetBrains"
        default:               return checker
        }
    }

    private func packageRoot(file: String = #filePath) -> URL {
        URL(fileURLWithPath: file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func read(_ relativePath: String) throws -> String {
        try String(contentsOf: packageRoot().appendingPathComponent(relativePath), encoding: .utf8)
    }

    private func readme() throws -> String { try read("README.md") }
    private func scannerSource() throws -> String { try read("Sources/MacUpdaterCore/ManualUpdateScanner.swift") }
    private func actionSource() throws -> String { try read("Sources/MacUpdaterCore/VendorUpdateAction.swift") }

    private func slice(_ text: String, from: String, to: String) throws -> String {
        let start = try #require(text.range(of: from))
        let region = text[start.lowerBound...]
        let end = try #require(region.range(of: to))
        return String(region[..<end.lowerBound])
    }

    private func matches(in text: String, pattern: String) throws -> [String] {
        let regex = try NSRegularExpression(pattern: pattern)
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            (1..<match.numberOfRanges)
                .compactMap { Range(match.range(at: $0), in: text).map { String(text[$0]) } }
                .first
        }
    }

    private func firstMatch(in text: String, pattern: String) throws -> String? {
        try matches(in: text, pattern: pattern).first
    }
}
