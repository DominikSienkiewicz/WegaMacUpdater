import Foundation

/// Pure formatters for the Logs view, kept out of the SwiftUI layer so they're unit
/// tested. They turn the scan's results into human lines: what was found, a per-source
/// breakdown, the real brew error reason (not just an exit code), and per-checker debug
/// lines. Messages are plain Polish to match the existing log style (`runCheck` etc.).
public enum ScanLog {

    // MARK: Source labels

    static func sourceLabel(_ kind: OutdatedItem.Kind) -> String {
        switch kind {
        case .formula:  return "Homebrew formuła"
        case .cask:     return "Homebrew cask"
        case .appStore: return "Mac App Store"
        case .npm:      return "npm"
        }
    }

    static func sourceLabel(_ source: ManualOutdatedApp.UpdateSource) -> String {
        switch source {
        case .cask:        return "Homebrew cask"
        case .mas:         return "Mac App Store"
        case .sparkle:     return "Sparkle"
        case .jetbrains:   return "JetBrains"
        case .github:      return "GitHub"
        case .synology:    return "Synology"
        case .antigravity: return "Antigravity"
        case .parallels:   return "Parallels"
        case .googleDrive: return "Google Drive"
        case .chatgpt:     return "ChatGPT"
        case .postman:     return "Postman (feed)"
        case .discord:     return "Discord"
        case .signal:      return "Signal"
        case .chrome:      return "Google Chrome"
        }
    }

    // MARK: 1. What was found

    /// One line per found update: `"Docker 4.78.0 → 4.79.0 · Homebrew cask"`. Tracked
    /// items first (in their list order), then the manual ones.
    public static func foundLines(items: [OutdatedItem], manual: [ManualOutdatedApp]) -> [String] {
        items.map { "\($0.name) \($0.from ?? "?") → \($0.to ?? "?") · \(sourceLabel($0.kind))" }
        + manual.map { "\($0.name) \($0.installedVersion ?? "?") → \($0.availableVersion ?? "?") · \(sourceLabel($0.source))" }
    }

    // MARK: 2. Per-source breakdown

    /// `"formuły: 1, caski: 1, MAS: 0, npm: 0, ręczne: 2"` — counts behind the headline total.
    public static func breakdown(items: [OutdatedItem], manual: [ManualOutdatedApp]) -> String {
        let f = items.filter { $0.kind == .formula }.count
        let c = items.filter { $0.kind == .cask }.count
        let m = items.filter { $0.kind == .appStore }.count
        let n = items.filter { $0.kind == .npm }.count
        return "formuły: \(f), caski: \(c), MAS: \(m), npm: \(n), ręczne: \(manual.count)"
    }

    // MARK: 3. Real failure reason

    /// The brew failure line (`Error: …`) from streamed install/upgrade output, so the
    /// persistent log records *why* it failed — not just the exit code.
    public static func brewErrorReason(from lines: [String]) -> String? {
        lines.last { $0.contains("Error:") }?.trimmingCharacters(in: .whitespaces)
    }

    // MARK: 4. Per-checker debug

    /// Debug line for one manual-checker outcome that actually engaged a source, with
    /// timing. `nil` for `.notApplicable` (no work done) and for `.unavailable` / `.failed`
    /// (already logged at warning/error level — no point duplicating them here).
    public static func checkerDebugLine(source: String, app: String, result: ManualCheckResult, millis: Int) -> String? {
        switch result {
        case .upToDate:
            return "\(source) · \(app): aktualna (\(millis) ms)"
        case .outdated(let item):
            return "\(source) · \(app): \(item.installedVersion ?? "?")→\(item.availableVersion ?? "?") (\(millis) ms)"
        case .notApplicable, .unavailable, .failed:
            return nil
        }
    }
}
