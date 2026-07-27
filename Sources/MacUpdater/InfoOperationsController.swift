import Foundation
import MacUpdaterCore

/// Owns Settings-side process, network, Keychain and helper operations.
@MainActor
final class InfoOperationsController: ObservableObject {
    @Published private(set) var diagnostics: DiagnosticsResult?
    @Published private(set) var catalogRefreshing = false
    @Published private(set) var catalogOutcome: CatalogRefresher.Outcome?
    @Published private(set) var helperStatus: PrivilegedHelperClient.Status = .notRegistered
    @Published private(set) var helperBusy = false
    @Published private(set) var helperError: String?
    @Published private(set) var githubTokenStored = false
    @Published private(set) var githubTokenStatus: String?

    func refreshPersistentState() {
        helperStatus = PrivilegedHelperClient.shared.status
        githubTokenStored = GitHubCredentialStore.hasToken
    }

    func saveGitHubToken(_ token: String) {
        let succeeded = GitHubCredentialStore.setToken(token)
        githubTokenStored = GitHubCredentialStore.hasToken
        githubTokenStatus = succeeded
            ? tr("Token zapisany w Keychain")
            : tr("Nie udało się zapisać tokenu")
    }

    func clearGitHubToken() {
        GitHubCredentialStore.clear()
        githubTokenStored = false
        githubTokenStatus = tr("Token usunięty")
    }

    func openLoginItemsSettings() {
        PrivilegedHelperClient.shared.openLoginItemsSettings()
    }

    func refreshHelperStatus() {
        helperStatus = PrivilegedHelperClient.shared.status
    }

    func installHelper(onWegaState: @MainActor (WegaState) -> Void) async {
        helperBusy = true
        helperError = nil
        defer { helperBusy = false }
        guard WegaHelper.isTeamIDConfigured else {
            helperError = tr("Brak skonfigurowanego Team ID — helper zadziała dopiero w podpisanym buildzie.")
            return
        }
        do {
            try PrivilegedHelperClient.shared.register()
        } catch {
            helperError = error.localizedDescription
        }
        refreshHelperStatus()
        if helperStatus == .requiresApproval {
            onWegaState(WegaState(
                pose: .alert,
                line: tr("Zatwierdź komponent w Ustawieniach → Elementy logowania.")
            ))
        } else if helperStatus == .enabled {
            onWegaState(WegaState(pose: .happy, line: tr("Komponent uprzywilejowany gotowy.")))
        }
    }

    func removeHelper() async {
        switch await BiometricGate.shared.authenticate(
            reason: tr("Potwierdź usunięcie komponentu uprzywilejowanego")
        ) {
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
            try await PrivilegedHelperClient.shared.unregister()
        } catch {
            helperError = error.localizedDescription
        }
        refreshHelperStatus()
    }

    func refreshCatalog() async {
        guard !catalogRefreshing else { return }
        catalogRefreshing = true
        defer { catalogRefreshing = false }
        catalogOutcome = await CatalogRefresher(source: AppEndpoints.shared.appCatalogURL).refresh()
    }

    func loadDiagnostics() async {
        guard diagnostics == nil else { return }
        do {
            diagnostics = try await OperationCoordinator.shared.withRead(
                label: "settings diagnostics"
            ) {
                await Self.readDiagnostics()
            }
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
