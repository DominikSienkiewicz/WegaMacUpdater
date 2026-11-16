import Foundation

/// The home-relative paths, possibly ending in a wildcard, where an app's leftovers may be.
/// Pure: nothing here reads the disk or applies the path rules; the planner does both.
enum LeftoverCandidates {
    struct Candidate {
        let components: [String]
        let source: LeftoverItem.Source
        let probableReason: LeftoverItem.ProbableReason?
    }

    private static let teamIDCharacters = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
    )

    /// The `~/Library` locations named after the app's bundle id, in the planner's order;
    /// nothing for a bundle id that fails SEC-06.
    static func bundleIdentifier(for app: LeftoverApp) -> [Candidate] {
        guard let id = app.bundleIdentifier, MigrationPlanner.isSafeBundleID(id) else { return [] }
        var insideLibrary: [[String]] = [
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
            ["Preferences", "ByHost", "\(id).*.plist"],
        ]
        if let team = app.teamIdentifier, isAlphanumeric(team) {
            insideLibrary.append(["Group Containers", "\(team).\(id)"])
        }
        insideLibrary.append(["Group Containers", "group.\(id)"])
        let recentDocuments = LeftoverPathRules.recentDocumentsFolder + ["\(id.lowercased()).sfl*"]
        return (insideLibrary.map { ["Library"] + $0 } + [recentDocuments]).map {
            Candidate(components: $0, source: .bundleIdentifier, probableReason: nil)
        }
    }

    /// The `~/…` entries of the matched cask's zap list, in its order. An entry outside
    /// `~/Library`, or from a cask matched only by name, is probable.
    static func zap(for app: LeftoverApp) -> [Candidate] {
        guard let cask = app.cask else { return [] }
        let isStrong = cask.isStrong(forBundleIdentifier: app.bundleIdentifier)
        return cask.zapTrashPaths.compactMap(LeftoverPathRules.zapComponents).map { components in
            Candidate(
                components: components,
                source: .homebrewZap(token: cask.token),
                probableReason: zapReason(components, isStrong: isStrong)
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
