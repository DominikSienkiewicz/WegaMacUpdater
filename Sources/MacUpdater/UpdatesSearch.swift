import SwiftUI
import MacUpdaterCore

/// UXP-35 part 2 — what ⌘F on Updates answers. The search never filters the list: the selection,
/// ⇧⌘A and the band's queue stand on the rows on screen, and a filter would queue rows nobody
/// sees. It names the matching rows instead or, for an app the list does not show, says what
/// Inventory already knows about it. It never reads the inventory itself: that read asks the
/// network for the cask catalog.
enum UpdatesSearch {
    /// One row of the Updates list, as the search sees it.
    struct Row: Equatable, Identifiable {
        /// What the inspector opens: the item's key, or `"m:"` and the path for a manual app.
        let key: String
        let name: String
        /// Whether the category on screen shows the row; following it otherwise brings back „Wszystkie”.
        let inCurrentScope: Bool
        var id: String { key }
    }

    /// How many matches the answer names before it asks for a narrower query.
    static let maximumListed = 3

    /// Trimmed; nil when nothing is left.
    static func normalized(_ query: String) -> String? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Case- and diacritic-insensitive: exact name first, then prefix, then contains; list order within each.
    static func matches(_ query: String, in names: [String]) -> [Int] {
        guard let needle = normalized(query).map(fold) else { return [] }
        let haystack = names.map(fold)
        let exact = haystack.indices.filter { haystack[$0] == needle }
        let prefix = haystack.indices.filter { haystack[$0] != needle && haystack[$0].hasPrefix(needle) }
        let inside = haystack.indices.filter { !haystack[$0].hasPrefix(needle) && haystack[$0].contains(needle) }
        return exact + prefix + inside
    }

    /// Every update the scan found after the user's rules, a cask under its app's name.
    /// `visibleKeys` are the batch rows the category on screen shows. A manual app shows under
    /// „Wszystkie” and „Aplikacje”, under the security category when its notes read as a fix, and
    /// never among the CLI tools.
    static func rows(
        items: [OutdatedItem], visibleKeys: Set<String>, caskAppPaths: [String: URL] = [:],
        manual: [ManualOutdatedApp], filter: UpdateFilter, isSecurity: (ManualOutdatedApp) -> Bool
    ) -> [Row] {
        let batch = items.map { item in
            Row(key: item.key,
                name: item.kind == .cask ? CaskDisplayName.name(token: item.name, appPath: caskAppPaths[item.name]) : item.name,
                inCurrentScope: visibleKeys.contains(item.key))
        }
        let apps = manual.map { app in
            Row(key: "m:" + app.path.path, name: app.name, inCurrentScope: showsManual(app, under: filter, isSecurity: isSecurity))
        }
        return batch + apps
    }

    /// The list's matches first, then a rule that hides the app, then what Inventory knows.
    /// `inventory` is nil until Inventory has been read once.
    static func answer(
        query: String, rows: [Row], hiddenByRules: [UpdatePolicyEntry], inventory: [ApplicationInfo]?,
        checks: [InstallationIdentity: InstallationCheck], policies: [String: UpdatePolicy] = [:], now: Date = Date()
    ) -> UpdatesSearchAnswer? {
        guard let query = normalized(query) else { return nil }
        if let listed = listAnswer(query, rows: rows) { return listed }
        if let rule = ruleAnswer(query, rules: hiddenByRules) { return rule }
        guard let inventory else { return .inventoryNotRead(query: query) }
        return inventoryAnswer(query, apps: inventory, checks: checks, policies: policies, now: now) ?? .notFound(query: query)
    }

    /// The answer as Wega says it; nil for `.onList`, which the row draws as links.
    static func text(for answer: UpdatesSearchAnswer, now: Date) -> String? {
        switch answer {
        case .onList:
            return nil
        case let .upToDate(name, version, checkedAt, sources):
            return trf("%@ — aktualna (%@, sprawdzono %@ przez %@)", name, version ?? "—",
                       CheckedAtCopy.day(checkedAt, now: now), sources.joined(separator: ", "))
        case let .notChecked(name, reason):
            return notCheckedText(name: name, reason: reason)
        case .hiddenByRule(let name):
            return trf("%@ — ukryta przez Twoją regułę", name)
        case .inventoryNotRead(let query):
            return trf("Nie mam jeszcze spisu aplikacji, więc nie wiem, co z „%@”.", query)
        case .notFound(let query):
            return trf("Nie widzę „%@” wśród aplikacji na tym Macu.", query)
        }
    }

    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    private static func showsManual(_ app: ManualOutdatedApp, under filter: UpdateFilter, isSecurity: (ManualOutdatedApp) -> Bool) -> Bool {
        switch filter {
        case .all, .apps: true
        case .security: isSecurity(app)
        case .cli: false
        }
    }

    private static func listAnswer(_ query: String, rows: [Row]) -> UpdatesSearchAnswer? {
        let found = matches(query, in: rows.map(\.name)).map { rows[$0] }
        guard !found.isEmpty else { return nil }
        return .onList(Array(found.prefix(maximumListed)), more: found.count > maximumListed)
    }

