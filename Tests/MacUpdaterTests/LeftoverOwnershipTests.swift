import Foundation
import Testing
@testable import MacUpdaterCore

@Suite("LeftoverPlanner ownership guard")
struct LeftoverOwnershipTests {
    private let fixture: LeftoverTestHome

    init() throws {
        fixture = try LeftoverTestHome()
    }

    private func plan(
        _ targets: [LeftoverApp], alsoRemoved: [LeftoverApp] = [], others: [LeftoverApp] = []
    ) -> [LeftoverPlanGroup] {
        LeftoverPlanner.plan(
            targets: targets, alsoRemoved: alsoRemoved, others: others, home: fixture.home,
            fileSystem: LiveCleanupFileSystem()
        )
    }

    private func item(_ url: URL, in groups: [LeftoverPlanGroup]) -> LeftoverItem? {
        groups.flatMap(\.items).first { $0.url == url }
    }

    private func app(
        id: String,
        name: String,
        fileName: String? = nil,
        path: String? = nil,
        bundleID: String?,
        team: String? = nil,
        zap: [String] = [],
        provenance: CaskMatchProvenance = .bundleIdentifier
    ) -> LeftoverApp {
        LeftoverApp(
            id: id, name: name, fileName: fileName ?? name, path: path ?? "/Applications/\(name).app",
            bundleIdentifier: bundleID, teamIdentifier: team,
            cask: zap.isEmpty ? nil : LeftoverCaskEvidence(token: id, zapTrashPaths: zap, provenance: provenance)
        )
    }

    // MARK: - Other installed apps

    @Test func longestBundleIDOwnsBothWays() throws {
        let stable = try fixture.folder("Library/Caches/com.google.Chrome")
        let canary = try fixture.folder("Library/Caches/com.google.Chrome.canary")
        let zap = ["~/Library/Caches/com.google.Chrome*"]

        let chromeRun = plan(
            [app(id: "chrome", name: "Google Chrome", bundleID: "com.google.Chrome", zap: zap)],
            others: [app(id: "canary", name: "Google Chrome Canary", bundleID: "com.google.Chrome.canary")]
        )

        #expect(item(stable, in: chromeRun)?.sharedWith == [])
        #expect(item(stable, in: chromeRun)?.isSelectedByDefault == true)
        #expect(item(canary, in: chromeRun)?.sharedWith == ["Google Chrome Canary"])
        #expect(item(canary, in: chromeRun)?.isSelectedByDefault == false)

        let canaryRun = plan(
            [app(id: "canary", name: "Google Chrome Canary", bundleID: "com.google.Chrome.canary", zap: zap)],
            others: [app(id: "chrome", name: "Google Chrome", bundleID: "com.google.Chrome")]
        )

        #expect(item(stable, in: canaryRun)?.sharedWith == ["Google Chrome"])
        #expect(item(stable, in: canaryRun)?.isSelectedByDefault == false)
        #expect(item(canary, in: canaryRun)?.sharedWith == [])
        #expect(item(canary, in: canaryRun)?.isSelectedByDefault == true)
    }

    @Test func secondCopyClaimsEverything() throws {
        let paths: Set<URL> = try [
            fixture.folder("Library/Application Support/obsidian"),
            fixture.file("Library/Preferences/md.obsidian.plist"),
            fixture.folder("Library/Caches/md.obsidian"),
            fixture.folder("Library/Group Containers/ABCDE12345.md.obsidian"),
            fixture.folder("Library/Group Containers/group.md.obsidian"),
            fixture.folder("Library/Logs/Obsidian"),
        ]
        let target = app(
            id: "target", name: "Obsidian", bundleID: "md.obsidian", team: "ABCDE12345",
            zap: ["~/Library/Application Support/obsidian"]
        )
        let secondCopy = app(id: "copy", name: "Obsidian", path: "~/Applications/Obsidian.app", bundleID: "MD.Obsidian")

        let items = plan([target], others: [secondCopy]).flatMap(\.items)

        #expect(Set(items.map(\.url)) == paths)
        #expect(items.allSatisfy { $0.sharedWith == ["Obsidian — ~/Applications/Obsidian.app"] })
        #expect(items.allSatisfy { !$0.isSelectedByDefault && $0.coTargets.isEmpty })
    }

    @Test func otherAppsZapPatternClaims() throws {
        let caches = try fixture.folder("Library/Caches/com.acme.app")
        let named = try fixture.folder("Library/Application Support/Acme")
        let logs = try fixture.folder("Library/Logs/com.acme.app")
        let suite = app(
            id: "suite", name: "Acme Suite", bundleID: "com.acmesuite.app",
            zap: ["~/Library/Caches/com.acme.*", "~/library/application support/ACME"], provenance: .displayName
        )

        let groups = plan([app(id: "target", name: "Acme", bundleID: "com.acme.app")], others: [suite])

        #expect(item(caches, in: groups)?.sharedWith == ["Acme Suite"])
        #expect(item(named, in: groups)?.sharedWith == ["Acme Suite"])
        #expect(item(logs, in: groups)?.sharedWith == [])
    }

    @Test func folderContainingAnotherAppsZapPathIsShared() throws {
        let vendor = try fixture.folder("Library/Application Support/Vendor")
        let own = try fixture.folder("Library/Application Support/Vendor/A")
        try fixture.folder("Library/Application Support/Vendor/B")
        let target = app(id: "a", name: "Vendor A", bundleID: "com.vendor.a", zap: [
            "~/Library/Application Support/Vendor", "~/Library/Application Support/Vendor/A",
        ])
        let others = [
            app(id: "b", name: "Vendor B", bundleID: "com.vendor.b", zap: ["~/Library/Application Support/Vendor/B"]),
            app(id: "c", name: "Vendor C", bundleID: "com.vendor.c", zap: ["~/Library/Application Support/Vendor/C*"]),
        ]

        let groups = plan([target], others: others)

        #expect(item(vendor, in: groups)?.sharedWith == ["Vendor B", "Vendor C"])
        #expect(item(own, in: groups)?.sharedWith == [])
    }

