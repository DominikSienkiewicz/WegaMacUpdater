import Foundation

public struct RemoveAppBundleRequest: Codable, Equatable, Sendable {
    public var path: String
    public var expectedBundleIdentifier: String

    public init(path: String, expectedBundleIdentifier: String) {
        self.path = path
        self.expectedBundleIdentifier = expectedBundleIdentifier
    }
}

public enum RemovalPolicy: String, Codable, Equatable, Sendable {
    case applicationBundle
    case applicationSupport
    case cache
    case preferencePlist
}

public struct RemovePathsRequest: Codable, Equatable, Sendable {
    public var paths: [String]
    public var policy: RemovalPolicy

    public init(paths: [String], policy: RemovalPolicy) {
        self.paths = paths
        self.policy = policy
    }
}

public enum PrivilegedHelperOperation: Codable, Equatable, Sendable {
    case removeAppBundle(RemoveAppBundleRequest)
    case removePaths(RemovePathsRequest)
    case verifyWritableOrExplain(path: String)
    case repairOwnershipForKnownHomebrewPaths
}
