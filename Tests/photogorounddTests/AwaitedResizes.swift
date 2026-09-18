import Foundation
import Synchronization
import Testing

@testable import photogoroundd

/// For a fixture whose tests are not about the resize budget: its own
/// resizer, and a budget no run reaches, so a sized request waits for its
/// resize rather than racing a clock.
///
/// **Why.** Three `EndpointCacheTests` failed together in a full parallel run
/// on 2026-09-16. Their endpoint shared the process's `Resizer` and the
/// production one-second budget, so another suite's resize, or a pool starved
/// by the rest of the run, made a sized request serve the original. Reproduced
/// by holding the shared resizer for 1.5 s. Syd: "we fixed flaky timing tests
/// at Indeed by using await Task {}.run." A test *about* the budget sets
/// `ServiceTiming.resizeBudget` itself.
let awaitedResizeBudget = Duration.seconds(600)

extension PictureEndpoint {
    func awaitingResizes() -> PictureEndpoint {
        var endpoint = self
        endpoint.resizer = Resizer()
        endpoint.resizeBudget = awaitedResizeBudget
        return endpoint
    }
}

extension DashboardEndpoint {
    func awaitingResizes() -> DashboardEndpoint {
        var endpoint = self
        endpoint.resizer = Resizer()
        endpoint.resizeBudget = awaitedResizeBudget
        return endpoint
    }
}

/// The tasks that kept resized copies, so a test can wait for a copy to be on
/// disk instead of polling for its row.
///
/// **Awaited, not polled.** Syd, 2026-09-17: "can you do `await Task { }.run()`
/// instead of a timer?" Keeping a copy became `async` when `PhotoStore` became
/// an actor, so the endpoint writes it in a task of its own and the response
/// goes out first. `CopyPlace.kept` hands that task over; this collects them,
/// and `settle()` is the handoff. A loop that watched for the `resized` row
/// would be asserting how fast this machine is.
final class KeptCopies: Sendable {
    private let tasks = Mutex<[Task<Void, Never>]>([])

    /// Installed as `PictureEndpoint.kept` or `DashboardEndpoint.kept`.
    ///
    /// Captures `self` rather than the `Mutex`: a `Mutex` is non-copyable, and
    /// a capture list would consume it.
    var collect: @Sendable (Task<Void, Never>) -> Void {
        { [self] task in tasks.withLock { $0.append(task) } }
    }

    /// Waits for every copy handed over so far, and for any handed over while
    /// waiting — a copy whose eviction sets off another write would otherwise
    /// be missed.
    func settle() async {
        while true {
            let pending = tasks.withLock { held -> [Task<Void, Never>] in
                let all = held
                held = []
                return all
            }
            if pending.isEmpty { return }
            for task in pending { await task.value }
        }
    }
}
