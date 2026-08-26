import Foundation
import SQLite3
import PhotoGoRoundAgentAPI

/// A connection to the library database.
///
/// Deliberately thin. It opens the file the way this project needs it opened,
/// caches the prepared statements the hot paths reuse, and knows that
/// `SQLITE_BUSY` is a normal outcome under WAL rather than an error.
///
/// Not `Sendable`, and that is the design. Multi-process access is SQLite's job
/// and WAL's; multi-*thread* access is avoided entirely by giving each
/// isolation domain its own connection.
public final class Database {
    /// How a transaction takes its lock.
    public enum TransactionKind: String {
        /// Defers the write lock until the first write, which means discovering
        /// a conflict at COMMIT. Fine for pure reads.
        case deferred = "DEFERRED"
        /// Takes the write lock up front. Everything that writes uses this —
        /// notably serving a picture, which is the statement two processes race
        /// on.
        case immediate = "IMMEDIATE"
    }

    let handle: OpaquePointer

    /// The file this connection was opened on, or `:memory:`.
    public let path: String

    /// How long a contended transaction keeps trying before it gives up.
    /// Honoured by `transaction`, not by SQLite — see the note at the pragma.
    public let busyTimeout: Duration

    private var cachedStatements: [String: Statement] = [:]
    private var transactionDepth = 0
    private var savepointCounter = 0

    /// How long SQLite itself waits on a locked database before giving up and
    /// returning `SQLITE_BUSY`. Retry-with-backoff sits on top of this.
    public static let defaultBusyTimeout: Duration = .seconds(5)

    /// What SQLite itself may still wait, in milliseconds, to absorb momentary
    /// page contention on statements that have no retry of their own.
    static let incidentalWait: Int32 = 50

    // MARK: - Opening

    /// Opens (creating if necessary) the database at `path`.
    ///
    /// `FULLMUTEX` is belt and braces: the connection is confined to one
    /// isolation domain by construction, but serialized mode costs nothing
    /// measurable and removes a class of misuse that fails silently.
    public init(path: String, busyTimeout: Duration = Database.defaultBusyTimeout) throws {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_URI
        let code = sqlite3_open_v2(path, &handle, flags, nil)
        guard code == SQLITE_OK, let handle else {
            // sqlite3_open_v2 hands back a handle even on failure, purely so the
            // error can be read off it. Close it before throwing.
            let error = SQLiteError.from(handle, code: code, context: "opening database")
            if let handle { sqlite3_close_v2(handle) }
            throw error
        }
        self.handle = handle
        self.path = path

        sqlite3_extended_result_codes(handle, 1)
        // **Zero, deliberately, and the budget is honoured in Swift instead.**
        //
        // `sqlite3_busy_timeout` waits by blocking the calling thread inside
        // `sqlite3_step`. That is fine on a thread we own and ruinous on a
        // cooperative-pool thread: at five seconds an attempt, a contended
        // transaction could hold one of a handful of pool threads for most of a
        // minute, and several at once starve every other async operation in the
        // process. Serving a picture was measured at 122 seconds on 2026-08-25
        // with the database under a long refresh.
        //
        // So SQLite returns `SQLITE_BUSY` immediately and `transaction` does the
        // waiting — on a clock it can honour with `Thread.sleep` or `Task.sleep`
        // depending on who is calling. Same total patience, no hostage thread.
        //
        // Not quite zero, and the residue is deliberate. `transaction` retries,
        // but a bare `run` or `first` outside one does not — and with a flat
        // zero those would start failing on the brief page contention WAL
        // produces at a checkpoint, where before SQLite simply absorbed it.
        // Fifty milliseconds is far too short to hold a thread hostage and long
        // enough to swallow that, so the un-retried statements keep the
        // robustness they had and the long waiting is still ours.
        sqlite3_busy_timeout(handle, Self.incidentalWait)
        self.busyTimeout = busyTimeout

        do {
            // Per-connection, every time.
            try execute("PRAGMA foreign_keys = ON;")

            // Per-database, but idempotent and cheap to reassert. WAL is what
            // makes multi-process access safe, which is the whole reason this
            // is SQLite rather than Core Data. It is a no-op for :memory:.
            if !isInMemory {
                try execute("PRAGMA journal_mode = WAL;")
                // NORMAL is the correct pairing with WAL: durable across process
                // crashes, which is all we need, and it avoids an fsync per commit.
                try execute("PRAGMA synchronous = NORMAL;")
            }
        } catch {
            sqlite3_close_v2(handle)
            throw error
        }
    }

    /// A private in-memory database, for tests and for anything that wants the
    /// schema without a file.
    public static func inMemory() throws -> Database {
        try Database(path: ":memory:")
    }

    deinit {
        // Statements hold references into the connection, so they must be gone
        // before it closes. close_v2 tolerates outstanding statements anyway,
        // but being explicit keeps the ordering obvious.
        cachedStatements.removeAll()
        sqlite3_close_v2(handle)
    }

    private var isInMemory: Bool {
        path == ":memory:" || path.hasPrefix("file::memory:")
    }

