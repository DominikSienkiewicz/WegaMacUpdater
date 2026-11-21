import Foundation
import MacUpdaterCore

/// Owns Settings-side process, network, Keychain and helper operations.
@MainActor
final class InfoOperationsController: ObservableObject {
    struct Dependencies {
        var helperStatus: @MainActor () -> PrivilegedHelperClient.Status
        var hasGitHubToken: @MainActor () -> Bool
        var setGitHubToken: @MainActor (String) -> Bool
        var clearGitHubToken: @MainActor () -> Void
        var openLoginItemsSettings: @MainActor () -> Void
        var teamIDConfigured: @MainActor () -> Bool
        var registerHelper: @MainActor () throws -> Void
        var authenticate: @MainActor (String) async -> BiometricGate.GateResult
        var unregisterHelper: @MainActor () async throws -> Void
        var refreshCatalog: @MainActor () async -> CatalogRefresher.Outcome
        var readDiagnostics: @MainActor () async throws -> DiagnosticsResult

        static let live = Dependencies(
            helperStatus: { PrivilegedHelperClient.shared.status },
            hasGitHubToken: { GitHubCredentialStore.hasToken },
            setGitHubToken: { GitHubCredentialStore.setToken($0) },
            clearGitHubToken: { GitHubCredentialStore.clear() },
            openLoginItemsSettings: { PrivilegedHelperClient.shared.openLoginItemsSettings() },
            teamIDConfigured: { WegaHelper.isTeamIDConfigured },
            registerHelper: { try PrivilegedHelperClient.shared.register() },
            authenticate: { reason in
                await BiometricGate.shared.authenticate(reason: reason)
            },
            unregisterHelper: { try await PrivilegedHelperClient.shared.unregister() },
            refreshCatalog: {
                await CatalogRefresher(source: AppEndpoints.shared.appCatalogURL).refresh()
            },
            readDiagnostics: {
                try await OperationCoordinator.shared.withRead(label: "settings diagnostics") {
                    await InfoOperationsController.readDiagnostics()
                }
            }
        )
    }

    @Published private(set) var diagnostics: DiagnosticsResult?
    @Published private(set) var catalogRefreshing = false
    @Published private(set) var catalogOutcome: CatalogRefresher.Outcome?
    @Published private(set) var helperStatus: PrivilegedHelperClient.Status = .notRegistered
    @Published private(set) var helperBusy = false
    @Published private(set) var helperError: String?
    @Published private(set) var githubTokenStored = false
    @Published private(set) var githubTokenStatus: String?

    private let dependencies: Dependencies

    init(dependencies: Dependencies = .live) {
        self.dependencies = dependencies
    }

    /// What the helper card asks while the helper waits for approval in System Settings.
    static var approvalHint: String {
        tr("Zatwierdź pomocnika w Ustawieniach systemowych → Elementy logowania, potem wróć tutaj.")
    }

    /// The helper card's hint once the helper's status is `status`. The approval request goes as
    /// soon as the helper no longer waits for approval; any other message, such as the one
    /// `installHelper` has just set, stays.
    static func helperHint(_ hint: String?, after status: PrivilegedHelperClient.Status) -> String? {
        hint == approvalHint && status != .requiresApproval ? nil : hint
    }

    func refreshPersistentState() {
        helperStatus = dependencies.helperStatus()
        githubTokenStored = dependencies.hasGitHubToken()
    }

    func saveGitHubToken(_ token: String) {
        let succeeded = dependencies.setGitHubToken(token)
        githubTokenStored = dependencies.hasGitHubToken()
        githubTokenStatus = succeeded
            ? tr("Token zapisany w Keychain")
            : tr("Nie udało się zapisać tokenu")
    }

    func clearGitHubToken() {
        dependencies.clearGitHubToken()
        githubTokenStored = false
        githubTokenStatus = tr("Token usunięty")
    }

    func openLoginItemsSettings() {
        dependencies.openLoginItemsSettings()
    }

    func refreshHelperStatus() {
        helperStatus = dependencies.helperStatus()
    }

    func installHelper(onWegaState: @MainActor (WegaState) -> Void) async {
        helperBusy = true
        helperError = nil
        defer { helperBusy = false }
        guard dependencies.teamIDConfigured() else {
            helperError = tr("Brak skonfigurowanego Team ID — helper zadziała dopiero w podpisanym buildzie.")
            return
        }
        do {
            try dependencies.registerHelper()
        } catch {
            helperError = error.localizedDescription
        }
        refreshHelperStatus()
        if helperStatus == .requiresApproval {
            onWegaState(WegaState(pose: .alert, line: Self.approvalHint))
        } else if helperStatus == .enabled {
            onWegaState(WegaState(pose: .happy, line: tr("Pomocnik Wegi jest gotowy.")))
        }
    }

    func removeHelper() async {
        switch await dependencies.authenticate(tr("Potwierdź usunięcie pomocnika Wegi")) {
        case .success, .unavailable:
            break
        case .cancelled:
            return
        case .failed(let message):
            helperError = message
            return
        }

        helperBusy = true
        helperError = nil
        defer { helperBusy = false }
        do {
            try await dependencies.unregisterHelper()
        } catch {
            helperError = error.localizedDescription
        }
        refreshHelperStatus()
    }

    func refreshCatalog() async {
        guard !catalogRefreshing else { return }
        catalogRefreshing = true
        defer { catalogRefreshing = false }
        catalogOutcome = await dependencies.refreshCatalog()
    }

    func loadDiagnostics() async {
        guard diagnostics == nil else { return }
        do {
            diagnostics = try await dependencies.readDiagnostics()
        } catch {
            diagnostics = DiagnosticsResult(brewVersion: nil, masVersion: nil, appManagement: .unknown)
        }
    }

    private nonisolated static func readDiagnostics() async -> DiagnosticsResult {
        let locator = BinaryLocator()
        var brewVersion: String?
        var masVersion: String?

        if let brewURL = locator.locateBrew(),
           let result = try? await ProcessRunner().run(ProcessRequest(
               executableURL: brewURL,
               arguments: ["--version"],
               environment: HomebrewEnvironment.environment,
               inheritParentEnvironment: false,
               timeout: 5,
               idleTimeout: 5
           )) {
            brewVersion = result.stdout.split(separator: "\n").first.map(String.init)
        }

        if let masURL = locator.locateMas(),
           let result = try? await ProcessRunner().run(ProcessRequest(
               executableURL: masURL,
               arguments: ["version"],
               environment: HomebrewEnvironment.environment,
               inheritParentEnvironment: false,
               timeout: 5,
               idleTimeout: 5
           )) {
            masVersion = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // REL-05 — the optional preflight: ask now whether macOS will let Wega replace an app
        // bundle, instead of finding out from the first upgrade that fails. Read-only and
        // non-destructive (see `AppManagementPermissionProbe.liveProbe`), and only ever
        // *indicative* — an upgrade that actually hits the refusal still has the last word.
        return DiagnosticsResult(
            brewVersion: brewVersion,
            masVersion: masVersion,
            appManagement: AppManagementPermissionProbe.liveStatus()
        )
    }
}

struct DiagnosticsResult: Sendable {
    var brewVersion: String?
    var masVersion: String?
    var appManagement: AppManagementPermission = .unknown
}
