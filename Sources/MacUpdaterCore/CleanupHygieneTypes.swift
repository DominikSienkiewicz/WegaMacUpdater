import Foundation

/// Where a shell file mentions a `PATH` entry. Only the place is kept, never the line's text.
public struct CleanupShellFileLocation: Codable, Equatable, Sendable {
    /// Absolute path of the shell file.
    public let file: String
    /// 1-based line number.
    public let line: Int

    public init(file: String, line: Int) {
        self.file = file
        self.line = line
    }
}

public enum CleanupTCCService: String, Codable, Equatable, Sendable, CaseIterable {
    case desktop = "kTCCServiceSystemPolicyDesktopFolder"
    case documents = "kTCCServiceSystemPolicyDocumentsFolder"
    case downloads = "kTCCServiceSystemPolicyDownloadsFolder"
    case networkVolumes = "kTCCServiceSystemPolicyNetworkVolumes"
    case removableVolumes = "kTCCServiceSystemPolicyRemovableVolumes"
    case allFiles = "kTCCServiceSystemPolicyAllFiles"

    /// The name `tccutil reset` takes: the service without the `kTCCService` prefix.
    public var tccutilName: String {
        String(rawValue.dropFirst("kTCCService".count))
    }
}

public struct CleanupTCCGrant: Codable, Equatable, Sendable {
    public let service: CleanupTCCService
    public let allowed: Bool

    public init(service: CleanupTCCService, allowed: Bool) {
        self.service = service
        self.allowed = allowed
    }
}

public enum CleanupTCCLinkKind: Codable, Equatable, Sendable {
    case activeCopy
    case copyToRemove
    case keptCopy
    case appManaged(owner: String)
}

/// The finding a map entry belongs to, so the duplicates section can say which entry is which.
public struct CleanupTCCLink: Codable, Equatable, Sendable {
    public let findingID: String
    public let kind: CleanupTCCLinkKind

    public init(findingID: String, kind: CleanupTCCLinkKind) {
        self.findingID = findingID
        self.kind = kind
    }
}

public enum CleanupTCCMap {
    public static let enabledKey = "cleanup.tccMap.enabled"
    public static let enabledByDefault = false
    public static let fullDiskAccessPaneURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
    )!
}
