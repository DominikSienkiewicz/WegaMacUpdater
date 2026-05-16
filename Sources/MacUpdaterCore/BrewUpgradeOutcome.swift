import Foundation

/// Analyzes raw brew upgrade output to determine whether the operation actually
/// succeeded. Brew sometimes prints "==> Upgraded N outdated package" even when
/// an individual cask failed mid-way (e.g. missing App source), so neither exit
/// code nor the summary line alone is reliable.
public struct BrewUpgradeOutcome: Equatable, Sendable {
    public let exitCode: Int32
    public let failedTokens: [String]
    public let errorLines: [String]

    public var isSuccessful: Bool {
        exitCode == 0 && errorLines.isEmpty
    }

    public init(exitCode: Int32, failedTokens: [String], errorLines: [String]) {
        self.exitCode = exitCode
        self.failedTokens = failedTokens
        self.errorLines = errorLines
    }

    /// Parses merged stdout+stderr output for "Error:" lines and extracts the
    /// offending token when the line has the shape "Error: <token>: <message>".
    public static func analyze(exitCode: Int32, output: String) -> BrewUpgradeOutcome {
        var errors: [String] = []
        var tokens: [String] = []
        var seen = Set<String>()

        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = String(rawLine).trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("Error:") else { continue }
            errors.append(line)

            let afterPrefix = line.dropFirst("Error:".count).trimmingCharacters(in: .whitespaces)
            if let colonIdx = afterPrefix.firstIndex(of: ":") {
                let candidate = afterPrefix[..<colonIdx].trimmingCharacters(in: .whitespaces)
                if isLikelyCaskToken(candidate), seen.insert(candidate).inserted {
                    tokens.append(candidate)
                }
            }
        }

        return BrewUpgradeOutcome(exitCode: exitCode, failedTokens: tokens, errorLines: errors)
    }

    private static func isLikelyCaskToken(_ s: String) -> Bool {
        guard !s.isEmpty, s.count <= 80 else { return false }
        return s.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "@" || $0 == "+" || $0 == "." }
    }
}
