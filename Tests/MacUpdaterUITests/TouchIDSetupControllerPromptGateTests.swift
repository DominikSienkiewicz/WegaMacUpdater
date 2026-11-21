import Foundation
@testable import MacUpdaterCore
import Testing

@testable import WegaMacUpdater

/// Owner decision 2026-11-21: what the Touch ID card reads, and what a helper reports, also close
/// Wega's own password prompts, so the card's recoveryOS note and the prompts never disagree.
@Suite("Touch ID — the card feeds the password prompt gate")
@MainActor
struct TouchIDSetupControllerPromptGateTests {
    private func controller(
        preflight: @escaping @Sendable () -> TouchIDDisablePreflight, gate: SudoPasswordPromptGate,
        disable: @escaping @MainActor @Sendable () async throws -> TouchIDSudoDisableResult = { .nothingToRemove }
    ) -> TouchIDSetupController {
        TouchIDSetupController(dependencies: .init(
            currentState: { .enabled }, helperIsEnabled: { true }, enableWithHelper: { .enabled },
            authorizeFallback: { .permissionDenied }, openInTerminal: { _ in },
            disableWithHelper: disable, disableAvailability: { .enabled }, preflight: preflight,
            promptGate: gate, logHelperCode: { _, _ in }
        ))
    }

    private static var unproven: TouchIDDisablePreflight {
        var preflight = TouchIDDisablePreflight.clear
        preflight.commandsAreSafe = false
        return preflight
    }

    @Test func theCardsLookIsTheGatesAnswer() {
        let gate = SudoPasswordPromptGate(readPreflight: { Issue.record("the card's look is recorded, not read again"); return .clear })
        let looks = LookQueue([Self.unproven, .clear])
        let controller = controller(preflight: { looks.next() }, gate: gate)
        #expect(gate.reason == .noProofOfSafety, "the look at launch")
        controller.refresh()
        #expect(gate.allowsPasswordPrompts, "Sprawdź ponownie")
    }

    @Test func aHelperReportClosesTheGateUntilAHelperCallSucceeds() async {
        let gate = SudoPasswordPromptGate(readPreflight: { .clear })
        let replies = DisableReplies([.refused(.notRegularFile), .nothingToRemove])
        let controller = controller(preflight: { .clear }, gate: gate, disable: { replies.next() })
        await controller.refreshDisableOffer()
        await controller.disable { _ in }
        #expect(gate.reason == .unsafePolicy(.notRegularFile))
        #expect(gate.helperReportedUnsafePolicy == .notRegularFile)

        let reopened = self.controller(preflight: { .clear }, gate: gate)
        #expect(reopened.recoveryOnlyReason == .unsafePolicy(.notRegularFile), "Settings opened again still knows")
        _ = controller
    }

    @Test func aSuccessfulHelperCallOpensItAgain() async {
        let gate = SudoPasswordPromptGate(readPreflight: { .clear })
        gate.helperReportedUnsafePolicy = .unsafeOwnership
        let controller = controller(preflight: { .clear }, gate: gate, disable: { .nothingToRemove })
        #expect(controller.recoveryOnlyReason == .unsafePolicy(.unsafeOwnership))
        // The button is hidden, but a helper call made before the report still answers here.
        await controller.disable { _ in }
        #expect(gate.helperReportedUnsafePolicy == nil)
        #expect(gate.allowsPasswordPrompts)
    }
}

private final class LookQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var looks: [TouchIDDisablePreflight]
    init(_ looks: [TouchIDDisablePreflight]) { self.looks = looks }
    func next() -> TouchIDDisablePreflight { lock.withLock { looks.count > 1 ? looks.removeFirst() : looks[0] } }
}

@MainActor
private final class DisableReplies {
    private var replies: [TouchIDSudoDisableResult]
    init(_ replies: [TouchIDSudoDisableResult]) { self.replies = replies }
    func next() -> TouchIDSudoDisableResult { replies.count > 1 ? replies.removeFirst() : replies[0] }
}
