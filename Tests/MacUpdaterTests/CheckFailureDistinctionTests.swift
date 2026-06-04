import XCTest
@testable import MacUpdaterCore

/// One-shot transport returning a fixed result, for driving a checker's branches.
private struct StubTransport: HTTPTransport {
    let result: Result<(Data, Int), Error>

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        switch result {
        case .failure(let error):
            throw error
        case .success(let (data, status)):
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            return (data, response)
        }
    }
}

/// Reproduces bug #8: a network failure used to collapse to `nil` (rendered as
/// "up to date"). The checker must now report `.failed` so the UI can say
/// "couldn't check" instead of falsely claiming everything is current.
final class CheckFailureDistinctionTests: XCTestCase {
    private let repos = ["com.test.app": GitHubCatalogEntry(bundleId: "com.test.app", repo: "owner/repo", caskToken: "test")]

    private func app(version: String?, bundleId: String? = "com.test.app") -> ApplicationInfo {
        ApplicationInfo(
            path: URL(fileURLWithPath: "/Applications/Test.app"),
            name: "Test",
            bundleIdentifier: bundleId,
            version: version,
            installDate: nil, updateDate: nil,
            isManagedByBrew: false
        )
    }

    private func checker(_ result: Result<(Data, Int), Error>) -> GitHubReleasesChecker {
        let client = HTTPClient(transport: StubTransport(result: result), maxRetries: 0, retryBaseDelay: 0)
        return GitHubReleasesChecker(client: client, repos: repos)
    }

    private func releaseJSON(_ tag: String) -> Data {
        Data(#"{"tag_name":"\#(tag)","draft":false,"prerelease":false}"#.utf8)
    }

    func testNetworkErrorReportsFailedNotUpToDate() async {
        let result = await checker(.failure(URLError(.notConnectedToInternet))).check(app: app(version: "1.0.0"))
        XCTAssertEqual(result, .failed)
    }

    func testServerErrorReportsFailed() async {
        let result = await checker(.success((Data(), 500))).check(app: app(version: "1.0.0"))
        XCTAssertEqual(result, .failed)
    }

    func testNewerReleaseReportsOutdated() async {
        let result = await checker(.success((releaseJSON("v2.0.0"), 200))).check(app: app(version: "1.0.0"))
        guard case .outdated(let item) = result else { return XCTFail("expected .outdated, got \(result)") }
        XCTAssertEqual(item.availableVersion, "2.0.0")
    }

    func testSameVersionReportsUpToDate() async {
        let result = await checker(.success((releaseJSON("v1.0.0"), 200))).check(app: app(version: "1.0.0"))
        XCTAssertEqual(result, .upToDate)
    }

    func testWrongBundleIdReportsNotApplicable() async {
        let result = await checker(.success((releaseJSON("v2.0.0"), 200))).check(app: app(version: "1.0.0", bundleId: "com.other.app"))
        XCTAssertEqual(result, .notApplicable)
    }
}
