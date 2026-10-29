import Foundation

/// Recognises Homebrew 7's tap-trust warning in a brew log and names the taps it lists.
///
/// Homebrew stops loading formulae, casks and commands from a third-party tap the user has
/// not trusted, and prints the same remedy block in the output of most commands. Wega already
/// shows that output in the brew log panel, so the panel is where the user meets the warning —
/// and where Wega can offer the fix instead of asking them to copy commands into a terminal.
///
/// The tap names are read from the remedy lines Homebrew prints (`brew untap <taps>` and the
/// whole-tap `brew trust <taps>`), never from prose. They become arguments of a command the
/// user runs with one click, so anything not shaped like `<user>/<repo>` is dropped: an option,
/// a placeholder such as `<user>/<tap>/<cask>`, a path.
public enum TapTrustWarning {
    /// The sentence only this warning prints. Without it no line is read as a remedy, so
    /// `brew untap` text from any other source — Wega's own `$ brew untap …` header, Homebrew's
    /// deprecated-taps notice — never turns into an offer.
    static let marker = "because tap trust is required"

    /// Remedy lines whose arguments are tap names. The narrower `brew trust --cask …` lines
    /// carry options and three-part names, which the tap-name filter rejects on its own.
    private static let remedyCommands = ["brew untap ", "brew trust "]

    /// Taps the warning in `log` names, each once, in the order Homebrew listed them.
    /// Empty when the log carries no tap-trust warning.
    public static func untrustedTaps(in log: [String]) -> [String] {
        let lines = log.map(unprefixed)
        guard lines.contains(where: { $0.contains(marker) }) else { return [] }

        var taps: [String] = []
        for line in lines {
            guard let command = remedyCommands.first(where: line.hasPrefix) else { continue }
            for name in line.dropFirst(command.count).split(separator: " ").map(String.init)
            where isTapName(name) && !taps.contains(name) {
                taps.append(name)
            }
        }
        return taps
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
