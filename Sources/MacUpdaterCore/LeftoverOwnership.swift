import Foundation

/// Whether another app still uses an item planned for a target. Pure: it compares the item's
/// home-relative components with the apps' bundle ids, names and zap lists, and never reads
/// the disk. Every comparison ignores case and Unicode normalisation (`LeftoverPathRules.key`).
enum LeftoverOwnership {
    private static let stateSuffixes = [".plist", ".savedState", ".binarycookies"].map(fold)
    private static let recentDocumentsSuffix = fold(".sfl")
    private static let digits = Set("0123456789".unicodeScalars)
    private static let groupPrefix = Array("group.".unicodeScalars)
    private static let teamIDLength = 10
    private static let teamIDScalars = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789".unicodeScalars)

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

    /// The longest bundle id that one of the name's bundle-id stems equals or begins with
    /// followed by `.` owns the item.
    private static func ownsByBundleIdentifier(_ name: String, app: LeftoverApp, allApps: [LeftoverApp]) -> Bool {
        guard let bundleID = bundleIdentifier(of: app) else { return false }
        return bundleIDStems(of: fold(name)).contains { stem in
            isNamed(stem, after: bundleID) && !allApps.contains { other in
                guard let otherID = bundleIdentifier(of: other) else { return false }
                return otherID.count > bundleID.count && isNamed(stem, after: otherID)
            }
        }
    }

    /// The folded name as it is, after a leading `group.`, and after a leading team id and `.`,
    /// each without a state suffix: group containers are named `group.<id>` and `<team>.<id>`.
    private static func bundleIDStems(of name: String) -> [String] {
        let scalars = Array(name.unicodeScalars)
        var names = [scalars[...]]
        if scalars.starts(with: groupPrefix) {
            names.append(scalars.dropFirst(groupPrefix.count))
        }
        if scalars.count > teamIDLength, scalars[teamIDLength] == ".",
           scalars[..<teamIDLength].allSatisfy(teamIDScalars.contains) {
            names.append(scalars.dropFirst(teamIDLength + 1))
        }
        return names.map { stem(of: String(String.UnicodeScalarView($0))) }
    }

    private static func isNamed(_ stem: String, after bundleID: String) -> Bool {
        stem == bundleID || stem.hasPrefix(bundleID + ".")
    }

    /// The folded name without one `.plist`, `.savedState`, `.binarycookies` or `.sfl<digits>` suffix.
    static func stem(of name: String) -> String {
        if let suffix = stateSuffixes.first(where: { name.hasSuffix($0) }) {
            return String(name.dropLast(suffix.count))
        }
        if let range = name.range(of: recentDocumentsSuffix, options: .backwards),
           name[range.upperBound...].unicodeScalars.allSatisfy(digits.contains) {
            return String(name[..<range.lowerBound])
        }
        return name
    }

    /// Whether the zap entry names the item: same depth, and every component covered.
    private static func names(_ entry: [String], _ components: [String]) -> Bool {
        entry.count == components.count && zip(entry, components).allSatisfy(covers)
    }

    /// Whether the item's path lies above a path the zap entry names: the item is shorter, and
    /// each of its components is covered by the entry's component at the same depth.
    private static func isAncestor(_ components: [String], of entry: [String]) -> Bool {
        components.count < entry.count && zip(entry, components).allSatisfy(covers)
    }

    /// Whether a zap entry's component covers an item's component: always for `**` or `{`,
    /// as a pattern for `*`, `?` or `[`, and otherwise as the same name.
    private static func covers(_ entryComponent: String, _ name: String) -> Bool {
        if LeftoverPathRules.hasDoubleStar(entryComponent) || entryComponent.unicodeScalars.contains("{") {
            return true
        }
        if LeftoverPathRules.hasWildcard(entryComponent) {
            return LeftoverPathRules.matches(pattern: entryComponent, name: name)
        }
        return fold(entryComponent) == fold(name)
    }

    /// The app's zap entries read for claiming. Unlike `LeftoverPathRules.zapComponents`, which
    /// gates what may be offered, this keeps wildcards anywhere, `**` and `{…}`: an entry dropped
    /// here would leave an item the app still uses ticked. Only an entry with an empty, `.` or
    /// `..` component is ignored.
    private static func zapEntries(of app: LeftoverApp) -> [[String]] {
        (app.cask?.zapTrashPaths ?? [])
            .compactMap(LeftoverPathRules.homeRelativeComponents)
            .filter { !$0.contains(where: isEmptyOrDots) }
    }

    private static func isEmptyOrDots(_ component: String) -> Bool {
        let scalars = Array(component.unicodeScalars)
        return scalars.isEmpty || scalars == ["."] || scalars == [".", "."]
    }

    private static func bundleIdentifier(of app: LeftoverApp) -> String? {
        guard let bundleID = app.bundleIdentifier, !bundleID.isEmpty else { return nil }
        return fold(bundleID)
    }

    private static func fold(_ name: String) -> String {
        LeftoverPathRules.key([name])
    }
}
