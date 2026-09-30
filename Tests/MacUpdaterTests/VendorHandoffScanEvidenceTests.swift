import Foundation
import Testing
@testable import MacUpdaterCore

@Suite("A full scan closes a vendor handoff only on positive evidence")
struct VendorHandoffScanEvidenceTests {
    @Test func currentAnswerFromTheHandoffSourceClosesIt() {
        let closed = VendorHandoffScanEvidence.confirmedCurrent(
            [handoff()], installationChecks: [check(outcome: .current)], stillOutdated: []
        )
        #expect(closed == [handoff()])
    }

    @Test func failedOrUncheckedSourceKeepsIt() {
        for outcome in [InstallationSourceCheck.Outcome.failed, .notChecked, .outdated] {
            let closed = VendorHandoffScanEvidence.confirmedCurrent(
                [handoff()], installationChecks: [check(outcome: outcome)], stillOutdated: []
            )
            #expect(closed.isEmpty, "\(outcome) is not evidence that the vendor update finished")
        }
    }

    @Test func missingCheckOrMissingSourceKeepsIt() {
        #expect(VendorHandoffScanEvidence.confirmedCurrent([handoff()], installationChecks: [], stillOutdated: []).isEmpty)
        let otherSourceOnly = check(outcome: .current, source: "Homebrew")
        #expect(VendorHandoffScanEvidence.confirmedCurrent(
            [handoff()], installationChecks: [otherSourceOnly], stillOutdated: []
        ).isEmpty)
    }

    @Test func differentBundleOrPathKeepsIt() {
        var otherBundle = app(version: "1.14.3")
        otherBundle.bundleIdentifier = "md.other"
        var otherPath = app(version: "1.14.3")
        otherPath.path = URL(fileURLWithPath: "/Other/Obsidian.app")
        for installed in [otherBundle, otherPath] {
            let foreign = InstallationCheck(app: installed, sources: [.init(source: "Obsidian", outcome: .current)], checkedAt: now)
            #expect(VendorHandoffScanEvidence.confirmedCurrent(
                [handoff()], installationChecks: [foreign], stillOutdated: []
            ).isEmpty)
        }
    }

    @Test func installationTheScanStillListsAsOutdatedKeepsIt() {
        var newer = handoff()
        newer.availableVersion = "1.14.4"
        let closed = VendorHandoffScanEvidence.confirmedCurrent(
            [handoff()], installationChecks: [check(outcome: .current)], stillOutdated: [newer]
        )
        #expect(closed.isEmpty)
    }

    @Test func sharedPackageUpdateClosesOnSourceEvidenceEvenWhenTheBundleStaysOld() {
        let asarUpdated = InstallationCheck(app: app(version: "1.12.7"), sources: [.init(source: "Obsidian", outcome: .current)], checkedAt: now)
        #expect(VendorHandoffScanEvidence.confirmedCurrent(
            [handoff()], installationChecks: [asarUpdated], stillOutdated: []
        ) == [handoff()])
    }

    private var now: Date { Date(timeIntervalSince1970: 2_000) }

    private func check(outcome: InstallationSourceCheck.Outcome, source: String = "Obsidian") -> InstallationCheck {
        InstallationCheck(app: app(version: "1.14.3"), sources: [.init(source: source, outcome: outcome)], checkedAt: now)
    }

    private func handoff() -> ManualOutdatedApp {
        ManualOutdatedApp(name: "Obsidian", path: app(version: "1.14.2").path, installedVersion: "1.14.2",
                          availableVersion: "1.14.3", source: .obsidian, bundleIdentifier: "md.obsidian",
                          completionRequirement: .init(version: "1.14.3", field: .sharedPackage, scheme: .semver))
    }

    private func app(version: String) -> ApplicationInfo {
        ApplicationInfo(path: URL(fileURLWithPath: "/Applications/Obsidian.app"), name: "Obsidian",
                        bundleIdentifier: "md.obsidian", version: version, buildVersion: version,
                        installDate: nil, updateDate: nil, isManagedByBrew: false)
    }
}
