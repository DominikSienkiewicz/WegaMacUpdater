import Foundation
import ServiceManagement

/// BG-02 — the "Uruchamiaj przy logowaniu" seam.
///
/// Wega's whole background mode — the scheduled read-only check, the badge, the
/// notifications and the opt-in silent updates — runs inside `MenuBarAgent`, a `Task` loop
/// that lives **only in the running app process**. Nothing of it is a daemon, so once the
/// user restarts the Mac the agent is gone until they launch Wega by hand: background mode
/// was a promise that held only until the first reboot.
///
/// This wraps `SMAppService.mainApp` — the same modern registration mechanism the privileged
/// helper uses (`SMAppService.daemon`), one tier up — so the app can register **itself** as
/// a login item. macOS then relaunches Wega at login, `AppDelegate` starts the menu-bar
/// agent again, and the background mode survives a restart. The user can read the real
/// system status and switch the item off at any time.
///
/// The seam (`LoginItemManaging`) exists so the app-side controller can be unit-tested with
/// a fake instead of mutating the tester's real login items.
public protocol LoginItemManaging: Sendable {
    var status: LoginItemService.Status { get }
    func register() throws
    func unregister() async throws
    func openLoginItemsSettings()
}

public final class LoginItemService: LoginItemManaging, @unchecked Sendable {
    public static let shared = LoginItemService()

    /// The five statuses `SMAppService` reports, surfaced verbatim so the UI can collapse
    /// them into the actionable set (`LoginItemState`) without this type deciding meaning.
    public enum Status: Equatable, Sendable {
        case notRegistered
        case enabled
        case requiresApproval
        case notFound
        case unknown
    }

    private let service: SMAppService

    private init() {
        self.service = SMAppService.mainApp
    }

    public var status: Status {
        switch service.status {
        case .notRegistered:    return .notRegistered
        case .enabled:          return .enabled
        case .requiresApproval: return .requiresApproval
        case .notFound:         return .notFound
        @unknown default:       return .unknown
        }
    }

    public var isEnabled: Bool { status == .enabled }

    /// Registers the app as a login item. macOS relaunches it at the next login; on some
    /// configurations the user must still confirm it in System Settings → Login Items
    /// (status then reads `.requiresApproval`).
    public func register() throws {
        try service.register()
    }

    /// Removes the login item, so Wega no longer starts at login (the "disable" path).
    public func unregister() async throws {
        try await service.unregister()
    }

    /// Deep-links to System Settings → Login Items, where the user finishes an approval or
    /// can flip the item off outside the app.
    public func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
