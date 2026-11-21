import Foundation
@testable import MacUpdaterCore
import Testing

@testable import WegaMacUpdater

@Suite("Touch ID setup controller coverage", .serialized)
@MainActor
struct TouchIDSetupControllerCoverageTests {
    private struct TestFailure: Error {}

    @Test func enabledHelperCompletesWithoutCallingFallback() async {
        let calls = TouchIDCallRecorder()
        let controller = TouchIDSetupController(dependencies: .init(
            currentState: { .enabled },
            helperIsEnabled: { true },
            enableWithHelper: {
                await calls.recordHelper()
                return .enabled
            },
            authorizeFallback: {
                await calls.recordFallback()
                return .otherError("fallback must not run")
            },
            openInTerminal: { _ in }
        ))
        var states: [WegaState] = []

        await controller.enable { states.append($0) }

        #expect(await calls.helperCalls == 1)
        #expect(await calls.fallbackCalls == 0)
        #expect(controller.state == .idle(.enabled))
        #expect(states.last?.pose == .happy)
    }

    @Test func helperFailureFallsBackAndASuccessfulFallbackRefreshesState() async {
        let state = TouchIDStateBox(.available)
        let calls = TouchIDCallRecorder()
        let controller = TouchIDSetupController(dependencies: .init(
            currentState: { state.value },
            helperIsEnabled: { true },
            enableWithHelper: { throw TestFailure() },
            authorizeFallback: {
                await calls.recordFallback()
                state.value = .enabled
                return .success
            },
            openInTerminal: { _ in }
        ))

        await controller.enable { _ in }

        #expect(await calls.fallbackCalls == 1)
        #expect(controller.state == .idle(.enabled))
        #expect(controller.errorMessage == nil)
    }

    @Test func cancellationAndOtherErrorsBecomeStableStates() async {
        let cancelled = TouchIDSetupController(dependencies: .init(
            currentState: { .available },
            helperIsEnabled: { false },
            enableWithHelper: { .enabled },
            authorizeFallback: { .cancelledByUser },
            openInTerminal: { _ in }
        ))
        await cancelled.enable { _ in }
        #expect(cancelled.state == .idle(.available))

        let failed = TouchIDSetupController(dependencies: .init(
            currentState: { .notSupported },
            helperIsEnabled: { false },
            enableWithHelper: { .enabled },
            authorizeFallback: { .otherError("authorization failed") },
            openInTerminal: { _ in }
        ))
        await failed.enable { _ in }
        #expect(failed.state == .failed(.notSupported, "authorization failed"))
        #expect(failed.errorMessage == "authorization failed")
    }

    @Test func aSecondEnableRequestIsIgnoredWhileAuthorizationIsInFlight() async {
        let latch = TouchIDAuthorizationLatch()
        let calls = TouchIDCallRecorder()
        let controller = TouchIDSetupController(dependencies: .init(
            currentState: { .available },
            helperIsEnabled: { false },
            enableWithHelper: { .enabled },
            authorizeFallback: {
                await calls.recordFallback()
                await latch.block()
                return .cancelledByUser
            },
            openInTerminal: { _ in }
        ))

        let first = Task { @MainActor in await controller.enable { _ in } }
        await latch.waitUntilBlocked()
        await controller.enable { _ in }
        #expect(await calls.fallbackCalls == 1)

        await latch.release()
        await first.value
        #expect(controller.state == .idle(.available))
    }

    @Test func manualFallbackAndRefreshUseInjectedDependencies() {
        let command = TouchIDCommandBox()
        let state = TouchIDStateBox(.available)
        let controller = TouchIDSetupController(dependencies: .init(
            currentState: { state.value },
            helperIsEnabled: { false },
            enableWithHelper: { .enabled },
            authorizeFallback: { .cancelledByUser },
            openInTerminal: { command.value = $0 }
        ))

        controller.openInTerminal(.enable)
        #expect(command.value == .enable)
        #expect(command.value?.text == TouchIDSudoConfigurator.manualEnableTerminalCommand)

        state.value = .enabled
        controller.refresh()
        #expect(controller.touchIDState == .enabled)
        #expect(!controller.isEnabling)
        #expect(!controller.wasPermissionDenied)
    }

