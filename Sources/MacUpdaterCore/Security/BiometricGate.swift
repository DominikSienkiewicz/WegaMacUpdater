import Foundation
import LocalAuthentication

/// In-app biometric gate for critical actions (**ICE-01 / D4**).
///
/// Distinct from the app's *other* Touch ID usage: `TouchIDSudoConfigurator`
/// wires `pam_tid` into `sudo` (system-level). This gate is for app-level
/// destructive actions that do **not** otherwise pass through `sudo` — e.g.
/// removing the privileged helper — where we want an explicit "prove it's you".
///
/// Two refinements over a naive `evaluatePolicy`:
/// - **Reuse window** via `touchIDAuthenticationAllowableReuseDuration` so a user
///   who just unlocked isn't prompted twice in quick succession.
/// - **Enrollment-change detection** via the non-deprecated
///   `LAContext.domainState.biometry.stateHash` (macOS 15+). If a new finger/face
///   was enrolled since the last successful gate, reuse is suppressed and a fresh
///   prompt is forced. (The old `evaluatedPolicyDomainState` is deprecated.)
public final class BiometricGate: @unchecked Sendable {
    public static let shared = BiometricGate()

    public enum GateResult: Equatable, Sendable {
        case success
        case unavailable        // no biometrics / policy can't be evaluated → caller decides
        case cancelled
        case failed(String)
    }

    private let defaultsKey = "wega.biometricStateHash.v1"
    private let defaults: UserDefaults
    private let reuseDuration: TimeInterval

    public init(defaults: UserDefaults = .standard, reuseDuration: TimeInterval = 30) {
        self.defaults = defaults
        self.reuseDuration = reuseDuration
    }

    /// Pure policy: force a fresh prompt (suppress reuse) when the enrollment hash
    /// changed vs. the stored baseline. First run (no baseline) does not force.
    /// A nil current hash against a stored one is treated as "changed" (fail-safe).
    public static func shouldForceFreshAuth(storedHash: Data?, currentHash: Data?) -> Bool {
        guard let storedHash else { return false }
        return storedHash != currentHash
    }

    /// Prompts the device owner (Touch ID, with password fallback) for `reason`.
    /// Returns `.unavailable` when biometrics/policy aren't usable so callers can
    /// choose to proceed (don't lock users without Touch ID out of their own app).
    public func authenticate(reason: String) async -> GateResult {
        let context = LAContext()
        var policyError: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &policyError) else {
            return .unavailable
        }

        let currentHash = currentEnrollmentHash(context)
        let storedHash = defaults.data(forKey: defaultsKey)
        context.touchIDAuthenticationAllowableReuseDuration =
            Self.shouldForceFreshAuth(storedHash: storedHash, currentHash: currentHash) ? 0 : reuseDuration

        do {
            let ok: Bool = try await withCheckedThrowingContinuation { continuation in
                context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, error in
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume(returning: success) }
                }
            }
            guard ok else { return .failed("Authentication returned false") }
            if let currentHash { defaults.set(currentHash, forKey: defaultsKey) } // refresh baseline
            return .success
        } catch let laError as LAError {
            switch laError.code {
            case .userCancel, .appCancel, .systemCancel:
                return .cancelled
            default:
                return .failed(laError.localizedDescription)
            }
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// Current biometric enrollment hash via the modern API (macOS 15+); nil on
    /// older systems or when no biometry is enrolled → change detection simply
    /// degrades to plain reuse behaviour.
    private func currentEnrollmentHash(_ context: LAContext) -> Data? {
        if #available(macOS 15.0, *) {
            return context.domainState?.biometry.stateHash
        }
        return nil
    }
}
