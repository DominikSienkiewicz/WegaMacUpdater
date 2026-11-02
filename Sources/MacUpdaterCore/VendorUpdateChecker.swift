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
    /// The user-facing label when comparison uses a separate build identifier.
    public var recordedLatest: String?
    public var source: ManualOutdatedApp.UpdateSource
    public var releaseNotes: ReleaseNotes?
    /// How to order `installed` against `latest`. Defaults to the build-numbered scheme
    /// most vendors use; sources that publish SemVer tags (GitHub) must say so, or a
    /// prerelease outranks its own release (REL-11).
    public var scheme: VersionScheme
    public var installedVersionField: VendorUpdateRequirement.Field

    public init(
        latest: String,
        installed: String,
        recordedInstalled: String? = nil,
        source: ManualOutdatedApp.UpdateSource,
        releaseNotes: ReleaseNotes? = nil,
        scheme: VersionScheme = .buildNumbered,
        recordedLatest: String? = nil,
        installedVersionField: VendorUpdateRequirement.Field = .shortVersion
    ) {
        self.latest = latest
        self.installed = installed
        self.recordedInstalled = recordedInstalled
        self.source = source
        self.releaseNotes = releaseNotes
        self.scheme = scheme
        self.recordedLatest = recordedLatest
        self.installedVersionField = installedVersionField
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
        await check(app: app, plan: plan(for: app))
    }

    internal func check(app: ApplicationInfo, plan: VendorCheckPlan?) async -> ManualCheckResult {
        UpdateDiagnostics.record("vendor.check.started", fields: [
            "checker": String(describing: Self.self),
            "bundleIdentifier": app.bundleIdentifier ?? "unknown",
            "installed": app.version ?? "unknown",
        ])
        guard let plan else { return recordVendorResult(.notApplicable, app: app, reason: "no_plan") }
        guard let response = try? await client.send(plan.request) else {
            return recordVendorResult(.unavailable, app: app, reason: "transport_error")
        }
        UpdateDiagnostics.record("vendor.response", fields: [
            "checker": String(describing: Self.self),
            "bundleIdentifier": app.bundleIdentifier ?? "unknown",
            "status": String(response.statusCode),
        ])
        if plan.upToDateStatusCodes.contains(response.statusCode) {
            return recordVendorResult(.upToDate, app: app, reason: "accepted_status")
        }
        guard response.statusCode == 200 else {
            return recordVendorResult(response.statusCode >= 500 ? .unavailable : .failed, app: app, reason: "http_status")
        }
        switch plan.evaluate(response.data) {
        case .decided(let result):
            UpdateDiagnostics.record("vendor.parse", fields: [
                "checker": String(describing: Self.self),
                "bundleIdentifier": app.bundleIdentifier ?? "unknown", "evaluation": "decided",
            ])
            return recordVendorResult(result, app: app, reason: "vendor_decision")
        case .candidate(let candidate):
            let upgrade = isUpgrade(installed: candidate.installed, latest: candidate.latest, scheme: candidate.scheme)
            UpdateDiagnostics.record("vendor.parse", fields: [
                "checker": String(describing: Self.self),
                "bundleIdentifier": app.bundleIdentifier ?? "unknown",
                "evaluation": "candidate", "installed": candidate.installed, "latest": candidate.latest,
                "source": candidate.source.badgeLabel, "scheme": String(describing: candidate.scheme),
                "versionField": String(describing: candidate.installedVersionField), "isUpgrade": String(upgrade),
            ])
            guard upgrade else { return recordVendorResult(.upToDate, app: app, reason: "version_comparison") }
            let result = ManualCheckResult.outdated(ManualOutdatedApp(
                name: app.name,
                path: app.path,
                installedVersion: candidate.recordedInstalled ?? candidate.installed,
                availableVersion: candidate.recordedLatest ?? candidate.latest,
                source: candidate.source,
                releaseNotes: candidate.releaseNotes,
                completionRequirement: VendorUpdateRequirement(version: candidate.latest,
                    field: candidate.installedVersionField, scheme: candidate.scheme)
            ))
            return recordVendorResult(result, app: app, reason: "version_comparison")
        }
    }

    private func recordVendorResult(_ result: ManualCheckResult, app: ApplicationInfo, reason: String) -> ManualCheckResult {
        var fields = result.vendorDiagnosticFields
        fields["checker"] = String(describing: Self.self)
        fields["bundleIdentifier"] = app.bundleIdentifier ?? "unknown"
        fields["reason"] = reason
        UpdateDiagnostics.record("vendor.completed", fields: fields)
        return result
    }
}

private extension ManualCheckResult {
    var vendorDiagnosticFields: [String: String] {
        switch self {
        case .notApplicable: ["outcome": "not_applicable"]
        case .upToDate: ["outcome": "up_to_date"]
        case .unavailable: ["outcome": "unavailable"]
        case .failed: ["outcome": "failed"]
        case .outdated(let item): [
            "outcome": "outdated", "installed": item.installedVersion ?? "unknown",
            "latest": item.availableVersion ?? "unknown", "source": item.source.badgeLabel,
        ]
        }
    }
}
