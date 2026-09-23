import Foundation

/// One step of the schema's history.
///
/// Migrations are append-only and never edited once they have run anywhere.
/// The version is what `PRAGMA user_version` records; the name is for the log.
public struct Migration: Sendable {
    public let version: Int
    public let name: String
    let apply: @Sendable (Database) throws -> Void

    init(version: Int, name: String, apply: @escaping @Sendable (Database) throws -> Void) {
        self.version = version
        self.name = name
        self.apply = apply
    }

    /// The common case: a migration that is just SQL.
    init(version: Int, name: String, sql: String) {
        self.init(version: version, name: name) { try $0.execute(sql) }
    }
}
