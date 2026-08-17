import Foundation

/// What the canary → rollback chain concluded about one cask after its upgrade.
///
/// Lives in Core rather than next to the filesystem work in `CaskRollbackGuard` so the
/// verdict can travel into the pure run aggregation below — the window and the background
/// updater both summarize from it, and neither can decide "success" without seeing it.
public enum CaskValidationVerdict: Equatable, Sendable {
    /// Gatekeeper accepted the new version and the publisher is unchanged.
    case healthy
    /// The new version failed its check and the previous one was restored.
    case rolledBack
    /// The new version failed its check and could not be restored. The worst case, and
    /// the one that must never be silent.
    case rollbackFailed
    /// The publisher's Team ID changed between versions — a possible takeover.
    case publisherChanged(old: String, new: String?)
    /// The publisher changed and the previous version was restored from its snapshot.
    case publisherChangedAndRolledBack(old: String, new: String?)
    /// The package manager reported success but the bundle on disk still holds the
    /// pre-upgrade version: nothing was installed, so there is nothing to validate and
    /// nothing to roll back. Homebrew does this whenever its own Caskroom record already
    /// names the new version while the app on disk does not — see `NoOpCaskUpgradeTests`.
    case notUpgraded
}

/// How one item ended the run, across **every** phase it had to clear: execution,
/// validation, rollback and the post-upgrade rescan.
///
/// The point of a single verdict per item is that there is exactly one place that can
/// answer "was this updated?" — before REL-02 the answer was assembled from a brew exit
/// code alone, and everything the later phases learned reached the log and nothing else.
public enum ItemUpdateVerdict: Equatable, Sendable {
    /// Cleared every phase.
    case succeeded
    /// Installed and verified, but the publisher's Team ID changed — the upgrade happened,
    /// and the user still has to be told.
    case publisherChanged(old: String, new: String?)
    /// The publisher changed, so the guard restored the previous trusted version.
    case publisherChangedAndRolledBack(old: String, new: String?)
    /// The installed app already differed from the trusted baseline, so no upgrade ran.
    case publisherMismatchBeforeUpgrade(old: String, current: String?)
    /// The upgrade ran, but the rescan that would confirm it could not complete.
    case notVerified
    /// The rescan still lists this item as outdated, whatever the tool reported.
    case stillOutdated
    /// The new version failed its check; the previous one is back in place.
    case rolledBack
    /// The package manager failed to install it.
    case executionFailed
    /// The unattended batch failed globally after this app had already been restored.
    case executionFailedAfterRollback
    /// The unattended batch failed globally and a publisher mismatch also triggered rollback.
    case executionFailedAfterPublisherRollback(old: String, new: String?)
    /// The unattended batch failed globally, but the app left on disk changed publisher.
    case executionFailedWithPublisherChange(old: String, new: String?)
    /// The new version failed its check and could not be restored.
    case rollbackFailed

    /// True only for verdicts where the item genuinely ended up on the new version.
    public var upgraded: Bool {
        switch self {
        case .succeeded, .publisherChanged: return true
        case .notVerified, .stillOutdated, .rolledBack, .publisherChangedAndRolledBack,
             .publisherMismatchBeforeUpgrade,
             .executionFailed, .executionFailedAfterRollback, .executionFailedAfterPublisherRollback,
             .executionFailedWithPublisherChange,
             .rollbackFailed: return false
        }
    }

    /// Outcomes the user must not be able to miss — they earn a sticky banner and a
    /// notification of their own, never a line in a collapsed log.
    public var isCritical: Bool {
        switch self {
        case .rollbackFailed, .publisherChanged, .publisherChangedAndRolledBack,
             .publisherMismatchBeforeUpgrade,
             .executionFailedAfterPublisherRollback, .executionFailedWithPublisherChange: return true
        case .succeeded, .notVerified, .stillOutdated, .rolledBack,
             .executionFailed, .executionFailedAfterRollback: return false
        }
    }

