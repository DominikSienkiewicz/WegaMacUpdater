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

    /// One app as the claim rules read it: its bundle id and names folded and its zap entries
    /// parsed once per planning run, not once per item.
    struct Claimant {
        /// Folded; nil for a missing or empty bundle id.
        let bundleIdentifier: String?
        fileprivate let names: Set<String>
        fileprivate let zapEntries: [[ZapComponent]]

        init(_ app: LeftoverApp) {
            bundleIdentifier = LeftoverOwnership.bundleIdentifier(of: app)
            names = Set([app.name, app.fileName].map(LeftoverOwnership.fold))
            zapEntries = LeftoverOwnership.zapEntries(of: app).map { $0.map(ZapComponent.init) }
        }
    }

    /// A planned item as the claim rules compare it, folded once for every app checked against it.
    struct ClaimedItem {
        fileprivate let components: [String]
        fileprivate let folded: [String]
        fileprivate let bundleIDStems: [String]
        fileprivate let source: LeftoverItem.Source

        /// - Parameters:
        ///   - components: the item's path below the home folder.
        ///   - source: the source that names the item; only an `.appName` item is claimed by name.
        init(components: [String], source: LeftoverItem.Source) {
            self.components = components
            folded = components.map(LeftoverOwnership.fold)
            bundleIDStems = folded.last.map(LeftoverOwnership.bundleIDStems) ?? []
            self.source = source
        }
    }

    /// One component of a zap entry read for claiming.
    fileprivate enum ZapComponent {
        /// `**` or `{…}`: the entry is read leniently, so it covers any name.
        case anyName
        case pattern(String)
        case name(folded: String)

        init(_ component: String) {
            if LeftoverPathRules.hasDoubleStar(component) || component.unicodeScalars.contains("{") {
                self = .anyName
            } else if LeftoverPathRules.hasWildcard(component) {
                self = .pattern(component)
            } else {
                self = .name(folded: LeftoverOwnership.fold(component))
            }
        }

        /// Whether it covers the item's component at `index`: as a pattern for `*`, `?` or `[`,
        /// and otherwise as the same name.
        func covers(_ item: ClaimedItem, at index: Int) -> Bool {
            switch self {
            case .anyName: true
            case .pattern(let pattern): LeftoverPathRules.matches(pattern: pattern, name: item.components[index])
            case .name(let folded): folded == item.folded[index]
            }
        }
    }

    /// Whether `app` claims the item at `components`, planned for `target`. A planning run uses
    /// the overload taking a `Claimant` per app instead, built once.
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
        claims(
            item: ClaimedItem(components: components, source: source),
            target: Claimant(target),
            by: Claimant(app),
            competingBundleIdentifiers: allApps.compactMap(bundleIdentifier(of:))
        )
    }

    /// Whether `app` claims `item`, planned for `target`.
    /// - Parameter competingBundleIdentifiers: the folded bundle ids of every app of the run; the
    ///   longest one naming an item owns it.
    static func claims(
        item: ClaimedItem,
        target: Claimant,
        by app: Claimant,
        competingBundleIdentifiers: [String]
    ) -> Bool {
        guard let name = item.folded.last else { return false }
        if let bundleID = app.bundleIdentifier, bundleID == target.bundleIdentifier { return true }
        return ownsByBundleIdentifier(item, bundleID: app.bundleIdentifier, competing: competingBundleIdentifiers)
            || (item.source == .appName && app.names.contains(name))
            || app.zapEntries.contains { names($0, item) || isAncestor(item, of: $0) }
    }

    /// The longest bundle id that one of the name's bundle-id stems equals or begins with
    /// followed by `.` owns the item.
    private static func ownsByBundleIdentifier(_ item: ClaimedItem, bundleID: String?, competing: [String]) -> Bool {
        guard let bundleID else { return false }
        return item.bundleIDStems.contains { stem in
            isNamed(stem, after: bundleID) && !competing.contains { otherID in
                otherID.count > bundleID.count && isNamed(stem, after: otherID)
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

    /// Whether the zap entry names the item: same depth, and every component covered. The last
    /// component, the one most likely to differ, is compared first.
    private static func names(_ entry: [ZapComponent], _ item: ClaimedItem) -> Bool {
        let last = item.components.count - 1
        return entry.count == item.components.count
            && entry[last].covers(item, at: last)
            && entry.indices.allSatisfy { entry[$0].covers(item, at: $0) }
    }

    /// Whether the item's path lies above a path the zap entry names: the item is shorter, and
    /// each of its components is covered by the entry's component at the same depth.
    private static func isAncestor(_ item: ClaimedItem, of entry: [ZapComponent]) -> Bool {
        let last = item.components.count - 1
        return item.components.count < entry.count
            && entry[last].covers(item, at: last)
            && item.components.indices.allSatisfy { entry[$0].covers(item, at: $0) }
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
