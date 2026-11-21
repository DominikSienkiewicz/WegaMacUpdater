import Foundation
import Testing
import WegaHelperKit
@testable import MacUpdaterCore

/// Z14 (design §3, §4): the app neither registers nor uses its root helper while the bundle it runs
/// from fails `HelperBundleGate`. Every caller that falls back when the helper is off — rollback,
/// self-update, Touch ID, Uninstall — then falls back the same way, through `isEnabled`, `call()` and
/// the availability mappings. Removing a registration stays allowed.
@Suite("Privileged helper client: bundle gate")
struct PrivilegedHelperBundleGateTests {
    typealias HelperError = PrivilegedHelperClient.HelperError

    private static let refusal = HelperBundleRefusal.notOwnedByRoot(.bundle)

    // MARK: - When the bundle is checked

    /// A trusted answer stays for the process: a root-owned bundle cannot become writable to the user
    /// without root, and checking again while a pkg install replaces the bundle could refuse a status
    /// poll and strand the install.
    @Test func aTrustedBundleIsCheckedOnlyUntilItIsTrusted() {
        let answers = Answers([.refused(Self.refusal), .trusted, .refused(.notInApplications)])
        let client = Self.client(trust: answers)

        #expect(client.bundleTrust == .refused(Self.refusal))
        #expect(client.bundleTrust == .trusted)
        #expect(client.bundleTrust == .trusted)
        #expect(client.bundleTrust == .trusted)
        #expect(answers.calls == 2)
    }

    /// A refusal is asked again on every read, so a refusal read mid-install heals, and a pkg installed
    /// over a dragged copy counts without a restart.
    @Test func aRefusalIsCheckedAgainOnEveryRead() {
        let answers = Answers([.refused(Self.refusal), .refused(.notInApplications), .refused(Self.refusal)])
        let client = Self.client(trust: answers)

        #expect(client.bundleTrust == .refused(Self.refusal))
        #expect(client.bundleTrust == .refused(.notInApplications))
        #expect(client.bundleTrust == .refused(Self.refusal))
        #expect(answers.calls == 3)
    }

    // MARK: - Registering and removing

    @Test func aRefusedBundleIsNeverRegistered() {
        let registration = Registration(status: .notRegistered)
        let client = Self.client(registration: registration, trust: Answers([.refused(Self.refusal)]))

        #expect(throws: HelperError.self) { try client.register() }
        do {
            try client.register()
        } catch HelperError.bundleNotTrusted(let refusal) {
            #expect(refusal == Self.refusal)
        } catch {
            Issue.record("unexpected \(error)")
        }
        #expect(registration.registerCalls == 0)
    }

    @Test func aTrustedBundleRegisters() throws {
        let registration = Registration(status: .notRegistered)
        let client = Self.client(registration: registration, trust: Answers([.trusted]))

        try client.register()

        #expect(registration.registerCalls == 1)
    }

    /// A registration left from a dragged copy must stay removable.
    @Test func aRefusedBundleCanStillRemoveTheRegistration() async throws {
        let registration = Registration(status: .enabled)
        let client = Self.client(registration: registration, trust: Answers([.refused(Self.refusal)]))

        try await client.unregister()

        #expect(registration.unregisterCalls == 1)
    }

    // MARK: - Using the helper

    @Test func theHelperIsEnabledOnlyWhenRegisteredAndTrusted() {
        #expect(Self.client(registration: Registration(status: .enabled), trust: Answers([.trusted])).isEnabled)
        #expect(!Self.client(registration: Registration(status: .enabled), trust: Answers([.refused(Self.refusal)])).isEnabled)
        #expect(!Self.client(registration: Registration(status: .notRegistered), trust: Answers([.trusted])).isEnabled)
        #expect(!Self.client(registration: Registration(status: .requiresApproval), trust: Answers([.trusted])).isEnabled)
    }

