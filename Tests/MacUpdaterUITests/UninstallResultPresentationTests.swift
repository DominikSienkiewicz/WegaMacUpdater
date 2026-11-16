import Foundation
import Testing
import MacUpdaterCore

@testable import WegaMacUpdater

@Suite("Uninstall result presentation")
struct UninstallResultPresentationTests {
    private func app(_ name: String, brew: Bool = false, folder: String = "/Applications") -> ApplicationInfo {
        ApplicationInfo(
            path: URL(fileURLWithPath: "\(folder)/\(name).app"),
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

    /// Spec 2 / 4.5: every app that was not removed is named with its own reason and action,
    /// one row each, so no reason is cut off by a line limit shared with the others.
    @Test func everyAppNotRemovedIsItsOwnRowWithNameReasonAndActions() throws {
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

        let report = UninstallResultPresentation.report(
            results: results, apps: cases.map(\.app), leftoversTrashed: 0, leftoversFailed: 0
        )

        #expect(report.rows.map(\.id) == cases.map(\.app.id))
        for (row, item) in zip(report.rows, cases) {
            #expect(row.name == item.app.name)
            #expect(row.reason.contains(item.reason), "\(item.app.name) must carry its reason \(item.reason)")
            #expect(row.actions == UninstallResultPresentation.actions(for: item.result, app: item.app))
        }
        #expect(report.banner == nil)
        let summary = try #require(report.summary)
        #expect(!summary.contains("\n"), "the banner keeps one summary line; the reasons live in the rows")
    }

    @Test func mixedSkippedAndFailedNamesBoth() throws {
        let broken = app("Broken"), stubborn = app("Stubborn")
        let report = UninstallResultPresentation.report(
            results: [broken.id: .failed("nope"), stubborn.id: .skippedStillRunning],
            apps: [broken, stubborn], leftoversTrashed: 0, leftoversFailed: 0
        )
        #expect(report.rows.map(\.name) == ["Broken", "Stubborn"])
        let summary = try #require(report.summary)
        #expect(summary.contains("Broken"), "the incomplete note names the failed app")
    }

    @Test func nothingToReportIsEmpty() {
        let report = UninstallResultPresentation.report(results: [:], apps: [], leftoversTrashed: 0, leftoversFailed: 0)
        #expect(report.banner == nil)
        #expect(report.summary == nil)
        #expect(report.rows.isEmpty)
    }

    /// Spec 4.5: removed apps are named with their category, not only counted.
    @Test func removedAppsAreNamedInTheSuccessBannerAndFailuresAreSeparate() throws {
        let trashed = app("Trashed"), cask = app("Cask", brew: true), broken = app("Broken")
        let report = UninstallResultPresentation.report(
            results: [trashed.id: .movedToTrash, cask.id: .removedByHomebrew, broken.id: .failed("nope")],
            apps: [trashed, cask, broken], leftoversTrashed: 2, leftoversFailed: 1
        )
        let banner = try #require(report.banner)
        #expect(banner.variant == .success)
        #expect(banner.message.contains("Trashed do Kosza"))
        #expect(banner.message.contains("Cask przez brew"))
        #expect(banner.message.contains("2 resztek do Kosza"))
        #expect(report.rows.map(\.id) == [broken.id])
        let summary = try #require(report.summary)
        #expect(summary.contains("Nie udało się przenieść 1 resztek do Kosza."), "failed leftover count is reported")
    }

    /// Spec 4.5: an app Wega's helper removed is named in its own category, apart from a plain
    /// move to the Trash.
    @Test func removedThroughTheHelperIsItsOwnCategory() throws {
        let helped = app("Helped"), trashed = app("Trashed")
        let report = UninstallResultPresentation.report(
            results: [helped.id: .movedToTrashByHelper, trashed.id: .movedToTrash],
            apps: [helped, trashed], leftoversTrashed: 0, leftoversFailed: 0
        )

        let banner = try #require(report.banner)
        #expect(banner.message.contains("Helped do Kosza przez pomocnika Wega"))
        #expect(banner.message.contains("Trashed do Kosza"))
        #expect(!banner.message.contains("Trashed do Kosza przez"))
        #expect(report.rows.isEmpty)
        #expect(report.summary == nil)
    }

    /// The helper's switch is in Wega's Settings window (`InfoView`'s helper card), so the
    /// "needs Wega's helper" row's button opens that window.
    @Test func helperSettingsActionOpensWegasSettingsWindow() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let view = try String(
            contentsOf: root.appendingPathComponent("Sources/MacUpdater/UninstallView.swift"), encoding: .utf8
        )
        let branchStart = try #require(view.range(of: "case .openHelperSettings:"))
        let branch = view[branchStart.upperBound...].prefix { $0 != "}" }

        #expect(view.contains("@Environment(\\.openSettings) private var openSettings"))
        #expect(branch.contains("openSettings()"))
    }

    @Test func failedBrewZapKeepsItsForceNote() throws {
        let cask = app("Cask", brew: true)
        let zapped = UninstallResultPresentation.report(
            results: [cask.id: .failed("zap failed")], apps: [cask],
            leftoversTrashed: 0, leftoversFailed: 0, requestedZap: true
        )
        #expect(try #require(zapped.summary).contains("--force"))
        let plain = UninstallResultPresentation.report(
            results: [cask.id: .failed("uninstall failed")], apps: [cask], leftoversTrashed: 0, leftoversFailed: 0
        )
        #expect(!(try #require(plain.summary)).contains("--force"))
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
        #expect(UninstallResultPresentation.actions(for: .blocked(.needsHelper), app: target)
                == [.openHelperSettings, .showInFinder(target.path)])
        #expect(UninstallResultPresentation.actions(for: .blocked(.needsAdministratorAccount), app: target)
                == [.showInFinder(target.path)])
        #expect(UninstallResultPresentation.actions(for: .movedToTrash, app: target).isEmpty)
    }

    @Test func noGenericIncompleteWhenReasonKnown() throws {
        let safari = app("Safari"), blocked = app("Blocked"), running = app("Running")
        let report = UninstallResultPresentation.report(
            results: [
                safari.id: .protected(.systemApplication),
                blocked.id: .blocked(.needsAppManagement),
                running.id: .skippedStillRunning,
            ],
            apps: [safari, blocked, running], leftoversTrashed: 0, leftoversFailed: 0
        )
        let summary = try #require(report.summary)
        #expect(!summary.contains("Odinstalowanie niepełne"))
        #expect(report.rows.allSatisfy { !$0.reason.contains("Odinstalowanie niepełne") })
    }

    /// A brew failure carries brew's whole, untranslated stderr. The row shows its `Error:`
    /// line; the full text stays reachable as the row's detail, and never reaches the summary.
    @Test func brewFailureIsShortenedToItsErrorLine() throws {
        let cask = app("Cask", brew: true)
        let noise = (1...40).map { "==> step \($0) of a long brew transcript" }.joined(separator: "\n")
        let stderr = "\(noise)\nError: Cask 'cask' is not installed.\n"
        let failure = BrewServiceError.commandFailed(
            arguments: ["uninstall", "--cask", "--", "cask"],
            result: ProcessResult(exitCode: 1, stdout: "", stderr: stderr)
        ).localizedDescription

        let report = UninstallResultPresentation.report(
            results: [cask.id: .failed(failure)], apps: [cask], leftoversTrashed: 0, leftoversFailed: 0
        )

        let row = try #require(report.rows.first)
        #expect(row.reason == "Error: Cask 'cask' is not installed.")
        #expect(row.detail == failure.trimmingCharacters(in: .whitespacesAndNewlines))
        let summary = try #require(report.summary)
        #expect(!summary.contains("==> step"))
        #expect(!summary.contains("\n"))
    }

    @Test func errorOnTheFirstStderrLineIsFound() {
        let failure = BrewServiceError.commandFailed(
            arguments: ["uninstall", "--cask", "--", "cask"],
            result: ProcessResult(exitCode: 1, stdout: "", stderr: "Error: Cask 'cask' is not installed.\n")
        ).localizedDescription

        let shortened = UninstallResultPresentation.failureReason(failure)

        #expect(shortened.reason == "Error: Cask 'cask' is not installed.")
        #expect(shortened.detail != nil)
    }

    @Test func aOneLineFailureHasNoSeparateDetail() {
        let shortened = UninstallResultPresentation.failureReason("The file couldn't be moved.")
        #expect(shortened.reason == "The file couldn't be moved.")
        #expect(shortened.detail == nil)
    }

    /// REL-16: two copies of one app never share a row id, a location or a Finder target.
    @Test func twoCopiesOfOneAppGetDistinctRows() throws {
        let system = app("Twin"), user = app("Twin", folder: "/Users/me/Applications")
        let report = UninstallResultPresentation.report(
            results: [
                system.id: .blocked(.needsAdministratorRights),
                user.id: .blocked(.needsAdministratorRights),
            ],
            apps: [system, user], leftoversTrashed: 0, leftoversFailed: 0
        )

        #expect(report.rows.map(\.id) == [system.id, user.id])
        #expect(Set(report.rows.map(\.id)).count == 2)
        #expect(report.rows.map(\.location) == [system.locationLabel, user.locationLabel])
        #expect(report.rows.map(\.actions) == [[.showInFinder(system.path)], [.showInFinder(user.path)]])
    }

    @Test func aUniqueAppShowsNoLocation() throws {
        let only = app("Only")
        let report = UninstallResultPresentation.report(
            results: [only.id: .skippedStillRunning], apps: [only], leftoversTrashed: 0, leftoversFailed: 0
        )
        #expect(try #require(report.rows.first).location == nil)
    }
}
