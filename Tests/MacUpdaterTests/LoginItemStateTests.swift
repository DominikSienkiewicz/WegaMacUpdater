import XCTest
@testable import MacUpdaterCore

/// BG-02 — the "Uruchamiaj przy logowaniu" toggle must show the *real* `SMAppService`
/// status, never a stored guess. `LoginItemState` collapses `SMAppService`'s five statuses
/// into the three the toggle can act on: it launches Wega at login, it does not, or the
/// user switched it off in System Settings → Login Items and has to finish there. This is
/// the pure decision the view renders, so it is pinned directly.
final class LoginItemStateTests: XCTestCase {
    func testEnabledReadsAsOn() {
        XCTAssertEqual(LoginItemState(status: .enabled), .enabled)
        XCTAssertTrue(LoginItemState(status: .enabled).isOn)
    }

    func testNotRegisteredReadsAsDisabled() {
        XCTAssertEqual(LoginItemState(status: .notRegistered), .disabled)
        XCTAssertFalse(LoginItemState(status: .notRegistered).isOn)
    }

    func testNotFoundReadsAsDisabled() {
        XCTAssertEqual(LoginItemState(status: .notFound), .disabled)
    }

    /// An unknown status is not a licence to claim the app relaunches at login.
    func testUnknownStatusReadsAsDisabled() {
        XCTAssertEqual(LoginItemState(status: .unknown), .disabled)
    }

    /// The item is registered but the user disabled it in System Settings → Login Items:
    /// it will not launch, so the toggle is *off* and points the user at System Settings.
    func testRequiresApprovalIsOffButNeedsSystemSettings() {
        let state = LoginItemState(status: .requiresApproval)
        XCTAssertEqual(state, .requiresApproval)
        XCTAssertFalse(state.isOn)
        XCTAssertTrue(state.needsSystemSettings)
    }

    func testOnlyTheApprovalStateNeedsSystemSettings() {
        XCTAssertFalse(LoginItemState.enabled.needsSystemSettings)
        XCTAssertFalse(LoginItemState.disabled.needsSystemSettings)
    }
}
