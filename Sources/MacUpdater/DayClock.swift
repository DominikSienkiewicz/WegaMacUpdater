import AppKit
import Combine
import Foundation

/// UXP-17 — "now" for the lines that name a day („dziś”, „wczoraj”, „jutro”).
///
/// A view works such a line out when it is drawn, and nothing draws the menu-bar menu or Wega's
/// card again at midnight: a check at 23:55 still read „Sprawdzono 23:55” the next morning. The
/// clock tells its observers to redraw when macOS says the day changed, the clock was set or the
/// Mac woke. `now` reads the time when asked, so a redraw for any other reason is current too.
///
/// Only the menu and the card observe it. `MenuBarAgent` drives the menu-bar label, and a change
/// there rebuilds the whole App body.
@MainActor
final class DayClock: ObservableObject {
    /// One notification that may move the day.
    struct Source {
        let center: NotificationCenter
        let name: Notification.Name
    }

    static let shared = DayClock()

    /// Where macOS announces a day change, a clock change and a wake from sleep.
    static var liveSources: [Source] {
        [
            Source(center: .default, name: .NSCalendarDayChanged),
            Source(center: .default, name: .NSSystemClockDidChange),
            Source(center: NSWorkspace.shared.notificationCenter, name: NSWorkspace.didWakeNotification),
        ]
    }

    private let currentDate: () -> Date
    private var subscriptions: [AnyCancellable] = []

    var now: Date { currentDate() }

    init(sources: [Source] = DayClock.liveSources, now currentDate: @escaping () -> Date = Date.init) {
        self.currentDate = currentDate
        // The system may post these off the main thread; observers redraw on it.
        subscriptions = sources.map { source in
            source.center.publisher(for: source.name)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    MainActor.assumeIsolated { self?.objectWillChange.send() }
                }
        }
    }
}
