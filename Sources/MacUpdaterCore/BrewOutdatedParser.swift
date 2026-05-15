import Foundation

public struct BrewOutdatedParser {
    private let decoder: JSONDecoder

    public init(decoder: JSONDecoder = JSONDecoder()) {
        self.decoder = decoder
    }

    public func parse(_ data: Data) throws -> BrewOutdated {
        let response = try decoder.decode(BrewOutdatedResponse.self, from: data)
        return BrewOutdated(
            formulae: response.formulae.map(\.item),
            casks: response.casks.map(\.item)
        )
    }

    public func parse(_ json: String) throws -> BrewOutdated {
        try parse(Data(json.utf8))
    }
}

private struct BrewOutdatedResponse: Decodable {
    var formulae: [BrewOutdatedPayload]
    var casks: [BrewOutdatedPayload]

    private enum CodingKeys: String, CodingKey {
        case formulae
        case casks
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        formulae = try container.decodeIfPresent([BrewOutdatedPayload].self, forKey: .formulae) ?? []
        casks = try container.decodeIfPresent([BrewOutdatedPayload].self, forKey: .casks) ?? []
    }
}

private struct BrewOutdatedPayload: Decodable {
    var name: String
    var installedVersions: [String]
    var currentVersion: String?
    var pinned: Bool?
    var autoUpdates: Bool?

    var item: BrewOutdatedItem {
        BrewOutdatedItem(
            name: name,
            installedVersions: installedVersions,
            currentVersion: currentVersion,
            pinned: pinned,
            autoUpdates: autoUpdates
        )
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case installedVersions = "installed_versions"
        case currentVersion = "current_version"
        case pinned
        case autoUpdates = "auto_updates"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        installedVersions = try container.decodeFlexibleStringArray(forKey: .installedVersions)
        currentVersion = try container.decodeIfPresent(String.self, forKey: .currentVersion)
        pinned = try container.decodeIfPresent(Bool.self, forKey: .pinned)
        autoUpdates = try container.decodeIfPresent(Bool.self, forKey: .autoUpdates)
    }
}

private extension KeyedDecodingContainer {
    func decodeFlexibleStringArray(forKey key: Key) throws -> [String] {
        if let strings = try? decode([String].self, forKey: key) {
            return strings
        }

        if let string = try? decode(String.self, forKey: key) {
            return [string]
        }

        return []
    }
}
