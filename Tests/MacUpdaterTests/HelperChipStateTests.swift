import XCTest
@testable import MacUpdaterCore

/// M3(a) — the sidebar chip used to read "brew · helper aktywny" unconditionally, a green
/// dot next to a claim nobody had checked. It now reports what `SMAppService` actually
/// says, collapsed to the three states a user can act on.
final class HelperChipStateTests: XCTestCase {
    func testEnabledHelperReadsAsActive() {
        XCTAssertEqual(HelperChipState(status: .enabled), .active)
    }

    /// The one state with an action attached: macOS is waiting for the user in
    /// System Settings → Login Items.
    func testRequiresApprovalIsItsOwnState() {
        XCTAssertEqual(HelperChipState(status: .requiresApproval), .needsApproval)
    }

    func testNotRegisteredReadsAsInactive() {
        XCTAssertEqual(HelperChipState(status: .notRegistered), .inactive)
    }

    func testNotFoundReadsAsInactive() {
        XCTAssertEqual(HelperChipState(status: .notFound), .inactive)
    }

    /// An unknown status is not a licence to claim the helper works.
    func testUnknownStatusReadsAsInactive() {
        XCTAssertEqual(HelperChipState(status: .unknown), .inactive)
    }

    func testOnlyTheApprovalStateOffersAnAction() {
        XCTAssertTrue(HelperChipState.needsApproval.opensLoginItemsSettings)
        XCTAssertFalse(HelperChipState.active.opensLoginItemsSettings)
        XCTAssertFalse(HelperChipState.inactive.opensLoginItemsSettings)
    }
}
