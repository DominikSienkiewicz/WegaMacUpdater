import SwiftUI
import MacUpdaterCore

/// LT-01 — the one question every „Cofnij” asks before anything is restored, on the „Cofnij
/// aktualizacje” screen and in the after-update summary alike. It names the app, says the
/// restored version will be pinned and until when the copy is kept, and adds the scope notice
/// (Docker's copy holds Docker.app only). Only its „Przywróć wersję” starts `undoUpdate`.
///
/// The screen that asks owns `target` and `isPresented`, and reports `isPresented` to
/// `.wegaAttention` itself.
struct UndoConfirmation: ViewModifier {
    @EnvironmentObject private var scan: ScanStore
    @Binding var target: UndoableUpdate?
    @Binding var isPresented: Bool

    init(target: Binding<UndoableUpdate?>, isPresented: Binding<Bool>) {
        _target = target
        _isPresented = isPresented
    }

    func body(content: Content) -> some View {
        content
            .confirmationDialog(
                target.map { trf("Cofnąć aktualizację: %@?", "\(CaskDisplayName.name(token: $0.token, appPath: URL(fileURLWithPath: $0.appPath)))") } ?? tr("Cofnąć aktualizację?"),
                isPresented: $isPresented,
                titleVisibility: .visible
            ) {
                if let target {
                    Button(trf("Przywróć wersję %@", "\(target.restoredVersion ?? "—")")) {
                        self.target = nil
                        Task { await scan.undoUpdate(target) }
                    }
                }
                Button(tr("Anuluj"), role: .cancel) { target = nil }
            } message: {
                if let target {
                    Text(Self.message(for: target))
                }
            }
    }

    static func message(for update: UndoableUpdate) -> String {
        let restoration = trf(
            "%@ zostanie zastąpiona kopią sprzed aktualizacji, a przywrócona wersja zostanie przypięta. Kopia jest trzymana do %@.",
            update.token,
            update.expiresAt.formatted(date: .abbreviated, time: .omitted)
        )
        guard let notice = RollbackScopePresentation.notice(for: update.rollbackScope) else { return restoration }
        return "\(restoration)\n\n\(notice.localizedDescription)"
    }
}

extension View {
    /// Asks `UndoConfirmation`'s question about `target` while `isPresented`.
    func undoConfirmation(target: Binding<UndoableUpdate?>, isPresented: Binding<Bool>) -> some View {
        modifier(UndoConfirmation(target: target, isPresented: isPresented))
    }
}
