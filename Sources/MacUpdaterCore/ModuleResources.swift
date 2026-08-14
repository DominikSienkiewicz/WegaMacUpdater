import Foundation

/// Locates `MacUpdaterCore`'s SwiftPM resource bundle — `endpoints.json` and `app-catalog.json`.
///
/// This exists instead of `Bundle.module`, which cannot be used from a packaged application.
/// SwiftPM generates that accessor for a module linked into an executable, so it searches
/// `Bundle.main.bundleURL` — the `.app` directory itself — and the build directory of whichever
/// machine compiled the binary, then calls `fatalError`. A packaged app keeps its resources in
/// `Contents/Resources`, which is neither, so the accessor terminated the process on launch while
/// passing every test: under `swift test` the baked-in build directory is exactly where the
/// bundle is.
///
/// The failure mode mattered as much as the location. `AppEndpoints.loadBundled()` and
/// `AppCatalog.loadBundled()` are both written to throw when the resource is missing, and their
/// callers handle that — but a `fatalError` is not an error to be handled, and it ran before
/// their `guard` could. Resolution therefore yields an optional and nothing here traps.
enum ModuleResources {

    /// `<package>_<target>`, the name SwiftPM gives the bundle. `build-pkg.sh` copies it under
    /// this name and `verify-bundle.sh` checks for it under this name; a mismatch would put the
    /// resources in the app while making them unreachable, which is precisely what happened here.
    static let bundleName = "WegaMacUpdater_MacUpdaterCore"

    /// Directories that may hold the bundle, most authoritative first, so a stale copy in a build
    /// directory can never shadow the one that was shipped and signed.
    private static var searchPaths: [URL] {
        let token = Bundle(for: BundleToken.self)
        return [
            Bundle.main.resourceURL,                        // packaged .app: Contents/Resources
            token.resourceURL,                              // framework or test bundle
            token.bundleURL.deletingLastPathComponent(),    // alongside the test binary
            Bundle.main.bundleURL                           // SwiftPM's executable layout
        ].compactMap { $0 }
    }

    /// The first of `candidates` that actually contains the bundle, or `nil` if none does.
    /// Exposed for tests, which build the layouts on disk rather than describing them.
    static func locateBundle(searching candidates: [URL]) -> Bundle? {
        for directory in candidates {
            let candidate = directory.appendingPathComponent(bundleName + ".bundle", isDirectory: true)
            if let bundle = Bundle(url: candidate) { return bundle }
        }
        return nil
    }

    /// A resource shipped inside the module's bundle, or `nil` when it cannot be found.
    /// The URL is resolved on each call; `Bundle` caches its own instances, so this stays cheap
    /// while keeping no non-Sendable state of our own.
    static func url(forResource resource: String, withExtension ext: String) -> URL? {
        locateBundle(searching: searchPaths)?.url(forResource: resource, withExtension: ext)
    }
}

/// Anchors `Bundle(for:)` to this module rather than to whoever calls it.
private final class BundleToken {}