    // MARK: - Turning Touch ID on through the helper (Aneks E.3, E.9)

    private func enablingController(
        state: TouchIDStateBox, preflight: TouchIDDisablePreflight = .clear, calls: TouchIDCallRecorder,
        logged: TouchIDLogBox = TouchIDLogBox(),
        enable: @escaping @MainActor @Sendable () async throws -> TouchIDSudoEnableResult
    ) -> TouchIDSetupController {
        TouchIDSetupController(dependencies: .init(
            currentState: { state.value },
            helperIsEnabled: { true },
            enableWithHelper: {
                await calls.recordHelper()
                return try await enable()
            },
            authorizeFallback: {
                await calls.recordFallback()
                return .permissionDenied
            },
            openInTerminal: { _ in },
            preflight: { preflight },
            logHelperCode: { verb, code in logged.append(verb, code) }
        ))
    }

    @Test func aHelperSuccessIsConfirmedByReadingTheFileAgain() async {
        let state = TouchIDStateBox(.available)
        let calls = TouchIDCallRecorder()
        let controller = enablingController(state: state, calls: calls) {
            state.value = .enabled
            return .enabled
        }
        var states: [WegaState] = []
        await controller.enable { states.append($0) }
        #expect(controller.state == .idle(.enabled))
        #expect(states.last == WegaState(pose: .happy, line: TouchIDEnableCopy.line(for: .enabled, isEnabled: true)))
        #expect(await calls.fallbackCalls == 0)
    }

    /// RC2-2: the helper's word alone is not a success; the file read again must say so.
    @Test func aSuccessTheFileDoesNotConfirmIsNotClaimed() async {
        for result in [TouchIDSudoEnableResult.enabled, .alreadyEnabled] {
            let calls = TouchIDCallRecorder()
            let controller = enablingController(state: TouchIDStateBox(.available), calls: calls) { result }
            var states: [WegaState] = []
            await controller.enable { states.append($0) }
            #expect(states.last == WegaState(pose: .idle, line: TouchIDEnableCopy.line(for: result, isEnabled: false)), "\(result)")
            #expect(controller.state == .idle(.available) && !controller.showsEnableCommand, "\(result)")
            #expect(await calls.fallbackCalls == 0, "\(result)")
        }
    }

    /// Review focus 3, [O14]: a refusal never falls into the Terminal command, which needs sudo too.
    @Test func aCallerRefusalShowsNoCommand() async {
        for refusal in [TouchIDSudoEnableRefusal.noConsoleUser, .callerNotConsoleUser, .callerNotAdministrator] {
            let calls = TouchIDCallRecorder()
            let controller = enablingController(state: TouchIDStateBox(.available), calls: calls) { .refused(refusal) }
            var states: [WegaState] = []
            await controller.enable { states.append($0) }
            #expect(!controller.wasPermissionDenied && !controller.showsEnableCommand, "\(refusal)")
            #expect(states.last?.line == TouchIDEnableCopy.line(for: .refused(refusal), isEnabled: false), "\(refusal)")
            #expect(controller.state == .idle(.available), "\(refusal)")
            #expect(await calls.fallbackCalls == 0, "\(refusal)")
        }
    }

    @Test func everyOtherHelperRefusalOrFailureShowsItsLineAndNoCommand() async {
        let backup = "/etc/pam.d/.sudo_local.wega-backup-0A1B"
        let results: [TouchIDSudoEnableResult] = TouchIDSudoEnableRefusal.allCases.map { .refused($0) }
            + [.restoredAfterFailure, .rollbackFailed(backupPath: backup), .rollbackFailed(backupPath: nil)]
        for result in results {
            let calls = TouchIDCallRecorder()
            let controller = enablingController(state: TouchIDStateBox(.available), calls: calls) { result }
            var states: [WegaState] = []
            await controller.enable { states.append($0) }
            let line = TouchIDEnableCopy.line(for: result, isEnabled: false)
            #expect(states.last == WegaState(pose: .idle, line: line), "\(result)")
            #expect(!controller.wasPermissionDenied && !controller.showsEnableCommand, "\(result)")
            #expect(await calls.fallbackCalls == 0, "\(result)")
            if case .rollbackFailed = result {
                #expect(controller.state == .failed(.available, line), "\(result): the card keeps it in red")
            } else {
                #expect(controller.state == .idle(.available), "\(result)")
            }
        }
    }

