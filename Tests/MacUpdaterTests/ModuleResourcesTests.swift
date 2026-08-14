import Foundation
import Testing
@testable import MacUpdaterCore

/// The v0.2.0 launch crash.
///
/// `AppEndpoints.loadBundled()` and `AppCatalog.loadBundled()` both read their JSON through the
/// module's resource bundle, and both are written to *throw* when it is missing — their doc
/// comments say so and their callers handle it. `Bundle.module` broke that contract from
/// underneath: SwiftPM generates its accessor for a module linked into an executable, so it looks
/// in `Bundle.main.bundleURL` — the `.app` directory itself — and in the build directory of the
/// machine that compiled it, and calls `fatalError` when neither exists.
///
/// A packaged app keeps its resources in `Contents/Resources`, which is neither of those. So the
/// released build died three seconds after launch, on every Mac, with a message naming a path on
/// a GitHub runner — while every test passed, because under `swift test` the build directory the
/// accessor bakes in is exactly where the bundle is.
///
/// These tests pin the two properties that make that impossible to repeat: the packaged layout is
/// searched, and a genuinely missing bundle is an optional rather than the end of the process.
@Suite("Resource bundle lookup survives the packaged layout")
struct ModuleResourcesTests {

    /// Red before the fix: there was no lookup to call — the only way to ask `Bundle.module` this
    /// question was to have the process die when the answer was "no".
    @Test func findsTheBundleInsideAPackagedAppLayout() throws {
        let root = try TemporaryDirectory()
        let resources = root.url
            .appendingPathComponent("WegaMacUpdater.app/Contents/Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)

        let bundle = resources.appendingPathComponent(
            ModuleResources.bundleName + ".bundle",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: bundle.appendingPathComponent("endpoints.json"))

        let found = ModuleResources.locateBundle(searching: [resources])

        #expect(found != nil, """
            The packaged layout — App.app/Contents/Resources/\(ModuleResources.bundleName).bundle — \
            must be searched. It is where build-pkg.sh puts the bundle and where verify-bundle.sh \
            checks for it, and it is the layout every installed copy has.
            """)
    }

    /// The other half, and the one that actually killed the release: an absent bundle has to be a
    /// value the caller can react to. `loadBundled()` promises to throw; it cannot keep that
    /// promise if resolving the bundle terminates the process first.
    @Test func reportsAMissingBundleAsNilRatherThanTerminating() throws {
        let root = try TemporaryDirectory()

        let found = ModuleResources.locateBundle(searching: [root.url])

        #expect(found == nil, "a missing bundle is an answer, not a fatal error")
    }

    /// The search order has to prefer the packaged location, so a stale bundle left in a build
    /// directory cannot shadow the one that was actually shipped and signed.
    @Test func prefersTheFirstCandidateThatExists() throws {
        let root = try TemporaryDirectory()
        let preferred = root.url.appendingPathComponent("preferred", isDirectory: true)
        let fallback = root.url.appendingPathComponent("fallback", isDirectory: true)

        for base in [preferred, fallback] {
            let bundle = base.appendingPathComponent(
                ModuleResources.bundleName + ".bundle",
                isDirectory: true
            )
            try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        }

        let found = try #require(ModuleResources.locateBundle(searching: [preferred, fallback]))

        #expect(found.bundleURL.path.contains("preferred"),
                "the first candidate that exists wins, so the shipped bundle is never shadowed")
    }

    /// The lookup only helps while nothing goes back to `Bundle.module`. Reintroducing it is a
    /// one-word edit that compiles, passes every test, and breaks only the packaged app — which is
    /// the exact combination that shipped a release nobody could launch.
    @Test func noSourceFileReachesForBundleModule() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources")

        let offenders = try FileManager.default
            .subpathsOfDirectory(atPath: sources.path)
            .filter { $0.hasSuffix(".swift") }
            .filter { path in
                let contents = (try? String(
                    contentsOf: sources.appendingPathComponent(path),
                    encoding: .utf8
                )) ?? ""
                return Self.strippingComments(from: contents).contains("Bundle.module")
            }

        #expect(offenders.isEmpty, """
            \(offenders.joined(separator: ", ")) uses Bundle.module. SwiftPM's accessor searches \
            the .app directory and the build directory of the machine that compiled it, then calls \
            fatalError — so in a packaged app it terminates the process at launch. Use \
            ModuleResources.url(forResource:withExtension:), which returns nil and lets the caller \
            throw as its documentation promises.
            """)
    }

    /// Each line up to its `//`, so prose about `Bundle.module` does not read as a use of it.
    ///
    /// The first version of this guard searched whole files and flagged the two files that
    /// document why the ban exists — and since it only ever ran in CI, it did so after the tag
    /// had been cut and the release workflow was already running.
    ///
    /// Known limit: a line carrying both a `//`-bearing string literal and a real use would be
    /// truncated before the use. No line in this codebase does that, and the alternative is
    /// parsing Swift to catch a case that has never occurred.
    private static func strippingComments(from source: String) -> String {
        source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in
                guard let comment = line.range(of: "//") else { return line }
                return line[line.startIndex..<comment.lowerBound]
            }
            .joined(separator: "\n")
    }
}
