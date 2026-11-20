import Foundation

/// Whether this installation carries the system-level askpass payload that only the `.pkg`
/// installs. A copy without it cannot ask for the administrator password.
public enum PasswordPromptAvailability {
    /// Resolved once per launch: only the installer ever changes the payload.
    private static let installed: Bool = (try? AuthorizationComponentResolver().resolveAndVerify()) != nil

    public static func isInstalled() -> Bool { installed }
}
