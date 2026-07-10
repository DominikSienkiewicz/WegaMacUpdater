import Foundation

public struct BrewInfoParser {
    private let decoder: JSONDecoder

    public init(decoder: JSONDecoder = JSONDecoder()) {
        self.decoder = decoder
    }

    public func parseCaskInstallations(_ data: Data) throws -> [BrewCaskInstallationInfo] {
        try parseCaskArtifactProfiles(data).map {
            BrewCaskInstallationInfo(token: $0.token, appArtifacts: $0.appArtifacts)
        }
    }

    public func parseCaskInstallations(_ json: String) throws -> [BrewCaskInstallationInfo] {
        try parseCaskInstallations(Data(json.utf8))
    }

    // MARK: - Cask artifact profiles + homepage (shared prerequisite for F1/F2/F3)

    /// Full artifact picture per cask from `brew info --cask --json=v2`: homepage
    /// plus every declared artifact stanza (`app`, `binary`, `zap`, `pkg`,
    /// `installer`, `preflight`, and any other stanza preserved verbatim). This is
    /// the model F2 ("may need admin password") and F3 (eligibility) reason over.
    public func parseCaskArtifactProfiles(_ data: Data) throws -> [CaskArtifactProfile] {
        let response = try decoder.decode(BrewInfoResponse.self, from: data)
        return response.casks.map {
            CaskArtifactProfile(token: $0.token, homepage: $0.homepage, artifacts: $0.artifacts)
        }
    }

    public func parseCaskArtifactProfiles(_ json: String) throws -> [CaskArtifactProfile] {
        try parseCaskArtifactProfiles(Data(json.utf8))
    }

    // MARK: - Download transparency (FEAT-03)

    /// Extracts download URL + checksum per cask from `brew info --cask --json=v2`.
    public func parseDownloadInfo(_ data: Data) throws -> [CaskDownloadInfo] {
        let response = try decoder.decode(BrewDownloadResponse.self, from: data)
        return response.casks.map { CaskDownloadInfo(token: $0.token, url: $0.url, sha256: $0.sha256) }
    }

    public func parseDownloadInfo(_ json: String) throws -> [CaskDownloadInfo] {
        try parseDownloadInfo(Data(json.utf8))
    }

    // MARK: - Installed versions (DEBT-05, robust JSON alternative)

    /// Token→installed-version map from `brew info --installed --json=v2` — a
    /// structured replacement for parsing `brew list --cask --versions` text.
    public func parseInstalledVersions(_ data: Data) throws -> [String: String] {
        let response = try decoder.decode(BrewInstalledResponse.self, from: data)
        return response.casks.reduce(into: [:]) { dict, cask in
            if let version = cask.installed, !version.isEmpty { dict[cask.token] = version }
        }
    }

    public func parseInstalledVersions(_ json: String) throws -> [String: String] {
        try parseInstalledVersions(Data(json.utf8))
    }
}

private struct BrewInstalledResponse: Decodable {
    var casks: [BrewInstalledCask]
    private enum CodingKeys: String, CodingKey { case casks }
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        casks = try container.decodeIfPresent([BrewInstalledCask].self, forKey: .casks) ?? []
    }
}

private struct BrewInstalledCask: Decodable {
    var token: String
    var installed: String?
}

private struct BrewDownloadResponse: Decodable {
    var casks: [BrewDownloadCask]

    private enum CodingKeys: String, CodingKey { case casks }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        casks = try container.decodeIfPresent([BrewDownloadCask].self, forKey: .casks) ?? []
    }
}

private struct BrewDownloadCask: Decodable {
    var token: String
    var url: String?
    var sha256: String?
}

private struct BrewInfoResponse: Decodable {
    var casks: [BrewInfoCask]

    private enum CodingKeys: String, CodingKey {
        case casks
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        casks = try container.decodeIfPresent([BrewInfoCask].self, forKey: .casks) ?? []
    }
}

private struct BrewInfoCask: Decodable {
    var token: String
    var homepage: String?
    var artifacts: [CaskArtifact]

    private enum CodingKeys: String, CodingKey {
        case token
        case homepage
        case artifacts
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        token = try container.decode(String.self, forKey: .token)
        homepage = try container.decodeIfPresent(String.self, forKey: .homepage)
        let raw = try container.decodeIfPresent([BrewArtifact].self, forKey: .artifacts) ?? []
        artifacts = raw.flatMap(\.artifacts)
    }
}

/// One element of a cask's `artifacts` array. In `brew info --json=v2` each
/// element is a single-key object (`{ "app": [...] }`, `{ "preflight": {} }`);
/// this decoder reads whatever key(s) it carries dynamically so no stanza is lost.
private struct BrewArtifact: Decodable {
    var artifacts: [CaskArtifact]

    private struct DynamicKey: CodingKey {
        var stringValue: String
        var intValue: Int?
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { self.intValue = intValue; self.stringValue = "\(intValue)" }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicKey.self)
        artifacts = container.allKeys.map { key in
            let names = (try? container.decode(ArtifactNames.self, forKey: key))?.names ?? []
            return CaskArtifact(kind: CaskArtifactKind(rawKey: key.stringValue), names: names)
        }
    }
}

/// Best-effort extraction of concrete target names from an artifact stanza value.
/// Handles the string / `[string]` / `[{ "target": … }]` shapes Homebrew emits;
/// anything else (hook bodies serialised as `{}` or `null`) yields no names.
private enum ArtifactNames: Decodable {
    case strings([String])

    var names: [String] {
        switch self {
        case .strings(let strings):
            return strings
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if let string = try? container.decode(String.self) {
            self = .strings([string])
            return
        }

        if let strings = try? container.decode([String].self) {
            self = .strings(strings)
            return
        }

        if let objects = try? container.decode([ArtifactObject].self) {
            self = .strings(objects.compactMap(\.target))
            return
        }

        self = .strings([])
    }
}

private struct ArtifactObject: Decodable {
    var target: String?
}
