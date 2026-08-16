import SQLite3

/// A failure reported by `libsqlite3`, carrying the primary result code, the
/// extended result code, and whatever the library had to say about it.
public struct SQLiteError: Error, CustomStringConvertible, Sendable {
    /// The primary result code, e.g. `SQLITE_BUSY`.
    public let code: Int32
    /// The extended result code, e.g. `SQLITE_BUSY_SNAPSHOT`.
    public let extendedCode: Int32
    /// `sqlite3_errmsg` at the moment of failure.
    public let message: String
    /// What we were doing — the SQL, or a description of the operation.
    public let context: String

    public init(code: Int32, extendedCode: Int32, message: String, context: String) {
        self.code = code
        self.extendedCode = extendedCode
        self.message = message
        self.context = context
    }

    /// Builds an error from a connection handle, which is the only place the
    /// message and extended code are available.
    static func from(_ handle: OpaquePointer?, code: Int32, context: String) -> SQLiteError {
        let message = handle.flatMap { sqlite3_errmsg($0).map(String.init(cString:)) }
            ?? String(cString: sqlite3_errstr(code))
        let extended = handle.map { sqlite3_extended_errcode($0) } ?? code
        return SQLiteError(code: code, extendedCode: extended, message: message, context: context)
    }

    /// `SQLITE_BUSY` and `SQLITE_LOCKED` are normal outcomes under WAL
    /// contention rather than errors, so callers on the deal and reservation
    /// paths retry them.
    public var isBusy: Bool {
        code == SQLITE_BUSY || code == SQLITE_LOCKED
    }

    public var description: String {
        "sqlite3 error \(code)/\(extendedCode): \(message) — while \(context)"
    }
}

/// Failures that are ours rather than SQLite's.
public enum SQLUsageError: Error, CustomStringConvertible, Sendable {
    /// A binding was supplied for a parameter the statement does not have.
    /// Almost always a typo in a parameter name, which is exactly the class of
    /// bug the named-parameter surface exists to catch.
    case unknownParameter(name: String, sql: String)
    /// A column was requested by a name the result set does not contain.
    case unknownColumn(name: String, available: [String])
    /// A column held a type the caller did not expect and could not convert.
    case unexpectedNull(column: String)

    public var description: String {
        switch self {
        case .unknownParameter(let name, let sql):
            "no parameter named \(name) in: \(sql)"
        case .unknownColumn(let name, let available):
            "no column named \(name); have \(available.joined(separator: ", "))"
        case .unexpectedNull(let column):
            "column \(column) was NULL but a value was required"
        }
    }
}
