import Foundation

/// One fix the brew log panel offers for Homebrew's tap-trust warning: a single brew command,
/// run only when the user clicks it.
///
/// Trusting a tap or removing one changes the user's Homebrew configuration, so the remedy
/// carries the exact argument vector that will run, and `commandLine` is what the notice shows.
public struct TapTrustRemedy: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        /// `brew trust --cask` for the installed casks that came from untrusted taps.
        case trustInstalledCasks
        /// `brew trust --formula` for the installed formulae that came from untrusted taps.
        case trustInstalledFormulae
        /// `brew untap` for the untrusted taps nothing installed came from.
        case untapUnused
    }

    public let kind: Kind
    /// Arguments after `brew`, as handed to `BrewService.events(arguments:)`.
    public let arguments: [String]

    public init(kind: Kind, arguments: [String]) {
        self.kind = kind
        self.arguments = arguments
    }

    /// The command as the user would type it — the same vector that runs, fence included.
    public var commandLine: String {
        (["brew"] + arguments).joined(separator: " ")
    }
}

/// Decides, per untrusted tap, which remedy to offer.
///
/// A tap something installed came from keeps working with the **narrowest** trust: exactly
/// those casks and formulae. Whole-tap trust is never offered — it also covers every cask,
/// formula and command the tap publishes in the future. A tap nothing installed came from is
/// unused, and untapping it is Homebrew's own first suggestion. Origins come from install
/// receipts (`HomebrewInstallReceipts`), never from a token resembling the tap's name.
public enum TapTrustPlanner {
    public static func remedies(
        forUntrustedTaps taps: [String],
        installed: [InstalledPackageOrigin]
    ) -> [TapTrustRemedy] {
        let listed = Set(taps.map { $0.lowercased() })
        let fromListedTaps = installed.filter { listed.contains($0.tap.lowercased()) }
        let usedTaps = Set(fromListedTaps.map { $0.tap.lowercased() })

        var remedies: [TapTrustRemedy] = []
        let casks = qualifiedNames(of: .cask, in: fromListedTaps)
        if !casks.isEmpty {
            remedies.append(TapTrustRemedy(kind: .trustInstalledCasks, arguments: BrewService.trustCaskArguments(names: casks)))
        }
        let formulae = qualifiedNames(of: .formula, in: fromListedTaps)
        if !formulae.isEmpty {
            remedies.append(TapTrustRemedy(kind: .trustInstalledFormulae, arguments: BrewService.trustFormulaArguments(names: formulae)))
        }
        let unused = taps.filter { !usedTaps.contains($0.lowercased()) }
        if !unused.isEmpty {
            remedies.append(TapTrustRemedy(kind: .untapUnused, arguments: BrewService.untapArguments(taps: unused)))
        }
        return remedies
    }

    /// `<user>/<repo>/<name>` — the fully-qualified form `brew trust --cask/--formula` takes.
    private static func qualifiedNames(of kind: InstalledPackageOrigin.Kind, in origins: [InstalledPackageOrigin]) -> [String] {
        Set(origins.filter { $0.kind == kind }.map { "\($0.tap)/\($0.name)" }).sorted()
    }
}
