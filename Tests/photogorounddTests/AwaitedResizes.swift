import Foundation
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

/// Waits for something to become true, rather than sleeping a guess.
///
/// **Why a wait at all.** Keeping a resized copy became `async` when
/// `PhotoStore` became an actor, so the endpoint hands the write to a task of
/// its own: the response goes out before the copy is on disk, and before the
/// eviction that follows the write. A test about that eviction has to wait for
/// it, and a fixed sleep is either too long to be quick or too short to be
/// reliable under a parallel run.
func until(
    _ reached: () -> Bool,
    _ what: String,
    within limit: Duration = .seconds(10)
) async {
    let clock = ContinuousClock()
    let deadline = clock.now + limit
    while clock.now < deadline {
        if reached() { return }
        try? await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("\(what) did not happen within \(limit)")
}
