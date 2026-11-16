import Foundation
import Testing
import MacUpdaterCore

@testable import WegaMacUpdater

/// Spec §5.8: the leftover section of the uninstall sheet. Every decision it renders — which
/// items are ticked when the sheet opens, which sit in the probable section, what select-all
/// covers, and how a row and the header read — lives in `UninstallLeftoverPresentation`.
///
/// The process-wide language is never switched here: Swift Testing runs suites in parallel and
/// other suites assert Polish text. A label is compared with `tr` of its Polish key, and
/// `everyNewStringHasItsEnglishValue` pins each key's English value from the brief.
@Suite("Uninstall leftover presentation")
struct UninstallLeftoverPresentationTests {
    private typealias Presentation = UninstallLeftoverPresentation
    private typealias Fixture = UninstallLeftoverPresentationFixtures

    @Test func probableAndSharedGoToProbableSection() {
        let sections = Presentation.sections([Fixture.obsidian, Fixture.zed])

        #expect(sections.map(\.id) == [Fixture.obsidian.id, Fixture.zed.id])
        #expect(sections.map(\.group) == [Fixture.obsidian, Fixture.zed])
        #expect(sections[0].main.map(\.id) == [Fixture.zap, Fixture.plist, Fixture.coTarget].map(\.id))
        #expect(
            sections[0].probable.map(\.id)
                == [Fixture.byName, Fixture.outside, Fixture.weakZap, Fixture.shared, Fixture.sharedOutside].map(\.id),
            "probable items and items another app still uses keep their canonical order"
        )
        #expect(sections[1].main.map(\.id) == [Fixture.zedPlist.id])
        #expect(sections[1].probable.map(\.id) == [Fixture.zedByName.id])
    }

    @Test func defaultSelectionSkipsProbableAndShared() {
        let selection = Presentation.defaultSelection([Fixture.obsidian, Fixture.zed], applicationsIncomplete: false)

        #expect(selection == Set([Fixture.zap, Fixture.plist, Fixture.coTarget, Fixture.zedPlist].map(\.url.path)))
    }

    /// Spec §5.5: an app missing from an incomplete scan may still use any item.
    @Test func incompleteScanTicksNothing() {
        let groups = [Fixture.obsidian, Fixture.zed]

        #expect(Presentation.defaultSelection(groups, applicationsIncomplete: true).isEmpty)
        #expect(!Presentation.defaultSelection(groups, applicationsIncomplete: false).isEmpty, "positive control")
    }

    @Test func selectAllCoversOnlyMainList() {
        let paths = Presentation.bulkPaths([Fixture.obsidian, Fixture.zed])

        #expect(paths == [Fixture.zap, Fixture.plist, Fixture.coTarget, Fixture.zedPlist].map(\.url.path))
    }

    /// Owner decision 2026-11-17: "Odznacz wszystko" clears every leftover of the sheet, probable
    /// ones included, while "Zaznacz wszystko" still ticks the main list only.
    @Test func deselectAllClearsProbableItemsToo() throws {
        let groups = [Fixture.obsidian, Fixture.zed]
        var selected = Presentation.defaultSelection(groups, applicationsIncomplete: false)
        selected.insert(Fixture.byName.url.path)

        selected.subtract(Presentation.deselectAllPaths(groups))

        #expect(selected.isEmpty, "a probable item ticked by hand is cleared too")
        let view = try Fixture.source("Sources/MacUpdater/UninstallLeftoverSelection.swift")
        #expect(view.contains("if allSelected { selected.subtract(UninstallLeftoverPresentation.deselectAllPaths(groups)) }"))
        #expect(view.contains("else { selected.formUnion(bulkPaths) }"))
    }

    @Test func sourceLabelPrecedence() {
        #expect(Presentation.sourceLabel(Fixture.sharedOutside) == trf("używa też %@", "Other App"),
                "sharing beats being outside ~/Library")
        #expect(Presentation.sourceLabel(Fixture.shared) == trf("używa też %@", "Other App, Second App"))
        #expect(Presentation.sourceLabel(Fixture.outside) == tr("poza ~/Library"),
                "outside ~/Library beats the zap list it came from")
        #expect(Presentation.sourceLabel(Fixture.weakZap) == tr("lista Homebrew (dopasowanie po nazwie)"))
        #expect(Presentation.sourceLabel(Fixture.byName) == tr("nazwa aplikacji"))
        #expect(Presentation.sourceLabel(Fixture.zap) == tr("lista Homebrew"))
        #expect(Presentation.sourceLabel(Fixture.plist) == tr("identyfikator aplikacji"))
    }

    /// A folder a strong cask lists that does not name the app: a vendor-wide or shared folder.
    @Test func notNamedForAppHasItsOwnLabel() {
        #expect(Presentation.sourceLabel(Fixture.vendorFolder) == tr("lista Homebrew (wspólny folder?)"))
        #expect(Translations.en["lista Homebrew (wspólny folder?)"] == "Homebrew list (shared folder?)")
        #expect(Presentation.sections([Fixture.word]).first?.probable == [Fixture.vendorFolder])
        #expect(Presentation.defaultSelection([Fixture.word], applicationsIncomplete: false).isEmpty)
    }

    @Test func sizeTextStates() {
        #expect(Presentation.sizeText(nil) == "…")
        #expect(Presentation.sizeText(.unknown) == tr("rozmiar nieznany"))
        #expect(Presentation.sizeText(.bytes(4_096)) == Fixture.bytes(4_096))
    }

    @Test func headerMarksPendingSizes() {
        let selected = Set([Fixture.zap, Fixture.plist].map(\.url.path))
        let groups = [Fixture.obsidian]

        let pending = Presentation.header(
            groups: groups, selected: selected, sizes: [Fixture.zap.id: .bytes(178_000_000)]
        )
        let measured = Presentation.header(
            groups: groups, selected: selected,
            sizes: [Fixture.zap.id: .bytes(178_000_000), Fixture.plist.id: .bytes(4_000_000)]
        )
        let unknown = Presentation.header(
            groups: groups, selected: selected,
            sizes: [Fixture.zap.id: .bytes(178_000_000), Fixture.plist.id: .unknown]
        )

        #expect(pending == trf("%@ · %@ zaznaczone", "2", Fixture.bytes(178_000_000)) + " …")
        #expect(measured == trf("%@ · %@ zaznaczone", "2", Fixture.bytes(182_000_000)),
                "an unticked item still being measured does not hold the total back")
        #expect(unknown == trf("%@ · %@ zaznaczone", "2", Fixture.bytes(178_000_000)))
    }

    @Test func sectionShownForCatalogNoteEvenWithoutItems() {
        #expect(Presentation.showsSection(groups: [], catalogUnavailable: true))
        #expect(!Presentation.showsSection(groups: [], catalogUnavailable: false))
        #expect(Presentation.showsSection(groups: [Fixture.zed], catalogUnavailable: false))
    }

    @Test func notesSayWhyItemsAreMissingOrUnticked() {
        let catalog = tr("Lista Homebrew jest niedostępna — pokazano tylko resztki znalezione po identyfikatorze i nazwie.")
        let incomplete = tr("Lista aplikacji jest niepełna — nic nie jest zaznaczone domyślnie.")

        #expect(Presentation.notes(catalogUnavailable: false, applicationsIncomplete: false).isEmpty)
        #expect(Presentation.notes(catalogUnavailable: true, applicationsIncomplete: false) == [catalog])
        #expect(Presentation.notes(catalogUnavailable: false, applicationsIncomplete: true) == [incomplete])
        #expect(Presentation.notes(catalogUnavailable: true, applicationsIncomplete: true) == [catalog, incomplete])
    }

    /// VoiceOver reads the path, where the item was found and its size.
    @Test func rowLabelCarriesPathSourceAndSize() {
        #expect(
            Presentation.accessibilityLabel(Fixture.byName, size: .bytes(2_000_000))
                == "~/Library/Caches/Obsidian, \(tr("nazwa aplikacji")), \(Fixture.bytes(2_000_000))"
        )
        #expect(Presentation.accessibilityLabel(Fixture.zap, size: nil)
                == "~/Library/Application Support/obsidian, \(tr("lista Homebrew")), …")
    }

    @Test func everyNewStringHasItsEnglishValue() {
        let english: [String: String] = [
            "Resztki aplikacji": "App leftovers",
            "Prawdopodobne — sprawdź przed zaznaczeniem": "Probable — check before ticking",
            "lista Homebrew": "Homebrew list",
            "lista Homebrew (dopasowanie po nazwie)": "Homebrew list (matched by name)",
            "identyfikator aplikacji": "bundle id",
            "nazwa aplikacji": "app name",
            "poza ~/Library": "outside ~/Library",
            "używa też %@": "also used by %@",
            "rozmiar nieznany": "size unknown",
            "%@ · %@ zaznaczone": "%@ · %@ ticked",
            "Lista Homebrew jest niedostępna — pokazano tylko resztki znalezione po identyfikatorze i nazwie.":
                "The Homebrew list is unavailable — showing only leftovers found by bundle id and name.",
            "Lista aplikacji jest niepełna — nic nie jest zaznaczone domyślnie.":
                "The app list is incomplete — nothing is ticked by default.",
        ]
        for (polish, value) in english {
            #expect(Translations.en[polish] == value, "\(polish)")
        }
        #expect(Translations.en["Resztki w ~/Library"] == nil, "the heading no longer says ~/Library")
    }

    /// The view cannot be driven from a package test, so this pins the wiring: the sheet opens
    /// with `defaultSelection` and nothing else, fed by the last scan's applications failure.
    /// The installed list and its completeness are read together before the first `await`: a
    /// scan finishing during that wait must not pair a partial list with a "complete" flag.
    @Test func sheetOpensWithTheDefaultSelection() throws {
        let view = try Fixture.source("Sources/MacUpdater/UninstallView.swift")
        let present = try Fixture.body(of: "private func presentUninstallDialog()", endingAt: "private func cancelUninstall()", in: view)
        let scan = try Fixture.body(of: "private func scan() async", endingAt: "/// - Parameter reported:", in: view)
        let firstAwait = try #require(present.range(of: "await "))
        let beforeFirstAwait = present[..<firstAwait.lowerBound]
        let selection = try Fixture.body(of: "UninstallLeftoverPresentation.defaultSelection(", endingAt: ")", in: String(present))

        #expect(present.contains("selectedLeftovers = UninstallLeftoverPresentation.defaultSelection("))
        #expect(present.components(separatedBy: "selectedLeftovers =").count == 2,
                "nothing else ticks leftovers when the sheet opens")
        #expect(scan.contains("applicationsSourceFailed = scan.failures.contains { $0.source == .applications }"))

        #expect(beforeFirstAwait.contains("let installed = apps"))
        #expect(beforeFirstAwait.contains("let applicationsIncomplete = applicationsSourceFailed"),
                "the applications source alone decides, not scanFailed")
        #expect(present.contains("operations.scanLeftovers(for: attempted, installed: installed)"))
        #expect(!present.contains("installed: apps"), "a later scan's list must not reach the planner")
        #expect(selection.contains("applicationsIncomplete: applicationsIncomplete"))
        #expect(present.contains("pendingApplicationsIncomplete = applicationsIncomplete"))
    }

    /// Preparing the sheet awaits the routes and the leftover plan. A second press meanwhile must
    /// not start a second preparation, and the button stays disabled until the first one ends.
    @Test func uninstallButtonCannotPrepareTheSheetTwice() throws {
        let view = try Fixture.source("Sources/MacUpdater/UninstallView.swift")
        let present = try Fixture.body(of: "private func presentUninstallDialog()", endingAt: "private func cancelUninstall()", in: view)
        let firstAwait = try #require(present.range(of: "await "))
        let beforeFirstAwait = present[..<firstAwait.lowerBound]

        #expect(beforeFirstAwait.contains("!isPreparingDialog else { return }"))
        #expect(beforeFirstAwait.contains("isPreparingDialog = true"))
        #expect(beforeFirstAwait.contains("defer { isPreparingDialog = false }"), "cleared on every exit path")
        #expect(view.contains(".disabled(targets.isEmpty || isUninstalling || isPreparingDialog)"))
    }
}

