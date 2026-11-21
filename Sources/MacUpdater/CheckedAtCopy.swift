import Foundation
import MacUpdaterCore

/// UXP-17 — how a moment is named next to "now": the time alone today, the day's name around
/// it, and the date beyond that. A bare "Sprawdzono 23:55" read the morning after looked like a
/// check from a few hours ago.
enum CheckedAtCopy {
    /// „Sprawdzono 21:14” today, „Sprawdzono wczoraj, 21:14” the day before, the date and time
    /// further back.
    static func checked(at date: Date, now: Date, calendar: Calendar = .current) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDate(date, inSameDayAs: now) { return trf("Sprawdzono %@", time) }
        if isDate(date, days: -1, from: now, calendar: calendar) { return trf("Sprawdzono wczoraj, %@", time) }
        return trf("Sprawdzono %@", date.formatted(date: .abbreviated, time: .shortened))
    }

    /// „dziś, 03:14”, „wczoraj, 03:14” or „jutro, 03:14”; the date and time for any other day.
    static func day(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDate(date, inSameDayAs: now) { return trf("dziś, %@", time) }
        if isDate(date, days: -1, from: now, calendar: calendar) { return trf("wczoraj, %@", time) }
        if isDate(date, days: 1, from: now, calendar: calendar) { return trf("jutro, %@", time) }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    private static func isDate(_ date: Date, days: Int, from now: Date, calendar: Calendar) -> Bool {
        guard let shifted = calendar.date(byAdding: .day, value: days, to: now) else { return false }
        return calendar.isDate(date, inSameDayAs: shifted)
    }
}
