import SwiftUI

/// Marks the update row open in the inspector: a lavender fill, an ink outline and a ledge below it.
/// The surface is inset so the outline and the ledge stay inside the row and the card's clip keeps them.
struct QueueRowSelectionSurface: ViewModifier {
    let isActive: Bool

    func body(content: Content) -> some View {
        content.background {
            if isActive {
                surface
                    .padding(.horizontal, 4)
                    .padding(.top, 2)
                    .padding(.bottom, 2 + WegaLayout.queueRowLedge)
            }
        }
    }

    private var surface: some View {
        let shape = RoundedRectangle(cornerRadius: WegaLayout.queueRowRadius, style: .continuous)
        return ZStack {
            shape
                .fill(Color.wegaSelectionLedge)
                .offset(y: WegaLayout.queueRowLedge)
            shape.fill(Color.wegaSelectionFill)
            shape.strokeBorder(Color.wegaSelectionOutline, lineWidth: WegaLayout.queueRowOutline)
        }
    }
}

extension View {
    func queueRowSelection(_ isActive: Bool) -> some View {
        modifier(QueueRowSelectionSurface(isActive: isActive))
    }
}
