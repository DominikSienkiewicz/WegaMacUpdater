import Foundation

/// A single outdated package, normalised across every source (brew formula/cask,
/// Mac App Store, npm global) into one row the update list can render and select.
///
/// The `key` carries a one-character source tag (`f:`/`c:`/`a:`/`n:`) that is
/// **load-bearing**: `UpdatePlanner.plan(selectedKeys:allKeys:)` routes each
/// selected key back to the right upgrade command by that prefix. Building and
/// parsing the keys used to live in two far-apart private methods of `UpdateView`,
/// so a mismatch silently upgraded the wrong things — now both sides share this type
/// and are covered by `UpdatePlannerTests`.
public struct OutdatedItem: Identifiable, Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case formula, cask, appStore, npm }

    public let key: String
    public var id: String { key }
    public let name: String
    public let from: String?
    public let to: String?
    public let kind: Kind

    public init(key: String, name: String, from: String?, to: String?, kind: Kind) {
        self.key = key
        self.name = name
        self.from = from
        self.to = to
        self.kind = kind
    }
}

/// The set of upgrade commands a selection maps to, split by package manager.
public struct UpdatePlan: Equatable, Sendable {
    public var formulaNames: [String]
    public var caskNames: [String]
    public var npmNames: [String]
    public var includesMas: Bool

    public var count: Int

    public init(formulaNames: [String], caskNames: [String], npmNames: [String], includesMas: Bool, count: Int) {
        self.formulaNames = formulaNames
        self.caskNames = caskNames
        self.npmNames = npmNames
        self.includesMas = includesMas
        self.count = count
    }
}

/// Tri-state of the "select all" control.
public enum SelectAllState: Equatable, Sendable { case none, all, partial }

/// What the Update screen should communicate after a check, separating a clean
/// "everything is current" from a check that couldn't complete (e.g. offline).
public enum ScanState: Equatable, Sendable {
    case upToDate
    case outdated(Int)
    /// Nothing found, but at least one source failed — we can't claim "up to date".
    case checkFailed
    /// Updates found, but some sources also failed — the list may be incomplete.
    case partialFailure(updates: Int, failed: Int)
}

/// Aggregated verdict over a batch of brew/npm upgrades, used to pick the result banner.
public struct UpdateOutcomeSummary: Equatable, Sendable {
    public var anyFailure: Bool
    public var failedTokens: [String]
    public var needsSudoPassword: Bool
    /// Human-readable detail lines explaining *why* the failed upgrades failed —
    /// the brew "Error:" block (with its continuation lines), or a synthesized
    /// exit-code note when brew produced no message. Written verbatim to the log.
    public var failureDetails: [String]

    public init(anyFailure: Bool, failedTokens: [String], needsSudoPassword: Bool, failureDetails: [String] = []) {
        self.anyFailure = anyFailure
        self.failedTokens = failedTokens
        self.needsSudoPassword = needsSudoPassword
        self.failureDetails = failureDetails
    }
}

/// Pure, view-independent orchestration logic for the Update screen. Extracted out
/// of `UpdateView` so it can be unit-tested without SwiftUI or live services.
public enum UpdatePlanner {
    static let formulaPrefix = "f:"
    static let caskPrefix = "c:"
    static let masPrefix = "a:"
    static let npmPrefix = "n:"

    /// Flattens the per-source outdated results into one selectable list, tagging each
    /// row's key with its source prefix. Order: formulae, casks, App Store, npm.
    public static func outdatedItems(
        brew: BrewOutdated?,
        mas: [MasOutdatedApp],
        npm: [NpmGlobalOutdated]
    ) -> [OutdatedItem] {
        var items: [OutdatedItem] = []
        if let brew {
            items += brew.formulae.map {
                OutdatedItem(key: "\(formulaPrefix)\($0.name)", name: $0.name,
                             from: $0.installedVersions.first, to: $0.currentVersion, kind: .formula)
            }
            items += brew.casks.map {
                OutdatedItem(key: "\(caskPrefix)\($0.name)", name: $0.name,
                             from: $0.installedVersions.first, to: $0.currentVersion, kind: .cask)
            }
        }
        items += mas.map {
            OutdatedItem(key: "\(masPrefix)\($0.appStoreID)", name: $0.name,
                         from: $0.installedVersion, to: $0.currentVersion, kind: .appStore)
        }
        items += npm.map {
            OutdatedItem(key: "\(npmPrefix)\($0.name)", name: $0.name,
                         from: $0.installedVersion, to: $0.latestVersion, kind: .npm)
        }
        return items
    }

    /// FEAT-03 download transparency: the subset of outdated casks Homebrew will install
    /// **without** verifying a checksum (`sha256` absent or `"no_check"`), used to drive
    /// the "no checksum" banner. Looked up by cask **token**: for a cask `OutdatedItem`
    /// the token lives in `.name` (copied verbatim from `brew outdated`), which is exactly
    /// how `downloads` is keyed (`CaskDownloadInfo.token`). Using `.key` here would carry
    /// the `"c:"` source-tag prefix and never match, silently suppressing the warning for
    /// every cask. Casks with no download info are not flagged — we warn only about a
    /// *known* missing checksum, never about absent information.
    public static func casksWithoutChecksum(
        _ casks: [OutdatedItem],
        downloads: [String: CaskDownloadInfo]
    ) -> [OutdatedItem] {
        casks.filter { downloads[$0.name]?.hasChecksum == false }
    }

