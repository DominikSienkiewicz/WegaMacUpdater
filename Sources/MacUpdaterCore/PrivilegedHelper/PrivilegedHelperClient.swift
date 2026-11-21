import Foundation
import ServiceManagement
import WegaHelperKit

/// Client side of the privileged helper (**FEAT-01**): registers/unregisters the
/// daemon via `SMAppService` and brokers whitelisted root operations over a
/// signature-pinned XPC connection.
///
/// Honest UX note: `SMAppService.daemon` registration is **not** silent — on
/// first registration macOS requires the user to approve the item in
/// System Settings → Login Items (status `requiresApproval`). The "no password
/// per operation" win applies *after* that one-time approval.
///
/// SEC-10 hardening: every XPC call is bounded by a **deadline** (an unresponsive
/// or dead helper resolves to `HelperError.timedOut` instead of hanging the app).
/// Every privileged call is gated by a per-verb version handshake: the app sends a
/// verb only to a helper whose protocol version lies between that verb's minimum
/// and the app's own version, so it never drives a helper that predates the verb or
/// postdates the app.
public final class PrivilegedHelperClient: @unchecked Sendable {
    public static let shared = PrivilegedHelperClient()

    public enum Status: Equatable, Sendable {
        case notRegistered
        case requiresApproval
        case enabled
        case notFound
        case unknown
    }

    public enum HelperError: Error, LocalizedError {
        case notEnabled
        case teamIDNotConfigured
        case operationFailed(String)
        case connectionFailed
        case timedOut
        case versionMismatch(helper: String, expected: String)
        /// Z14: the bundle the app runs from fails `HelperBundleGate`, so the helper is neither
        /// registered nor used.
        case bundleNotTrusted(HelperBundleRefusal)

        public var errorDescription: String? {
            switch self {
            case .notEnabled:           return "Helper nie jest aktywny (wymaga rejestracji/zgody)."
            case .teamIDNotConfigured:  return "Team ID nie ustawiony w WegaHelper.teamIdentifier."
            case .operationFailed(let m): return m
            case .connectionFailed:     return "Nie udało się połączyć z helperem."
            case .timedOut:             return "Helper nie odpowiedział w wyznaczonym czasie."
            case .versionMismatch(let helper, let expected):
                return "Niezgodna wersja helpera (uruchomiony \(helper), oczekiwano \(expected)) — zarejestruj helper ponownie."
            case .bundleNotTrusted:
                return "Ta kopia Wegi nie może używać pomocnika: zainstaluj ją z podpisanego pakietu .pkg."
            }
        }
    }

    /// XPC observation deadlines. Installations return a durable ID immediately and
    /// are polled separately; a query timing out never means that the installer stopped.
    enum Deadline {
        static let handshake: Duration = .seconds(10)
        static let enableTouchID: Duration = .seconds(60)
        static let disableTouchID: Duration = .seconds(60)
        static let installationStatus: Duration = .seconds(10)
        static let replaceBundle: Duration = .seconds(600)
        /// The helper hands over every item of the bundle under one lock, so a large app takes
        /// a while; a timeout does not mean the app is still in `/Applications`.
        static let stageForTrash: Duration = .seconds(600)
    }

    /// The `SMAppService` registration, behind closures so tests stand in for it.
    struct Registration {
        var status: () -> Status
        var register: () throws -> Void
        var unregister: () async throws -> Void
    }

    private let registration: Registration
    private let trustCache: HelperBundleTrustCache
    private let machServiceName: String

    private convenience init() {
        let service = SMAppService.daemon(plistName: WegaHelper.plistName)
        self.init(
            registration: Registration(
                status: { Self.status(of: service.status) },
                register: { try service.register() },
                unregister: { try await service.unregister() }
            ),
            evaluateBundleTrust: { HelperBundleGate.live(bundlePath: Bundle.main.bundlePath) },
            machServiceName: WegaHelper.machServiceName
        )
    }

