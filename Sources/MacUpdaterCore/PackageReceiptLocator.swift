import Foundation
import WegaHelperKit

/// Which installer package owns a file on disk, asked of macOS itself.
///
/// A `.pkg`-installed bundle carries no token, no appcast and no vendor id — nothing that
/// says which Homebrew cask, if any, packages it. The receipt database does: every `.pkg`
/// records the files it laid down, so `pkgutil --file-info` answers "which package put this
/// here" with the package identifier, and a cask's `uninstall` stanza names that same
/// identifier. That pair is the only exact, vendor-independent bridge between an installed
/// JDK and the cask that can update it — which is why it is used instead of guessing a token
/// from the bundle's name.
public struct PackageReceiptLocator: Sendable {
    private let runner: ProcessRunning

    public init(runner: ProcessRunning = ProcessRunner()) {
        self.runner = runner
    }

    /// The package identifier that installed `bundleURL`, or `nil` when the bundle came from
    /// somewhere other than an installer package (a drag install, an archive, a build tree).
    public func packageIdentifier(forBundleAt bundleURL: URL) async -> String? {
        let probe = bundleURL.appendingPathComponent("Contents/Info.plist")
        let request = ProcessRequest(
            executableURL: SystemPaths.pkgutil,
            arguments: ["--file-info", probe.path],
            environment: [:],
            inheritParentEnvironment: false,
            timeouts: .query
        )
        guard let result = try? await runner.run(request), result.exitCode == 0 else { return nil }
        return PackageReceiptParser.packageIdentifier(fromFileInfo: result.stdout)
    }
}

/// Parses `pkgutil --file-info` output. Split out from the process call so the format —
/// blank-line-separated blocks of `key: value`, one block per owning package — is testable
/// without a subprocess.
public enum PackageReceiptParser {
    /// The first `pkgid:` value in the output.
    ///
    /// A path can be claimed by more than one receipt (a package upgraded in place leaves the
    /// older receipt behind). `pkgutil` prints the most recent block first, and taking the
    /// first one keeps the answer deterministic rather than dependent on how many upgrades a
    /// machine has seen.
    public static func packageIdentifier(fromFileInfo output: String) -> String? {
        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = String(rawLine).trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("pkgid:") else { continue }
            let value = String(line.dropFirst("pkgid:".count)).trimmingCharacters(in: .whitespaces)
            return value.isEmpty ? nil : value
        }
        return nil
    }
}

/// Reverse lookup from an installer-package identifier to the Homebrew cask that declares it.
///
/// Built once per scan from the cask database that is already downloaded for name matching,
/// so resolving a JDK costs no extra network call and no extra `brew` process.
public struct CaskPackageReceiptIndex: Sendable {
    private let tokensByIdentifier: [String: String]

    public init(casks: [BrewCask]) {
        // Sorted so a package identifier claimed by two casks always resolves to the same one;
        // Homebrew keeps its versioned JDK casks disjoint, so this is a tie-break that should
        // never fire rather than a routine choice.
        tokensByIdentifier = casks
            .sorted { $0.token < $1.token }
            .reduce(into: [:]) { index, cask in
                for identifier in cask.pkgutilIdentifiers where index[identifier] == nil {
                    index[identifier] = cask.token
                }
            }
    }

    public func token(forPackageIdentifier identifier: String) -> String? {
        tokensByIdentifier[identifier]
    }
}
