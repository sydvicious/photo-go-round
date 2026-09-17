import Foundation

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