    /// Review focus 2: right after the app update the helper is still v7, which the handshake
    /// refuses for this verb; the card says so and offers the Terminal command.
    @Test func anOutdatedHelperOffersTheManualEnableCommand() async {
        let calls = TouchIDCallRecorder()
        let controller = enablingController(state: TouchIDStateBox(.available), calls: calls) {
            throw PrivilegedHelperClient.HelperError.versionMismatch(helper: "7", expected: "8…8")
        }
        var states: [WegaState] = []
        await controller.enable { states.append($0) }
        #expect(controller.wasPermissionDenied && controller.showsEnableCommand)
        #expect(controller.enableHelperOutdated)
        #expect(states.last == WegaState(pose: .idle, line: TouchIDEnableCopy.outdatedHelper))
        #expect(await calls.fallbackCalls == 0)

        controller.refresh()
        #expect(!controller.showsEnableCommand)
        let unsafe = enablingController(
            state: TouchIDStateBox(.available),
            preflight: TouchIDDisablePreflight(refusal: .unsafeOwnership, unsafeLocalDirectory: nil, fallbackPath: nil),
            calls: TouchIDCallRecorder()
        ) { throw PrivilegedHelperClient.HelperError.versionMismatch(helper: "7", expected: "8…8") }
        await unsafe.enable { _ in }
        #expect(!unsafe.showsEnableCommand, "no sudo command while the app sees an unsafe policy")
    }

    /// Z13: no answer does not mean nothing changed; the helper may have finished under its lock.
    @Test func aTransportErrorAfterWhichTheFileIsEnabledIsASuccess() async {
        let state = TouchIDStateBox(.available)
        let calls = TouchIDCallRecorder()
        let controller = enablingController(state: state, calls: calls) {
            state.value = .enabled
            throw PrivilegedHelperClient.HelperError.timedOut
        }
        var states: [WegaState] = []
        await controller.enable { states.append($0) }
        #expect(controller.state == .idle(.enabled))
        #expect(states.last == WegaState(pose: .happy, line: TouchIDEnableCopy.line(for: .enabled, isEnabled: true)))
        #expect(await calls.fallbackCalls == 0)
    }

    @Test func aTransportErrorWithTouchIDStillOffOffersTheManualCommand() async {
        let calls = TouchIDCallRecorder()
        let controller = enablingController(state: TouchIDStateBox(.available), calls: calls) {
            throw PrivilegedHelperClient.HelperError.connectionFailed
        }
        await controller.enable { _ in }
        #expect(await calls.fallbackCalls == 1)
        #expect(controller.wasPermissionDenied && controller.showsEnableCommand)
        #expect(!controller.enableHelperOutdated)
    }

    /// The app logs the helper's code for a refusal or a failure, never the backup path or a byte of
    /// the file, in both directions.
    @Test func refusalCodesAreLoggedWithoutTheirDetail() async {
        let logged = TouchIDLogBox()
        let state = TouchIDStateBox(.available)
        let failing = enablingController(state: state, calls: TouchIDCallRecorder(), logged: logged) {
            .rollbackFailed(backupPath: "/etc/pam.d/.sudo_local.wega-backup-0A1B")
        }
        await failing.enable { _ in }
        let succeeding = enablingController(state: state, calls: TouchIDCallRecorder(), logged: logged) { .enabled }
        await succeeding.enable { _ in }
        #expect(logged.entries == [TouchIDLogBox.Entry(verb: .enableTouchIDForSudo, code: -21)])

        let disabling = TouchIDSetupController(dependencies: .init(
            currentState: { .enabled }, helperIsEnabled: { true }, enableWithHelper: { .enabled },
            authorizeFallback: { .cancelledByUser }, openInTerminal: { _ in },
            disableWithHelper: { .refused(.unsafeOwnership) },
            logHelperCode: { verb, code in logged.append(verb, code) }
        ))
        await disabling.disable { _ in }
        #expect(logged.entries.last == TouchIDLogBox.Entry(verb: .disableTouchIDForSudo, code: -5))
        #expect(logged.entries.count == 2)
    }