    private static func ruleAnswer(_ query: String, rules: [UpdatePolicyEntry]) -> UpdatesSearchAnswer? {
        matches(query, in: rules.map(\.displayName)).first.map { .hiddenByRule(name: rules[$0].displayName) }
    }

    private static func inventoryAnswer(
        _ query: String, apps: [ApplicationInfo], checks: [InstallationIdentity: InstallationCheck],
        policies: [String: UpdatePolicy], now: Date
    ) -> UpdatesSearchAnswer? {
        guard let index = matches(query, in: apps.map(\.name)).first else { return nil }
        let app = apps[index]
        return evidence(InventoryCheckPresentation(app: app, check: checks[app.installation], policies: policies, now: now))
    }

    /// The Inventory screen's own status for the app. An update the list does not show is no
    /// current result either: the list is the answer for updates.
    private static func evidence(_ presentation: InventoryCheckPresentation) -> UpdatesSearchAnswer {
        let name = presentation.app.name
        switch presentation.status {
        case .current:
            guard let check = presentation.check else { return .notChecked(name: name, reason: .noCurrentResult) }
            return .upToDate(name: name, version: presentation.app.version, checkedAt: check.checkedAt,
                             sources: check.sources.filter { $0.outcome == .current }.map { tr($0.source) })
        case .excluded: return .hiddenByRule(name: name)
        case .noSource: return .notChecked(name: name, reason: .noSource)
        case .failed: return .notChecked(name: name, reason: .checkFailed)
        case .notChecked, .stale, .updateAvailable: return .notChecked(name: name, reason: .noCurrentResult)
        }
    }

    private static func notCheckedText(name: String, reason: UpdatesSearchAnswer.NotCheckedReason) -> String {
        switch reason {
        case .noSource: trf("%@ — nie wiem, skąd ją aktualizować", name)
        case .checkFailed: trf("%@ — sprawdzenie się nie udało, spróbuję przy następnym skanie", name)
        case .noCurrentResult: trf("%@ — nie mam aktualnego wyniku, sprawdzę ją przy następnym skanie", name)
        }
    }
}

/// One answer to a search on Updates.
enum UpdatesSearchAnswer: Equatable {
    /// Why an app Inventory lists has no answer: no known source, a failed check, or no result
    /// that is current (none yet, older than a day, or an update the list does not show).
    enum NotCheckedReason: Equatable { case noSource, checkFailed, noCurrentResult }
    /// Up to `UpdatesSearch.maximumListed` rows of the list; `more` when there were others.
    case onList([UpdatesSearch.Row], more: Bool)
    case hiddenByRule(name: String)
    case upToDate(name: String, version: String?, checkedAt: Date, sources: [String])
    case notChecked(name: String, reason: NotCheckedReason)
    case inventoryNotRead(query: String)
    case notFound(query: String)
}

/// ⌘F's answer, one row above the Updates list: the matches as links that open the inspector, or
/// Inventory's word on an app that is not on the list, with the way to the rules or to Inventory.
struct UpdatesSearchAnswerRow: View {
    let answer: UpdatesSearchAnswer
    let onShow: (UpdatesSearch.Row) -> Void
    let onShowRules: () -> Void
    let onOpenInventory: () -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { content }
            VStack(alignment: .leading, spacing: 4) { content }
        }
        .font(.wega(.callout))
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var content: some View {
        if case let .onList(rows, more) = answer {
            Text(tr("Na liście aktualizacji:"))
            ForEach(rows) { row in
                Button(row.name) { onShow(row) }
                    .buttonStyle(.link)
            }
            if more {
                Text(tr("i więcej — zawęź wyszukiwanie"))
            }
        } else if let text = UpdatesSearch.text(for: answer, now: Date()) {
            Label(text, systemImage: symbol)
                .fixedSize(horizontal: false, vertical: true)
            if case .hiddenByRule = answer {
                Button(tr("Pokaż reguły"), action: onShowRules)
                    .buttonStyle(.link)
            } else {
                Button(tr("Otwórz Spis"), action: onOpenInventory)
                    .buttonStyle(.link)
            }
        }
    }

    private var symbol: String {
        switch answer {
        case .upToDate: "checkmark.circle"
        case .notChecked: "questionmark.circle"
        case .hiddenByRule: "eye.slash"
        case .onList, .inventoryNotRead, .notFound: "magnifyingglass"
        }
    }
}

/// The Updates screen's `.searchable` field, carried by an invisible view that `DetailColumn`
/// mounts only while Updates is on screen. `UpdateView` stays mounted on every screen, so the
/// field on it would sit in every screen's toolbar. Leaving Updates clears the query.
struct UpdatesSearchField: View {
    @Binding var search: String
    @FocusState private var searchFocused: Bool

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .searchable(text: $search, prompt: tr("Znajdź aplikację"))
            .searchFocused($searchFocused)
            .receivesSearchFocusRequests(on: .update) { searchFocused = true }
            .onDisappear { search = "" }
    }
}
