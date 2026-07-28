import Testing
import Foundation
@testable import MacUpdaterCore

private final class FakeTransport: HTTPTransport, @unchecked Sendable {
    struct Stub { let data: Data; let status: Int; let headers: [String: String] }
    private let lock = NSLock()
    private var queue: [Stub]
    private(set) var count = 0
    init(_ stubs: [Stub]) { queue = stubs }
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let stub: Stub = lock.withLock {
            count += 1
            return queue.isEmpty ? Stub(data: Data(), status: 200, headers: [:]) : queue.removeFirst()
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: stub.status, httpVersion: nil, headerFields: stub.headers)!
        return (stub.data, response)
    }
}

@Suite("P1Backends")
struct P1BackendsTests {

    // MARK: SEC-05 — GitHub primary rate-limit (403 + remaining 0) jest retry'owany

    @Test func retriesOn403PrimaryRateLimitThenSucceeds() async throws {
        let transport = FakeTransport([
            .init(data: Data(), status: 403, headers: ["X-RateLimit-Remaining": "0"]),
            .init(data: Data("ok".utf8), status: 200, headers: [:]),
        ])
        let client = HTTPClient(transport: transport, maxRetries: 2, retryBaseDelay: 0)
        let response = try await client.get(URL(string: "https://api.github.com/x")!)
        #expect(response.statusCode == 200)
        #expect(transport.count == 2)
    }

    @Test func doesNotRetryPlain403() async throws {
        let transport = FakeTransport([.init(data: Data(), status: 403, headers: [:])])
        let client = HTTPClient(transport: transport, maxRetries: 2, retryBaseDelay: 0)
        let response = try await client.get(URL(string: "https://api.github.com/x")!)
        #expect(response.statusCode == 403)
        #expect(transport.count == 1) // 403 bez nagłówka limitu = definitywny
    }

    // MARK: SEC-04 — podpis fail-closed + DBT-5 guard

    /// Was: `#expect(CatalogSignature.isConfigured == false) // placeholder w repo`, which
    /// pinned a fact about the repository rather than about the code. Once a real publisher
    /// key ships, that fact is false by design — so the unconfigured verifier is now built
    /// explicitly, and the assertion says what it always meant: no key, no verification.
    @Test func catalogSignatureUnconfiguredFailsClosed() {
        let unconfigured = CatalogSignature(publicKeyBase64: CatalogSignature.unconfiguredPlaceholder)
        #expect(unconfigured.isConfigured == false)
        #expect(unconfigured.verify(data: Data("x".utf8), signatureBase64: "AAAA") == false)
    }

    @Test func overlayKeepsBaselineOnInvalidFixedURLButAppliesTemplates() throws {
        let base = try AppEndpoints.loadBundled()
        let overlay = AppEndpointsOverlay(
            jetbrainsReleases: nil, chatgptAppcast: nil, googleDriveOmaha: nil,
            caskDatabase: "ma spacje i nie jest url", appCatalog: nil,
            githubLatestRelease: "https://example.test/{repo}", synologyChangeLog: nil,
            antigravityUpdate: nil, parallelsUpdates: nil, postmanUpdate: nil,
            discordUpdate: nil, signalUpdate: nil, chromeVersions: nil, homebrewWebsite: nil,
            homebrewInstallCommand: nil, githubReleasesPage: nil, googleDriveDownload: nil,
            projectRepository: nil, projectIssues: nil, authorLinkedIn: nil, masRepository: nil
        )
        let merged = base.overlaying(overlay)
        #expect(merged.caskDatabase == base.caskDatabase)                 // zły URL → baseline (DBT-5)
        // SEC-08 zaostrzyło szablony: nadpisanie musi być https ORAZ trafiać na host, z którym
        // baseline już rozmawia. `example.test` jest poza allowlistą, więc baseline zostaje —
        // wcześniej ten sam wpis przechodził, bo sprawdzana była tylko składnia URL-a.
        #expect(merged.githubLatestRelease == base.githubLatestRelease)
    }

