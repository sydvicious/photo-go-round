import Foundation
import SQLite3

/// `SQLITE_TRANSIENT` is a macro and does not import, so it is spelled out
/// here once. It tells SQLite to copy the bytes, which is what we want
/// everywhere — no bound buffer has to outlive the bind call.
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// A prepared statement, bound by parameter name rather than by index.
///
/// Binding by name is the whole point of this wrapper: it makes a mistyped
/// parameter a thrown error at the call site instead of a silently-NULL column
/// three tables away, and it removes index miscounting as a category of bug.
///
/// Not `Sendable`. A statement belongs to its `Database`, and a `Database`
/// belongs to whatever isolation domain opened it.
public final class Statement {
    private let connection: OpaquePointer
    private let handle: OpaquePointer
    private var columnIndexByName: [String: Int32] = [:]

    /// The SQL this statement was prepared from. Kept for error messages.
    public let sql: String

    /// True between the first `step()` that returned a row and the `reset()`
    /// that ends the iteration. The `Database` statement cache consults this so
    /// a re-entrant use of the same SQL gets a fresh statement rather than
    /// yanking the one being iterated out from under its caller.
    private(set) var isActive = false

    init(connection: OpaquePointer, sql: String) throws {
        var stmt: OpaquePointer?
        let code = sqlite3_prepare_v2(connection, sql, -1, &stmt, nil)
        guard code == SQLITE_OK, let stmt else {
            throw SQLiteError.from(connection, code: code, context: "preparing: \(sql)")
        }
        self.connection = connection
        self.handle = stmt
        self.sql = sql

        // Result column names are known at prepare time, so the name→index map
        // is built once rather than per row.
        for index in 0..<sqlite3_column_count(stmt) {
            if let name = sqlite3_column_name(stmt, index) {
                columnIndexByName[String(cString: name)] = index
            }
        }
    }

    deinit {
        sqlite3_finalize(handle)
    }

    // MARK: - Binding

    /// Binds every supplied parameter, clearing anything left over from a
    /// previous execution first so a partial binding cannot inherit stale
    /// values.
    public func bind(_ bindings: SQLBindings) throws {
        sqlite3_clear_bindings(handle)
        for (name, value) in bindings {
            guard let index = parameterIndex(for: name) else {
                throw SQLUsageError.unknownParameter(name: name, sql: sql)
            }
            try bind(value, at: index)
        }
    }

    /// `sqlite3_bind_parameter_index` wants the sigil included, but call sites
    /// read better writing `["seq": …]` than `[":seq": …]`. Accept either, and
    /// try the three sigils SQLite recognises before giving up.
    private func parameterIndex(for name: String) -> Int32? {
        if let first = name.first, first == ":" || first == "@" || first == "$" {
            let index = sqlite3_bind_parameter_index(handle, name)
            return index > 0 ? index : nil
        }
        for sigil in [":", "@", "$"] {
            let index = sqlite3_bind_parameter_index(handle, sigil + name)
            if index > 0 { return index }
        }
        return nil
    }

    private func bind(_ value: SQLValue, at index: Int32) throws {
        let code: Int32 = switch value {
        case .null:
            sqlite3_bind_null(handle, index)
        case .int(let v):
            sqlite3_bind_int64(handle, index, v)
        case .double(let v):
            sqlite3_bind_double(handle, index, v)
        case .text(let v):
            sqlite3_bind_text(handle, index, v, -1, SQLITE_TRANSIENT)
        case .blob(let v):
            v.isEmpty
                ? sqlite3_bind_zeroblob(handle, index, 0)
                : v.withUnsafeBytes {
                    sqlite3_bind_blob(handle, index, $0.baseAddress, Int32($0.count), SQLITE_TRANSIENT)
                }
        }
        guard code == SQLITE_OK else {
            throw SQLiteError.from(connection, code: code, context: "binding parameter \(index) of: \(sql)")
        }
    }

    // MARK: - Execution

    /// Advances the statement. Returns true if a row is available.
    @discardableResult
    public func step() throws -> Bool {
        let code = sqlite3_step(handle)
        switch code {
        case SQLITE_ROW:
            isActive = true
            return true
        case SQLITE_DONE:
            isActive = false
            return false
        default:
            isActive = false
            throw SQLiteError.from(connection, code: code, context: "stepping: \(sql)")
        }
    }

    /// Returns the statement to its pre-execution state. Safe to call at any
    /// point, including part way through a result set.
    public func reset() {
        sqlite3_reset(handle)
        isActive = false
    }

    /// Runs a statement that returns no rows.
    public func execute(_ bindings: SQLBindings = [:]) throws {
        defer { reset() }
        reset()
        try bind(bindings)
        while try step() {}
    }

    /// Runs a statement and calls `each` once per row.
    ///
    /// The `Row` handed to the closure is a view onto this statement's current
    /// position. Read what you need from it inside the closure; do not store it.
    public func query(_ bindings: SQLBindings = [:], each: (Row) throws -> Void) throws {
        defer { reset() }
        reset()
        try bind(bindings)
        let row = Row(statement: self)
        while try step() {
            try each(row)
        }
    }

