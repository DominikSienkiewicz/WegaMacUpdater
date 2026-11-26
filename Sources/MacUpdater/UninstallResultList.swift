import SwiftUI
import MacUpdaterCore

/// Presents the apps that stayed and each selected file, with recovery actions. A long
/// report scrolls inside a bounded height to leave room for the app list.
struct UninstallResultList: View {
    let report: UninstallResultReport
    let onAction: (UninstallResultAction) -> Void
    let onDismiss: () -> Void

    private static let maxRowsHeight: CGFloat = 220

    /// Held here rather than per row: `ViewThatFits` builds both variants, so a row's own
    /// state would reset the moment an expanded detail made the list switch to scrolling.
    @State private var expandedRows: Set<String> = []
    @State private var expandedFileGroups: Set<UninstallFileGroup.Kind> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                if let summary = report.summary {
                    ErrorBanner(message: summary)
                } else {
                    Spacer(minLength: 0)
                }
                if report.offersOpenTrash {
                    Button(UninstallResultAction.openTrash.title) { onAction(.openTrash) }
                        .controlSize(.small)
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
            if !report.rows.isEmpty || !report.files.isEmpty {
                ViewThatFits(in: .vertical) {
                    rowStack
                    ScrollView { rowStack }
                }
                .frame(maxHeight: Self.maxRowsHeight)
            }
        }
        .onChange(of: report) { _, _ in
            expandedRows.removeAll()
            expandedFileGroups.removeAll()
        }
    }

    private var rowStack: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(report.rows) { row in
                UninstallResultRowView(row: row, showsDetail: detailBinding(for: row.id), onAction: onAction)
                if row.id != report.rows.last?.id {
                    Divider().opacity(0.4)
                }
            }
            if !report.files.isEmpty {
                Text(tr("Resztki aplikacji"))
                    .font(.wega(.callout, weight: .semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 8)
                    .accessibilityAddTraits(.isHeader)
                ForEach(report.fileGroups) { group in
                    WegaDisclosure(isExpanded: fileGroupBinding(for: group.id)) {
                        ForEach(group.files) { file in
                            UninstallFileResultRow(file: file, onAction: onAction)
                            if file.id != group.files.last?.id { Divider().opacity(0.4) }
                        }
                        .padding(.leading, 16)
                    } label: {
                        Text(group.title)
                            .font(.wega(.callout, weight: .medium))
                            .padding(.vertical, 6)
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .background(Color(NSColor.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
    }

    private func fileGroupBinding(for kind: UninstallFileGroup.Kind) -> Binding<Bool> {
        Binding(
            get: { expandedFileGroups.contains(kind) },
            set: { isExpanded in
                if isExpanded { expandedFileGroups.insert(kind) } else { expandedFileGroups.remove(kind) }
            }
        )
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

private struct UninstallFileResultRow: View {
    let file: UninstallFileResult
    let onAction: (UninstallResultAction) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text((file.url.path as NSString).abbreviatingWithTildeInPath)
                    .font(.wega(.footnote, monospaced: true))
                    .textSelection(.enabled)
                Text(file.reason)
                    .font(.wega(.footnote))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if let action = file.action {
                Button(action.title) { onAction(action) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityLabel(trf("%@: %@", file.url.path, action.title))
            }
        }
        .padding(.vertical, 6)
    }
}