    /// Druga połowa kontraktu SEC-08: zaostrzenie nie może zabić samego mechanizmu overlaya —
    /// nadpisanie szablonu na hoście z allowlisty ma nadal działać.
    @Test func overlayAppliesATemplateOverrideOnAnAllowlistedHost() throws {
        let base = try AppEndpoints.loadBundled()
        let onAllowlist = "https://api.github.com/repos/{repo}/releases/latest?per_page=1"
        let overlay = AppEndpointsOverlay(
            jetbrainsReleases: nil, chatgptAppcast: nil, googleDriveOmaha: nil,
            caskDatabase: nil, appCatalog: nil,
            githubLatestRelease: onAllowlist, synologyChangeLog: nil,
            antigravityUpdate: nil, parallelsUpdates: nil, postmanUpdate: nil,
            discordUpdate: nil, signalUpdate: nil, chromeVersions: nil, homebrewWebsite: nil,
            homebrewInstallCommand: nil, githubReleasesPage: nil, googleDriveDownload: nil,
            projectRepository: nil, projectIssues: nil, authorLinkedIn: nil, masRepository: nil
        )

        #expect(base.overlaying(overlay).githubLatestRelease == onAllowlist)
    }

    // MARK: FEAT-03 — transparentność (host + checksum vs no_check)

    @Test func parsesDownloadTransparency() throws {
        let json = """
        {"casks":[
          {"token":"signed-app","url":"https://dl.example.com/a.dmg","sha256":"abc123def456"},
          {"token":"auto-app","url":"https://updates.example.org/b.zip","sha256":"no_check"}
        ]}
        """
        let infos = try BrewInfoParser().parseDownloadInfo(json)
        let signed = try #require(infos.first { $0.token == "signed-app" })
        let auto = try #require(infos.first { $0.token == "auto-app" })
        #expect(signed.hasChecksum == true)
        #expect(signed.host == "dl.example.com")
        #expect(auto.hasChecksum == false)            // no_check → instalacja bez weryfikacji
        #expect(auto.host == "updates.example.org")
    }

    // MARK: FEAT-02 — scoring confidence dopasowania

    /// LT-03 (follow-up) — the same signal ladder, now expressed as the route the matcher
    /// took rather than as strings the caller re-scores. Every band this case pinned is still
    /// here; the "tylko fuzzy" row moved to `CaskMatchScorer.unmatched`, because a match too
    /// weak to be found is not a weak match — it is no match, and `CaskMatcher` returns
    /// `.none` for it.
    @Test func confidenceScoringBySignalStrength() {
        #expect(CaskMatchScorer.score(provenance: .token) == .high)                  // token exact
        #expect(CaskMatchScorer.score(provenance: .installedToken) == .high)         // already a cask
        #expect(CaskMatchScorer.score(provenance: .displayName) == .medium)          // name exact
        #expect(CaskMatchScorer.unmatched == .low)                                   // tylko fuzzy
        #expect(CaskMatchScorer.score(provenance: .curatedMapping) == .high)         // curated
        #expect(CaskMatchScorer.score(provenance: .displayName,
                                      installedAppTeamID: "AAA", caskExpectedTeamID: "AAA") == .high) // TeamID match
        #expect(CaskMatchScorer.score(provenance: .curatedMapping,
                                      installedAppTeamID: "AAA", caskExpectedTeamID: "BBB") == .low)  // TeamID mismatch
    }

    @Test func onlyHighConfidenceAutoConfirms() {
        #expect(CaskMatchConfidence.high.allowsAutoConfirm == true)
        #expect(CaskMatchConfidence.medium.allowsAutoConfirm == false)
        #expect(CaskMatchConfidence.low.allowsAutoConfirm == false)
        #expect(CaskMatchConfidence.low < CaskMatchConfidence.high)
    }
}
