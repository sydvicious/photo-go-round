import Foundation
import Testing

@testable import PhotoGoRoundKit
@testable import photogoroundd

/// Where the listener ends up, which is the whole of how anything finds it.
///
/// These start real listeners. They are loopback-only and answer nothing, so
/// they cost a bind and a teardown — worth it, because the port is the one fact
/// in this design that cannot be checked by reading the arguments.
@Suite("Listener port", .serialized)
struct ListenerPortTests {

    /// Starts a listener and reports the port it bound, or nil if it never
    /// became ready.
    ///
    /// Nil rather than a failure, because a bind can legitimately lose a race
    /// for a specific number and the caller is the only one that knows whether
    /// that is the answer or a reason to try again.
    private func bind(_ pinned: UInt16?) async throws -> UInt16? {
        let reported = Reported()
        let listener = HTTPListener(
            port: pinned,
            advertising: PictureEndpoint.path,
            onReady: { reported.set($0) }
        ) { _ in .noContent() }

        try listener.start()
        defer { listener.stop() }

        // Binding is asynchronous, so this waits for the callback rather than
        // assuming it has already happened.
        for _ in 0..<100 {
            if let port = reported.value { return port }
            try await Task.sleep(for: .milliseconds(10))
        }
        return nil
    }

    private final class Reported: @unchecked Sendable {
        private let lock = NSLock()
        private var port: UInt16?
        func set(_ new: UInt16) {
            lock.lock()
            defer { lock.unlock() }
            port = new
        }
        var value: UInt16? {
            lock.lock()
            defer { lock.unlock() }
            return port
        }
    }

    @Test("With no port pinned the kernel picks one, and the listener says which")
    func floatingPortIsReported() async throws {
        let port = try #require(try await bind(nil))
        // Any real port will do. What matters is that a number came back at
        // all: nothing can be published if the listener does not say.
        #expect(port > 0)
    }

    @Test("Two agents can run at once, because neither asked for a number")
    func twoFloatingListenersCoexist() async throws {
        let first = try #require(try await bind(nil))
        let second = try #require(try await bind(nil))
        #expect(first > 0)
        #expect(second > 0)
        // The pair is the point — a fixed default would have made the second
        // one a collision.
    }

    @Test("A pinned port is the port")
    func pinnedPortIsHonoured() async throws {
        // The number is taken from the kernel rather than written here, so this
        // asks for one that was free a moment ago instead of one that happens
        // to be free on the machine running the tests.
        //
        // Retried, because "free a moment ago" is not "free now": the listener
        // that surrendered it may not have finished letting go. Losing that
        // race is not the failure this is looking for.
        //
        // **A bound port that is not the candidate is that same lost race**, not
        // a failure: since 2026-09-17 the listener answers a refused fixed port
        // by taking one from the kernel rather than by not starting. Syd: "If
        // the agent can't get the port it wants, it should fall back to what it
        // does now."
        for _ in 0..<10 {
            guard let candidate = try await bind(nil) else { continue }
            // The listener that surrendered the number is torn down
            // asynchronously, so asking for it in the same breath is the race
            // this loop exists to lose occasionally. The wait is for that
            // teardown and not for the assertion.
            try await Task.sleep(for: .milliseconds(20))
            if let bound = try await bind(candidate), bound == candidate { return }
        }
        Issue.record("no port could be pinned in ten attempts")
    }

    /// **The fixed port is a preference, not a requirement.** Two agents on one
    /// Mac — Syd's and an agent's, or a scratch run beside the installed one —
    /// must both start, and the second one is found the way everything was
    /// found before: by the value it publishes.
    @Test("A port that is already held is fallen back from, not failed on")
    func aHeldPortFallsBack() async throws {
        // **The holder takes a port from the kernel and keeps it**, rather than
        // this binding one, letting it go and hoping to find it still free. The
        // first version did that and failed in a full run: the holder lost the
        // race to re-take its own number, fell back, and left the number free
        // for the listener that was supposed to be refused it.
        let reported = Reported()
        let holder = HTTPListener(
            port: nil, advertising: PictureEndpoint.path, onReady: { reported.set($0) }
        ) { _ in .noContent() }
        try holder.start()
        defer { holder.stop() }

        var holding: UInt16?
        for _ in 0..<100 {
            if let port = reported.value {
                holding = port
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        let held = try #require(holding, "the holder never became ready")

        let bound = try #require(try await bind(held), "the second listener never became ready")

        #expect(bound != held, "it bound a port another listener was holding")
        #expect(bound != 0)
    }
}
