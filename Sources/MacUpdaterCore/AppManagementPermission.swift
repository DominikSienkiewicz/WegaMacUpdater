import Combine
import Foundation

/// Whether Wega may replace an application bundle in `/Applications` (REL-05).
///
/// Since macOS 13 that is gated by the TCC permission **App Management**, and the gate
/// covers *child processes*: `brew` runs as Wega's child, so a missing grant makes the
/// `ditto` that swaps the bundle fail with `Operation not permitted`. No public API
/// answers "am I granted?", so Wega has two signals and they are deliberately not equal
/// in weight:
///
/// - the **observed** denial parsed out of brew's own output
///   (``BrewUpgradeOutcome/requiresAppManagementPermission``) — authoritative, it is the
///   real operation failing for the real reason;
/// - the **preflight** probe (``AppManagementPermissionProbe``) — indicative only, and
///   never allowed to talk an observed denial back up into a success.
public enum AppManagementPermission: Equatable, Sendable {
    case granted
    case denied
    /// Nothing conclusive — no bundle was available to probe.
    case unknown
}

/// Where Wega sends the user to grant the permission.
public enum AppManagementSettings {
    /// System Settings → Privacy & Security → App Management.
    ///
    /// Deliberately *not* in `endpoints.json`: that file is overlaid by a user-writable
    /// copy, and the destination Wega points at to grant a privacy permission must not be
    /// redirectable. This is an OS pane identifier, not a vendor endpoint.
    public static let paneURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AppBundles"
    )!
}

/// What probing one bundle concluded.
public enum AppManagementProbeResult: Equatable, Sendable {
    case writable
    case permissionDenied
    /// Not answerable — the bundle is gone, unreadable for an unrelated reason, or the
    /// file the probe wanted does not exist.
    case unavailable
}

/// The optional preflight: ask *before* the first update whether the permission is in
/// place, instead of discovering it from a failed upgrade.
///
/// The decision is pure and unit-tested; the syscall and the directory listing are the
/// thin, untestable edges kept deliberately small.
public enum AppManagementPermissionProbe {
    /// How many bundles the live preflight is willing to touch. One clear answer is
    /// enough; a couple of spares only cover the case where the first is unreadable.
    public static let defaultProbeLimit = 3

    /// Folds per-bundle results into one verdict.
    ///
    /// A single refusal decides the whole thing: App Management is granted to Wega as a
    /// whole, so one `EPERM` is evidence of a missing grant, while a writable bundle may
    /// merely be one Wega itself installed and owns.
    public static func status(
        bundles: [URL],
        probe: (URL) -> AppManagementProbeResult
    ) -> AppManagementPermission {
        var sawWritable = false
        for bundle in bundles {
            switch probe(bundle) {
            case .permissionDenied: return .denied
            case .writable:         sawWritable = true
            case .unavailable:      continue
            }
        }
        return sawWritable ? .granted : .unknown
    }

    /// Which bundles are worth probing: installed applications that are not Wega itself.
    /// Sorted so two runs on the same machine probe the same bundles and a denial does
    /// not appear to come and go.
    public static func probeCandidates(
        in contents: [URL],
        excluding ownBundle: URL?,
        limit: Int = defaultProbeLimit
    ) -> [URL] {
        guard limit > 0 else { return [] }
        let own = ownBundle?.standardizedFileURL
        let candidates = contents
            .filter { $0.pathExtension == "app" && $0.standardizedFileURL != own }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        return Array(candidates.prefix(limit))
    }

    /// Non-destructive live probe: open a file *inside* the bundle for writing and close
    /// it immediately without writing a byte. App Management is enforced when the write
    /// handle is opened, so an `EPERM` here is the same refusal `ditto` hits mid-upgrade —
    /// and a success leaves the bundle byte-identical.
    public static func liveProbe(_ bundle: URL) -> AppManagementProbeResult {
        let target = bundle.appendingPathComponent("Contents/Info.plist").path
        guard FileManager.default.fileExists(atPath: target) else { return .unavailable }
        let descriptor = open(target, O_WRONLY)
        if descriptor >= 0 {
            close(descriptor)
            return .writable
        }
        return errno == EPERM || errno == EACCES ? .permissionDenied : .unavailable
    }

    /// The whole preflight, wired to the live filesystem. Returns ``AppManagementPermission/unknown``
    /// when `/Applications` cannot be listed at all.
    public static func liveStatus(
        applicationsDirectory: URL = URL(fileURLWithPath: "/Applications", isDirectory: true),
        ownBundle: URL? = Bundle.main.bundleURL
    ) -> AppManagementPermission {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: applicationsDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        return status(
            bundles: probeCandidates(in: contents, excluding: ownBundle),
            probe: liveProbe
        )
    }
}

/// Stops the unattended round from walking into the same refusal every interval.
///
/// A denied App Management grant is not transient: the round after it fails identically,
/// and so does the one after that — which is how a single missing permission turns into a
/// notification every scheduled check. Once the refusal is observed, background rounds are
/// held back until the cooldown expires, so the loop becomes one retry a day and the user's
/// grant is still picked up without anyone having to reset anything.
public struct AppManagementDenialGate: Equatable, Sendable {
    /// One day: long enough to stop being a loop, short enough to self-heal unattended.
    public static let retryCooldown: TimeInterval = 24 * 60 * 60

    public private(set) var deniedAt: Date?

    public init(deniedAt: Date? = nil) {
        self.deniedAt = deniedAt
    }

    public mutating func recordDenial(at date: Date) {
        deniedAt = date
    }

    public mutating func clear() {
        deniedAt = nil
    }

    public func allowsRound(now: Date) -> Bool {
        guard let deniedAt else { return true }
        let elapsed = now.timeIntervalSince(deniedAt)
        // A backwards clock jump must not strand the gate shut for longer than the
        // cooldown it agreed to.
        return elapsed >= Self.retryCooldown || elapsed < 0
    }
}

/// Persists ``AppManagementDenialGate`` across launches. A denial that only lived in
/// memory would come back on every relaunch — the exact loop the gate exists to close.
@MainActor
public final class AppManagementDenialStore: ObservableObject {
    public static let shared = AppManagementDenialStore()

    private static let defaultsKey = "wega.appManagement.deniedAt"

    private let defaults: UserDefaults

    @Published public private(set) var gate: AppManagementDenialGate

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.object(forKey: Self.defaultsKey) as? Date
        gate = AppManagementDenialGate(deniedAt: stored)
    }

    public func allowsRound(now: Date = Date()) -> Bool {
        gate.allowsRound(now: now)
    }

    public func recordDenial(at date: Date = Date()) {
        gate.recordDenial(at: date)
        defaults.set(date, forKey: Self.defaultsKey)
    }

    public func clear() {
        guard gate.deniedAt != nil else { return }
        gate.clear()
        defaults.removeObject(forKey: Self.defaultsKey)
    }
}
