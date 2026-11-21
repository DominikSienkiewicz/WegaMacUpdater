import SwiftUI
import MacUpdaterCore

enum DiagnosticsExportOutcome: Equatable { case saved(URL), failed(String), cancelled }

struct DiagnosticsExportPayload {
    let data: Data
    let suggestedFileName: String
}

/// The sentence the user reads after an export. A cancelled panel says nothing: the user
/// chose not to save, so there is nothing to report. A reason's own closing full stop is
/// dropped, since the sentence puts one after it.
enum DiagnosticsExportStatusCopy {
    static func text(for outcome: DiagnosticsExportOutcome?) -> String? {
        switch outcome {
        case .saved: return tr("Zapisano diagnostykę.")
        case .failed(let reason):
            let sentence = reason.hasSuffix(".") ? String(reason.dropLast()) : reason
            return trf("Nie udało się zapisać diagnostyki: %@. Spróbuj ponownie.", sentence)
        case .cancelled, nil: return nil
        }
    }
}

/// Names what the report button opens, so the label is the promise: the sheet only opens
/// a draft, nothing is sent until the user sends it from their mail client or GitHub.
enum BugReportCopy {
    static func openTitle(for channel: BugReportChannel) -> String {
        switch channel {
        case .email: return tr("Otwórz szkic e-maila")
        case .gitHubIssue: return tr("Otwórz zgłoszenie na GitHubie")
        }
    }

    static func entriesHint(entryCount: Int) -> String? {
        entryCount == 0 ? tr("Zaznacz wpisy w logu, jeśli chcesz je dołączyć.") : nil
    }
}

struct DiagnosticsExportStatusRow: View {
    @ObservedObject var controller: DiagnosticsExportController

    var body: some View {
        switch controller.outcome {
        case .saved:
            HStack(spacing: 10) {
                if let text = DiagnosticsExportStatusCopy.text(for: controller.outcome) {
                    Label(text, systemImage: "checkmark.circle")
                        .font(.wega(.subheadline)).foregroundStyle(.secondary)
                }
                Button(tr("Pokaż w Finderze")) { controller.revealLastExport() }
                    .buttonStyle(.link).font(.wega(.subheadline))
                Spacer()
            }
        case .failed:
            if let text = DiagnosticsExportStatusCopy.text(for: controller.outcome) {
                Text(text)
                    .font(.wega(.subheadline)).foregroundStyle(Color.wegaDanger)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .cancelled, nil:
            EmptyView()
        }
    }
}
