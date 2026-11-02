import Foundation

/// Recognises Homebrew 7's tap-trust warning in a brew log and names the taps it lists.
///
/// Homebrew stops loading formulae, casks and commands from a third-party tap the user has
/// not trusted, and prints the same remedy block in the output of most commands. Wega already
/// shows that output in the brew log panel, so the panel is where the user meets the warning —
/// and where Wega can offer the fix instead of asking them to copy commands into a terminal.
///
/// Tap names come from Homebrew's warning commands or its exact package-load refusal.
/// Names become command arguments, so options, placeholders and paths are rejected.
/// A refusal must name a fully-qualified package belonging to the tap it reports.
public enum TapTrustWarning {
    enum PackageKind: String {
        case cask
        case formula
    }

    struct LoadRefusal {
        let kind: PackageKind
        let qualifiedName: String
        let tap: String
    }

    /// The marker required before reading the warning's remedy-command lines, so
    /// `brew untap` text from any other source — Wega's own `$ brew untap …` header, Homebrew's
    /// deprecated-taps notice — never turns into an offer.
    static let marker = "because tap trust is required"

    /// Remedy lines whose arguments are tap names. The narrower `brew trust --cask …` lines
    /// carry options and three-part names, which the tap-name filter rejects on its own.
    private static let remedyCommands = ["brew untap ", "brew trust "]

    /// Taps named by a warning or an exact package-load refusal, each once.
    public static func untrustedTaps(in log: [String]) -> [String] {
        let lines = log.map(unprefixed)
        let hasWarning = lines.contains { $0.contains(marker) }

        var taps: [String] = []
        for line in lines {
            if let refusal = loadRefusal(in: line), !taps.contains(refusal.tap) {
                taps.append(refusal.tap)
            }
            guard hasWarning, let command = remedyCommands.first(where: line.hasPrefix) else { continue }
            for name in line.dropFirst(command.count).split(separator: " ").map(String.init)
            where isTapName(name) && !taps.contains(name) {
                taps.append(name)
            }
        }
        return taps
    }

    static func loadRefusal(in line: String) -> LoadRefusal? {
        let words = unprefixed(line).split(separator: " ").map(String.init)
        guard words.count == 10,
              Array(words.prefix(4)) == ["Error:", "Refusing", "to", "load"],
              let kind = PackageKind(rawValue: words[4]),
              Array(words[6...8]) == ["from", "untrusted", "tap"],
              words[9].hasSuffix(".") else { return nil }
        let tap = String(words[9].dropLast())
        let name = words[5]
        let parts = name.split(separator: "/", omittingEmptySubsequences: false)
        guard isTapName(tap), parts.count == 3,
              parts.prefix(2).joined(separator: "/") == tap,
              parts[2].range(of: #"^[A-Za-z0-9][A-Za-z0-9_.+@-]*$"#, options: .regularExpression) != nil else { return nil }
        return LoadRefusal(kind: kind, qualifiedName: name, tap: tap)
    }

    /// `<user>/<repo>` — the only shape Homebrew accepts as a tap name. A leading `-` would
    /// make a name read as an option, so neither part may start with one.
    static func isTapName(_ name: String) -> Bool {
        name.range(of: #"^[A-Za-z0-9][A-Za-z0-9_.-]*/[A-Za-z0-9][A-Za-z0-9_.-]*$"#, options: .regularExpression) != nil
    }

    /// The line as Homebrew printed it: the batch lane's `[token] ` prefix
    /// (`UpgradeLogPrefix`) and the warning's indentation removed.
    private static func unprefixed(_ line: String) -> String {
        var text = Substring(line)
        if text.hasPrefix("["), let close = text.firstIndex(of: "]"),
           text[text.index(after: close)...].hasPrefix(" ") {
            text = text[text.index(close, offsetBy: 2)...]
        }
        return text.trimmingCharacters(in: .whitespaces)
    }
}
