import XCTest
@testable import MacUpdaterCore

/// M5 (drive-by) — the Inventory table asked for columns weighted 1.6 / 0.6 / 1.2 / 0.8 / 1.2
/// and wrote it as `.frame(maxWidth: .infinity * flex)`. Infinity times any positive number
/// is infinity, so every column got the same width and the designed layout never once
/// rendered. The arithmetic lives here, where it can be checked.
final class ProportionalWidthsTests: XCTestCase {
    /// The Inventory table's real weights. They sum to 5.4, so a 1000pt row gives the name
    /// column 1000 × 1.6 / 5.4 ≈ 296pt — and the version column less than half of that,
    /// which is the whole point and is exactly what the old code failed to do.
    func testWidthsAreProportionalToTheirWeights() {
        let widths = ColumnLayout.proportionalWidths(total: 1000, weights: [1.6, 0.6, 1.2, 0.8, 1.2])
        XCTAssertEqual(widths, [296.3, 111.1, 222.2, 148.1, 222.2].map { CGFloat($0) }, accuracy: 0.1)
    }

    func testWidthsSumToTheAvailableWidth() {
        let widths = ColumnLayout.proportionalWidths(total: 800, weights: [1.6, 0.6, 1.2])
        XCTAssertEqual(widths.reduce(0, +), 800, accuracy: 0.001)
    }

    func testEqualWeightsSplitEvenly() {
        let widths = ColumnLayout.proportionalWidths(total: 300, weights: [1, 1, 1])
        XCTAssertEqual(widths, [100, 100, 100])
    }

    func testSpacingIsRemovedBeforeDistributing() {
        let widths = ColumnLayout.proportionalWidths(total: 320, weights: [1, 1], spacing: 20)
        XCTAssertEqual(widths, [150, 150])
    }

    /// Degenerate inputs must not divide by zero or hand back negative frames.
    func testZeroWeightsYieldZeroWidths() {
        XCTAssertEqual(ColumnLayout.proportionalWidths(total: 500, weights: [0, 0]), [0, 0])
    }

    func testNoColumnsYieldNoWidths() {
        XCTAssertTrue(ColumnLayout.proportionalWidths(total: 500, weights: []).isEmpty)
    }

    func testWidthNeverGoesNegativeWhenSpacingExceedsAvailableWidth() {
        let widths = ColumnLayout.proportionalWidths(total: 10, weights: [1, 1], spacing: 40)
        XCTAssertEqual(widths, [0, 0])
    }
}

private func XCTAssertEqual(
    _ lhs: [CGFloat], _ rhs: [CGFloat], accuracy: CGFloat,
    file: StaticString = #filePath, line: UInt = #line
) {
    XCTAssertEqual(lhs.count, rhs.count, file: file, line: line)
    for (a, b) in zip(lhs, rhs) {
        XCTAssertEqual(a, b, accuracy: accuracy, file: file, line: line)
    }
}
