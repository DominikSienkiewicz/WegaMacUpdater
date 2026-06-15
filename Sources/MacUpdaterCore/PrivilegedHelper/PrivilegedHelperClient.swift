import Foundation
import ServiceManagement

/// Client side of the privileged helper (**FEAT-01**): registers/unregisters the
/// daemon via `SMAppService` and brokers whitelisted root operations over a
/// signature-pinned XPC connection.
///
/// Honest UX note: `SMAppService.daemon` registration is **not** silent — on
/// first registration macOS requires the user to approve the item in
/// System Settings → Login Items (status `requiresApproval`). The "no password
/// per operation" win applies *after* that one-time approval.
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

        public var errorDescription: String? {
            switch self {
            case .notEnabled:           return "Helper nie jest aktywny (wymaga rejestracji/zgody)."
            case .teamIDNotConfigured:  return "Team ID nie ustawiony w WegaHelper.teamIdentifier."
            case .operationFailed(let m): return m
            case .connectionFailed:     return "Nie udało się połączyć z helperem."
            }
        }
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

    // MARK: - Whitelisted operations (XPC)

    public func helperVersion() async throws -> String {
        try await call { (proxy, done: @escaping @Sendable (Result<String, Error>) -> Void) in
            proxy.helperVersion { version in done(.success(version)) }
        }
    }

    public func enableTouchIDForSudo() async throws {
        _ = try await call { (proxy, done: @escaping @Sendable (Result<Bool, Error>) -> Void) in
            proxy.enableTouchIDForSudo { ok, message in
                done(ok ? .success(true) : .failure(HelperError.operationFailed(message ?? "enableTouchIDForSudo failed")))
            }
        }
    }

    public func installVerifiedPackage(at path: String) async throws {
        _ = try await call { (proxy, done: @escaping @Sendable (Result<Bool, Error>) -> Void) in
            proxy.installVerifiedPackage(atPath: path) { ok, message in
                done(ok ? .success(true) : .failure(HelperError.operationFailed(message ?? "installVerifiedPackage failed")))
            }
        }
    }

    // MARK: - XPC plumbing

    /// One-shot connection per call: connect, pin the helper's signature, run the
    /// verb, tear down. `body` must invoke `done` exactly conceptually-once; the
    /// `Once` box guarantees the continuation can't be resumed twice (which would
    /// crash) even if both the error handler and the reply fire.
    private func call<T: Sendable>(
        _ body: @escaping @Sendable (_ proxy: WegaPrivilegedOps, _ done: @escaping @Sendable (Result<T, Error>) -> Void) -> Void
    ) async throws -> T {
        guard isEnabled else { throw HelperError.notEnabled }

        let connection = NSXPCConnection(machServiceName: WegaHelper.machServiceName, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: WegaPrivilegedOps.self)
        // Pin the daemon we talk to (macOS 13+). Kernel validates via audit token.
        connection.setCodeSigningRequirement(WegaHelper.helperRequirement())
        // NSXPCConnection isn't Sendable; the box lets the @Sendable XPC handlers
        // reference it without tripping Swift 6 strict-concurrency capture rules.
        let box = ConnectionBox(connection)

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
            let once = Once(continuation)
            connection.invalidationHandler = { once.resume(.failure(HelperError.connectionFailed)) }
            connection.interruptionHandler = { once.resume(.failure(HelperError.connectionFailed)) }
            connection.resume()

            let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                once.resume(.failure(error))
                box.connection.invalidate()
            }
            guard let ops = proxy as? WegaPrivilegedOps else {
                once.resume(.failure(HelperError.connectionFailed))
                connection.invalidate()
                return
            }
            body(ops) { result in
                once.resume(result)
                box.connection.invalidate()
            }
        }
    }
}

/// Wraps a non-Sendable `NSXPCConnection` so escaping `@Sendable` XPC handlers
/// can invalidate it under Swift 6 strict concurrency.
private final class ConnectionBox: @unchecked Sendable {
    let connection: NSXPCConnection
    init(_ connection: NSXPCConnection) { self.connection = connection }
}

/// Resume-once wrapper around a `CheckedContinuation` — double-resume is a hard
/// crash, and XPC can fire both a reply and an invalidation.
private final class Once<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    private let continuation: CheckedContinuation<T, Error>

    init(_ continuation: CheckedContinuation<T, Error>) { self.continuation = continuation }

    func resume(_ result: Result<T, Error>) {
        lock.lock(); defer { lock.unlock() }
        guard !done else { return }
        done = true
        continuation.resume(with: result)
    }
}
