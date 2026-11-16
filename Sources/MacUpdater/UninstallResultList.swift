import SwiftUI
import MacUpdaterCore

/// The result of an uninstall run that left apps behind: one summary line, then one row per
/// app that was not removed, each with its own reason and the action that helps. A long
/// result scrolls inside a bounded height instead of pushing the app list out of the window.
struct UninstallResultList: View {
    let report: UninstallResultReport
    let onAction: (UninstallResultAction) -> Void
    let onDismiss: () -> Void

    private static let maxRowsHeight: CGFloat = 220

    /// Held here rather than per row: `ViewThatFits` builds both variants, so a row's own
    /// state would reset the moment an expanded detail made the list switch to scrolling.
    @State private var expandedRows: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                if let summary = report.summary {
                    ErrorBanner(message: summary)
                } else {
                    Spacer(minLength: 0)
                }
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.wega(.callout))
                        .foregroundStyle(.secondary)
                        .padding(6)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tr("Ukryj wynik"))
            }
            if !report.rows.isEmpty {
                ViewThatFits(in: .vertical) {
                    rowStack
                    ScrollView { rowStack }
                }
                .frame(maxHeight: Self.maxRowsHeight)
            }
        }
        .onChange(of: report) { _, _ in expandedRows = [] }
    }

    private var rowStack: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(report.rows) { row in
                UninstallResultRowView(row: row, showsDetail: detailBinding(for: row.id), onAction: onAction)
                if row.id != report.rows.last?.id {
                    Divider().opacity(0.4)
                }
            }
        }
        .padding(.horizontal, 12)
        .background(Color(NSColor.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
    }

    private func detailBinding(for id: String) -> Binding<Bool> {
        Binding(
            get: { expandedRows.contains(id) },
            set: { isExpanded in
                if isExpanded { expandedRows.insert(id) } else { expandedRows.remove(id) }
            }
        )
    }
}

private struct UninstallResultRowView: View {
    let row: UninstallResultRow
    @Binding var showsDetail: Bool
    let onAction: (UninstallResultAction) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.name).font(.wega(.callout, weight: .medium))
                if let location = row.location {
                    Text(location)
                        .font(.wega(.footnote, monospaced: true))
                        .foregroundStyle(Color.wegaDanger.opacity(0.85))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Text(row.reason)
                    .font(.wega(.footnote))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail = row.detail {
                    WegaDisclosure(isExpanded: $showsDetail) {
                        Text(detail)
                            .font(.wega(.footnote, monospaced: true))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 4)
                    } label: {
                        Text(tr("Szczegóły")).font(.wega(.footnote))
                    }
                }
            }
            Spacer(minLength: 8)
            ForEach(row.actions, id: \.title) { action in
                Button(action.title) { onAction(action) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityLabel(trf("%@: %@", row.name, action.title))
            }
        }
        .padding(.vertical, 8)
    }
}
