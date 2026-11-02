import Foundation

public enum ZedReleaseChannel: String, Codable, Sendable {
    case stable, preview

    public init?(bundleIdentifier: String?) {
        switch bundleIdentifier {
        case "dev.zed.Zed": self = .stable
        case "dev.zed.Zed-Preview": self = .preview
        default: return nil
        }
    }

    var caskToken: String { self == .stable ? "zed" : "zed@preview" }
}

/// Checks the same channel-specific release metadata as Zed's own updater.
/// Installation remains inside Zed; downloaded asset URLs are never executed by Wega.
public struct ZedUpdateChecker: VendorUpdateChecker {
    public let client: HTTPClient
    private let architecture: String

    public init(client: HTTPClient = .shared, architecture: String? = nil) {
        self.client = client
        self.architecture = architecture ?? Self.hostArchitecture
    }

    public func plan(for app: ApplicationInfo) -> VendorCheckPlan? {
        guard let channel = ZedReleaseChannel(bundleIdentifier: app.bundleIdentifier),
              let installed = app.version, Self.isReleaseVersion(installed),
              ["aarch64", "x86_64"].contains(architecture),
              let url = AppEndpoints.shared.zedReleaseURL(channel: channel, architecture: architecture) else { return nil }
        return VendorCheckPlan(request: HTTPRequest(url: url, enableETag: true)) { data in
            guard let release = try? JSONDecoder().decode(Release.self, from: data),
                  Self.isReleaseVersion(release.version) else { return .decided(.failed) }
            return .candidate(VendorCandidate(latest: release.version, installed: installed,
                                               source: .zed(channel: channel), scheme: .semver))
        }
    }

    static func isZed(bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier else { return false }
        return bundleIdentifier == "dev.zed.Zed" || bundleIdentifier.hasPrefix("dev.zed.Zed-")
    }

    static func isCompatibleCask(_ token: String, bundleIdentifier: String?) -> Bool {
        guard isZed(bundleIdentifier: bundleIdentifier) else { return true }
        return ZedReleaseChannel(bundleIdentifier: bundleIdentifier)?.caskToken == token
    }

    private static var hostArchitecture: String {
        #if arch(arm64)
        "aarch64"
        #else
        "x86_64"
        #endif
    }

    private static func isReleaseVersion(_ version: String) -> Bool {
        let number = "(?:0|[1-9][0-9]*)"
        let identifier = "(?:0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*)"
        let pattern = "\\A\(number)\\.\(number)\\.\(number)(?:-\(identifier)(?:\\.\(identifier))*)?(?:\\+[0-9A-Za-z-]+(?:\\.[0-9A-Za-z-]+)*)?\\z"
        return version.range(of: pattern, options: .regularExpression) != nil
    }

    private struct Release: Decodable {
        let version: String
    }
}
