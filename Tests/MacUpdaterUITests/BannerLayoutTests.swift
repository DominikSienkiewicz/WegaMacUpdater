import SwiftUI
import XCTest
@testable import WegaMacUpdater

/// UX-07: an error banner used to paste brew's whole, untranslated `stderr` into its
/// message with no line cap, so a long failure could grow the banner until it pushed the
/// rest of the window off-screen. The message is now capped at `lineLimit(3)`; these tests
/// pin that a long, multi-line message renders no taller than a three-line one.
final class BannerLayoutTests: XCTestCase {
    /// A stand-in for brew's `stderr`: many newline-separated lines, exactly what used to
    /// arrive verbatim in the banner. Each line is short so line count — not wrapping —
    /// drives the height, keeping the comparison unambiguous.
    private static func lines(_ count: Int) -> String {
        (1...count).map { "line \($0)" }.joined(separator: "\n")
    }

    @MainActor
    private func bannerHeight(message: String) -> CGFloat {
        let view = BannerView(
            data: BannerData(
                variant: .danger,
                title: "Błąd Homebrew",
                message: message,
                action: .openLogs
            ),
            onClose: {}
        )
        .frame(width: 360)

        return NSHostingView(rootView: view).fittingSize.height
    }

    @MainActor
    func testLongStderrDoesNotGrowBannerBeyondThreeLines() {
        let threeLineHeight = bannerHeight(message: Self.lines(3))
        let longStderrHeight = bannerHeight(message: Self.lines(100))

        XCTAssertEqual(
            longStderrHeight,
            threeLineHeight,
            accuracy: 1.0,
            "A 100-line stderr must render no taller than a three-line message — lineLimit(3) is missing or higher"
        )
    }

    /// Guards the measurement itself: the fitting height has to react to line count below
    /// the cap, otherwise the equality test above could pass on a degenerate zero height.
    @MainActor
    func testBannerHeightGrowsWithLineCountBelowTheCap() {
        let oneLineHeight = bannerHeight(message: Self.lines(1))
        let threeLineHeight = bannerHeight(message: Self.lines(3))

        XCTAssertGreaterThan(threeLineHeight, oneLineHeight)
    }

    @MainActor
    private func errorBannerHeight(message: String) -> CGFloat {
        let view = ErrorBanner(message: message).frame(width: 360)
        return NSHostingView(rootView: view).fittingSize.height
    }

    /// The sibling `ErrorBanner` (Inventory / Uninstall / Migration) is capped the same way.
    @MainActor
    func testErrorBannerLongMessageDoesNotGrowBeyondThreeLines() {
        let threeLineHeight = errorBannerHeight(message: Self.lines(3))
        let longStderrHeight = errorBannerHeight(message: Self.lines(100))

        XCTAssertEqual(
            longStderrHeight,
            threeLineHeight,
            accuracy: 1.0,
            "A 100-line message must render no taller than a three-line one in ErrorBanner too"
        )
    }
}
