import SwiftUI
import MacUpdaterCore

/// Shown when apps refused to quit. Force quitting is opt-in: no button is the default
/// action, and Esc cancels the whole uninstall.
struct UninstallForceQuitSheet: View {
    let apps: [ApplicationInfo]
    let onChoice: (UninstallForceQuitChoice) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(tr("Te aplikacje nie chcą się zamknąć"))
                .font(.wega(.title3, weight: .semibold))
            VStack(alignment: .leading, spacing: 4) {
                ForEach(apps) { app in
                    Text(app.name).font(.wega(.callout, weight: .medium))
                }
            }
            Text(tr("Wymuszenie zamknięcia może spowodować utratę niezapisanej pracy."))
                .font(.wega(.subheadline))
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button(tr("Anuluj"), role: .cancel) { onChoice(.cancel) }
                    .keyboardShortcut(.cancelAction)
                Button(tr("Pomiń te aplikacje")) { onChoice(.skip) }
                Button(tr("Wymuś zamknięcie"), role: .destructive) { onChoice(.forceQuit) }
            }
        }
        .padding(22)
        .frame(width: 420)
    }
}
