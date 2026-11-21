import SwiftUI
import MacUpdaterCore

// MARK: - C2 stage 4 — the list while the after-update summary is open
//
// The summary replaces the rows until it is closed: what the run did to every planned item, the
// hand-offs the band counts, the restart bar and the run's log. Nothing here can be queued or
// inspected (the inspector's after-update mode is stage 5), so ⇧⌘A and ⌘⏎ have nothing to reach.

/// The list header's row while the summary is open: the queue column held empty, „Wynik
/// aktualizacji” in the group headers' monospaced capitals and, while anything is left to update,
/// the link that closes the summary — the same door as the band's „Zamknij podsumowanie”.
struct UpdateRunSummaryHeader: View {
    let remainingCount: Int
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: WegaLayout.checkboxSpacing) {
            QueueColumnPlaceholder()
            Text(tr("Wynik aktualizacji"))
                .font(.wega(.subheadline, weight: .semibold, monospaced: true))
                .tracking(0.8)
                .textCase(.uppercase)
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
            if remainingCount > 0 {
                Button(trf("Pozostałe aktualizacje: %@ ›", "\(remainingCount)"), action: onClose)
                    .buttonStyle(.link)
                    .font(.wega(.subheadline))
                    .lineLimit(1)
                    // The count is what the link says; at the narrowest column the title gives way.
                    .layoutPriority(1)
            }
        }
    }
}

/// The summary's groups, each only when it has rows: „Wymaga uwagi” (with the link to the run's
/// log), „Nie zaczęłam”, the hand-offs `handOffs` draws, „Zaktualizowano”; then the restart bar and
/// the log with `listColumn`'s own views and closures.
struct UpdateRunSummaryList<HandOffs: View>: View {
    @EnvironmentObject private var scan: ScanStore
    let report: UpdateRunReport
    let onShowLog: () -> Void
    let handOffs: HandOffs
    /// The undo „Cofnij” asked about, pending the undo screen's own confirmation. Transient, as
    /// on that screen: no background task writes to it.
    @State private var undoTarget: UndoableUpdate?
    @State private var showUndoConfirmation = false

    /// `handOffs` draws exactly what the band's „U producenta” counts (`handOffCount(for: .all)`).
    init(report: UpdateRunReport, onShowLog: @escaping () -> Void, @ViewBuilder handOffs: () -> HandOffs) {
        self.report = report
        self.onShowLog = onShowLog
        self.handOffs = handOffs()
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: WegaLayout.sectionSpacing) {
                group(.needsAttention, title: tr("Wymaga uwagi"), tint: .wegaDanger, showsLogLink: true)
                group(.notStarted, title: tr("Nie zaczęłam"), tint: .wegaToffee)
                handOffs
                group(.updated, title: tr("Zaktualizowano"), tint: .wegaSuccess)
                if !scan.restartCandidates.isEmpty {
                    RestartSection(
                        candidates: scan.restartCandidates,
                        busyProcess: scan.restartBusy,
                        onRestart: { info in Task { await scan.restartApp(info) } },
                        pendingForce: scan.pendingForceRestart,
                        onForce: { info in Task { await scan.confirmForceRestart(info) } },
                        onKeepOpen: { info in scan.keepAppOpen(info) },
                        onDismissForcePrompt: { info in scan.dismissForceRestartPrompt(info) }
                    )
                }
                if scan.showLog {
                    BrewLogPanel(lines: scan.brewLog, tapTrust: scan.tapTrustActions) { scan.showLog = false }
                }
            }
            .padding(WegaLayout.listGutter)
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
        // The only scan under an open summary is the undo's check, which is replacing the
        // hand-off rows: inert for its duration, like `listColumn`'s rows.
        .disabled(!ScanSelectionGate.allowsSelection(isRefreshing: scan.isRefreshing))
        .undoConfirmation(target: $undoTarget, isPresented: $showUndoConfirmation)
        .wegaAttention(showUndoConfirmation)
    }

    @ViewBuilder
    private func group(_ group: UpdateRunReport.Group, title: String, tint: Color, showsLogLink: Bool = false) -> some View {
        let entries = report.entries(in: group)
        if !entries.isEmpty {
            WegaCard {
                UpdateGroupHeader(title: title, tint: tint, count: entries.count)
                    .overlay(alignment: .trailing) {
                        if showsLogLink {
                            Button(tr("Pokaż log"), action: onShowLog)
                                .buttonStyle(.link)
                                .font(.wega(.subheadline))
                                .padding(.trailing, WegaLayout.cardPadding)
                        }
                    }
                ForEach(entries) { entry in
                    UpdateRunResultRow.make(entry: entry, in: report, scan: scan, requestUndo: { undo in
                        undoTarget = undo
                        showUndoConfirmation = true
                    })
                        // One undo at a time: `undoUpdate` refuses a second while the first restores.
                        .disabled(scan.undoBusy != nil)
                        .overlay(alignment: .bottom) {
                            if entry.id != entries.last?.id { Divider().opacity(0.4).padding(.leading, WegaLayout.cardPadding) }
                        }
                }
            }
        }
    }
}

