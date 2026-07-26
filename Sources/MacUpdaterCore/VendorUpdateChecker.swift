import Foundation

/// The outcome of interpreting a checker's already-status-classified 200 body (ARCH-06).
///
/// Most vendors parse a latest version string and let the shared driver run the identical
/// `isUpgrade` comparison; a few decide the whole result themselves (a build-number
/// comparison, draft filtering, a "no version parsed means current" rule, or an empty
/// installed version). Both cases funnel through the one driver so the skeleton — and the
/// `statusCode >= 500 ? .unavailable : .failed` classification — is never copied per vendor.
public enum VendorEvaluation: Sendable {
    /// A concrete latest version was parsed. The driver applies the shared `isUpgrade`
    /// comparison against `installed` and, when it is an upgrade, builds the outdated item.
    case candidate(VendorCandidate)
    /// The checker resolved the outcome entirely on its own.
    case decided(ManualCheckResult)
}

/// The parsed "there is a newer version" payload handed back to the shared driver. Keeping
/// it a struct (rather than a case with defaulted associated values) lets the common
/// `recordedInstalled`/`releaseNotes` fields default cleanly at the call site.
public struct VendorCandidate: Sendable {
    /// The latest version advertised by the source.
    public var latest: String
    /// The installed version to compare against with `isUpgrade`.
    public var installed: String
    /// The version to store on the result when it differs from the compared `installed`
    /// (Google Drive compares a bundle build but records the short version). Defaults to
    /// `installed`.
    public var recordedInstalled: String?
    public var source: ManualOutdatedApp.UpdateSource
    public var releaseNotes: String?

    public init(
        latest: String,
        installed: String,
        recordedInstalled: String? = nil,
        source: ManualOutdatedApp.UpdateSource,
        releaseNotes: String? = nil
    ) {
        self.latest = latest
        self.installed = installed
        self.recordedInstalled = recordedInstalled
        self.source = source
        self.releaseNotes = releaseNotes
    }
}

/// The vendor-specific inputs to a single update check, produced synchronously before any
/// network I/O: the request to send, any non-200 status codes that already mean "current"
/// (e.g. Squirrel's `204`), and the closure that interprets a successful body.
public struct VendorCheckPlan: Sendable {
    public var request: HTTPRequest
    /// Status codes that mean "already up to date" without a body — checked before the
    /// `200` guard so a vendor's `204` reads as current, not as a failure.
    public var upToDateStatusCodes: Set<Int>
    public var evaluate: @Sendable (Data) -> VendorEvaluation

    public init(
        request: HTTPRequest,
        upToDateStatusCodes: Set<Int> = [],
        evaluate: @escaping @Sendable (Data) -> VendorEvaluation
    ) {
        self.request = request
        self.upToDateStatusCodes = upToDateStatusCodes
        self.evaluate = evaluate
    }
}

/// One shared shape for every vendor update checker (ARCH-06 — "13 vendor-checkerów
/// powiela ten sam szkielet").
///
/// Each checker supplies only the vendor-specific `plan(for:)`. The identical
/// `check → GET → klasyfikacja → parse → isUpgrade` skeleton — including the single
/// `statusCode >= 500 ? .unavailable : .failed` classification, which used to be copied
/// verbatim into 13 files — lives exactly once in the `check(app:)` default below. Adding a
/// vendor means writing a `plan`, not another copy of the skeleton.
public protocol VendorUpdateChecker: Sendable {
    /// The one HTTP client used by the shared driver. Exposed so the default `check(app:)`
    /// can drive the request without each checker re-implementing it.
    var client: HTTPClient { get }

    /// The vendor-specific plan for this app, or `nil` when the checker does not apply
    /// (wrong bundle id, no comparable version, an endpoint that could not be built).
    /// Returning `nil` yields `.notApplicable` without touching the network.
    func plan(for app: ApplicationInfo) -> VendorCheckPlan?
}

public extension VendorUpdateChecker {
    /// The one generic driver. Every checker routes through this: resolve the plan, perform
    /// the request, apply the single shared status classification, and hand a successful
    /// body to the vendor's `evaluate`.
    func check(app: ApplicationInfo) async -> ManualCheckResult {
        guard let plan = plan(for: app) else { return .notApplicable }
        guard let response = try? await client.send(plan.request) else { return .unavailable }
        if plan.upToDateStatusCodes.contains(response.statusCode) { return .upToDate }
        guard response.statusCode == 200 else {
            return response.statusCode >= 500 ? .unavailable : .failed
        }
        switch plan.evaluate(response.data) {
        case .decided(let result):
            return result
        case .candidate(let candidate):
            guard isUpgrade(installed: candidate.installed, latest: candidate.latest) else { return .upToDate }
            return .outdated(ManualOutdatedApp(
                name: app.name,
                path: app.path,
                installedVersion: candidate.recordedInstalled ?? candidate.installed,
                availableVersion: candidate.latest,
                source: candidate.source,
                releaseNotes: candidate.releaseNotes
            ))
        }
    }
}
