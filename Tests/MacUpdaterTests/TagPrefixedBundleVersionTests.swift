import Foundation
import Testing
@testable import MacUpdaterCore

/// Raspberry Pi Imager writes its version as a git tag, `v2.0.12`, into both
/// `CFBundleShortVersionString` and `CFBundleVersion`, while the cask records `2.0.12`.
/// The tolerant parser dropped the `v2` component (`Int("v2")` is `nil`) and read the
/// bundle as `0.12`, so the REL-17 drift detector offered `2.0.12` as an update, and the
/// arrival check after `brew reinstall` reported "nothing installed" for the same reason.
@Suite("Tag-prefixed bundle versions compare as the version they name")
struct TagPrefixedBundleVersionTests {

    @Test func aVPrefixedBundleVersionEqualsTheUnprefixedCaskVersion() {
        #expect(versionsEqual("v2.0.12", "2.0.12"))
        #expect(compareVersions("v2.0.12", "2.0.12", scheme: .buildNumbered) == .orderedSame)
        #expect(!isUpgrade(installed: "v2.0.12", latest: "2.0.12"))
        #expect(isUpgrade(installed: "v2.0.12", latest: "2.0.13"))
    }

    @Test func aCurrentRaspberryPiImagerProducesNoCaskDriftRow() {
        let imager = ApplicationInfo(
            path: URL(fileURLWithPath: "/Applications/Raspberry Pi Imager.app"),
            name: "Raspberry Pi Imager",
            bundleIdentifier: "com.raspberrypi.rpi-imager",
            version: "v2.0.12",
            buildVersion: "v2.0.12",
            installDate: nil,
            updateDate: nil,
            isManagedByBrew: true,
            caskToken: "raspberry-pi-imager"
        )
        let rows = ManualUpdateScanner.caskMetadataDriftRows(
            installedApps: [imager],
            brewCaskVersions: ["raspberry-pi-imager": "2.0.12"],
            alreadyListedTokens: []
        )
        #expect(rows.isEmpty)
    }

    @Test func reinstallingTheVersionAlreadyOnDiskIsNotReportedAsANoOp() {
        let installedNothing = UpdateOperationRecoveryPlan.installedNothing(
            evidence: .forcedReinstall(expectedVersion: "2.0.12"),
            installedVersion: "v2.0.12",
            snapshotVersion: "v2.0.12"
        )
        #expect(!installedNothing)
    }
}
