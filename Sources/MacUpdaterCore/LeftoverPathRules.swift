import Darwin
import Foundation

/// Pure rules deciding which home-relative paths may ever be offered for the Trash.
enum LeftoverPathRules {
    private static let protectedRoots: [[String]] = [
        ["Desktop"], ["Documents"], ["Downloads"], ["Pictures"], ["Movies"], ["Music"], ["Public"],
        ["Library", "Mobile Documents"], ["Library", "CloudStorage"], ["Library", "Mail"],
        ["Library", "Messages"], ["Library", "Safari"], ["Library", "Keychains"],
    ]

    private static let droppedLibraryFolders: [String] = [
        "LaunchAgents", "Internet Plug-Ins", "Audio", "Services", "QuickLook", "PreferencePanes",
        "Fonts", "Input Methods", "Screen Savers", "Spotlight", "ColorPickers",
        "Contextual Menu Items", "Extensions",
    ]

    private static let applePrefix = "com.apple."
    private static let recentDocumentsFolder = [
        "Library", "Application Support", "com.apple.sharedfilelist",
        "com.apple.LSSharedFileList.ApplicationRecentDocuments",
    ]

    /// Home-relative components of a `~/…` zap entry, or nil when the entry is not safely expressible.
    static func zapComponents(_ entry: String) -> [String]? {
        guard entry.hasPrefix("~/") else { return nil }
        var body = String(entry.dropFirst(2))
        if body.hasSuffix("/") { body.removeLast() }
        let components = body.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !components.isEmpty else { return nil }
        for (index, component) in components.enumerated() {
            if component.isEmpty || component == "." || component == ".." { return nil }
            if component.contains("**") || component.contains("{") || component.contains("}") { return nil }
            if index < components.count - 1, hasWildcard(component) { return nil }
        }
        return components
    }

    static func isOfferable(_ components: [String]) -> Bool {
        let minimumDepth = equals(components.first, "Library") ? 3 : 2
        guard components.count >= minimumDepth else { return false }
        guard !protectedRoots.contains(where: { startsWith(components, $0) }) else { return false }
        if components.count >= 2, equals(components[0], "Library"),
           droppedLibraryFolders.contains(where: { equals(components[1], $0) }) {
            return false
        }
        if components.contains(where: { $0.lowercased().hasPrefix(applePrefix) }) {
            return isRecentDocumentsFile(components)
        }
        return true
    }

    static func isInsideLibrary(_ components: [String]) -> Bool {
        equals(components.first, "Library")
    }

    static func hasWildcard(_ component: String) -> Bool {
        component.contains { "*?[".contains($0) }
    }

    static func matches(pattern: String, name: String) -> Bool {
        fnmatch(pattern, name, FNM_PERIOD | FNM_CASEFOLD) == 0
    }

    /// Case-folded, NFC-normalised join used for every path comparison.
    static func key(_ components: [String]) -> String {
        components
            .map { $0.precomposedStringWithCanonicalMapping.lowercased() }
            .joined(separator: "/")
    }

    private static func isRecentDocumentsFile(_ components: [String]) -> Bool {
        guard components.count == recentDocumentsFolder.count + 1,
              startsWith(components, recentDocumentsFolder) else { return false }
        return !components[components.count - 1].lowercased().hasPrefix(applePrefix)
    }

    private static func startsWith(_ components: [String], _ root: [String]) -> Bool {
        components.count >= root.count && zip(components, root).allSatisfy { equals($0, $1) }
    }

    private static func equals(_ lhs: String?, _ rhs: String) -> Bool {
        lhs?.caseInsensitiveCompare(rhs) == .orderedSame
    }
}