    init(registration: Registration, evaluateBundleTrust: @escaping () -> HelperBundleTrust, machServiceName: String) {
        self.registration = registration
        self.trustCache = HelperBundleTrustCache(evaluate: evaluateBundleTrust)
        self.machServiceName = machServiceName
    }

    // MARK: - Lifecycle (SMAppService)

    public var status: Status { registration.status() }

    private static func status(of status: SMAppService.Status) -> Status {
        switch status {
        case .notRegistered:    return .notRegistered
        case .enabled:          return .enabled
        case .requiresApproval: return .requiresApproval
        case .notFound:         return .notFound
        @unknown default:       return .unknown
        }
    }

    /// Z14: whether the bundle Wega runs from may host the root helper (`HelperBundleGate`). Kept
    /// once trusted, checked again while refused; see `HelperBundleTrustCache`.
    public var bundleTrust: HelperBundleTrust { trustCache.current }

    /// Registered, approved, and running from a bundle only root can change. Every caller that falls
    /// back when the helper is off falls back the same way when the bundle is refused.
    public var isEnabled: Bool { status == .enabled && bundleTrust == .trusted }

    /// Whether Uninstall may route a root-owned app to the helper. Read from the registration
    /// alone; the handshake that finds a stale helper is `uninstallAvailabilityAfterHandshake()`.
    public var uninstallAvailability: UninstallHelperAvailability {
        if case .refused = bundleTrust { return .untrustedBundle }
        return Self.uninstallAvailability(isEnabled: isEnabled)
    }

    static func uninstallAvailability(isEnabled: Bool) -> UninstallHelperAvailability {
        isEnabled ? .enabled : .off
    }

    /// Maps how a version handshake failed to what Uninstall may do with the helper.
    static func uninstallAvailability(handshakeFailure: Error) -> UninstallHelperAvailability {
        switch handshakeFailure as? HelperError {
        case .notEnabled: .off
        case .bundleNotTrusted: .untrustedBundle
        default: .stale
        }
    }

    /// One bounded handshake (the handshake deadline, and at most one retry after a dropped
    /// connection) before Uninstall promises the helper, so a stale or dead helper is found before
    /// Wega quits anything.
    public func uninstallAvailabilityAfterHandshake() async -> UninstallHelperAvailability {
        do {
            try await performHandshake(for: .stageApplicationBundleForTrash)
            return .enabled
        } catch {
            return Self.uninstallAvailability(handshakeFailure: error)
        }
    }

    /// Registers the daemon. May leave the service in `.requiresApproval` until
    /// the user toggles it on in System Settings. A bundle that fails `HelperBundleGate` is never
    /// registered: launchd would run the helper as root from files the user can replace.
    public func register() throws {
        if case .refused(let refusal) = bundleTrust { throw HelperError.bundleNotTrusted(refusal) }
        try registration.register()
    }

    public func unregister() async throws {
        try await registration.unregister()
    }

    /// Deep-links to System Settings → Login Items so the user can approve.
    public func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    // MARK: - Version handshake (SEC-10)

    /// Pure decision: may `verb` be sent to a helper that reported `reported`? Only when it is
    /// 1–4 ASCII digits naming a version between the verb's minimum and `current`, the app's own.
    /// Digits only, because `Int("+7") == 7`. Side-effect-free so it is unit tested directly.
    static func handshakeOutcome(
        reported: String, for verb: WegaHelperVerb, current: String = WegaHelper.version
    ) -> HandshakeOutcome {
        let minimum = WegaHelper.minimumHelperVersion(for: verb)
        let accepted = "\(minimum)…\(current)"
        guard let version = protocolVersion(reported), let newest = protocolVersion(current),
              minimum <= version, version <= newest else {
            return .mismatch(reported: reported, expected: accepted)
        }
        return .compatible
    }

    enum HandshakeOutcome: Equatable, Sendable {
        case compatible
        /// `expected` is the accepted range, such as `"6…7"`.
        case mismatch(reported: String, expected: String)
    }

