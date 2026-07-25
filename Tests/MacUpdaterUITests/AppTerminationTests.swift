import AppKit
import XCTest
import MacUpdaterCore
@testable import WegaMacUpdater

/// REL-06 — the real `NSApplicationDelegate` answer to ⌘Q / log-out / shutdown.
///
/// `MutationGuardTests` owns the decision, `TerminationDuringMutationTests` owns the
/// wiring's shape; this exercises the delegate method itself. The two AppKit touch-points
/// are replaced: the alert would block on a run loop, and
/// `reply(toApplicationShouldTerminate:)` would talk to the test runner's own NSApplication.
final class AppTerminationTests: XCTestCase {

    @MainActor
    private func makeDelegate(
        answer: QuitDuringMutationChoice,
        onReply: @escaping @MainActor (Bool) -> Void
    ) -> AppDelegate {
        let delegate = AppDelegate()
        delegate.confirmQuitDuringMutation = { _ in answer }
        delegate.replyToTermination = onReply
        return delegate
    }

    @MainActor
    func testQuitIsImmediateWhenNothingIsMutating() {
        var replies: [Bool] = []
        let delegate = makeDelegate(answer: .quitAnyway) { replies.append($0) }

        XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateNow)
        XCTAssertTrue(replies.isEmpty, "An immediate quit needs no deferred reply")
    }

    /// The regression: this used to be an unconditional, instant process exit.
    @MainActor
    func testQuitIsDeferredWhileAMutationIsInFlight() {
        var replies: [Bool] = []
        let delegate = makeDelegate(answer: .waitForMutation) { replies.append($0) }
        let ticket = MutationGuard.shared.begin("test: aktualizacja")
        defer { MutationGuard.shared.end(ticket) }

        XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateLater)
        XCTAssertTrue(replies.isEmpty, "REL-06: the quit must not be granted while the mutation runs")
    }

    @MainActor
    func testWaitingForTheMutationGrantsTheQuitOnlyAfterItFinishes() async {
        let granted = expectation(description: "termination granted")
        var replies: [Bool] = []
        let delegate = makeDelegate(answer: .waitForMutation) {
            replies.append($0)
            granted.fulfill()
        }
        let ticket = MutationGuard.shared.begin("test: aktualizacja")

        XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateLater)
        XCTAssertTrue(replies.isEmpty)

        MutationGuard.shared.end(ticket)
        await fulfillment(of: [granted], timeout: 5)
        XCTAssertEqual(replies, [true])
    }

    /// "Anuluj" leaves the app running — and must still answer, or the log-out hangs.
    @MainActor
    func testCancellingTheQuitRepliesFalse() {
        var replies: [Bool] = []
        let delegate = makeDelegate(answer: .cancel) { replies.append($0) }
        let ticket = MutationGuard.shared.begin("test: aktualizacja")
        defer { MutationGuard.shared.end(ticket) }

        XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateLater)
        XCTAssertEqual(replies, [false])
    }

    /// "Zakończ mimo to" is the user's call, and it is granted immediately.
    @MainActor
    func testQuittingAnywayIsGrantedImmediately() {
        var replies: [Bool] = []
        let delegate = makeDelegate(answer: .quitAnyway) { replies.append($0) }
        let ticket = MutationGuard.shared.begin("test: aktualizacja")
        defer { MutationGuard.shared.end(ticket) }

        XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateLater)
        XCTAssertEqual(replies, [true])
    }
}