    /// What the log says about this verdict. Polish, like every other `WegaLog` message.
    public var logDescription: String {
        switch self {
        case .succeeded:        return "zaktualizowano"
        case .publisherChanged: return "zaktualizowano, ale zmienił się Team ID wydawcy"
        case .publisherChangedAndRolledBack:
            return "zmienił się Team ID wydawcy — przywrócono poprzednią zaufaną wersję"
        case .publisherMismatchBeforeUpgrade:
            return "Team ID już różnił się od zaufanego baseline — aktualizację zablokowano przed uruchomieniem"
        case .notVerified:      return "zaktualizowano, ale skan po aktualizacji nie potwierdził wyniku"
        case .stillOutdated:    return "nadal widnieje jako nieaktualne po skanie kontrolnym"
        case .rolledBack:       return "nowa wersja nie przeszła kontroli — przywrócono poprzednią"
        case .executionFailed:  return "menedżer pakietów zgłosił błąd"
        case .executionFailedAfterRollback:
            return "menedżer pakietów zgłosił błąd; przywrócono poprzednią wersję po kontroli"
        case .executionFailedAfterPublisherRollback:
            return "menedżer pakietów zgłosił błąd; zmiana wydawcy wymusiła przywrócenie poprzedniej wersji"
        case .executionFailedWithPublisherChange:
            return "menedżer pakietów zgłosił błąd, ale aplikacja na dysku zmieniła Team ID wydawcy"
        case .rollbackFailed:   return "nowa wersja nie przeszła kontroli, a rollback się nie powiódł"
        }
    }

    /// Phases report independently and can disagree (a cask brew called upgraded, that the
    /// canary then rejected). The worse verdict wins, so no later phase can talk an earlier
    /// failure back up into a success.
    var severity: Int {
        switch self {
        case .succeeded:        return 0
        case .publisherChanged: return 1
        case .notVerified:      return 2
        case .stillOutdated:    return 3
        case .rolledBack, .publisherChangedAndRolledBack: return 4
        case .publisherMismatchBeforeUpgrade: return 5
        case .executionFailed:  return 5
        case .executionFailedAfterRollback, .executionFailedAfterPublisherRollback,
             .executionFailedWithPublisherChange: return 5
        case .rollbackFailed:   return 6
        }
    }
}

/// One result per item **and** source: the verdict, plus the identity needed to tie it
/// back to the row it came from (`key`, the source-tagged key `UpdatePlanner` routes on).
public struct ItemUpdateOutcome: Equatable, Sendable {
    public let key: String
    public let name: String
    public let kind: OutdatedItem.Kind
    public private(set) var verdict: ItemUpdateVerdict

    public init(key: String, name: String, kind: OutdatedItem.Kind, verdict: ItemUpdateVerdict) {
        self.key = key
        self.name = name
        self.kind = kind
        self.verdict = verdict
    }

    mutating func escalate(to newVerdict: ItemUpdateVerdict) {
        if newVerdict.severity > verdict.severity { verdict = newVerdict }
    }

    /// Validation describes the app left on disk, independently of the process-wide exit.
    /// Preserve both facts when a background batch failed after mutating this item.
    mutating func applyValidation(_ validation: CaskValidationVerdict) {
        switch (verdict, validation) {
        case (.executionFailed, .rolledBack):
            verdict = .executionFailedAfterRollback
        case (.executionFailed, .publisherChangedAndRolledBack(let old, let new)):
            verdict = .executionFailedAfterPublisherRollback(old: old, new: new)
        case (.executionFailed, .publisherChanged(let old, let new)):
            verdict = .executionFailedWithPublisherChange(old: old, new: new)
        case (_, .healthy):
            break
        case (_, .rolledBack):
            escalate(to: .rolledBack)
        case (_, .publisherChangedAndRolledBack(let old, let new)):
            escalate(to: .publisherChangedAndRolledBack(old: old, new: new))
        case (_, .rollbackFailed):
            escalate(to: .rollbackFailed)
        case (_, .publisherChanged(let old, let new)):
            escalate(to: .publisherChanged(old: old, new: new))
        case (_, .notUpgraded):
            // The item is exactly as outdated as it was before the run. Saying so here matters
            // because the confirming rescan cannot: it asks brew, and brew is the thing whose
            // record was wrong.
            escalate(to: .stillOutdated)
        }
    }

