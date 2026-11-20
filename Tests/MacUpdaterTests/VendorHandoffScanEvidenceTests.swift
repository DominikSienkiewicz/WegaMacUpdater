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

    @Test func handoffFromASourceThatNoLongerChecksItsAppIsRetired() {
        let gitHubObsidian = gitHubHandoff("md.obsidian", repo: "obsidianmd/obsidian-releases")
        let gitHubRectangle = gitHubHandoff("com.knollsoft.Rectangle", repo: "rxhanson/Rectangle")
        #expect(VendorHandoffScanEvidence.retired([handoff(), gitHubObsidian, gitHubRectangle]) == [gitHubObsidian])
    }

    @Test func scanSeeingTheAppAtTheTargetVersionClosesAHandoffWithoutACurrentAnswer() {
        let closed = VendorHandoffScanEvidence.confirmedCurrent(
            [logiHandoff()], installationChecks: [logiCheck(version: "2.9.1013853")], stillOutdated: []
        )
        #expect(closed == [logiHandoff()])
    }

    @Test func scanSeeingTheAppBelowTheTargetKeepsTheHandoff() {
        let closed = VendorHandoffScanEvidence.confirmedCurrent(
            [logiHandoff()], installationChecks: [logiCheck(version: "2.9.994631")], stillOutdated: []
        )
        #expect(closed.isEmpty)
    }

    @Test func aReachedVersionOfAnotherBundleKeepsTheHandoff() {
        var foreign = logiCheck(version: "2.9.1013853")
        foreign = InstallationCheck(
            app: ApplicationInfo(path: foreign.path, name: "Logi", bundleIdentifier: "com.other", version: "2.9.1013853",
                                 installDate: nil, updateDate: nil, isManagedByBrew: false),
            sources: [], checkedAt: now
        )
        #expect(VendorHandoffScanEvidence.confirmedCurrent([logiHandoff()], installationChecks: [foreign], stillOutdated: []).isEmpty)
    }

    @Test func aSharedPackageRequirementNeverClosesOnTheBundleVersionAlone() {
        var shared = logiHandoff()
        shared.completionRequirement = .init(version: "2.9.1013853", field: .sharedPackage, scheme: .buildNumbered)
        #expect(VendorHandoffScanEvidence.confirmedCurrent(
            [shared], installationChecks: [logiCheck(version: "2.9.1013853")], stillOutdated: []
        ).isEmpty)
    }

    @Test func handoffOfAnAppAbsentFromACompleteScanAndFromDiskVanished() {
        let gone = VendorHandoffScanEvidence.vanished(
            [logiHandoff()], installationChecks: [], scanComplete: true, fileExists: { $0.path == "/Applications" }
        )
        #expect(gone == [logiHandoff()])
    }

    @Test func handoffIsNotVanishedWhenTheScanWasIncompleteTheBundleExistsOrACheckExists() {
        #expect(VendorHandoffScanEvidence.vanished(
            [logiHandoff()], installationChecks: [], scanComplete: false, fileExists: { $0.path == "/Applications" }
        ).isEmpty)
        #expect(VendorHandoffScanEvidence.vanished(
            [logiHandoff()], installationChecks: [], scanComplete: true, fileExists: { _ in true }
        ).isEmpty)
        #expect(VendorHandoffScanEvidence.vanished(
            [logiHandoff()], installationChecks: [logiCheck(version: "2.9.994631")], scanComplete: true, fileExists: { $0.path == "/Applications" }
        ).isEmpty)
    }

    @Test func handoffOnAnUnreachableVolumeIsNotVanished() {
        var external = logiHandoff()
        external.path = URL(fileURLWithPath: "/Volumes/Ext/Logi.app")
        #expect(VendorHandoffScanEvidence.vanished(
            [external], installationChecks: [], scanComplete: true, fileExists: { _ in false }
        ).isEmpty, "a missing parent directory means the volume is unmounted, not that the app is gone")
    }

    private func logiHandoff() -> ManualOutdatedApp {
        ManualOutdatedApp(name: "Logi Options+", path: URL(fileURLWithPath: "/Applications/logioptionsplus.app"),
                          installedVersion: "2.9.1013853", availableVersion: "2.9.1013853",
                          source: .cask(token: "logi-options+"), origin: .brew, bundleIdentifier: "com.logi.optionsplus",
                          completionRequirement: .init(version: "2.9.1013853", field: .shortVersion, scheme: .buildNumbered),
                          caskPolicyToken: "logi-options+")
    }

    private func logiCheck(version: String) -> InstallationCheck {
        InstallationCheck(
            app: ApplicationInfo(path: URL(fileURLWithPath: "/Applications/logioptionsplus.app"), name: "Logi Options+",
                                 bundleIdentifier: "com.logi.optionsplus", version: version,
                                 installDate: nil, updateDate: nil, isManagedByBrew: false),
            sources: [.init(source: "Homebrew", outcome: .notChecked)], checkedAt: now
        )
    }

    private var now: Date { Date(timeIntervalSince1970: 2_000) }

    private func gitHubHandoff(_ bundleIdentifier: String, repo: String) -> ManualOutdatedApp {
        ManualOutdatedApp(name: bundleIdentifier, path: URL(fileURLWithPath: "/Applications/\(bundleIdentifier).app"),
                          installedVersion: "1.15.0", availableVersion: "1.15.1",
                          source: .github(repo: repo, selfUpdates: true), bundleIdentifier: bundleIdentifier,
                          completionRequirement: .init(version: "1.15.1", scheme: .semver))
    }

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
