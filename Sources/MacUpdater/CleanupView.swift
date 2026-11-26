import AppKit
import SwiftUI
import MacUpdaterCore

/// The Cleanup ("Porządki") destination: why one tool appears several times in System Settings →
/// Files and Folders, and what an update left behind. It binds `CleanupStore`'s state and sends
/// its intents; the report's texts, the sheet's content and the removal decisions come from
/// `CleanupPresentation`. The store runs one operation at a time, so every control that starts
/// one is enabled only while it is idle.
struct CleanupView: View {
    let onWegaState: (WegaState) -> Void
    /// Opens "Odinstaluj aplikacje" with the app at this bundle preselected.
    var onUninstallApp: (URL) -> Void = { _ in }
    var onReviewAppCopies: (String) -> Void = { _ in }

    @EnvironmentObject private var store: CleanupStore
    /// The Settings switch for the Files and Folders map; the section follows it, not the stored report.
    @AppStorage(CleanupTCCMap.enabledKey) private var tccMapEnabled = CleanupTCCMap.enabledByDefault
    @State private var confirming: CleanupFinding?
    @State private var showsPathWarning = false
    @State private var exportError: String?
    @State private var copiedCommand: String?
    @State private var search = ""
    @State private var inspectedTool: String?
    private var page: CleanupPage { store.filePage }
    @FocusState private var searchFocused: Bool

    private var isIdle: Bool { store.phase == .idle }

    var body: some View {
        Group {
            if page == .tools && store.report == nil {
                pages
            } else {
                pages
                    .searchable(text: $search, prompt: page == .tools ? tr("Szukaj narzędzia lub ścieżki…") : tr("Szukaj pliku lub projektu…"))
                    .searchFocused($searchFocused)
                    .receivesSearchFocusRequests(on: .cleanup) { searchFocused = true }
            }
        }
        .alert(tr("Odczytać PATH z powłoki?"), isPresented: $showsPathWarning) {
            Button(tr("Odczytaj PATH")) { store.readPath() }
            Button(tr("Anuluj"), role: .cancel) {}
        } message: {
            Text(tr("Wega raz uruchomi konfigurację Twojej powłoki (np. ~/.zshrc), żeby odczytać PATH. Jeśli teraz pojawi się jakieś pytanie lub okno, pochodzi ono z tej konfiguracji, nie z Wegi. Zapisana zostanie tylko lista katalogów PATH."))
        }
        .sheet(item: $confirming) { finding in
            CleanupConfirmationSheet(store: store, finding: finding) { confirming = nil }
        }
        .wegaAttention(confirming != nil || showsPathWarning || !errorMessages.isEmpty)
        .onChange(of: store.phase) { old, new in announce(from: old, to: new) }
        .onAppear { store.applyTCCMapSetting() }
        .onChange(of: page) { search = "" }
    }

