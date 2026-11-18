import AppKit

/// Resolves artwork in both signed app bundles and SwiftPM's development layout.
/// `Bundle.module` traps when its build-machine path is absent from a packaged app.
enum WegaBrandAsset {
    private static let bundleName = "WegaMacUpdater_WegaMacUpdater"

    @MainActor
    static let image: NSImage? = artworkURL.flatMap { NSImage(contentsOf: $0) }

    private static var artworkURL: URL? {
        let token = Bundle(for: WegaBrandBundleToken.self)
        let directories = [
            Bundle.main.resourceURL,
            token.resourceURL,
            token.bundleURL.deletingLastPathComponent(),
            Bundle.main.bundleURL,
        ].compactMap { $0 }

        for directory in directories {
            let url = directory.appendingPathComponent(bundleName + ".bundle", isDirectory: true)
            if let bundle = Bundle(url: url) {
                return bundle.url(forResource: "WegaAppIcon", withExtension: "png")
            }
        }
        return nil
    }
}

private final class WegaBrandBundleToken {}