    private static func protocolVersion(_ text: String) -> Int? {
        let digits = Array(text.utf8)
        guard (1...4).contains(digits.count), digits.allSatisfy({ (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) }) else {
            return nil
        }
        return Int(text)
    }

    /// The reported version when `verb` may be sent to it; `.versionMismatch` otherwise.
    static func acceptedVersion(
        reported: String, for verb: WegaHelperVerb, current: String = WegaHelper.version
    ) throws -> String {
        switch handshakeOutcome(reported: reported, for: verb, current: current) {
        case .compatible:
            return reported
        case .mismatch(let reported, let expected):
            throw HelperError.versionMismatch(helper: reported, expected: expected)
        }
    }

    /// Probes the running daemon's protocol version (bounded by the handshake deadline) and
    /// checks it against `verb`'s accepted range. A helper too old for the verb, or newer than the
    /// app, throws `.versionMismatch`; a dead one throws `.timedOut`. Runs before every privileged
    /// call below, each with its own verb.
    @discardableResult
    public func performHandshake(for verb: WegaHelperVerb) async throws -> String {
        try Self.acceptedVersion(reported: try await helperVersion(), for: verb)
    }

    /// One bounded handshake for `verb` (at most one retry after a dropped connection), so a screen
    /// can offer the verb only when the running helper will take it.
    public func availabilityAfterHandshake(for verb: WegaHelperVerb) async -> HelperVerbAvailability {
        do {
            try await performHandshake(for: verb)
            return .enabled
        } catch {
            return Self.verbAvailability(handshakeFailure: error)
        }
    }

    /// Not enabled, or a bundle the helper may not run from, reads as off; everything else (wrong
    /// version, no answer, a raw XPC error) as stale.
    static func verbAvailability(handshakeFailure: Error) -> HelperVerbAvailability {
        switch handshakeFailure as? HelperError {
        case .notEnabled, .bundleNotTrusted: .off
        default: .stale
        }
    }

    /// Whether a call failed because its connection dropped: the client's interruption or
    /// invalidation handler (`.connectionFailed`), or the proxy's raw XPC error, whichever came first.
    static func isDroppedConnection(_ error: Error) -> Bool {
        if case .connectionFailed = error as? HelperError { return true }
        let raw = error as NSError
        return raw.domain == NSCocoaErrorDomain
            && (raw.code == NSXPCConnectionInterrupted || raw.code == NSXPCConnectionInvalid)
    }

    /// RC2-3: runs `attempt` once more when its connection dropped, and never again after that.
    /// Only for the version probe: a helper idle for a minute may be exiting just as the first
    /// connection reaches it, and asking its version twice changes nothing. A verb may already have
    /// run on the helper, so no verb is ever sent twice.
    static func retryingOnceOnConnectionFailure<T>(_ attempt: () async throws -> T) async throws -> T {
        do {
            return try await attempt()
        } catch where isDroppedConnection(error) {
            return try await attempt()
        }
    }

    // MARK: - Whitelisted operations (XPC)

    public func helperVersion() async throws -> String {
        try await Self.retryingOnceOnConnectionFailure {
            try await call(deadline: Deadline.handshake) { (proxy, done: @escaping @Sendable (sending Result<String, Error>) -> Void) in
                proxy.helperVersion { version in done(.success(version)) }
            }
        }
    }

    /// Turns Touch ID for `sudo` on as root. A transport error or an unknown reply means the outcome
    /// is not known, and the caller reads the file again.
    public func enableTouchIDForSudo() async throws -> TouchIDSudoEnableResult {
        try await performHandshake(for: .enableTouchIDForSudo)
        return try await call(deadline: Deadline.enableTouchID) { (proxy, done: @escaping @Sendable (sending Result<TouchIDSudoEnableResult, Error>) -> Void) in
            proxy.enableTouchIDForSudoChecked { code, detail in
                done(Self.enableReply(code: code, detail: detail))
            }
        }
    }

