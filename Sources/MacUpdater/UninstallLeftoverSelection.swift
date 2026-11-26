import SwiftUI
import AppKit
import MacUpdaterCore

/// File groups, selection policy and labels for the uninstall sheet.
enum UninstallLeftoverPresentation {
    struct Section: Identifiable {
        let group: LeftoverGroup
        var cacheAndLogs: [LeftoverItem] = []
        var personalData: [LeftoverItem] = []
        var probable: [LeftoverItem] = []

        var id: String { group.id }
    }

    static func sections(_ groups: [LeftoverGroup]) -> [Section] {
        let library = FileManager.default.homeDirectoryForCurrentUser.appending(component: "Library").pathComponents
        return groups.map { group in
            group.items.reduce(into: Section(group: group)) { section, item in
                if !item.hasStrongUnsharedMatch {
                    section.probable.append(item)
                } else if isCacheOrLog(item, library: library) {
                    section.cacheAndLogs.append(item)
                } else {
                    section.personalData.append(item)
                }
            }
        }
    }

    private static func isCacheOrLog(_ item: LeftoverItem, library: [String]) -> Bool {
        let components = item.url.pathComponents
        guard components.starts(with: library), components.count > library.count + 1 else { return false }
        return components[library.count] == "Caches" || components[library.count] == "Logs"
    }

    /// An incomplete inventory may miss another app that uses a cache, so each item needs individual consent.
    static func bulkPaths(_ groups: [LeftoverGroup], applicationsIncomplete: Bool = false) -> [String] {
        guard !applicationsIncomplete else { return [] }
        return sections(groups).flatMap(\.cacheAndLogs).map(\.url.path)
    }

    /// What "Odznacz wszystko" unticks: every item of the sheet, probable ones ticked by hand too.
    static func deselectAllPaths(_ groups: [LeftoverGroup]) -> [String] {
        groups.flatMap(\.items).map(\.url.path)
    }

    /// Where the item was found. Another app still using it outweighs everything else.
    static func sourceLabel(_ item: LeftoverItem) -> String {
        if !item.sharedWith.isEmpty {
            return trf("używa też %@", item.sharedWith.joined(separator: ", "))
        }
        switch item.probableReason {
        case .outsideLibrary: return tr("poza ~/Library")
        case .caskMatchedByName: return tr("lista Homebrew (dopasowanie po nazwie)")
        case .appName: return tr("nazwa aplikacji")
        case .notNamedForApp: return tr("lista Homebrew (wspólny folder?)")
        case nil: break
        }
        switch item.source {
        case .appName: return tr("nazwa aplikacji")
        case .homebrewZap: return tr("lista Homebrew")
        case .bundleIdentifier: return tr("identyfikator aplikacji")
        }
    }

    /// `nil` while the item is still being measured.
    static func sizeText(_ size: LeftoverSize?) -> String {
        switch size {
        case nil: "…"
        case .unknown: tr("rozmiar nieznany")
        case .bytes(let bytes): ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        }
    }

    /// The ticked count and their measured total, marked as incomplete while a ticked item is
    /// still being measured.
    static func header(groups: [LeftoverGroup], selected: Set<String>, sizes: [String: LeftoverSize]) -> String {
        let ticked = groups.flatMap(\.items).filter { selected.contains($0.url.path) }
        let total = ticked.reduce(Int64(0)) { sum, item in
            guard case .bytes(let bytes) = sizes[item.url.path] else { return sum }
            return sum + bytes
        }
        let text = trf("%@ · %@ zaznaczone", "\(ticked.count)", totalText(total))
        return ticked.contains { sizes[$0.url.path] == nil } ? text + " …" : text
    }

    /// A number even for nothing: "0 KB", never "Zero KB".
    private static func totalText(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false
        return formatter.string(fromByteCount: bytes)
    }

    /// Without any item the section still has to say that the Homebrew list could not be read.
    static func showsSection(groups: [LeftoverGroup], catalogUnavailable: Bool) -> Bool {
        !groups.isEmpty || catalogUnavailable
    }

    /// Why items may be missing from the list or left unticked.
    static func notes(catalogUnavailable: Bool, applicationsIncomplete: Bool) -> [String] {
        var notes: [String] = []
        if catalogUnavailable {
            notes.append(tr("Lista Homebrew jest niedostępna — pokazano tylko resztki znalezione po identyfikatorze i nazwie."))
        }
        if applicationsIncomplete {
            notes.append(tr("Lista aplikacji jest niepełna. Inne aplikacje mogą używać tych plików. Wybierz je pojedynczo."))
        }
        return notes
    }

    static func displayPath(_ item: LeftoverItem) -> String {
        (item.url.path as NSString).abbreviatingWithTildeInPath
    }

    /// VoiceOver reads the path, where the item was found and its size; the toggle style adds
    /// the ticked state.
    static func accessibilityLabel(_ item: LeftoverItem, size: LeftoverSize?) -> String {
        "\(displayPath(item)), \(sourceLabel(item)), \(sizeText(size))"
    }
}

// MARK: - UX-13 leftover selection