    private var pages: some View {
        VStack(spacing: 0) {
            Picker(tr("Porządki"), selection: $store.filePage) {
                ForEach(CleanupPage.allCases, id: \.self) { page in Text(page.title).tag(page) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding([.top, .horizontal], 16)
            .disabled(!isIdle)
            if page == .tools {
                toolsPage
            } else {
                CleanupFileReviewView(page: page, search: search, store: page == .installers ? store.installerReview : store.xcodeReview)
                    .id(page)
            }
        }
    }

    @ViewBuilder
    private var toolsPage: some View {
        if let report = store.report {
            let review = CleanupToolsReview(report: report, home: store.home, mapEnabled: tccMapEnabled, search: search, inspectedTool: inspectedTool)
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(review.headline).font(.wega(.headline))
                    Text(CleanupPresentation.scanDateText(report.createdAt))
                        .font(.wega(.subheadline)).foregroundStyle(.secondary)
                }
                Spacer()
                progress
                if isIdle {
                    Button { store.scan() } label: {
                        Label(tr("Sprawdź ponownie"), systemImage: "arrow.clockwise")
                    }
                }
                reportMenu(report)
            }
            .controlSize(.small)
            .padding(16)
            messages
            CleanupToolsResultsView(review: review, searching: !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                                    actions: actions(for: report))
        } else {
            messages
            if store.phase == .scanning {
                HStack {
                    Spacer()
                    progress
                }
                .padding(.horizontal, 16)
                SniffingScene(caption: tr("Przeglądam katalogi z PATH i wersje narzędzi. Niczego nie zmieniam."))
                    .padding(24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                EmptyHero(
                    pose: .idle, title: tr("Porządki w narzędziach"),
                    message: tr("Wega poszuka dodatkowych kopii i plików po aktualizacjach."),
                    action: AnyView(
                        Button { store.scan() } label: { Label(tr("Sprawdź narzędzia"), systemImage: "magnifyingglass") }
                            .buttonStyle(.borderedProminent)
                            .tint(Color.wegaHoneyFill).foregroundStyle(Color.wegaInk)
                            .disabled(!isIdle)
                    ), compact: true
                )
            }
        }
    }

    @ViewBuilder
    private var progress: some View {
        if let text = CleanupPresentation.progressText(store.phase) {
            ProgressView().controlSize(.small)
            Text(text).font(.wega(.subheadline)).foregroundStyle(.secondary)
            if store.phase == .scanning || store.phase == .readingPath {
                Button(tr("Anuluj")) { store.cancel() }
            }
        }
    }

    private func reportMenu(_ report: CleanupReport) -> some View {
        Menu {
            Text(CleanupPresentation.headline(report.totals))
            Text("PATH: " + CleanupPresentation.pathHint(report.path, now: .now))
            Button(tr("Odczytaj PATH")) { showsPathWarning = true }.disabled(!isIdle)
            Divider()
            Button(tr("Raport tekstowy…")) { export(.text) }
            Button(tr("Raport JSON…")) { export(.json) }
        } label: {
            Label(tr("Opcje raportu"), systemImage: "ellipsis.circle")
                .labelStyle(.iconOnly)
        }
        .fixedSize()
        .help(tr("Opcje raportu"))
    }

    private func actions(for report: CleanupReport) -> CleanupFindingActions {
        CleanupFindingActions(
            canAct: isIdle, copiedCommand: copiedCommand,
            onRemove: { id in confirming = report.findings.first { $0.id == id } }, onCopy: copy, onKeep: { store.keep($0) },
            onUninstallApp: onUninstallApp, onReviewAppCopies: onReviewAppCopies,
            onCheckPath: { name in
                inspectedTool = name
                showsPathWarning = true
            }
        )
    }

    /// What went wrong, top to bottom. One list for the banners and for Wega's ball (UXP-27),
    /// so a new error cannot show without also holding it.
    private var errorMessages: [String] {
        [
            store.lastScanFailed ? tr("Skan nie powiódł się. Poprzedni wynik, jeśli był, zostaje na ekranie.") : nil,
            CleanupPresentation.pathReadMessage(store.pathReadResult),
            exportError,
        ].compactMap { $0 }
    }

    private var messages: some View {
        VStack(spacing: 8) {
            ForEach(errorMessages, id: \.self) { ErrorBanner(message: $0) }
        }
        .padding(.horizontal, 16)
    }

    // MARK: - Intents

    /// The command goes to the pasteboard only; Wega never runs it.
    private func copy(_ command: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
        copiedCommand = command
    }

    private func export(_ format: CleanupPresentation.ExportFormat) {
        guard let report = store.report else { return }
        exportError = nil
        let panel = NSSavePanel()
        panel.nameFieldStringValue = format.fileName
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try format.data(report, home: store.home, tccMapEnabled: tccMapEnabled).write(to: url, options: .atomic)
        } catch {
            exportError = trf("Nie udało się zapisać pliku: %@", error.localizedDescription)
        }
    }

    private func announce(from old: CleanupStore.Phase, to new: CleanupStore.Phase) {
        if new == .scanning {
            onWegaState(WegaState(pose: .sniff, line: tr("Węszę po katalogach z narzędziami…")))
        } else if old == .scanning, new == .idle {
            onWegaState(CleanupPresentation.scanEndedState(failed: store.lastScanFailed, cancelled: store.lastScanCancelled))
        }
    }
}

