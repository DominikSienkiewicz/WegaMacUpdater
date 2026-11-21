import Foundation
import Testing
import WegaHelperKit
@testable import MacUpdaterCore

/// Owner decision 2026-11-21 (Z12): while the Touch ID card's checks say the settings `sudo` reads
/// cannot be trusted, Wega asks for no administrator password itself. One gate gives that answer,
/// with the card's own rule.
@Suite("Sudo password prompt gate")
struct SudoPasswordPromptGateTests {
    private static func preflight(refusal: TouchIDSudoDisableRefusal? = nil, safe: Bool = true,
                                  sudoFileUnsafe: Bool = false) -> TouchIDDisablePreflight {
        TouchIDDisablePreflight(refusal: refusal, unsafeLocalDirectory: nil, fallbackPath: nil,
                                commandsAreSafe: safe, sudoPolicyIsUnsafe: sudoFileUnsafe)
    }

    // MARK: The card's rule

    @Test func proofOfSafetyAndNothingReportedLeavesNoReason() {
        #expect(Self.preflight().recoveryOnlyReason(helperReported: nil) == nil)
    }

    @Test func aRefusalTheAppSawComesFirst() {
        let seen = Self.preflight(refusal: .notRegularFile, safe: false, sudoFileUnsafe: true)
        #expect(seen.recoveryOnlyReason(helperReported: .unsafeOwnership) == .unsafePolicy(.notRegularFile))
    }

    @Test func aRefusalTheHelperReportedClosesASafeLook() {
        #expect(Self.preflight().recoveryOnlyReason(helperReported: .unsafeOwnership) == .unsafePolicy(.unsafeOwnership))
    }

    @Test func anUnsafeSudoFileComesBeforeMissingProof() {
        #expect(Self.preflight(safe: false, sudoFileUnsafe: true).recoveryOnlyReason(helperReported: nil) == .unsafeSudoFile)
    }

    @Test func missingProofIsAReason() {
        #expect(Self.preflight(safe: false).recoveryOnlyReason(helperReported: nil) == .noProofOfSafety)
    }

    // MARK: The gate

    @Test func theFirstQuestionReadsAndTheAnswerStandsUntilTheNextRead() {
        let reads = Counter()
        let looks = Locked([Self.preflight(safe: false), Self.preflight()])
        let gate = SudoPasswordPromptGate(readPreflight: {
            reads.increment()
            return looks.withLock { $0.count > 1 ? $0.removeFirst() : $0[0] }
        })
        #expect(gate.reason == .noProofOfSafety)
        #expect(!gate.allowsPasswordPrompts)
        #expect(reads.value == 1, "a later question reuses the last read")
        #expect(gate.check() == nil, "check() reads again")
        #expect(gate.allowsPasswordPrompts)
        #expect(reads.value == 2)
    }

    @Test func aRecordedLookIsTheAnswer() {
        let gate = SudoPasswordPromptGate(readPreflight: { Issue.record("record(_:) must not read"); return .clear })
        #expect(gate.record(Self.preflight(sudoFileUnsafe: true)) == .unsafeSudoFile)
        #expect(gate.reason == .unsafeSudoFile)
        #expect(gate.record(Self.preflight()) == nil)
        #expect(gate.allowsPasswordPrompts)
    }

    @Test func whatTheHelperReportedHoldsUntilAHelperCallSucceeds() {
        let gate = SudoPasswordPromptGate(readPreflight: { .clear })
        gate.check()
        gate.helperReportedUnsafePolicy = .notRegularFile
        #expect(gate.reason == .unsafePolicy(.notRegularFile))
        #expect(gate.check() == .unsafePolicy(.notRegularFile), "a safe look of the app's own does not clear it")
        gate.helperReportedUnsafePolicy = nil
        #expect(gate.allowsPasswordPrompts)
    }

    @Test func reasonsHaveLogNamesWithoutPaths() {
        #expect(SudoPolicyDistrust.unsafePolicy(.unsafeOwnership).logName == "unsafePolicy(-5)")
        #expect(SudoPolicyDistrust.noProofOfSafety.logName == "noProofOfSafety")
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}

private final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func withLock<Result>(_ body: (inout Value) -> Result) -> Result { lock.withLock { body(&value) } }
}
