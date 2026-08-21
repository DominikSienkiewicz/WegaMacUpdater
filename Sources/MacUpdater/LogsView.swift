import SwiftUI
import AppKit
import MacUpdaterCore

extension LogLevelFilter {
    var label: String {
        switch self {
        case .all:           return tr("Wszystkie")
        case .warningsAndUp: return tr("Ostrzeżenia+")
        case .errorsOnly:    return tr("Tylko błędy")
        }
    }
}

/// Przycinanie zaznaczenia do tego, co użytkownik faktycznie widzi.
///
/// Wydzielone z widoku, bo to jedyna reguła w tej zakładce, którą da się złamać cicho:
/// bez niej można zaznaczyć pięć wpisów, zmienić filtr i wysłać dwanaście.
enum LogSelection {
    static func pruned(_ selection: Set<LogEntry.ID>, toVisible visible: [LogEntry]) -> Set<LogEntry.ID> {
        selection.intersection(Set(visible.map(\.id)))
    }
}

struct LogsView: View {
    @ObservedObject var store = LogStore.shared
    var onWegaState: ((WegaState) -> Void)?
    var initialFilter: LogLevelFilter = .all

    @State private var filter: LogLevelFilter = .all
    @State private var search: String = ""
    @State private var confirmingClear = false
    @State private var selection: Set<LogEntry.ID> = []
    @State private var reportController: BugReportController?
    // OBS-02 — "Kopiuj" hands over the 2000 lines currently on screen. The export hands over
    // both log files plus the environment they were produced in, redacted.
    @StateObject private var diagnosticsExport = DiagnosticsExportController()

