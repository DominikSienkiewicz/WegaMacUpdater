import Foundation

/// What the app must do with a termination request (REL-06).
public enum TerminationDecision: Equatable, Sendable {
    /// Nothing is being mutated — the process may go away immediately.
    case now
    /// A Caskroom mutation is in flight: hold the process and ask the user.
    case waitForMutation
}

/// The three answers the "something is still running" dialog offers (REL-06).
public enum QuitDuringMutationChoice: Equatable, Sendable {
    /// Keep the process alive until the mutation finishes, then quit. The default.
    case waitForMutation
    /// Quit now, accepting a possibly half-written Caskroom.
    case quitAnyway
    /// Don't quit at all.
    case cancel
}

/// Knows whether anything is currently rewriting the Caskroom, and keeps the process
/// alive while that is true (REL-06).
///
/// Two kinds of source feed it, because the app has two kinds:
///
/// * **Tickets** — a mutation that tells the guard when it starts and when it stops
///   (`begin` / `end`). This is the preferred shape: it is exact, and it carries a label
///   the quit dialog can show.
/// * **Probes** — a mutation the guard can only *ask about*, because it is owned elsewhere
///   and exposes nothing but a boolean (`UpgradeMutex.isBusy`). A probe is enough to decide
///   a termination request, since that decision is made on the spot.
///
/// The `.suddenTerminationDisabled` assertion follows from that asymmetry. Sudden
/// termination is the one path that never reaches `applicationShouldTerminate` — at log-out
/// the process is simply killed — so the assertion has to already be in place *before* the
/// mutation starts. A ticket can arrange that; a probe cannot, because nobody calls the
/// guard when a probed mutation begins. So the assertion is held for as long as any ticket
/// is open **or** any probe is registered: registering a probe is the statement "a mutation
/// can start here at any moment without telling you". With the background updater armed on
/// a timer that is simply true for the whole session, and there is no instant at which
/// re-enabling sudden termination would be safe.
@MainActor
public final class MutationGuard {

    /// Handle for one in-flight mutation. Returned by `begin`, consumed by `end`.
    public struct Ticket: Hashable, Sendable {
        fileprivate let id: Int
    }

    public static let shared = MutationGuard()

    private struct Probe {
        let label: String
        let isMutating: @MainActor () -> Bool
    }

    private var probes: [Probe] = []
    private var tickets: [Int: String] = [:]
    private var nextTicketID = 0
    private var activity: NSObjectProtocol?

    private let beginActivity: @MainActor (ProcessInfo.ActivityOptions, String) -> NSObjectProtocol
    private let endActivity: @MainActor (NSObjectProtocol) -> Void

    /// The activity hooks are injected so the assertion's lifetime can be asserted in a
    /// test — `ProcessInfo` offers no way to read back which activities are open.
    public init(
        beginActivity: @escaping @MainActor (ProcessInfo.ActivityOptions, String) -> NSObjectProtocol = {
            ProcessInfo.processInfo.beginActivity(options: $0, reason: $1)
        },
        endActivity: @escaping @MainActor (NSObjectProtocol) -> Void = {
            ProcessInfo.processInfo.endActivity($0)
        }
    ) {
        self.beginActivity = beginActivity
        self.endActivity = endActivity
    }

    /// True while any registered source reports a mutation in flight.
    public var isMutating: Bool {
        !tickets.isEmpty || probes.contains { $0.isMutating() }
    }

    /// Human-readable names of what is running right now, for the quit dialog.
    public var runningLabels: [String] {
        tickets.sorted { $0.key < $1.key }.map(\.value)
            + probes.filter { $0.isMutating() }.map(\.label)
    }

    /// Registers a mutation source that can only be polled. See the type's note on why this
    /// pins the sudden-termination assertion for the rest of the session.
    public func addProbe(_ label: String, _ isMutating: @escaping @MainActor () -> Bool) {
        probes.append(Probe(label: label, isMutating: isMutating))
        refreshActivityAssertion()
    }

    /// Marks the start of a mutation this guard owns. Pair with `end`, ideally via `defer`.
    public func begin(_ label: String) -> Ticket {
        nextTicketID += 1
        tickets[nextTicketID] = label
        refreshActivityAssertion()
        return Ticket(id: nextTicketID)
    }

    /// Marks the end of a mutation. Ending a ticket twice is a no-op.
    public func end(_ ticket: Ticket) {
        tickets.removeValue(forKey: ticket.id)
        refreshActivityAssertion()
    }

    public func terminationDecision() -> TerminationDecision {
        isMutating ? .waitForMutation : .now
    }

    /// Returns once nothing is mutating any more. Probes cannot notify, so this polls;
    /// the interval only decides how long a quit lingers after the last mutation ends.
    /// Returns early if the calling task is cancelled.
    public func waitUntilIdle(pollInterval: Duration = .milliseconds(250)) async {
        while isMutating {
            do { try await Task.sleep(for: pollInterval) } catch { return }
        }
    }

    /// Test seam: how many activity assertions this guard currently holds (0 or 1).
    public var heldActivityCount: Int { activity == nil ? 0 : 1 }

    private var mayMutate: Bool { !tickets.isEmpty || !probes.isEmpty }

    private func refreshActivityAssertion() {
        if mayMutate, activity == nil {
            activity = beginActivity(.suddenTerminationDisabled, "Wega mutates the Homebrew Caskroom")
        } else if !mayMutate, let open = activity {
            endActivity(open)
            activity = nil
        }
    }
}
