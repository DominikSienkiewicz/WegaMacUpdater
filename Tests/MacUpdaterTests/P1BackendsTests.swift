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

    @Test func catalogSignatureUnconfiguredFailsClosed() {
        #expect(CatalogSignature.isConfigured == false) // placeholder w repo
        #expect(CatalogSignature.verify(data: Data("x".utf8), signatureBase64: "AAAA") == false)
    }

    @Test func overlayKeepsBaselineOnInvalidFixedURLButAppliesTemplates() throws {
        let base = try AppEndpoints.loadBundled()
        let overlay = AppEndpointsOverlay(
            jetbrainsReleases: nil, chatgptAppcast: nil, googleDriveOmaha: nil,
            caskDatabase: "ma spacje i nie jest url", appCatalog: nil,
            githubLatestRelease: "https://example.test/{repo}", synologyChangeLog: nil,
            antigravityUpdate: nil, parallelsUpdates: nil, homebrewWebsite: nil,
            homebrewInstallCommand: nil, githubReleasesPage: nil, googleDriveDownload: nil,
            projectRepository: nil, projectIssues: nil, authorLinkedIn: nil, masRepository: nil
        )
        let merged = base.overlaying(overlay)
        #expect(merged.caskDatabase == base.caskDatabase)                 // zły URL → baseline (DBT-5)
        #expect(merged.githubLatestRelease == "https://example.test/{repo}") // szablon → nadpisany
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

    @Test func confidenceScoringBySignalStrength() {
        #expect(CaskMatchScorer.score(applicationName: "Visual Studio Code",
                                      caskToken: "visual-studio-code",
                                      caskNames: [], viaCustomMapping: false) == .high)        // token exact
        #expect(CaskMatchScorer.score(applicationName: "Visual Studio Code",
                                      caskToken: "vscode",
                                      caskNames: ["Visual Studio Code"], viaCustomMapping: false) == .medium) // name exact
        #expect(CaskMatchScorer.score(applicationName: "VS Code",
                                      caskToken: "visual-studio-code",
                                      caskNames: ["Visual Studio Code"], viaCustomMapping: false) == .low)    // tylko fuzzy
        #expect(CaskMatchScorer.score(applicationName: "X", caskToken: "y",
                                      caskNames: [], viaCustomMapping: true) == .high)          // curated
        #expect(CaskMatchScorer.score(applicationName: "X", caskToken: "y", caskNames: [],
                                      viaCustomMapping: false,
                                      installedAppTeamID: "AAA", caskExpectedTeamID: "AAA") == .high) // TeamID match
        #expect(CaskMatchScorer.score(applicationName: "X", caskToken: "y", caskNames: [],
                                      viaCustomMapping: false,
                                      installedAppTeamID: "AAA", caskExpectedTeamID: "BBB") == .low)  // TeamID mismatch
    }

    @Test func onlyHighConfidenceAutoConfirms() {
        #expect(CaskMatchConfidence.high.allowsAutoConfirm == true)
        #expect(CaskMatchConfidence.medium.allowsAutoConfirm == false)
        #expect(CaskMatchConfidence.low.allowsAutoConfirm == false)
        #expect(CaskMatchConfidence.low < CaskMatchConfidence.high)
    }
}
