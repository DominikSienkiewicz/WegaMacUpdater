import SwiftUI
import AppKit
import MacUpdaterCore

/// The menu-bar item itself: a box icon, badged with the update count when > 0.
struct MenuBarLabel: View {
    let count: Int
    let isChecking: Bool

    var body: some View {
        if count > 0 {
            Label("\(count)", systemImage: "shippingbox.fill")
        } else {
            Image(systemName: "shippingbox")
        }
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
            NSApplication.shared.terminate(nil)
        }
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
