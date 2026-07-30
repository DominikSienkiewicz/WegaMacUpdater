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
