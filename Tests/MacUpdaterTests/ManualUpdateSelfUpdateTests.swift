import Testing
import Foundation
@testable import MacUpdaterCore

/// UX-15 — Wega's self-update rides the same manual path every other app uses. These pin the
/// pure mapping from a `WegaSelfUpdateChecker.Result` to the synthetic "Wega" `ManualOutdatedApp`
/// that the scanner folds into its list, so the self-update is counted, badged, notified and
/// listed in the Updates window's manual section like any vendor app ("one count, everywhere").
@Suite("ManualUpdateScanner self-update")
struct ManualUpdateSelfUpdateTests {

    private let assetURL = URL(string: "https://example.com/WegaMacUpdater.dmg")!
    private let releaseURL = URL(string: "https://github.com/owner/repo/releases/tag/v0.2.0")!
    private let appPath = URL(fileURLWithPath: "/Applications/WegaMacUpdater.app")

    @Test func availableUpdateBecomesWegaManualRow() {
        let app = ManualUpdateScanner.selfUpdateApp(
            from: .updateAvailable(version: "0.2.0", assetURL: assetURL, releaseURL: releaseURL, notes: "Fixes"),
            appPath: appPath,
            installedVersion: "0.1.0",
            bundleIdentifier: "com.wega.WegaMacUpdater"
        )

        #expect(app?.name == "Wega")
        #expect(app?.installedVersion == "0.1.0")
        #expect(app?.availableVersion == "0.2.0")
        #expect(app?.source == .wega(releaseURL: releaseURL))
        #expect(app?.origin == .manual)
        #expect(app?.releaseNotes == "Fixes")
        #expect(app?.path == appPath)
        #expect(app?.bundleIdentifier == "com.wega.WegaMacUpdater")
    }

    /// The Updates-window row action resolves to opening the release page — never `.launchApp`,
    /// which would relaunch Wega itself and apply nothing.
    @Test func wegaRowActionOpensReleasePage() {
        let source: ManualOutdatedApp.UpdateSource = .wega(releaseURL: releaseURL)

        #expect(source.badgeLabel == "Wega")
        #expect(source.provenance == .vendorDirect)
        #expect(source.updateActionKind == .openURL(releaseURL, style: .vendorDownload))
    }

    @Test func upToDateProducesNoRow() {
        let app = ManualUpdateScanner.selfUpdateApp(
            from: .upToDate,
            appPath: appPath,
            installedVersion: "0.1.0",
            bundleIdentifier: "com.wega.WegaMacUpdater"
        )
        #expect(app == nil)
    }

    @Test func failedCheckProducesNoRow() {
        let app = ManualUpdateScanner.selfUpdateApp(
            from: .failed,
            appPath: appPath,
            installedVersion: "0.1.0",
            bundleIdentifier: "com.wega.WegaMacUpdater"
        )
        #expect(app == nil)
    }
}
