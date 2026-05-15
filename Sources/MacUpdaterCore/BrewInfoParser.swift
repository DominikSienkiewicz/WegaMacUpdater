import Foundation

public struct BrewInfoParser {
    private let decoder: JSONDecoder

    public init(decoder: JSONDecoder = JSONDecoder()) {
        self.decoder = decoder
    }

    public func parseCaskInstallations(_ data: Data) throws -> [BrewCaskInstallationInfo] {
        let response = try decoder.decode(BrewInfoResponse.self, from: data)
        return response.casks.map {
            BrewCaskInstallationInfo(token: $0.token, appArtifacts: $0.appArtifacts)
        }
    }

    public func parseCaskInstallations(_ json: String) throws -> [BrewCaskInstallationInfo] {
        try parseCaskInstallations(Data(json.utf8))
    }
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
    var appArtifacts: [String]

    private enum CodingKeys: String, CodingKey {
        case token
        case artifacts
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        token = try container.decode(String.self, forKey: .token)
        let artifacts = try container.decodeIfPresent([BrewArtifact].self, forKey: .artifacts) ?? []
        appArtifacts = artifacts.flatMap(\.apps)
    }
}

private struct BrewArtifact: Decodable {
    var apps: [String]

    private enum CodingKeys: String, CodingKey {
        case app
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        apps = try container.decodeIfPresent(AppArtifactValue.self, forKey: .app)?.apps ?? []
    }
}

private enum AppArtifactValue: Decodable {
    case strings([String])

    var apps: [String] {
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

        if let objects = try? container.decode([AppArtifactObject].self) {
            self = .strings(objects.compactMap(\.target))
            return
        }

        self = .strings([])
    }
}

private struct AppArtifactObject: Decodable {
    var target: String?
}
