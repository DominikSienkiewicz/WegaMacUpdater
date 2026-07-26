import Testing
import Foundation
@testable import MacUpdaterCore

/// UX-11g — the menu-bar dropdown used to report only *how many* updates were found, never
/// *which* apps. These tests pin the projection the dropdown lists from: the display names
/// of everything a background check found outdated, in the badge's order and under the same
/// ignore/pin rules — so the list can never disagree with the count next to it.
@Suite("MenuBarScanResult names")
struct MenuBarScanResultNamesTests {

    private func manual(_ name: String) -> ManualOutdatedApp {
        ManualOutdatedApp(name: name,
                          path: URL(fileURLWithPath: "/Applications/\(name).app"),
                          installedVersion: "1.0", availableVersion: "2.0", source: .sparkle)
    }

    /// A result shaped exactly the way `MenuBarUpdateChecker` builds one, with `total`
    /// computed the way the checker computes it (policy-filtered items + manual).
    private func checkerResult(policies: [String: UpdatePolicy] = [:]) -> MenuBarScanResult {
        let brew = BrewOutdated(
            formulae: [BrewOutdatedItem(name: "wget", installedVersions: ["1.0"], currentVersion: "1.1")],
            casks:    [BrewOutdatedItem(name: "figma", installedVersions: ["1.0"], currentVersion: "2.0")]
        )
        let mas = [MasOutdatedApp(appStoreID: "409183694", name: "Keynote",
                                  installedVersion: "13.0", currentVersion: "14.0")]
        let npm = [NpmGlobalOutdated(name: "typescript", installedVersion: "5.3", latestVersion: "5.4")]
        let manualApps = [manual("Zed")]

        let items = UpdatePlanner.applyPolicies(
            UpdatePlanner.outdatedItems(brew: brew, mas: mas, npm: npm), policies: policies
        )
        let visibleManual = UpdatePlanner.applyPolicies(manualApps, policies: policies)
        return MenuBarScanResult(
            brew: brew, mas: mas, npm: npm, manualApps: manualApps,
            failedChecks: 0, scannedAt: Date(), total: items.count + visibleManual.count
        )
    }

    /// The dropdown lists every source, in the badge's order: formulae, casks, App Store,
    /// npm, then the manually-checked apps.
    @Test func namesCoverEverySourceInBadgeOrder() {
        let names = checkerResult().outdatedDisplayNames()

        #expect(names == ["wget", "figma", "Keynote", "typescript", "Zed"])
    }

    /// The list must never disagree with the number beside it: one name per counted update.
    @Test func nameCountMatchesBadgeTotal() {
        let result = checkerResult()

        #expect(result.outdatedDisplayNames().count == result.total)
    }

    /// An ignored app is dropped from the list exactly as it is dropped from the count.
    @Test func ignoredAppsAreOmittedJustLikeTheBadge() {
        let policies = [UpdatePlanner.key(name: "figma", kind: .cask): UpdatePolicy.ignored]
        let result = checkerResult(policies: policies)

        let names = result.outdatedDisplayNames(policies: policies)
        #expect(!names.contains("figma"))
        #expect(names == ["wget", "Keynote", "typescript", "Zed"])
        #expect(names.count == result.total)
    }

    /// Nothing outdated → nothing to name.
    @Test func nothingOutdatedYieldsNoNames() {
        let empty = MenuBarScanResult(brew: nil, mas: [], npm: [], manualApps: [],
                                      failedChecks: 0, scannedAt: Date(), total: 0)

        #expect(empty.outdatedDisplayNames().isEmpty)
    }
}

/// UX-11g — the dropdown caps the named list and summarises the remainder as
/// „i jeszcze N aplikacji". That summary is grammatically inflected, so it must decline
/// correctly for every count in both languages.
@Suite("MenuBarScanResult overflow summary")
struct MenuBarOverflowSummaryTests {

    private let overflow = "i jeszcze %@ aplikacji"

    @Test func polishOverflowDeclinesForEveryRange() {
        #expect(pluralize(overflow, count: 1, language: .pl) == "i jeszcze 1 aplikacja")
        #expect(pluralize(overflow, count: 3, language: .pl) == "i jeszcze 3 aplikacje")
        #expect(pluralize(overflow, count: 22, language: .pl) == "i jeszcze 22 aplikacje")
        #expect(pluralize(overflow, count: 5, language: .pl) == "i jeszcze 5 aplikacji")
        #expect(pluralize(overflow, count: 13, language: .pl) == "i jeszcze 13 aplikacji")
    }

    @Test func englishOverflowCollapsesToSingularAndPlural() {
        #expect(pluralize(overflow, count: 1, language: .en) == "and 1 more app")
        #expect(pluralize(overflow, count: 3, language: .en) == "and 3 more apps")
        #expect(pluralize(overflow, count: 5, language: .en) == "and 5 more apps")
    }
}
