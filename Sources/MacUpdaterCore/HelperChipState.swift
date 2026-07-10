import Foundation

/// What the sidebar chip may claim about the privileged helper (M3a).
///
/// `SMAppService` reports five statuses; a user can only act on three distinctions:
/// it works, macOS is waiting for their approval, or it is not running. Anything we
/// cannot interpret collapses to `inactive` — an app whose pitch is "supply-chain
/// guardian" does not get to display a green dot on a guess.
///
/// The colour and the label are the view's business; this type carries the meaning.
public enum HelperChipState: Equatable, Sendable {
    case active
    case needsApproval
    case inactive

    public init(status: PrivilegedHelperClient.Status) {
        switch status {
        case .enabled:          self = .active
        case .requiresApproval: self = .needsApproval
        case .notRegistered, .notFound, .unknown: self = .inactive
        }
    }

    /// Only the approval state has somewhere useful to send the user.
    public var opensLoginItemsSettings: Bool {
        self == .needsApproval
    }
}
