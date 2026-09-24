import Foundation
import Testing

@testable import PhotosGoRoundServer

/// The launch's refresh and cache walk wait for the first picture, or for
/// `LaunchHold.limit`. `Plans/Startup Performance.md`.
@Suite("Launch hold")
struct LaunchHoldTests {

    /// A class rather than a `Mutex`, because a `Mutex` is non-copyable and
    /// an escaping closure cannot capture one.
    final class Flag<Value: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Value
        init(_ value: Value) { self.value = value }
        var current: Value { lock.withLock { value } }
        func set(_ new: Value) { lock.withLock { value = new } }
    }

    @Test("A waiter is held until the hold opens, and then released")
    func waitsUntilOpened() async throws {
        let hold = LaunchHold()
        let released = Flag(false)
        let waiter = Task {
            await hold.wait()
            released.set(true)
        }
        // The waiter is parked before anything opens the hold, so the open is
        // what releases it rather than a race it happened to win.
        while await hold.waitingCount == 0 { await Task.yield() }
        #expect(!released.current)

        #expect(await hold.open(because: .delivered))
        await waiter.value
        #expect(released.current)
    }

    @Test("It opens once, and the first reason is the one kept")
    func opensOnce() async {
        let hold = LaunchHold()
        #expect(await hold.open(because: .emptyDeck))
        #expect(await !hold.open(because: .delivered))
        #expect(await hold.opened == .emptyDeck)
    }

    @Test("Waiting on an open hold does not wait")
    func openHoldDoesNotWait() async {
        let hold = LaunchHold()
        await hold.open(because: .nothingQueued)
        await hold.wait()
    }

    @Test("Nothing asked for, it opens by itself after the limit")
    func opensAfterTheLimit() async {
        let hold = LaunchHold()
        hold.openAfter(.milliseconds(10)) { _, _ in }
        await hold.wait()
        #expect(await hold.opened == .timedOut)
    }

    @Test("A hold already open is not reopened by the limit")
    func limitAfterOpen() async throws {
        let hold = LaunchHold()
        await hold.open(because: .delivered)
        let said = Flag<LaunchHold.Reason?>(nil)
        hold.openAfter(.milliseconds(1)) { reason, _ in said.set(reason) }
        try await Task.sleep(for: .milliseconds(50))
        #expect(await hold.opened == .delivered)
        #expect(said.current == nil)
    }

    @Test("The line names how long it held and why it opened")
    func line() {
        #expect(
            RunCommand.launchHoldLine(.delivered, after: .milliseconds(7_240))
                == "LAUNCH: refresh and cache walk held 7.2s, until a picture was delivered")
    }
}
