import Foundation

public enum FirefoxReleaseChannel: String, Codable, Sendable {
    case release, esr, beta

    var sourceLabel: String {
        switch self {
        case .release: "Firefox"
        case .esr: "Firefox ESR"
        case .beta: "Firefox Beta"
        }
    }

    fileprivate var caskToken: String {
        switch self {
        case .release: "firefox"
        case .esr: "firefox@esr"
        case .beta: "firefox@beta"
        }
    }

    fileprivate func accepts(_ version: String, published: Bool = false) -> Bool {
        guard MozillaReleaseVersion(version) != nil else { return false }
        switch self {
        case .release: return !version.contains("b") && !version.hasSuffix("esr")
        case .esr: return !version.contains("b") && (!published || version.hasSuffix("esr"))
        case .beta: return version.contains("b")
        }
    }
}

/// Reads Mozilla's packaged build metadata without starting or loading Firefox.
enum FirefoxInstallationMetadata {
    static func channel(for app: ApplicationInfo) -> FirefoxReleaseChannel? {
        guard let fields = appFields(at: app.path), let remotingName = fields["RemotingName"] else { return nil }
        switch remotingName {
        case "firefox": return .release
        case "firefox-esr": return .esr
        case "firefox-beta": return .beta
        default: return nil
        }
    }

    private static func appFields(at path: URL) -> [String: String]? {
        let metadata = path.appendingPathComponent("Contents/Resources/application.ini")
        guard let text = try? String(contentsOf: metadata, encoding: .utf8), !text.contains("\u{0}") else { return nil }
        var inAppSection = false
        var appSections = 0
        var fields: [String: String] = [:]
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix(";") || line.hasPrefix("#") { continue }
            if line.hasPrefix("[") {
                inAppSection = line == "[App]"
                if inAppSection { appSections += 1 }
                continue
            }
            guard inAppSection, let separator = line.firstIndex(of: "=") else { continue }
            let key = line[..<separator].trimmingCharacters(in: .whitespaces)
            guard fields[key] == nil else { return nil }
            fields[key] = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
        }
        return appSections == 1 ? fields : nil
    }
}

/// Mozilla's public release metadata is independent of Homebrew and preserves each install's channel.
public struct FirefoxUpdateChecker: VendorUpdateChecker {
    public static let bundleIdentifier = "org.mozilla.firefox"
    public let client: HTTPClient

    public init(client: HTTPClient = .shared) { self.client = client }

    public static func allowsCask(_ token: String, for app: ApplicationInfo) -> Bool {
        guard app.bundleIdentifier == bundleIdentifier else { return true }
        guard let channel = FirefoxInstallationMetadata.channel(for: app),
              let installed = app.version, channel.accepts(installed) else { return false }
        return channel.caskToken == token
    }

    static func sourceLabel(for app: ApplicationInfo) -> String {
        guard app.bundleIdentifier == bundleIdentifier else { return "Firefox" }
        return FirefoxInstallationMetadata.channel(for: app)?.sourceLabel ?? "Firefox"
    }

    public func plan(for app: ApplicationInfo) -> VendorCheckPlan? {
        guard app.bundleIdentifier == Self.bundleIdentifier else { return nil }
        let channel = FirefoxInstallationMetadata.channel(for: app)
        let installed = app.version
        return VendorCheckPlan(request: HTTPRequest(url: AppEndpoints.shared.firefoxVersionsURL, enableETag: true)) { data in
            guard let channel, let installed, channel.accepts(installed),
                  let releases = try? JSONDecoder().decode(FirefoxReleases.self, from: data),
                  let latest = releases.latest(for: channel, installed: installed), channel.accepts(latest, published: true)
            else { return .decided(.failed) }
            return .candidate(VendorCandidate(latest: latest, installed: installed,
                                              source: .firefox(channel: channel), scheme: .mozilla))
        }
    }
}

private struct FirefoxReleases: Decodable {
    let release: String?
    let beta: String?
    let esr: String?
    let nextESR: String?

    enum CodingKeys: String, CodingKey {
        case release = "LATEST_FIREFOX_VERSION"
        case beta = "LATEST_FIREFOX_RELEASED_DEVEL_VERSION"
        case esr = "FIREFOX_ESR"
        case nextESR = "FIREFOX_ESR_NEXT"
    }

    func latest(for channel: FirefoxReleaseChannel, installed: String) -> String? {
        switch channel {
        case .release: return release
        case .beta: return beta
        case .esr:
            let supported = [esr, nextESR].compactMap { $0 }.filter { channel.accepts($0, published: true) }
            let sameMajor = supported.filter { $0.split(separator: ".").first == installed.split(separator: ".").first }
            return (sameMajor.isEmpty ? supported : sameMajor).max {
                isUpgrade(installed: $0, latest: $1, scheme: .mozilla)
            }
        }
    }
}