    /// An unknown code, a detail on a code other than −21, or −21 with a path outside the policy
    /// directory is an operation failure that carries only the code: the detail is never passed on.
    static func enableReply(code: Int, detail: String?) -> Result<TouchIDSudoEnableResult, Error> {
        guard let result = TouchIDSudoEnableResult(wireCode: code, detail: detail) else {
            return .failure(HelperError.operationFailed("enableTouchIDForSudo failed (\(code))"))
        }
        return .success(result)
    }

    /// Removes the exact Touch ID directive from `sudo_local` as root. A transport error or an
    /// unknown reply means the outcome is not known, and the caller reads the file again.
    public func disableTouchIDForSudo() async throws -> TouchIDSudoDisableResult {
        try await performHandshake(for: .disableTouchIDForSudo)
        return try await call(deadline: Deadline.disableTouchID) { (proxy, done: @escaping @Sendable (sending Result<TouchIDSudoDisableResult, Error>) -> Void) in
            proxy.disableTouchIDForSudo { code, detail in
                done(Self.disableReply(code: code, detail: detail))
            }
        }
    }

    /// An unknown code, or −21 with a path outside the policy directory, is an operation failure
    /// that carries only the code: the path is never passed on.
    static func disableReply(code: Int, detail: String?) -> Result<TouchIDSudoDisableResult, Error> {
        guard let result = TouchIDSudoDisableResult(wireCode: code, detail: detail) else {
            return .failure(HelperError.operationFailed("disableTouchIDForSudo failed (\(code))"))
        }
        return .success(result)
    }

    public func installVerifiedPackage(at path: String, version: String) async throws {
        try await trackedInstaller.install(at: path, version: version)
    }

    public func reconcilePackageInstallation() async throws -> PendingHelperInstallation? {
        try await trackedInstaller.reconcile()
    }

    private var trackedInstaller: HelperPackageInstallation {
        HelperPackageInstallation(
            handshake: { _ = try await self.performHandshake(for: .beginPackageInstallation) },
            statusHandshake: { _ = try await self.performHandshake(for: .packageInstallationStatus) },
            begin: { id, path, version in
                try await self.installationReply { proxy, reply in
                    proxy.beginPackageInstallation(atPath: path, operationID: id.uuidString, expectedVersion: version, withReply: reply)
                }
            },
            status: { id in
                try await self.installationReply { proxy, reply in
                    proxy.packageInstallationStatus(operationID: id.uuidString, withReply: reply)
                }
            },
            verifyInstalled: { version in
                try CodeSignatureVerifier.verify(
                    installerAt: PackagePayloadVerifier.installedAppURL, expectedTeamID: WegaHelper.teamIdentifier,
                    bundleID: WegaHelper.appBundleID, expectedVersion: version
                )
            }
        )
    }

    private func installationReply(
        _ request: @escaping @Sendable (WegaPrivilegedOps, @escaping @Sendable (Data?, String?) -> Void) -> Void
    ) async throws -> PackageInstallationStatus {
        let data: Data = try await call(deadline: Deadline.installationStatus) { proxy, done in
            request(proxy) { data, error in
                if let data { done(.success(data)) }
                else { done(.failure(HelperError.operationFailed(error ?? "Nie można odczytać stanu instalacji."))) }
            }
        }
        return try JSONDecoder().decode(PackageInstallationStatus.self, from: data)
    }

    /// FEAT-05: atomic bundle rollback as root (protected locations).
    public func replaceBundle(at targetPath: String, withSnapshotAt snapshotPath: String) async throws {
        try await performHandshake(for: .replaceBundle)
        _ = try await call(deadline: Deadline.replaceBundle) { (proxy, done: @escaping @Sendable (sending Result<Bool, Error>) -> Void) in
            proxy.replaceBundle(atPath: targetPath, withSnapshotAtPath: snapshotPath) { ok, message in
                done(ok ? .success(true) : .failure(HelperError.operationFailed(message ?? "replaceBundle failed")))
            }
        }
    }

