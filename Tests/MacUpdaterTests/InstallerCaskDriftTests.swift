import Foundation
import Testing
@testable import MacUpdaterCore

/// Logi Options+ installs through an installer script, so its cask declares no `.app` and the
/// drift filter never read its bundle. After the app updated itself to `2.9.1013853`, brew kept
/// recording `2.9.994631`: every scan listed the update again, and "Sprawdź tę aplikację"
/// cleared it only until the next scan. The scan already attributes that bundle to the cask
/// through its package receipt; the filter has to read that copy.
@Suite("Drift for casks that install without an .app artifact")
struct InstallerCaskDriftTests {
    private let logi = BrewOutdatedItem(
        name: "logi-options+", installedVersions: ["2.9.994631"], currentVersion: "2.9.1013853"
    )
    private let installerOnly = [BrewCaskInstallationInfo(token: "logi-options+", appArtifacts: [])]

    @Test func aReceiptAttributedBundleAtTheCaskVersionHidesTheCask() {
        let drifted = filter().driftedTokens(
            outdated: [logi], installationInfo: installerOnly,
            attributedInstallations: [installation(version: "2.9.1013853", owner: .confirmed)]
        )
        #expect(drifted == ["logi-options+"])
    }

    @Test func aReceiptAttributedBundleBehindTheCaskKeepsTheCask() {
        let drifted = filter().driftedTokens(
            outdated: [logi], installationInfo: installerOnly,
            attributedInstallations: [installation(version: "2.9.994631", owner: .confirmed)]
        )
        #expect(drifted.isEmpty)
    }

    @Test func anUnconfirmedOrMissingOwnerKeepsTheCask() {
        for installations in [[installation(version: "2.9.1013853", owner: .unconfirmed)], []] {
            let drifted = filter().driftedTokens(
                outdated: [logi], installationInfo: installerOnly, attributedInstallations: installations
            )
            #expect(drifted.isEmpty)
        }
    }

    private enum Owner { case confirmed, unconfirmed }

    private func filter() -> BrewCaskDriftFilter {
        BrewCaskDriftFilter(
            applicationsDir: URL(fileURLWithPath: "/Applications", isDirectory: true),
            userApplicationsDir: URL(fileURLWithPath: "/Users/test/Applications", isDirectory: true),
            readBundleVersion: { _ in nil }
        )
    }

    private func installation(version: String, owner: Owner) -> InstallationCheck {
        let app = ApplicationInfo(
            path: URL(fileURLWithPath: "/Applications/logioptionsplus.app"),
            name: "logioptionsplus",
            bundleIdentifier: "com.logi.optionsplus",
            version: version,
            buildVersion: version,
            installDate: nil,
            updateDate: nil,
            isManagedByBrew: true,
            caskToken: "logi-options+"
        )
        var check = InstallationCheck(app: app, sources: [], checkedAt: Date(timeIntervalSince1970: 0))
        switch owner {
        case .confirmed: check.caskToken = "logi-options+"
        case .unconfirmed: check.unconfirmedCaskToken = "logi-options+"
        }
        return check
    }
}
