import XCTest
@testable import MacUpdaterCore

/// `brew outdated` is treated as the single source of truth for brew-managed apps,
/// so the manual cask-version check is skipped for them. But that only holds when
/// brew actually *tracks an installed version* for the cask. Claude and Postman are
/// listed by `brew list --cask` yet their Caskroom metadata is empty (the apps
/// self-updated out-of-band), so `brew info --installed` has no version for them and
/// `brew outdated` can never report them — they must fall through to the cask-version
/// check instead of being silently deferred to a brew that can't see them.
final class BrewManagementTests: XCTestCase {

    func testTrackedInstalledCaskIsAuthoritative() {
        XCTAssertTrue(BrewManagement.isAuthoritative(
            caskToken: "discord",
            isManagedByBrew: true,
            installedCaskTokens: ["discord", "firefox", "claude"],
            brewTrackedTokens: ["discord", "firefox"]
        ))
    }

    // The bug: listed by `brew list --cask` but with no tracked version → NOT
    // authoritative, so it routes to the cask-version check and gets detected.
    func testListedButUntrackedCaskIsNotAuthoritative() {
        XCTAssertFalse(BrewManagement.isAuthoritative(
            caskToken: "claude",
            isManagedByBrew: true,
            installedCaskTokens: ["discord", "firefox", "claude"],
            brewTrackedTokens: ["discord", "firefox"]
        ))
        XCTAssertFalse(BrewManagement.isAuthoritative(
            caskToken: "postman",
            isManagedByBrew: true,
            installedCaskTokens: ["claude", "postman"],
            brewTrackedTokens: []
        ))
    }

    func testAppWithoutCaskTokenFallsBackToManagedFlag() {
        XCTAssertFalse(BrewManagement.isAuthoritative(
            caskToken: nil, isManagedByBrew: false,
            installedCaskTokens: [], brewTrackedTokens: []
        ))
    }

    func testAdoptionCandidateNotInstalledAsCaskIsNotAuthoritative() {
        // A non-brew app that merely matches an available cask token (candidate) is
        // not brew-managed — unchanged behaviour, still runs the cask-version check.
        XCTAssertFalse(BrewManagement.isAuthoritative(
            caskToken: "rectangle",
            isManagedByBrew: false,
            installedCaskTokens: ["discord"],
            brewTrackedTokens: ["discord"]
        ))
    }

    func testMatchingIsNormalizationInsensitive() {
        // Token casing / separators shouldn't break the tracked-version lookup.
        XCTAssertTrue(BrewManagement.isAuthoritative(
            caskToken: "Google-Drive",
            isManagedByBrew: true,
            installedCaskTokens: ["google-drive"],
            brewTrackedTokens: ["google_drive"]
        ))
    }
}