/// One planned item of the run: its icon, name, versions and what became of it, with
/// „Zaufaj nowemu podpisowi” or „Cofnij” where the report allows one. VoiceOver reads one
/// sentence, "{name}: {note}"; the buttons stay the row's actions.
struct UpdateRunResultRow: View {
    let entry: UpdateRunReportEntry
    /// This run's undo for the entry, which the note names ("kopia do …").
    let undo: UndoableUpdate?
    let isUndoing: Bool
    let onTrust: (() -> Void)?
    let onUndo: (() -> Void)?

    /// The report's note without the "{name}: " that a changed publisher's or a failed rollback's
    /// sentence starts with: the row already names the item, and VoiceOver would say it twice.
    /// The banners raised when the summary closes keep the whole sentence.
    var note: String {
        let sentence = entry.note(undo: undo)
        let prefix = "\(entry.name): "
        return sentence.hasPrefix(prefix) ? String(sentence.dropFirst(prefix.count)) : sentence
    }

    /// What VoiceOver reads for the row, worded now (re-read after a language switch).
    var accessibilitySentence: String { "\(entry.name): \(note)" }

    var body: some View {
        HStack(spacing: WegaLayout.checkboxSpacing) {
            QueueColumnPlaceholder()
            icon
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.name).font(.wega(.body, weight: .semibold))
                if entry.from != nil || entry.to != nil {
                    VersionArrow(from: entry.from ?? "—", to: entry.to ?? "—")
                }
                Text(note)
                    .font(.wega(.subheadline))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let undo {
                    RollbackScopeNotice(scope: undo.rollbackScope, compact: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            action
        }
        .padding(.horizontal, WegaLayout.cardPadding)
        .padding(.vertical, WegaLayout.updateRowPadding)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySentence)
    }

    @ViewBuilder
    private var icon: some View {
        if let path = entry.appPath {
            AppIcon(path: path, size: WegaLayout.updateIconSize)
        } else {
            PackageLetterIcon(name: entry.name, size: WegaLayout.updateIconSize)
        }
    }

    @ViewBuilder
    private var action: some View {
        if let onTrust {
            Button(tr("Zaufaj nowemu podpisowi"), action: onTrust)
                .controlSize(.small)
        } else if let onUndo {
            if isUndoing {
                ProgressView().controlSize(.small)
            } else {
                Button(tr("Cofnij"), action: onUndo)
                    .controlSize(.small)
            }
        }
    }
}

extension UpdateRunResultRow {
    /// The row the summary draws for `entry`: trust only where the report offers it, through
    /// today's store action; an undo only with this run's undo still in `scan.undoableUpdates`,
    /// and only as a request for `UndoConfirmation`'s question (`requestUndo`), never the undo itself.
    static func make(entry: UpdateRunReportEntry, in report: UpdateRunReport, scan: ScanStore,
                     requestUndo: @escaping (UndoableUpdate) -> Void) -> UpdateRunResultRow {
        let undo = report.undo(for: entry, in: scan.undoableUpdates)
        let onTrust: (() -> Void)? = entry.offersPublisherTrust ? {
            Task { await scan.trustNewPublisher(token: entry.name, reportedTeamID: entry.reportedTeamID, appURL: entry.appPath) }
        } : nil
        let onUndo: (() -> Void)? = undo.map { undo in { requestUndo(undo) } }
        return UpdateRunResultRow(entry: entry, undo: undo, isUndoing: scan.undoBusy == entry.name,
                                  onTrust: onTrust, onUndo: onUndo)
    }
}
