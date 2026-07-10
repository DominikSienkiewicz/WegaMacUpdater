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
    /// M3(d) — set when the agent had something to announce but has never been allowed to
    /// ask for permission. The window renders an explanation card; the system dialog waits.
    @Published private(set) var needsNotificationExplanation = false

    private var lastNotifiedCount = 0
    private var loop: Task<Void, Never>?

    private enum Keys {
        static let interval = "wega.menubar.interval"
        static let lastCheck = "wega.menubar.lastCheck"
        static let lastCount = "wega.menubar.lastCount"
        static let notificationAnswer = "wega.notifications.inAppAnswer"
    }

    /// What the user told Wega about notifications, persisted so a declined card never
    /// comes back. Only `.agreed` may spend the one-shot macOS dialog.
    private var inAppAnswer: NotificationPrompt.InAppAnswer {
        get {
            switch UserDefaults.standard.string(forKey: Keys.notificationAnswer) {
            case "agreed":   return .agreed
            case "declined": return .declined
            default:         return .unanswered
            }
        }
        set {
            let raw: String? = switch newValue {
            case .agreed:     "agreed"
            case .declined:   "declined"
            case .unanswered: nil
            }
            UserDefaults.standard.set(raw, forKey: Keys.notificationAnswer)
        }
    }

    private init() {
        let defaults = UserDefaults.standard
        interval = defaults.string(forKey: Keys.interval).flatMap(CheckInterval.init(rawValue:)) ?? .every6Hours
        updateCount = defaults.integer(forKey: Keys.lastCount)
        let stored = defaults.double(forKey: Keys.lastCheck)
        lastCheck = stored > 0 ? Date(timeIntervalSinceReferenceDate: stored) : nil
        lastNotifiedCount = updateCount
    }

    /// The user accepted the in-app explanation. Now — and only now — ask macOS.
    func agreeToNotifications() async {
        inAppAnswer = .agreed
        needsNotificationExplanation = false
        guard Bundle.main.bundleIdentifier != nil else { return }
        _ = try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .badge, .sound])
    }

    /// The user declined the card. Don't nag: no system dialog, and no card ever again.
    func declineNotifications() {
        inAppAnswer = .declined
        needsNotificationExplanation = false
    }

    private func systemNotificationStatus() async -> NotificationPrompt.SystemStatus {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral: return .authorized
        case .denied:                               return .denied
        case .notDetermined:                        return .notDetermined
        @unknown default:                           return .denied
        }
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

    /// M4 — the dock badge has exactly one owner: this agent. A scan run from the window
    /// reports its result here instead of leaving the badge showing yesterday's number.
    /// Also resets the notification watermark, so the next background check does not
    /// re-announce updates the user has just seen (or just installed).
    func reportWindowScan(count: Int, failedChecks: Int) {
        updateCount = count
        lastCheckFailed = count == 0 && failedChecks > 0
        lastCheck = Date()
        lastNotifiedCount = count
        persist()
        updateDockBadge()
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

    /// M3(d) — a background check never raises the macOS permission dialog. It either posts
    /// (already authorised), raises Wega's own explanation card, or stays quiet.
    private func postNotification(count: Int) {
        // UNUserNotificationCenter requires a bundled app; skip under `swift run`.
        guard Bundle.main.bundleIdentifier != nil else { return }
        let title = tr("Dostępne aktualizacje")
        let body = trf("Wega znalazła %@ aktualizacji do zainstalowania.", "\(count)")
        // Task inherits this @MainActor context, so the non-Sendable center never
        // crosses an actor boundary.
        Task {
            switch NotificationPrompt.decide(system: await systemNotificationStatus(), inApp: inAppAnswer) {
            case .stayQuiet:
                return
            case .explainInApp:
                needsNotificationExplanation = true
            case .askSystem:
                // The user agreed in the card but the dialog has not run yet; it belongs to
                // `agreeToNotifications()`, on a user gesture — not to this timer.
                needsNotificationExplanation = true
            case .post:
                let center = UNUserNotificationCenter.current()
                let content = UNMutableNotificationContent()
                content.title = title
                content.body = body
                content.badge = NSNumber(value: count)
                let request = UNNotificationRequest(identifier: "wega.updates", content: content, trigger: nil)
                try? await center.add(request)
            }
        }
    }
}