    /// Runs a statement and returns the transformed first row, or nil if there
    /// were none. The statement is reset either way, so a `LIMIT 1` query does
    /// not leave a read transaction open behind it.
    public func first<T>(_ bindings: SQLBindings = [:], _ transform: (Row) throws -> T) throws -> T? {
        defer { reset() }
        reset()
        try bind(bindings)
        guard try step() else { return nil }
        return try transform(Row(statement: self))
    }

    /// Runs a statement and collects every row.
    public func all<T>(_ bindings: SQLBindings = [:], _ transform: (Row) throws -> T) throws -> [T] {
        var results: [T] = []
        try query(bindings) { results.append(try transform($0)) }
        return results
    }

    // MARK: - Column access

    var columnCount: Int32 { sqlite3_column_count(handle) }

    var columnNames: [String] {
        columnIndexByName.sorted { $0.value < $1.value }.map(\.key)
    }

    func columnIndex(_ name: String) throws -> Int32 {
        guard let index = columnIndexByName[name] else {
            throw SQLUsageError.unknownColumn(name: name, available: columnNames)
        }
        return index
    }

    func isNull(at index: Int32) -> Bool {
        sqlite3_column_type(handle, index) == SQLITE_NULL
    }

    func int64(at index: Int32) -> Int64 {
        sqlite3_column_int64(handle, index)
    }

    func double(at index: Int32) -> Double {
        sqlite3_column_double(handle, index)
    }

    func text(at index: Int32) -> String? {
        sqlite3_column_text(handle, index).map { String(cString: $0) }
    }

    func blob(at index: Int32) -> Data? {
        guard let bytes = sqlite3_column_blob(handle, index) else { return nil }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(handle, index)))
    }
}

/// A view onto one row of a result set, addressed by column name.
///
/// Valid for the duration of the closure it is handed to. It holds its
/// statement strongly, so an escaped `Row` reads the statement's later position
/// rather than dangling — wrong, but not unsafe.
public struct Row {
    let statement: Statement

    /// Columns this row actually has, in order. Useful in tests and in
    /// diagnostics; production code addresses columns by name.
    public var columnNames: [String] { statement.columnNames }

    // Positional access, for the handful of places where a query has exactly
    // one unnamed column — `PRAGMA user_version`, `COUNT(*)`, and friends.

    public func isNull(at index: Int32) -> Bool { statement.isNull(at: index) }
    public func int64(at index: Int32) -> Int64 { statement.int64(at: index) }
    public func int(at index: Int32) -> Int { Int(statement.int64(at: index)) }
    public func double(at index: Int32) -> Double { statement.double(at: index) }
    public func string(at index: Int32) -> String? { statement.text(at: index) }
    public func data(at index: Int32) -> Data? { statement.blob(at: index) }

    public func isNull(_ column: String) throws -> Bool {
        statement.isNull(at: try statement.columnIndex(column))
    }

    public func int64(_ column: String) throws -> Int64 {
        let index = try statement.columnIndex(column)
        guard !statement.isNull(at: index) else {
            throw SQLUsageError.unexpectedNull(column: column)
        }
        return statement.int64(at: index)
    }

    public func int(_ column: String) throws -> Int {
        Int(try int64(column))
    }

    public func bool(_ column: String) throws -> Bool {
        try int64(column) != 0
    }

    public func double(_ column: String) throws -> Double {
        let index = try statement.columnIndex(column)
        guard !statement.isNull(at: index) else {
            throw SQLUsageError.unexpectedNull(column: column)
        }
        return statement.double(at: index)
    }

    public func string(_ column: String) throws -> String {
        let index = try statement.columnIndex(column)
        guard let value = statement.text(at: index) else {
            throw SQLUsageError.unexpectedNull(column: column)
        }
        return value
    }

    public func data(_ column: String) throws -> Data {
        let index = try statement.columnIndex(column)
        guard let value = statement.blob(at: index) else {
            throw SQLUsageError.unexpectedNull(column: column)
        }
        return value
    }

    public func optionalInt64(_ column: String) throws -> Int64? {
        let index = try statement.columnIndex(column)
        return statement.isNull(at: index) ? nil : statement.int64(at: index)
    }

    public func optionalInt(_ column: String) throws -> Int? {
        try optionalInt64(column).map(Int.init)
    }

    public func optionalString(_ column: String) throws -> String? {
        statement.text(at: try statement.columnIndex(column))
    }

    public func optionalData(_ column: String) throws -> Data? {
        statement.blob(at: try statement.columnIndex(column))
    }

    /// Timestamps are whole seconds since the epoch throughout the schema.
    public func date(_ column: String) throws -> Date {
        Date(timeIntervalSince1970: Double(try int64(column)))
    }

    public func optionalDate(_ column: String) throws -> Date? {
        try optionalInt64(column).map { Date(timeIntervalSince1970: Double($0)) }
    }
}
