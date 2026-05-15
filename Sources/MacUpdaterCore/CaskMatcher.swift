import Foundation

public enum CaskMatch: Equatable, Sendable {
    case managed(token: String)
    case candidate(token: String)
    case none
}

public struct CaskMatcher {
    private let customMappings: [String: String]

    public init(customMappings: [String: String] = MacUpdaterConstants.customCaskMappings) {
        self.customMappings = customMappings
    }

    public func match(
        applicationName: String,
        installedCasks: Set<String>,
        availableCasks: [BrewCask]
    ) -> CaskMatch {
        let normalizedName = StringNormalizer.normalize(applicationName)
        let normalizedInstalledCasks = installedCasks.reduce(into: [String: String]()) { partial, token in
            partial[StringNormalizer.normalize(token), default: token] = token
        }

        if let installedToken = normalizedInstalledCasks[normalizedName] {
            return .managed(token: installedToken)
        }

        let matchedToken = customMappings[applicationName] ?? availableCasks.first { cask in
            StringNormalizer.normalize(cask.token) == normalizedName ||
                cask.name.contains { StringNormalizer.normalize($0) == normalizedName }
        }?.token

        guard let matchedToken else {
            return .none
        }

        if installedCasks.contains(matchedToken) {
            return .managed(token: matchedToken)
        }

        if let installedToken = normalizedInstalledCasks[StringNormalizer.normalize(matchedToken)] {
            return .managed(token: installedToken)
        }

        return .candidate(token: matchedToken)
    }
}
