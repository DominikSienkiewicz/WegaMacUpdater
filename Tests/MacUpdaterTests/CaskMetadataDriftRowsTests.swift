import Foundation
import Testing
@testable import MacUpdaterCore

/// REL-17 — the *reverse* of ``BrewCaskDriftFilter``'s drift.
///
/// That filter hides a cask whose on-disk bundle is already at or past `current_version`
/// while brew's metadata lags (self-updaters rewriting their own bundle) — a false
/// positive. The opposite direction is a false *negative* and had no handler at all: when
/// brew's Caskroom records a version the app on disk never reached (an install that did
/// not land, an out-of-band downgrade), `brew outdated` compares its own receipt against
/// the cask and stays silent, while `ManualUpdateScanner` treats brew as authoritative and
/// therefore runs neither the cask-version check nor any vendor checker on that app. The
/// pending update is then invisible to every source.
///
/// Reproduced by Discord: `brew list --cask --versions discord` reports `0.0.403` while
/// `/Applications/Discord.app` is `0.0.402`. Discord's own Squirrel feed answers **204**
/// ("you are current") for `0.0.402`, so the vendor checker could not have caught it
/// either — Homebrew's own metadata is the only source that knows `0.0.403` exists.
///
/// These pin the pure rule in isolation from the async `scan()` around it, exactly as the
/// REL-07 forcing tests do.
@Suite("REL-17 — brew cask metadata drift row forcing")
struct CaskMetadataDriftRowsTests {

