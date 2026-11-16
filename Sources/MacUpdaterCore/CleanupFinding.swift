import Foundation

public enum CleanupDetectorID: String, Codable, Equatable, Sendable {
    case pathDuplicates = "D1"
    case source = "D2"
    case versionDirectories = "D3"
    case homebrew = "D4"
    case runtimeVersions = "D5"
    case gradle = "D6"
    case jetBrains = "D7"
    case shellState = "D8"
    case pathHygiene = "D9"
    case tccMap = "D10"
}

public enum CleanupVersionManager: String, Codable, Equatable, Sendable {
    case uv, fnm, nvm, pyenv, sdkman, rustup, mise, asdf, volta, pnpmEnv
}

public enum CleanupPackageManager: String, Codable, Equatable, Sendable {
    case npm, pnpm, bun, pipx, cargo, go
}

public enum CleanupSource: Codable, Equatable, Sendable {
    case homebrewFormula(name: String)
    case homebrewCask(token: String)
    case appBundle(name: String)
    case appManaged(owner: String)
    case versionManager(CleanupVersionManager)
    case packageManager(CleanupPackageManager)
    case nativeVersionDirectory(tool: String)
    case system
    case standalone
}

/// Process arguments can carry tokens, so they are shown live but never encoded.
public struct CleanupProcess: Codable, Equatable, Sendable {
    public let pid: Int32
    public let name: String
    public let executablePath: String
    public let arguments: [String]

    public init(pid: Int32, name: String, executablePath: String, arguments: [String]) {
        self.pid = pid
        self.name = name
        self.executablePath = executablePath
        self.arguments = arguments
    }

    private enum CodingKeys: String, CodingKey {
        case pid, name, executablePath
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        pid = try container.decode(Int32.self, forKey: .pid)
        name = try container.decode(String.self, forKey: .name)
        executablePath = try container.decode(String.self, forKey: .executablePath)
        arguments = []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(pid, forKey: .pid)
        try container.encode(name, forKey: .name)
        try container.encode(executablePath, forKey: .executablePath)
    }
}

public enum CleanupStatus: Codable, Equatable, Sendable {
    case active
    case shadowed
    case unused
    case stale
    case inUse([CleanupProcess])
    case expected
    case appManaged
    case dependency([String])
    case brokenLink
    case skippedProtected
    case info
    /// Absolute paths of the files or manager settings that reference the item.
    case pinned(by: [String])
    case recentUpgrade(until: Date)
    /// A `PATH` entry or a map entry that points at nothing.
    case deadEntry
}

public enum CleanupBrewAction: Codable, Equatable, Sendable {
    case uninstallFormula(String)
    case uninstallCask(String)
    case cleanup(String)
}

public enum CleanupInstruction: Codable, Equatable, Sendable {
    case removeWithCreatingTool
    case removeAppLinkWithAdminRights(link: String)
    /// Empty `locations` means no shell file Wega checks mentions the entry.
    case editShellFiles(entry: String, locations: [CleanupShellFileLocation])
    case switchOffInFilesAndFolders
}

public enum CleanupAction: Codable, Equatable, Sendable {
    case trash([URL])
    case trashBatch(parent: URL, entries: [URL])
    case brew(CleanupBrewAction)
    case command(String)
    case instruction(CleanupInstruction)
    case none
}

public enum CleanupReason: Codable, Equatable, Sendable {
    case olderVersion(current: String)
    /// A version in a recognised layout that is newer than the current one.
    case newerVersion(current: String)
    case shadowedBy(path: String)
    case systemCopy
    case managedByApp(owner: String)
    case staleSinceBoot(count: Int)
    case keptSinceBoot(count: Int)
    case unknownVersionDirectory
    case currentVersion
    case protectedLocation
    case brokenLink
    case requiredBy([String])
    case homebrewLeftovers(items: Int)
    case homebrewKeptVersions(count: Int)
    case installedOnlyAsDependency
    case recentlyUpgraded
    case notRequiredByProjects
    case requiredByProjects
    case unusedGradleDistribution
    case unreferencedJDK(major: Int)
    case systemJDK(major: Int)
    case ideVersionNotInstalled(installed: [String])
    case ideNotFound
    case newerThanInstalledIDE(installed: [String])
    case missingPathEntry
    case repeatedPathEntry(count: Int)
    case samePlaceAs(path: String)
    case nestedIn(parent: String)
    case olderCopyWins(version: String, newer: String, newerVersion: String)
    case tccEntry(grants: [CleanupTCCGrant], link: CleanupTCCLink?)
    case tccEntryFileGone(grants: [CleanupTCCGrant])
}

public enum CleanupVersionRelation: Codable, Equatable, Sendable {
    case olderOrSame, newer, unknown, notApplicable
}

public enum CleanupRisk: String, Codable, Equatable, Sendable {
    case low, medium, high
}

public enum CleanupBucket: String, Codable, Equatable, Sendable {
    case safe, needsDecision, excluded
}

public struct CleanupFileIdentity: Codable, Hashable, Sendable {
    public let device: UInt64
    public let inode: UInt64

