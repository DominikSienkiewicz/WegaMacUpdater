import Foundation
import MacUpdaterCore
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
            enableWithHelper: { await calls.recordHelper() },
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
            enableWithHelper: {},
            authorizeFallback: { .cancelledByUser },
            openInTerminal: { _ in }
        ))
        await cancelled.enable { _ in }
        #expect(cancelled.state == .idle(.available))

        let failed = TouchIDSetupController(dependencies: .init(
            currentState: { .notSupported },
            helperIsEnabled: { false },
            enableWithHelper: {},
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
            enableWithHelper: {},
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
            enableWithHelper: {},
            authorizeFallback: { .cancelledByUser },
            openInTerminal: { command.value = $0 }
        ))

        controller.openManualFallback()
        #expect(command.value == TouchIDSudoConfigurator.manualEnableTerminalCommand)

        state.value = .enabled
        controller.refresh()
        #expect(controller.touchIDState == .enabled)
        #expect(!controller.isEnabling)
        #expect(!controller.wasPermissionDenied)
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
            enableWithHelper: {},
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
            currentState: { state.value }, helperIsEnabled: { true }, enableWithHelper: {},
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

private final class TouchIDCommandBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: String?

    var value: String? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