    /// Resolves which packages to upgrade. An empty selection means "all of them",
    /// matching the UI's "Update all" affordance. Returns the names split per manager.
    public static func plan(selectedKeys: Set<String>, allKeys: [String]) -> UpdatePlan {
        let keys = selectedKeys.isEmpty ? Set(allKeys) : selectedKeys
        return UpdatePlan(
            formulaNames: keys.compactMap { name(of: $0, prefix: formulaPrefix) }.sorted(),
            caskNames:    keys.compactMap { name(of: $0, prefix: caskPrefix) }.sorted(),
            npmNames:     keys.compactMap { name(of: $0, prefix: npmPrefix) }.sorted(),
            includesMas:  keys.contains { $0.hasPrefix(masPrefix) },
            count:        keys.count
        )
    }

    private static func name(of key: String, prefix: String) -> String? {
        key.hasPrefix(prefix) ? String(key.dropFirst(prefix.count)) : nil
    }

    public static func selectAllState(selectedCount: Int, totalCount: Int) -> SelectAllState {
        if selectedCount == 0 { return .none }
        if selectedCount == totalCount { return .all }
        return .partial
    }

    /// Toggling "select all" clears the selection when everything is already selected,
    /// otherwise selects everything.
    public static func toggledAll(selected: Set<String>, allKeys: [String]) -> Set<String> {
        selected.count == allKeys.count ? [] : Set(allKeys)
    }

    /// Deduplicates manual-update results that resolve to the same on-disk app, keeping
    /// the highest-priority source (e.g. brew cask over Sparkle), then sorts by name.
    public static func dedupedByPriority(_ items: [ManualOutdatedApp]) -> [ManualOutdatedApp] {
        var byPath: [String: ManualOutdatedApp] = [:]
        for item in items {
            let key = item.path.path
            if let existing = byPath[key] {
                if item.source.priority > existing.source.priority { byPath[key] = item }
            } else {
                byPath[key] = item
            }
        }
        return byPath.values.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    /// Manual updates split by install origin so the Updates window can present each
    /// under an origin-consistent header — Brew casks under "Homebrew Casks", everything
    /// genuinely outside a package manager under "Ręcznie zainstalowane". Grouping by
    /// `origin` (not by `source`) is what keeps the window in step with the Inventory
    /// badge: a self-updating Homebrew cask (Docker, Postman, ChatGPT…) stays in the
    /// Brew group even when its update is delivered by the app itself rather than `brew`.
    public struct ManualGroups: Equatable, Sendable {
        public var brew: [ManualOutdatedApp]
        public var appStore: [ManualOutdatedApp]
        public var manual: [ManualOutdatedApp]

        public init(brew: [ManualOutdatedApp], appStore: [ManualOutdatedApp], manual: [ManualOutdatedApp]) {
            self.brew = brew
            self.appStore = appStore
            self.manual = manual
        }
    }

    public static func groupManual(_ items: [ManualOutdatedApp]) -> ManualGroups {
        ManualGroups(
            brew:     items.filter { $0.origin == .brew },
            appStore: items.filter { $0.origin == .appStore },
            // `.npm` never reaches the manual path (npm globals aren't `.app` bundles),
            // so it folds in with `.manual` for a total partition.
            manual:   items.filter { $0.origin == .manual || $0.origin == .npm }
        )
    }

    /// Decides what the screen reports given how many updates were found and how many
    /// source checks failed. A failed check with zero finds must read as "couldn't
    /// check", never "up to date".
    public static func scanState(updateCount: Int, failedChecks: Int) -> ScanState {
        switch (updateCount, failedChecks) {
        case (0, 0):            return .upToDate
        case (0, _):            return .checkFailed
        case (let n, 0):        return .outdated(n)
        case (let n, let f):    return .partialFailure(updates: n, failed: f)
        }
    }

    /// Collapses a batch of upgrade outcomes into the booleans the result banner needs,
    /// plus the detail lines that explain each failure for the log.
    public static func summarize(outcomes: [BrewUpgradeOutcome]) -> UpdateOutcomeSummary {
        var details: [String] = []
        for outcome in outcomes where !outcome.isSuccessful {
            if outcome.errorLines.isEmpty {
                details.append("brew zakończył działanie z kodem \(outcome.exitCode) bez komunikatu „Error:”.")
            } else {
                details.append(contentsOf: outcome.errorLines)
            }
        }
        return UpdateOutcomeSummary(
            anyFailure: outcomes.contains { !$0.isSuccessful },
            failedTokens: outcomes.flatMap(\.failedTokens),
            needsSudoPassword: outcomes.contains { $0.requiresSudoPassword },
            failureDetails: details
        )
    }
}
