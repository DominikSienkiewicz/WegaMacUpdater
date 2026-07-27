import Foundation

/// What the "Uruchamiaj przy logowaniu" toggle may claim about the login item (BG-02).
///
/// `SMAppService` reports five statuses; the toggle can act on three distinctions: Wega
/// launches at login, it does not, or the user switched the item off in System Settings →
/// Login Items and has to finish there. Anything we cannot interpret collapses to
/// `disabled` — the toggle never claims the app relaunches on a guess.
///
/// Colour and label are the view's business; this type carries the meaning, mirroring
/// `HelperChipState`.
public enum LoginItemState: Equatable, Sendable {
    case enabled
    case disabled
    case requiresApproval

    public init(status: LoginItemService.Status) {
        switch status {
        case .enabled:          self = .enabled
        case .requiresApproval: self = .requiresApproval
        case .notRegistered, .notFound, .unknown: self = .disabled
        }
    }

    /// The toggle is "on" only when the item will actually relaunch Wega at login.
    public var isOn: Bool { self == .enabled }

    /// Only the approval state has somewhere useful to send the user: the item is
    /// registered but disabled outside the app, so re-registering won't help — System
    /// Settings will.
    public var needsSystemSettings: Bool { self == .requiresApproval }
}
