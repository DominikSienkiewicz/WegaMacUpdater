import Foundation
import Testing
@testable import MacUpdaterCore

/// REL-05 — the TCC permission **App Management**, recognized as a named failure mode.
///
/// Since macOS 13, replacing a bundle in `/Applications` needs that grant, and the grant
/// covers child processes: `brew` runs as Wega's child, so a missing grant makes the
/// `ditto` that swaps the bundle fail with `Operation not permitted`. brew wraps that in a
/// generic `Error: Failure while executing;` headline and names no cask, so the token
/// parser finds nothing to blame — the failure arrives as an unattributed wall of stderr.
///
/// Three things follow, and this suite covers all three:
///
/// 1. the refusal is *recognized* (`requiresAppManagementPermission`) rather than passed on
///    verbatim, so the UI can offer the one button that fixes it;
/// 2. it never reads as success — including when the canary inspects the untouched old
///    bundle and, of course, finds it healthy;
/// 3. it does not repeat every interval: once observed, unattended rounds are held back by
///    ``AppManagementDenialGate`` instead of failing identically on schedule.
///
/// Point 2 has held since REL-02 (`recordBackgroundRound` fails the whole batch, and
/// `applyValidation` refuses to let `.healthy` promote anything). It is pinned here rather
/// than fixed, because it is the half of the card that would silently rot first.
@Suite("REL-05 — App Management permission denial")
struct REL05AppManagementPermissionTests {

    // MARK: Fixtures

    /// Real-world shape of the refusal, captured in `BrewUpgradeOutcomeTests`: the cause is
    /// on a continuation line printed by `ditto`, not on the `Error:` headline.
    private static let deniedOutput = """
    ==> Upgrading discord
      0.0.392 -> 0.0.395
    Error: Failure while executing; `/usr/bin/ditto ...` exited with 1. Here's the output:
    ditto: /Applications/Discord.app: Operation not permitted
    ==> Purging files for version 0.0.395 of Cask discord
    ==> Upgraded 1 outdated package
    discord 0.0.392 -> 0.0.395
    """

    private func caskItem(_ token: String) -> OutdatedItem {
        OutdatedItem(key: UpdatePlanner.key(name: token, kind: .cask), name: token,
                     from: nil, to: nil, kind: .cask)
    }

    // MARK: 1 — the refusal is recognized

    @Test("`analyze` flags an App Management refusal against a bundle")
    func analyzeFlagsAppManagementDenial() {
        let outcome = BrewUpgradeOutcome.analyze(exitCode: 1, output: Self.deniedOutput)

        #expect(outcome.requiresAppManagementPermission)
        #expect(!outcome.isSuccessful)
    }

    /// The two halves of the pattern are both load-bearing: `Operation not permitted` on an
    /// ordinary file is a different failure with a different fix, and must not borrow this
    /// banner.
    @Test("`Operation not permitted` outside a bundle is not an App Management refusal")
    func plainPermissionErrorIsNotFlagged() {
        let outcome = BrewUpgradeOutcome.analyze(
            exitCode: 1,
            output: "Error: Failure while executing; `/bin/rm` exited with 1.\nrm: /opt/homebrew/var/cache: Operation not permitted\n"
        )

        #expect(!outcome.requiresAppManagementPermission)
    }

    @Test("A bundle path without the errno text is not an App Management refusal")
    func bundlePathAloneIsNotFlagged() {
        let outcome = BrewUpgradeOutcome.analyze(
            exitCode: 0,
            output: "Error: intellij-idea: It seems the App source '/Applications/IntelliJ IDEA.app' is not there.\n"
        )

        #expect(!outcome.requiresAppManagementPermission)
    }

    @Test("A clean upgrade carries no permission flag")
    func cleanUpgradeIsNotFlagged() {
        let outcome = BrewUpgradeOutcome.analyze(
            exitCode: 0,
            output: "==> Upgraded 1 outdated package\ndiscord 0.0.392 -> 0.0.395\n"
        )

        #expect(!outcome.requiresAppManagementPermission)
    }

