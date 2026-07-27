import Foundation
import Testing
@testable import MacUpdaterCore

/// REL-07 — the scanner forces a rolled-back cask back onto the update list even though
/// `brew outdated` no longer reports it (Caskroom == latest after the auto-rollback), and
/// stamps it so the UI can label it "cofnięto — ponów próbę".
///
/// This pins the pure forcing rule in isolation from the async `scan()` around it: given the
/// ledger's tokens, the installed apps, and what brew *already* lists, which forced rows come
/// out and with what content.
@Suite("REL-07 — rolled-back row forcing")
struct RolledBackRowForcingTests {

    private func caskApp(
        _ token: String,
        name: String,
        installed: String,
        path: String
    ) -> ApplicationInfo {
        ApplicationInfo(
            path: URL(fileURLWithPath: path),
            name: name,
            bundleIdentifier: "com.example.\(token)",
            version: installed,
            installDate: nil,
            updateDate: nil,
            isManagedByBrew: true,
            caskToken: token
        )
    }

    /// The core guarantee: a token brew stays silent about still produces a labelled row that
    /// shows the reverted (installed) version against the version brew's metadata still claims.
    @Test func forcesALabelledRowForASilentRolledBackCask() {
        let rows = ManualUpdateScanner.rolledBackRows(
            rolledBackTokens: ["figma"],
            installedApps: [caskApp("figma", name: "Figma", installed: "1.0", path: "/Applications/Figma.app")],
            brewCaskVersions: ["figma": "2.0"],
            alreadyListedTokens: []
        )

        #expect(rows.count == 1)
        let row = rows[0]
        #expect(row.rolledBack)
        #expect(row.source == .cask(token: "figma"),
                "REL-07: the retry routes through the existing brew-install action for the cask")
        #expect(row.installedVersion == "1.0",
                "REL-07: the row shows the reverted version actually on disk, not brew's metadata")
        #expect(row.availableVersion == "2.0")
        #expect(row.name == "Figma")
        #expect(row.path == URL(fileURLWithPath: "/Applications/Figma.app"))
        #expect(row.origin == .brew)
        #expect(row.bundleIdentifier == "com.example.figma")
    }

    /// If upstream has since shipped a newer release, `brew outdated` reports the cask again
    /// and it is already on the list — forcing a second row would duplicate it.
    @Test func doesNotForceARowBrewAlreadyReports() {
        let rows = ManualUpdateScanner.rolledBackRows(
            rolledBackTokens: ["figma"],
            installedApps: [caskApp("figma", name: "Figma", installed: "1.0", path: "/Applications/Figma.app")],
            brewCaskVersions: ["figma": "2.0"],
            alreadyListedTokens: ["figma"]
        )

        #expect(rows.isEmpty)
    }

    /// A mark for a token whose app is no longer installed cannot be turned into a row (there
    /// is no path or version to show); it is skipped rather than fabricated.
    @Test func skipsTokensWithNoInstalledApp() {
        let rows = ManualUpdateScanner.rolledBackRows(
            rolledBackTokens: ["figma"],
            installedApps: [],
            brewCaskVersions: ["figma": "2.0"],
            alreadyListedTokens: []
        )

        #expect(rows.isEmpty)
    }

    @Test func producesNothingWhenNoTokensAreRolledBack() {
        let rows = ManualUpdateScanner.rolledBackRows(
            rolledBackTokens: [],
            installedApps: [caskApp("figma", name: "Figma", installed: "1.0", path: "/Applications/Figma.app")],
            brewCaskVersions: ["figma": "2.0"],
            alreadyListedTokens: []
        )

        #expect(rows.isEmpty)
    }

    /// Multiple forced rows come out in a stable (token-sorted) order so the list does not
    /// reshuffle between scans.
    @Test func forcedRowsAreDeterministicallyOrdered() {
        let rows = ManualUpdateScanner.rolledBackRows(
            rolledBackTokens: ["zoom", "figma"],
            installedApps: [
                caskApp("zoom", name: "Zoom", installed: "5.0", path: "/Applications/zoom.us.app"),
                caskApp("figma", name: "Figma", installed: "1.0", path: "/Applications/Figma.app")
            ],
            brewCaskVersions: ["zoom": "6.0", "figma": "2.0"],
            alreadyListedTokens: []
        )

        #expect(rows.map(\.name) == ["Figma", "Zoom"])
    }
}
