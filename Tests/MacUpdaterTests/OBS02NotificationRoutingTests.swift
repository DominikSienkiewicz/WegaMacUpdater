import Foundation
import Testing
@testable import MacUpdaterCore

/// OBS-02 — the last criterion: a notification leads to the operation it is about.
///
/// The other twelve criteria shipped with the card; this one was left open because it needs a
/// `UNUserNotificationCenterDelegate` in app startup, which nothing in the tree had. Clicking
/// any of Wega's three notifications did the system default — bring the app forward, to
/// whatever screen it last showed — so *"Wega naprawiła przerwaną aktualizację"* landed the
/// user on the updates list, with no way to find out what it had restored.
///
/// The destination travels in the notification's `userInfo`, which makes both ends of the trip
/// pure: what gets written when it is posted, and what gets read when it is clicked. Only
/// activating the app and moving the window is not, and that half lives in `NotificationRouter`
/// in the app target, pinned by `OBS02NotificationRouterTests`.
@Suite("OBS-02 — notifications route to what they are about")
struct OBS02NotificationRoutingTests {

    /// The round trip, over every destination the sidebar has. A payload that survives posting
    /// but not reading would route every notification to nowhere, silently.
    @Test(arguments: [
        SidebarSelection.updates(.all),
        .updates(.apps),
        .updates(.cli),
        .updates(.security),
        .migration,
        .inventory,
        .uninstall,
        .logs,
    ])
    func aDestinationSurvivesTheTripThroughUserInfo(destination: SidebarSelection) {
        let payload = NotificationRouting.payload(for: destination)

        #expect(NotificationRouting.destination(from: payload) == destination)
    }

    /// A notification posted by an older build is still sitting in Notification Center and will
    /// be delivered without a payload. That has to read as "no destination" rather than as some
    /// default, because sending the user somewhere they did not ask to go is worse than the
    /// behaviour this replaces.
    @Test func aNotificationWithoutAPayloadAsksForNothing() {
        #expect(NotificationRouting.destination(from: [:]) == nil)
        #expect(NotificationRouting.destination(from: ["unrelated": "value"]) == nil)
        #expect(NotificationRouting.destination(from: [NotificationRouting.destinationKey: "not.a.destination"]) == nil,
                "OBS-02: an unrecognised destination is no destination — never a fallback screen")
        #expect(NotificationRouting.destination(from: [NotificationRouting.destinationKey: 42]) == nil,
                "OBS-02: a payload of the wrong type is not a destination either")
    }

    /// A clean unattended round points at what changed.
    @Test func acleanBackgroundRoundOpensTheUpdatesList() {
        let summary = Self.summary(verdicts: ["figma": .healthy])

        #expect(summary.critical.isEmpty, "sanity: this round has nothing to answer for")
        #expect(NotificationRouting.destination(forBackgroundRound: summary) == .updates(.all))
    }

    /// A round with anything critical in it points at the log instead. The updates list shows
    /// *that* something went wrong; only the log says *what*, and that is the whole reason this
    /// notification is worth clicking.
    ///
    /// Red before the fix: with no payload at all, both rounds landed wherever the window was.
    @Test(arguments: [CaskValidationVerdict.rollbackFailed,
                      .publisherChangedAndRolledBack(old: "OLDTEAM", new: "NEWTEAM")])
    func aBackgroundRoundThatNeedsAttentionOpensTheLog(verdict: CaskValidationVerdict) {
        let summary = Self.summary(verdicts: ["figma": verdict])

        #expect(!summary.critical.isEmpty, "sanity: this round has something to answer for")
        #expect(NotificationRouting.destination(forBackgroundRound: summary) == .logs,
                "OBS-02: the reason lives in the log, so that is where the notification goes")
    }

    /// Recovery always points at the log, whatever it settled: "an interrupted update was
    /// finished" is only meaningful beside the line saying which build came back.
    @Test func aRecoveryReportAlwaysOpensTheLog() {
        #expect(NotificationRouting.recoveryDestination == .logs)
    }

    @Test func thePendingUpdatesNotificationOpensTheUnfilteredList() {
        #expect(NotificationRouting.pendingUpdatesDestination == .updates(.all),
                "OBS-02: the agent counts every category, so it must not land on a filtered list")
    }

    // MARK: Helper

    private static func summary(verdicts: [String: CaskValidationVerdict]) -> UpdateRunSummary {
        var run = UpdateRunOutcome()
        let items = verdicts.keys.map { OutdatedItem(key: "c:\($0)", name: $0, from: "1.0", to: "2.0", kind: .cask) }
        run.record(items, outcome: BrewUpgradeOutcome(exitCode: 0, failedTokens: [], errorLines: []))
        run.applyValidation(verdicts)
        return run.summary
    }
}
