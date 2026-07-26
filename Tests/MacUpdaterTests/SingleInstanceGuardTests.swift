import Testing
@testable import MacUpdaterCore

/// REL-08 — a second copy of Wega must not mutate the same Homebrew prefix in
/// parallel with the first. Two instances would race for the brew lock, the exact
/// corruption the in-process coordinator prevents. The launch decision is a pure
/// function of how many *other* instances are already running.
@Suite("SingleInstanceGuard")
struct SingleInstanceGuardTests {
    @Test func proceedsWhenNoOtherInstanceIsRunning() {
        #expect(SingleInstanceGuard.decide(otherInstanceCount: 0) == .proceed)
    }

    @Test func blocksWhenAnotherInstanceIsAlreadyRunning() {
        #expect(SingleInstanceGuard.decide(otherInstanceCount: 1) == .anotherInstanceRunning)
    }

    @Test func blocksRegardlessOfHowManyOtherInstancesExist() {
        #expect(SingleInstanceGuard.decide(otherInstanceCount: 3) == .anotherInstanceRunning)
    }

    /// A negative count can only mean a miscount upstream; failing open (proceed) keeps
    /// the app launchable rather than bricking it on a bad enumeration.
    @Test func treatsANonPositiveCountAsNoOtherInstance() {
        #expect(SingleInstanceGuard.decide(otherInstanceCount: -1) == .proceed)
    }
}
