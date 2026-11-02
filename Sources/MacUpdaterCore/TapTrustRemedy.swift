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
        /// Trust a specific definition Homebrew refused to load while checking an untap.
        case trustRequiredCask
        case trustRequiredFormula
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
    private static let successPrefix = "[wega] succeeded: "

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
        for tap in unused {
            remedies.append(TapTrustRemedy(kind: .untapUnused, arguments: BrewService.untapArguments(taps: [tap])))
        }
        return remedies
    }

    /// Pending remedies, including explicit scoped trust after a blocked untap.
    /// Only Wega's successful-exit marker dismisses an action; starting it is not success.
    public static func pending(_ remedies: [TapTrustRemedy], in log: [String]) -> [TapTrustRemedy] {
        var succeeded: Set<String> = []
        var blocked: [TapTrustRemedy] = []
        var untapTargets: Set<String> = []
        var readingWarning = false
        for line in log {
            if line.contains(TapTrustWarning.marker) {
                readingWarning = true
            }
            if readingWarning {
                let warnedTaps = Set(TapTrustWarning.remedyTaps(in: line))
                for remedy in remedies where !tapNames(in: remedy).isDisjoint(with: warnedTaps) {
                    succeeded.remove(remedy.commandLine)
                }
            }
            if line.hasPrefix("$ ") {
                readingWarning = false
                let command = String(line.dropFirst(2))
                untapTargets = tapsInUntap(command)
                succeeded.remove(command)
            } else if line.hasPrefix(successPrefix) {
                readingWarning = false
                let command = String(line.dropFirst(successPrefix.count))
                succeeded.insert(command)
                let removedTaps = tapsInUntap(command)
                blocked.removeAll { remedy in
                    remedy.commandLine == command || remedy.arguments.last.map { name in
                        removedTaps.contains(name.split(separator: "/").prefix(2).joined(separator: "/"))
                    } == true
                }
                untapTargets.removeAll()
            } else if let refusal = TapTrustWarning.loadRefusal(in: line), untapTargets.contains(refusal.tap) {
                let remedy = trustRequired(by: refusal)
                succeeded.remove(remedy.commandLine)
                if !blocked.contains(remedy) { blocked.append(remedy) }
            }
        }
        let recoveryCommands = Set(blocked.map(\.commandLine))
        return blocked + remedies.filter { !succeeded.contains($0.commandLine) && !recoveryCommands.contains($0.commandLine) }
    }

    /// The line Wega writes into the brew log when it starts `remedy` — the same `$ brew …`
    /// form every other streamed brew command in the log begins with.
    public static func logHeader(for remedy: TapTrustRemedy) -> String {
        "$ " + remedy.commandLine
    }

    public static func logSuccess(for remedy: TapTrustRemedy) -> String {
        successPrefix + remedy.commandLine
    }

    private static func tapNames(in remedy: TapTrustRemedy) -> Set<String> {
        let names = remedy.arguments.drop(while: { $0 != "--" }).dropFirst()
        if remedy.kind == .untapUnused { return Set(names) }
        return Set(names.map { $0.split(separator: "/").prefix(2).joined(separator: "/") })
    }

    private static func tapsInUntap(_ command: String) -> Set<String> {
        let words = command.split(separator: " ").map(String.init)
        guard Array(words.prefix(3)) == ["brew", "untap", "--"], words.count > 3 else { return [] }
        let taps = words.dropFirst(3)
        guard taps.allSatisfy(TapTrustWarning.isTapName) else { return [] }
        return Set(taps)
    }

    private static func trustRequired(by refusal: TapTrustWarning.LoadRefusal) -> TapTrustRemedy {
        switch refusal.kind {
        case .cask:
            return TapTrustRemedy(kind: .trustRequiredCask, arguments: BrewService.trustCaskArguments(names: [refusal.qualifiedName]))
        case .formula:
            return TapTrustRemedy(kind: .trustRequiredFormula, arguments: BrewService.trustFormulaArguments(names: [refusal.qualifiedName]))
        }
    }

    /// `<user>/<repo>/<name>` — the fully-qualified form `brew trust --cask/--formula` takes.
    private static func qualifiedNames(of kind: InstalledPackageOrigin.Kind, in origins: [InstalledPackageOrigin]) -> [String] {
        Set(origins.filter { $0.kind == kind }.map { "\($0.tap)/\($0.name)" }).sorted()
    }
}
