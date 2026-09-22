import Foundation
import Testing

@testable import PhotoGoRoundKit

/// Waiting on a busy database must not cost the process a thread.
///
/// The cooperative thread pool has about as many threads as the machine has
/// cores, and every `async` operation in the process needs one to run on. A
/// database call that waits by *blocking* takes one out of circulation for the
/// duration — so a few contended transactions stall serving, caching and
/// refreshing all at once. A single picture request was measured at 122 seconds
/// on 2026-08-25 with the library under a long refresh.
///
/// `sqlite3_busy_timeout` is therefore zero and the waiting is ours: a sleeping
/// thread for callers that are already synchronous, and a suspension for callers
/// that are not.
@Suite("Waiting without blocking")
struct BlockingTests {

    private func library() throws -> (URL, String) {
        let directory = URL.temporaryDirectory.appending(path: "pgr-block-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appending(path: "photogoround.sqlite").path(percentEncoded: false)
        try Migrator.migrate(Database(path: path))
        return (directory, path)
    }

    /// How many waiters were inside the wait at the same moment.
    private struct Overlap: Sendable {
        var current = 0
        var peak = 0
        mutating func enter() { current += 1; peak = max(peak, current) }
        mutating func leave() { current -= 1 }
    }

    /// **Waiters overlap instead of queueing behind each other.**
    ///
    /// Asserted by counting how many are inside the wait at once rather than by
    /// timing the group, because the suite runs in parallel and wall-clock
    /// bounds measure the machine's load as much as the code's behaviour.
    ///
    /// The counting is what makes the two behaviours separable. A waiter that
    /// *blocks* holds a cooperative-pool thread, and the pool has about as many
    /// threads as the machine has cores — so no more than roughly that many
    /// waiters can ever be counted in at once, and the rest never even start. A
    /// waiter that *suspends* gives the thread straight back, so all of them are
    /// in flight together.
    @Test("Contended waiters overlap instead of queueing behind each other")
    func contendedWaitersDoNotSerialise() async throws {
        let (directory, path) = try library()
        defer { try? FileManager.default.removeItem(at: directory) }

        // One writer, holding the lock for the whole test.
        let holder = try Database(path: path)
        try holder.execute("BEGIN IMMEDIATE;")
        defer { try? holder.execute("ROLLBACK;") }

        let cores = ProcessInfo.processInfo.activeProcessorCount
        let waiters = cores * 4
        let overlap = Mutex(Overlap())

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<waiters {
                group.addTask {
                    guard let database = try? Database(path: path) else { return }
                    overlap.withLock { $0.enter() }
                    // Expected to give up: the lock is held for the whole test.
                    _ = try? await database.transaction(.immediate, within: .milliseconds(400)) {
                        try database.run("INSERT INTO deck_event (kind, at) VALUES ('x', 0);")
                    }
                    overlap.withLock { $0.leave() }
                }
            }
        }

        let peak = overlap.withLock { $0.peak }
        #expect(
            peak > cores * 2,
            "only \(peak) of \(waiters) waiters were ever in flight at once on a \(cores)-core machine; they were holding threads rather than suspending"
        )
    }

    /// Unrelated async work keeps running while the database is contended.
    ///
    /// This is the property the outage actually violated: not that a deal was
    /// slow, but that everything *else* stopped too.
    ///
    /// **The assertion is that the bystander finishes while waiters are still
    /// waiting**, which is a fact about ordering rather than about duration. If
    /// the waiters held threads, the bystander could not run at all until they
    /// were done, so it would finish last every time.
    @Test("Other async work still progresses while transactions wait")
    func unrelatedWorkIsNotStarved() async throws {
        let (directory, path) = try library()
        defer { try? FileManager.default.removeItem(at: directory) }

        let holder = try Database(path: path)
        try holder.execute("BEGIN IMMEDIATE;")
        defer { try? holder.execute("ROLLBACK;") }

        let cores = ProcessInfo.processInfo.activeProcessorCount
        let overlap = Mutex(Overlap())
        let stillWaitingWhenDone = Mutex(-1)
        let ticks = Mutex(0)

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<(cores * 4) {
                group.addTask {
                    guard let database = try? Database(path: path) else { return }
                    overlap.withLock { $0.enter() }
                    // A minute of patience they will never need: the bystander
                    // cancels them as soon as it has what it came for, so the
                    // test never waits on a clock and never races one.
                    _ = try? await database.transaction(.immediate, within: .seconds(60)) {
                        try database.run("INSERT INTO deck_event (kind, at) VALUES ('x', 0);")
                    }
                    overlap.withLock { $0.leave() }
                }
            }
            // The bystander runs here in the group's own body: five short hops,
            // each needing a pool thread to resume on.
            for _ in 0..<5 {
                try? await Task.sleep(for: .milliseconds(10))
                ticks.withLock { $0 += 1 }
            }
            stillWaitingWhenDone.withLock { $0 = overlap.withLock { $0.current } }
            group.cancelAll()
        }

        #expect(ticks.withLock { $0 } == 5, "the bystander task never finished")
        // **Every waiter must still be waiting.** Each holds a four-second
        // budget against a lock that is never released, so none of them can
        // finish on its own — and the bystander needs two hundred milliseconds.
        // If it suspended properly, it is done long before any of them.
        //
        // A weaker "at least one was still waiting" was tried first and was
        // worthless: it passed with the blocking implementation too, because
        // some waiters were always still going. This is the version that fails
        // when the property fails.
        //
        // **Every one of them**, and it is exact rather than approximate now:
        // the waiters have a minute of patience and are cancelled the moment the
        // bystander is done, so none can finish on its own and there is no clock
        // for a loaded machine to skew. With the waiting done by blocking, the
        // bystander only runs once the waiters have given their threads back, so
        // almost none are left.
        let waiters = cores * 4
        let left = stillWaitingWhenDone.withLock { $0 }
        #expect(
            left == waiters,
            "only \(left) of \(waiters) were still waiting when the bystander finished; it had to queue behind them for a thread"
        )
    }

    /// A busy database that outlasts the caller's patience is still a *busy*
    /// error, so an outer retry treats it as contention rather than as damage —
    /// and nothing upstream may read it as "there is nothing to deal".
    @Test("Giving up reports contention, not an empty library")
    func givingUpIsStillBusy() async throws {
        let (directory, path) = try library()
        defer { try? FileManager.default.removeItem(at: directory) }

        let holder = try Database(path: path)
        try holder.execute("BEGIN IMMEDIATE;")
        defer { try? holder.execute("ROLLBACK;") }

        let database = try Database(path: path)
        do {
            try await database.transaction(.immediate, within: .milliseconds(100)) {
                try database.run("INSERT INTO deck_event (kind, at) VALUES ('x', 0);")
            }
            Issue.record("the transaction should not have succeeded against a held lock")
        } catch let error as SQLiteError {
            #expect(error.isBusy)
        }
    }
}

