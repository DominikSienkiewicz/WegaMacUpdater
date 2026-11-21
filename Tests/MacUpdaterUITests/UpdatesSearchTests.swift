import AppKit
import Foundation
import SwiftUI
import MacUpdaterCore
import Testing
@testable import WegaMacUpdater

/// UXP-35 part 2 — ⌘F on Updates. The search never filters the list: the selection, ⇧⌘A and the
/// band's queue all stand on the rows on screen. It answers in one row above the list instead —
/// the matching rows as links, or, for an app that is not on the list, what Inventory already
/// knows about it. Search never starts an Inventory read: that read asks the network for the cask
/// catalog.
@Suite("Find on Updates") @MainActor
struct UpdatesSearchTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func anEmptyQueryAnswersNothing() {
        for query in ["", "   ", "\n"] { #expect(UpdatesSearch.answer(query: query, rows: [row("c:zoom", "Zoom")], hiddenByRules: [], inventory: [], inventoryIsStale: false, checks: [:], policies: [:], now: now) == nil) }
    }
    @Test func aRowOnTheListIsTheAnswerExactNameFirst() {
        let rows = [row("c:zoom-helper", "Zoom Helper"), row("c:zoom", "zoom", inScope: false), row("m:/A/Café Studio.app", "Café Studio")]
        #expect(UpdatesSearch.answer(query: "ZOOM", rows: rows, hiddenByRules: [], inventory: nil, inventoryIsStale: false, checks: [:], policies: [:], now: now)
                == .onList([rows[1], rows[0]], more: false))
        #expect(UpdatesSearch.answer(query: "cafe", rows: rows, hiddenByRules: [], inventory: nil, inventoryIsStale: false, checks: [:], policies: [:], now: now)
                == .onList([rows[2]], more: false), "diacritics are ignored")
        let many = (1...5).map { row("n:pkg\($0)", "pkg\($0)") }
        #expect(UpdatesSearch.answer(query: "pkg", rows: many, hiddenByRules: [], inventory: nil, inventoryIsStale: false, checks: [:], policies: [:], now: now)
                == .onList(Array(many.prefix(3)), more: true))
    }
    @Test func aRuleThatHidesItSaysSo() {
        let rule = UpdatePolicyEntry(key: "c:spotify", displayName: "Spotify", policy: .ignored)
        #expect(UpdatesSearch.answer(query: "spot", rows: [], hiddenByRules: [rule], inventory: [], inventoryIsStale: false, checks: [:], policies: [:], now: now)
                == .hiddenByRule(name: "Spotify"))
    }
    @Test func withoutAnInventoryWegaSaysSheHasNotLooked() {
        #expect(UpdatesSearch.answer(query: "spotify", rows: [], hiddenByRules: [], inventory: nil, inventoryIsStale: false, checks: [:], policies: [:], now: now)
                == .inventoryNotRead(query: "spotify"))
    }
    @Test func theInventorysEvidenceDecidesTheAnswer() {
        let app = application("Spotify", version: "1.2.3")
        let current = InstallationCheck(app: app, sources: [.init(source: "Homebrew", outcome: .current)], checkedAt: now.addingTimeInterval(-600))
        #expect(answer("spotify", app, current) == .upToDate(name: "Spotify", version: "1.2.3", checkedAt: current.checkedAt, sources: ["Homebrew"]))
        #expect(answer("spotify", app, InstallationCheck(app: app, sources: [], checkedAt: now)) == .notChecked(name: "Spotify", reason: .noSource))
        #expect(answer("spotify", app, InstallationCheck(app: app, sources: [.init(source: "Spotify", outcome: .failed)], checkedAt: now))
                == .notChecked(name: "Spotify", reason: .checkFailed))
        #expect(answer("spotify", app, InstallationCheck(app: app, sources: [.init(source: "Homebrew", outcome: .current)], checkedAt: now.addingTimeInterval(-90_000)))
                == .notChecked(name: "Spotify", reason: .noCurrentResult), "older than a day is stale")
        #expect(answer("spotify", app, nil) == .notChecked(name: "Spotify", reason: .noCurrentResult))
        #expect(UpdatesSearch.answer(query: "nothing-like-it", rows: [], hiddenByRules: [], inventory: [app], inventoryIsStale: false, checks: [:], policies: [:], now: now)
                == .notFound(query: "nothing-like-it"))
    }
    @Test func everyAnswerReadsInBothLanguages() {
        let checked = now.addingTimeInterval(-600)
        withLanguage(.pl) {
            #expect(UpdatesSearch.text(for: .upToDate(name: "Spotify", version: "1.2.3", checkedAt: checked, sources: ["Homebrew"]), now: now)
                    == "Spotify — aktualna (1.2.3, sprawdzono \(CheckedAtCopy.day(checked, now: now)) przez Homebrew)")
            #expect(UpdatesSearch.text(for: .notChecked(name: "Spotify", reason: .noSource), now: now) == "Spotify — nie wiem, skąd ją aktualizować")
            #expect(UpdatesSearch.text(for: .notChecked(name: "Spotify", reason: .checkFailed), now: now) == "Spotify — sprawdzenie się nie udało, spróbuję przy następnym skanie")
            #expect(UpdatesSearch.text(for: .notChecked(name: "Spotify", reason: .noCurrentResult), now: now) == "Spotify — nie mam aktualnego wyniku, sprawdzę ją przy następnym skanie")
            #expect(UpdatesSearch.text(for: .hiddenByRule(name: "Spotify"), now: now) == "Spotify — ukryta przez Twoją regułę")
            #expect(UpdatesSearch.text(for: .inventoryNotRead(query: "spo"), now: now) == "Nie mam jeszcze spisu aplikacji, więc nie wiem, co z „spo”.")
            #expect(UpdatesSearch.text(for: .notFound(query: "spo"), now: now) == "Nie widzę „spo” wśród aplikacji na tym Macu.")
            #expect(UpdatesSearch.text(for: .onList([], more: false), now: now) == nil)
        }
        withLanguage(.en) {
            #expect(UpdatesSearch.text(for: .hiddenByRule(name: "Spotify"), now: now) == "Spotify — hidden by your rule")
            #expect(UpdatesSearch.text(for: .notChecked(name: "Spotify", reason: .noSource), now: now) == "Spotify — I don't know where to update it from")
            #expect(tr("Znajdź aplikację") == "Find an app" && tr("Pokaż reguły") == "Show Rules" && tr("Otwórz Spis") == "Open Inventory")
        }
    }
    @Test func theSearchIsWiredOnlyToTheUpdatesScreen() throws {
        let detail = try source("Sources/MacUpdater/DetailColumn.swift")
        #expect(detail.contains("if selection.tab == .update {\n                UpdatesSearchField(search: $updatesSearch)"))
        #expect(detail.contains("searchQuery: updatesSearch,"))
        let search = try source("Sources/MacUpdater/UpdatesSearch.swift")
        for literal in [".searchable(text: $search, prompt: tr(\"Znajdź aplikację\"))", ".searchFocused($searchFocused)",
                        ".receivesSearchFocusRequests(on: .update) { searchFocused = true }"] {
            #expect(search.contains(literal), "\(literal)")
        }
        let view = try source("Sources/MacUpdater/UpdateView.swift")
        let screen = try slice(view, from: "private var screenBody: some View", to: "private var scopeBar: some View")
        #expect(screen.contains("UpdatesSearchAnswerRow("))
        #expect(!view.contains(".searchable("), "UpdateView stays mounted on every screen; the field must not follow it")
        let column = try slice(view, from: "private var listColumn: some View", to: "/// F2 — \"show me exactly what you will do\"")
        #expect(!column.contains("UpdatesSearch"), "the answer lies above the list, not in it")
    }

    @Test func aRuleTheInventorySeesHidesItAndAnUnlistedUpdateIsNoCurrentResult() {
        let app = application("Spotify", version: "1.2.3")
        let outdated = InstallationCheck(app: app, sources: [.init(source: "Homebrew", outcome: .outdated, availableVersion: "2.0", policyKey: "c:spotify")],
                                         checkedAt: now.addingTimeInterval(-600))
        let checks = [InstallationIdentity(path: outdated.path): outdated]
        #expect(UpdatesSearch.answer(query: "spotify", rows: [], hiddenByRules: [], inventory: [app], inventoryIsStale: false, checks: checks, policies: ["c:spotify": .ignored], now: now)
                == .hiddenByRule(name: "Spotify"))
        #expect(UpdatesSearch.answer(query: "spotify", rows: [], hiddenByRules: [], inventory: [app], inventoryIsStale: false, checks: checks, policies: [:], now: now)
                == .notChecked(name: "Spotify", reason: .noCurrentResult), "an update the list does not show is not a current result")
    }

    /// The answer reads the checks the Inventory screen shows: the background round's when it is
    /// newer than the window's scan, the window's otherwise.
    @Test func theChecksComeFromTheNewerRound() {
        let app = application("Spotify", version: "1.2.3")
        let windows = InstallationCheck(app: app, sources: [.init(source: "Homebrew", outcome: .current)], checkedAt: now.addingTimeInterval(-60))
        let background = InstallationCheck(app: app, sources: [.init(source: "Spotify", outcome: .failed)], checkedAt: now)
        let newer = MenuBarScanResult(brew: nil, mas: [], npm: [], manualApps: [], failedChecks: 1, scannedAt: now, total: 0,
                                      installationChecks: [background])
        let identity = InstallationIdentity(path: app.path)
        #expect(InventoryCheckSource.checksByPath(scan: [windows], scanCheckedAt: now.addingTimeInterval(-60), background: newer)
                == [identity: background])
        #expect(InventoryCheckSource.checksByPath(scan: [windows], scanCheckedAt: now.addingTimeInterval(60), background: newer)
                == [identity: windows])
        #expect(InventoryCheckSource.checksByPath(scan: [windows], scanCheckedAt: nil, background: nil) == [identity: windows])
    }

    /// A match in another category says so, so following it brings back "Wszystkie": a CLI tool
    /// while the apps are on screen, or a manual app under the CLI category.
    @Test func aRowInAnotherCategoryIsMarkedOutOfScope() {
        let formula = OutdatedItem(key: "f:wget", name: "wget", from: "1", to: "2", kind: .formula)
        let cask = OutdatedItem(key: "c:zoom", name: "zoom", from: "1", to: "2", kind: .cask)
        let manual = ManualOutdatedApp(name: "Obsidian", path: URL(fileURLWithPath: "/Applications/Obsidian.app"),
                                       installedVersion: "1", availableVersion: "2", source: .obsidian)
        let paths = ["zoom": URL(fileURLWithPath: "/Applications/zoom.us.app")]
        let apps = UpdatesSearch.rows(items: [formula, cask], visibleKeys: ["c:zoom"], caskAppPaths: paths,
                                      manual: [manual], filter: .apps, isSecurity: { _ in false })
        #expect(apps == [
            .init(key: "f:wget", name: "wget", inCurrentScope: false),
            .init(key: "c:zoom", name: "zoom.us", inCurrentScope: true),
            .init(key: "m:/Applications/Obsidian.app", name: "Obsidian", inCurrentScope: true),
        ])
        let cli = UpdatesSearch.rows(items: [formula], visibleKeys: ["f:wget"], caskAppPaths: [:], manual: [manual], filter: .cli, isSecurity: { _ in true })
        #expect(cli.map(\.inCurrentScope) == [true, false])
        let security = UpdatesSearch.rows(items: [], visibleKeys: [], caskAppPaths: [:], manual: [manual, manual], filter: .security, isSecurity: { _ in true })
        #expect(security.map(\.inCurrentScope) == [true, true])
    }

    /// A query typed during a scan or a run: the answer lies in `screenBody`, above the list. A
    /// running update disables that whole screen, links included; a scan in place disables only
    /// the rows below, so the answer keeps reading the rows on screen.
    @Test func theAnswerLiesAboveTheListInsideTheRunsLock() throws {
        let view = try source("Sources/MacUpdater/UpdateView.swift")
        let screen = try slice(view, from: "private var screenBody: some View", to: "private var scopeBar: some View")
        let answer = try #require(screen.range(of: "UpdatesSearchAnswerRow("))
        let list = try #require(screen.range(of: "                listColumn\n"))
        #expect(answer.upperBound < list.lowerBound)
        #expect(view.contains("screenBody\n                .disabled(!ScanSelectionGate.allowsScreenInteraction(isUpdating: scan.updating))"))
        #expect(screen.contains("if !row.inCurrentScope { onScopeChange?(.all) }\n        scan.inspectedKey = row.key"))
        #expect(screen.contains("inventory: inventory.lastReadAt == nil ? nil : inventory.apps"), "search never reads the inventory itself")
        #expect(!screen.contains("inventory.scan("))
        #expect(screen.contains(
            "inventoryIsStale: inventory.isStale(given: InventoryChangeStamp.current(scan: scan, migration: migration, cleanup: cleanup, menuBar: MenuBarAgent.shared))"
        ), "the same stamp the Inventory screen reads")
        #expect(screen.contains("UpdatesSearchAnswerRow(answer: answer, inventoryReadAt: inventory.lastReadAt,"))
    }

    /// The narrow (388 pt) and compact (480 pt) list widths, less the row's 16 pt gutters, with
    /// the longest answers in Polish and English: nothing is pushed out and the text wraps.
    @Test(arguments: [CGFloat(356), 448])
    func everyAnswerFitsTheNarrowestList(width: CGFloat) {
        let long = "Microsoft Remote Desktop Beta"
        let answers: [UpdatesSearchAnswer] = [
            .onList([row("c:a", long), row("c:b", long + " Helper"), row("c:c", long + " Preview")], more: true),
            .upToDate(name: long, version: "10.13.2 (2045)", checkedAt: now, sources: ["Homebrew", "Microsoft AutoUpdate"]),
            .notChecked(name: long, reason: .noCurrentResult),
            .hiddenByRule(name: long),
            .inventoryNotRead(query: long),
            .notFound(query: long),
            .fromStaleInventory(.upToDate(name: long, version: nil, checkedAt: now, sources: ["Homebrew", "Microsoft AutoUpdate"])),
            .fromStaleInventory(.hiddenByRule(name: long)),
            .fromStaleInventory(.notFound(query: long)),
        ]
        let everySource: [ScanFailureSource] = [.homebrew, .caskCatalog, .applications, .appStore, .npm]
        for language in [AppLanguage.pl, .en] {
            withLanguage(language) {
                // The longest banner a read that left sources out can raise.
                let longestProblem = everySource.map { ScanSourceFailure(source: $0, message: "") }.scanErrorMessage
                for answer in answers {
                    for problem in [nil, longestProblem] {
                        let view = UpdatesSearchAnswerRow(answer: answer, inventoryReadAt: now, inventoryProblem: problem,
                                                          onShow: { _ in }, onShowRules: {}, onOpenInventory: {})
                        let fitted = NSHostingController(rootView: view).sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude))
                        #expect(fitted.width <= width, "\(language) \(answer): needs \(fitted.width) pt")
                        let caveat = UpdatesSearch.caveat(for: answer, inventoryReadAt: now, inventoryProblem: problem, now: Date())
                        for text in [UpdatesSearch.text(for: answer, now: Date()), caveat].compactMap({ $0 }) {
                            let needed = NSHostingController(rootView: Text(verbatim: text).font(.wega(.callout)))
                                .sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude)).height
                            #expect(fitted.height + 0.5 >= needed, "\(language) \(answer): \(fitted.height) pt tall, the text needs \(needed) pt")
                        }
                    }
                }
            }
        }
    }

    /// An Inventory that something has changed since its read (an update run, a migration, a
    /// removal, an install, an undo) may no longer match the disk. Wega says so under what it read,
    /// in the Inventory screen's own words, leaves the version out and offers Inventory; a "not on
    /// this Mac" is qualified, not withheld. The list, the rules and a never-read Inventory answer
    /// as before.
    @Test func aStaleInventoryQualifiesWhatItSays() throws {
        let app = application("Spotify", version: "1.2.3")
        let readAt = now.addingTimeInterval(-3_600)
        let current = InstallationCheck(app: app, sources: [.init(source: "Homebrew", outcome: .current)], checkedAt: now.addingTimeInterval(-600))
        let staleCurrent = answer("spotify", app, current, stale: true)
        #expect(staleCurrent == .fromStaleInventory(.upToDate(name: "Spotify", version: nil, checkedAt: current.checkedAt, sources: ["Homebrew"])))
        #expect(answer("spotify", app, nil, stale: true) == .fromStaleInventory(.notChecked(name: "Spotify", reason: .noCurrentResult)))
        let gone = UpdatesSearch.answer(query: "nothing-like-it", rows: [], hiddenByRules: [], inventory: [app], inventoryIsStale: true, now: now)
        #expect(gone == .fromStaleInventory(.notFound(query: "nothing-like-it")))
        #expect(UpdatesSearch.answer(query: "spotify", rows: [row("c:spotify", "Spotify")], hiddenByRules: [], inventory: [app], inventoryIsStale: true, now: now)
                == .onList([row("c:spotify", "Spotify")], more: false))
        #expect(UpdatesSearch.answer(query: "spot", rows: [], hiddenByRules: [UpdatePolicyEntry(key: "c:spotify", displayName: "Spotify", policy: .ignored)],
                                     inventory: [app], inventoryIsStale: true, now: now) == .hiddenByRule(name: "Spotify"))
        #expect(UpdatesSearch.answer(query: "spotify", rows: [], hiddenByRules: [], inventory: nil, inventoryIsStale: true, now: now) == .inventoryNotRead(query: "spotify"))

        let staleUpToDate = try #require(staleCurrent)
        let staleGone = try #require(gone)
        withLanguage(.pl) {
            let caveat = "Odczytano \(CheckedAtCopy.day(readAt, now: now)) — spis mógł się zmienić"
            for stale in [staleUpToDate, staleGone] {
                #expect(UpdatesSearch.caveat(for: stale, inventoryReadAt: readAt, now: now) == caveat, "\(stale)")
                #expect(UpdatesSearch.links(for: stale) == [.inventory], "\(stale)")
            }
            #expect(UpdatesSearch.text(for: staleUpToDate, now: now)
                    == "Spotify — aktualna (—, sprawdzono \(CheckedAtCopy.day(current.checkedAt, now: now)) przez Homebrew)", "no version from a list that may be old")
            #expect(UpdatesSearch.text(for: staleGone, now: now) == "Nie widzę „nothing-like-it” wśród aplikacji na tym Macu.", "qualified, not withheld")
            #expect(UpdatesSearch.links(for: .fromStaleInventory(.hiddenByRule(name: "Spotify"))) == [.rules, .inventory])
        }
        let fresh = answer("spotify", app, current)
        #expect(fresh == .upToDate(name: "Spotify", version: "1.2.3", checkedAt: current.checkedAt, sources: ["Homebrew"]), "a current Inventory is unchanged")
        for unqualified in [fresh, .notFound(query: "x"), .hiddenByRule(name: "Spotify"), .inventoryNotRead(query: "x"), .onList([], more: false)].compactMap({ $0 }) {
            #expect(UpdatesSearch.caveat(for: unqualified, inventoryReadAt: readAt, now: now) == nil, "\(unqualified)")
        }
        #expect(UpdatesSearch.links(for: .hiddenByRule(name: "Spotify")) == [.rules])
        #expect(UpdatesSearch.links(for: .notFound(query: "x")) == [.inventory] && UpdatesSearch.links(for: .onList([], more: false)).isEmpty)
    }

    /// Final review M-a — an Inventory read that left sources out is not a complete one (REL-14).
    /// What ⌘F reads from it is qualified like what it reads from a changed Inventory, in the
    /// Inventory screen's own words: its banner, „Część źródeł skanu zawiodła (…) — lista może
    /// być niekompletna.”, under the answer, next to Open Inventory. No new text.
    @Test func aPartlyFailedInventoryReadQualifiesWhatItSays() throws {
        let readAt = now.addingTimeInterval(-3_600)
        let gone = UpdatesSearchAnswer.fromStaleInventory(.notFound(query: "nothing-like-it"))
        let failures = [ScanSourceFailure(source: .homebrew, message: "brew list failed")]
        withLanguage(.pl) {
            let problem = failures.scanErrorMessage
            #expect(problem == "Część źródeł skanu zawiodła (Homebrew) — lista może być niekompletna.")
            #expect(UpdatesSearch.caveat(for: gone, inventoryReadAt: readAt, inventoryProblem: problem, now: now) == problem)
            #expect(UpdatesSearch.caveat(for: gone, inventoryReadAt: readAt, inventoryProblem: nil, now: now)
                    == "Odczytano \(CheckedAtCopy.day(readAt, now: now)) — spis mógł się zmienić", "a changed Inventory reads as before")
            #expect(UpdatesSearch.caveat(for: .notFound(query: "x"), inventoryReadAt: readAt, inventoryProblem: problem, now: now) == nil,
                    "only a qualified answer carries a caveat")
            #expect(UpdatesSearch.links(for: gone) == [.inventory])
        }
        withLanguage(.en) {
            let problem = failures.scanErrorMessage
            #expect(UpdatesSearch.caveat(for: gone, inventoryReadAt: readAt, inventoryProblem: problem, now: now) == problem)
            #expect(problem?.contains("incomplete") == true)
        }

        let view = try source("Sources/MacUpdater/UpdateView.swift")
        let screen = try slice(view, from: "private var screenBody: some View", to: "private var scopeBar: some View")
        #expect(screen.contains("cleanup: cleanup, menuBar: MenuBarAgent.shared)) || inventory.errorMessage != nil,"),
                "a read that left sources out is qualified like a changed one")
        #expect(screen.contains("UpdatesSearchAnswerRow(answer: answer, inventoryReadAt: inventory.lastReadAt, inventoryProblem: inventory.errorMessage,"))
        let row = try source("Sources/MacUpdater/UpdatesSearch.swift")
        #expect(row.contains("UpdatesSearch.caveat(for: answer, inventoryReadAt: inventoryReadAt, inventoryProblem: inventoryProblem, now: Date())"))
    }

    /// Final review M-b — „Pokaż reguły” opened the sheet of rules hiding this scan's results even
    /// for a rule only Inventory knew, so the sheet could open empty. It opens the sheet only when
    /// the sheet lists the rule the answer names, and Settings → Paused updates otherwise.
    @Test func showRulesNeverOpensASheetWithoutTheRule() throws {
        let spotify = UpdatePolicyEntry(key: "c:spotify", displayName: "Spotify", policy: .ignored)
        #expect(UpdatesSearch.rulesDestination(for: .hiddenByRule(name: "Spotify"), hiddenByRules: [spotify]) == .sheet)
        #expect(UpdatesSearch.rulesDestination(for: .fromStaleInventory(.hiddenByRule(name: "Spotify")), hiddenByRules: [spotify]) == .sheet)
        #expect(UpdatesSearch.rulesDestination(for: .hiddenByRule(name: "Zoom"), hiddenByRules: [spotify]) == .settings,
                "a rule from Inventory that this scan's sheet does not list")
        #expect(UpdatesSearch.rulesDestination(for: .hiddenByRule(name: "Spotify"), hiddenByRules: []) == .settings, "never an empty sheet")
        #expect(UpdatesSearch.rulesDestination(for: .fromStaleInventory(.hiddenByRule(name: "Zoom")), hiddenByRules: [spotify]) == .settings)
        let fromRules = try #require(UpdatesSearch.answer(query: "spot", rows: [], hiddenByRules: [spotify], inventory: [], inventoryIsStale: false))
        #expect(UpdatesSearch.rulesDestination(for: fromRules, hiddenByRules: [spotify]) == .sheet, "an answer from the rules names a listed one")

        let view = try source("Sources/MacUpdater/UpdateView.swift")
        let screen = try slice(view, from: "private var screenBody: some View", to: "private var scopeBar: some View")
        #expect(screen.contains("onShowRules: { showRules(for: answer) }"))
        #expect(screen.contains("switch UpdatesSearch.rulesDestination(for: answer, hiddenByRules: scan.rulesHidingResults) {"))
        #expect(screen.contains("case .settings: SettingsRoute.shared.open(.policies, with: openSettings)"))
        #expect(view.contains("@Environment(\\.openSettings) private var openSettings"))
    }

    // MARK: - Helpers

    private func row(_ key: String, _ name: String, inScope: Bool = true) -> UpdatesSearch.Row {
        UpdatesSearch.Row(key: key, name: name, inCurrentScope: inScope)
    }

    private func application(_ name: String, version: String) -> ApplicationInfo {
        ApplicationInfo(path: URL(fileURLWithPath: "/Applications/\(name).app"), name: name,
                        bundleIdentifier: "test.find.\(name.lowercased())", version: version,
                        installDate: nil, updateDate: nil, isManagedByBrew: false)
    }

    private func answer(_ query: String, _ app: ApplicationInfo, _ check: InstallationCheck?, stale: Bool = false) -> UpdatesSearchAnswer? {
        UpdatesSearch.answer(query: query, rows: [], hiddenByRules: [], inventory: [app], inventoryIsStale: stale,
                             checks: check.map { [InstallationIdentity(path: $0.path): $0] } ?? [:], policies: [:], now: now)
    }

    private func source(_ relativePath: String, file: String = #filePath) throws -> String {
        let root = URL(fileURLWithPath: file).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }

    private func slice(_ text: String, from: String, to: String) throws -> String {
        let start = try #require(text.range(of: from))
        let region = text[start.lowerBound...]
        let end = try #require(region.range(of: to))
        return String(region[..<end.lowerBound])
    }
}
