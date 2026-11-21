import Foundation
import MacUpdaterCore
import Testing

@testable import WegaMacUpdater

/// Which `sudo` routes the Touch ID card may offer (RC2-6, RC2-7, Aneks E.6): the enable and disable
/// buttons of the helper and the two Terminal commands. An unsafe policy, seen by the app or reported
/// by the helper, an unsafe `/etc/pam.d/sudo` and a missing proof all close every one of them.
@Suite("Touch ID — which sudo routes the card offers", .serialized)
@MainActor
struct TouchIDSetupControllerGateTests {
    static let removable = TouchIDDisablePreflight(
        refusal: nil, unsafeLocalDirectory: nil, fallbackPath: nil, commandsAreSafe: true,
        removalPlan: .remove(lines: 1, contents: Data("# c\n".utf8)))

    private func controller(
        state: TouchIDSudoConfigurator.State, helper: GateBox<Bool> = GateBox(true),
        availability: HelperVerbAvailability = .enabled, preflight: TouchIDDisablePreflight,
        enable: @escaping @MainActor @Sendable () async throws -> TouchIDSudoEnableResult = { .enabled },
        disable: @escaping @MainActor @Sendable () async throws -> TouchIDSudoDisableResult = { .nothingToRemove }
    ) -> TouchIDSetupController {
        TouchIDSetupController(dependencies: .init(
            currentState: { state }, helperIsEnabled: { helper.value }, enableWithHelper: enable,
            authorizeFallback: { .permissionDenied }, openInTerminal: { _ in },
            disableWithHelper: disable, disableAvailability: { availability }, preflight: { preflight },
            logHelperCode: { _, _ in }
        ))
    }

    private func showsDisableCommand(
        state: TouchIDSudoConfigurator.State = .enabled, helper: Bool = false, availability: HelperVerbAvailability = .enabled,
        preflight: TouchIDDisablePreflight = removable
    ) async -> Bool {
        let controller = controller(state: state, helper: GateBox(helper), availability: availability, preflight: preflight)
        await controller.refreshDisableOffer()
        return controller.showsDisableCommand
    }

    /// E.6: Touch ID on, no helper that can do it, proof of safety, no later policy file, and the
    /// app's own read of `sudo_local` plans a removal.
    @Test func theDisableCommandNeedsEveryConditionOfE6() async {
        #expect(await showsDisableCommand(), "no helper")
        #expect(await showsDisableCommand(helper: true, availability: .off), "a helper that is not running")
        #expect(await showsDisableCommand(helper: true, availability: .stale), "an outdated helper")
        #expect(!(await showsDisableCommand(helper: true, availability: .enabled)), "a helper that can: its button, not sudo")
        #expect(!(await showsDisableCommand(state: .available)), "Touch ID is off")
        var preflight = Self.removable
        preflight.refusal = .unsafeOwnership
        preflight.commandsAreSafe = false
        #expect(!(await showsDisableCommand(preflight: preflight)), "−5 seen")
        preflight = Self.removable
        preflight.commandsAreSafe = false
        #expect(!(await showsDisableCommand(preflight: preflight)), "no proof")
        preflight = Self.removable
        preflight.sudoPolicyIsUnsafe = true
        #expect(!(await showsDisableCommand(preflight: preflight)), "/etc/pam.d/sudo unsafe")
        preflight = Self.removable
        preflight.fallbackPath = "/etc/pam.conf"
        #expect(!(await showsDisableCommand(preflight: preflight)), "a later policy file")
        for plan in [nil, TouchIDSudoDisablePlan.nothingToRemove, .refused(.otherDirectivesPresent), .refused(.tooLarge)] {
            preflight = Self.removable
            preflight.removalPlan = plan
            #expect(!(await showsDisableCommand(preflight: preflight)), "\(String(describing: plan))")
        }
    }

    /// RC2-7, group A concern 5: after the helper reports −4 or −5 while turning Touch ID off, its
    /// button goes too, and no command takes its place, until a helper call succeeds.
    @Test func aHelperReportedUnsafePolicyHidesTheDisableButtonAndTheCommand() async {
        let helper = GateBox(true)
        let controller = controller(state: .enabled, helper: helper, preflight: Self.removable, disable: { .refused(.unsafeOwnership) })
        await controller.refreshDisableOffer()
        #expect(controller.offersDisableButton && controller.recoveryOnlyReason == nil)

        await controller.disable { _ in }

        #expect(controller.disableOffer == .available, "the handshake still finds a helper")
        #expect(!controller.offersDisableButton && controller.recoveryOnlyReason == .unsafePolicy(.unsafeOwnership))
        helper.value = false
        await controller.refreshDisableOffer()
        #expect(controller.disableOffer == .helperMissing && !controller.showsDisableCommand)
    }

    /// RC2-6: a missing proof is treated like −5, in both directions.
    @Test func aMissingProofClosesEverySudoRoute() async {
        var unproven = Self.removable
        unproven.commandsAreSafe = false

        let off = controller(state: .available, preflight: unproven) {
            throw PrivilegedHelperClient.HelperError.versionMismatch(helper: "7", expected: "8…8")
        }
        #expect(off.recoveryOnlyReason == .noProofOfSafety && !off.offersEnableButton)
        await off.enable { _ in }
        #expect(off.wasPermissionDenied && !off.showsEnableCommand)

        let on = controller(state: .enabled, preflight: unproven)
        await on.refreshDisableOffer()
        #expect(on.disableOffer == .available && !on.offersDisableButton)
        #expect(!(await showsDisableCommand(preflight: unproven)))
    }

    @Test func anUnsafeSudoFileClosesEverySudoRoute() async {
        var preflight = Self.removable
        preflight.sudoPolicyIsUnsafe = true
        preflight.commandsAreSafe = false

        let off = controller(state: .available, preflight: preflight) { throw PrivilegedHelperClient.HelperError.connectionFailed }
        #expect(off.recoveryOnlyReason == .unsafeSudoFile && !off.offersEnableButton)
        await off.enable { _ in }
        #expect(off.wasPermissionDenied && !off.showsEnableCommand)
        let on = controller(state: .enabled, preflight: preflight)
        await on.refreshDisableOffer()
        #expect(!on.offersDisableButton)
    }

    /// What was seen comes before what is missing, so the card names the real problem.
    @Test func theReasonNamesWhatWasSeenFirst() {
        var preflight = TouchIDDisablePreflight(refusal: .notRegularFile, unsafeLocalDirectory: nil, fallbackPath: nil)
        preflight.sudoPolicyIsUnsafe = true
        #expect(controller(state: .available, preflight: preflight).recoveryOnlyReason == .unsafePolicy(.notRegularFile))
        preflight.refusal = nil
        #expect(controller(state: .available, preflight: preflight).recoveryOnlyReason == .unsafeSudoFile)
        #expect(controller(state: .available, preflight: .clear).recoveryOnlyReason == nil)
        #expect(controller(state: .available, preflight: .clear).offersEnableButton)
        #expect(controller(state: .enabled, preflight: .clear).offersDisableButton == false, "no offer worked out yet")
    }
}

final class GateBox<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) { stored = value }

    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
