import Foundation

/// REL-12 — the foreground upgrade's stop switch, and the rule for where it may take effect.
///
/// Cancelling an upgrade is not the same problem as cancelling a scan. A scan only reads, so
/// killing `brew` mid-query costs nothing; an upgrade is replacing an app bundle, and a
/// process killed halfway through that leaves a half-written `.app` behind. So the request is
/// **cooperative**: it is honoured at the boundary between packages, never inside one. The
/// package already running finishes; nothing after it starts.
///
/// The type also remembers what it stopped. A run that skipped work is not a run that
/// succeeded, and the report has to be able to tell the difference — otherwise a cancelled
/// upgrade announces "everything is up to date" about packages nobody touched.
public struct UpdateInterruption: Equatable, Sendable {
    /// Whether the user has asked this run to stop.
    public private(set) var isRequested = false
    /// Planned keys that were never attempted because the run stopped at a boundary.
    public private(set) var skippedKeys: Set<String> = []

    public init() {}

    public mutating func request() {
        isRequested = true
    }

    /// Call at every package boundary, before starting the next package: returns `true` when
    /// the run must stop here, recording `remaining` — everything this run would still have
    /// attempted — as skipped.
    public mutating func shouldStop(before remaining: [String]) -> Bool {
        guard isRequested else { return false }
        skippedKeys.formUnion(remaining)
        return true
    }

    /// True only when stopping actually cost something. Pressing "Anuluj" while the last
    /// package is already running skips nothing, and such a run is reported as a normal one.
    public var didSkipWork: Bool { !skippedKeys.isEmpty }
}

/// REL-12 — what each remaining phase of one upgrade run would still touch.
///
/// The run executes in a fixed order — formulae, then the cask batch, then the npm packages
/// one at a time, then the App Store batch — so "what is left" at any boundary is a
/// projection of the plan, not a running tally the caller has to maintain by hand.
public struct UpgradeBoundaryKeys: Equatable, Sendable {
    /// Keys of the cask batch, which brew upgrades in a single invocation.
    public let caskKeys: [String]
    /// npm keys in the order the run will install them — one process per package.
    public let npmKeys: [String]
    /// Keys of the App Store batch, likewise a single `mas upgrade`.
    public let masKeys: [String]

    public init(planned: [OutdatedItem], npmNames: [String]) {
        self.caskKeys = planned.filter { $0.kind == .cask }.map(\.key)
        self.masKeys = planned.filter { $0.kind == .appStore }.map(\.key)
        // npm runs package by package, so its keys are ordered the way the run will walk
        // them rather than the way the scan happened to list them.
        let npmKeysByName = Dictionary(
            planned.filter { $0.kind == .npm }.map { ($0.name, $0.key) },
            uniquingKeysWith: { first, _ in first }
        )
        self.npmKeys = npmNames.compactMap { npmKeysByName[$0] }
    }

    /// Everything after the formula batch.
    public var afterFormulae: [String] { caskKeys + npmKeys + masKeys }

    /// Everything from the npm package at `index` onwards.
    public func fromNpmPackage(at index: Int) -> [String] {
        Array(npmKeys.dropFirst(index)) + masKeys
    }
}
