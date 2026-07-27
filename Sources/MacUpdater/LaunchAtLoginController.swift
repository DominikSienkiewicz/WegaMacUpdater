import Foundation
import MacUpdaterCore

/// BG-02 — drives the "Uruchamiaj przy logowaniu" toggle. Registers / unregisters the app
/// as a login item and, after every action, re-reads the **real** `SMAppService` status so
/// the toggle can never drift from what the system actually does. The `LoginItemManaging`
/// dependency is injected so the register/unregister/refresh logic is unit-tested against a
/// fake instead of the tester's real login items.
@MainActor
final class LaunchAtLoginController: ObservableObject {
    @Published private(set) var state: LoginItemState
    @Published private(set) var errorMessage: String?

    private let service: LoginItemManaging

    init(service: LoginItemManaging = LoginItemService.shared) {
        self.service = service
        self.state = LoginItemState(status: service.status)
    }

    /// Re-reads the live login-item status. Cheap; called on appear and when the app
    /// returns to the front, since the user can flip the item off in System Settings.
    func refresh() {
        state = LoginItemState(status: service.status)
    }

    /// Turns the login item on (register) or off (unregister). On failure the error is
    /// surfaced and the toggle falls back to whatever the system really reports — it never
    /// pretends an action that threw succeeded.
    func setEnabled(_ desired: Bool) async {
        errorMessage = nil
        do {
            if desired {
                try service.register()
            } else {
                try await service.unregister()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        refresh()
    }

    func openLoginItemsSettings() {
        service.openLoginItemsSettings()
    }
}
