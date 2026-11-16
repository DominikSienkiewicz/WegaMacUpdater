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

    @EnvironmentObject private var store: CleanupStore
    /// The Settings switch for the Files and Folders map; the section follows it, not the stored report.
    @AppStorage(CleanupTCCMap.enabledKey) private var tccMapEnabled = CleanupTCCMap.enabledByDefault
    @State private var confirming: CleanupFinding?
    @State private var showsPathWarning = false
    @State private var exportError: String?
    @State private var copiedCommand: String?

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
        .onChange(of: store.phase) { old, new in announce(from: old, to: new) }
        .onAppear { store.applyTCCMapSetting() }
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

    private var messages: some View {
        VStack(spacing: 8) {
            if store.lastScanFailed {
                ErrorBanner(message: tr("Skan nie powiódł się. Poprzedni wynik, jeśli był, zostaje na ekranie."))
            }
            if let message = CleanupPresentation.pathReadMessage(store.pathReadResult) {
                ErrorBanner(message: message)
            }
            if let exportError {
                ErrorBanner(message: exportError)
            }
        }
        .padding(.horizontal, 16)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if let report = store.report {
            ScrollView {
                VStack(spacing: 12) {
                    ForEach(
                        CleanupPresentation.sections(report, home: store.home, tccMapEnabled: tccMapEnabled), id: \.kind
                    ) { section in
                        CleanupSectionCard(
                            section: section, canRemove: isIdle, copiedCommand: copiedCommand,
                            onRemove: { id in confirming = report.findings.first { $0.id == id } }, onCopy: copy
                        )
                    }
                }
                .padding(16)
            }
            .scrollEdgeEffectStyle(.soft, for: .top)
        } else if store.phase == .scanning {
            EmptyHero(
                pose: .sniff, title: tr("Skanuję…"),
                message: tr("Przeglądam katalogi z PATH, katalogi wersji i stan powłok. Niczego nie zmieniam."),
                compact: true
            )
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

/// One section of the report: its notes, then its rows, with a tool's name above its first row.
private struct CleanupSectionCard: View {
    let section: CleanupPresentation.Section
    let canRemove: Bool
    let copiedCommand: String?
    let onRemove: (_ findingID: String) -> Void
    let onCopy: (String) -> Void

    var body: some View {
        WegaCard(padded: false) {
            WegaCardHeader(icon: icon, title: section.title, count: section.rows.isEmpty ? nil : section.rows.count)
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
                ForEach(section.rows.indices, id: \.self) { index in
                    let row = section.rows[index]
                    if let header = row.groupHeader {
                        Text(header)
                            .font(.wega(.callout, weight: .semibold))
                            .padding(.horizontal, WegaLayout.cardPadding)
                            .padding(.top, 10)
                    }
                    CleanupFindingRow(
                        row: row, canRemove: canRemove, copiedCommand: copiedCommand,
                        onRemove: onRemove, onCopy: onCopy
                    )
                    if index < section.rows.count - 1 {
                        Divider().opacity(0.3)
                    }
                }
            }
            .padding(.vertical, 6)
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

/// Status, path, detail and size, then the row's one control: a removal that opens the
/// confirmation sheet, a copy button, or a note in its place.
private struct CleanupFindingRow: View {
    let row: CleanupPresentation.Row
    let canRemove: Bool
    let copiedCommand: String?
    let onRemove: (_ findingID: String) -> Void
    let onCopy: (String) -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
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
                }
            }
        }
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