/// The "zostaw" radio of a copy that offers the choice, then status, path, detail and size, then
/// the row's one control: a removal that opens the confirmation sheet, the hand-off to
/// "Odinstaluj aplikacje", a copy button, or a note in its place.
struct CleanupFindingRow: View {
    let row: CleanupPresentation.Row
    let actions: CleanupFindingActions
    let actionInHeader: Bool
    let approximateOrder: Bool
    var firstInShell: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                if let keep = row.keep, let id = row.findingID { keepRadio(keep, findingID: id) }
                if let badge { WegaBadge(label: badge, variant: badgeVariant) }
                Spacer()
                if let size = row.sizeText {
                    Text(size).font(.wega(.subheadline, monospaced: true)).foregroundStyle(.secondary)
                }
            }
            if let source = row.finding?.source, row.origin != nil {
                let label = Text(CleanupToolsReview.friendlySource(source) ?? row.status)
                    .font(.wega(.callout, weight: .semibold))
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) {
                        label.frame(minWidth: 128, alignment: .leading)
                        pathText.fixedSize()
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        label
                        pathText
                    }
                }
            } else {
                pathText
            }
            let detail = row.copyDetail ?? row.detail
            if !detail.isEmpty {
                Text(detail).font(.wega(.subheadline)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            control
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, WegaLayout.cardPadding)
        .padding(.vertical, 8)
    }

    private var pathText: some View {
        Text(row.title)
            .font(.wega(.callout, monospaced: true)).textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var badge: String? {
        guard let finding = row.finding, finding.detector == .pathDuplicates else { return row.status }
        if finding.id == firstInShell { return tr("Pierwsza w ścieżce Terminala") }
        switch finding.status {
        case .expected where finding.source == .system: return nil
        case .active, .shadowed:
            if approximateOrder { return nil }
            return firstInShell == nil ? row.status : tr("Dalsza w ścieżce Terminala")
        default: return row.status
        }
    }

    private var control: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let note = row.note, note != tr("tylko informacja") {
                Text(note)
                    .font(.wega(.subheadline, monospaced: isCommand))
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
            }
            if !actionInHeader { CleanupFindingButton(row: row, actions: actions) }
        }
    }

    /// Choosing the copy that already stays is recorded too, so a later `PATH` change keeps it.
    private func keepRadio(_ keep: CleanupPresentation.KeepControl, findingID: String) -> some View {
        Button { actions.onKeep(findingID) } label: {
            Label(CleanupPresentation.keepTitle, systemImage: keep == .kept ? "largecircle.fill.circle" : "circle")
                .font(.wega(.subheadline))
        }
        .buttonStyle(.borderless)
        .disabled(!actions.canAct)
        .accessibilityLabel(CleanupPresentation.keepAccessibilityLabel(for: row))
        .accessibilityAddTraits(keep == .kept ? .isSelected : [])
    }

    private var isCommand: Bool {
        if case .copyCommand = row.button { return true }
        return false
    }

    private var badgeVariant: WegaBadgeVariant {
        switch row.bucket {
        case .safe: .success
        case .needsDecision: .brew
        case .excluded, nil: .info
        }
    }
}

struct CleanupFindingActions {
    let canAct: Bool
    let copiedCommand: String?
    let onRemove: (String) -> Void
    let onCopy: (String) -> Void
    let onKeep: (String) -> Void
    let onUninstallApp: (URL) -> Void
    let onReviewAppCopies: (String) -> Void
    let onCheckPath: (String) -> Void
}

struct CleanupFindingButton: View {
    let row: CleanupPresentation.Row
    let actions: CleanupFindingActions

    var body: some View {
        if let button = row.button {
            Group {
                switch button {
                case .trash, .brew, .brewCleanup:
                    if let id = row.findingID {
                        Button(CleanupPresentation.buttonTitle(button)) { actions.onRemove(id) }
                            .disabled(!actions.canAct)
                    }
                case .copyCommand(let command):
                    Button(actions.copiedCommand == command ? tr("Skopiowano") : CleanupPresentation.buttonTitle(button)) {
                        actions.onCopy(command)
                    }
                    .help(CleanupPresentation.effectText(for: .command(command)) ?? "")
                case .uninstallApp(_, let bundle):
                    Button(CleanupPresentation.buttonTitle(button)) { actions.onUninstallApp(bundle) }
                        .disabled(!actions.canAct)
                case .reviewAppCopies(let bundleIdentifier):
                    Button(CleanupPresentation.buttonTitle(button)) { actions.onReviewAppCopies(bundleIdentifier) }
                        .disabled(!actions.canAct)
                }
            }
            .controlSize(.small)
        }
    }
}
