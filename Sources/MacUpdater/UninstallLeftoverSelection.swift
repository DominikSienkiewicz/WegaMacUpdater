import SwiftUI
import AppKit
import MacUpdaterCore

/// Spec §5.8: every decision the leftover section of the uninstall sheet renders — which items
/// are ticked when it opens, which sit in the probable section, what select-all covers and how a
/// row and the header read — so `UninstallLeftoverSelection` only draws them.
enum UninstallLeftoverPresentation {
    /// One app's leftovers: its main list, then the items to check before ticking.
    struct Section: Identifiable {
        let group: LeftoverGroup
        let main: [LeftoverItem]
        /// Found only by a weak source, or still used by another installed app.
        let probable: [LeftoverItem]

        var id: String { group.id }
    }

    /// One section per group, each list in the planner's canonical order.
    static func sections(_ groups: [LeftoverGroup]) -> [Section] {
        groups.map { group in
            Section(
                group: group,
                main: group.items.filter { !isProbable($0) },
                probable: group.items.filter(isProbable)
            )
        }
    }

    /// The paths ticked when the sheet opens. Nothing is ticked when the app scan was incomplete:
    /// an app missing from it may still use any of the items.
    static func defaultSelection(_ groups: [LeftoverGroup], applicationsIncomplete: Bool) -> Set<String> {
        guard !applicationsIncomplete else { return [] }
        return Set(groups.flatMap(\.items).filter(\.isSelectedByDefault).map(\.url.path))
    }

    /// What the select-all button ticks and unticks: the main lists only. Probable items are
    /// ticked one by one.
    static func bulkPaths(_ groups: [LeftoverGroup]) -> [String] {
        sections(groups).flatMap(\.main).map(\.url.path)
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
        let text = trf(
            "%@ · %@ zaznaczone",
            "\(ticked.count)",
            ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
        )
        return ticked.contains { sizes[$0.url.path] == nil } ? text + " …" : text
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
            notes.append(tr("Lista aplikacji jest niepełna — nic nie jest zaznaczone domyślnie."))
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

    private static func isProbable(_ item: LeftoverItem) -> Bool {
        item.probableReason != nil || !item.sharedWith.isEmpty
    }
}

// MARK: - UX-13 leftover selection

/// The sheet section listing the leftovers found for the non-brew targets, per app: the main
/// list, then the probable items. Selection is bound to the caller, which opens the sheet with
/// `UninstallLeftoverPresentation.defaultSelection`; the copy makes clear the files go to the
/// recoverable Trash. Sizes are measured here, one item at a time, after the sheet opens.
struct UninstallLeftoverSelection: View {
    let groups: [LeftoverGroup]
    @Binding var selected: Set<String>
    let catalogUnavailable: Bool
    let applicationsIncomplete: Bool
    let measure: @Sendable (URL) async -> LeftoverSize

    @State private var sizes: [String: LeftoverSize] = [:]

    private var bulkPaths: [String] { UninstallLeftoverPresentation.bulkPaths(groups) }
    private var allSelected: Bool { !bulkPaths.isEmpty && selected.isSuperset(of: bulkPaths) }

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
                if !bulkPaths.isEmpty {
                    Button(allSelected ? tr("Odznacz wszystko") : tr("Zaznacz wszystko")) {
                        if allSelected { selected.subtract(bulkPaths) }
                        else { selected.formUnion(bulkPaths) }
                    }
                    .buttonStyle(.plain)
                    .font(.wega(.subheadline))
                    .foregroundStyle(Color.wegaHoney)
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
                    rows(section.main)
                    if !section.probable.isEmpty {
                        Text(tr("Prawdopodobne — sprawdź przed zaznaczeniem"))
                            .font(.wega(.footnote, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.top, 4)
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
                    Text(UninstallLeftoverPresentation.sourceLabel(item))
                        .font(.wega(.footnote))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
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