    // MARK: - An unsafe policy the helper saw (RC2-7)

    private func stickyController(
        state: TouchIDStateBox, preflight: TouchIDDisablePreflight = .clear,
        enable: TouchIDReplyQueue<TouchIDSudoEnableResult> = TouchIDReplyQueue([]),
        disable: TouchIDReplyQueue<TouchIDSudoDisableResult> = TouchIDReplyQueue([])
    ) -> TouchIDSetupController {
        TouchIDSetupController(dependencies: .init(
            currentState: { state.value }, helperIsEnabled: { true },
            enableWithHelper: { try enable.next() },
            authorizeFallback: { .permissionDenied }, openInTerminal: { _ in },
            disableWithHelper: { try disable.next() },
            preflight: { preflight },
            logHelperCode: { _, _ in }
        ))
    }

    /// Root may see an ACL the user cannot: after the helper reports −5, a later transport error
    /// must not bring back the `sudo` command, until a helper call succeeds.
    @Test func aHelperReportedUnsafePolicyStaysUntilAHelperCallSucceeds() async {
        let state = TouchIDStateBox(.available)
        let replies = TouchIDReplyQueue<TouchIDSudoEnableResult>([
            .success(.refused(.unsafeOwnership)), .failure(PrivilegedHelperClient.HelperError.connectionFailed),
            .success(.refused(.callerNotAdministrator)), .success(.enabled),
        ])
        let controller = stickyController(state: state, enable: replies)

        await controller.enable { _ in }
        #expect(controller.helperObservedUnsafePolicy && controller.unsafePolicy == .unsafeOwnership)
        #expect(!controller.offersEnableButton)

        await controller.enable { _ in }
        #expect(controller.wasPermissionDenied && !controller.showsEnableCommand, "no sudo command after a helper −5")
        controller.refresh()
        #expect(controller.helperObservedUnsafePolicy, "reading the file again does not clear what root saw")

        await controller.enable { _ in }
        #expect(controller.helperObservedUnsafePolicy, "a refusal is not a success")

        state.value = .enabled
        await controller.enable { _ in }
        #expect(!controller.helperObservedUnsafePolicy && controller.unsafePolicy == nil)
    }

    @Test func aMinus4FromTheHelperIsRememberedAndAnyEnableSuccessClearsIt() async {
        let replies = TouchIDReplyQueue<TouchIDSudoEnableResult>([.success(.refused(.notRegularFile)), .success(.alreadyEnabled)])
        let controller = stickyController(state: TouchIDStateBox(.available), enable: replies)
        await controller.enable { _ in }
        #expect(controller.unsafePolicy == .notRegularFile)
        await controller.enable { _ in }
        #expect(!controller.helperObservedUnsafePolicy, "the helper's success clears it, whatever the file says")
    }

    @Test func anUnsafePolicyReportedWhileTurningOffIsRememberedToo() async {
        let replies = TouchIDReplyQueue<TouchIDSudoDisableResult>([
            .success(.refused(.notRegularFile)), .success(.nothingToRemove), .success(.refused(.unsafeOwnership)),
            .success(.refused(.otherDirectivesPresent)), .success(.removed(lines: 1)),
        ])
        let controller = stickyController(state: TouchIDStateBox(.enabled), disable: replies)
        await controller.disable { _ in }
        #expect(controller.unsafePolicy == .notRegularFile)
        await controller.disable { _ in }
        #expect(!controller.helperObservedUnsafePolicy)
        await controller.disable { _ in }
        #expect(controller.unsafePolicy == .unsafeOwnership)
        await controller.disable { _ in }
        #expect(controller.helperObservedUnsafePolicy, "another refusal is not a success")
        await controller.disable { _ in }
        #expect(!controller.helperObservedUnsafePolicy)
    }

