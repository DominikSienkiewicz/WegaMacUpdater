import XCTest
@testable import MacUpdaterCore

/// M3(c) — Wega used to write a `sudo` shim and an askpass helper into Application Support
/// on every launch, before the user had agreed to anything or asked for a single update.
/// The files are now installed lazily, at the point brew is about to need them.
final class AskpassBootstrapDecisionTests: XCTestCase {
    /// Touch ID authenticates sudo through PAM; the shim would actively suppress that
    /// prompt, so we neither need nor install it.
    func testTouchIDEnabledNeedsNoAskpassFiles() {
        XCTAssertFalse(HomebrewEnvironment.shouldBootstrapAskpass(touchIDState: .enabled))
    }

    func testTouchIDAvailableButUnusedStillNeedsAskpassFiles() {
        XCTAssertTrue(HomebrewEnvironment.shouldBootstrapAskpass(touchIDState: .available))
    }

    func testMachineWithoutTouchIDNeedsAskpassFiles() {
        XCTAssertTrue(HomebrewEnvironment.shouldBootstrapAskpass(touchIDState: .notSupported))
    }
}
