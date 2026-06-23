import XCTest
@testable import MacUpdaterCore

/// Postman self-updates via Squirrel.Mac (no Sparkle `SUFeedURL`) and its Homebrew
/// cask `postman` lags the real release channel — exactly why MacUpdater sees an
/// update Wega missed. The fix queries Postman's own Squirrel feed, the same pattern
/// already used for ChatGPT / Parallels.
final class PostmanUpdateCheckerTests: XCTestCase {

    // Trimmed real payload from https://dl.pstmn.io/update/osx_64/12.15.6 captured
    // 2026-06-22. Squirrel returns 200 + this JSON when an update exists; the `name`
    // field is the latest version. The user runs 12.15.6 while the cask still says
    // 12.15.6, so only this feed surfaces 12.16.0.
    private let sampleJSON = """
    {"name":"12.16.0","notes":"## 12.16.0\\n\\nBug fixes","pub_date":"2026-06-22T02:57:37.000Z","url":"https://dl.pstmn.io/download/version/12.16.0/osx_64?filetype=zip"}
    """

    private func postmanApp(version: String) -> ApplicationInfo {
        ApplicationInfo(
            path: URL(fileURLWithPath: "/Applications/Postman.app"),
            name: "Postman",
            bundleIdentifier: "com.postmanlabs.mac",
            version: version,
            installDate: nil,
            updateDate: nil,
            isManagedByBrew: true,
            caskToken: "postman"
        )
    }

    // MARK: Parser

    func testLatestVersionExtractsNameFromSquirrelJSON() {
        XCTAssertEqual(PostmanUpdateParser.latestVersion(fromSquirrelJSON: Data(sampleJSON.utf8)), "12.16.0")
    }

    func testLatestVersionReturnsNilForEmptyBody() {
        XCTAssertNil(PostmanUpdateParser.latestVersion(fromSquirrelJSON: Data()))
    }

    func testLatestVersionReturnsNilForMalformedJSON() {
        XCTAssertNil(PostmanUpdateParser.latestVersion(fromSquirrelJSON: Data("not json".utf8)))
    }

    // MARK: Config

    func testCheckerTargetsPostmanBundleIdentifier() {
        XCTAssertEqual(PostmanUpdateChecker.bundleIdentifier, "com.postmanlabs.mac")
    }

    // This machine is Apple Silicon, yet the `osx_arm64` channel is stale (returns 204)
    // while `osx_64` carries the live universal build. The checker MUST use `osx_64`.
    func testUpdateURLUsesOsx64Channel() {
        XCTAssertEqual(PostmanUpdateChecker.updateURL(forVersion: "12.15.6")?.absoluteString,
                       "https://dl.pstmn.io/update/osx_64/12.15.6")
    }

    func testReportedInstalledIsDetectedAsOutdatedAgainstLatest() {
        let latest = PostmanUpdateParser.latestVersion(fromSquirrelJSON: Data(sampleJSON.utf8))!
        XCTAssertTrue(isUpgrade(installed: "12.15.6", latest: latest))
    }

    // MARK: End-to-end check() over a stubbed transport

    func testCheckReturnsOutdatedWhenFeedOffersNewer() async {
        let checker = PostmanUpdateChecker(client: FakeHTTP.client(ok: sampleJSON))
        let result = await checker.check(app: postmanApp(version: "12.15.6"))
        guard case .outdated(let app) = result else { return XCTFail("expected .outdated, got \(result)") }
        XCTAssertEqual(app.availableVersion, "12.16.0")
        XCTAssertEqual(app.installedVersion, "12.15.6")
        XCTAssertEqual(app.source, .postman)
    }

    // Squirrel answers 204 No Content when the running build is current.
    func testCheckReturnsUpToDateOn204() async {
        let checker = PostmanUpdateChecker(client: FakeHTTP.client(status: 204))
        let result = await checker.check(app: postmanApp(version: "12.16.0"))
        XCTAssertEqual(result, .upToDate)
    }

    func testCheckIsNotApplicableForOtherApps() async {
        let checker = PostmanUpdateChecker(client: FakeHTTP.client(ok: sampleJSON))
        let other = ApplicationInfo(
            path: URL(fileURLWithPath: "/Applications/Other.app"),
            name: "Other", bundleIdentifier: "com.other", version: "1.0",
            installDate: nil, updateDate: nil, isManagedByBrew: false
        )
        let result = await checker.check(app: other)
        XCTAssertEqual(result, .notApplicable)
    }

    func testCheckReturnsUnavailableOnServerError() async {
        let checker = PostmanUpdateChecker(client: FakeHTTP.client(status: 503))
        let result = await checker.check(app: postmanApp(version: "12.15.6"))
        XCTAssertEqual(result, .unavailable)
    }
}
