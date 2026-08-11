import Foundation
import XCTest
@testable import WegaMacUpdater

/// A banner that takes itself off the screen after three seconds is only safe if it was
/// never carrying anything the user still needed. These pin the rule that decides which
/// banners those are — and the assumption it leans on.
final class BannerDismissalTests: XCTestCase {

    private func banner(_ variant: BannerData.Variant, action: BannerAction? = nil) -> BannerData {
        BannerData(variant: variant, title: "title", message: "message", action: action)
    }

    /// The banner in the screenshot this came from: "Zaktualizowano 1 pakietów / Wszystko
    /// gotowe." — nothing failed, nothing to press.
    func testASuccessBannerWithNothingToPressDismissesItself() {
        XCTAssertTrue(BannerDismissal.isSelfDismissing(banner(.success)))
    }

    /// The reason the rule reads the action and not just the variant: a success banner that
    /// grows a button must stop vanishing, without anyone having to remember this file.
    func testASuccessBannerCarryingAnActionWaits() {
        for action in [BannerAction.openLogs, .openSettings, .openAppManagementSettings] {
            XCTAssertFalse(
                BannerDismissal.isSelfDismissing(banner(.success, action: action)),
                "a success banner offering \(action) must stay until the action is taken or dismissed"
            )
        }
    }

    /// A failure has to be read to be understood, and some of these are the only place the
    /// user is told at all.
    func testFailuresAlwaysWait() {
        XCTAssertFalse(BannerDismissal.isSelfDismissing(banner(.danger)))
        XCTAssertFalse(BannerDismissal.isSelfDismissing(banner(.danger, action: .openLogs)))
    }

    /// `BannerDismissal` excludes sticky banners — the ones the user must not miss — only
    /// because every sticky banner raised today is a `.danger`. That is an assumption about
    /// call sites, not something the rule can check, so it is checked here: a sticky success
    /// banner would be dismissed by a timer despite being raised precisely because it must
    /// not be missed.
    func testEveryStickyBannerIsRaisedAsAFailure() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // MacUpdaterUITests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // <root>
            .appendingPathComponent("Sources/MacUpdater")

        let files = try FileManager.default
            .contentsOfDirectory(at: sources, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }

        // `showStickyBanner(BannerData(variant: .danger` — allowing whitespace and newlines
        // between the call and the variant, which the formatter is free to move.
        let callSite = try NSRegularExpression(pattern: #"showStickyBanner\(\s*BannerData\(\s*variant:\s*\.(\w+)"#)

        var variants: [String] = []
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            let range = NSRange(text.startIndex..., in: text)
            for match in callSite.matches(in: text, range: range) {
                guard let found = Range(match.range(at: 1), in: text) else { continue }
                variants.append(String(text[found]))
            }
        }

        XCTAssertFalse(variants.isEmpty, "Sanity: the scan should find the sticky banner call sites")
        XCTAssertEqual(
            Set(variants),
            ["danger"],
            "A sticky banner raised as .success would be auto-dismissed by BannerDismissal"
        )
    }

    func testTheBannerIsReadableBeforeItLeaves() {
        XCTAssertEqual(BannerDismissal.delay, .seconds(3))
    }

    /// "Ogranicz ruch" has to actually change the dismissal, not merely be consulted. The
    /// banner still leaves visibly under it — a fade rather than nothing — so this asserts
    /// the two animations differ instead of asserting either one's shape.
    func testReducedMotionChangesHowTheBannerLeaves() {
        XCTAssertNotEqual(
            BannerDismissal.removal(reduceMotion: true),
            BannerDismissal.removal(reduceMotion: false),
            "The spring is used regardless of the accessibility setting"
        )
    }
}
