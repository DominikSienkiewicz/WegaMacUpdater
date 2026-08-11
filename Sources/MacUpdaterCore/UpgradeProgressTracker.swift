/// Turns the markers Homebrew prints into `UpgradeProgress`.
///
/// One instance per run, fed every stdout/stderr chunk of every brew call that run makes,
/// plus direct advances for the two sources that report nothing per package: npm (a loop
/// that already knows its package) and the Mac App Store (one opaque batch).
///
/// `plannedTokens` is what the run set out to upgrade, and the only thing it may credit.
/// `brew upgrade <names…>` also upgrades outdated *dependents* nobody selected and
/// announces each of them with the same marker, so a tracker that counted every token it
/// saw reached the total before the run had started its cask phase.
///
/// `soleDownloadToken` is the run's only planned package, when it has exactly one. It is
/// the one case where a download may be named without guessing.
public final class UpgradeProgressTracker {
    public let totalUnits: Int

    private let plannedTokens: Set<String>
    private let soleDownloadToken: String?
    private var finishedTokens: Set<String> = []
    private var inFlightToken: String?
    private var explicitlyCompletedUnits = 0
    private var stage: UpgradeStage = .preparing
    private var pendingLine: String = ""

    public init(totalUnits: Int, plannedTokens: Set<String>, soleDownloadToken: String? = nil) {
        self.totalUnits = totalUnits
        self.plannedTokens = Set(plannedTokens.map(Self.bareName))
        self.soleDownloadToken = soleDownloadToken
    }

    public var progress: UpgradeProgress {
        UpgradeProgress(
            completedUnits: min(finishedTokens.count + explicitlyCompletedUnits, totalUnits),
            totalUnits: totalUnits,
            stage: stage
        )
    }

    @discardableResult
    public func consume(chunk: String) -> UpgradeProgress {
        pendingLine += chunk
        // Chunks arrive on pipe-read boundaries, not line boundaries, so the tail of one
        // read is usually half a line. Parsing it would drop the marker it belongs to.
        while let lineBreak = pendingLine.firstIndex(where: \.isNewline) {
            apply(BrewUpgradeProgressParser.event(for: String(pendingLine[..<lineBreak])))
            pendingLine = String(pendingLine[pendingLine.index(after: lineBreak)...])
        }
        return progress
    }

    /// A brew call returned. Only a successful one closes the package it left in flight:
    /// the package brew died on is not finished work.
    public func brewCallFinished(succeeded: Bool) {
        flushPendingLine()
        if succeeded { closeInFlight() }
        inFlightToken = nil
    }

    /// npm advances one unit per successful package; the App Store batch advances by its
    /// whole size, and only when the call returned without error — a failed `mas upgrade`
    /// is no evidence that any single app was updated.
    public func completeUnits(_ count: Int) {
        explicitlyCompletedUnits += max(0, count)
    }

    /// npm upgrades one package per call and prints nothing this tracker parses, so the
    /// run names the package it is about to hand over.
    public func beginInstalling(token: String) {
        stage = .installing(token: token)
    }

    /// The App Store batch moves several apps behind one opaque call, so it names none.
    public func beginInstallingBatch() {
        stage = .installing(token: nil)
    }

    private func apply(_ event: BrewProgressEvent?) {
        switch event {
        case .packageStarted(let token):
            let name = Self.bareName(token)
            // The boundary rule: whatever was running is done, because brew moved on — an
            // unplanned dependent starting proves that too. A cask announces itself twice
            // (`Upgrading x`, then `Installing Cask x`), so the same token starting again
            // closes nothing.
            if inFlightToken != name { closeInFlight() }
            // Only a planned package may be credited later; brew's own dependents never can.
            inFlightToken = plannedTokens.contains(name) ? name : nil
            // The stage still names what is really installing, planned or not.
            stage = .installing(token: token)
        case .packageFinished(let token):
            let name = Self.bareName(token)
            if plannedTokens.contains(name) { finishedTokens.insert(name) }
            if inFlightToken == name { inFlightToken = nil }
            // The stage is left alone on purpose: nothing else has started yet, and naming
            // a phase that is not running would be worse than a label a moment stale.
        case .downloadStarted(let token):
            // A cask that fetches a resource mid-install was named one line earlier, so the
            // package in flight beats falling back to the generic label.
            stage = .downloading(token: token ?? inFlightToken ?? soleDownloadToken)
        case nil:
            break
        }
    }

    /// Whatever is in flight is a planned bare name, so what lands here is always creditable.
    private func closeInFlight() {
        guard let inFlightToken else { return }
        finishedTokens.insert(inFlightToken)
        self.inFlightToken = nil
    }

    /// Brew prints a tapped name (`homebrew/core/node`) where the plan holds the bare one,
    /// so both sides are matched on the substring after the last `/`.
    private static func bareName(_ token: String) -> String {
        guard let bare = token.split(separator: "/").last else { return token }
        return String(bare)
    }

    private func flushPendingLine() {
        guard !pendingLine.isEmpty else { return }
        apply(BrewUpgradeProgressParser.event(for: pendingLine))
        pendingLine = ""
    }
}