/// Contention must never be reported as a source going away.
///
/// Seen live on 2026-08-25:
///
/// ```
/// ! source 22 unavailable: refresh failed: sqlite3 error 5/5: database is
///   locked — while stepping: UPDATE source SET available = 1 …
/// ```
///
/// The folder was a local one and was perfectly fine. `markUnavailable` is how
/// this system says *these photographs cannot be reached* — an unplugged drive,
/// a revoked permission — and it takes them off the screen and writes a reason
/// beside the source in the settings panel. A busy database says nothing
/// whatever about a source, so answering that way is simply false.
///
/// It became reachable when SQLite stopped absorbing busy waits internally:
/// statements outside a transaction have no retry of their own, so contention
/// that used to block now surfaces as an error, and `refresh` caught everything
/// alike.
@Suite("Contention is not unavailability")
struct ContentionIsNotUnavailabilityTests {

    @Test("A busy database never marks a source unavailable")
    func busyDoesNotMarkUnavailable() async throws {
        let folder = TemporaryFolder(name: "pgr-busy-source")
        folder.write("one.png")
        folder.write("two.png")

        let directory = URL.temporaryDirectory.appending(path: "pgr-busy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appending(path: "photogoround.sqlite").path(percentEncoded: false)
        try Migrator.migrate(Database(path: path))

        // A short fuse, so the test spends a fraction of a second finding out
        // rather than the full default patience.
        let connection = try Database(path: path, busyTimeout: .milliseconds(150))
        let store = SourceStore(database: connection)
        let source = try store.add(kind: .folder, locator: folder.path, recursive: false)

        // Somebody else holds the writer for the whole refresh.
        let holder = try Database(path: path)
        try holder.execute("BEGIN IMMEDIATE;")
        defer { try? holder.execute("ROLLBACK;") }

        let result = await store.refresh(source)

        #expect(
            !result.sourceUnavailable,
            "a busy database was reported as the source being unavailable"
        )
        // And the row itself is untouched: nothing was written claiming the
        // folder had gone.
        let after = try #require(try store.source(uuid: source.uuid))
        #expect(after.available)
        #expect(after.unavailableReason == nil)
    }
}