    /// Review focus 5: a symlinked or group-writable `sudo_local`, seen by the app or reported by the
    /// helper, leaves neither the helper's enable button nor the Terminal command.
    @Test func anUnsafePolicyHidesEveryCommandAndButton() async {
        for refusal in [TouchIDSudoDisableRefusal.unsafeOwnership, .notRegularFile] {
            let preflight = TouchIDDisablePreflight(refusal: refusal, unsafeLocalDirectory: nil, fallbackPath: nil)
            let replies = TouchIDReplyQueue<TouchIDSudoEnableResult>([.failure(PrivilegedHelperClient.HelperError.connectionFailed)])
            let controller = stickyController(state: TouchIDStateBox(.available), preflight: preflight, enable: replies)
            #expect(controller.unsafePolicy == refusal && !controller.offersEnableButton, "\(refusal)")
            await controller.enable { _ in }
            #expect(controller.wasPermissionDenied && !controller.showsEnableCommand, "\(refusal)")
        }
        let clear = stickyController(state: TouchIDStateBox(.available))
        #expect(clear.unsafePolicy == nil && clear.offersEnableButton)
        #expect(!stickyController(state: TouchIDStateBox(.enabled)).offersEnableButton, "Touch ID is already on")
    }

    // MARK: - Turning Touch ID off

    private func disablingController(
        state: TouchIDStateBox, helper: Bool = true, availability: HelperVerbAvailability = .enabled,
        preflight: TouchIDDisablePreflight = .clear, calls: TouchIDCallRecorder,
        disable: @escaping @MainActor @Sendable () async throws -> TouchIDSudoDisableResult
    ) -> TouchIDSetupController {
        TouchIDSetupController(dependencies: .init(
            currentState: { state.value },
            helperIsEnabled: { helper },
            enableWithHelper: { .enabled },
            authorizeFallback: { .cancelledByUser },
            openInTerminal: { _ in },
            disableWithHelper: {
                await calls.recordHelper()
                return try await disable()
            },
            disableAvailability: { availability },
            preflight: { preflight }
        ))
    }

    @Test func disablingThroughTheHelperReadsTheFileAgainAndSaysSo() async {
        let state = TouchIDStateBox(.enabled)
        let calls = TouchIDCallRecorder()
        let controller = disablingController(state: state, calls: calls) {
            state.value = .available
            return .removed(lines: 1)
        }
        var states: [WegaState] = []

        await controller.disable { states.append($0) }

        #expect(await calls.helperCalls == 1)
        #expect(controller.state == .idle(.available))
        #expect(states.last?.line == TouchIDDisableCopy.line(for: .removed(lines: 1), stillEnabled: false))
        #expect(states.last?.pose == .idle)
    }

    @Test func aSuccessAddsTheLocalDirectoryWarning() async {
        let state = TouchIDStateBox(.enabled)
        let preflight = TouchIDDisablePreflight(refusal: nil, unsafeLocalDirectory: "/usr/local/etc", fallbackPath: nil)
        let controller = disablingController(state: state, preflight: preflight, calls: TouchIDCallRecorder()) {
            state.value = .available
            return .removed(lines: 1)
        }
        var states: [WegaState] = []
        await controller.disable { states.append($0) }
        let line = TouchIDDisableCopy.line(for: .removed(lines: 1), stillEnabled: false)
            + " " + TouchIDDisableCopy.localDirectoryWarning(path: "/usr/local/etc")
        #expect(states.last?.line == line)
    }

    @Test func aHelperErrorDoesNotClaimNothingChanged() async {
        let state = TouchIDStateBox(.enabled)
        let controller = disablingController(state: state, calls: TouchIDCallRecorder()) { throw TestFailure() }
        var states: [WegaState] = []

        await controller.disable { states.append($0) }

        #expect(states.last?.line == TouchIDDisableCopy.afterHelperError(stillEnabled: true))
        #expect(controller.state == .idle(.enabled))
    }