    @Test func wildcardInAMiddleComponentStillClaims() throws {
        let vendor = try fixture.folder("Library/Application Support/Vendor")
        let cache = try fixture.folder("Library/Caches/com.vendor.b.x")
        let target = app(id: "a", name: "Vendor A", bundleID: "com.vendor.a", zap: [
            "~/Library/Application Support/Vendor", "~/Library/Caches/com.vendor.*",
        ])
        let others = [
            app(id: "middle", name: "Middle", bundleID: nil, zap: ["~/Library/*/Vendor/X"]),
            app(id: "plain", name: "Plain", bundleID: nil, zap: ["~/Library/Caches/com.vendor.b*"]),
            app(id: "doubleStar", name: "Double Star", bundleID: nil, zap: ["~/Library/Caches/com.vendor.b**"]),
            app(id: "braces", name: "Braces", bundleID: nil, zap: ["~/Library/Caches/com.vendor.{b,c}*"]),
        ]

        let groups = plan([target], others: others)

        #expect(item(vendor, in: groups)?.sharedWith == ["Middle"])
        #expect(item(cache, in: groups)?.sharedWith == ["Plain", "Double Star", "Braces"])
    }

    @Test func groupAndTeamContainersOfAnotherAppAreClaimed() throws {
        let otherTeam = try fixture.folder("Library/Group Containers/ABCDE12345.com.vendor.b")
        let otherGroup = try fixture.folder("Library/Group Containers/group.com.vendor.b")
        let ownTeam = try fixture.folder("Library/Group Containers/ABCDE12345.com.vendor.a")
        let target = app(
            id: "a", name: "Vendor A", bundleID: "com.vendor.a", team: "ABCDE12345",
            zap: ["~/Library/Group Containers/*.vendor*"]
        )

        let groups = plan([target], others: [app(id: "b", name: "Vendor B", bundleID: "com.vendor.b")])

        #expect(item(otherTeam, in: groups)?.sharedWith == ["Vendor B"])
        #expect(item(otherGroup, in: groups)?.sharedWith == ["Vendor B"])
        #expect(item(ownTeam, in: groups)?.sharedWith == [])
    }

    @Test func sameNameClaimsNameItems() throws {
        let named = try fixture.folder("Library/Application Support/Acme")
        let zapped = try fixture.folder("Library/Logs/Acme")
        let caches = try fixture.folder("Library/Caches/com.acme.app")
        let target = app(id: "target", name: "Acme", bundleID: "com.acme.app", zap: ["~/Library/Logs/Acme"])
        let others = [
            app(id: "namesake", name: "ACME", path: "/Applications/Other/ACME.app", bundleID: "org.other.acme"),
            app(id: "studio", name: "Acme Studio", fileName: "acme", bundleID: "com.studio.app"),
        ]

        let groups = plan([target], others: others)

        #expect(item(named, in: groups)?.source == .appName)
        #expect(item(named, in: groups)?.sharedWith == ["ACME — /Applications/Other/ACME.app", "Acme Studio"])
        #expect(item(zapped, in: groups)?.source == .homebrewZap(token: "target"))
        #expect(item(zapped, in: groups)?.sharedWith == [])
        #expect(item(caches, in: groups)?.sharedWith == [])
    }

    // MARK: - Apps of the same run

    @Test func coTargetsDoNotShareButAreRecorded() throws {
        let caches = try fixture.folder("Library/Caches/com.acme.app")
        let helperHostPreferences = try fixture.file("Library/Preferences/ByHost/com.acme.app.helper.0000-1111.plist")
        let first = app(id: "first", name: "Acme", bundleID: "com.acme.app")
        let second = app(id: "second", name: "Acme", path: "~/Applications/Acme.app", bundleID: "com.acme.app")
        let helper = app(id: "helper", name: "Acme Helper", bundleID: "com.acme.app.helper")

        let groups = plan([first, second], alsoRemoved: [helper])

        #expect(groups.map(\.appID) == ["first"])
        #expect(groups.flatMap(\.items).count == 2)
        #expect(item(caches, in: groups)?.coTargets == ["second"])
        #expect(item(helperHostPreferences, in: groups)?.coTargets == ["second", "helper"])
        #expect(groups.flatMap(\.items).allSatisfy { $0.sharedWith.isEmpty && $0.isSelectedByDefault })
    }

    // MARK: - Bundle-id rule

    @Test func stateSuffixIsNotPartOfABundleID() {
        let chrome = app(id: "chrome", name: "Google Chrome", bundleID: "com.google.Chrome")
        func claims(_ name: String, byAppWithBundleID bundleID: String) -> Bool {
            let other = app(id: "other", name: "Other", bundleID: bundleID)
            return LeftoverOwnership.claims(
                item: ["Library", "Caches", name], source: .bundleIdentifier,
                target: chrome, by: other, allApps: [chrome, other]
            )
        }

        #expect(claims("com.google.Chrome.json", byAppWithBundleID: "com.google.Chrome.json"))
        #expect(claims("COM.GOOGLE.CHROME.CANARY.SFL3", byAppWithBundleID: "com.google.Chrome.canary"))
        for suffix in [".plist", ".savedState", ".binarycookies", ".sfl", ".sfl3", ".SFL12"] {
            #expect(!claims("com.google.Chrome\(suffix)", byAppWithBundleID: "com.google.Chrome\(suffix)"))
        }
    }
}
