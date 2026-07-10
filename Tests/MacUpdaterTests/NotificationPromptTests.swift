import XCTest
@testable import MacUpdaterCore

/// M3(d) — the background agent used to call `requestAuthorization` the first time it had
/// something to say, so macOS threw its permission dialog at a user who had not asked for
/// anything and had no idea which app was talking. Wega explains itself first, in its own
/// window, and only asks the system once the user has agreed to be asked.
final class NotificationPromptTests: XCTestCase {
    func testAuthorizedUserJustGetsTheNotification() {
        XCTAssertEqual(
            NotificationPrompt.decide(system: .authorized, inApp: .unanswered),
            .post
        )
    }

    /// The system dialog can only ever be shown once. Spend it on a user who said yes.
    func testUndecidedUserSeesOurExplanationFirst() {
        XCTAssertEqual(
            NotificationPrompt.decide(system: .notDetermined, inApp: .unanswered),
            .explainInApp
        )
    }

    func testUndecidedUserWhoAgreedInAppGetsTheSystemDialog() {
        XCTAssertEqual(
            NotificationPrompt.decide(system: .notDetermined, inApp: .agreed),
            .askSystem
        )
    }

    /// Declining the card is an answer, and it sticks: no system dialog, and the card
    /// never comes back. Anything else is nagging.
    func testUserWhoDeclinedTheCardIsNeverAskedAgain() {
        XCTAssertEqual(
            NotificationPrompt.decide(system: .notDetermined, inApp: .declined),
            .stayQuiet
        )
    }

    /// "No" means no. Never re-ask, never nag, and never show the card again.
    func testDeniedUserIsLeftAlone() {
        XCTAssertEqual(
            NotificationPrompt.decide(system: .denied, inApp: .unanswered),
            .stayQuiet
        )
    }

    func testDeniedUserIsLeftAloneEvenAfterAgreeingInApp() {
        XCTAssertEqual(
            NotificationPrompt.decide(system: .denied, inApp: .agreed),
            .stayQuiet
        )
    }

    /// A background check must never be the thing that triggers a system dialog.
    func testOnlyTheSystemDialogDecisionIsAllowedToPrompt() {
        XCTAssertTrue(NotificationPrompt.Decision.askSystem.promptsTheSystem)
        XCTAssertFalse(NotificationPrompt.Decision.explainInApp.promptsTheSystem)
        XCTAssertFalse(NotificationPrompt.Decision.post.promptsTheSystem)
        XCTAssertFalse(NotificationPrompt.Decision.stayQuiet.promptsTheSystem)
    }
}
