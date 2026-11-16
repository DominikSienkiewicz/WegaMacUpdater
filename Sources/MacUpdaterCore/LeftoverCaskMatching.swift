import Foundation

public enum LeftoverCaskMatching {
    public static func evidence(
        for apps: [ApplicationInfo],
        casks: [BrewCask],
        matcher: CaskMatcher = CaskMatcher()
    ) -> [String: LeftoverCaskEvidence] {
        let zapPathsByToken = casks.reduce(into: [String: [String]]()) { partial, cask in
            partial[cask.token] = partial[cask.token] ?? cask.zapTrashPaths
        }
        let index = matcher.makeIndex(installedCasks: [], availableCasks: casks)
        var evidence: [String: LeftoverCaskEvidence] = [:]
        for app in apps {
            guard let (token, provenance) = tokenAndProvenance(for: app, matcher: matcher, index: index),
                  CaskChannelPolicy.permits(token, for: app),
                  let zapTrashPaths = zapPathsByToken[token]
            else { continue }
            evidence[app.id] = LeftoverCaskEvidence(token: token, zapTrashPaths: zapTrashPaths, provenance: provenance)
        }
        return evidence
    }

    private static func tokenAndProvenance(
        for app: ApplicationInfo,
        matcher: CaskMatcher,
        index: CaskMatcher.Index
    ) -> (String, CaskMatchProvenance)? {
        if let token = app.caskToken {
            return (token, app.caskMatchProvenance ?? .token)
        }
        let match = matcher.match(applicationName: app.name, bundleIdentifier: app.bundleIdentifier, using: index)
        guard let token = match.token, let provenance = match.provenance else { return nil }
        return (token, provenance)
    }
}

public extension LeftoverApp {
    init(_ app: ApplicationInfo, teamIdentifier: String?, cask: LeftoverCaskEvidence?) {
        self.init(
            id: app.id,
            name: app.name,
            fileName: app.path.deletingPathExtension().lastPathComponent,
            path: (app.path.path as NSString).abbreviatingWithTildeInPath,
            bundleIdentifier: app.bundleIdentifier,
            teamIdentifier: teamIdentifier,
            cask: cask
        )
    }
}