/// Optional files that can accompany a non-Homebrew app to the Trash. Sizes arrive after the sheet opens.
struct UninstallLeftoverSelection: View {
    let groups: [LeftoverGroup]
    @Binding var selected: Set<String>
    let catalogUnavailable: Bool
    let applicationsIncomplete: Bool
    let measure: @Sendable (URL) async -> LeftoverSize

    @State private var sizes: [String: LeftoverSize] = [:]

    private var bulkPaths: [String] {
        UninstallLeftoverPresentation.bulkPaths(groups, applicationsIncomplete: applicationsIncomplete)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "folder.badge.minus")
                    .foregroundStyle(Color.wegaHoney)
                    .font(.wega(.body))
                Text(tr("Resztki aplikacji"))
                    .font(.wega(.callout, weight: .semibold))
                Text(UninstallLeftoverPresentation.header(groups: groups, selected: selected, sizes: sizes))
                    .font(.wega(.callout, monospaced: true))
                    .foregroundStyle(.tertiary)
                Spacer()
                if !selected.isEmpty {
                    Button(tr("Odznacz wszystko")) {
                        selected.subtract(UninstallLeftoverPresentation.deselectAllPaths(groups))
                    }
                    .buttonStyle(.link)
                }
            }
            if !groups.isEmpty {
                Text(tr("Domyślnie zachowasz wszystkie pliki z tej listy."))
                    .font(.wega(.subheadline))
                if !bulkPaths.isEmpty {
                    Button(tr("Zaznacz pamięć podręczną i logi")) {
                        selected.formUnion(bulkPaths)
                    }
                    .disabled(selected.isSuperset(of: bulkPaths))
                }
            }
            Text(tr("Zaznaczone pliki trafią do Kosza — możesz je stamtąd przywrócić."))
                .font(.wega(.subheadline))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(
                UninstallLeftoverPresentation.notes(
                    catalogUnavailable: catalogUnavailable,
                    applicationsIncomplete: applicationsIncomplete
                ),
                id: \.self
            ) { note in
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Color.wegaHoney)
                        .font(.wega(.subheadline))
                    Text(note)
                        .font(.wega(.subheadline))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            ForEach(UninstallLeftoverPresentation.sections(groups)) { section in
                VStack(alignment: .leading, spacing: 6) {
                    if groups.count > 1 {
                        Text(section.group.app.name)
                            .font(.wega(.subheadline, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    if !section.cacheAndLogs.isEmpty {
                        sectionHeading(tr("Pamięć podręczna i logi"))
                        rows(section.cacheAndLogs)
                    }
                    if !section.personalData.isEmpty {
                        sectionHeading(tr("Ustawienia, profile i inne dane aplikacji"))
                        rows(section.personalData)
                    }
                    if !section.probable.isEmpty {
                        sectionHeading(tr("Prawdopodobne — sprawdź przed zaznaczeniem"))
                        rows(section.probable)
                    }
                }
            }
        }
        .padding(12)
        .background(
            Color(NSColor.controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: 10)
        )
        .task(id: groups.map(\.id)) { await measureSizes() }
    }

    private func sectionHeading(_ title: String) -> some View {
        Text(title)
            .font(.wega(.footnote, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.top, 4)
            .accessibilityAddTraits(.isHeader)
    }

    private func rows(_ items: [LeftoverItem]) -> some View {
        ForEach(items) { item in
            UninstallLeftoverRow(
                item: item,
                size: sizes[item.url.path],
                isOn: selected.contains(item.url.path),
                toggle: { toggle(item.url.path) }
            )
        }
    }

    /// One item at a time, so the rows fill in as sizes arrive; closing the sheet cancels the
    /// task and stops before the next item.
    private func measureSizes() async {
        for item in groups.flatMap(\.items) {
            if Task.isCancelled { return }
            sizes[item.url.path] = await measure(item.url)
        }
    }

    private func toggle(_ path: String) {
        if selected.contains(path) { selected.remove(path) } else { selected.insert(path) }
    }
}

private struct UninstallLeftoverRow: View {
    let item: LeftoverItem
    let size: LeftoverSize?
    let isOn: Bool
    let toggle: @MainActor @Sendable () -> Void

    private var sourceLabel: String { UninstallLeftoverPresentation.sourceLabel(item) }

    var body: some View {
        Toggle(isOn: selectionToggleBinding(isOn: isOn, toggle: toggle)) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 8) {
                    Text(item.url.lastPathComponent)
                        .font(.wega(.subheadline, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                    Text(UninstallLeftoverPresentation.sizeText(size))
                        .font(.wega(.footnote, monospaced: true))
                        .foregroundStyle(.secondary)
                    if item.sharedWith.isEmpty {
                        Text(sourceLabel)
                            .font(.wega(.footnote))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .help(sourceLabel)
                    }
                }
                if !item.sharedWith.isEmpty {
                    Label(sourceLabel, systemImage: "person.2")
                        .font(.wega(.footnote, weight: .semibold))
                        .foregroundStyle(Color.wegaHoney)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(UninstallLeftoverPresentation.displayPath(item))
                    .font(.wega(.footnote, monospaced: true))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .contentShape(Rectangle())
        }
        .toggleStyle(WegaCheckboxToggleStyle(glyphFont: .wega(.body), spacing: 10))
        .accessibilityLabel(UninstallLeftoverPresentation.accessibilityLabel(item, size: size))
    }
}