    /// Compound background verdicts participate in each relevant summary bucket.
    var reportedVerdicts: [ItemUpdateVerdict] {
        switch verdict {
        case .executionFailedAfterRollback:
            return [.executionFailed, .rolledBack]
        case .publisherChangedAndRolledBack(let old, let new):
            return [.rolledBack, .publisherChangedAndRolledBack(old: old, new: new)]
        case .executionFailedAfterPublisherRollback(let old, let new):
            return [.executionFailed, .rolledBack, .publisherChangedAndRolledBack(old: old, new: new)]
        case .executionFailedWithPublisherChange(let old, let new):
            return [.executionFailed, .publisherChanged(old: old, new: new)]
        default:
            return [verdict]
        }
    }
}

/// Everything one upgrade run produced, accumulated phase by phase.
///
/// Built by the window (`ScanStore.runUpdate`) and by the background updater, which is the
/// point: "we updated N packages" is now one computation over one list, instead of two
/// hand-rolled inferences that each dropped a different phase on the floor.
public struct UpdateRunOutcome: Equatable, Sendable {
    public private(set) var items: [ItemUpdateOutcome] = []
    /// Verbatim tool output explaining the failures, written to the log as-is.
    public private(set) var diagnostics: [String] = []
    public private(set) var needsSudoPassword = false
    /// REL-05 — macOS refused to let Wega replace an app bundle. Carried separately from
    /// the diagnostics text because it has a one-click fix, and a fix is not something to
    /// leave buried in `stderr`.
    public private(set) var needsAppManagementPermission = false

    public init() {
        // A new run starts with no outcomes, diagnostics, or permission failures.
    }

    /// Records casks rejected before the package manager runs because the installed app
    /// already differs from the trusted publisher baseline.
    public mutating func recordPublisherVetoes(
        _ covered: [OutdatedItem],
        audits: [String: TeamIDAudit]
    ) {
        for item in covered {
            guard case let .changed(old, current) = audits[item.name] else { continue }
            items.append(ItemUpdateOutcome(
                key: item.key,
                name: item.name,
                kind: item.kind,
                verdict: .publisherMismatchBeforeUpgrade(old: old, current: current)
            ))
        }
    }

    /// Records what one package-manager invocation did to the items it covered.
    /// `failedTokens` is matched against `OutdatedItem.name` — the token the tool prints.
    public mutating func record(_ covered: [OutdatedItem], outcome: BrewUpgradeOutcome) {
        let failed = Set(outcome.failedTokens)
        // A batch can fail without naming anyone (non-zero exit, no `Error: <token>:` line).
        // Then nothing in it may claim success.
        let batchFailed = !outcome.isSuccessful && failed.isEmpty

        for item in covered {
            let verdict: ItemUpdateVerdict = failed.contains(item.name) || batchFailed
                ? .executionFailed
                : .succeeded
            items.append(ItemUpdateOutcome(key: item.key, name: item.name, kind: item.kind, verdict: verdict))
        }

        if !outcome.isSuccessful {
            diagnostics.append(contentsOf: outcome.errorLines.isEmpty
                ? ["brew zakończył działanie z kodem \(outcome.exitCode) bez komunikatu „Error:”."]
                : outcome.errorLines)
        }
        needsSudoPassword = needsSudoPassword || outcome.requiresSudoPassword
        needsAppManagementPermission = needsAppManagementPermission || outcome.requiresAppManagementPermission
    }

    /// Records an unattended batch, where a non-zero process exit invalidates the whole
    /// command. Background execution has no user present to inspect a partial result, so a
    /// global failure may not be narrowed to only the tokens brew happened to name.
    public mutating func recordBackgroundRound(_ covered: [OutdatedItem], outcome: BrewUpgradeOutcome) {
        guard outcome.exitCode != 0 else {
            record(covered, outcome: outcome)
            return
        }

        record(covered, outcome: BrewUpgradeOutcome(
            exitCode: outcome.exitCode,
            failedTokens: covered.map(\.name),
            errorLines: outcome.errorLines,
            requiresSudoPassword: outcome.requiresSudoPassword,
            requiresAppManagementPermission: outcome.requiresAppManagementPermission
        ))
    }

    /// `mas upgrade` is one process for every App Store item and reports no per-item result:
    /// it either completes or throws. Pass the thrown error's description as `failure`.
    ///
    /// The synthetic per-item outcome is what `runNpmUpgrade` has always produced and the
    /// MAS path never did — the thrown error reached the collapsible log and stopped there,
    /// leaving the run with nothing to be unhappy about.
    public mutating func record(masItems: [OutdatedItem], failure: String?) {
        for item in masItems {
            items.append(ItemUpdateOutcome(key: item.key, name: item.name, kind: item.kind,
                                           verdict: failure == nil ? .succeeded : .executionFailed))
        }
        if let failure { diagnostics.append("mas upgrade: \(failure)") }
    }

