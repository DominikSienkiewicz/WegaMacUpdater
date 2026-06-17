import Foundation

/// Analyzes raw brew upgrade output to determine whether the operation actually
/// succeeded. Brew sometimes prints "==> Upgraded N outdated package" even when
/// an individual cask failed mid-way (e.g. missing App source), so neither exit
/// code nor the summary line alone is reliable.
public struct BrewUpgradeOutcome: Equatable, Sendable {
    public let exitCode: Int32
    public let failedTokens: [String]
    public let errorLines: [String]
    /// True when brew's cask uninstall hooks invoked `sudo` and got
    /// "a password is required" — i.e. SUDO_ASKPASS is not configured and
    /// Wega runs without a controlling terminal. UI should surface this as
    /// an actionable hint (configure askpass), not a generic failure.
    public let requiresSudoPassword: Bool

    public var isSuccessful: Bool {
        exitCode == 0 && errorLines.isEmpty
    }

    public init(exitCode: Int32, failedTokens: [String], errorLines: [String], requiresSudoPassword: Bool = false) {
        self.exitCode = exitCode
        self.failedTokens = failedTokens
        self.errorLines = errorLines
        self.requiresSudoPassword = requiresSudoPassword
    }

    /// Parses merged stdout+stderr output for "Error:" lines and extracts the
    /// offending token when the line has the shape "Error: <token>: <message>".
    ///
    /// brew often prints a generic headline ("Error: Failure while executing; ...")
    /// and puts the *actual* cause on the lines that follow, so we also capture the
    /// continuation lines after an "Error:" until the next section header ("==>"),
    /// a blank line, or another marker. Those continuation lines are what make the
    /// log explain *why* an upgrade failed instead of merely that it did.
    public static func analyze(exitCode: Int32, output: String) -> BrewUpgradeOutcome {
        var errors: [String] = []
        var tokens: [String] = []
        var seen = Set<String>()
        var sudoPasswordRequired = false
        var capturingContinuation = false

        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = String(rawLine).trimmingCharacters(in: .whitespaces)

            if line.contains("sudo: a password is required") ||
               line.contains("sudo: a terminal is required to read the password") {
                sudoPasswordRequired = true
                capturingContinuation = false
                continue
            }

            if line.hasPrefix("Error:") {
                errors.append(line)
                capturingContinuation = true

                let afterPrefix = line.dropFirst("Error:".count).trimmingCharacters(in: .whitespaces)
                if let colonIdx = afterPrefix.firstIndex(of: ":") {
                    let candidate = afterPrefix[..<colonIdx].trimmingCharacters(in: .whitespaces)
                    if isLikelyCaskToken(candidate), seen.insert(candidate).inserted {
                        tokens.append(candidate)
                    }
                }
                continue
            }

            // Continuation of a multi-line error block: keep the detail lines that
            // follow an "Error:", stopping at the next section header / blank line.
            if capturingContinuation {
                if line.isEmpty || line.hasPrefix("==>") || line.hasPrefix("✔") || line.hasPrefix("Warning:") {
                    capturingContinuation = false
                } else if errors.count < maxCapturedErrorLines {
                    errors.append(line)
                }
            }
        }

        return BrewUpgradeOutcome(
            exitCode: exitCode,
            failedTokens: tokens,
            errorLines: errors,
            requiresSudoPassword: sudoPasswordRequired
        )
    }

    /// Safety cap so a pathological error block can't grow the log unbounded.
    private static let maxCapturedErrorLines = 40

    /// Tokens whose failure is an interrupted-upgrade leftover — brew bailed with
    /// "It seems there is already an App at '…'" because a stale staged app from a
    /// previous, cut-short upgrade is occupying the destination (e.g. a cask left in
    /// the `…upgrading` state). A forced retry (`--force`) overwrites the leftover and
    /// completes, so these are safe to retry exactly once. A *missing* source
    /// ("App source … is not there") is a different failure and is deliberately
    /// excluded — `--force` can't conjure a missing app.
    public var tokensRetryableWithForce: [String] {
        var result: [String] = []
        var seen = Set<String>()
        for line in errorLines where line.hasPrefix("Error:") && line.contains("already an App at") {
            let afterPrefix = line.dropFirst("Error:".count).trimmingCharacters(in: .whitespaces)
            guard let colonIdx = afterPrefix.firstIndex(of: ":") else { continue }
            let candidate = afterPrefix[..<colonIdx].trimmingCharacters(in: .whitespaces)
            if Self.isLikelyCaskToken(candidate), seen.insert(candidate).inserted {
                result.append(candidate)
            }
        }
        return result
    }

    /// Folds a forced-retry outcome back into the original batch outcome. The retried
    /// tokens' original failures are dropped (we just re-ran them); whatever the forced
    /// retry produced for those tokens stands. Unrelated failures in the original batch
    /// (a different cask that failed for a non-retryable reason) are preserved.
    public static func merging(
        original: BrewUpgradeOutcome,
        forcedRetry: BrewUpgradeOutcome,
        retriedTokens: [String]
    ) -> BrewUpgradeOutcome {
        let retried = Set(retriedTokens)

        let keptFailedTokens = original.failedTokens.filter { !retried.contains($0) }
        let keptErrorLines = original.errorLines.filter { line in
            !retried.contains(where: { tokenInErrorLine(line, token: $0) })
        }

        let failedTokens = keptFailedTokens + forcedRetry.failedTokens
        let errorLines = keptErrorLines + forcedRetry.errorLines

        let succeeded = failedTokens.isEmpty && errorLines.isEmpty && forcedRetry.isSuccessful
        let exitCode: Int32 = succeeded
            ? 0
            : (forcedRetry.exitCode != 0 ? forcedRetry.exitCode : original.exitCode)

        return BrewUpgradeOutcome(
            exitCode: exitCode,
            failedTokens: failedTokens,
            errorLines: errorLines,
            requiresSudoPassword: original.requiresSudoPassword || forcedRetry.requiresSudoPassword
        )
    }

    /// True when an `Error: <token>: …` line is about `token`.
    private static func tokenInErrorLine(_ line: String, token: String) -> Bool {
        guard line.hasPrefix("Error:") else { return false }
        let afterPrefix = line.dropFirst("Error:".count).trimmingCharacters(in: .whitespaces)
        guard let colonIdx = afterPrefix.firstIndex(of: ":") else { return false }
        return afterPrefix[..<colonIdx].trimmingCharacters(in: .whitespaces) == token
    }

    private static func isLikelyCaskToken(_ s: String) -> Bool {
        guard !s.isEmpty, s.count <= 80 else { return false }
        return s.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "@" || $0 == "+" || $0 == "." }
    }
}
