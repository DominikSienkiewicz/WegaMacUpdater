import Foundation

/// Marks a streamed log line with the package it came from.
///
/// The log panel is one flat list, and a run now feeds it from several processes at once.
/// Chronological order is still the honest order — but without a source a reader cannot tell
/// which of three concurrent downloads a `==> Downloading` line belongs to.
///
/// The prefix is a package token, not interface text: it is never translated.
public enum UpgradeLogPrefix {
    public static func line(_ line: String, from source: String) -> String {
        source.isEmpty ? line : "[\(source)] \(line)"
    }

    public static func lines(_ lines: [String], from source: String) -> [String] {
        guard !source.isEmpty else { return lines }
        return lines.map { "[\(source)] \($0)" }
    }
}
