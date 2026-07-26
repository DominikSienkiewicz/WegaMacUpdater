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
/// or dead helper resolves to `HelperError.timedOut` instead of hanging the app),
/// and every privileged mutation is gated by a **version handshake** so the app
/// never drives a stale helper left behind by an update.
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

        public var errorDescription: String? {
            switch self {
            case .notEnabled:           return "Helper nie jest aktywny (wymaga rejestracji/zgody)."
            case .teamIDNotConfigured:  return "Team ID nie ustawiony w WegaHelper.teamIdentifier."
            case .operationFailed(let m): return m
            case .connectionFailed:     return "Nie udało się połączyć z helperem."
            case .timedOut:             return "Helper nie odpowiedział w wyznaczonym czasie."
            case .versionMismatch(let helper, let expected):
                return "Niezgodna wersja helpera (uruchomiony \(helper), oczekiwano \(expected)) — zarejestruj helper ponownie."
            }
        }
    }

    /// Per-operation XPC deadlines. The handshake/version probe is short (a dead
    /// helper should be detected fast); the mutating verbs are generous because
    /// the helper runs a real installer / bundle copy before replying — but they
    /// are still finite, so a hung daemon can never block the app forever.
    private enum Deadline {
        static let handshake: Duration = .seconds(10)
        static let enableTouchID: Duration = .seconds(60)
        static let installPackage: Duration = .seconds(1800)
        static let replaceBundle: Duration = .seconds(600)
    }

    private let service: SMAppService

    private init() {
        self.service = SMAppService.daemon(plistName: WegaHelper.plistName)
    }

    // MARK: - Lifecycle (SMAppService)

    public var status: Status {
        switch service.status {
        case .notRegistered:    return .notRegistered
        case .enabled:          return .enabled
        case .requiresApproval: return .requiresApproval
        case .notFound:         return .notFound
        @unknown default:       return .unknown
        }
    }

    public var isEnabled: Bool { status == .enabled }

    /// Registers the daemon. May leave the service in `.requiresApproval` until
    /// the user toggles it on in System Settings.
    public func register() throws {
        try service.register()
    }

    public func unregister() async throws {
        try await service.unregister()
    }

    /// Deep-links to System Settings → Login Items so the user can approve.
    public func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    // MARK: - Version handshake (SEC-10)

    /// Pure decision: does the version the running helper reported match the one
    /// this app build was compiled against? Kept side-effect-free so it is unit
    /// tested directly (the version-comparison logic is the part worth pinning).
    static func handshakeOutcome(reported: String, expected: String = WegaHelper.version) -> HandshakeOutcome {
        reported == expected ? .compatible : .mismatch(reported: reported, expected: expected)
    }

    enum HandshakeOutcome: Equatable, Sendable {
        case compatible
        case mismatch(reported: String, expected: String)
    }

    /// Probes the running daemon's protocol version (bounded by the handshake
    /// deadline) and verifies it matches the version this app expects. A stale
    /// helper throws `.versionMismatch`; a dead one throws `.timedOut`. Exposed so
    /// callers can validate the helper explicitly, and run before every privileged
    /// mutation below.
    @discardableResult
    public func performHandshake() async throws -> String {
        let reported = try await helperVersion()
        switch Self.handshakeOutcome(reported: reported) {
        case .compatible:
            return reported
        case .mismatch(let reported, let expected):
            throw HelperError.versionMismatch(helper: reported, expected: expected)
        }
    }

    // MARK: - Whitelisted operations (XPC)

    public func helperVersion() async throws -> String {
        try await call(deadline: Deadline.handshake) { (proxy, done: @escaping @Sendable (sending Result<String, Error>) -> Void) in
            proxy.helperVersion { version in done(.success(version)) }
        }
    }

    public func enableTouchIDForSudo() async throws {
        try await performHandshake()
        _ = try await call(deadline: Deadline.enableTouchID) { (proxy, done: @escaping @Sendable (sending Result<Bool, Error>) -> Void) in
            proxy.enableTouchIDForSudo { ok, message in
                done(ok ? .success(true) : .failure(HelperError.operationFailed(message ?? "enableTouchIDForSudo failed")))
            }
        }
    }

    public func installVerifiedPackage(at path: String) async throws {
        try await performHandshake()
        _ = try await call(deadline: Deadline.installPackage) { (proxy, done: @escaping @Sendable (sending Result<Bool, Error>) -> Void) in
            proxy.installVerifiedPackage(atPath: path) { ok, message in
                done(ok ? .success(true) : .failure(HelperError.operationFailed(message ?? "installVerifiedPackage failed")))
            }
        }
    }

    /// FEAT-05: atomic bundle rollback as root (protected locations).
    public func replaceBundle(at targetPath: String, withSnapshotAt snapshotPath: String) async throws {
        try await performHandshake()
        _ = try await call(deadline: Deadline.replaceBundle) { (proxy, done: @escaping @Sendable (sending Result<Bool, Error>) -> Void) in
            proxy.replaceBundle(atPath: targetPath, withSnapshotAtPath: snapshotPath) { ok, message in
                done(ok ? .success(true) : .failure(HelperError.operationFailed(message ?? "replaceBundle failed")))
            }
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
        guard isEnabled else { throw HelperError.notEnabled }

        let connection = NSXPCConnection(machServiceName: WegaHelper.machServiceName, options: .privileged)
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
    onTimeout: @escaping @Sendable () -> Void = {},
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
