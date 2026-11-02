import Foundation

/// The installed antivirus product and its independently unverified update channels.
public struct BitdefenderProductStatus: Equatable, Sendable {
    public enum Freshness: Equatable, Sendable {
        case unknown
    }

    public let installedProductVersion: String?
    public let installedProductBuild: String?
    public var productFreshness: Freshness { .unknown }
    public var malwareDefinitionsFreshness: Freshness { .unknown }
    public var supportURL: URL? { BitdefenderSupport.supportURL }
}

public enum BitdefenderSupport {
    public static let bundleIdentifier = "com.bitdefender.antivirusformac"
    public static let supportURL = URL(string: "https://www.bitdefender.com/consumer/support/answer/32547/")

    /// Bundle versions describe the installed product; they cannot establish either channel's freshness.
    public static func status(for app: ApplicationInfo) -> BitdefenderProductStatus? {
        guard app.bundleIdentifier == bundleIdentifier else { return nil }
        return BitdefenderProductStatus(
            installedProductVersion: nonempty(app.version),
            installedProductBuild: nonempty(app.buildVersion)
        )
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}
