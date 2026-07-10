import Foundation

/// Who is allowed to ask the user for notification permission, and when (M3d).
///
/// macOS grants an app exactly one shot at the system permission dialog. Firing it from a
/// background timer — which is what the menu-bar agent used to do the first time it found
/// updates — spends that shot on a moment when the user is looking at another app and has
/// no idea why Wega is talking to them. So Wega explains itself in its own window first,
/// and only asks the system after the user has agreed to be asked.
public enum NotificationPrompt {
    /// Mirrors the subset of `UNAuthorizationStatus` that changes our behaviour. Kept as a
    /// plain enum so the decision is testable without `UserNotifications`.
    public enum SystemStatus: Equatable, Sendable {
        case notDetermined
        case authorized
        case denied
    }

    /// What the user has told *Wega* — distinct from what they have told macOS. Declining
    /// the card is a real answer and it sticks; there is no "ask me again later" state,
    /// because that state is how apps end up nagging.
    public enum InAppAnswer: Equatable, Sendable {
        case unanswered
        case agreed
        case declined
    }

    public enum Decision: Equatable, Sendable {
        /// Show the in-app explanation card. Nothing is posted, nothing is prompted.
        case explainInApp
        /// The user opted in; it is now fair to raise the system dialog.
        case askSystem
        /// Permission is granted — just post.
        case post
        /// Permission was refused. Say nothing, and do not ask again.
        case stayQuiet
    }

    public static func decide(system: SystemStatus, inApp: InAppAnswer) -> Decision {
        switch system {
        case .authorized: return .post
        case .denied:     return .stayQuiet
        case .notDetermined:
            switch inApp {
            case .unanswered: return .explainInApp
            case .agreed:     return .askSystem
            case .declined:   return .stayQuiet
            }
        }
    }
}

public extension NotificationPrompt.Decision {
    /// The single decision permitted to raise the macOS dialog. Asserting on this is how
    /// the tests pin "a background check never prompts".
    var promptsTheSystem: Bool { self == .askSystem }
}
