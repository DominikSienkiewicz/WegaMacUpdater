import Foundation

/// A `~/…` path that may be offered for the Trash after an app is uninstalled.
public struct LeftoverItem: Equatable, Sendable, Identifiable {
    public enum Source: Equatable, Sendable {
        case homebrewZap(token: String)
        case bundleIdentifier
        case appName
    }

    public enum ProbableReason: Equatable, Sendable {
        case caskMatchedByName
        case outsideLibrary
        case appName
        /// A strong cask's zap item whose own name does not point to the app: a vendor-wide or
        /// shared folder (Word's `Application Support/Microsoft`, Chrome's Google updater).
        case notNamedForApp
    }

    public let url: URL
    public let source: Source
    public let probableReason: ProbableReason?
    public let sharedWith: [String]
    public let coTargets: [String]

    /// Even an exact match may contain the user's local profile.
    public var isSelectedByDefault: Bool { false }
    public var hasStrongUnsharedMatch: Bool { probableReason == nil && sharedWith.isEmpty }
    public var id: String { url.path }

    public init(
        url: URL,
        source: Source,
        probableReason: ProbableReason? = nil,
        sharedWith: [String] = [],
        coTargets: [String] = []
    ) {
        self.url = url
        self.source = source
        self.probableReason = probableReason
        self.sharedWith = sharedWith
        self.coTargets = coTargets
    }
}

/// The Homebrew cask matched to an app, with how strongly it was matched.
public struct LeftoverCaskEvidence: Equatable, Sendable {
    public let token: String
    public let zapTrashPaths: [String]
    public let provenance: CaskMatchProvenance

    public init(token: String, zapTrashPaths: [String], provenance: CaskMatchProvenance) {
        self.token = token
        self.zapTrashPaths = zapTrashPaths
        self.provenance = provenance
    }

    /// Whether the cask match is trustworthy enough to offer its zap paths without a "probable" mark.
    public func isStrong(forBundleIdentifier bundleIdentifier: String?) -> Bool {
        switch provenance {
        case .bundleIdentifier, .curatedMapping:
            return true
        case .installedToken, .token, .displayName:
            guard let bundleIdentifier, MigrationPlanner.isSafeBundleID(bundleIdentifier) else { return false }
            return zapTrashPaths
                .compactMap(LeftoverPathRules.zapComponents)
                .joined()
                .contains { Self.component($0, namesBoundedID: bundleIdentifier) }
        }
    }

    /// Whether `component` holds `id`, ignoring case, bounded on each side by its start or end, a
    /// `.` or a wildcard character.
    static func component(_ component: String, namesBoundedID id: String) -> Bool {
        let boundaries = CharacterSet(charactersIn: ".*?[]")
        var searchRange = component.startIndex..<component.endIndex
        while let found = component.range(of: id, options: .caseInsensitive, range: searchRange) {
            let before = found.lowerBound == component.startIndex
                || component[component.index(before: found.lowerBound)].unicodeScalars.allSatisfy(boundaries.contains)
            let after = found.upperBound == component.endIndex
                || component[found.upperBound].unicodeScalars.allSatisfy(boundaries.contains)
            if before && after { return true }
            searchRange = found.upperBound..<component.endIndex
        }
        return false
    }
}

/// The app being uninstalled, as far as leftover planning needs to know it.
public struct LeftoverApp: Equatable, Sendable {
    public let id: String
    public let name: String
    public let fileName: String
    /// App bundle path, abbreviated with `~`.
    public let path: String
    public let bundleIdentifier: String?
    public let teamIdentifier: String?
    public let cask: LeftoverCaskEvidence?

    public init(
        id: String,
        name: String,
        fileName: String,
        path: String,
        bundleIdentifier: String?,
        teamIdentifier: String?,
        cask: LeftoverCaskEvidence?
    ) {
        self.id = id
        self.name = name
        self.fileName = fileName
        self.path = path
        self.bundleIdentifier = bundleIdentifier
        self.teamIdentifier = teamIdentifier
        self.cask = cask
    }
}

/// The leftovers planned for one app.
public struct LeftoverPlanGroup: Equatable, Sendable {
    public let appID: String
    public let items: [LeftoverItem]

    public init(appID: String, items: [LeftoverItem]) {
        self.appID = appID
        self.items = items
    }
}
