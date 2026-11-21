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

    @EnvironmentObject private var store: CleanupStore
    /// The Settings switch for the Files and Folders map; the section follows it, not the stored report.
    @AppStorage(CleanupTCCMap.enabledKey) private var tccMapEnabled = CleanupTCCMap.enabledByDefault
    @State private var confirming: CleanupFinding?
    @State private var showsPathWarning = false
    @State private var exportError: String?
    @State private var copiedCommand: String?
    @State private var search = ""
    @FocusState private var searchFocused: Bool

    private var isIdle: Bool { store.phase == .idle }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 10)
            messages
            content
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
        .searchable(text: $search, prompt: tr("Szukaj narzędzia lub ścieżki…"))
        .searchFocused($searchFocused)
        .receivesSearchFocusRequests(on: .cleanup) { searchFocused = true }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                pathLine
                if let report = store.report {
                    Text(CleanupPresentation.headline(report.totals))
                        .font(.wega(.headline))
                    Text(CleanupPresentation.scanDateText(report.createdAt))
                        .font(.wega(.subheadline))
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()
            if let progress = CleanupPresentation.progressText(store.phase) {
                ProgressView().controlSize(.small)
                Text(progress)
                    .font(.wega(.subheadline))
                    .foregroundStyle(.secondary)
            }
            if store.phase == .scanning || store.phase == .readingPath {
                Button(tr("Anuluj")) { store.cancel() }
                    .controlSize(.small)
            }
            exportMenu
            Button { showsPathWarning = true } label: {
                Label(tr("Odczytaj PATH"), systemImage: "terminal")
            }
            .controlSize(.small)
            .disabled(!isIdle)
            Button { store.scan() } label: {
                Label(tr("Skanuj"), systemImage: "magnifyingglass")
            }
            .controlSize(.small)
            .disabled(!isIdle)
        }
    }

    private var pathLine: some View {
        HStack(spacing: 6) {
            Text(verbatim: "PATH:")
                .font(.wega(.subheadline, weight: .semibold))
                .foregroundStyle(.secondary)
            let hint = CleanupPresentation.pathHint(store.pathSnapshot, now: Date())
            if store.pathSnapshot?.isApproximate != false {
                WegaBadge(label: hint, variant: .brew)
            } else {
                Text(hint)
                    .font(.wega(.subheadline))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var exportMenu: some View {
        Menu {
            Button(tr("Raport tekstowy…")) { export(.text) }
            Button(tr("Raport JSON…")) { export(.json) }
        } label: {
            Label(tr("Eksportuj"), systemImage: "square.and.arrow.up")
        }
        .menuStyle(.button)
        .controlSize(.small)
        .fixedSize()
        .disabled(store.report == nil)
        .help(tr("Zapisz raport jako tekst lub JSON, ze ścieżkami w postaci ~"))
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

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if let report = store.report {
            let cards = CleanupPresentation.sections(report, home: store.home, tccMapEnabled: tccMapEnabled)
                .compactMap { section in
                    CleanupPresentation.layout(of: section, search: search).map { (section: section, layout: $0) }
                }
            ScrollView {
                if cards.isEmpty, !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(tr("Nic w raporcie nie pasuje do wyszukiwania."))
                        .font(.wega(.subheadline))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(32)
                } else {
                    VStack(spacing: 12) {
                        ForEach(cards, id: \.section.kind) { card in
                            CleanupSectionCard(
                                section: card.section, layout: card.layout, canRemove: isIdle, copiedCommand: copiedCommand,
                                onRemove: { id in confirming = report.findings.first { $0.id == id } }, onCopy: copy,
                                onKeep: { store.keep($0) }, onUninstallApp: onUninstallApp
                            )
                        }
                    }
                    .padding(16)
                }
            }
            .scrollEdgeEffectStyle(.soft, for: .top)
        } else if store.phase == .scanning {
            // UXP-27 — Wega sniffs during every scan, this one too.
            SniffingScene(caption: tr("Przeglądam katalogi z PATH i wersje narzędzi. Niczego nie zmieniam."))
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            EmptyHero(
                pose: .idle, title: tr("Porządki"),
                message: tr("Wega sprawdzi, które narzędzia masz w kilku kopiach i co zostało po aktualizacjach. Nic nie zniknie bez Twojego potwierdzenia."),
                action: AnyView(
                    Button(tr("Skanuj")) { store.scan() }
                        .disabled(!isIdle)
                ),
                compact: true
            )
        }
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

/// One section of the report: its notes, the tools that need action, then the rest in a
/// collapsed "Bez akcji" group. While searching, every match is shown and nothing is collapsed.
private struct CleanupSectionCard: View {
    let section: CleanupPresentation.Section
    let layout: CleanupPresentation.SectionLayout
    let canRemove: Bool
    let copiedCommand: String?
    let onRemove: (_ findingID: String) -> Void
    let onCopy: (String) -> Void
    let onKeep: (_ findingID: String) -> Void
    let onUninstallApp: (URL) -> Void

    @State private var quietExpanded = false
    @State private var expandedOrigins: Set<String> = []

    var body: some View {
        WegaCard(padded: false) {
            WegaCardHeader(icon: icon, title: section.title, count: nil, note: layout.headerNote)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(section.notes.indices, id: \.self) { index in
                    Text(section.notes[index])
                        .font(.wega(.subheadline))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, WegaLayout.cardPadding)
                        .padding(.vertical, 6)
                }
                rows(of: layout.shown)
                if let quietTitle = layout.quietTitle {
                    if !layout.shown.isEmpty {
                        Divider().opacity(0.3)
                    }
                    WegaDisclosure(isExpanded: $quietExpanded, leadingInset: WegaLayout.cardPadding) {
                        ForEach(layout.quiet.indices, id: \.self) { index in
                            Divider().opacity(0.3)
                            quietItem(layout.quiet[index])
                        }
                    } label: {
                        Text(quietTitle)
                            .font(.wega(.callout, weight: .semibold))
                            .padding(.trailing, WegaLayout.cardPadding)
                            .padding(.vertical, 8)
                    }
                }
            }
            .padding(.vertical, 6)
        }
    }

    @ViewBuilder
    private func quietItem(_ item: CleanupPresentation.QuietItem) -> some View {
        switch item {
        case .tool(let group):
            rows(of: [group])
        case .origin(let line):
            WegaDisclosure(isExpanded: originBinding(line.origin), leadingInset: WegaLayout.cardPadding + Self.originIndent) {
                rows(of: line.tools).padding(.leading, Self.originIndent)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(line.title)
                        .font(.wega(.callout, monospaced: true))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(line.title)
                    if let companions = line.companions {
                        Text(companions)
                            .font(.wega(.subheadline))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                .padding(.trailing, WegaLayout.cardPadding)
                .padding(.vertical, 6)
            }
        }
    }

    private static let originIndent: CGFloat = 16

    private func originBinding(_ origin: CleanupPresentation.Row.Origin) -> Binding<Bool> {
        let key = origin.directory + origin.source
        return Binding(
            get: { expandedOrigins.contains(key) },
            set: { open in
                if open { expandedOrigins.insert(key) } else { expandedOrigins.remove(key) }
            }
        )
    }

    private func rows(of toolGroups: [CleanupPresentation.ToolGroup]) -> some View {
        ForEach(toolGroups.indices, id: \.self) { groupIndex in
            let group = toolGroups[groupIndex]
            if groupIndex > 0 {
                Divider().opacity(0.3)
            }
            if let name = group.name {
                Text(name)
                    .font(.wega(.callout, weight: .semibold))
                    .padding(.horizontal, WegaLayout.cardPadding)
                    .padding(.top, 10)
            }
            ForEach(group.rows.indices, id: \.self) { index in
                if index > 0 {
                    Divider().opacity(0.3)
                }
                CleanupFindingRow(
                    row: group.rows[index], canRemove: canRemove, copiedCommand: copiedCommand,
                    onRemove: onRemove, onCopy: onCopy, onKeep: onKeep, onUninstallApp: onUninstallApp
                )
            }
        }
    }

    private var icon: String {
        switch section.kind {
        case .duplicates: "square.on.square"
        case .homebrew: "mug"
        case .runtimes: "square.stack.3d.up"
        case .gradle: "hammer"
        case .jetBrains: "chevron.left.forwardslash.chevron.right"
        case .shellState: "terminal"
        case .pathHygiene: "arrow.triangle.branch"
        case .protectedLocations: "lock.shield"
        case .filesAndFolders: "hand.raised"
        }
    }
}

/// The "zostaw" radio of a copy that offers the choice, then status, path, detail and size, then
/// the row's one control: a removal that opens the confirmation sheet, the hand-off to
/// "Odinstaluj aplikacje", a copy button, or a note in its place.
private struct CleanupFindingRow: View {
    let row: CleanupPresentation.Row
    let canRemove: Bool
    let copiedCommand: String?
    let onRemove: (_ findingID: String) -> Void
    let onCopy: (String) -> Void
    let onKeep: (_ findingID: String) -> Void
    let onUninstallApp: (URL) -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            if let keep = row.keep, let findingID = row.findingID {
                keepRadio(keep, findingID: findingID)
            }
            WegaBadge(label: row.status, variant: badgeVariant)
                .frame(minWidth: 120, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title)
                    .font(.wega(.callout, monospaced: true))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .help(row.title)
                Text(row.detail)
                    .font(.wega(.subheadline))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let size = row.sizeText {
                Text(size)
                    .font(.wega(.subheadline, monospaced: true))
                    .foregroundStyle(.secondary)
            }
            control
        }
        .padding(.horizontal, WegaLayout.cardPadding)
        .padding(.vertical, 8)
    }

    private var control: some View {
        VStack(alignment: .trailing, spacing: 4) {
            if let note = row.note {
                Text(note)
                    .font(.wega(.subheadline, monospaced: isCommand))
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.trailing)
                    .textSelection(.enabled)
                    .frame(maxWidth: 280, alignment: .trailing)
            }
            if let button = row.button {
                switch button {
                case .trash, .brew, .brewCleanup:
                    if let findingID = row.findingID {
                        Button(CleanupPresentation.buttonTitle(button)) { onRemove(findingID) }
                            .controlSize(.small)
                            .disabled(!canRemove)
                    }
                case .copyCommand(let command):
                    Button(copiedCommand == command ? tr("Skopiowano") : CleanupPresentation.buttonTitle(button)) {
                        onCopy(command)
                    }
                    .controlSize(.small)
                    .help(CleanupPresentation.effectText(for: .command(command)) ?? "")
                case .uninstallApp(_, let bundle):
                    Button(CleanupPresentation.buttonTitle(button)) { onUninstallApp(bundle) }
                        .controlSize(.small)
                }
            }
        }
    }

    /// Choosing the copy that already stays is recorded too, so a later `PATH` change keeps it.
    private func keepRadio(_ keep: CleanupPresentation.KeepControl, findingID: String) -> some View {
        Button { onKeep(findingID) } label: {
            Label(CleanupPresentation.keepTitle, systemImage: keep == .kept ? "largecircle.fill.circle" : "circle")
                .font(.wega(.subheadline))
        }
        .buttonStyle(.borderless)
        .disabled(!canRemove)
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
