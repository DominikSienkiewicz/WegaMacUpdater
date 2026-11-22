import AppKit
import Foundation
import SwiftUI
import Testing
@testable import WegaMacUpdater

/// UX-15 — the notices above the Updates list each had a shape of their own: a stroked
/// banner, a tinted full-width strip, a white card, a red label. They now share
/// `WegaCallout`, whose level is the only thing that changes how a notice looks.
@Suite("Wega callout")
@MainActor
struct WegaCalloutTests {
    @Test func bannerVariantsMapOntoCalloutLevels() {
        #expect(WegaCalloutLevel(banner: .success) == .success)
        #expect(WegaCalloutLevel(banner: .danger) == .urgent)
    }

    /// Levels must not be told apart by colour alone.
    @Test func everyLevelHasItsOwnSymbol() {
        let symbols = Set(WegaCalloutLevel.allCases.map(\.symbolName))

        #expect(symbols.count == WegaCalloutLevel.allCases.count)
    }

    /// UX-07's cap holds for the shared component itself, not only for the banners built on it.
    @Test func aLongMessageStopsAtThreeLines() {
        func height(_ lines: Int) -> CGFloat {
            let message = (1...lines).map { "line \($0)" }.joined(separator: "\n")
            let view = WegaCallout(.urgent, title: "Błąd", message: message).frame(width: 360)
            return NSHostingView(rootView: view).fittingSize.height
        }

        #expect(height(3) > height(1))
        #expect(abs(height(100) - height(3)) <= 1)
    }

    @Test func everyNoticeOnTheUpdatesPathUsesTheOneCallout() throws {
        let shared = try source("Sources/MacUpdater/SharedViews.swift")
        let banner = try slice(shared, from: "struct BannerView: View", to: "/// F3 — the per-app opt-in")
        let error = try slice(shared, from: "struct ErrorBanner: View", to: "// MARK: - WegaBadge")
        let detail = try source("Sources/MacUpdater/DetailColumn.swift")
        let brew = try slice(detail, from: "private struct BrewInviteCard: View", to: "struct DetailColumn: View")
        let update = try source("Sources/MacUpdater/UpdateView.swift")
        // Up to the next declaration: the comment it used to end at went with UXP-25.
        let stale = try slice(update, from: "private var staleCaskCard: some View", to: "private var selectAllState: SelectAllState")
        let checksum = try slice(update, from: "private func caskTransparencyNote", to: "// MARK: - List groupings (UX-18)")

        for notice in [banner, error, brew, stale, checksum] {
            #expect(notice.contains("WegaCallout("), "each notice draws through the shared callout")
        }
        #expect(!banner.contains(".stroke("), "the banner no longer draws a frame of its own")
    }

    private func source(_ relativePath: String, file: String = #filePath) throws -> String {
        let root = URL(fileURLWithPath: file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }

    private func slice(_ source: String, from start: String, to end: String) throws -> Substring {
        let lower = try #require(source.range(of: start)?.lowerBound, "missing anchor: \(start)")
        let upper = try #require(
            source.range(of: end, range: lower..<source.endIndex)?.lowerBound, "missing anchor: \(end)"
        )
        return source[lower..<upper]
    }
}
