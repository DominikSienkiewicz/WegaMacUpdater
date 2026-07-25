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
            ? trf("%@ aktualizacji dostępnych", "\(count)")
            : tr("Wszystko aktualne"))
    }
}

/// The dropdown shown when the menu-bar item is clicked (standard `.menu` style).
struct MenuBarContent: View {
    @ObservedObject var agent: MenuBarAgent
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(statusText)

        if let last = agent.lastCheck {
            Text(trf("Sprawdzono %@", last.formatted(date: .omitted, time: .shortened)))
        }

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
        if agent.updateCount > 0 { return trf("%@ aktualizacji dostępnych", "\(agent.updateCount)") }
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
