import Foundation

public enum ThunderbirdReleaseChannel: String, Codable, Sendable {
    case release, esr, beta

    public var label: String {
        switch self {
        case .release: "Release"
        case .esr: "ESR"
        case .beta: "Beta"
        }
    }

    var caskToken: String {
        switch self {
        case .release: "thunderbird"
        case .esr: "thunderbird@esr"
        case .beta: "thunderbird@beta"
        }
    }

    func acceptsInstalledVersion(_ version: String) -> Bool {
        guard let parsed = MozillaReleaseVersion(version) else { return false }
        switch self {
        case .release: return parsed.beta == nil && !version.hasSuffix("esr")
        case .esr: return parsed.beta == nil
        case .beta: return parsed.beta != nil
        }
    }
}

public enum ThunderbirdInstallationChannel {
    public static func read(at appPath: URL) -> ThunderbirdReleaseChannel? {
        let resources = appPath.appendingPathComponent("Contents/Resources")
        let remoting = text(at: resources.appendingPathComponent("application.ini")).flatMap(remotingName(in:))
        let channelPreference = text(at: resources.appendingPathComponent("defaults/pref/channel-prefs.js")).flatMap(preference(in:))
        let modern = remoting.flatMap { name -> ThunderbirdReleaseChannel? in
            switch name {
            case "thunderbird": .release
            case "thunderbird-esr": .esr
            case "thunderbird-beta": .beta
            default: nil
            }
        }
        let legacy = channelPreference.flatMap(ThunderbirdReleaseChannel.init(rawValue:))
        guard remoting == nil || modern != nil, channelPreference == nil || legacy != nil,
              modern == nil || legacy == nil || modern == legacy else { return nil }
        return modern ?? legacy
    }

    public static func permitsCask(_ token: String, for app: ApplicationInfo) -> Bool {
        guard ThunderbirdUpdateChecker.recognizes(app) else { return true }
        guard let channel = read(at: app.path), let version = app.version,
              channel.acceptsInstalledVersion(version) else { return false }
        return channel.caskToken == token
    }

    private static func text(at url: URL) -> String? {
        guard let data = try? Data(contentsOf: url), data.count <= 65_536 else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func remotingName(in text: String) -> String? {
        var inApp = false
        var names: [String] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                inApp = line == "[App]"
            } else if inApp, !line.hasPrefix(";"), !line.hasPrefix("#") {
                let pair = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                if pair.count == 2, pair[0].trimmingCharacters(in: .whitespaces) == "RemotingName" {
                    names.append(pair[1].trimmingCharacters(in: .whitespaces))
                }
            }
        }
        return names.count > 1 ? "" : names.first
    }

    private static func preference(in text: String) -> String? {
        let uncommented = text.replacingOccurrences(of: #"(?s)/\*.*?\*/"#, with: "", options: .regularExpression)
        let pattern = #"(?m)^\s*pref\(\s*["']app\.update\.channel["']\s*,\s*["']([^"']+)["']\s*\)\s*;\s*(?://[^\r\n]*)?$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let matches = regex.matches(in: uncommented, range: NSRange(uncommented.startIndex..., in: uncommented))
        guard matches.count == 1, let match = matches.first,
              let range = Range(match.range(at: 1), in: uncommented) else { return matches.isEmpty ? nil : "" }
        return String(uncommented[range])
    }
}

public struct ThunderbirdUpdateChecker: VendorUpdateChecker {
    public static let bundleIdentifiers: Set<String> = ["org.mozilla.thunderbird", "org.mozilla.thunderbirdbeta"]
    public let client: HTTPClient
    private let readChannel: @Sendable (URL) -> ThunderbirdReleaseChannel?

    public init(
        client: HTTPClient = .shared,
        readChannel: @escaping @Sendable (URL) -> ThunderbirdReleaseChannel? = ThunderbirdInstallationChannel.read
    ) {
        self.client = client
        self.readChannel = readChannel
    }

    public func plan(for app: ApplicationInfo) -> VendorCheckPlan? {
        guard Self.recognizes(app), let installed = app.version,
              let channel = readChannel(app.path), channel.acceptsInstalledVersion(installed) else { return nil }
        return VendorCheckPlan(request: HTTPRequest(url: AppEndpoints.shared.thunderbirdVersionsURL, enableETag: true)) { data in
            guard let versions = try? JSONDecoder().decode([String: String].self, from: data),
                  let latest = Self.latestVersion(in: versions, channel: channel, installed: installed) else {
                return .decided(.failed)
            }
            return .candidate(VendorCandidate(latest: latest, installed: installed,
                                              source: .thunderbird(channel: channel), scheme: .mozilla))
        }
    }

    public func check(app: ApplicationInfo) async -> ManualCheckResult {
        guard Self.recognizes(app) else { return .notApplicable }
        guard let plan = plan(for: app) else {
            UpdateDiagnostics.record("vendor.completed", fields: [
                "checker": "ThunderbirdUpdateChecker", "outcome": "unavailable",
                "bundleIdentifier": app.bundleIdentifier ?? "unknown", "reason": "unknown_channel_or_version"
            ])
            return .unavailable
        }
        return await check(app: app, plan: plan)
    }

    public static func recognizes(_ app: ApplicationInfo) -> Bool {
        app.bundleIdentifier.map(bundleIdentifiers.contains) ?? false
    }

    private static func latestVersion(in versions: [String: String], channel: ThunderbirdReleaseChannel, installed: String) -> String? {
        switch channel {
        case .release:
            guard let version = versions["LATEST_THUNDERBIRD_VERSION"], channel.acceptsInstalledVersion(version) else { return nil }
            return version
        case .beta:
            guard let version = versions["LATEST_THUNDERBIRD_DEVEL_VERSION"], channel.acceptsInstalledVersion(version) else { return nil }
            return version
        case .esr:
            guard let current = versions["THUNDERBIRD_ESR"], current.hasSuffix("esr"),
                  channel.acceptsInstalledVersion(current) else { return nil }
            let next = versions["THUNDERBIRD_ESR_NEXT"].flatMap { value in
                value.hasSuffix("esr") && channel.acceptsInstalledVersion(value) ? value : nil
            }
            let installedMajor = MozillaReleaseVersion(installed)?.components.first
            return [current, next].compactMap { $0 }
                .first { MozillaReleaseVersion($0)?.components.first == installedMajor } ?? current
        }
    }
}
