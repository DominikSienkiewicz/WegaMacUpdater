import Foundation

public struct JetBrainsUpdateChecker: Sendable {
    private let session: URLSession

    private static let products: [String: (code: String, caskToken: String)] = [
        "com.jetbrains.intellij":    (code: "IIU", caskToken: "intellij-idea"),
        "com.jetbrains.intellij.ce": (code: "IIC", caskToken: "intellij-idea-ce"),
        "com.jetbrains.pycharm":     (code: "PCP", caskToken: "pycharm"),
        "com.jetbrains.pycharm.ce":  (code: "PCC", caskToken: "pycharm-ce"),
        "com.jetbrains.webstorm":    (code: "WS",  caskToken: "webstorm"),
        "com.jetbrains.goland":      (code: "GO",  caskToken: "goland"),
        "com.jetbrains.clion":       (code: "CL",  caskToken: "clion"),
        "com.jetbrains.rider":       (code: "RD",  caskToken: "rider"),
        "com.jetbrains.datagrip":    (code: "DG",  caskToken: "datagrip"),
        "com.jetbrains.rubymine":    (code: "RM",  caskToken: "rubymine"),
        "com.jetbrains.phpstorm":    (code: "PS",  caskToken: "phpstorm"),
        "com.jetbrains.dataspell":   (code: "DS",  caskToken: "dataspell"),
        "com.jetbrains.aqua":        (code: "QA",  caskToken: "aqua"),
        "com.jetbrains.rustrover":   (code: "RR",  caskToken: "rustrover"),
    ]

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func check(app: ApplicationInfo) async -> ManualOutdatedApp? {
        guard let bundleId = app.bundleIdentifier,
              let product = Self.products[bundleId] else { return nil }

        let urlString = "https://data.services.jetbrains.com/products/releases?code=\(product.code)&latest=true&type=release"
        guard let url = URL(string: urlString) else { return nil }

        var request = URLRequest(url: url)
        request.cachePolicy = .reloadRevalidatingCacheData

        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let releases = try? JSONDecoder().decode([String: [JetBrainsRelease]].self, from: data),
              let latest = releases[product.code]?.first?.version else { return nil }

        let installed = app.version ?? ""
        guard !installed.isEmpty, isUpgrade(installed: installed, latest: latest) else { return nil }

        return ManualOutdatedApp(
            name: app.name,
            path: app.path,
            installedVersion: app.version,
            availableVersion: latest,
            source: .jetbrains(caskToken: product.caskToken)
        )
    }
}

private struct JetBrainsRelease: Decodable {
    let version: String
}
