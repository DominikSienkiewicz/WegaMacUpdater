import Foundation

/// How often the menu-bar agent checks for updates in the background.
public enum CheckInterval: String, CaseIterable, Codable, Sendable, Identifiable {
    case off
    case hourly
    case every6Hours
    case daily

    public var id: String { rawValue }

    /// Polling period in seconds, or `nil` when automatic checks are disabled.
    public var seconds: TimeInterval? {
        switch self {
        case .off:          return nil
        case .hourly:       return 60 * 60
        case .every6Hours:  return 6 * 60 * 60
        case .daily:        return 24 * 60 * 60
        }
    }

    public var isAutomatic: Bool { seconds != nil }
}

/// Pure scheduling decisions for the background checker — easy to unit-test without
/// timers or a clock.
public enum UpdateSchedule {
    /// Whether a check is due. A never-checked agent (`lastCheck == nil`) is always due.
    public static func shouldCheck(lastCheck: Date?, interval: TimeInterval, now: Date) -> Bool {
        guard interval > 0 else { return false }
        guard let lastCheck else { return true }
        return now.timeIntervalSince(lastCheck) >= interval
    }

    /// The earliest moment the next check should run.
    public static func nextCheckDate(lastCheck: Date?, interval: TimeInterval, now: Date) -> Date {
        guard interval > 0 else { return .distantFuture }
        guard let lastCheck else { return now }
        return max(now, lastCheck.addingTimeInterval(interval))
    }

    /// Seconds to wait before the next check (never negative).
    public static func secondsUntilNextCheck(lastCheck: Date?, interval: TimeInterval, now: Date) -> TimeInterval {
        guard interval > 0 else { return .infinity }
        return max(0, nextCheckDate(lastCheck: lastCheck, interval: interval, now: now).timeIntervalSince(now))
    }
}
