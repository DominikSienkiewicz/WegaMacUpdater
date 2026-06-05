import Foundation
import AppKit
import UserNotifications
import MacUpdaterCore

/// Drives the menu-bar presence: periodic read-only update checks, the badge count,
/// and notifications. Pure scheduling lives in `MacUpdaterCore.UpdateSchedule`; the
/// read-only scan in `MacUpdaterCore.MenuBarUpdateChecker`.
@MainActor
final class MenuBarAgent: ObservableObject {
    static let shared = MenuBarAgent()

    @Published var interval: CheckInterval {
        didSet {
            UserDefaults.standard.set(interval.rawValue, forKey: Keys.interval)
        }
    }
    @Published private(set) var updateCount: Int
    @Published private(set) var isChecking = false
    @Published private(set) var lastCheck: Date?
    /// True when the most recent check found nothing but at least one source failed.
    @Published private(set) var lastCheckFailed = false

    private var lastNotifiedCount = 0
    private var loop: Task<Void, Never>?

    private enum Keys {
        static let interval = "wega.menubar.interval"
        static let lastCheck = "wega.menubar.lastCheck"
        static let lastCount = "wega.menubar.lastCount"
    }

    private init() {
        let defaults = UserDefaults.standard
        interval = defaults.string(forKey: Keys.interval).flatMap(CheckInterval.init(rawValue:)) ?? .every6Hours
        updateCount = defaults.integer(forKey: Keys.lastCount)
        let stored = defaults.double(forKey: Keys.lastCheck)
        lastCheck = stored > 0 ? Date(timeIntervalSinceReferenceDate: stored) : nil
        lastNotifiedCount = updateCount
    }

    /// Starts the background polling loop (idempotent).
    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                if let self, self.isDue() {
                    await self.performCheck()
                }
                try? await Task.sleep(for: .seconds(300))
            }
        }
    }

    private func isDue() -> Bool {
        guard let seconds = interval.seconds else { return false }
        return UpdateSchedule.shouldCheck(lastCheck: lastCheck, interval: seconds, now: Date())
    }

    /// Manual "check now" from the menu.
    func checkNow() async {
        await performCheck()
    }

    private func performCheck() async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }

        let policies = UpdatePolicyStore.shared.policiesMap
        let result = await MenuBarUpdateChecker().availableUpdateCount(policies: policies)

        updateCount = result.total
        lastCheckFailed = result.total == 0 && result.failedChecks > 0
        lastCheck = Date()
        persist()
        updateDockBadge()

        // Notify only when something new appeared (avoid re-nagging every interval).
        if result.total > 0 && result.total != lastNotifiedCount {
            lastNotifiedCount = result.total
            postNotification(count: result.total)
        } else if result.total == 0 {
            lastNotifiedCount = 0
        }
    }

    private func persist() {
        let defaults = UserDefaults.standard
        defaults.set(updateCount, forKey: Keys.lastCount)
        defaults.set(lastCheck?.timeIntervalSinceReferenceDate ?? 0, forKey: Keys.lastCheck)
    }

    private func updateDockBadge() {
        NSApp.dockTile.badgeLabel = updateCount > 0 ? "\(updateCount)" : nil
    }

    // MARK: - Notifications

    private func postNotification(count: Int) {
        // UNUserNotificationCenter requires a bundled app; skip under `swift run`.
        guard Bundle.main.bundleIdentifier != nil else { return }
        let title = tr("Dostępne aktualizacje")
        let body = trf("Wega znalazła %@ aktualizacji do zainstalowania.", "\(count)")
        // Task inherits this @MainActor context, so the non-Sendable center never
        // crosses an actor boundary.
        Task {
            let center = UNUserNotificationCenter.current()
            guard (try? await center.requestAuthorization(options: [.alert, .badge, .sound])) == true else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.badge = NSNumber(value: count)
            let request = UNNotificationRequest(identifier: "wega.updates", content: content, trigger: nil)
            try? await center.add(request)
        }
    }
}
