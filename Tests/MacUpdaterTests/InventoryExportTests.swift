import XCTest
@testable import MacUpdaterCore

/// UX-11f — the inventory / Brewfile export. Exercises the pure text generation so the
/// bytes written to disk are pinned without a save panel or SwiftUI.
final class InventoryExportTests: XCTestCase {
    private func app(
        _ name: String,
        path: String? = nil,
        version: String? = "1.0",
        bundleId: String? = "com.example.app",
        brew: Bool = false,
        caskToken: String? = nil,
        mas: Bool = false,
        masAppID: String? = nil
    ) -> ApplicationInfo {
        ApplicationInfo(
            path: URL(fileURLWithPath: path ?? "/Applications/\(name).app"),
            name: name,
            bundleIdentifier: bundleId,
            version: version,
            installDate: nil,
            updateDate: nil,
            isManagedByBrew: brew,
            caskToken: caskToken,
            isManagedByMas: mas,
            masAppID: masAppID
        )
    }

    // MARK: Brewfile

    func testBrewfileEmitsCaskAndMasEntries() {
        let apps = [
            app("Firefox", brew: true, caskToken: "firefox"),
            app("Xcode", mas: true, masAppID: "497799835"),
        ]

        let brewfile = InventoryExport.brewfile(apps: apps)

        XCTAssertTrue(brewfile.contains("cask \"firefox\""), brewfile)
        XCTAssertTrue(brewfile.contains("mas \"Xcode\", id: 497799835"), brewfile)
    }

    func testBrewfileSortsAndDeduplicatesCasks() {
        let apps = [
            app("Zoom", path: "/Applications/Zoom.app", brew: true, caskToken: "zoom"),
            app("Firefox", path: "/Applications/Firefox.app", brew: true, caskToken: "firefox"),
            // REL-16: a second copy of one app shares the token — one install line, not two.
            app("Firefox", path: "/Applications/Old/Firefox.app", brew: true, caskToken: "firefox"),
        ]

        let brewfile = InventoryExport.brewfile(apps: apps)

        let caskLines = brewfile.split(separator: "\n").map(String.init).filter { $0.hasPrefix("cask ") }
        XCTAssertEqual(caskLines, ["cask \"firefox\"", "cask \"zoom\""])
    }

    func testBrewfileDeduplicatesMasByAppStoreID() {
        let apps = [
            app("Keynote", path: "/Applications/Keynote.app", mas: true, masAppID: "409183694"),
            app("Keynote", path: "/Applications/Keynote 2.app", mas: true, masAppID: "409183694"),
        ]

        let masLines = InventoryExport.brewfile(apps: apps)
            .split(separator: "\n").map(String.init).filter { $0.hasPrefix("mas ") }

        XCTAssertEqual(masLines, ["mas \"Keynote\", id: 409183694"])
    }

    func testBrewfileRecordsManualAppsAsComments() {
        let apps = [app("Custom Tool", version: "2.1", bundleId: "com.custom.tool")]

        let brewfile = InventoryExport.brewfile(apps: apps)

        XCTAssertTrue(brewfile.contains("# Installed outside Homebrew/App Store"), brewfile)
        XCTAssertTrue(brewfile.contains("# - Custom Tool 2.1 (com.custom.tool)"), brewfile)
        XCTAssertFalse(brewfile.contains("cask "), brewfile)
    }

    func testBrewfileRecordsNpmGlobalsAsComments() {
        let brewfile = InventoryExport.brewfile(
            apps: [],
            npmGlobals: [NpmGlobalPackage(name: "typescript", installedVersion: "5.4.0")]
        )

        XCTAssertTrue(brewfile.contains("# Global npm packages"), brewfile)
        XCTAssertTrue(brewfile.contains("# - typescript@5.4.0"), brewfile)
    }

    func testBrewfileEscapesQuotesInMasName() {
        let apps = [app("My \"Cool\" App", mas: true, masAppID: "123")]

        let brewfile = InventoryExport.brewfile(apps: apps)

        XCTAssertTrue(brewfile.contains("mas \"My \\\"Cool\\\" App\", id: 123"), brewfile)
    }

    func testBrewfileIsStableAcrossReExport() {
        let apps = [
            app("Firefox", brew: true, caskToken: "firefox"),
            app("Xcode", mas: true, masAppID: "497799835"),
            app("Manual", bundleId: "com.manual.app"),
        ]

        XCTAssertEqual(InventoryExport.brewfile(apps: apps), InventoryExport.brewfile(apps: apps))
    }

    func testEmptyInventoryStillProducesHeaderOnlyBrewfile() {
        let brewfile = InventoryExport.brewfile(apps: [])

        XCTAssertTrue(brewfile.hasPrefix("# Brewfile"), brewfile)
        XCTAssertFalse(brewfile.contains("cask "), brewfile)
        XCTAssertFalse(brewfile.contains("mas "), brewfile)
    }

    // MARK: CSV

    func testCSVHasHeaderAndOneRowPerApp() {
        let apps = [
            app("Firefox", path: "/Applications/Firefox.app", version: "120.0",
                bundleId: "org.mozilla.firefox", brew: true, caskToken: "firefox"),
            app("Xcode", path: "/Applications/Xcode.app", version: "15.0",
                bundleId: "com.apple.dt.Xcode", mas: true, masAppID: "497799835"),
        ]

        let rows = InventoryExport.csv(apps: apps).components(separatedBy: "\r\n")

        XCTAssertEqual(rows[0], "Name,Version,Bundle ID,Source,Cask,App Store ID,Path")
        XCTAssertEqual(rows[1], "Firefox,120.0,org.mozilla.firefox,brew,firefox,,/Applications/Firefox.app")
        XCTAssertEqual(rows[2], "Xcode,15.0,com.apple.dt.Xcode,mas,,497799835,/Applications/Xcode.app")
    }

    func testCSVQuotesFieldsWithCommasAndQuotes() {
        let apps = [app("Comma, Inc \"App\"", path: "/Applications/App.app", version: nil, bundleId: nil)]

        let rows = InventoryExport.csv(apps: apps).components(separatedBy: "\r\n")

        XCTAssertEqual(rows[1], "\"Comma, Inc \"\"App\"\"\",,,manual,,,/Applications/App.app")
    }

    func testCSVAppendsNpmGlobals() {
        let rows = InventoryExport.csv(
            apps: [],
            npmGlobals: [NpmGlobalPackage(name: "eslint", installedVersion: "9.0.0")]
        ).components(separatedBy: "\r\n")

        XCTAssertEqual(rows[1], "eslint,9.0.0,,npm,,,")
    }

    func testCSVLinesEndWithCRLF() {
        let csv = InventoryExport.csv(apps: [app("A")])

        XCTAssertTrue(csv.hasSuffix("\r\n"), csv)
        XCTAssertTrue(csv.contains("\r\n"), csv)
    }
}
