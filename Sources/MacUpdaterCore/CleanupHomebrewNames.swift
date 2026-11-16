import Foundation

/// Gate for every Homebrew name that reaches an argument list or a command string in Cleanup.
public enum CleanupHomebrewNames {
    private static let allowedScalars = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789@+._-"
    )

    /// A formula is `name` or `user/tap/name`; every part is non-empty, never an option and
    /// never a path hop.
    public static func isValid(_ name: String) -> Bool {
        let parts = name.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 1 || parts.count == 3 else { return false }
        return parts.allSatisfy { part in
            !part.isEmpty && !part.hasPrefix("-") && part != "." && part != ".."
                && part.unicodeScalars.allSatisfy { allowedScalars.contains($0) }
        }
    }
}