    /// Uninstall: has the helper move a root-owned application out of `/Applications` into a
    /// staging slot owned by this user, and returns where the bundle now is. The caller puts it
    /// in the Trash as the user.
    ///
    /// - Throws: `StagingFailure`, whose `requestSent` tells a failure of the handshake (nothing
    ///   was sent: a stale, unregistered or silent helper) from a failure of the staging request
    ///   itself. After the request, `.timedOut` or `.connectionFailed` (or a raw XPC error) means
    ///   no answer came back, so the app may already have left `/Applications`;
    ///   `.operationFailed` carries the helper's reason for refusing or moving nothing.
    public func stageApplicationBundleForTrash(at path: URL, expectedBundleID: String) async throws -> URL {
        do {
            try await performHandshake(for: .stageApplicationBundleForTrash)
        } catch {
            throw StagingFailure(underlying: error, requestSent: false)
        }
        do {
            return try await call(deadline: Deadline.stageForTrash) { (proxy, done: @escaping @Sendable (sending Result<URL, Error>) -> Void) in
                proxy.stageApplicationBundleForTrash(atPath: path.path, expectedBundleID: expectedBundleID) { stagedPath, note in
                    done(Self.stagingReply(stagedPath: stagedPath, note: note))
                }
            }
        } catch {
            throw StagingFailure(underlying: error, requestSent: true)
        }
    }

    /// A staged path is the result even with a note: the note only says that some items stayed
    /// root-owned, which the helper records in its own log.
    static func stagingReply(stagedPath: String?, note: String?) -> Result<URL, Error> {
        guard let stagedPath else {
            return .failure(HelperError.operationFailed(note ?? "stageApplicationBundleForTrash failed"))
        }
        return .success(URL(fileURLWithPath: stagedPath))
    }

    /// Why staging failed, and whether it failed before the staging request was sent (the
    /// handshake) or after. `underlying` is the client's `HelperError` or a raw XPC error.
    public struct StagingFailure: Error {
        public let underlying: Error
        public let requestSent: Bool

        public init(underlying: Error, requestSent: Bool) {
            self.underlying = underlying
            self.requestSent = requestSent
        }
    }

    // MARK: - XPC plumbing

    /// One-shot connection per call: connect, pin the helper's signature, run the
    /// verb, tear down. `body` must invoke `done` exactly conceptually-once; the
    /// `Once` box guarantees the continuation can't be resumed twice (which would
    /// crash) even if the reply, an error, an invalidation, and the deadline all
    /// fire. `deadline` bounds the wait: an unresponsive helper resolves to
    /// `HelperError.timedOut` and the connection is torn down (SEC-10).
    private func call<T: Sendable>(
        deadline: Duration,
        _ body: @escaping @Sendable (_ proxy: WegaPrivilegedOps, _ done: @escaping @Sendable (sending Result<T, Error>) -> Void) -> Void
    ) async throws -> T {
        if case .refused(let refusal) = bundleTrust { throw HelperError.bundleNotTrusted(refusal) }
        guard status == .enabled else { throw HelperError.notEnabled }

        let connection = NSXPCConnection(machServiceName: machServiceName, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: WegaPrivilegedOps.self)
        // Pin the daemon we talk to (macOS 13+). Kernel validates via audit token.
        connection.setCodeSigningRequirement(WegaHelper.helperRequirement())
        // NSXPCConnection isn't Sendable; the box lets the @Sendable XPC handlers
        // reference it without tripping Swift 6 strict-concurrency capture rules.
        let box = ConnectionBox(connection)

        return try await awaitReplyWithDeadline(
            timeout: deadline,
            onTimeout: { box.connection.invalidate() },
            body: { done in
            connection.invalidationHandler = { done(.failure(HelperError.connectionFailed)) }
            connection.interruptionHandler = { done(.failure(HelperError.connectionFailed)) }
            connection.resume()

            let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                done(.failure(error))
                box.connection.invalidate()
            }
            guard let ops = proxy as? WegaPrivilegedOps else {
                done(.failure(HelperError.connectionFailed))
                box.connection.invalidate()
                return
            }
            body(ops) { result in
                done(result)
                box.connection.invalidate()
            }
        })
    }
}

