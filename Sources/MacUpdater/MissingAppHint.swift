import SwiftUI

/// UXP-35 — "why isn't X here?": the Updates list only shows what Wega found an update for, so a
/// missing app is not proof that it is current. The hint leads to Inventory, which lists every app
/// with its own status.
struct MissingAppHint: View {
    let onOpenInventory: () -> Void

    var body: some View {
        Button(action: onOpenInventory) {
            Label(tr("Nie widzisz aplikacji? Brak na liście nie znaczy, że jest aktualna — sprawdź jej status w Spisie"),
                  systemImage: "magnifyingglass")
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .buttonStyle(.link)
        .font(.wega(.callout))
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
