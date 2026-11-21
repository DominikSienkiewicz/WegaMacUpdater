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

    /// I1: with no `sudo_local`, a template that is not root's alone, or that the app could not look
    /// at, hides the enable command after the helper could not do it, and the card says recoveryOS.
    @Test func anUnsafeTemplateHidesTheEnableCommand() async {
        func preflight(template: PAMPolicyFileFacts?) -> TouchIDDisablePreflight {
            let file = PAMPolicyFileFacts(
                isRegularFile: true, identity: PAMFileIdentity(device: 1, inode: 2), linkCount: 1, ownerUID: 0, groupID: 0,
                permissions: 0o444, accessControl: .absent, size: 40, modifiedNanoseconds: 0)
            return TouchIDDisablePreflight.evaluate(.init(
                policyDirectory: .found(PAMPolicyDirectoryFacts(isDirectory: true, ownerUID: 0, permissions: 0o755, accessControl: .absent)),
                sudoLocal: .missing, sudoPolicy: .found(file), template: template.map { .found($0) } ?? .unknown,
                localDirectories: [], existingFallbackPaths: []))
        }
        var writable = PAMPolicyFileFacts(
            isRegularFile: true, identity: PAMFileIdentity(device: 1, inode: 3), linkCount: 1, ownerUID: 0, groupID: 0,
            permissions: 0o666, accessControl: .absent, size: 40, modifiedNanoseconds: 0)
        for (name, unsafe) in [("0666", preflight(template: writable)), ("not looked at", preflight(template: nil))] {
            let off = controller(state: .available, helper: GateBox(false), preflight: unsafe)
            await off.enable { _ in }
            #expect(off.wasPermissionDenied && !off.showsEnableCommand, "\(name)")
            #expect(off.recoveryOnlyReason == .noProofOfSafety, "\(name)")
        }
        writable.permissions = 0o444
        let safe = controller(state: .available, helper: GateBox(false), preflight: preflight(template: writable))
        await safe.enable { _ in }
        #expect(safe.showsEnableCommand, "Apple's root:wheel 0444 template")
    }

    /// M6: the enable command rests on a preflight read when the helper could not do it, not on the
    /// card's last look. The policy turns unproven between that look and the click, on the path
    /// without a helper and on the outdated-helper path, and no command or Terminal line appears.
    @Test func theEnableCommandRestsOnAFreshPreflight() async {
        var unproven = TouchIDDisablePreflight.clear
        unproven.commandsAreSafe = false
        struct Path {
            let name: String
            let helperIsEnabled: Bool
            let enable: @MainActor @Sendable () async throws -> TouchIDSudoEnableResult
        }
        let paths = [
            Path(name: "no helper", helperIsEnabled: false, enable: { .enabled }),
            Path(name: "an outdated helper", helperIsEnabled: true,
                 enable: { throw PrivilegedHelperClient.HelperError.versionMismatch(helper: "7", expected: "8…8") }),
        ]
        for path in paths {
            let name = path.name, helperIsEnabled = path.helperIsEnabled
            let observed = GateBox(TouchIDDisablePreflight.clear)
            let controller = TouchIDSetupController(dependencies: .init(
                currentState: { .available }, helperIsEnabled: { helperIsEnabled }, enableWithHelper: path.enable,
                authorizeFallback: { .permissionDenied }, openInTerminal: { _ in }, preflight: { observed.value },
                logHelperCode: { _, _ in }
            ))
            #expect(controller.offersEnableButton, "\(name): the card's look was safe")
            observed.value = unproven
            var lines: [String] = []

            await controller.enable { lines.append($0.line) }

            #expect(controller.wasPermissionDenied, "\(name)")
            #expect(!controller.showsEnableCommand && controller.recoveryOnlyReason == .noProofOfSafety, "\(name)")
            #expect(!lines.contains(tr("macOS zablokował zapis — wklej komendę do Terminala.")), "\(name): \(lines)")
        }
    }

    /// M3: "wklej komendę do Terminala" only when the card shows the command. Here the policy turns
    /// unsafe while the helper does not answer, so no command is shown and no line points at one.
    @Test func theTerminalLinePointsAtACommandOnlyWhenOneIsShown() async {
        let observed = GateBox(TouchIDDisablePreflight.clear)
        let racing = TouchIDSetupController(dependencies: .init(
            currentState: { .available }, helperIsEnabled: { true },
            enableWithHelper: {
                observed.value = TouchIDDisablePreflight(refusal: .unsafeOwnership, unsafeLocalDirectory: nil, fallbackPath: nil)
                throw PrivilegedHelperClient.HelperError.connectionFailed
            },
            authorizeFallback: { .permissionDenied }, openInTerminal: { _ in }, preflight: { observed.value },
            logHelperCode: { _, _ in }
        ))
        var lines: [String] = []
        await racing.enable { lines.append($0.line) }
        #expect(racing.wasPermissionDenied && !racing.showsEnableCommand)
        #expect(lines.isEmpty, "the card's recoveryOS note is the whole message: \(lines)")

        let shown = controller(state: .available, preflight: .clear) { throw PrivilegedHelperClient.HelperError.connectionFailed }
        var shownLines: [String] = []
        await shown.enable { shownLines.append($0.line) }
        #expect(shown.showsEnableCommand && shownLines == [tr("macOS zablokował zapis — wklej komendę do Terminala.")])
    }

    /// RC2-8: "Otwórz w Terminalu" opens the command it is handed, never a fixed one. Together with
    /// the card pins (`TouchIDCardPinTests`), the disable card's button opens the disable command.
    @Test func theTerminalOpensTheCommandItIsHanded() {
        let opened = GateBox<[TouchIDManualCommand]>([])
        let controller = TouchIDSetupController(dependencies: .init(
            currentState: { .enabled }, helperIsEnabled: { false }, enableWithHelper: { .enabled },
            authorizeFallback: { .permissionDenied }, openInTerminal: { command in opened.value.append(command) }
        ))
        controller.openInTerminal(.disable)
        controller.openInTerminal(.enable)
        #expect(opened.value == [.disable, .enable])
        #expect(TouchIDManualCommand.disable.text == TouchIDSudoConfigurator.manualDisableTerminalCommand)
        #expect(TouchIDManualCommand.enable.text == TouchIDSudoConfigurator.manualEnableTerminalCommand)
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