/// Whether a privileged verb may be sent to the running helper, after one bounded handshake.
public enum HelperVerbAvailability: Equatable, Sendable {
    case enabled
    /// The helper is not registered or not approved.
    case off
    /// The helper predates the verb, postdates the app, or did not answer.
    case stale
}

/// Z14, design §3: once the bundle is trusted the answer is kept for the process; a refusal is
/// evaluated again on every read.
///
/// A root-owned bundle cannot become writable to the user without root, so a kept "trusted" cannot
/// go stale through user-level code. Checking it per call instead would read the bundle while a
/// helper-driven pkg install replaces it: one transient refusal on a status poll turns the install
/// into an unknown outcome that blocks every change. Checking a refusal again lets a transient one
/// heal and picks up a pkg installed over a dragged copy.
final class HelperBundleTrustCache: @unchecked Sendable {
    private let lock = NSLock()
    private var trusted = false
    private let evaluate: () -> HelperBundleTrust

    init(evaluate: @escaping () -> HelperBundleTrust) {
        self.evaluate = evaluate
    }

    var current: HelperBundleTrust {
        lock.lock()
        defer { lock.unlock() }
        if trusted { return .trusted }
        let answer = evaluate()
        trusted = answer == .trusted
        return answer
    }
}

/// Wraps a non-Sendable `NSXPCConnection` so escaping `@Sendable` XPC handlers
/// can invalidate it under Swift 6 strict concurrency.
private final class ConnectionBox: @unchecked Sendable {
    let connection: NSXPCConnection
    init(_ connection: NSXPCConnection) { self.connection = connection }
}

/// Resume-once wrapper around a `CheckedContinuation` — double-resume is a hard
/// crash, and XPC can fire both a reply and an invalidation. `resume` reports
/// whether *this* call was the one that resumed, so the deadline race can cancel
/// the loser (SEC-10).
private final class Once<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    private let continuation: CheckedContinuation<T, Error>

    init(_ continuation: CheckedContinuation<T, Error>) { self.continuation = continuation }

    @discardableResult
    func resume(_ result: sending Result<T, Error>) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !done else { return false }
        done = true
        continuation.resume(with: result)
        return true
    }
}

/// Runs a reply-callback-style operation but resolves with `HelperError.timedOut`
/// if the reply does not arrive within `timeout`. `body` registers a completion
/// path and calls the supplied `done` when the reply (or an error) arrives;
/// `onTimeout` fires exactly once, and only when the deadline wins the race, so
/// the caller can tear down a dead connection. The continuation is resumed
/// exactly once even if a late reply arrives after the deadline — this is what
/// turns an unresponsive helper into a bounded error instead of a hang (SEC-10).
///
/// Deliberately free of any XPC dependency so the deadline behaviour is unit
/// tested directly (see PrivilegedHelperDeadlineTests).
func awaitReplyWithDeadline<T: Sendable>(
    timeout: Duration,
    onTimeout: @escaping @Sendable () -> Void = {
        // Callers without connection state have nothing to tear down after a timeout.
    },
    body: (_ done: @escaping @Sendable (sending Result<T, Error>) -> Void) -> Void
) async throws -> T {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
        let once = Once(continuation)
        let timeoutTask = Task {
            try? await Task.sleep(for: timeout)
            if once.resume(.failure(PrivilegedHelperClient.HelperError.timedOut)) {
                onTimeout()
            }
        }
        let done: @Sendable (sending Result<T, Error>) -> Void = { result in
            if once.resume(result) {
                timeoutTask.cancel()
            }
        }
        body(done)
    }
}
