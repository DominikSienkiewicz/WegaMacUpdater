import XCTest
@testable import MacUpdaterCore

/// Pins the mapping from a concrete update source to its provenance family, the
/// single source of truth the Updates window uses to colour-code source badges.
/// A regression here would silently repaint every source badge the same colour.
final class ProvenanceTests: XCTestCase {
    func testCaskIsHomebrew() {
        XCTAssertEqual(ManualOutdatedApp.UpdateSource.cask(token: "x").provenance, .homebrew)
    }

    func testMasIsAppStore() {
        XCTAssertEqual(ManualOutdatedApp.UpdateSource.mas(appStoreID: "1").provenance, .appStore)
    }

    func testJetbrainsIsJetbrains() {
        XCTAssertEqual(ManualOutdatedApp.UpdateSource.jetbrains(caskToken: "idea").provenance, .jetbrains)
    }

    func testGithubIsGithub() {
        XCTAssertEqual(ManualOutdatedApp.UpdateSource.github(repo: "o/r").provenance, .github)
    }

    func testSparkleIsSparkle() {
        XCTAssertEqual(ManualOutdatedApp.UpdateSource.sparkle.provenance, .sparkle)
    }

    func testSynologyIsSynology() {
        XCTAssertEqual(ManualOutdatedApp.UpdateSource.synology(downloadPage: "p").provenance, .synology)
    }

    // These self-updating vendor apps ship their own updater while their Homebrew
    // cask lags upstream; they all share the vendorDirect provenance family.
    func testVendorDirectSources() {
        let sources: [ManualOutdatedApp.UpdateSource] = [
            .antigravity, .parallels, .googleDrive, .chatgpt, .postman, .discord, .signal, .chrome
        ]
        for source in sources {
            XCTAssertEqual(source.provenance, .vendorDirect, "\(source) should classify as .vendorDirect")
        }
    }
}
