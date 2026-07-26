import XCTest

/// QA-10c — the spawn timeout for UI tests that launch the real app must be configurable rather
/// than a hard-coded 10 s, so slower machines and CI can raise it via the environment.
final class UITestTimeoutTests: XCTestCase {
    func testDefaultsToTenSecondsWhenEnvironmentUnset() {
        XCTAssertEqual(UITestTimeout.resolved(from: [:]), 10)
    }

    func testReadsPositiveOverrideFromEnvironment() {
        let environment = [UITestTimeout.environmentKey: "42.5"]
        XCTAssertEqual(UITestTimeout.resolved(from: environment), 42.5)
    }

    func testTrimsSurroundingWhitespaceInOverride() {
        let environment = [UITestTimeout.environmentKey: "  30  "]
        XCTAssertEqual(UITestTimeout.resolved(from: environment), 30)
    }

    func testIgnoresNonNumericOverride() {
        let environment = [UITestTimeout.environmentKey: "soon"]
        XCTAssertEqual(UITestTimeout.resolved(from: environment), 10)
    }

    func testIgnoresEmptyOverride() {
        let environment = [UITestTimeout.environmentKey: "   "]
        XCTAssertEqual(UITestTimeout.resolved(from: environment), 10)
    }

    func testIgnoresNonPositiveOverride() {
        XCTAssertEqual(UITestTimeout.resolved(from: [UITestTimeout.environmentKey: "0"]), 10)
        XCTAssertEqual(UITestTimeout.resolved(from: [UITestTimeout.environmentKey: "-5"]), 10)
    }
}