    private var visible: [LogEntry] {
        // Najnowsze na górze.
        filterLogEntries(store.entries, level: filter, search: search).reversed()
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider().opacity(0.5)
            if let reason = logEmptyReason(totalCount: store.entries.count, visibleCount: visible.count) {
                emptyState(reason)
            } else {
                List(visible, selection: $selection) { entry in
                    LogRow(entry: entry)
                        .listRowInsets(EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8))
                        .listRowSeparator(.hidden)
                }
                .listStyle(.plain)
                .scrollEdgeEffectStyle(.soft, for: .top)
            }
        }
        // UX-11c — native `.searchable` in place of the toolbar's hand-built search field.
        .searchable(text: $search, prompt: tr("Szukaj w logach…"))
        .onAppear {
            filter = initialFilter
            onWegaState?(WegaState(pose: .sniff, line: tr("Zaglądam do notatek…")))
        }
        .onChange(of: filter) { _, _ in selection = LogSelection.pruned(selection, toVisible: visible) }
        .onChange(of: search) { _, _ in selection = LogSelection.pruned(selection, toVisible: visible) }
        .sheet(item: $reportController) { controller in
            BugReportSheet(controller: controller) { reportController = nil }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Picker("", selection: $filter) {
                ForEach(LogLevelFilter.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(width: 320)

            Spacer()

            Button { revealInFinder() } label: { Label(tr("Pokaż w Finderze"), systemImage: "folder") }
                .buttonStyle(.plain).foregroundStyle(Color.wegaHoney)
            Button { copyVisible() } label: { Label(tr("Kopiuj"), systemImage: "doc.on.doc") }
                .buttonStyle(.plain).foregroundStyle(Color.wegaHoney)
            Button {
                Task { await diagnosticsExport.export() }
            } label: {
                Label(tr("Eksportuj diagnostykę"), systemImage: "shippingbox")
            }
            .buttonStyle(.plain).foregroundStyle(Color.wegaHoney)
            .disabled(diagnosticsExport.isExporting)
            .help(tr("Zapisuje redagowaną paczkę zip z oboma plikami logów i pełnym kontekstem środowiska."))
            Button { startReport() } label: {
                Label(tr("Zgłoś błąd…"), systemImage: "exclamationmark.bubble")
            }
            .buttonStyle(.plain).foregroundStyle(Color.wegaHoney)
            .disabled(selection.isEmpty)
            .help(tr("Zaznacz wpisy w logu, żeby zgłosić błąd"))
            Button { confirmingClear = true } label: { Label(tr("Wyczyść"), systemImage: "trash") }
                .buttonStyle(.plain).foregroundStyle(Color.wegaDanger)
                .confirmationDialog(tr("Wyczyścić logi?"), isPresented: $confirmingClear) {
                    Button(tr("Wyczyść"), role: .destructive) { clearLog() }
                    Button(tr("Anuluj"), role: .cancel) { /* tylko zamyka dialog */ }
                }
        }
        .padding(.horizontal, 16)
        .frame(height: 48)
    }

    // UX-06 — an empty log and a filter that hides everything are different situations, so
    // each gets its own state. "Nothing has happened yet" rests; "nothing matches the filter"
    // sniffs and offers a way back to the full list.
    @ViewBuilder
    private func emptyState(_ reason: LogEmptyReason) -> some View {
        switch reason {
        case .noEntries:
            VStack(spacing: 16) {
                Spacer()
                WegaFull(pose: .idle, size: 120)
                Text(tr("Cicho jak makiem zasiał — żadnych zdarzeń."))
                    .font(.wega(.body)).foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .noFilterMatches:
            VStack(spacing: 12) {
                Spacer()
                WegaFull(pose: .sniff, size: 120)
                Text(tr("Nic nie pasuje do filtra."))
                    .font(.wega(.body)).foregroundStyle(.secondary)
                Text(tr("Zmień poziom lub frazę wyszukiwania, żeby zobaczyć więcej zdarzeń."))
                    .font(.wega(.callout)).foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                Button(tr("Wyczyść filtr")) {
                    filter = .all
                    search = ""
                }
                .controlSize(.small)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func revealInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([store.logFileURL])
    }

    private func copyVisible() {
        let text = visible.map(\.fileText).joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Czyszczenie logu zabiera ze sobą zaznaczenie — ta sama zasada, co przy zmianie
    /// filtra: zaznaczone może być wyłącznie to, co użytkownik nadal widzi. Bez tego
    /// „Zgłoś błąd…" zostaje aktywny nad wpisami, których już nie ma.
    private func clearLog() {
        store.clear()
        selection.removeAll()
    }

    private func startReport() {
        let selected = visible.filter { selection.contains($0.id) }
                              .sorted { $0.date < $1.date }
        guard !selected.isEmpty else { return }
        reportController = BugReportController(entries: selected)
    }
}

/// Jeden wiersz logu: płaska linia albo, gdy wpis niesie strukturalny detal, `WegaDisclosure`
/// go rozwijająca.
///
/// Własny `View`, bo rozwinięcie jest stanem per wiersz, a `List`/`ForEach` nie dają miejsca
/// na `@State` per element inaczej niż wydzielając go do osobnego typu. `WegaDisclosure`
/// zamiast `DisclosureGroup`, żeby cel kliknięcia był całym nagłówkiem, nie samym chevronem —
/// `UX02ActionableControlsTests.noDisclosureGroupSurvivesInTheAppTarget` pilnuje tego w całym
/// celu aplikacji.
private struct LogRow: View {
    let entry: LogEntry

    @State private var isExpanded = false

    var body: some View {
        if let detail = entry.detail {
            WegaDisclosure(isExpanded: $isExpanded) {
                Text(detail.continuationLines.joined(separator: "\n"))
                    .font(.wega(.footnote, monospaced: true))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 8)
            } label: {
                rowLine(entry)
            }
        } else {
            rowLine(entry)
        }
    }

    private func rowLine(_ e: LogEntry) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(Self.timeFormatter.string(from: e.date))
                .font(.wega(.subheadline, monospaced: true)).foregroundStyle(.tertiary)
                .frame(width: 64, alignment: .leading)
            Text(e.level.rawValue.uppercased())
                .font(.wega(.footnote, weight: .bold, monospaced: true))
                .foregroundStyle(levelColor(e.level))
                .frame(width: 64, alignment: .leading)
            Text(e.category.label)
                .font(.wega(.footnote, weight: .medium))
                .foregroundStyle(Color.wegaHoney)
                .frame(width: 84, alignment: .leading)
            Text(e.message)
                .font(.wega(.subheadline, monospaced: true))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 2)
    }

    private func levelColor(_ level: LogLevel) -> Color {
        switch level {
        case .error:        return Color.wegaDanger
        case .warning:      return Color.wegaToffee
        case .info, .debug: return .secondary
        }
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f
    }()
}