    public init(device: UInt64, inode: UInt64) {
        self.device = device
        self.inode = inode
    }
}

public struct CleanupFinding: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let detector: CleanupDetectorID
    public let tool: String
    public let path: URL
    public let realpath: URL?
    public let source: CleanupSource?
    public let version: String?
    public let size: Int64?
    public let status: CleanupStatus
    public let reason: CleanupReason
    public let action: CleanupAction
    public let risk: CleanupRisk
    public let bucket: CleanupBucket
    public let identity: CleanupFileIdentity?

    public init(
        detector: CleanupDetectorID,
        tool: String,
        path: URL,
        realpath: URL?,
        source: CleanupSource?,
        version: String?,
        size: Int64?,
        status: CleanupStatus,
        reason: CleanupReason,
        action: CleanupAction,
        risk: CleanupRisk,
        bucket: CleanupBucket,
        identity: CleanupFileIdentity?
    ) {
        let base = "\(detector.rawValue):\(Self.statusKey(status)):\(path.path)"
        self.id = detector == .tccMap ? "\(base):\(tool)" : base
        self.detector = detector
        self.tool = tool
        self.path = path
        self.realpath = realpath
        self.source = source
        self.version = version
        self.size = size
        self.status = status
        self.reason = reason
        self.action = action
        self.risk = risk
        self.bucket = bucket
        self.identity = identity
    }

    /// The status's case name. It is part of the id because D8 reports a directory's stale and
    /// kept entries as two findings for the same path. D10 findings share the database file's path,
    /// so their id also carries the tool.
    private static func statusKey(_ status: CleanupStatus) -> String {
        switch status {
        case .active: "active"
        case .shadowed: "shadowed"
        case .unused: "unused"
        case .stale: "stale"
        case .inUse: "inUse"
        case .expected: "expected"
        case .appManaged: "appManaged"
        case .dependency: "dependency"
        case .brokenLink: "brokenLink"
        case .skippedProtected: "skippedProtected"
        case .info: "info"
        case .pinned: "pinned"
        case .recentUpgrade: "recentUpgrade"
        case .deadEntry: "deadEntry"
        }
    }
}

public enum CleanupLeftoverKind: Sendable {
    case homebrewCleanup, homebrewAutoremove, runtimeVersion, gradleDistribution, gradleJDK, jetBrainsDirectory
}

public enum CleanupBucketPolicy {
    public static func bucket(
        status: CleanupStatus,
        source: CleanupSource?,
        relation: CleanupVersionRelation,
        recognisedLayout: Bool
    ) -> CleanupBucket {
        if isExcluded(status) { return .excluded }
        if needsDecision(status: status, source: source, relation: relation, recognisedLayout: recognisedLayout) {
            return .needsDecision
        }
        return .safe
    }

    /// The detectors that find leftovers rather than copies: only a Gradle distribution or a JetBrains
    /// folder can be safe, and only when the evidence behind "unused" is complete.
    public static func bucket(
        status: CleanupStatus,
        kind: CleanupLeftoverKind,
        evidenceComplete: Bool
    ) -> CleanupBucket {
        if isExcluded(status) { return .excluded }
        guard case .unused = status, evidenceComplete else { return .needsDecision }
        switch kind {
        case .gradleDistribution, .jetBrainsDirectory: return .safe
        case .homebrewCleanup, .homebrewAutoremove, .runtimeVersion, .gradleJDK: return .needsDecision
        }
    }

    private static func isExcluded(_ status: CleanupStatus) -> Bool {
        switch status {
        case .active, .expected, .appManaged, .dependency, .info, .brokenLink, .skippedProtected, .pinned, .recentUpgrade, .deadEntry:
            return true
        case .shadowed, .unused, .stale, .inUse:
            return false
        }
    }

    private static func needsDecision(
        status: CleanupStatus,
        source: CleanupSource?,
        relation: CleanupVersionRelation,
        recognisedLayout: Bool
    ) -> Bool {
        if case .inUse = status { return true }
        if isOwnedOutsideTheSystem(source) { return true }
        if case .nativeVersionDirectory = source, !recognisedLayout { return true }
        if case .shadowed = status { return relation == .newer || relation == .unknown }
        return false
    }

    private static func isOwnedOutsideTheSystem(_ source: CleanupSource?) -> Bool {
        switch source {
        case .packageManager, .versionManager, .standalone:
            return true
        default:
            return false
        }
    }
}

public struct CleanupTotals: Codable, Equatable, Sendable {
    public var safe: Int64
    public var needsDecision: Int64

    public init(safe: Int64, needsDecision: Int64) {
        self.safe = safe
        self.needsDecision = needsDecision
    }

    public static func sum(_ findings: [CleanupFinding]) -> CleanupTotals {
        var totals = CleanupTotals(safe: 0, needsDecision: 0)
        for finding in findings {
            let size = finding.size ?? 0
            switch finding.bucket {
            case .safe: totals.safe += size
            case .needsDecision: totals.needsDecision += size
            case .excluded: break
            }
        }
        return totals
    }
}
