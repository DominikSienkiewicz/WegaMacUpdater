import XCTest
@testable import MacUpdaterCore

/// ARCH-06 — "13 vendor-checkerów powiela ten sam szkielet".
///
/// Regression coverage for the unified vendor-check architecture:
///  * a brand-new vendor is added purely as **data** — a `VendorCheckPlan` — and runs
///    through the one shared `VendorUpdateChecker` driver, with no per-vendor copy of the
///    `check → GET → klasyfikacja → parse → isUpgrade` skeleton;
///  * the single `statusCode >= 500 ? .unavailable : .failed` classification lives in that
///    one driver and is exercised here through it;
///  * update actions are expressed as data in Core (`UpdateSource.updateActionKind` /
///    `.badgeLabel`), so a new self-updating vendor renders with no new UI `switch` branch.
final class VendorUpdateCheckerTests: XCTestCase {

    /// One-shot transport returning a fixed result, for driving the shared driver's branches.
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

    /// A brand-new vendor defined only as data: an endpoint, a parse closure, and a source.
    /// It supplies NO `check(app:)` method — the shared `VendorUpdateChecker` driver runs the
    /// whole skeleton for it. This is exactly "dodanie nowego vendora jako danych".
    private struct NewVendorChecker: VendorUpdateChecker {
        let client: HTTPClient
        func plan(for app: ApplicationInfo) -> VendorCheckPlan? {
            guard let installed = app.version, !installed.isEmpty else { return nil }
            return VendorCheckPlan(
                request: HTTPRequest(url: URL(string: "https://example.test/latest")!, enableETag: true)
            ) { data in
                guard let latest = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines), !latest.isEmpty
                else { return .decided(.failed) }
                return .candidate(VendorCandidate(latest: latest, installed: installed, source: .signal))
            }
        }
    }

    private func app(version: String?) -> ApplicationInfo {
        ApplicationInfo(
            path: URL(fileURLWithPath: "/Applications/New.app"),
            name: "New",
            bundleIdentifier: "test.new",
            version: version,
            installDate: nil, updateDate: nil,
            isManagedByBrew: false
        )
    }

    private func checker(_ result: Result<(Data, Int), Error>) -> NewVendorChecker {
        NewVendorChecker(client: HTTPClient(transport: StubTransport(result: result), maxRetries: 0, retryBaseDelay: 0))
    }

    // MARK: The shared driver realizes the whole skeleton for a data-only checker

    func testDataOnlyCheckerReportsOutdatedThroughSharedDriver() async {
        let result = await checker(.success((Data("2.0.0".utf8), 200))).check(app: app(version: "1.0.0"))
        guard case .outdated(let item) = result else { return XCTFail("expected .outdated, got \(result)") }
        XCTAssertEqual(item.availableVersion, "2.0.0")
        XCTAssertEqual(item.installedVersion, "1.0.0")
    }

    func testDataOnlyCheckerUpToDateWhenNotNewer() async {
        // The driver runs the shared isUpgrade comparison — an equal/older feed is current.
        let result = await checker(.success((Data("1.0.0".utf8), 200))).check(app: app(version: "1.0.0"))
        XCTAssertEqual(result, .upToDate)
    }

    func testUnparseableBodyReportsFailedViaEvaluate() async {
        let result = await checker(.success((Data("".utf8), 200))).check(app: app(version: "1.0.0"))
        XCTAssertEqual(result, .failed)
    }

    // MARK: The single shared classification, exercised through the driver

    func testServerErrorClassifiesUnavailable() async {
        let result = await checker(.success((Data(), 503))).check(app: app(version: "1.0.0"))
        XCTAssertEqual(result, .unavailable)
    }

    func testClientErrorClassifiesFailed() async {
        let result = await checker(.success((Data(), 404))).check(app: app(version: "1.0.0"))
        XCTAssertEqual(result, .failed)
    }

    func testTransportErrorClassifiesUnavailable() async {
        let result = await checker(.failure(URLError(.timedOut))).check(app: app(version: "1.0.0"))
        XCTAssertEqual(result, .unavailable)
    }

    func testInapplicablePlanSkipsNetwork() async {
        // No version → plan is nil → .notApplicable, and the (would-throw) transport is
        // never reached — proving `plan == nil` short-circuits before any request.
        let result = await checker(.failure(URLError(.notConnectedToInternet))).check(app: app(version: nil))
        XCTAssertEqual(result, .notApplicable)
    }

    func testUpToDateStatusCodeShortCircuitsBeforeParsing() async {
        // A plan may declare status codes that already mean "current" (e.g. Squirrel's 204),
        // classified before the 200 guard — without invoking evaluate.
        struct SquirrelStyleChecker: VendorUpdateChecker {
            let client: HTTPClient
            func plan(for app: ApplicationInfo) -> VendorCheckPlan? {
                VendorCheckPlan(
                    request: HTTPRequest(url: URL(string: "https://example.test/x")!),
                    upToDateStatusCodes: [204]
                ) { _ in .decided(.failed) }
            }
        }
        let client = HTTPClient(transport: StubTransport(result: .success((Data(), 204))), maxRetries: 0, retryBaseDelay: 0)
        let result = await SquirrelStyleChecker(client: client).check(app: app(version: "1.0.0"))
        XCTAssertEqual(result, .upToDate)
    }

    // MARK: Actions as data — a new self-updating vendor needs no UI branch

    func testSelfUpdatingSourcesShareTheOneLaunchAppAction() {
        let selfUpdating: [ManualOutdatedApp.UpdateSource] = [
            .sparkle, .antigravity, .parallels, .chatgpt, .postman, .discord, .signal, .chrome, .obsidian
        ]
        for source in selfUpdating {
            XCTAssertEqual(source.updateActionKind, .launchApp, "\(source) should map to the shared launchApp action")
        }
    }

    func testNonLaunchActionKindsAreResolvedFromData() {
        XCTAssertEqual(ManualOutdatedApp.UpdateSource.cask(token: "docker").updateActionKind, .brewInstall(token: "docker"))
        XCTAssertEqual(ManualOutdatedApp.UpdateSource.mas(appStoreID: "1").updateActionKind, .appStore)
        XCTAssertEqual(ManualOutdatedApp.UpdateSource.jetbrains(caskToken: "idea").updateActionKind, .jetBrainsToolbox)

        guard case .openURL(_, let style) = ManualOutdatedApp.UpdateSource.github(repo: "o/r").updateActionKind else {
            return XCTFail("github should resolve to an openURL action")
        }
        XCTAssertEqual(style, .githubReleases)
    }

    func testBadgeLabelsAreResolvedFromData() {
        XCTAssertEqual(ManualOutdatedApp.UpdateSource.signal.badgeLabel, "Signal")
        XCTAssertEqual(ManualOutdatedApp.UpdateSource.cask(token: "docker").badgeLabel, "docker")
        XCTAssertEqual(ManualOutdatedApp.UpdateSource.jetbrains(caskToken: "idea").badgeLabel, "idea")
        XCTAssertEqual(ManualOutdatedApp.UpdateSource.mas(appStoreID: "497799835").badgeLabel, "497799835")
    }
}
