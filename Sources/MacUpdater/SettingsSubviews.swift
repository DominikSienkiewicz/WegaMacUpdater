import SwiftUI
import MacUpdaterCore

// MARK: - Settings page

/// One Settings tab's scrolling column of cards.
///
/// It scrolls to the card the route asks for, once, and only when that card is on this page
/// (see `SettingsRoute.consumeFocus(on:)`). A card that is not drawn, such as Touch ID on a Mac
/// without a sensor, leaves the page at its top.
struct SettingsPage<Content: View>: View {
    let tab: SettingsTab
    @ObservedObject var route: SettingsRoute
    let content: Content

    init(tab: SettingsTab, route: SettingsRoute, @ViewBuilder content: () -> Content) {
        self.tab = tab
        self.route = route
        self.content = content()
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 14) { content }
                    .padding(16)
            }
            .onChange(of: route.focusedCard, initial: true) {
                guard let card = route.consumeFocus(on: tab) else { return }
                proxy.scrollTo(card, anchor: .top)
            }
        }
    }
}

// MARK: - Card hint

/// The line under a card's buttons where the card says what its last action needs or did, such
/// as "approve the helper in System Settings". The Settings window has no Wega to say it, so the
/// card does. Draws nothing until there is something to say.
struct SettingsCardHint: View {
    let text: String?

    var body: some View {
        if let text {
            Text(text)
                .font(.wega(.callout))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Sub-views

struct LabeledValue: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.wega(.footnote, weight: .semibold))
                .foregroundStyle(.tertiary)
                .textCase(.uppercase)
                .tracking(0.5)
            Text(value)
                .font(.wega(.callout, monospaced: true))
        }
    }
}

struct DiagRow: View {
    let label: String
    var required: Bool = false
    var value: String? = nil
    var active: Bool? = nil
    /// Overrides the dot's colour for rows whose *value* carries the verdict — a present
    /// value normally means "found", but "odmowa" is a present value that is not healthy.
    var healthy: Bool? = nil

    private var statusColor: Color {
        if let healthy { return healthy ? .wegaSuccess : Color.wegaDanger }
        if value != nil { return .wegaSuccess }
        if active == true { return .wegaSuccess }
        if required { return Color.wegaDanger }
        return .secondary
    }

    private var statusText: String {
        if let v = value { return v }
        if let a = active { return a ? tr("aktywny") : tr("nieaktywny") }
        return required ? tr("nie znaleziono") : tr("niedostępny")
    }

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(statusColor).frame(width: 8, height: 8)
            Text(label).font(.wega(.callout))
            Spacer()
            Text(statusText)
                .font(.wega(.subheadline, monospaced: true))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 5)
    }
}

struct LicenseRow: View {
    let name: String
    let license: String
    let url: URL

    var body: some View {
        HStack(spacing: 8) {
            Text(name).font(.wega(.callout, weight: .medium))
            Text(license)
                .font(.wega(.subheadline))
                .foregroundStyle(.secondary)
            Spacer()
            Link("↗", destination: url)
                .font(.wega(.callout))
        }
        .padding(.vertical, 5)
    }
}

/// Notatki jednego wydania, domyślnie zwinięte.
///
/// Wydzielone z `InfoView.selfUpdateNotes`, bo `WegaDisclosure` potrzebuje bindingu,
/// a `ForEach` nie może trzymać `@State` dla każdego elementu z osobna.
struct SelfUpdateNoteDisclosure: View {
    let note: ReleaseNote

    @State private var isExpanded = false

    var body: some View {
        WegaDisclosure(isExpanded: $isExpanded) {
            Text(note.body.isEmpty ? tr("Brak opublikowanych notatek") : note.body)
                .font(.wega(.subheadline))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        } label: {
            HStack(spacing: 6) {
                Text(note.version).font(.wega(.callout, weight: .medium))
                if let published = note.publishedAt {
                    Text(published, style: .date)
                        .font(.wega(.subheadline))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
