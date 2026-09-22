import Foundation

@testable import PhotoGoRoundAgentAPI

/// The error ledger, read after the reports ahead of the read have landed.
///
/// **Reports go through a queue.** `AgentErrors.record` is called from
/// synchronous `@Sendable` closures on whatever thread is passing, so it yields
/// into an `AsyncStream` rather than taking a lock — Syd, 2026-09-17:
/// "AsyncStream for both". A test that records and then reads is therefore
/// ahead of the drain unless it says so, and `settle()` puts a barrier through
/// the same queue rather than watching a clock.
extension AgentErrors {
    nonisolated var settled: [Entry] {
        get async {
            await settle()
            return await entries
        }
    }

    nonisolated func settled(at now: Date) async -> [Entry] {
        await settle()
        return await entries(at: now)
    }
}
