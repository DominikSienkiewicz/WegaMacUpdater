import Testing
import Foundation
@testable import MacUpdaterCore

/// `JetBrainsUpdateChecker` drives 14 IDEs and had no dedicated test. These exercise
/// the full async `check(app:)` flow through the injected `HTTPClient` seam (a fake
/// transport — no network), covering the four `ManualCheckResult` outcomes plus the
/// "checker doesn't apply" guards.
@Suite("JetBrainsUpdateChecker")
struct JetBrainsUpdateCheckerTests {
    private let bundleID = "com.jetbrains.intellij"
    private let code = "IIU"

    private var products: [String: JetBrainsCatalogEntry] {
        [bundleID: JetBrainsCatalogEntry(bundleId: bundleID, code: code, caskToken: "intellij-idea")]
    }

    /// JetBrains' releases endpoint returns `{ "<code>": [ { "version": "…" }, … ] }`.
    private func feed(version: String) -> String {
        #"{"\#(code)":[{"version":"\#(version)"}]}"#
    }

    private func app(bundleID: String?, version: String?) -> ApplicationInfo {
        ApplicationInfo(
            path: URL(fileURLWithPath: "/Applications/IntelliJ IDEA.app"),
            name: "IntelliJ IDEA",
            bundleIdentifier: bundleID,
            version: version,
            installDate: nil,
            updateDate: nil,
            isManagedByBrew: false
        )
    }

    private func checker(_ client: HTTPClient) -> JetBrainsUpdateChecker {
        JetBrainsUpdateChecker(client: client, products: products)
    }

    @Test func outdatedWhenFeedHasNewerVersion() async {
        let result = await checker(FakeHTTP.client(ok: feed(version: "2026.1.2")))
            .check(app: app(bundleID: bundleID, version: "2026.1.1"))

        guard case .outdated(let outdated) = result else {
            Issue.record("expected .outdated, got \(result)"); return
        }
        #expect(outdated.availableVersion == "2026.1.2")
        #expect(outdated.installedVersion == "2026.1.1")
        #expect(outdated.source == .jetbrains(caskToken: "intellij-idea"))
    }

    @Test func upToDateWhenInstalledMatchesFeed() async {
        let result = await checker(FakeHTTP.client(ok: feed(version: "2026.1.2")))
            .check(app: app(bundleID: bundleID, version: "2026.1.2"))
        #expect(result == .upToDate)
    }

    // An app the checker doesn't know about must short-circuit to .notApplicable
    // *before* any network call — a fake that would 500 proves no request is made.
    @Test func notApplicableForUnknownBundleID() async {
        let result = await checker(FakeHTTP.client(status: 500))
            .check(app: app(bundleID: "com.unknown.app", version: "1.0"))
        #expect(result == .notApplicable)
    }

    // A known app with no readable installed version can't be compared — .notApplicable,
    // never a false .outdated/.upToDate.
    @Test func notApplicableWhenInstalledVersionMissing() async {
        let result = await checker(FakeHTTP.client(ok: feed(version: "2026.1.2")))
            .check(app: app(bundleID: bundleID, version: ""))
        #expect(result == .notApplicable)
    }

    // A 5xx server error means the source is temporarily silent — .unavailable
    // (transient upstream outage), not .failed. Not a silent "up to date" either.
    @Test func unavailableWhenServerErrors() async {
        let result = await checker(FakeHTTP.client(status: 503))
            .check(app: app(bundleID: bundleID, version: "2026.1.1"))
        #expect(result == .unavailable)
    }

    @Test func failedOnMalformedJSON() async {
        let result = await checker(FakeHTTP.client(ok: "<<not json>>"))
            .check(app: app(bundleID: bundleID, version: "2026.1.1"))
        #expect(result == .failed)
    }
}
