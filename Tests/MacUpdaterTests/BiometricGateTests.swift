import Testing
import Foundation
@testable import MacUpdaterCore

/// ICE-01 — the enrollment-change decision is the security-critical, pure part
/// (the actual `evaluatePolicy` prompt needs a real device + Touch ID).
@Suite("BiometricGate")
struct BiometricGateTests {
    @Test func forcesFreshAuthOnlyWhenEnrollmentChanged() {
        let a = Data([1, 2, 3])
        let b = Data([4, 5, 6])
        // First run (no baseline) → don't force; reuse window applies.
        #expect(BiometricGate.shouldForceFreshAuth(storedHash: nil, currentHash: a) == false)
        // Same enrollment → don't force.
        #expect(BiometricGate.shouldForceFreshAuth(storedHash: a, currentHash: a) == false)
        // New finger/face enrolled → force a fresh prompt.
        #expect(BiometricGate.shouldForceFreshAuth(storedHash: a, currentHash: b) == true)
        // Can't read current hash but had a baseline → fail-safe to fresh prompt.
        #expect(BiometricGate.shouldForceFreshAuth(storedHash: a, currentHash: nil) == true)
    }
}
