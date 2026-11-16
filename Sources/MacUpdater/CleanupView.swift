import SwiftUI
import MacUpdaterCore

/// Placeholder destination until the cleanup report view lands.
struct CleanupView: View {
    let onWegaState: (WegaState) -> Void

    var body: some View {
        Text(tr("Porządki"))
            .font(.title2)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
