import Foundation
import Testing
import MacUpdaterCore

@testable import WegaMacUpdater

@Suite("Uninstall result presentation")
struct UninstallResultPresentationTests {
    private func app(_ name: String, brew: Bool = false) -> ApplicationInfo {
        ApplicationInfo(
            path: URL(fileURLWithPath: "/Applications/\(name).app"),
            name: name,
            bundleIdentifier: "com.example.\(name.lowercased())",
            version: "1.0",
            installDate: nil,
            updateDate: nil,
            isManagedByBrew: brew,
            caskToken: brew ? name.lowercased() : nil
        )
    }

    private struct Case {
        let app: ApplicationInfo
        let result: UninstallTargetResult
        let reason: String
    }

    @Test func everySkippedAppIsNamedWithItsReason() throws {
        let staging = URL(fileURLWithPath: "/private/var/staging/Stage.app")
        let cases: [Case] = [
            Case(app: app("Running"), result: .skippedStillRunning, reason: "nadal działa"),
            Case(app: app("Twin"), result: .skippedAmbiguousProcess, reason: "procesu"),
            Case(app: app("NeedsHelper"), result: .blocked(.needsHelper), reason: "pomocnik"),
            Case(app: app("NeedsAdminAccount"), result: .blocked(.needsAdministratorAccount), reason: "konta administratora"),
            Case(app: app("NeedsRights"), result: .blocked(.needsAdministratorRights), reason: "uprawnień administratora"),
            Case(app: app("NeedsAppMgmt"), result: .blocked(.needsAppManagement), reason: "Zarządzaniu aplikacjami"),
            Case(app: app("Staged"), result: .leftInStaging(staging), reason: staging.path),
            Case(app: app("Safari"), result: .protected(.systemApplication), reason: "Aplikacja systemowa macOS"),
            Case(app: app("Broken"), result: .failed("disk on fire"), reason: "disk on fire"),
        ]
        let results = Dictionary(uniqueKeysWithValues: cases.map { ($0.app.id, $0.result) })

        let summary = UninstallResultPresentation.summary(
            results: results, apps: cases.map(\.app), leftoversTrashed: 0, leftoversFailed: 0
        )

        let error = try #require(summary.error)
        for item in cases {
            let app = item.app, reason = item.reason
            #expect(error.contains(app.name), "\(app.name) must be named")
            #expect(error.contains(reason), "\(app.name) must carry its reason \(reason)")
        }
        #expect(summary.banner == nil)
    }

    @Test func mixedSkippedAndFailedNamesBoth() throws {
        let broken = app("Broken"), stubborn = app("Stubborn")
        let summary = UninstallResultPresentation.summary(
            results: [broken.id: .failed("nope"), stubborn.id: .skippedStillRunning],
            apps: [broken, stubborn], leftoversTrashed: 0, leftoversFailed: 0
        )
        let error = try #require(summary.error)
        #expect(error.contains("Broken"))
        #expect(error.contains("Stubborn"))
    }

    @Test func nothingToReportIsEmpty() {
        let summary = UninstallResultPresentation.summary(results: [:], apps: [], leftoversTrashed: 0, leftoversFailed: 0)
        #expect(summary.banner == nil)
        #expect(summary.error == nil)
    }

    @Test func removedAppsProduceASuccessBannerAndFailuresAreSeparate() throws {
        let trashed = app("Trashed"), cask = app("Cask", brew: true), broken = app("Broken")
        let summary = UninstallResultPresentation.summary(
            results: [trashed.id: .movedToTrash, cask.id: .removedByHomebrew, broken.id: .failed("nope")],
            apps: [trashed, cask, broken], leftoversTrashed: 2, leftoversFailed: 1
        )
        let banner = try #require(summary.banner)
        #expect(banner.variant == .success)
        #expect(banner.message.contains("brew"))
        #expect(banner.message.contains("Kosza"))
        let error = try #require(summary.error)
        #expect(error.contains("Broken"))
        #expect(!error.contains("Trashed"))
        #expect(error.contains("1"), "failed leftover count is reported")
    }

    @Test func failedBrewZapKeepsItsForceNote() throws {
        let cask = app("Cask", brew: true)
        let zapped = UninstallResultPresentation.summary(
            results: [cask.id: .failed("zap failed")], apps: [cask],
            leftoversTrashed: 0, leftoversFailed: 0, requestedZap: true
        )
        #expect(try #require(zapped.error).contains("--force"))
        let plain = UninstallResultPresentation.summary(
            results: [cask.id: .failed("uninstall failed")], apps: [cask], leftoversTrashed: 0, leftoversFailed: 0
        )
        #expect(!(try #require(plain.error)).contains("--force"))
    }

    @Test func blockedResultsOfferTheirAction() {
        let target = app("Target")
        let staging = URL(fileURLWithPath: "/private/var/staging/Target.app")
        #expect(UninstallResultPresentation.actions(for: .blocked(.needsAppManagement), app: target)
                == [.openAppManagementSettings])
        #expect(UninstallResultPresentation.actions(for: .blocked(.needsAdministratorRights), app: target)
                == [.showInFinder(target.path)])
        #expect(UninstallResultPresentation.actions(for: .leftInStaging(staging), app: target)
                == [.showInFinder(staging)])
        #expect(UninstallResultPresentation.actions(for: .movedToTrash, app: target).isEmpty)
    }

    @Test func noGenericIncompleteWhenReasonKnown() throws {
        let safari = app("Safari"), blocked = app("Blocked"), running = app("Running")
        let summary = UninstallResultPresentation.summary(
            results: [
                safari.id: .protected(.systemApplication),
                blocked.id: .blocked(.needsAppManagement),
                running.id: .skippedStillRunning,
            ],
            apps: [safari, blocked, running], leftoversTrashed: 0, leftoversFailed: 0
        )
        let error = try #require(summary.error)
        #expect(!error.contains("Odinstalowanie niepełne"))
    }
}
