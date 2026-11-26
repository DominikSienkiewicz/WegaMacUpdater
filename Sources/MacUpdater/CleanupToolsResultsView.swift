import SwiftUI
import MacUpdaterCore

struct CleanupToolsResultsView: View {
    let review: CleanupToolsReview
    let searching: Bool
    let actions: CleanupFindingActions
    @State private var expandedCards: Set<String> = []
    @State private var showsChecked = false
    @State private var showsScope = false

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                if !review.warnings.isEmpty {
                    WegaCallout(.info, title: tr("Uwagi do skanu"), message: review.warnings.first,
                                fullMessage: review.warnings.joined(separator: "\n"))
                }
                if let reminder = review.mapAccessReminder {
                    WegaCallout(.info, title: tr("Pełny dostęp do dysku"), message: reminder, fullMessage: reminder)
                }
                if let message = review.inspectedToolMessage {
                    Text(message).font(.wega(.callout)).textSelection(.enabled)
                }
                ForEach(review.cards) { card in
                    CleanupToolCard(card: card, searching: searching, actions: actions, expanded: Binding(
                        get: { expandedCards.contains(card.id) },
                        set: { open in
                            if open { expandedCards.insert(card.id) } else { expandedCards.remove(card.id) }
                        }
                    ))
                }
                if searching {
                    if review.cards.isEmpty {
                        Text(tr("Nic w raporcie nie pasuje do wyszukiwania."))
                            .foregroundStyle(.secondary).frame(maxWidth: .infinity).padding()
                    }
                } else {
                    areas(review.checked, title: review.checkedTitle, expanded: $showsChecked)
                    areas(review.scope, title: tr("Zakres skanu"), expanded: $showsScope)
                }
            }
            .padding(16)
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
    }

    @ViewBuilder
    private func areas(_ areas: [CleanupToolsReview.Area], title: String, expanded: Binding<Bool>) -> some View {
        if !areas.isEmpty {
            WegaCard {
                WegaDisclosure(isExpanded: expanded) {
                    ForEach(areas) { area in
                        Divider().padding(.vertical, 6)
                        Label(area.section.title, systemImage: area.section.kind.icon)
                            .font(.wega(.callout, weight: .semibold))
                        ForEach(area.section.notes.filter { !review.warnings.contains($0) && $0 != review.mapAccessReminder }, id: \.self) { note in
                            Text(note).font(.wega(.subheadline)).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        ForEach(area.quiet.indices, id: \.self) { index in
                            CleanupQuietItem(item: area.quiet[index], shellOrder: review.shellOrder, actions: actions)
                        }
                    }
                } label: {
                    Text(title).font(.wega(.callout, weight: .semibold)).padding(.vertical, 6)
                }
                .padding(8)
            }
        }
    }
}

struct CleanupToolCard: View {
    let card: CleanupToolsReview.Card
    let searching: Bool
    let actions: CleanupFindingActions
    @Binding var expanded: Bool

    var body: some View {
        WegaCard(padded: false) {
            WegaCardHeader(icon: card.kind.icon, title: card.title, caption: card.subtitle) {
                if let row = card.quickAction { CleanupFindingButton(row: row, actions: actions) }
            }
            if searching {
                details
            } else {
                WegaDisclosure(isExpanded: $expanded, leadingInset: WegaLayout.cardPadding) {
                    details
                } label: {
                    Text(expanded ? tr("Ukryj szczegóły") : tr("Pokaż szczegóły"))
                        .font(.wega(.subheadline)).padding(.vertical, 8)
                        .accessibilityLabel(trf("Szczegóły: %@", card.title))
                }
            }
            if card.group.checkShellOrder, let name = card.group.name {
                VStack(alignment: .leading, spacing: 6) {
                    if expanded || searching {
                        Text(tr("Wega jeszcze nie sprawdziła, którą kopię wybiera Terminal."))
                            .font(.wega(.subheadline)).foregroundStyle(.secondary)
                    }
                    Button { actions.onCheckPath(name) } label: {
                        Label(tr("Sprawdź, którą kopię wybiera Terminal"), systemImage: "magnifyingglass")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.wegaHoneyFill).foregroundStyle(Color.wegaInk)
                    .controlSize(.small)
                    .disabled(!actions.canAct)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, WegaLayout.cardPadding).padding(.bottom, 10)
            }
        }
    }

    private var details: some View {
        ForEach(card.group.rows.indices, id: \.self) { index in
            let row = card.group.rows[index]
            if index > 0 { Divider().opacity(0.3) }
            CleanupFindingRow(row: row, actions: actions, actionInHeader: card.quickAction?.button == row.button,
                              approximateOrder: card.approximateOrder, firstInShell: card.firstInShell)
        }
    }
}

private struct CleanupQuietItem: View {
    let item: CleanupPresentation.QuietItem
    let shellOrder: [String: Int]
    let actions: CleanupFindingActions
    @State private var expanded = false

    var body: some View {
        switch item {
        case .tool(let group):
            rows(group)
        case .origin(let line):
            WegaDisclosure(isExpanded: $expanded) {
                ForEach(line.tools.indices, id: \.self) { rows(line.tools[$0]) }
            } label: {
                VStack(alignment: .leading) {
                    Text(line.title)
                    if let companions = line.companions { Text(companions).foregroundStyle(.secondary) }
                }
                .font(.wega(.subheadline))
            }
        }
    }

    private func rows(_ group: CleanupPresentation.ToolGroup) -> some View {
        let first = CleanupToolsReview.firstCopy(in: group.workingCopies, order: shellOrder)
        return VStack(alignment: .leading) {
            if let name = group.name { Text(name).font(.wega(.callout, weight: .semibold)) }
            ForEach(group.rows.indices, id: \.self) { index in
                CleanupFindingRow(row: group.rows[index], actions: actions, actionInHeader: false, approximateOrder: shellOrder.isEmpty, firstInShell: first?.id)
            }
        }
    }
}
