import Foundation

/// Whether another app still uses an item planned for a target. Pure: it compares the item's
/// home-relative components with the apps' bundle ids, names and zap lists, and never reads
/// the disk. Every comparison ignores case and Unicode normalisation (`LeftoverPathRules.key`).
enum LeftoverOwnership {
    private static let stateSuffixes = [".plist", ".savedState", ".binarycookies"].map(fold)
    private static let recentDocumentsSuffix = fold(".sfl")
    private static let digits = Set("0123456789".unicodeScalars)

    /// Whether `app` claims the item at `components`, planned for `target`.
    /// - Parameters:
    ///   - components: the item's path below the home folder.
    ///   - source: the source that names the item; only an `.appName` item is claimed by name.
    ///   - allApps: the apps whose bundle ids compete for an item named after a bundle id; the
    ///     longest matching bundle id owns it.
    static func claims(
        item components: [String],
        source: LeftoverItem.Source,
        target: LeftoverApp,
        by app: LeftoverApp,
        allApps: [LeftoverApp]
    ) -> Bool {
        guard let name = components.last else { return false }
        if let bundleID = bundleIdentifier(of: app), bundleID == bundleIdentifier(of: target) { return true }
        return ownsByBundleIdentifier(name, app: app, allApps: allApps)
            || (source == .appName && [app.name, app.fileName].contains { fold($0) == fold(name) })
            || zapEntries(of: app).contains { names($0, components) || isAncestor(components, of: $0) }
    }

    /// The longest bundle id that the name, without a state suffix, equals or begins with
    /// followed by `.` owns the item.
    private static func ownsByBundleIdentifier(_ name: String, app: LeftoverApp, allApps: [LeftoverApp]) -> Bool {
        guard let bundleID = bundleIdentifier(of: app) else { return false }
        let stem = stem(of: fold(name))
        guard isNamed(stem, after: bundleID) else { return false }
        return !allApps.contains { other in
            guard let otherID = bundleIdentifier(of: other) else { return false }
            return otherID.count > bundleID.count && isNamed(stem, after: otherID)
        }
    }

    private static func isNamed(_ stem: String, after bundleID: String) -> Bool {
        stem == bundleID || stem.hasPrefix(bundleID + ".")
    }

    /// The folded name without one `.plist`, `.savedState`, `.binarycookies` or `.sfl<digits>` suffix.
    private static func stem(of name: String) -> String {
        if let suffix = stateSuffixes.first(where: { name.hasSuffix($0) }) {
            return String(name.dropLast(suffix.count))
        }
        if let range = name.range(of: recentDocumentsSuffix, options: .backwards),
           name[range.upperBound...].unicodeScalars.allSatisfy(digits.contains) {
            return String(name[..<range.lowerBound])
        }
        return name
    }

    /// Whether the zap entry names the item: same depth, same folders, and a last component
    /// that matches as a pattern or is the same name.
    private static func names(_ entry: [String], _ components: [String]) -> Bool {
        guard entry.count == components.count, let pattern = entry.last, let name = components.last else { return false }
        let lastMatches = LeftoverPathRules.hasWildcard(pattern)
            ? LeftoverPathRules.matches(pattern: pattern, name: name)
            : fold(pattern) == fold(name)
        return lastMatches
            && LeftoverPathRules.key(Array(entry.dropLast())) == LeftoverPathRules.key(Array(components.dropLast()))
    }

    /// Whether the item's path lies above a path the zap entry names. Only the entry's
    /// folders are compared, never its last component.
    private static func isAncestor(_ components: [String], of entry: [String]) -> Bool {
        components.count < entry.count
            && LeftoverPathRules.key(components) == LeftoverPathRules.key(Array(entry.prefix(components.count)))
    }

    private static func zapEntries(of app: LeftoverApp) -> [[String]] {
        app.cask?.zapTrashPaths.compactMap(LeftoverPathRules.zapComponents) ?? []
    }

    private static func bundleIdentifier(of app: LeftoverApp) -> String? {
        guard let bundleID = app.bundleIdentifier, !bundleID.isEmpty else { return nil }
        return fold(bundleID)
    }

    private static func fold(_ name: String) -> String {
        LeftoverPathRules.key([name])
    }
}
