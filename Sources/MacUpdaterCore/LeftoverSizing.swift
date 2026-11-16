import Foundation

/// The disk space a leftover takes, or `unknown` when it was not or could not be measured.
public enum LeftoverSize: Equatable, Sendable {
    case bytes(Int64)
    case unknown
}

/// Sizes the leftovers offered after an uninstall with Cleanup's allocated-size logic: a link
/// counts as the link itself, and a folder is summed without following the links inside it.
public enum LeftoverSizing {
    /// Never read inside: reading another app's container can raise macOS's "access data from
    /// other apps" prompt just because the sheet opened.
    private static let unmeasuredFolders: Set<String> = [
        LeftoverPathRules.key(["Library", "Containers"]),
        LeftoverPathRules.key(["Library", "Group Containers"]),
    ]

    /// The allocated size of `url`; `unknown` without touching the disk for an item inside
    /// `~/Library/Containers` or `~/Library/Group Containers`, and `unknown` when measuring fails.
    public static func measure(_ url: URL, home: URL, fileSystem: any CleanupFileSystem) -> LeftoverSize {
        guard !isInsideUnmeasuredFolder(url, home: home),
              let bytes = try? fileSystem.allocatedSize(of: url)
        else { return .unknown }
        return .bytes(bytes)
    }

    /// Compares whole components, ignoring case like `LeftoverPathRules.key`.
    private static func isInsideUnmeasuredFolder(_ url: URL, home: URL) -> Bool {
        let homeComponents = CleanupPathText.components(of: home.path)
        let components = CleanupPathText.components(of: url.path)
        guard components.count > homeComponents.count,
              LeftoverPathRules.key(Array(components.prefix(homeComponents.count))) == LeftoverPathRules.key(homeComponents)
        else { return false }
        let folder = components.dropFirst(homeComponents.count).prefix(2)
        return unmeasuredFolders.contains(LeftoverPathRules.key(Array(folder)))
    }
}
