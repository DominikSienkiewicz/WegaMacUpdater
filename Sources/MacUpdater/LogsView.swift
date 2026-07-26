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

struct LogsView: View {
    @ObservedObject var store = LogStore.shared
    var onWegaState: ((WegaState) -> Void)?
    var initialFilter: LogLevelFilter = .all

    @State private var filter: LogLevelFilter = .all
    @State private var search: String = ""
    @State private var confirmingClear = false

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
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(visible) { row($0) }
                    }
                    .padding(.vertical, 6)
                }
                .scrollEdgeEffectStyle(.soft, for: .top)
            }
        }
        // UX-11c — native `.searchable` in place of the toolbar's hand-built search field.
        .searchable(text: $search, prompt: tr("Szukaj w logach…"))
        .onAppear {
            filter = initialFilter
            onWegaState?(WegaState(pose: .sniff, line: tr("Zaglądam do notatek…")))
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
            Button { confirmingClear = true } label: { Label(tr("Wyczyść"), systemImage: "trash") }
                .buttonStyle(.plain).foregroundStyle(Color.wegaDanger)
                .confirmationDialog(tr("Wyczyścić logi?"), isPresented: $confirmingClear) {
                    Button(tr("Wyczyść"), role: .destructive) { store.clear() }
                    Button(tr("Anuluj"), role: .cancel) { /* tylko zamyka dialog */ }
                }
        }
        .padding(.horizontal, 16)
        .frame(height: 48)
    }

    private func row(_ e: LogEntry) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(Self.timeFormatter.string(from: e.date))
                .font(.system(size: 11, design: .monospaced)).foregroundStyle(.tertiary)
                .frame(width: 64, alignment: .leading)
            Text(e.level.rawValue.uppercased())
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(levelColor(e.level))
                .frame(width: 64, alignment: .leading)
            Text(e.category.label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Color.wegaHoney)
                .frame(width: 84, alignment: .leading)
            Text(e.message)
                .font(.system(size: 11.5, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16).padding(.vertical, 4)
    }

    private func levelColor(_ level: LogLevel) -> Color {
        switch level {
        case .error:        return Color.wegaDanger
        case .warning:      return Color.wegaToffee
        case .info, .debug: return .secondary
        }
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
                    .font(.system(size: 13)).foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .noFilterMatches:
            VStack(spacing: 12) {
                Spacer()
                WegaFull(pose: .sniff, size: 120)
                Text(tr("Nic nie pasuje do filtra."))
                    .font(.system(size: 13)).foregroundStyle(.secondary)
                Text(tr("Zmień poziom lub frazę wyszukiwania, żeby zobaczyć więcej zdarzeń."))
                    .font(.system(size: 12)).foregroundStyle(.tertiary)
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
        let text = visible.map(\.fileLine).joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f
    }()
}
