import Testing
import MacUpdaterCore
@testable import WegaMacUpdater

@Suite("Info operations controller runtime coverage")
@MainActor
struct InfoOperationsControllerCoverageTests {
    @Test func persistentStateAndCredentialActionsUseTheirInjectedBoundaries() {
        let harness = Harness()
        harness.helperStatus = .enabled
        harness.hasToken = true
        let controller = InfoOperationsController(dependencies: dependencies(harness))

        controller.refreshPersistentState()
        controller.saveGitHubToken("secret")
        controller.clearGitHubToken()
        controller.openLoginItemsSettings()

        #expect(controller.helperStatus == .enabled)
        #expect(harness.savedToken == "secret")
        #expect(harness.clearTokenCalls == 1)
        #expect(harness.openSettingsCalls == 1)
        #expect(!controller.githubTokenStored)
        #expect(controller.githubTokenStatus != nil)
    }

    @Test func failedCredentialWriteReportsFailureAndReadsBackTheActualState() {
        let harness = Harness()
        harness.setTokenResult = false
        harness.hasToken = false
        let controller = InfoOperationsController(dependencies: dependencies(harness))

        controller.saveGitHubToken("rejected")

        #expect(!controller.githubTokenStored)
        #expect(controller.githubTokenStatus != nil)
        #expect(harness.savedToken == "rejected")
    }

    @Test func unsignedBuildStopsBeforeHelperRegistration() async {
        let harness = Harness()
        harness.teamIDConfigured = false
        let controller = InfoOperationsController(dependencies: dependencies(harness))

        await controller.installHelper { _ in
            Issue.record("An unsigned build must not announce helper success")
        }

        #expect(harness.registerCalls == 0)
        #expect(controller.helperError != nil)
        #expect(!controller.helperBusy)
    }

    @Test func helperRegistrationFailureIsReportedAndStatusIsRefreshed() async {
        let harness = Harness()
        harness.registerError = StubError.failed
        harness.helperStatus = .notFound
        let controller = InfoOperationsController(dependencies: dependencies(harness))

        await controller.installHelper { _ in }

        #expect(harness.registerCalls == 1)
        #expect(controller.helperStatus == .notFound)
        #expect(controller.helperError != nil)
        #expect(!controller.helperBusy)
    }

    @Test func helperRegistrationAnnouncesApprovalAndEnabledStates() async {
        let approvalHarness = Harness()
        approvalHarness.helperStatus = .requiresApproval
        let approvalController = InfoOperationsController(dependencies: dependencies(approvalHarness))
        var approvalState: WegaState?

        await approvalController.installHelper { approvalState = $0 }

        #expect(approvalState?.pose == .alert)

        let enabledHarness = Harness()
        enabledHarness.helperStatus = .enabled
        let enabledController = InfoOperationsController(dependencies: dependencies(enabledHarness))
        var enabledState: WegaState?

        await enabledController.installHelper { enabledState = $0 }

        #expect(enabledState?.pose == .happy)
    }

    @Test func cancelledHelperRemovalDoesNotTouchTheHelper() async {
        let harness = Harness()
        harness.authentication = .cancelled
        let controller = InfoOperationsController(dependencies: dependencies(harness))

        await controller.removeHelper()

        #expect(harness.unregisterCalls == 0)
        #expect(!controller.helperBusy)
    }

    @Test func failedAuthenticationExplainsWhyRemovalStopped() async {
        let harness = Harness()
        harness.authentication = .failed("denied")
        let controller = InfoOperationsController(dependencies: dependencies(harness))

        await controller.removeHelper()

        #expect(harness.unregisterCalls == 0)
        #expect(controller.helperError == "denied")
    }

    @Test func unavailableAuthenticationStillAllowsHelperRemoval() async {
        let harness = Harness()
        harness.authentication = .unavailable
        harness.helperStatus = .notRegistered
        let controller = InfoOperationsController(dependencies: dependencies(harness))

        await controller.removeHelper()

        #expect(harness.unregisterCalls == 1)
        #expect(controller.helperStatus == .notRegistered)
        #expect(controller.helperError == nil)
        #expect(!controller.helperBusy)
    }

