import XCTest
@testable import MacUpdaterCore

/// F3 — which casks the menu-bar agent may upgrade while nobody is watching.
///
/// Four conditions, all of them necessary: the user opted this app in, the cask passes
/// `BackgroundUpdateEligibility` (no privileged hooks, a real `sha256`), the app is not
/// running, and it is not pinned or ignored. Anything short of all four falls back to the
/// one-click, user-present upgrade. The honest framing is "safe = automatic, the rest = one
/// click" — never "everything updates itself".
final class BackgroundUpdatePlannerTests: XCTestCase {
    private func profile(_ token: String, _ kinds: [CaskArtifactKind]) -> CaskArtifactProfile {
        CaskArtifactProfile(token: token, artifacts: kinds.map { CaskArtifact(kind: $0) })
    }

    private func download(_ token: String, verified: Bool) -> CaskDownloadInfo {
        CaskDownloadInfo(token: token,
                         url: "https://example.test/\(token).dmg",
                         sha256: verified ? String(repeating: "a", count: 64) : "no_check")
    }

    private func plan(
        candidates: [String],
        optedIn: Set<String> = [],
        running: Set<String> = [],
        policies: [String: UpdatePolicy] = [:],
        profiles: [CaskArtifactProfile]? = nil,
        downloads: [CaskDownloadInfo]? = nil
    ) -> [String] {
        let profileMap = Dictionary(
            (profiles ?? candidates.map { profile($0, [.app, .zap]) }).map { ($0.token, $0) },
            uniquingKeysWith: { first, _ in first })
        let downloadMap = Dictionary(
            (downloads ?? candidates.map { download($0, verified: true) }).map { ($0.token, $0) },
            uniquingKeysWith: { first, _ in first })
        return BackgroundUpdatePlanner.eligibleTokens(.init(
            candidates: candidates,
            profiles: profileMap,
            downloads: downloadMap,
            optedIn: optedIn,
            runningProcessTokens: running,
            policies: policies
        ))
    }

    func testAnOptedInSafeCaskThatIsNotRunningIsUpgraded() {
        XCTAssertEqual(plan(candidates: ["iterm2"], optedIn: ["iterm2"]), ["iterm2"])
    }

    /// Opt-in is the whole contract. Silence is not consent.
    func testACaskTheUserNeverOptedInIsLeftAlone() {
        XCTAssertEqual(plan(candidates: ["iterm2"]), [])
    }

    /// Replacing the bundle of a running app is how you corrupt someone's session.
    func testARunningAppIsNeverUpgradedInTheBackground() {
        XCTAssertEqual(plan(candidates: ["iterm2"], optedIn: ["iterm2"], running: ["iterm2"]), [])
    }

    func testACaskWithAPrivilegedHookIsRefusedEvenWhenOptedIn() {
        XCTAssertEqual(
            plan(candidates: ["parallels"], optedIn: ["parallels"],
                 profiles: [profile("parallels", [.app, .preflight])]),
            []
        )
    }

    func testACaskWithoutAChecksumIsRefusedEvenWhenOptedIn() {
        XCTAssertEqual(
            plan(candidates: ["google-chrome"], optedIn: ["google-chrome"],
                 downloads: [download("google-chrome", verified: false)]),
            []
        )
    }

    /// An ignored app is not a candidate for anything, least of all a silent upgrade.
    func testAnIgnoredCaskIsRefusedEvenWhenOptedIn() {
        XCTAssertEqual(
            plan(candidates: ["iterm2"], optedIn: ["iterm2"], policies: ["c:iterm2": .ignored]),
            []
        )
    }

    /// Pinning means "hold here". A background job must not step over that.
    func testAPinnedCaskIsRefusedEvenWhenOptedIn() {
        XCTAssertEqual(
            plan(candidates: ["iterm2"], optedIn: ["iterm2"], policies: ["c:iterm2": .pinned(version: "3.4")]),
            []
        )
    }

    func testACaskWithNoKnownProfileIsRefused() {
        let downloads = [download("mystery", verified: true)]
        let result = BackgroundUpdatePlanner.eligibleTokens(.init(
            candidates: ["mystery"], profiles: [:],
            downloads: Dictionary(downloads.map { ($0.token, $0) }, uniquingKeysWith: { a, _ in a }),
            optedIn: ["mystery"], runningProcessTokens: [], policies: [:]))
        XCTAssertEqual(result, [])
    }

    func testOnlyTheEligibleSubsetIsReturnedFromAMixedBatch() {
        let result = plan(
            candidates: ["iterm2", "parallels", "google-chrome", "alacritty"],
            optedIn: ["iterm2", "parallels", "google-chrome", "alacritty"],
            running: ["alacritty"],
            profiles: [
                profile("iterm2", [.app, .zap]),
                profile("parallels", [.app, .preflight]),
                profile("google-chrome", [.app, .zap]),
                profile("alacritty", [.app])
            ],
            downloads: [
                download("iterm2", verified: true),
                download("parallels", verified: true),
                download("google-chrome", verified: false),
                download("alacritty", verified: true)
            ]
        )
        XCTAssertEqual(result, ["iterm2"])
    }

    /// Order follows the candidate list, so the notification can name apps predictably.
    func testResultPreservesCandidateOrder() {
        let result = plan(candidates: ["zed", "alacritty", "iterm2"],
                          optedIn: ["zed", "alacritty", "iterm2"])
        XCTAssertEqual(result, ["zed", "alacritty", "iterm2"])
    }
}
