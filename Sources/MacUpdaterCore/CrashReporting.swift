import Combine
import Foundation

/// LT-05 — the system source of crash and hang diagnostics, behind a protocol.
///
/// The only production conformer is the MetricKit subscriber in the app target. Keeping the
/// seam here means the decision logic — is the user opted in, what gets parsed, what gets
/// kept, what gets thrown away — is exercised in a unit test with a stand-in source, without
/// MetricKit, without a real crash, and without waiting for the system to deliver anything.
///
/// A conformer must deliver **nothing** until ``startDelivering(to:)`` is called and must
/// stop the moment ``stopDelivering()`` is: that call pair *is* the opt-in.
public protocol CrashDiagnosticSource: AnyObject {
    /// Subscribes to the system's diagnostic feed. `handler` receives the payload's JSON
    /// serialisation, on the main actor.
    func startDelivering(to handler: @escaping @MainActor @Sendable (Data) -> Void)

    /// Unsubscribes. After this returns, the handler must not be called again.
    func stopDelivering()
}

/// LT-05 — the opt-in gate and ledger for crash reporting.
///
/// # Privacy contract
///
/// 1. **Off by default.** No diagnostic is collected until the user turns the switch on in
///    Settings; ``setEnabled(_:)`` is the only thing that subscribes to the system source.
/// 2. **Nothing leaves the Mac.** There is no endpoint, no upload, no "anonymous statistics"
///    escape hatch — not even an opt-out one. Reports are written to the same owner-only
///    directory as `wega.log` and go somewhere else only if the user copies them there.
/// 3. **Nothing retroactive.** Turning the switch on subscribes from that moment forward.
///    MetricKit can also hand over diagnostics recorded *before* consent
///    (`pastDiagnosticPayloads`); Wega does not ask for them, because "I agree from now on"
///    is not agreement to a backlog.
/// 4. **Redacted, bounded, revocable.** Every stored field passes ``LogRedaction``; the store
///    keeps at most a few recent reports; the user can delete all of them at any time.
@MainActor
public final class CrashReportingController: ObservableObject {
    public static let shared = CrashReportingController()

    static let defaultsKey = "wega.crashReporting.optIn.v1"

    private let store: CrashDiagnosticStore
    private let defaults: UserDefaults
    private let now: () -> Date
    private var source: CrashDiagnosticSource?

    /// Whether the user has opted in. Absent from `UserDefaults` on a fresh install, which
    /// reads as `false` — collection is off until it is switched on deliberately.
    @Published public private(set) var isEnabled: Bool

    /// Stored reports, newest first.
    @Published public private(set) var records: [CrashDiagnosticRecord]

    public init(
        source: CrashDiagnosticSource? = nil,
        store: CrashDiagnosticStore = .shared,
        defaults: UserDefaults = .standard,
        now: @escaping () -> Date = Date.init
    ) {
        self.source = source
        self.store = store
        self.defaults = defaults
        self.now = now
        self.isEnabled = defaults.bool(forKey: Self.defaultsKey)
        self.records = store.records()
        if isEnabled { subscribeToSource() }
    }

    /// Hands the controller its system source once the app is up. The singleton is created
    /// before the app delegate runs, so the MetricKit subscriber — which lives in the app
    /// target, the only place allowed to import MetricKit — is attached here rather than
    /// injected at construction. Attaching starts delivery only if the user already opted in.
    public func attach(source: CrashDiagnosticSource) {
        guard self.source !== source else { return }
        self.source?.stopDelivering()
        self.source = source
        if isEnabled { subscribeToSource() }
    }

    public func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        defaults.set(enabled, forKey: Self.defaultsKey)
        if enabled {
            subscribeToSource()
            WegaLog.info(.app, "Raportowanie awarii (MetricKit) włączone — raporty zostają lokalnie.")
        } else {
            source?.stopDelivering()
            WegaLog.info(.app, "Raportowanie awarii (MetricKit) wyłączone.")
        }
    }

    /// Deletes every stored report. Independent of the switch: a user can stop collecting and
    /// keep what they have, or keep collecting and wipe the history.
    public func clearRecords() {
        store.clear()
        records = []
        WegaLog.info(.app, "Usunięto zapisane raporty awarii.")
    }

    /// The whole local history as copyable text.
    public var reportText: String { store.reportText() }

    private func subscribeToSource() {
        source?.startDelivering { [weak self] data in
            self?.receive(payloadJSON: data)
        }
    }

    /// The one entry point for delivered data. Guarded a second time on ``isEnabled``: a
    /// system source that keeps talking after `stopDelivering()` must not be able to write
    /// anything into the store.
    func receive(payloadJSON: Data) {
        guard isEnabled else { return }
        let parsed = CrashDiagnosticPayloadParser.records(fromPayloadJSON: payloadJSON, receivedAt: now())
        let added = store.ingest(parsed)
        guard !added.isEmpty else { return }
        records = store.records()
        for record in added {
            WegaLog.warning(.app, "Raport awarii Wegi: \(record.headline)")
        }
    }
}