    @Test func helperRemovalFailureIsPublished() async {
        let harness = Harness()
        harness.authentication = .success
        harness.unregisterError = StubError.failed
        let controller = InfoOperationsController(dependencies: dependencies(harness))

        await controller.removeHelper()

        #expect(harness.unregisterCalls == 1)
        #expect(controller.helperError != nil)
        #expect(!controller.helperBusy)
    }

    @Test func catalogRefreshPublishesItsOutcome() async {
        let harness = Harness()
        harness.catalogOutcome = .notModified
        let controller = InfoOperationsController(dependencies: dependencies(harness))

        await controller.refreshCatalog()

        #expect(harness.catalogCalls == 1)
        #expect(controller.catalogOutcome == .notModified)
        #expect(!controller.catalogRefreshing)
    }

    @Test func diagnosticsLoadSucceedsOnceAndFallsBackAfterFailure() async {
        let successHarness = Harness()
        successHarness.diagnostics = DiagnosticsResult(
            brewVersion: "Homebrew 5",
            masVersion: "2.0",
            appManagement: .granted
        )
        let successController = InfoOperationsController(dependencies: dependencies(successHarness))

        await successController.loadDiagnostics()
        await successController.loadDiagnostics()

        #expect(successHarness.diagnosticsCalls == 1)
        #expect(successController.diagnostics?.brewVersion == "Homebrew 5")
        #expect(successController.diagnostics?.masVersion == "2.0")
        #expect(successController.diagnostics?.appManagement == .granted)

        let failureHarness = Harness()
        failureHarness.diagnosticsError = StubError.failed
        let failureController = InfoOperationsController(dependencies: dependencies(failureHarness))

        await failureController.loadDiagnostics()

        #expect(failureController.diagnostics?.brewVersion == nil)
        #expect(failureController.diagnostics?.masVersion == nil)
        #expect(failureController.diagnostics?.appManagement == .unknown)
    }
}

@MainActor
private final class Harness {
    var helperStatus = PrivilegedHelperClient.Status.notRegistered
    var hasToken = false
    var setTokenResult = true
    var savedToken: String?
    var clearTokenCalls = 0
    var openSettingsCalls = 0
    var teamIDConfigured = true
    var registerCalls = 0
    var registerError: Error?
    var authentication = BiometricGate.GateResult.success
    var unregisterCalls = 0
    var unregisterError: Error?
    var catalogCalls = 0
    var catalogOutcome = CatalogRefresher.Outcome.updated
    var diagnosticsCalls = 0
    var diagnostics = DiagnosticsResult(brewVersion: nil, masVersion: nil)
    var diagnosticsError: Error?
}

@MainActor
private func dependencies(_ harness: Harness) -> InfoOperationsController.Dependencies {
    InfoOperationsController.Dependencies(
        helperStatus: { harness.helperStatus },
        hasGitHubToken: { harness.hasToken },
        setGitHubToken: { token in
            harness.savedToken = token
            if harness.setTokenResult { harness.hasToken = true }
            return harness.setTokenResult
        },
        clearGitHubToken: {
            harness.clearTokenCalls += 1
            harness.hasToken = false
        },
        openLoginItemsSettings: { harness.openSettingsCalls += 1 },
        teamIDConfigured: { harness.teamIDConfigured },
        registerHelper: {
            harness.registerCalls += 1
            if let error = harness.registerError { throw error }
        },
        authenticate: { _ in harness.authentication },
        unregisterHelper: {
            harness.unregisterCalls += 1
            if let error = harness.unregisterError { throw error }
        },
        refreshCatalog: {
            harness.catalogCalls += 1
            return harness.catalogOutcome
        },
        readDiagnostics: {
            harness.diagnosticsCalls += 1
            if let error = harness.diagnosticsError { throw error }
            return harness.diagnostics
        }
    )
}

private enum StubError: Error {
    case failed
}
