import SwiftUI
import MacUpdaterCore

/// LT-01 — the „Cofnij aktualizacje” destination.
///
/// Undo used to render at the bottom of the Updates list, below every package section, the
/// manual-update groups and the restart prompt. It is an action on updates that already
/// happened, and it was competing for attention with the list of updates that have not —
/// visible only after scrolling past everything else. It gets its own destination, in the
/// sidebar's *Narzędzia* section next to the other repair tools.
///
/// The list itself is still `UndoUpdateSection`; only its confirmation and its home moved.
/// Unlike the other destinations this one takes no `onWegaState`: the window already sets the
/// mascot from the selection, and the one thing worth saying here — that an undo landed — is
/// emitted by `ScanStore` itself when it completes.
struct RollbackView: View {
    @EnvironmentObject private var scan: ScanStore

    /// The update the user has asked to take back, pending confirmation. Purely transient:
    /// no background task writes to it, so it may die with the view tree.
    @State private var undoTarget: UndoableUpdate? = nil
    @State private var showUndoConfirmation = false

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .confirmationDialog(
                undoTarget.map { trf("Cofnąć aktualizację: %@?", "\($0.token)") } ?? tr("Cofnąć aktualizację?"),
                isPresented: $showUndoConfirmation,
                titleVisibility: .visible
            ) {
                if let undoTarget {
                    Button(trf("Przywróć wersję %@", "\(undoTarget.restoredVersion ?? "—")")) {
                        self.undoTarget = nil
                        Task { await scan.undoUpdate(undoTarget) }
                    }
                }
                Button(tr("Anuluj"), role: .cancel) { undoTarget = nil }
            } message: {
                if let undoTarget {
                    Text(trf("%@ zostanie zastąpiona kopią sprzed aktualizacji, a przywrócona wersja zostanie przypięta. Kopia jest trzymana do %@.",
                             "\(undoTarget.token)",
                             "\(undoTarget.expiresAt.formatted(date: .abbreviated, time: .omitted))"))
                }
            }
            // The retention sweep can drop a snapshot between the last refresh and the
            // moment this destination is opened, so the list is re-read on arrival rather
            // than trusted from whenever the Updates tab last looked.
            .onAppear { scan.refreshUndoableUpdates() }
    }

    @ViewBuilder
    private var content: some View {
        if scan.undoableUpdates.isEmpty {
            EmptyHero(
                pose: .sleep,
                title: tr("Nic do cofnięcia"),
                message: tr("Po każdej aktualizacji Wega trzyma kopię poprzedniej wersji przez 7 dni — przez ten czas znajdziesz ją tutaj. Teraz żadna kopia nie czeka."),
                compact: true
            )
        } else {
            ScrollView {
                LazyVStack(spacing: 12) {
                    UndoUpdateSection(
                        items: scan.undoableUpdates,
                        busyToken: scan.undoBusy
                    ) { undoable in
                        undoTarget = undoable
                        showUndoConfirmation = true
                    }
                }
                .padding(16)
            }
            .scrollEdgeEffectStyle(.soft, for: .top)
        }
    }
}
