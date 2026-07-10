import XCTest
@testable import MacUpdaterCore

final class CatalogIssueBuilderTests: XCTestCase {
    private let endpoint = URL(string: "https://github.com/owner/repo/issues/new")!

    func testURLPercentEncodesTitleAndBody() throws {
        let builder = CatalogIssueBuilder(
            appName: "Acme Studio & Co",
            bundleID: "com.acme.studio",
            feedURL: "https://acme.example/appcast.xml?ch=beta",
            versionFormat: "1.2.3"
        )
        let url = try XCTUnwrap(builder.url(newIssueEndpoint: endpoint))
        let string = url.absoluteString
        XCTAssertTrue(string.hasPrefix("https://github.com/owner/repo/issues/new?title="))
        XCTAssertFalse(string.contains(" "), "spaces must be percent-encoded, not left raw")
        XCTAssertTrue(string.contains("Acme%20Studio%20%26%20Co"), "space and ampersand must be escaped")

        // The query round-trips cleanly back to the original values.
        let comps = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let items = Dictionary(uniqueKeysWithValues: (comps.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(items["title"], "[Catalog] Add update support for Acme Studio & Co")
        XCTAssertEqual(items["body"]?.contains("com.acme.studio"), true)
        XCTAssertEqual(items["body"]?.contains("https://acme.example/appcast.xml?ch=beta"), true)
        XCTAssertEqual(items["body"]?.contains("1.2.3"), true)
    }

    func testOptionalFieldsAreOmittedWhenNil() throws {
        let builder = CatalogIssueBuilder(appName: "Solo", bundleID: "com.solo")
        let url = try XCTUnwrap(builder.url(newIssueEndpoint: endpoint))
        let comps = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let body = comps.queryItems?.first(where: { $0.name == "body" })?.value ?? ""
        XCTAssertFalse(body.contains("SUFeedURL"), "no feed line when feedURL is nil")
        XCTAssertFalse(body.contains("Version format"), "no version line when versionFormat is nil")
        XCTAssertTrue(body.contains("com.solo"))
    }

    func testURLStaysUnderHardLengthLimitByTruncatingBodyNotTitle() throws {
        let hugeName = String(repeating: "N", count: 500)
        let hugeFeed = "https://acme.example/" + String(repeating: "a", count: 20_000)
        let builder = CatalogIssueBuilder(appName: hugeName, bundleID: "com.acme", feedURL: hugeFeed)

        let url = try XCTUnwrap(builder.url(newIssueEndpoint: endpoint))
        XCTAssertLessThanOrEqual(url.absoluteString.count, CatalogIssueBuilder.maxURLLength)

        // The title is preserved in full — only the body is sacrificed to the cap.
        let comps = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let title = comps.queryItems?.first(where: { $0.name == "title" })?.value ?? ""
        XCTAssertEqual(title, "[Catalog] Add update support for \(hugeName)")
    }

    func testTitleFallsBackToBundleIDWhenAppNameBlank() throws {
        let builder = CatalogIssueBuilder(appName: "   ", bundleID: "com.blank.app")
        let url = try XCTUnwrap(builder.url(newIssueEndpoint: endpoint))
        let comps = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let title = comps.queryItems?.first(where: { $0.name == "title" })?.value ?? ""
        XCTAssertEqual(title, "[Catalog] Add update support for com.blank.app")
    }
}
