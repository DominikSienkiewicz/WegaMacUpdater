import Foundation

/// Runs `work` concurrently with at most `limit` tasks in flight at any moment and
/// returns every result (order is not significant).
///
/// A bounded alternative to dropping every task into one `withTaskGroup`: a large
/// `/Applications` scan multiplies the number of per-app network checkers, and an
/// unbounded group would open hundreds of simultaneous connections, hammering the
/// remote update APIs. Capping the in-flight count keeps the fan-out polite while
/// still overlapping the slow network calls.
///
/// A `limit <= 0` is treated as "no cap" (run everything at once).
public func runBounded<T: Sendable>(
    limit: Int,
    _ work: [@Sendable () async -> T]
) async -> [T] {
    guard !work.isEmpty else { return [] }
    let cap = limit <= 0 ? work.count : min(limit, work.count)

    var results: [T] = []
    results.reserveCapacity(work.count)

    await withTaskGroup(of: T.self) { group in
        var next = 0
        // Prime the group up to the cap.
        while next < cap {
            group.addTask(operation: work[next])
            next += 1
        }
        // Each time one finishes, admit the next so the in-flight count stays at the cap.
        for await result in group {
            results.append(result)
            if next < work.count {
                group.addTask(operation: work[next])
                next += 1
            }
        }
    }

    return results
}

/// The `@MainActor` variant of `runBounded`.
///
/// An upgrade's work is not CPU work: each of these tasks starts a package-manager process
/// and then waits for it. `await` releases the actor, so the processes genuinely overlap
/// while every piece of state the tasks touch — the log, the progress tracker, the rollback
/// ledger, the operation journal — stays on a single actor. That is why the concurrent
/// upgrade path introduces no lock and no buffer shared between threads.
///
/// A `limit <= 0` is treated as "no cap" (run everything at once).
@MainActor
public func runBoundedOnMainActor<T: Sendable>(
    limit: Int,
    _ work: [@MainActor @Sendable () async -> T]
) async -> [T] {
    guard !work.isEmpty else { return [] }
    let cap = limit <= 0 ? work.count : min(limit, work.count)

    var results: [T] = []
    results.reserveCapacity(work.count)

    await withTaskGroup(of: T.self) { group in
        var next = 0
        while next < cap {
            let job = work[next]
            group.addTask(operation: job)
            next += 1
        }
        for await result in group {
            results.append(result)
            if next < work.count {
                let job = work[next]
                group.addTask(operation: job)
                next += 1
            }
        }
    }

    return results
}