    @Test func aVersionMismatchRaceShowsTheOutdatedHelperText() async {
        let state = TouchIDStateBox(.enabled)
        let controller = disablingController(state: state, calls: TouchIDCallRecorder()) {
            throw PrivilegedHelperClient.HelperError.versionMismatch(helper: "6", expected: "7")
        }
        var states: [WegaState] = []
        await controller.disable { states.append($0) }
        #expect(states.last?.line == TouchIDDisableCopy.outdatedHelper)
        #expect(controller.disableOffer == .helperOutdated)
    }

    @Test func aFailedRestoreShowsAsAnErrorWithTheBackupsPath() async {
        let state = TouchIDStateBox(.enabled)
        let controller = disablingController(state: state, calls: TouchIDCallRecorder()) {
            .rollbackFailed(backupPath: "/etc/pam.d/.sudo_local.wega-x")
        }
        await controller.disable { _ in }
        #expect(controller.errorMessage?.contains("/etc/pam.d/.sudo_local.wega-x") == true)
        #expect(controller.touchIDState == .enabled)
    }

    @Test func aRefusalNamesTheLaterPolicyFileTheAppSaw() async {
        let state = TouchIDStateBox(.enabled)
        let preflight = TouchIDDisablePreflight(refusal: nil, unsafeLocalDirectory: nil, fallbackPath: "/usr/share/pam.d/sudo_local")
        let controller = disablingController(state: state, preflight: preflight, calls: TouchIDCallRecorder()) {
            .refused(.fallbackPolicyPresent)
        }
        var states: [WegaState] = []
        await controller.disable { states.append($0) }
        #expect(states.last?.line == TouchIDDisableCopy.line(for: .refused(.fallbackPolicyPresent), stillEnabled: true, fallbackPath: "/usr/share/pam.d/sudo_local"))
    }

    @Test func withoutTheHelperNothingIsAsked() async {
        let calls = TouchIDCallRecorder()
        let controller = disablingController(state: TouchIDStateBox(.enabled), helper: false, calls: calls) { .nothingToRemove }
        await controller.disable { _ in }
        #expect(await calls.helperCalls == 0)
        #expect(controller.state == .idle(.enabled))
    }

    @Test func aStaleHelperIsNotAskedAndTheCardSaysSo() async {
        let calls = TouchIDCallRecorder()
        let controller = disablingController(state: TouchIDStateBox(.enabled), availability: .stale, calls: calls) { .nothingToRemove }
        var states: [WegaState] = []

        await controller.refreshDisableOffer()
        #expect(controller.disableOffer == .helperOutdated)
        await controller.disable { states.append($0) }

        #expect(await calls.helperCalls == 0)
        #expect(states.last?.line == TouchIDDisableCopy.outdatedHelper)
        #expect(controller.state == .idle(.enabled))
    }

    @Test func theOfferFollowsWhatTheAppObserved() async {
        let state = TouchIDStateBox(.enabled)
        let calls = TouchIDCallRecorder()
        let offer = { (helper: Bool, availability: HelperVerbAvailability, refusal: TouchIDSudoDisableRefusal?) async -> TouchIDSetupController.DisableOffer in
            let controller = self.disablingController(
                state: state, helper: helper, availability: availability,
                preflight: TouchIDDisablePreflight(refusal: refusal, unsafeLocalDirectory: nil, fallbackPath: nil), calls: calls
            ) { .nothingToRemove }
            await controller.refreshDisableOffer()
            return controller.disableOffer
        }
        #expect(await offer(true, .enabled, nil) == .available)
        #expect(await offer(true, .off, nil) == .helperMissing)
        #expect(await offer(false, .enabled, nil) == .helperMissing)
        #expect(await offer(true, .stale, nil) == .helperOutdated)
        #expect(await offer(true, .enabled, .unsafeOwnership) == .blocked(.unsafeOwnership), "no button for an unsafe file, and no handshake needed")
        #expect(await calls.helperCalls == 0)
    }