private enum UninstallLeftoverPresentationFixtures {
    static let home = URL(filePath: NSHomeDirectory(), directoryHint: .isDirectory)

    static let zap = item("Library/Application Support/obsidian", source: .homebrewZap(token: "obsidian"))
    static let plist = item("Library/Preferences/md.obsidian.plist", source: .bundleIdentifier)
    static let byName = item("Library/Caches/Obsidian", source: .appName, probable: .appName)
    static let outside = item(".config/obsidian", source: .homebrewZap(token: "obsidian"), probable: .outsideLibrary)
    static let weakZap = item("Library/Logs/obsidian", source: .homebrewZap(token: "obsidian"), probable: .caskMatchedByName)
    static let shared = item(
        "Library/Caches/com.vendor.shared", source: .homebrewZap(token: "obsidian"), sharedWith: ["Other App", "Second App"]
    )
    static let sharedOutside = item(
        ".config/vendor", source: .homebrewZap(token: "obsidian"), probable: .outsideLibrary, sharedWith: ["Other App"]
    )
    /// Another target of the same run also claims it: that decides its release, not its tick.
    static let coTarget = item(
        "Library/Application Support/com.vendor.suite", source: .bundleIdentifier, coTargets: ["/Applications/Suite.app"]
    )
    static let zedPlist = item("Library/Preferences/dev.zed.Zed.plist", source: .bundleIdentifier)
    static let zedByName = item("Library/Caches/Zed", source: .appName, probable: .appName)

