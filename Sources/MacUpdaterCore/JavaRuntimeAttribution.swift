import Foundation

/// Receipt-backed JDK attribution for scan evidence, separate from app-bundle rollback paths.
struct JavaRuntimeAttribution: Sendable {
    let runtimes: [ApplicationInfo]
    let managedPaths: [String: URL]

    init(
        runtimes: [ApplicationInfo], packageIdentifiers: [InstallationIdentity: Set<String>],
        casks: [BrewCask], installedCasks: Set<String>, brewTrackedTokens: Set<String>
    ) {
        let claims = casks.reduce(into: [String: Set<String>]()) { result, cask in
            for identifier in cask.pkgutilIdentifiers { result[identifier, default: []].insert(cask.token) }
        }
        let claimedTokens = runtimes.map { runtime in
            (packageIdentifiers[runtime.installation] ?? []).reduce(into: Set<String>()) { tokens, identifier in
                tokens.formUnion(claims[identifier] ?? [])
            }
        }
        let tokens = runtimes.map { runtime -> String? in
            guard let identifiers = packageIdentifiers[runtime.installation], !identifiers.isEmpty,
                  let version = runtime.version, !version.isEmpty else { return nil }
            var matches = Set<String>()
            for identifier in identifiers {
                guard let candidates = claims[identifier], candidates.count == 1,
                      let token = candidates.first else { return nil }
                matches.insert(token)
            }
            guard matches.count == 1, let token = matches.first,
                  Self.matchesMajor(version: version, token: token) else { return nil }
            return token
        }
        let copies = Dictionary(grouping: claimedTokens.flatMap { $0 }, by: { $0 })
        var paths: [String: URL] = [:]
        self.runtimes = zip(runtimes, tokens).map { runtime, token in
            var attributed = runtime
            attributed.caskToken = nil
            attributed.isManagedByBrew = false
            guard let token, copies[token]?.count == 1 else { return attributed }
            attributed.caskToken = token
            attributed.isManagedByBrew = installedCasks.contains(token)
            if attributed.isManagedByBrew, brewTrackedTokens.contains(token) { paths[token] = runtime.path }
            return attributed
        }
        managedPaths = paths
    }

    private static func matchesMajor(version: String, token: String) -> Bool {
        guard let suffix = token.split(separator: "@").dropFirst().first,
              let expected = Int(suffix.prefix(while: { $0.isNumber })) else { return true }
        let components = version.split(whereSeparator: { !$0.isNumber })
        guard let first = components.first.flatMap({ Int($0) }) else { return false }
        let major = first == 1 ? components.dropFirst().first.flatMap { Int($0) } : first
        return major == expected
    }
}