    /// After the helper answers, the offer is worked out again from the file read afterwards, so a
    /// refusal the app can now see, or a Touch ID already off, does not leave the button up.
    @Test func theOfferIsWorkedOutAgainAfterTheHelperAnswers() async {
        let state = TouchIDStateBox(.enabled)
        let observed = TouchIDPreflightBox(.clear)
        let refusing = TouchIDSetupController(dependencies: .init(
            currentState: { state.value }, helperIsEnabled: { true }, enableWithHelper: { .enabled },
            authorizeFallback: { .cancelledByUser }, openInTerminal: { _ in },
            disableWithHelper: {
                observed.value = TouchIDDisablePreflight(refusal: .unsafeOwnership, unsafeLocalDirectory: nil, fallbackPath: nil)
                return .refused(.unsafeOwnership)
            },
            disableAvailability: { .enabled },
            preflight: { observed.value }
        ))
        await refusing.refreshDisableOffer()
        #expect(refusing.disableOffer == .available)
        await refusing.disable { _ in }
        #expect(refusing.disableOffer == .blocked(.unsafeOwnership), "no button again for a refusal the app now sees")

        let removing = disablingController(state: state, calls: TouchIDCallRecorder()) {
            state.value = .available
            return .removed(lines: 1)
        }
        await removing.refreshDisableOffer()
        #expect(removing.disableOffer == .available)
        await removing.disable { _ in }
        #expect(removing.disableOffer == .unknown, "Touch ID is off, so there is nothing to turn off")
    }

    @Test func twoDisableRequestsDoNotOverlap() async {
        let state = TouchIDStateBox(.enabled)
        let latch = TouchIDAuthorizationLatch()
        let calls = TouchIDCallRecorder()
        let controller = disablingController(state: state, calls: calls) {
            await latch.block()
            return .nothingToRemove
        }
        let first = Task { @MainActor in await controller.disable { _ in } }
        await latch.waitUntilBlocked()
        #expect(controller.isDisabling)
        await controller.disable { _ in }
        #expect(await calls.helperCalls == 1)
        await latch.release()
        await first.value
        #expect(!controller.isDisabling)
    }
}

private actor TouchIDCallRecorder {
    private(set) var helperCalls = 0
    private(set) var fallbackCalls = 0

    func recordHelper() { helperCalls += 1 }
    func recordFallback() { fallbackCalls += 1 }
}

private actor TouchIDAuthorizationLatch {
    private var blocked = false
    private var released = false
    private var blockedWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func block() async {
        blocked = true
        blockedWaiters.forEach { $0.resume() }
        blockedWaiters.removeAll()
        guard !released else { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func waitUntilBlocked() async {
        guard !blocked else { return }
        await withCheckedContinuation { blockedWaiters.append($0) }
    }

    func release() {
        released = true
        releaseWaiters.forEach { $0.resume() }
        releaseWaiters.removeAll()
    }
}

private final class TouchIDPreflightBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: TouchIDDisablePreflight

    init(_ value: TouchIDDisablePreflight) { stored = value }

    var value: TouchIDDisablePreflight {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

private final class TouchIDStateBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: TouchIDSudoConfigurator.State

    init(_ value: TouchIDSudoConfigurator.State) { stored = value }

    var value: TouchIDSudoConfigurator.State {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

/// The helper's replies, in order, one per call.
private final class TouchIDReplyQueue<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var replies: [Result<Value, any Error>]

    init(_ replies: [Result<Value, any Error>]) { self.replies = replies }

    func next() throws -> Value {
        try lock.withLock { replies.removeFirst() }.get()
    }
}

private final class TouchIDLogBox: @unchecked Sendable {
    struct Entry: Equatable {
        let verb: WegaHelperVerb
        let code: Int
    }

    private let lock = NSLock()
    private var stored: [Entry] = []

    var entries: [Entry] { lock.withLock { stored } }

    func append(_ verb: WegaHelperVerb, _ code: Int) {
        lock.withLock { stored.append(Entry(verb: verb, code: code)) }
    }
}

private final class TouchIDCommandBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: TouchIDManualCommand?

    var value: TouchIDManualCommand? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
