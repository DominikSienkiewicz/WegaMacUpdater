import Foundation

/// Turns the markers Homebrew prints into `UpgradeProgress`.
///
/// One instance per run, fed every stdout/stderr chunk of every brew call that run makes,
/// plus direct advances for the two sources that report nothing per package: npm (a loop
/// that already knows its package) and the Mac App Store (one opaque batch).
///
/// `soleDownloadToken` is the run's only planned package, when it has exactly one. It is
/// the one case where a download may be named without guessing.
public final class UpgradeProgressTracker {
    public let totalUnits: Int

    private let soleDownloadToken: String?
    private var finishedTokens: Set<String> = []
    private var inFlightToken: String?
    private var explicitlyCompletedUnits = 0
    private var stage: UpgradeStage = .preparing
    private var pendingLine: String = ""

    public init(totalUnits: Int, soleDownloadToken: String? = nil) {
        self.totalUnits = totalUnits
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

    public func beginRefreshing() {
        stage = .refreshing
    }

    private func apply(_ event: BrewProgressEvent?) {
        switch event {
        case .packageStarted(let token):
            // The boundary rule: whatever was running is done, because brew moved on. A
            // cask announces itself twice (`Upgrading x`, then `Installing Cask x`), so the
            // same token starting again closes nothing.
            if inFlightToken != token { closeInFlight() }
            inFlightToken = token
            stage = .installing(token: token)
        case .packageFinished(let token):
            finishedTokens.insert(token)
            if inFlightToken == token { inFlightToken = nil }
            // The stage is left alone on purpose: nothing else has started yet, and naming
            // a phase that is not running would be worse than a label a moment stale.
        case .downloadStarted(let token):
            stage = .downloading(token: token ?? soleDownloadToken)
        case nil:
            break
        }
    }

    private func closeInFlight() {
        guard let inFlightToken else { return }
        finishedTokens.insert(inFlightToken)
        self.inFlightToken = nil
    }

    private func flushPendingLine() {
        guard !pendingLine.isEmpty else { return }
        apply(BrewUpgradeProgressParser.event(for: pendingLine))
        pendingLine = ""
    }
}
