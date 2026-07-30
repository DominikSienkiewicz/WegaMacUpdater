import Foundation
import MacUpdaterCore
import MetricKit

/// LT-05 — the entire system-facing half of crash reporting: subscribe to MetricKit, hand the
/// payload's JSON to Core, unsubscribe. Every decision about what that JSON becomes lives in
/// `CrashDiagnosticPayloadParser` / `CrashDiagnosticStore`, which know nothing about MetricKit
/// and are testable without it.
///
/// Only MetricKit's optional diagnostic callback is implemented. Omitting its metric callback
/// keeps launch, battery, display and memory telemetry outside the collection path entirely.
///
/// # Why MetricKit, and what it can and cannot do here
///
/// `MXMetricManager` is available on macOS 12+ and delivers diagnostics **on device, to the
/// app itself**, with no entitlement, no `Info.plist` key and no dependency on the App Store:
/// Xcode Organizer's crash aggregation is App-Store-only, but this path is not, so a
/// Developer-ID-signed, notarized Wega does receive its own crash reports. Delivery is
/// immediate on macOS 12+ rather than batched with the daily metric payload.
///
/// Two real limits are worth knowing, because they decide what this feature can promise:
///
///   * **Payloads are delivered to a *running* app.** A crash is reported on the next launch,
///     so a crash that happens on *every* launch never reports itself. The `.ips` files macOS
///     writes to the user's own diagnostic-reports folder remain the backstop for that case.
///   * **`metrickitd` is a launchd *agent*.** Delivery needs a user login session; a daemon
///     or system-extension context would get nothing. Wega is a normal GUI app, so this is
///     satisfied — but it is why the subscription is made from the app, not the helper.
///
/// The `MX*` API is annotated `API_TO_BE_DEPRECATED` in favour of the Swift `MetricManager`
/// (async sequences), which is macOS 27+ and therefore unavailable at this project's macOS 26
/// deployment target. `MXMetricManager` is the correct call today and emits no deprecation
/// warning; the swap becomes possible when the floor rises.
final class MetricKitCrashDiagnosticSource: NSObject, CrashDiagnosticSource, MXMetricManagerSubscriber, @unchecked Sendable {
    /// MetricKit invokes subscriber callbacks on a background queue, so the handler is read
    /// and written under a lock rather than assumed to be main-thread-confined.
    private let lock = NSLock()
    private var handler: (@MainActor @Sendable (Data) -> Void)?
    private var isSubscribed = false

    // MARK: - CrashDiagnosticSource

    func startDelivering(to handler: @escaping @MainActor @Sendable (Data) -> Void) {
        lock.lock()
        self.handler = handler
        let alreadySubscribed = isSubscribed
        isSubscribed = true
        lock.unlock()

        guard !alreadySubscribed else { return }
        MXMetricManager.shared.add(self)
        // Deliberately *not* draining `MXMetricManager.shared.pastDiagnosticPayloads`:
        // consent given now is consent from now on, not permission to sweep up crashes
        // recorded before the switch was turned on.
    }

    func stopDelivering() {
        lock.lock()
        handler = nil
        let wasSubscribed = isSubscribed
        isSubscribed = false
        lock.unlock()

        guard wasSubscribed else { return }
        MXMetricManager.shared.remove(self)
    }

    // MARK: - MXMetricManagerSubscriber

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        let documents = payloads.map { $0.jsonRepresentation() }
        lock.lock()
        let handler = self.handler
        lock.unlock()

        guard let handler, !documents.isEmpty else { return }
        Task { @MainActor in
            for document in documents { handler(document) }
        }
    }
}
