import SwiftUI
import MacUpdaterCore

/// Confirms one Cleanup removal: the `~` path(s), size, reason, the exact action and its risk.
///
/// The first request never acknowledges use. When the remover answers that processes use the
/// item, the sheet lists them (name, PID, arguments held in memory) and only a second
/// confirmation with the separate toggle on sends an acknowledged request. A successful removal
/// closes the sheet; any other answer is explained here.
struct CleanupConfirmationSheet: View {
    @ObservedObject var store: CleanupStore
    let finding: CleanupFinding
    let onClose: () -> Void

    @State private var submitted = false
    @State private var acknowledged = false

    private var state: CleanupPresentation.SheetState {
        CleanupPresentation.sheetState(submitted: submitted, phase: store.phase, outcome: store.lastOutcome)
    }

    var body: some View {
        let confirmation = CleanupPresentation.confirmation(for: finding, home: store.home)
        let state = state
        VStack(alignment: .leading, spacing: 14) {
            Text(tr("Potwierdź usunięcie"))
                .font(.wega(.title3, weight: .bold))
            field(tr("Ścieżka")) {
                ForEach(confirmation.paths.indices, id: \.self) { index in
                    Text(confirmation.paths[index])
                        .font(.wega(.callout, monospaced: true))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            field(tr("Rozmiar")) { Text(confirmation.sizeText).font(.wega(.callout)) }
            field(tr("Powód")) { Text(confirmation.reason).font(.wega(.callout)) }
            field(tr("Działanie")) {
                Text(confirmation.action)
                    .font(.wega(.callout, monospaced: true))
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.wegaRecessedSurface, in: RoundedRectangle(cornerRadius: 7))
            }
            Text(confirmation.risk)
                .font(.wega(.callout, weight: .semibold))
                .foregroundStyle(finding.risk == .high ? Color.wegaDanger : Color.secondary)
            if !confirmation.processes.isEmpty {
                field(tr("Używane podczas skanu przez")) { processList(confirmation.processes) }
            }
            if case .needsAcknowledgement(let processes) = state {
                acknowledgement(processes)
            }
            if case .refused(let message) = state {
                ErrorBanner(message: message)
            }
            if state == .working {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(tr("Usuwam…")).font(.wega(.callout)).foregroundStyle(.secondary)
                }
            }
            buttons(state: state, confirmTitle: confirmation.confirmTitle)
        }
        .padding(24)
        .frame(width: 520)
        .interactiveDismissDisabled(state == .working)
        .onChange(of: state) { _, new in
            if new == .done { onClose() }
            if case .needsAcknowledgement = new { acknowledged = false }
        }
    }

    private func field<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.wega(.subheadline, weight: .semibold))
                .foregroundStyle(.tertiary)
            content()
        }
    }

    private func processList(_ lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(lines.indices, id: \.self) { index in
                Text(lines[index])
                    .font(.wega(.subheadline, monospaced: true))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func acknowledgement(_ processes: [CleanupProcess]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(tr("Ten element jest teraz używany przez:"))
                .font(.wega(.callout, weight: .semibold))
                .foregroundStyle(Color.wegaDanger)
            processList(processes.map(CleanupPresentation.processLine))
            Toggle(tr("Rozumiem, że te procesy mogą przestać działać poprawnie. Usuń mimo to."), isOn: $acknowledged)
                .toggleStyle(.checkbox)
                .font(.wega(.callout))
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.wegaDanger.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    private func buttons(state: CleanupPresentation.SheetState, confirmTitle: String) -> some View {
        HStack {
            Spacer()
            if case .refused = state {
                Button(tr("Zamknij")) { onClose() }
                    .keyboardShortcut(.cancelAction)
            } else {
                Button(tr("Anuluj")) { onClose() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(state == .working)
                Button(confirmTitle) { confirm(state) }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.wegaHoneyFill)
                    .foregroundStyle(Color.wegaInk)
                    .disabled(!CleanupPresentation.canConfirm(state, phase: store.phase, acknowledged: acknowledged))
            }
        }
    }

    private func confirm(_ state: CleanupPresentation.SheetState) {
        store.remove(CleanupPresentation.removalIntent(for: finding, state: state, acknowledged: acknowledged))
        submitted = true
    }
}
