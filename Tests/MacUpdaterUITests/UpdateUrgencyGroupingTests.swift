import Foundation
import MacUpdaterCore
import Testing
@testable import WegaMacUpdater

/// UX-18 — the Updates list was grouped only by package manager: up to nine cards, two of
/// them titled "Homebrew Casks", with a possible security fix somewhere in the middle. The
/// owner chose grouping by what the user does next: possible security fixes first, then apps,
/// then CLI tools, then what the vendor or the user has to finish. Grouping by source stays
/// one menu choice away, because it is the grouping the Inventory window shares.
@Suite("Update urgency grouping")
@MainActor
struct UpdateUrgencyGroupingTests {
    private let firefox = OutdatedItem(key: "c:firefox", name: "firefox", from: "1", to: "2", kind: .cask)
    private let slack = OutdatedItem(key: "a:1", name: "Slack", from: "1", to: "2", kind: .appStore)
    private let wget = OutdatedItem(key: "f:wget", name: "wget", from: "1", to: "2", kind: .formula)
    private let tsc = OutdatedItem(key: "n:typescript", name: "typescript", from: "1", to: "2", kind: .npm)

    private func manual(_ name: String) -> ManualOutdatedApp {
        ManualOutdatedApp(
            name: name,
            path: URL(fileURLWithPath: "/Applications/\(name).app"),
            installedVersion: "1",
            availableVersion: "2",
            source: .sparkle
        )
    }

    @Test func urgencyIsTheDefaultAndSourceStaysAvailable() {
        #expect(UpdateGrouping.default == .urgency)
        #expect(UpdateGrouping.allCases == [.urgency, .source])
    }

    @Test func possibleSecurityFixesLeadAndLeaveTheRest() {
        let risky = manual("Risky")
        let calm = manual("Calm")

        let groups = UrgencyGroups.make(
            items: [], manual: [calm, risky], filter: .all, isSecurity: { $0.name == "Risky" }
        )

        #expect(groups.security == [risky])
        #expect(groups.needsYou == [calm])
    }

    @Test func packagesSplitIntoAppsAndToolsInTheirOrder() {
        let groups = UrgencyGroups.make(
            items: [wget, firefox, tsc, slack], manual: [], filter: .all, isSecurity: { _ in false }
        )

        #expect(groups.apps == [firefox, slack])
        #expect(groups.cli == [wget, tsc])
    }

    /// The scope bar still decides what is on screen; grouping only decides the order.
    @Test func theScopeStillDecidesWhatIsShown() {
        let risky = manual("Risky")
        let calm = manual("Calm")
        func groups(_ filter: UpdateFilter) -> UrgencyGroups {
            UrgencyGroups.make(
                items: [wget, firefox], manual: [risky, calm], filter: filter,
                isSecurity: { $0.name == "Risky" }
            )
        }

        #expect(groups(.cli) == UrgencyGroups(security: [], apps: [], cli: [wget], needsYou: []))
        #expect(groups(.apps) == UrgencyGroups(security: [risky], apps: [firefox], cli: [], needsYou: [calm]))
        #expect(groups(.security) == UrgencyGroups(security: [risky], apps: [], cli: [], needsYou: []))
    }

    /// Mixed groups lose the per-source header, so each row names its source, and a row the
    /// rollback net cannot cover says so itself — LT-01's disclosure, moved onto the row.
    @Test func everyRowNamesItsSourceAndItsRollbackLimit() {
        #expect(OutdatedItem.Kind.cask.sourceLabel == tr("Homebrew (cask)"))
        #expect(OutdatedItem.Kind.formula.sourceLabel == tr("Homebrew (formuła)"))
        #expect(OutdatedItem.Kind.appStore.sourceLabel == tr("Mac App Store"))
        #expect(OutdatedItem.Kind.npm.sourceLabel == tr("npm (globalny)"))

        #expect(UpdateView.rollbackCaption(for: .cask) == nil, "casks carry their own verdict")
        for kind in [OutdatedItem.Kind.formula, .appStore, .npm] {
            #expect(UpdateView.rollbackCaption(for: kind)?.hasPrefix(tr("Bez automatycznego cofnięcia")) == true)
        }
    }

    @Test func theListOffersBothGroupingsAndRowsShowWhatTheyNeed() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let view = try String(contentsOf: root.appendingPathComponent("Sources/MacUpdater/UpdateView.swift"), encoding: .utf8)
        let shared = try String(contentsOf: root.appendingPathComponent("Sources/MacUpdater/SharedViews.swift"), encoding: .utf8)

        #expect(view.contains("@AppStorage(UpdateGrouping.storageKey)"))
        #expect(view.contains("urgencyGroupedSections"))
        #expect(view.contains("sourceGroupedSections"))
        #expect(shared.contains("rollbackUnavailableReason"), "a row without the net says so")
    }
}
