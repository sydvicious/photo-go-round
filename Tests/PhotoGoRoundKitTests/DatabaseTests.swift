import Foundation
import Testing

@testable import PhotoGoRoundKit

@Suite("SQLite layer")
struct DatabaseTests {

    /// A scratch directory that cleans itself up, since WAL means a database is
    /// three files rather than one.
    private static func withTemporaryDatabase<T>(_ body: (Database) throws -> T) throws -> T {
        let directory = URL.temporaryDirectory.appending(path: "pgr-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try Database(path: directory.appending(path: "library.sqlite").path(percentEncoded: false))
        return try body(database)
    }

    // MARK: - Opening

    @Test("A file-backed database opens in WAL mode")
    func fileDatabaseUsesWAL() throws {
        try Self.withTemporaryDatabase { database in
            let mode = try database.scalarString("PRAGMA journal_mode;")
            #expect(mode == "wal")
        }
    }

    @Test("Foreign keys are enforced on every connection")
    func foreignKeysAreOn() throws {
        let database = try Database.inMemory()
        #expect(try database.scalarInt("PRAGMA foreign_keys;") == 1)

        try database.execute(
            """
            CREATE TABLE parent (id INTEGER PRIMARY KEY);
            CREATE TABLE child (id INTEGER PRIMARY KEY, parent_id INTEGER NOT NULL REFERENCES parent(id));
            """
        )
        #expect(throws: SQLiteError.self) {
            try database.run("INSERT INTO child (parent_id) VALUES (:p);", ["p": 99])
        }
    }

    @Test("A fresh database reports user_version 0")
    func userVersionStartsAtZero() throws {
        let database = try Database.inMemory()
        #expect(try database.userVersion == 0)
        try database.setUserVersion(7)
        #expect(try database.userVersion == 7)
    }

    // MARK: - Binding and reading

    @Test("Every storage class round-trips through named bindings")
    func storageClassesRoundTrip() throws {
        let database = try Database.inMemory()
        try database.execute(
            "CREATE TABLE t (i INTEGER, d REAL, s TEXT, b BLOB, n INTEGER);"
        )
        let blob = Data([0xDE, 0xAD, 0xBE, 0xEF])
        try database.run(
            "INSERT INTO t (i, d, s, b, n) VALUES (:i, :d, :s, :b, :n);",
            ["i": .int(42), "d": .double(2.5), "s": .text("héllo"), "b": .blob(blob), "n": .null]
        )

        let row = try database.first("SELECT i, d, s, b, n FROM t;") { row in
            (
                i: try row.int("i"),
                d: try row.double("d"),
                s: try row.string("s"),
                b: try row.data("b"),
                n: try row.optionalInt("n")
            )
        }
        let value = try #require(row)
        #expect(value.i == 42)
        #expect(value.d == 2.5)
        #expect(value.s == "héllo")
        #expect(value.b == blob)
        #expect(value.n == nil)
    }

    @Test("An empty blob round-trips as an empty blob rather than NULL")
    func emptyBlobRoundTrips() throws {
        let database = try Database.inMemory()
        try database.execute("CREATE TABLE t (b BLOB);")
        try database.run("INSERT INTO t (b) VALUES (:b);", ["b": .blob(Data())])
        let isNull = try database.first("SELECT b FROM t;") { try $0.isNull("b") }
        #expect(isNull == false)
    }

    @Test("Booleans and dates use the conventions the schema assumes")
    func conveniencesMatchSchemaConventions() throws {
        let database = try Database.inMemory()
        try database.execute("CREATE TABLE t (flag INTEGER, at INTEGER);")
        let when = Date(timeIntervalSince1970: 1_700_000_000)
        try database.run("INSERT INTO t (flag, at) VALUES (:flag, :at);", ["flag": SQLValue(true), "at": SQLValue(when)])

        let row = try database.first("SELECT flag, at FROM t;") { (try $0.bool("flag"), try $0.date("at")) }
        let value = try #require(row)
        #expect(value.0 == true)
        #expect(value.1 == when)
    }