    /// Every verb starts with the version probe through `call()`, so a refused bundle is answered
    /// before any connection opens. The Mach name is one nobody serves, so a client that did connect
    /// would fail with a connection error instead, never reaching a real helper.
    @Test func aRefusedBundleSendsNothingToTheHelper() async {
        let client = Self.client(registration: Registration(status: .enabled), trust: Answers([.refused(Self.refusal)]))

        await #expect(throws: HelperError.self) { _ = try await client.helperVersion() }
        do {
            _ = try await client.helperVersion()
            Issue.record("a refused bundle must not reach the helper")
        } catch HelperError.bundleNotTrusted(let refusal) {
            #expect(refusal == Self.refusal)
        } catch {
            Issue.record("expected bundleNotTrusted, got \(error)")
        }
        do {
            try await client.replaceBundle(at: "/Applications/X.app", withSnapshotAt: "/tmp/X.app")
            Issue.record("a refused bundle must not reach the helper")
        } catch HelperError.bundleNotTrusted {
            // Expected: refused before the handshake connects.
        } catch {
            Issue.record("expected bundleNotTrusted, got \(error)")
        }
    }

    /// The refusal wins over an unregistered helper, so the caller can say why, not just "turn it on".
    @Test func theRefusalIsReportedAheadOfAMissingRegistration() async {
        let client = Self.client(registration: Registration(status: .notRegistered), trust: Answers([.refused(.notInApplications)]))

        do {
            _ = try await client.helperVersion()
            Issue.record("must throw")
        } catch HelperError.bundleNotTrusted(let refusal) {
            #expect(refusal == .notInApplications)
        } catch {
            Issue.record("expected bundleNotTrusted, got \(error)")
        }
    }

    // MARK: - What callers are told

    @Test func uninstallReadsARefusedBundleAsItsOwnCase() {
        #expect(Self.client(registration: Registration(status: .enabled), trust: Answers([.refused(Self.refusal)])).uninstallAvailability
                == .untrustedBundle)
        #expect(Self.client(registration: Registration(status: .notRegistered), trust: Answers([.refused(Self.refusal)])).uninstallAvailability
                == .untrustedBundle)
        #expect(Self.client(registration: Registration(status: .enabled), trust: Answers([.trusted])).uninstallAvailability == .enabled)
        #expect(Self.client(registration: Registration(status: .notRegistered), trust: Answers([.trusted])).uninstallAvailability == .off)
    }

    @Test func aRefusedHandshakeReadsAsUntrustedForUninstallAndOffForAVerb() {
        let error = HelperError.bundleNotTrusted(Self.refusal)
        #expect(PrivilegedHelperClient.uninstallAvailability(handshakeFailure: error) == .untrustedBundle)
        #expect(PrivilegedHelperClient.verbAvailability(handshakeFailure: error) == .off)
    }

    @Test func theRefusalIsNeverAskedAgain() async {
        let attempts = AttemptCounter()
        await #expect(throws: HelperError.self) {
            try await PrivilegedHelperClient.retryingOnceOnConnectionFailure { () async throws -> String in
                attempts.increment()
                throw HelperError.bundleNotTrusted(Self.refusal)
            }
        }
        #expect(attempts.count == 1)
    }

    // MARK: - Fixtures

    private static func client(
        registration: Registration = Registration(status: .enabled), trust: Answers
    ) -> PrivilegedHelperClient {
        PrivilegedHelperClient(
            registration: .init(
                status: { registration.status },
                register: { try registration.register() },
                unregister: { try await registration.unregister() }
            ),
            evaluateBundleTrust: { trust.next() },
            machServiceName: "com.wega.tests.nobody-serves-this-\(UUID().uuidString)"
        )
    }

    /// Gives its answers in order and repeats the last one.
    private final class Answers: @unchecked Sendable {
        private let lock = NSLock()
        private var remaining: [HelperBundleTrust]
        private(set) var calls = 0

        init(_ answers: [HelperBundleTrust]) { remaining = answers }

        func next() -> HelperBundleTrust {
            lock.lock(); defer { lock.unlock() }
            calls += 1
            return remaining.count > 1 ? remaining.removeFirst() : remaining[0]
        }
    }

    private final class Registration: @unchecked Sendable {
        let status: PrivilegedHelperClient.Status
        private(set) var registerCalls = 0
        private(set) var unregisterCalls = 0

        init(status: PrivilegedHelperClient.Status) { self.status = status }

        func register() throws { registerCalls += 1 }
        func unregister() async throws { unregisterCalls += 1 }
    }

    private final class AttemptCounter: @unchecked Sendable {
        private(set) var count = 0
        func increment() { count += 1 }
    }
}
