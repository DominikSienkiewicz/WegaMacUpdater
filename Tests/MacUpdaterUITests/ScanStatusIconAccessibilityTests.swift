import XCTest

@testable import WegaMacUpdater

/// UX-09 — the Updates sidebar used to signal scan success vs failure with colour alone (same
/// glyph, green vs red) and told VoiceOver nothing. A failed scan must now change the *symbol*,
/// and every observable scan state must expose a spoken `accessibilityValue`, so the status
/// reaches users who cannot tell the colours apart and users on VoiceOver.
final class ScanStatusIconAccessibilityTests: XCTestCase {
    private let base = "arrow.triangle.2.circlepath"

    private func semantics(_ activity: UpdateActivity) -> ScanStatusAccessibilitySemantics {
        ScanStatusAccessibilitySemantics(activity: activity, baseSymbol: base)
    }

    func testScanFailureChangesTheSymbolNotJustTheColour() {
        XCTAssertNotEqual(
            semantics(.error).symbolName, base,
            "A failed scan must swap the icon symbol, not only recolour it."
        )
    }

    func testEveryObservableScanStateExposesAnAccessibilityValue() {
        XCTAssertNotNil(semantics(.scanning).accessibilityValue)
        XCTAssertNotNil(semantics(.success).accessibilityValue)
        XCTAssertNotNil(semantics(.error).accessibilityValue)
    }

    func testFailureAndSuccessDifferInSymbolAndAccessibilityValue() {
        let success = semantics(.success)
        let failure = semantics(.error)

        XCTAssertNotEqual(
            failure.symbolName, success.symbolName,
            "Colour-blind users need distinct symbols for success and failure."
        )
        XCTAssertNotEqual(
            failure.accessibilityValue, success.accessibilityValue,
            "VoiceOver must announce success and failure differently."
        )
    }

    func testIdleKeepsTheBaseSymbolAndAnnouncesNoScanStatus() {
        XCTAssertEqual(semantics(.idle).symbolName, base)
        XCTAssertNil(semantics(.idle).accessibilityValue)
    }
}