    @Test("A mistyped parameter name is an error, not a silent NULL")
    func unknownParameterThrows() throws {
        let database = try Database.inMemory()
        try database.execute("CREATE TABLE t (i INTEGER);")
        #expect(throws: SQLUsageError.self) {
            try database.run("INSERT INTO t (i) VALUES (:eye);", ["i": 1])
        }
    }

    @Test("A mistyped column name is an error, and says what was available")
    func unknownColumnThrows() throws {
        let database = try Database.inMemory()
        try database.execute("CREATE TABLE t (alpha INTEGER);")
        try database.run("INSERT INTO t (alpha) VALUES (:a);", ["a": 1])
        #expect(throws: SQLUsageError.self) {
            _ = try database.first("SELECT alpha FROM t;") { try $0.int("alfa") }
        }
    }

    @Test("A required column that is NULL throws rather than defaulting")
    func nullInRequiredColumnThrows() throws {
        let database = try Database.inMemory()
        try database.execute("CREATE TABLE t (i INTEGER);")
        try database.run("INSERT INTO t (i) VALUES (NULL);")
        #expect(throws: SQLUsageError.self) {
            _ = try database.first("SELECT i FROM t;") { try $0.int("i") }
        }
    }

    // MARK: - Statement reuse

    @Test("The hot statements are prepared once and reused")
    func statementsAreCached() throws {
        let database = try Database.inMemory()
        try database.execute("CREATE TABLE t (i INTEGER);")
        let sql = "INSERT INTO t (i) VALUES (:i);"
        let first = try database.prepare(sql)
        let second = try database.prepare(sql)
        #expect(first === second)
    }

    @Test("A re-entrant use of the same SQL gets its own statement")
    func reentrantUseGetsAFreshStatement() throws {
        let database = try Database.inMemory()
        try database.execute("CREATE TABLE t (i INTEGER);")
        for i in 1...3 { try database.run("INSERT INTO t (i) VALUES (:i);", ["i": SQLValue(i)]) }

        let sql = "SELECT i FROM t ORDER BY i;"
        let outer = try database.prepare(sql)
        var seen: [Int] = []
        var innerWasDistinct = false
        try outer.query { row in
            seen.append(try row.int("i"))
            // Iterating the same SQL from inside the loop must not yank the
            // outer statement's position out from under it.
            let inner = try database.prepare(sql)
            innerWasDistinct = inner !== outer
            _ = try inner.all { try $0.int("i") }
        }
        #expect(seen == [1, 2, 3])
        #expect(innerWasDistinct)
    }

    @Test("Forgetting prepared statements is safe after a schema change")
    func forgettingStatementsSurvivesSchemaChange() throws {
        let database = try Database.inMemory()
        try database.execute("CREATE TABLE t (i INTEGER);")
        _ = try database.prepare("SELECT i FROM t;")
        database.forgetPreparedStatements()
        try database.execute("ALTER TABLE t ADD COLUMN j INTEGER;")
        let names = try database.first("SELECT * FROM t LIMIT 1;") { $0.columnNames } ?? []
        #expect(names.isEmpty)  // no rows, but preparing did not throw
    }

    // MARK: - Transactions

    @Test("A committed transaction keeps its writes")
    func transactionCommits() throws {
        let database = try Database.inMemory()
        try database.execute("CREATE TABLE t (i INTEGER);")
        try database.transaction {
            try database.run("INSERT INTO t (i) VALUES (:i);", ["i": 1])
            try database.run("INSERT INTO t (i) VALUES (:i);", ["i": 2])
        }
        #expect(try database.scalarInt("SELECT COUNT(*) FROM t;") == 2)
    }

    @Test("A throwing transaction rolls back all of its writes")
    func transactionRollsBack() throws {
        struct Boom: Error {}
        let database = try Database.inMemory()
        try database.execute("CREATE TABLE t (i INTEGER);")
        #expect(throws: Boom.self) {
            try database.transaction {
                try database.run("INSERT INTO t (i) VALUES (:i);", ["i": 1])
                throw Boom()
            }
        }
        #expect(try database.scalarInt("SELECT COUNT(*) FROM t;") == 0)
        // And the connection is usable afterwards rather than stuck mid-transaction.
        try database.run("INSERT INTO t (i) VALUES (:i);", ["i": 9])
        #expect(try database.scalarInt("SELECT COUNT(*) FROM t;") == 1)
    }

    @Test("A nested transaction becomes a savepoint the outer one survives")
    func nestedTransactionIsASavepoint() throws {
        struct Boom: Error {}
        let database = try Database.inMemory()
        try database.execute("CREATE TABLE t (i INTEGER);")
        try database.transaction {
            try database.run("INSERT INTO t (i) VALUES (:i);", ["i": 1])
            do {
                try database.transaction {
                    try database.run("INSERT INTO t (i) VALUES (:i);", ["i": 2])
                    throw Boom()
                }
            } catch is Boom {
                // Inner unwound; outer carries on.
            }
            try database.run("INSERT INTO t (i) VALUES (:i);", ["i": 3])
        }
        let values = try database.all("SELECT i FROM t ORDER BY i;") { try $0.int("i") }
        #expect(values == [1, 3])
    }

    @Test("A transaction returns its body's value")
    func transactionReturnsAValue() throws {
        let database = try Database.inMemory()
        try database.execute("CREATE TABLE t (i INTEGER);")
        let inserted = try database.transaction { () -> Int64 in
            try database.run("INSERT INTO t (i) VALUES (:i);", ["i": 5])
            return database.lastInsertRowID
        }
        #expect(inserted == 1)
    }

    // MARK: - Concurrency

    @Test("WAL lets a second connection read while the first is mid-write")
    func readerProceedsDuringWrite() throws {
        let directory = URL.temporaryDirectory.appending(path: "pgr-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appending(path: "library.sqlite").path(percentEncoded: false)

        let writer = try Database(path: path)
        let reader = try Database(path: path, busyTimeout: .milliseconds(50))
        try writer.execute("CREATE TABLE t (i INTEGER);")
        try writer.run("INSERT INTO t (i) VALUES (:i);", ["i": 1])

        try writer.execute("BEGIN IMMEDIATE;")
        try writer.run("INSERT INTO t (i) VALUES (:i);", ["i": 2])

        // The reader sees the pre-transaction snapshot and is not blocked by it.
        // This is the property Core Data's SQLite store does not offer, and the
        // reason the whole design is safe with an agent, an app, and a saver all
        // touching one file.
        #expect(try reader.scalarInt("SELECT COUNT(*) FROM t;") == 1)

        // A second writer, though, is refused — one writer at a time is exactly
        // what makes the deal atomic across processes.
        #expect(throws: SQLiteError.self) {
            try reader.execute("BEGIN IMMEDIATE;")
        }

        try writer.execute("COMMIT;")
        #expect(try reader.scalarInt("SELECT COUNT(*) FROM t;") == 2)
    }

    @Test("A busy transaction is retried rather than surfaced")
    func busyTransactionIsRetried() throws {
        let directory = URL.temporaryDirectory.appending(path: "pgr-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appending(path: "library.sqlite").path(percentEncoded: false)

        let holder = try Database(path: path)
        try holder.execute("CREATE TABLE t (i INTEGER);")

        // Hold the write lock, then release it from another thread shortly
        // after. Touching one connection from two threads is exactly what the
        // rest of the kit avoids; it is safe here only because the connection
        // is opened FULLMUTEX, and it is done deliberately to keep the test to
        // one process.
        try holder.execute("BEGIN IMMEDIATE;")
        let released = DispatchSemaphore(value: 0)
        let contender = try Database(path: path, busyTimeout: .milliseconds(10))

        DispatchQueue.global().asyncAfter(deadline: .now() + 0.15) {
            try? holder.execute("COMMIT;")
            released.signal()
        }

        // Backoff should carry this past the lock rather than throwing.
        try contender.transaction {
            try contender.run("INSERT INTO t (i) VALUES (:i);", ["i": 1])
        }
        released.wait()
        #expect(try contender.scalarInt("SELECT COUNT(*) FROM t;") == 1)
    }

    // MARK: - Integrity

    @Test("A freshly written database passes integrity_check")
    func integrityCheckPasses() throws {
        try Self.withTemporaryDatabase { database in
            try database.execute("CREATE TABLE t (i INTEGER);")
            try database.run("INSERT INTO t (i) VALUES (:i);", ["i": 1])
            #expect(try database.integrityCheck().isEmpty)
        }
    }
}
