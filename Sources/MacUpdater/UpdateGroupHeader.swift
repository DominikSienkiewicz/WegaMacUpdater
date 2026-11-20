import SwiftUI

/// The C2 header of an Updates group card: a coloured dot, the title in monospaced capitals
/// (numbered `01 · …` in urgency grouping), the count and an optional note, with the group's
/// select-all circle ahead of the text block and an optional caption under it.
///
/// It mirrors `WegaCardHeader`'s layout, so the circle lands in the same column as the row
/// circles below, but it is Updates-only: the other screens keep the icon header.
struct UpdateGroupHeader: View {
    let title: String
    let tint: Color
    let ordinal: Int?
    let count: Int
    let note: String?
    let caption: String?
    let selection: SelectionCheckbox?

    init(title: String, tint: Color, ordinal: Int? = nil, count: Int, note: String? = nil,
         caption: String? = nil, selection: SelectionCheckbox? = nil) {
        self.title = title
        self.tint = tint
        self.ordinal = ordinal
        self.count = count
        self.note = note
        self.caption = caption
        self.selection = selection
    }

    /// The visible label: the zero-padded group number and the title, or the title alone.
    static func label(ordinal: Int?, title: String) -> String {
        guard let ordinal else { return title }
        return "\(String(format: "%02d", ordinal)) · \(title)"
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            if let selection {
                selection.padding(.trailing, WegaLayout.checkboxSpacing)
            }
            VStack(alignment: .leading, spacing: 4) {
                headerRow
                if let caption {
                    Text(caption)
                        .font(.wega(.subheadline))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.horizontal, WegaLayout.cardPadding)
        .padding(.vertical, 14)
        .overlay(alignment: .bottom) { Divider().opacity(0.3) }
    }

    private var headerRow: some View {
        HStack(spacing: 8) {
            Circle().fill(tint).frame(width: 8, height: 8)
                .accessibilityHidden(true)
            Text(Self.label(ordinal: ordinal, title: title))
                .font(.wega(.subheadline, weight: .semibold, monospaced: true))
                .tracking(0.8)
                .textCase(.uppercase)
                .accessibilityLabel(title)
                .accessibilityAddTraits(.isHeader)
            Text("\(count)")
                .font(.wega(.callout, monospaced: true))
                .foregroundStyle(.tertiary)
            if let note {
                Text(note).font(.wega(.subheadline)).foregroundStyle(.tertiary)
            }
            Spacer()
        }
    }
}
