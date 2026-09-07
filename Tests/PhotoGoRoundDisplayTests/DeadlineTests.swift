import Foundation
import Synchronization
import Testing

@testable import PhotoGoRoundAgentAPI

/// Giving up on an answer that is not coming.
///
/// **The case these exist for is an agent that accepts the connection and then
/// says nothing** — which is what a wedged photo library does to it, since a
/// PhotoKit call parked on a cooperative thread costs the runtime a thread and
/// enough of them stop the agent answering anything at all. A refused
/// connection was always handled; silence was not, and silence is the one that
/// lasts until something gives up.
@Suite("Waiting only so long for an answer")
struct DeadlineTests {

    @Test("Work that answers in time answers, and its value comes back")
    func promptWorkAnswers() async throws {
        let value = try await Deadline.run(within: .seconds(30)) { 7 }
        #expect(value == 7)
    }

    @Test("Work that never answers expires instead of waiting")
    func silenceExpires() async {
        // The whole fault, in one line: before this, a client asked and waited
        // for as long as the agent stayed stuck.
        await #expect(throws: Deadline.Expired.self) {
            try await Deadline.run(within: .milliseconds(50)) {
                try await Task.sleep(for: .seconds(60))
            }
        }
    }

    /// The limit travels with the error so that whatever reports it can say how
    /// long it actually waited, rather than restating a constant that may not be
    /// the one that fired.
    @Test("The expiry says how long it waited")
    func expiryCarriesItsLimit() async {
        do {
            try await Deadline.run(within: .milliseconds(50)) {
                try await Task.sleep(for: .seconds(60))
            }
            Issue.record("expected an expiry")
        } catch let expired as Deadline.Expired {
            #expect(expired.limit == .milliseconds(50))
        } catch {
            Issue.record("expected Expired, got \(error)")
        }
    }

    /// **A failure that arrives in time is not a timeout**, and a client that
    /// could not tell the two apart would report every refused connection as an
    /// agent that had gone quiet.
    @Test("An error from the work itself passes through unchanged")
    func realFailuresAreNotExpiries() async {
        struct Refused: Error, Equatable {}
        await #expect(throws: Refused.self) {
            try await Deadline.run(within: .seconds(30)) { throw Refused() }
        }
    }

    /// Slow is not the same as silent. A bound that fired on anything that
    /// suspended at all would report a busy agent as a broken one.
    @Test("Work that is slow but inside the limit still answers")
    func slowWorkStillAnswers() async throws {
        let value = try await Deadline.run(within: .seconds(30)) {
            try await Task.sleep(for: .milliseconds(20))
            return "here"
        }
        #expect(value == "here")
    }

    /// **The caller returns at the limit, not when the work does.** This is the
    /// property the whole thing is for: an abandoned request must not be waited
    /// for at scope exit, which is what a structured child would have meant.
    @Test("The caller is released at the limit, not when the work finishes")
    func theCallerDoesNotWaitForAbandonedWork() async {
        let clock = ContinuousClock()
        let started = clock.now
        _ = try? await Deadline.run(within: .milliseconds(50)) {
            try await Task.sleep(for: .seconds(10))
        }
        // Generously above the limit and far below the work's own duration, so
        // this cannot pass by accident on a loaded machine.
        #expect(clock.now - started < .seconds(2))
    }

    /// Cancelling is what releases the socket when the transport cooperates —
    /// `URLSession` does. It is best effort: the point of the deadline is that
    /// the caller is freed whether or not the work takes any notice.
    @Test("Abandoned work is asked to stop")
    func abandonedWorkIsCancelled() async throws {
        let noticed = Mutex(false)
        _ = try? await Deadline.run(within: .milliseconds(50)) {
            do {
                try await Task.sleep(for: .seconds(10))
            } catch {
                noticed.withLock { $0 = true }
                throw error
            }
        }
        // The cancel is issued as the caller leaves; give the abandoned task a
        // moment to observe it.
        try await Task.sleep(for: .milliseconds(200))
        #expect(noticed.withLock { $0 })
    }
}
