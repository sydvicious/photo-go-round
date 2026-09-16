import Foundation
import Testing

@testable import PhotoGoRoundAgentAPI
@testable import PhotoGoRoundKit

/// The `LOCK:` line: a transaction that held the write lock too long says so.
///
/// Syd, 2026-09-16: "long locks in the database are death." `Agent Performance
/// Overhaul.md`, *The `LOCK:` line*.
@Suite("Long locks are reported")
struct LongLockTests {

    /// Every report a connection made.
    final class Heard {
        var locks: [Database.LongLock] = []
    }

    private static func connection() throws -> (Database, Heard) {
        let database = try Database.inMemory()
        try database.run("CREATE TABLE t (x INTEGER);")
        let heard = Heard()
        database.reportLongLock = { heard.locks.append($0) }
        return (database, heard)
    }

    /// Past the threshold by enough that a busy test machine cannot make a
    /// short hold look long or a long one look short.
    private static let tooLong = Database.longLockThreshold * 2

    @Test("A transaction held past the threshold is reported, with where it came from")
    func longHoldIsReported() throws {
        let (database, heard) = try Self.connection()

        try database.transaction {
            try database.run("INSERT INTO t VALUES (1);")
            Thread.sleep(forTimeInterval: Self.tooLong.totalSeconds)
        }

        let lock = try #require(heard.locks.first)
        #expect(heard.locks.count == 1)
        #expect(lock.held >= Self.tooLong)
        #expect(lock.attempts == 1)
        #expect(lock.function == "longHoldIsReported()")
        #expect(lock.fileID.hasSuffix("LongLockTests.swift"))
    }

    @Test("The async form reports too")
    func asyncHoldIsReported() async throws {
        let (database, heard) = try Self.connection()

        try await database.transaction {
            try database.run("INSERT INTO t VALUES (1);")
            Thread.sleep(forTimeInterval: Self.tooLong.totalSeconds)
        }

        #expect(heard.locks.count == 1)
        #expect(heard.locks.first?.function == "asyncHoldIsReported()")
    }

    @Test("A short transaction says nothing")
    func shortHoldIsSilent() throws {
        let (database, heard) = try Self.connection()

        try database.transaction { try database.run("INSERT INTO t VALUES (1);") }

        #expect(heard.locks.isEmpty)
    }

    /// A deferred transaction takes no write lock at `BEGIN`, and may never
    /// take one; its length is a reader's, and under WAL a reader blocks nobody.
    @Test("A long deferred transaction says nothing")
    func deferredHoldIsSilent() throws {
        let (database, heard) = try Self.connection()

        try database.transaction(.deferred) {
            _ = try database.scalarInt("SELECT COUNT(*) FROM t;")
            Thread.sleep(forTimeInterval: Self.tooLong.totalSeconds)
        }

        #expect(heard.locks.isEmpty)
    }

    @Test("The line says how long it held, how long it waited, the attempts, and the caller")
    func wording() {
        let lock = Database.LongLock(
            held: .milliseconds(812), waited: .milliseconds(3), attempts: 2,
            function: "upsert(_:to:at:isolation:onAdded:)",
            fileID: "PhotoGoRoundKit/PhotoPool.swift", line: 96)

        #expect(
            lock.text
                == "LOCK: held 812ms · waited 3ms · 2 attempts · upsert(_:to:at:isolation:onAdded:) (PhotoPool.swift:96)")
    }

    @Test("One attempt is singular")
    func oneAttempt() {
        let lock = Database.LongLock(
            held: .milliseconds(60), waited: .zero, attempts: 1,
            function: "register(kind:displayID:now:)",
            fileID: "PhotoGoRoundKit/Deck+Consumers.swift", line: 29)

        #expect(
            lock.text
                == "LOCK: held 60ms · waited 0ms · 1 attempt · register(kind:displayID:now:) (Deck+Consumers.swift:29)")
    }
}