    // MARK: - Statements

    /// Prepares a statement, reusing the cached one when there is a cached one
    /// to reuse.
    ///
    /// Serving and selecting run constantly, so re-preparing them every time
    /// would be waste. A statement that is currently being iterated
    /// is not handed out again — re-entrant use gets its own.
    public func prepare(_ sql: String) throws -> Statement {
        if let cached = cachedStatements[sql], !cached.isActive {
            cached.reset()
            return cached
        }
        let statement = try Statement(connection: handle, sql: sql)
        if cachedStatements[sql] == nil {
            cachedStatements[sql] = statement
        }
        return statement
    }

    /// Drops the prepared-statement cache. Needed after a migration, since a
    /// statement prepared against the old schema may no longer be valid.
    public func forgetPreparedStatements() {
        cachedStatements.removeAll()
    }

    // MARK: - Running SQL

    /// Runs SQL that returns no rows. Accepts multiple statements, which is why
    /// this goes through `sqlite3_exec` rather than the statement wrapper —
    /// migrations are written as scripts.
    public func execute(_ sql: String) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        let code = sqlite3_exec(handle, sql, nil, nil, &errorMessage)
        guard code == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? String(cString: sqlite3_errstr(code))
            sqlite3_free(errorMessage)
            throw SQLiteError(
                code: code,
                extendedCode: sqlite3_extended_errcode(handle),
                message: message,
                context: "executing: \(sql)"
            )
        }
    }

    /// Runs one parameterised statement that returns no rows.
    public func run(_ sql: String, _ bindings: SQLBindings = [:]) throws {
        try prepare(sql).execute(bindings)
    }

    /// Runs a query and returns the transformed first row, or nil.
    public func first<T>(_ sql: String, _ bindings: SQLBindings = [:], _ transform: (Row) throws -> T) throws -> T? {
        try prepare(sql).first(bindings, transform)
    }

    /// Runs a query and returns every transformed row.
    public func all<T>(_ sql: String, _ bindings: SQLBindings = [:], _ transform: (Row) throws -> T) throws -> [T] {
        try prepare(sql).all(bindings, transform)
    }

    /// Runs a query and calls `each` once per row, without collecting them.
    /// This is the one to use when a scan could return fifty thousand rows.
    public func query(_ sql: String, _ bindings: SQLBindings = [:], each: (Row) throws -> Void) throws {
        try prepare(sql).query(bindings, each: each)
    }

    /// First column of the first row as an integer, or nil if the query
    /// returned nothing. `COUNT(*)` and friends.
    public func scalarInt(_ sql: String, _ bindings: SQLBindings = [:]) throws -> Int? {
        try first(sql, bindings) { $0.isNull(at: 0) ? nil : $0.int(at: 0) } ?? nil
    }

    /// First column of the first row as a string, or nil.
    public func scalarString(_ sql: String, _ bindings: SQLBindings = [:]) throws -> String? {
        try first(sql, bindings) { $0.string(at: 0) } ?? nil
    }

    /// Rowid of the most recent successful insert on this connection.
    public var lastInsertRowID: Int64 {
        sqlite3_last_insert_rowid(handle)
    }

    /// Rows changed by the most recent statement on this connection.
    public var changes: Int {
        Int(sqlite3_changes(handle))
    }

    // MARK: - Transactions

    /// Runs `body` inside a transaction, retrying the whole thing if SQLite
    /// reports contention.
    ///
    /// WAL permits exactly one writer, so `SQLITE_BUSY` is an ordinary outcome
    /// rather than a failure. `sqlite3_busy_timeout` absorbs most of it; the
    /// paths two processes genuinely race on — serving a picture — want this
    /// retry as well, because a busy *snapshot* at COMMIT cannot be
    /// waited out and has to be replayed.
    ///
    /// `body` is therefore called more than once in the contended case, so it
    /// must be safe to replay. Every caller in this kit satisfies that by doing
    /// all of its reading inside the transaction.
    @discardableResult
    public func transaction<T>(
        _ kind: TransactionKind = .immediate,
        within budget: Duration? = nil,
        _ body: () throws -> T
    ) throws -> T {
        try retrying(kind, within: budget, body) { delay in Thread.sleep(forTimeInterval: delay) }
    }

    /// The same transaction, for a caller that is already `async`.
    ///
    /// **The only difference is how it waits, and it is the whole reason this
    /// exists.** The synchronous form sleeps a thread. On the cooperative pool
    /// that thread is one of very few and is holding up everything else in the
    /// process; here the wait is a suspension, so the pool gets the thread back
    /// and the contended caller costs nothing but its own progress.
    ///
    /// `body` is synchronous on purpose. A transaction that awaits inside itself
    /// holds SQLite's single writer across a suspension of unbounded length,
    /// which is the deadlock this project would least enjoy finding.
    @discardableResult
    public func transaction<T>(
        _ kind: TransactionKind = .immediate,
        within budget: Duration? = nil,
        isolation: isolated (any Actor)? = #isolation,
        _ body: () throws -> T
    ) async throws -> T {
        // Written out here rather than delegated to a helper: a separate
        // `async` method on a non-`Sendable` class is a region crossing, and
        // Swift 6 is right to refuse it. Inheriting the caller's isolation and
        // staying put is what keeps this connection in the one domain it
        // belongs to.
        if transactionDepth > 0 { return try savepoint(body) }

        let deadline = ContinuousClock.now + (budget ?? busyTimeout)
        var attempt = 0
        while true {
            if let result = try attemptTransaction(kind, body) { return result }
            attempt += 1
            guard ContinuousClock.now < deadline else { throw SQLiteError.busyAfterWaiting }
            Log.sql.debug(
                "awaiting a busy database, attempt \(attempt, privacy: .public)")
            // **A suspension, not a sleeping thread.** This is the whole of F.
            //
            // Cancellation is honoured rather than swallowed: a caller that has
            // been cancelled has no interest in the writer any more, and going
            // on waiting for it would keep a queue of doomed transactions
            // contending for the lock behind whatever is still live.
            try await Task.sleep(
                for: .milliseconds(Int(Self.backoffInterval(attempt: attempt) * 1000)))
        }
    }

    /// One attempt, plus the bookkeeping that makes a replay safe.
    ///
    /// Returns nil when the attempt was refused for contention and is worth
    /// making again, so both retry loops share every rule except how they wait.
    private func attemptTransaction<T>(
        _ kind: TransactionKind, _ body: () throws -> T
    ) throws -> T? {
        do {
            try execute("BEGIN \(kind.rawValue);")
            transactionDepth = 1
            do {
                let result = try body()
                try execute("COMMIT;")
                transactionDepth = 0
                return result
            } catch {
                // ROLLBACK can itself fail if the transaction was already
                // rolled back by SQLite; that is not the error worth
                // reporting, so the original one wins.
                try? execute("ROLLBACK;")
                transactionDepth = 0
                throw error
            }
        } catch let error as SQLiteError where error.isBusy {
            return nil
        }
    }

    private func retrying<T>(
        _ kind: TransactionKind,
        within budget: Duration?,
        _ body: () throws -> T,
        wait: (TimeInterval) -> Void
    ) throws -> T {
        // A nested transaction becomes a savepoint. Retry belongs to the
        // outermost one, since only it can replay the whole unit of work.
        if transactionDepth > 0 { return try savepoint(body) }

        let deadline = ContinuousClock.now + (budget ?? busyTimeout)
        var attempt = 0
        while true {
            if let result = try attemptTransaction(kind, body) { return result }
            attempt += 1
            guard ContinuousClock.now < deadline else { throw SQLiteError.busyAfterWaiting }
            Log.sql.debug(
                "retrying transaction after busy, attempt \(attempt, privacy: .public)")
            wait(Self.backoffInterval(attempt: attempt))
        }
    }

    private func savepoint<T>(_ body: () throws -> T) throws -> T {
        savepointCounter += 1
        let name = "pgr_sp_\(savepointCounter)"
        try execute("SAVEPOINT \(name);")
        transactionDepth += 1
        defer { transactionDepth -= 1 }
        do {
            let result = try body()
            try execute("RELEASE \(name);")
            return result
        } catch {
            try? execute("ROLLBACK TO \(name);")
            try? execute("RELEASE \(name);")
            throw error
        }
    }

    /// Exponential backoff with jitter, capped. The jitter matters: without it,
    /// two processes that collide once tend to collide again on the same
    /// schedule.
    /// **Capped higher than it used to be, because SQLite is no longer waiting
    /// too.** The old 200 ms ceiling sat on top of a five-second `busy_timeout`,
    /// so the real patience came from SQLite. With that at zero, all of it is
    /// here, and a ceiling low enough to spin would turn a busy database into a
    /// hot loop.
    private static func backoffInterval(attempt: Int) -> TimeInterval {
        let base = min(0.250, 0.002 * pow(2, Double(attempt - 1)))
        return base * Double.random(in: 0.5...1.5)
    }

    // MARK: - Pragmas

    /// `PRAGMA user_version`, which is what the migrator uses to decide what to
    /// apply.
    public var userVersion: Int {
        get throws { try scalarInt("PRAGMA user_version;") ?? 0 }
    }

    public func setUserVersion(_ version: Int) throws {
        // PRAGMA does not accept a bound parameter for its value.
        try execute("PRAGMA user_version = \(version);")
    }

    /// Runs `PRAGMA integrity_check` and returns whatever it complained about.
    /// An empty array means the database is sound.
    public func integrityCheck() throws -> [String] {
        try all("PRAGMA integrity_check;") { $0.string(at: 0) ?? "" }
            .filter { $0 != "ok" }
    }
}

extension Duration {
    /// Whole milliseconds, rounded down. `sqlite3_busy_timeout` takes an Int32.
    var milliseconds: Int {
        let (seconds, attoseconds) = components
        return Int(seconds) * 1000 + Int(attoseconds / 1_000_000_000_000_000)
    }
}