    /// Folds the canary / rollback verdicts in, keyed by cask token.
    ///
    /// `.healthy` is deliberately not applied: when brew never replaced the bundle the
    /// canary inspects the *old* app, which of course passes Gatekeeper — accepting that
    /// verdict would talk a failed install back up into a success.
    public mutating func applyValidation(_ verdicts: [String: CaskValidationVerdict]) {
        for index in items.indices where items[index].kind == .cask {
            guard let validation = verdicts[items[index].name] else { continue }
            items[index].applyValidation(validation)
        }
    }

    /// Folds the post-upgrade rescan in — the last phase an item has to clear.
    ///
    /// Only items still standing as `.succeeded` are touched: an item that was rolled back
    /// is of course still outdated, and it stays a rollback in the report.
    ///
    /// - Parameters:
    ///   - stillOutdatedKeys: keys the fresh scan still reports as outdated.
    ///   - confirmed: whether that scan could actually answer for these sources.
    public mutating func applyRescan(stillOutdatedKeys: Set<String>, confirmed: Bool) {
        for index in items.indices where items[index].verdict == .succeeded {
            if stillOutdatedKeys.contains(items[index].key) {
                items[index].escalate(to: .stillOutdated)
            } else if !confirmed {
                items[index].escalate(to: .notVerified)
            }
        }
    }

    public var summary: UpdateRunSummary {
        UpdateRunSummary(
            items: items,
            diagnostics: diagnostics,
            needsSudoPassword: needsSudoPassword,
            needsAppManagementPermission: needsAppManagementPermission
        )
    }
}

/// The run, reduced to what a banner, a notification and the log each need.
public struct UpdateRunSummary: Equatable, Sendable {
    public let items: [ItemUpdateOutcome]
    public let diagnostics: [String]
    public let needsSudoPassword: Bool
    public let needsAppManagementPermission: Bool

    public init(
        items: [ItemUpdateOutcome],
        diagnostics: [String],
        needsSudoPassword: Bool,
        needsAppManagementPermission: Bool = false
    ) {
        self.items = items
        self.diagnostics = diagnostics
        self.needsSudoPassword = needsSudoPassword
        self.needsAppManagementPermission = needsAppManagementPermission
    }

    public var attempted: Int { items.count }
    public var isEmpty: Bool { items.isEmpty }

    /// Items that genuinely ended up on the new version.
    public var upgraded: [ItemUpdateOutcome] { items.filter { $0.verdict.upgraded } }
    /// Items that did not — for whatever reason, in whatever phase.
    public var notUpgraded: [ItemUpdateOutcome] { items.filter { !$0.verdict.upgraded } }
    /// Items whose outcome must reach the user as a sticky banner / its own notification.
    public var critical: [ItemUpdateOutcome] { items.filter { $0.verdict.isCritical } }

    /// The single gate on announcing success: every item cleared every required phase.
    public var allItemsUpgraded: Bool { notUpgraded.isEmpty }

    public func names(where predicate: (ItemUpdateVerdict) -> Bool) -> [String] {
        items.filter { $0.reportedVerdicts.contains(where: predicate) }.map(\.name)
    }

    public var rollbackFailures: [ItemUpdateOutcome] {
        items.filter { $0.verdict == .rollbackFailed }
    }

    public var publisherChanges: [ItemUpdateOutcome] {
        items.compactMap { item in
            switch item.verdict {
            case .publisherChanged:
                return item
            case .publisherChangedAndRolledBack:
                return item
            case .publisherMismatchBeforeUpgrade:
                return item
            case .executionFailedAfterPublisherRollback(let old, let new):
                return ItemUpdateOutcome(key: item.key, name: item.name, kind: item.kind,
                                         verdict: .publisherChangedAndRolledBack(old: old, new: new))
            case .executionFailedWithPublisherChange(let old, let new):
                return ItemUpdateOutcome(key: item.key, name: item.name, kind: item.kind,
                                         verdict: .publisherChanged(old: old, new: new))
            default:
                return nil
            }
        }
    }
}
