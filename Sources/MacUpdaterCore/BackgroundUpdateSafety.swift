import Foundation

/// Runtime vetoes that keep unattended cask upgrades inside the rollback guarantee.
///
/// Eligibility from cask metadata is necessary but not sufficient: an installed bundle
/// still has to resolve on this Mac, and the copy-on-write clone has to succeed in this
/// exact round. Candidate order is preserved for deterministic commands and reporting.
public enum BackgroundUpdateSafety {
    public static func pathBackedTokens(_ candidates: [String], appPaths: [String: URL]) -> [String] {
        candidates.filter { token in
            guard let appPath = appPaths[token] else { return false }
            return appPath.pathExtension.caseInsensitiveCompare("app") == .orderedSame
        }
    }

    public static func snapshotBackedTokens(_ candidates: [String], snapshots: [String: URL]) -> [String] {
        candidates.filter { snapshots[$0] != nil }
    }
}
