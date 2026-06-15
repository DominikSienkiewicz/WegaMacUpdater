import Testing
import Foundation
@testable import MacUpdaterCore

private final class FakeTransport: HTTPTransport, @unchecked Sendable {
    struct Stub { let data: Data; let status: Int }
    private let lock = NSLock()
    private var queue: [Stub]
    init(_ stubs: [Stub]) { self.queue = stubs }
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let stub = lock.withLock { queue.isEmpty ? Stub(data: Data(), status: 200) : queue.removeFirst() }
        let response = HTTPURLResponse(url: request.url!, statusCode: stub.status, httpVersion: nil, headerFields: [:])!
        return (stub.data, response)
    }
}

@Suite("WegaSelfUpdateChecker")
struct WegaSelfUpdateCheckerTests {

    private func release(tag: String, draft: Bool = false, prerelease: Bool = false, assets: [(String, String)]) -> String {
        let assetJSON = assets
            .map { #"{"name":"\#($0.0)","browser_download_url":"\#($0.1)"}"# }
            .joined(separator: ",")
        return """
        {"tag_name":"\(tag)","draft":\(draft),"prerelease":\(prerelease),
         "html_url":"https://github.com/owner/repo/releases/tag/\(tag)",
         "assets":[\(assetJSON)]}
        """
    }

    private func checker(_ body: String, status: Int = 200, current: String) -> WegaSelfUpdateChecker {
        let client = HTTPClient(transport: FakeTransport([.init(data: Data(body.utf8), status: status)]), maxRetries: 0, retryBaseDelay: 0)
        return WegaSelfUpdateChecker(repo: "owner/repo", currentVersion: current, client: client)
    }

    @Test func detectsNewerReleaseAndPrefersDMG() async {
        let body = release(tag: "v0.2.0", assets: [
            ("WegaMacUpdater.pkg", "https://example.com/Wega.pkg"),
            ("WegaMacUpdater.dmg", "https://example.com/Wega.dmg"),
        ])
        let result = await checker(body, current: "0.1.0").check()

        #expect(result == .updateAvailable(
            version: "0.2.0",
            assetURL: URL(string: "https://example.com/Wega.dmg")!,
            releaseURL: URL(string: "https://github.com/owner/repo/releases/tag/v0.2.0")!,
            notes: ""
        ))
    }

    @Test func reportsUpToDateWhenSameVersion() async {
        let body = release(tag: "v0.1.0", assets: [("WegaMacUpdater.dmg", "https://example.com/Wega.dmg")])
        let result = await checker(body, current: "0.1.0").check()
        #expect(result == .upToDate)
    }

    @Test func reportsUpToDateWhenReleaseIsOlder() async {
        let body = release(tag: "v0.0.9", assets: [("WegaMacUpdater.dmg", "https://example.com/Wega.dmg")])
        let result = await checker(body, current: "0.1.0").check()
        #expect(result == .upToDate)
    }

    @Test func fallsBackToPkgWhenNoDMG() async {
        let body = release(tag: "v0.2.0", assets: [("WegaMacUpdater.pkg", "https://example.com/Wega.pkg")])
        let result = await checker(body, current: "0.1.0").check()
        #expect(result == .updateAvailable(
            version: "0.2.0",
            assetURL: URL(string: "https://example.com/Wega.pkg")!,
            releaseURL: URL(string: "https://github.com/owner/repo/releases/tag/v0.2.0")!,
            notes: ""
        ))
    }

    @Test func ignoresPrereleaseLatest() async {
        let body = release(tag: "v0.2.0", prerelease: true, assets: [("WegaMacUpdater.dmg", "https://example.com/Wega.dmg")])
        let result = await checker(body, current: "0.1.0").check()
        #expect(result == .upToDate)
    }

    @Test func failsOnHTTPError() async {
        let result = await checker("{}", status: 500, current: "0.1.0").check()
        #expect(result == .failed)
    }
}