    /// The BG-04 forced retry runs into the same wall, so folding its outcome back in may
    /// not lose the reason the first attempt failed.
    @Test("Merging a forced retry keeps the permission flag from either side")
    func mergingKeepsPermissionFlag() {
        let denied = BrewUpgradeOutcome.analyze(exitCode: 1, output: Self.deniedOutput)
        let clean = BrewUpgradeOutcome(exitCode: 0, failedTokens: [], errorLines: [])

        #expect(BrewUpgradeOutcome.merging(original: denied, forcedRetry: clean, retriedTokens: ["discord"])
            .requiresAppManagementPermission)
        #expect(BrewUpgradeOutcome.merging(original: clean, forcedRetry: denied, retriedTokens: ["discord"])
            .requiresAppManagementPermission)
    }

    // MARK: 2 — it never reads as success

    /// The card's headline symptom: brew still prints `==> Upgraded 1 outdated package` and
    /// exits 0 while the bundle was never replaced. Nothing in the run may claim success,
    /// and the summary must carry the *reason* — a count of failures is not actionable.
    @Test("An unattended round that hit the refusal reports no upgrade")
    func unattendedRoundReportsNoUpgrade() {
        var run = UpdateRunOutcome()
        run.recordBackgroundRound(
            [caskItem("discord")],
            outcome: BrewUpgradeOutcome.analyze(exitCode: 0, output: Self.deniedOutput)
        )

        let summary = run.summary
        #expect(summary.upgraded.isEmpty)
        #expect(!summary.allItemsUpgraded)
        #expect(summary.needsAppManagementPermission)
    }

    /// The subtle half: when brew never replaced the bundle, the canary inspects the *old*
    /// app — which passes Gatekeeper, is signed by the same publisher, and looks perfectly
    /// healthy. A round that let `.healthy` promote the item would notify success over an
    /// update that never happened.
    @Test("A healthy canary on the untouched old bundle cannot promote the refusal to success")
    func healthyCanaryCannotPromoteRefusal() {
        var run = UpdateRunOutcome()
        run.recordBackgroundRound(
            [caskItem("discord")],
            outcome: BrewUpgradeOutcome.analyze(exitCode: 0, output: Self.deniedOutput)
        )
        run.applyValidation(["discord": .healthy])
        run.applyRescan(stillOutdatedKeys: [], confirmed: true)

        #expect(run.summary.upgraded.isEmpty)
        #expect(run.summary.items.first?.verdict == .executionFailed)
    }

    // MARK: 3 — it does not repeat every interval

    @Test("A fresh gate lets a round through")
    func freshGateAllowsRound() {
        #expect(AppManagementDenialGate().allowsRound(now: Date()))
    }

    @Test("An observed refusal holds back the rounds that would fail identically")
    func denialHoldsBackFollowingRounds() {
        let denialTime = Date(timeIntervalSince1970: 1_000_000)
        var gate = AppManagementDenialGate()
        gate.recordDenial(at: denialTime)

        // The next scheduled checks — the ones that used to notify a failure every interval.
        #expect(!gate.allowsRound(now: denialTime.addingTimeInterval(60)))
        #expect(!gate.allowsRound(now: denialTime.addingTimeInterval(6 * 60 * 60)))
        #expect(!gate.allowsRound(
            now: denialTime.addingTimeInterval(AppManagementDenialGate.retryCooldown - 1)
        ))
    }

    /// Held back, not switched off: the grant may arrive while nobody tells Wega, so the
    /// gate reopens on its own rather than waiting for a reset that may never come.
    @Test("The gate reopens once the cooldown has passed")
    func gateReopensAfterCooldown() {
        let denialTime = Date(timeIntervalSince1970: 1_000_000)
        var gate = AppManagementDenialGate()
        gate.recordDenial(at: denialTime)

        #expect(gate.allowsRound(
            now: denialTime.addingTimeInterval(AppManagementDenialGate.retryCooldown)
        ))
    }

    @Test("A round that no longer hits the refusal clears the gate immediately")
    func clearingReopensTheGate() {
        var gate = AppManagementDenialGate()
        gate.recordDenial(at: Date(timeIntervalSince1970: 1_000_000))
        gate.clear()

        #expect(gate.deniedAt == nil)
        #expect(gate.allowsRound(now: Date(timeIntervalSince1970: 1_000_060)))
    }

    /// A clock that jumps backwards (DST, NTP correction, a restored machine) must not
    /// strand the gate shut for longer than the cooldown it agreed to.
    @Test("A backwards clock jump does not strand the gate shut")
    func backwardsClockDoesNotStrandTheGate() {
        var gate = AppManagementDenialGate()
        gate.recordDenial(at: Date(timeIntervalSince1970: 2_000_000))

        #expect(gate.allowsRound(now: Date(timeIntervalSince1970: 1_000_000)))
    }

    // MARK: 4 — the preflight

    @Test("One refusal decides the verdict, whatever else was writable")
    func oneRefusalDecidesTheVerdict() {
        let bundles = [URL(fileURLWithPath: "/Applications/A.app"),
                       URL(fileURLWithPath: "/Applications/B.app")]

        let status = AppManagementPermissionProbe.status(bundles: bundles) { url in
            url.lastPathComponent == "A.app" ? .writable : .permissionDenied
        }

        #expect(status == .denied)
    }

    @Test("A writable bundle and no refusal reads as granted")
    func writableBundleReadsAsGranted() {
        let status = AppManagementPermissionProbe.status(
            bundles: [URL(fileURLWithPath: "/Applications/A.app")]
        ) { _ in .writable }

        #expect(status == .granted)
    }

    /// Nothing answerable is reported as such. A preflight that guessed "granted" here
    /// would be worse than no preflight — it would vouch for a permission nobody checked.
    @Test("Nothing answerable reads as unknown, never as granted")
    func nothingAnswerableReadsAsUnknown() {
        #expect(AppManagementPermissionProbe.status(bundles: []) { _ in .writable } == .unknown)
        #expect(AppManagementPermissionProbe.status(
            bundles: [URL(fileURLWithPath: "/Applications/A.app")]
        ) { _ in .unavailable } == .unknown)
    }

    @Test("The preflight never probes Wega's own bundle")
    func preflightSkipsOwnBundle() {
        let own = URL(fileURLWithPath: "/Applications/Wega.app")
        let contents = [own,
                        URL(fileURLWithPath: "/Applications/Discord.app"),
                        URL(fileURLWithPath: "/Applications/Utilities")]

        let candidates = AppManagementPermissionProbe.probeCandidates(in: contents, excluding: own)

        #expect(candidates.map(\.lastPathComponent) == ["Discord.app"])
    }

    /// Deterministic and bounded: the same machine probes the same bundles every time, so a
    /// denial cannot appear to come and go with directory-enumeration order.
    @Test("The preflight probes a bounded, stable set of bundles")
    func preflightIsBoundedAndStable() {
        let contents = ["Zoom.app", "Discord.app", "Firefox.app", "Alacritty.app"]
            .map { URL(fileURLWithPath: "/Applications/\($0)") }

        let candidates = AppManagementPermissionProbe.probeCandidates(
            in: contents, excluding: nil, limit: 2
        )

        #expect(candidates.map(\.lastPathComponent) == ["Alacritty.app", "Discord.app"])
        #expect(AppManagementPermissionProbe.probeCandidates(
            in: contents, excluding: nil, limit: 0
        ).isEmpty)
    }

    // MARK: 5 — the production wiring (checkable where it lives)

    /// `BackgroundUpdater.runIfEligible` sits behind live `BrewService` / coordinator /
    /// notification-center values a unit test cannot stand in for — the situation BG-04
    /// documents. So the round's shape is pinned at source level instead: the gate is
    /// consulted *before* any brew invocation (a check placed after the round would let the
    /// failing upgrade run first, which is exactly the loop being closed), and the denial is
    /// recorded from what the round observed.
    @Test("The unattended round consults the gate before it runs brew")
    func backgroundRoundConsultsGateBeforeRunningBrew() throws {
        let source = try backgroundUpdaterSource()

        let gateCheck = try #require(source.range(of: "AppManagementDenialStore.shared.allowsRound()"))
        let firstBrewRun = try #require(source.range(of: "await runBrew(arguments:"))
        let recordDenial = try #require(source.range(of: "AppManagementDenialStore.shared.recordDenial()"))

        #expect(gateCheck.lowerBound < firstBrewRun.lowerBound,
                "the gate must be consulted before brew runs, not after the round already failed")
        #expect(firstBrewRun.lowerBound < recordDenial.lowerBound,
                "the denial is recorded from the observed outcome, not guessed up front")
        #expect(source.contains("AppManagementDenialStore.shared.clear()"),
                "a round that no longer hits the refusal must lift the hold")
    }

    /// The window's banner: one named permission and the button that grants it, taking
    /// precedence over the sudo hint — which would otherwise send the user to configure
    /// Touch ID for a failure Touch ID cannot fix.
    @Test("The window surfaces the refusal as a named banner with the settings deep link")
    func windowBannerNamesThePermission() throws {
        let source = try ScanStoreSources.everything()

        let permissionBranch = try #require(source.range(of: "summary.needsAppManagementPermission"))
        let sudoBranch = try #require(source.range(of: "summary.needsSudoPassword"))

        #expect(permissionBranch.lowerBound < sudoBranch.lowerBound,
                "the App Management branch must be evaluated before the sudo hint")
        #expect(source.contains("action: .openAppManagementSettings"),
                "the banner must carry the action that opens the permission pane")
    }

    @Test("The deep link targets the App Management pane")
    func deepLinkTargetsAppManagementPane() {
        #expect(AppManagementSettings.paneURL.absoluteString ==
                "x-apple.systempreferences:com.apple.preference.security?Privacy_AppBundles")
    }

    // MARK: Source access

    private func backgroundUpdaterSource(file: String = #filePath) throws -> String {
        try sourceFile("Sources/MacUpdater/BackgroundUpdater.swift", file: file)
    }

    private func sourceFile(_ relativePath: String, file: String = #filePath) throws -> String {
        let packageRoot = URL(fileURLWithPath: file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: packageRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }
}
