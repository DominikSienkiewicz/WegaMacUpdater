import SwiftUI
import AppKit
import MacUpdaterCore

/// The menu-bar item itself: a box icon, badged with the update count when > 0.
struct MenuBarLabel: View {
    let count: Int
    let isChecking: Bool

    var body: some View {
        Group {
            if count > 0 {
                Label("\(count)", systemImage: "shippingbox.fill")
            } else {
                Image(systemName: "shippingbox")
            }
        }
        .accessibilityLabel(count > 0
            ? trp("%@ aktualizacji dostępnych", count)
            : tr("Wszystko aktualne"))
    }
}

/// The dropdown shown when the menu-bar item is clicked (standard `.menu` style).
struct MenuBarContent: View {
    @ObservedObject var agent: MenuBarAgent
    @Environment(\.openWindow) private var openWindow

    /// UX-11g — how many app names the dropdown lists before collapsing the rest into a
    /// „i jeszcze N" summary, so a large backlog can't turn the menu into a wall of rows.
    /// The full list is one click away behind „Otwórz Wega".
    private static let maxListedApps = 10

    var body: some View {
        statusSection

        Divider()

        Button(agent.isChecking ? tr("Sprawdzam…") : tr("Sprawdź teraz")) {
            Task { await agent.checkNow() }
        }
        .disabled(agent.isChecking)

        Button(tr("Otwórz Wega")) {
            openWindow(id: "main")
            NSApplication.shared.activate(ignoringOtherApps: true)
        }

        Divider()

        Picker(tr("Sprawdzaj automatycznie"), selection: $agent.interval) {
            ForEach(CheckInterval.allCases) { interval in
                Text(intervalLabel(interval)).tag(interval)
            }
        }

        Divider()

        Button(tr("Zakończ Wega")) {
            requestQuit()
        }
    }

    /// The informational top of the menu: the one-line status, the last-check time, and —
    /// since UX-11g — the names of the apps that actually have updates. Naming them is the
    /// whole point of the card: the dropdown used to say only *how many* updates there were,
    /// never *which* apps. The names come from the last check under the same ignore/pin
    /// rules as the badge, so the list can never disagree with the count above it.
    @ViewBuilder private var statusSection: some View {
        Text(statusText)

        if let last = agent.lastCheck {
            Text(trf("Sprawdzono %@", last.formatted(date: .omitted, time: .shortened)))
        }

        let names = agent.outdatedNames
        if !names.isEmpty {
            Divider()
            ForEach(Array(names.prefix(Self.maxListedApps).enumerated()), id: \.offset) { _, name in
                Text(name)
            }
            if names.count > Self.maxListedApps {
                Text(trp("i jeszcze %@ aplikacji", names.count - Self.maxListedApps))
            }
        }
    }

    /// REL-06 — this used to be a bare `terminate(nil)`, which killed a running `brew
    /// upgrade --cask` from a menu click. The decision now belongs to one place,
    /// `AppDelegate.applicationShouldTerminate`, which `terminate(_:)` runs: keeping a
    /// second copy of the policy here is how the two would drift apart.
    ///
    /// What the menu still has to do itself is check `MutationGuard.shared.isMutating`
    /// (which reads `UpgradeMutex.isBusy` among others): the confirmation is a *window*,
    /// and the menu-bar extra is not a regular app activation — without bringing Wega
    /// forward the alert opens behind whatever the user was looking at and the click
    /// merely seems to have done nothing.
    private func requestQuit() {
        if MutationGuard.shared.isMutating {
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
        NSApplication.shared.terminate(nil)
    }

    private var statusText: String {
        if agent.isChecking { return tr("Sprawdzam aktualizacje…") }
        if agent.updateCount > 0 { return trp("%@ aktualizacji dostępnych", agent.updateCount) }
        if agent.lastCheckFailed { return tr("Nie udało się sprawdzić") }
        if agent.lastCheck == nil { return tr("Jeszcze nie sprawdzano") }
        return tr("Wszystko aktualne")
    }

    private func intervalLabel(_ interval: CheckInterval) -> String {
        switch interval {
        case .off:         return tr("Wyłączone")
        case .hourly:      return tr("Co godzinę")
        case .every6Hours: return tr("Co 6 godzin")
        case .daily:       return tr("Codziennie")
        }
    }
}
