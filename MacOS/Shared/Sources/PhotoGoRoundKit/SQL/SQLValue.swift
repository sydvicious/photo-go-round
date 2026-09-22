import Foundation

/// The five storage classes SQLite actually has.
///
/// Call sites bind by name into a dictionary of these rather than calling
/// `sqlite3_bind_int64(stmt, 3, …)` and counting indices by hand.
public enum SQLValue: Sendable, Equatable {
    case null
    case int(Int64)
    case double(Double)
    case text(String)
    case blob(Data)
}

extension SQLValue: ExpressibleByNilLiteral {
    public init(nilLiteral: ()) { self = .null }
}

extension SQLValue: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int64) { self = .int(value) }
}

extension SQLValue: ExpressibleByFloatLiteral {
    public init(floatLiteral value: Double) { self = .double(value) }
}

extension SQLValue: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { self = .text(value) }
}

extension SQLValue: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) { self = .int(value ? 1 : 0) }
}

extension SQLValue {
    public init(_ value: Int) { self = .int(Int64(value)) }
    public init(_ value: Int64) { self = .int(value) }
    public init(_ value: Double) { self = .double(value) }
    public init(_ value: String) { self = .text(value) }
    public init(_ value: Data) { self = .blob(value) }

    /// SQLite has no boolean type; we store 0 and 1 and say so here once.
    public init(_ value: Bool) { self = .int(value ? 1 : 0) }

    public init(_ value: Int?) { self = value.map { .int(Int64($0)) } ?? .null }
    public init(_ value: Int64?) { self = value.map { .int($0) } ?? .null }
    public init(_ value: Double?) { self = value.map { .double($0) } ?? .null }
    public init(_ value: String?) { self = value.map { .text($0) } ?? .null }
    public init(_ value: Bool?) { self = value.map { .int($0 ? 1 : 0) } ?? .null }

    /// Timestamps are stored as whole seconds since the epoch, everywhere.
    public init(_ value: Date) { self = .int(Int64(value.timeIntervalSince1970.rounded())) }
    public init(_ value: Date?) { self = value.map { SQLValue($0) } ?? .null }
}

/// Named bindings for one statement execution.
public typealias SQLBindings = [String: SQLValue]