    private func caskApp(
        _ token: String,
        name: String,
        installed: String?,
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

    /// The regression: brew records a version the bundle on disk never reached, so brew
    /// reports nothing and the app is silently presented as current. One `.cask` row must
    /// come out, showing the version really on disk against the one brew claims.
    @Test func forcesARowWhenBrewRecordsAVersionTheDiskNeverReached() {
        let rows = ManualUpdateScanner.caskMetadataDriftRows(
            installedApps: [caskApp("discord", name: "Discord", installed: "0.0.402",
                                    path: "/Applications/Discord.app")],
            brewCaskVersions: ["discord": "0.0.403"],
            alreadyListedTokens: []
        )

        #expect(rows.count == 1)
        let row = rows[0]
        #expect(row.source == .cask(token: "discord"),
                "REL-17: the repair routes through the existing brew-install action, which force-reinstalls")
        #expect(row.installedVersion == "0.0.402",
                "REL-17: the row shows the version actually on disk, not brew's metadata")
        #expect(row.availableVersion == "0.0.403")
        #expect(row.name == "Discord")
        #expect(row.path == URL(fileURLWithPath: "/Applications/Discord.app"))
        #expect(row.origin == .brew)
        #expect(row.bundleIdentifier == "com.example.discord")
        #expect(!row.rolledBack,
                "REL-17: no rollback happened here, so the row must not claim the REL-07 'cofnięto' label")
    }

    /// The healthy majority: brew's record and the bundle agree. Nothing to force.
    @Test func producesNothingWhenBrewAndDiskAgree() {
        let rows = ManualUpdateScanner.caskMetadataDriftRows(
            installedApps: [caskApp("figma", name: "Figma", installed: "2.0", path: "/Applications/Figma.app")],
            brewCaskVersions: ["figma": "2.0"],
            alreadyListedTokens: []
        )

        #expect(rows.isEmpty)
    }

    /// Homebrew's `version,build` encoding against a bare bundle version is noise, not a
    /// drift — the guard against turning every such cask into a phantom row.
    @Test func treatsAOneSidedBuildSuffixAsNoiseRatherThanDrift() {
        let rows = ManualUpdateScanner.caskMetadataDriftRows(
            installedApps: [caskApp("zoom", name: "Zoom", installed: "5.3.1", path: "/Applications/zoom.us.app")],
            brewCaskVersions: ["zoom": "5.3.1,50301"],
            alreadyListedTokens: []
        )

        #expect(rows.isEmpty)
    }

    /// Forward drift — the bundle is *ahead* of brew's record because the app self-updated.
    /// That is ``BrewCaskDriftFilter``'s case and must stay out of this one.
    @Test func ignoresForwardDriftWhereTheDiskIsAheadOfBrew() {
        let rows = ManualUpdateScanner.caskMetadataDriftRows(
            installedApps: [caskApp("brave-browser", name: "Brave", installed: "3.0",
                                    path: "/Applications/Brave Browser.app")],
            brewCaskVersions: ["brave-browser": "2.0"],
            alreadyListedTokens: []
        )

        #expect(rows.isEmpty)
    }

    /// A cask brew lists but tracks no version for is *not* brew-authoritative — the
    /// cask-version check already owns it (see ``BrewManagement``), so forcing a row here
    /// would duplicate that path.
    @Test func skipsCasksBrewTracksNoVersionFor() {
        let rows = ManualUpdateScanner.caskMetadataDriftRows(
            installedApps: [caskApp("postman", name: "Postman", installed: "1.0",
                                    path: "/Applications/Postman.app")],
            brewCaskVersions: [:],
            alreadyListedTokens: []
        )

        #expect(rows.isEmpty)
    }

    /// Whatever already reached the list — `brew outdated`, the cask-version check, a
    /// REL-07 forced row — must not gain a second row for the same token.
    @Test func doesNotDuplicateATokenAlreadyOnTheList() {
        let rows = ManualUpdateScanner.caskMetadataDriftRows(
            installedApps: [caskApp("discord", name: "Discord", installed: "0.0.402",
                                    path: "/Applications/Discord.app")],
            brewCaskVersions: ["discord": "0.0.403"],
            alreadyListedTokens: ["discord"]
        )

        #expect(rows.isEmpty)
    }

    /// An app with no readable bundle version gives nothing to compare; a row would be
    /// fabricated rather than observed.
    @Test func skipsAppsWithNoReadableBundleVersion() {
        let rows = ManualUpdateScanner.caskMetadataDriftRows(
            installedApps: [caskApp("figma", name: "Figma", installed: nil, path: "/Applications/Figma.app")],
            brewCaskVersions: ["figma": "2.0"],
            alreadyListedTokens: []
        )

        #expect(rows.isEmpty)
    }

    /// An unparseable "version" (a git hash, a channel name) is genuinely incomparable and
    /// must not be forced into an order — the same gate `isUpgrade` already applies.
    @Test func skipsUnparseableVersions() {
        let rows = ManualUpdateScanner.caskMetadataDriftRows(
            installedApps: [caskApp("ghostty", name: "Ghostty", installed: "tip",
                                    path: "/Applications/Ghostty.app")],
            brewCaskVersions: ["ghostty": "latest"],
            alreadyListedTokens: []
        )

        #expect(rows.isEmpty)
    }

    /// Stable (token-sorted) order so the list does not reshuffle between scans.
    @Test func forcedRowsAreDeterministicallyOrdered() {
        let rows = ManualUpdateScanner.caskMetadataDriftRows(
            installedApps: [
                caskApp("zoom", name: "Zoom", installed: "5.0", path: "/Applications/zoom.us.app"),
                caskApp("discord", name: "Discord", installed: "0.0.402", path: "/Applications/Discord.app")
            ],
            brewCaskVersions: ["zoom": "6.0", "discord": "0.0.403"],
            alreadyListedTokens: []
        )

        #expect(rows.map(\.name) == ["Discord", "Zoom"])
    }

    /// A detector nobody calls would pass every case above and surface nothing. Asserted at
    /// source level, as REL-07 does for its prune, because driving a real `scan()` needs brew,
    /// a filesystem full of apps, and the network.
    ///
    /// Red before the fix: nothing in `Sources/` called `caskMetadataDriftRows`.
    @Test func theScanFeedsTheDetectorTheAppsItAlreadyGathered() throws {
        let source = try String(
            contentsOf: packageRoot().appendingPathComponent("Sources/MacUpdaterCore/ManualUpdateScanner.swift"),
            encoding: .utf8
        )

        #expect(source.contains("Self.caskMetadataDriftRows("),
                "REL-17: `scan()` must actually call the detector, or the drift stays invisible")
        #expect(source.contains("installedApps: appsToCheck"),
                """
                REL-17: the detector must run over `appsToCheck` — the set that already excludes \
                the casks `brew outdated` reports — so a cask brew is correctly handling cannot \
                also gain a drift row.
                """)
    }

    private func packageRoot(file: String = #filePath) -> URL {
        URL(fileURLWithPath: file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
