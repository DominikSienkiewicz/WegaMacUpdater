import Foundation

/// The home-relative paths, possibly ending in a wildcard, where an app's leftovers may be.
/// Pure: nothing here reads the disk or applies the path rules; the planner does both.
enum LeftoverCandidates {
    struct Candidate {
        let components: [String]
        let source: LeftoverItem.Source
        let probableReason: LeftoverItem.ProbableReason?
        /// The ByHost template's bundle id: a found name's part between `<id>.` and `.plist` must hold
        /// no `.`, or the file belongs to a longer id (`<id>.canary.<UUID>.plist`).
        var byHostIdentifier: String?
        /// Set on a ticked Homebrew-list entry: a found item whose name does not point to the app is
        /// `.notNamedForApp`.
        var appNames: AppNames?

        /// Whether an item found on disk for this candidate is the app's.
        func admits(_ found: [String]) -> Bool {
            guard let id = byHostIdentifier, let name = found.last else { return true }
            let hostPart = Array(name.unicodeScalars)
                .dropFirst(id.unicodeScalars.count + 1)
                .dropLast(byHostSuffix.unicodeScalars.count)
            return !hostPart.contains(".")
        }

        /// Why an item found on disk for this candidate is probable, judged on its own name.
        func probableReason(found: [String]) -> LeftoverItem.ProbableReason? {
            guard probableReason == nil, let appNames, let name = found.last, !appNames.matches(name) else {
                return probableReason
            }
            return .notNamedForApp
        }
    }

    /// What the name of a ticked Homebrew-list item must point to: the app's display name, `.app`
    /// file name or cask token, or its safe bundle id.
    struct AppNames {
        private let names: Set<String>
        private let bundleIdentifier: String?

        init(app: LeftoverApp, token: String) {
            names = Set([app.name, app.fileName, token].map { LeftoverPathRules.key([$0]) })
            bundleIdentifier = app.bundleIdentifier.flatMap { MigrationPlanner.isSafeBundleID($0) ? $0 : nil }
        }

        /// Without one state suffix the name equals one of the names, or it holds the bundle id the
        /// way a zap entry names it (`LeftoverCaskEvidence.component(_:namesBoundedID:)`).
        func matches(_ name: String) -> Bool {
            names.contains(LeftoverOwnership.stem(of: LeftoverPathRules.key([name])))
                || bundleIdentifier.map { LeftoverCaskEvidence.component(name, namesBoundedID: $0) } == true
        }
    }

    private static let byHostSuffix = ".plist"

    private static let teamIDCharacters = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
    )

    /// The `~/Library` locations named after the app's bundle id, in the planner's order;
    /// nothing for a bundle id that fails SEC-06.
    static func bundleIdentifier(for app: LeftoverApp) -> [Candidate] {
        guard let id = app.bundleIdentifier, MigrationPlanner.isSafeBundleID(id) else { return [] }
        let inLibrary = { (components: [String]) in
            Candidate(components: ["Library"] + components, source: .bundleIdentifier, probableReason: nil)
        }
        var candidates = [
            ["Application Support", id],
            ["Preferences", "\(id).plist"],
            ["Caches", id],
            ["Saved Application State", "\(id).savedState"],
            ["Containers", id],
            ["HTTPStorages", id],
            ["HTTPStorages", "\(id).binarycookies"],
            ["WebKit", id],
            ["Logs", id],
            ["Application Scripts", id],
            ["Cookies", "\(id).binarycookies"],
        ].map(inLibrary)
        candidates.append(Candidate(
            components: ["Library", "Preferences", "ByHost", "\(id).*\(byHostSuffix)"],
            source: .bundleIdentifier,
            probableReason: nil,
            byHostIdentifier: id
        ))
        if let team = app.teamIdentifier, isAlphanumeric(team) {
            candidates.append(inLibrary(["Group Containers", "\(team).\(id)"]))
        }
        candidates.append(inLibrary(["Group Containers", "group.\(id)"]))
        let recentDocuments = LeftoverPathRules.recentDocumentsFolder + ["\(id.lowercased()).sfl*"]
        candidates.append(Candidate(components: recentDocuments, source: .bundleIdentifier, probableReason: nil))
        return candidates
    }

    /// The `~/…` entries of the matched cask's zap list, in its order. An entry outside
    /// `~/Library`, or from a cask matched only by name, is probable. Any other entry carries the
    /// app's names, so an item it finds whose own name does not point to the app is probable too.
    static func zap(for app: LeftoverApp) -> [Candidate] {
        guard let cask = app.cask else { return [] }
        let isStrong = cask.isStrong(forBundleIdentifier: app.bundleIdentifier)
        let appNames = AppNames(app: app, token: cask.token)
        return cask.zapTrashPaths.compactMap(LeftoverPathRules.zapComponents).map { components in
            let reason = zapReason(components, isStrong: isStrong)
            return Candidate(
                components: components,
                source: .homebrewZap(token: cask.token),
                probableReason: reason,
                appNames: reason == nil ? appNames : nil
            )
        }
    }

    /// The `~/Library` folders whose entries are matched against the app's names.
    static let nameParents: [[String]] = [["Library", "Application Support"], ["Library", "Caches"], ["Library", "Logs"]]

    private static let minimumNameLength = 3
    private static let genericNames: Set<String> = [
        "apple", "google", "microsoft", "adobe", "mozilla", "jetbrains", "electron", "data", "cache", "caches",
        "logs", "log", "temp", "tmp", "shared", "common", "default", "settings", "config", "support", "library",
        "updater", "update", "updates", "helper", "crashreporter", "crashpad", "plugins", "app", "application",
        "applications",
    ]

    /// The app's display name and file name, once each, minus any too short, too generic or not
    /// expressible as one path component to be matched against a folder name.
    static func names(for app: LeftoverApp) -> [String] {
        var seenKeys: Set<String> = []
        return [app.name, app.fileName].filter { name in
            isUsableName(name) && seenKeys.insert(LeftoverPathRules.key([name])).inserted
        }
    }

    static func nameCandidate(parent: [String], name: String) -> Candidate {
        Candidate(components: parent + [name], source: .appName, probableReason: .appName)
    }

    private static func isUsableName(_ name: String) -> Bool {
        name.count >= minimumNameLength
            && !name.unicodeScalars.contains { $0 == "/" || $0 == ":" }
            && !name.hasPrefix(".")
            && !genericNames.contains(name.lowercased())
    }

    private static func zapReason(_ components: [String], isStrong: Bool) -> LeftoverItem.ProbableReason? {
        guard LeftoverPathRules.isInsideLibrary(components) else { return .outsideLibrary }
        return isStrong ? nil : .caskMatchedByName
    }

    private static func isAlphanumeric(_ team: String) -> Bool {
        !team.isEmpty && team.unicodeScalars.allSatisfy(teamIDCharacters.contains)
    }
}
