import Foundation
import Testing
@testable import MacUpdaterCore

/// REL-05 — the denial gate has to be disarmed by the same paths that arm it.
///
/// The gate holds unattended rounds back for 24 h after macOS refuses to let Wega replace a
/// bundle, so the background updater stops walking into the same wall every interval. Both
/// update paths arm it: the unattended round at `BackgroundUpdater`, and the window at
/// `ScanStore+Actions` — deliberately, and the comment there says so ("teach the unattended
/// round about it too").
///
/// Only one of them disarmed it. `AppManagementDenialStore.clear()` appeared exactly once in
/// the whole tree, in `BackgroundUpdater`. So a user who hit the refusal in the window, granted
/// the permission, and then ran a successful update from that same window left the gate armed:
/// unattended rounds stayed blocked for up to 24 h with nothing wrong any more, and nothing on
/// screen said why. The asymmetry is invisible precisely because it only shows up later, in the
/// path the user is not looking at.
///
/// The gate's own behaviour is pinned in `REL05AppManagementPermissionTests`; this pins the
/// property that made the bug possible — that arming and disarming travel together.
@MainActor
@Suite("REL-05 — arming and disarming the denial gate are symmetric")
struct REL05DenialGateSymmetryTests {

    /// Behavioural: granting the permission and completing a clean run has to reopen the gate,
    /// whichever path observed the refusal.
    @Test func aCleanRunReopensAGateThatAnEarlierRefusalClosed() throws {
        let suite = "wega.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AppManagementDenialStore(defaults: defaults)

        store.recordDenial()
        #expect(!store.allowsRound(), "sanity: an observed refusal holds unattended rounds back")

        store.clear()
        #expect(store.allowsRound(),
                "REL-05: once the permission is granted and a run completes, the gate must reopen")
    }

    // MARK: The wiring that made the bug possible

    /// Source-level, because `ScanStore` lives in the app target this bundle cannot import and
    /// its report path needs a whole window's worth of state to drive.
    ///
    /// Red before the fix: `clear()` occurred exactly once in `Sources/`, in `BackgroundUpdater`.
    @Test func bothUpdatePathsArmAndDisarmTheGate() throws {
        for path in ["Sources/MacUpdater/BackgroundUpdater.swift",
                     "Sources/MacUpdater/ScanStore+Actions.swift"] {
            let source = try read(path)

            #expect(source.contains("AppManagementDenialStore.shared.recordDenial()"),
                    "REL-05: \(path) observes the refusal, so it must arm the gate")
            #expect(source.contains("AppManagementDenialStore.shared.clear()"),
                    """
                    REL-05: \(path) arms the gate but never disarms it. A permission granted \
                    after a refusal on this path would leave unattended rounds blocked for 24 h \
                    with nothing left to block them.
                    """)
        }
    }

    /// The disarm must not hide behind a success check. `BackgroundUpdater` keys both branches
    /// on the *refusal*, not on whether the round went well — a run that failed for some
    /// unrelated reason still proves the permission is no longer missing, and a gate that only
    /// reopens on a flawless run would stay shut on a machine with any other problem.
    @Test func theWindowPathKeysTheGateOnTheRefusalNotOnSuccess() throws {
        let source = try read("Sources/MacUpdater/ScanStore+Actions.swift")
        let arm = try #require(source.range(of: "AppManagementDenialStore.shared.recordDenial()"))
        let disarm = try #require(source.range(of: "AppManagementDenialStore.shared.clear()"))
        let earlyReturn = try #require(source.range(of: "WegaLog.info(.homebrew, \"Zaktualizowano \\(count) pakietów\")"))

        #expect(disarm.lowerBound < earlyReturn.lowerBound,
                """
                REL-05: the gate is settled before the all-upgraded path returns, so a clean run \
                reopens it too — that is the run most likely to follow the user granting the \
                permission.
                """)
        #expect(arm.lowerBound < earlyReturn.lowerBound || disarm.lowerBound < arm.lowerBound,
                "REL-05: both branches are decided in one place, the way BackgroundUpdater does it")
    }

    private func read(_ relativePath: String, file: String = #filePath) throws -> String {
        let root = URL(fileURLWithPath: file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }
}