    static let vendorFolder = item(
        "Library/Application Support/Microsoft", source: .homebrewZap(token: "microsoft-word"), probable: .notNamedForApp
    )

    static let obsidian = group("Obsidian", [zap, plist, byName, outside, weakZap, shared, sharedOutside, coTarget])
    static let zed = group("Zed", [zedPlist, zedByName])
    static let word = group("Microsoft Word", [vendorFolder])

    static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }

    static func source(_ relative: String) throws -> String {
        let root = URL(filePath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appending(path: relative), encoding: .utf8)
    }

    static func body(of start: String, endingAt end: String, in text: String) throws -> Substring {
        let from = try #require(text.range(of: start))
        let to = try #require(text.range(of: end, range: from.upperBound..<text.endIndex))
        return text[from.upperBound..<to.lowerBound]
    }

    private static func item(
        _ relative: String,
        source: LeftoverItem.Source,
        probable: LeftoverItem.ProbableReason? = nil,
        sharedWith: [String] = [],
        coTargets: [String] = []
    ) -> LeftoverItem {
        LeftoverItem(
            url: home.appending(path: relative, directoryHint: .notDirectory),
            source: source,
            probableReason: probable,
            sharedWith: sharedWith,
            coTargets: coTargets
        )
    }

    private static func group(_ name: String, _ items: [LeftoverItem]) -> LeftoverGroup {
        LeftoverGroup(
            app: ApplicationInfo(
                path: URL(filePath: "/Applications/\(name).app", directoryHint: .isDirectory),
                name: name,
                bundleIdentifier: "com.example.\(name.lowercased())",
                version: "1.0",
                installDate: nil,
                updateDate: nil,
                isManagedByBrew: false,
                caskToken: nil
            ),
            items: items
        )
    }
}
