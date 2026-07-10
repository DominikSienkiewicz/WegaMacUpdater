import XCTest
@testable import MacUpdaterCore

/// The catalog's URL validation (F5b) lives on the **decoding** path, because decoding is
/// where untrusted data enters — a JSON file that anyone can open a pull request against.
/// The memberwise initialisers are the in-code path, used by tests and by callers that
/// already hold trusted values, and they deliberately do not re-validate.
///
/// These pin that asymmetry, so nobody "fixes" it by moving validation into the initialiser
/// (which would not help — a hostile catalog never reaches it) or removes it from the
/// decoder (which would reopen the hole where `synology.downloadPage` went straight to
/// `NSWorkspace.open`).
final class CatalogEntryConstructionTests: XCTestCase {
    func testSynologyEntryKeepsTheValuesItWasBuiltWith() {
        let entry = SynologyCatalogEntry(
            bundleId: "com.synology.DriveClient",
            identify: "Synology Drive Client",
            downloadPage: "https://www.synology.com/support/download"
        )
        XCTAssertEqual(entry.bundleId, "com.synology.DriveClient")
        XCTAssertEqual(entry.identify, "Synology Drive Client")
        XCTAssertEqual(entry.downloadPage, "https://www.synology.com/support/download")
    }

    func testSparkleFeedOverrideKeepsTheValuesItWasBuiltWith() {
        let entry = SparkleFeedOverrideEntry(bundleId: "com.openai.codex", feedURL: "https://example.test/appcast.xml")
        XCTAssertEqual(entry.bundleId, "com.openai.codex")
        XCTAssertEqual(entry.feedURL, "https://example.test/appcast.xml")
    }

    func testEntriesWithEqualFieldsAreEqual() {
        XCTAssertEqual(
            SynologyCatalogEntry(bundleId: "a", identify: "b", downloadPage: "https://c.test"),
            SynologyCatalogEntry(bundleId: "a", identify: "b", downloadPage: "https://c.test")
        )
        XCTAssertEqual(
            SparkleFeedOverrideEntry(bundleId: "a", feedURL: "https://b.test"),
            SparkleFeedOverrideEntry(bundleId: "a", feedURL: "https://b.test")
        )
    }

    /// The guarantee that matters: the *decoder* rejects a non-https download page, whatever
    /// the memberwise initialiser would have accepted.
    func testDecodingStillRejectsANonHTTPSDownloadPage() {
        let json = Data("""
        { "bundleId": "x", "identify": "y", "downloadPage": "http://evil.test/page" }
        """.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(SynologyCatalogEntry.self, from: json))
    }

    func testDecodingStillRejectsANonHTTPSFeedURL() {
        let json = Data("""
        { "bundleId": "x", "feedURL": "http://evil.test/appcast.xml" }
        """.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(SparkleFeedOverrideEntry.self, from: json))
    }
}
