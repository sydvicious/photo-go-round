import Foundation

@testable import PhotoGoRoundKit

/// A structural description of a database's schema, for asserting that a
/// migrated database is indistinguishable from a freshly created one.
///
/// Structure comes from the pragmas rather than from the stored CREATE text,
/// because SQLite records `ALTER TABLE ADD COLUMN` by appending to the original
/// statement — so a table built by migration and the same table built fresh
/// have identical structure and different text. The stored text is captured
/// too, but only indexes and triggers compare on it, since those are always
/// created whole.
struct SchemaSnapshot: Equatable, CustomStringConvertible {

    struct Column: Equatable, CustomStringConvertible {
        var name: String
        var type: String
        var notNull: Bool
        var defaultValue: String?
        var primaryKeyPosition: Int

        var description: String {
            var parts = [name, type]
            if notNull { parts.append("NOT NULL") }
            if let defaultValue { parts.append("DEFAULT \(defaultValue)") }
            if primaryKeyPosition > 0 { parts.append("PK\(primaryKeyPosition)") }
            return parts.joined(separator: " ")
        }
    }

    struct ForeignKey: Equatable, CustomStringConvertible {
        var column: String
        var referencesTable: String
        var referencesColumn: String?
        var onDelete: String
        var onUpdate: String

        var description: String {
            "\(column) -> \(referencesTable).\(referencesColumn ?? "rowid") "
                + "ON DELETE \(onDelete) ON UPDATE \(onUpdate)"
        }
    }

    struct Table: Equatable, CustomStringConvertible {
        var name: String
        var columns: [Column]
        var foreignKeys: [ForeignKey]

        var description: String {
            "TABLE \(name)\n"
                + columns.map { "    \($0)" }.joined(separator: "\n")
                + (foreignKeys.isEmpty ? "" : "\n" + foreignKeys.map { "    FK \($0)" }.joined(separator: "\n"))
        }
    }

    /// Indexes and triggers, compared on their normalised definitions.
    struct Definition: Equatable, CustomStringConvertible {
        var kind: String
        var name: String
        var sql: String

        var description: String { "\(kind.uppercased()) \(name): \(sql)" }
    }

    var version: Int
    var tables: [Table]
    var definitions: [Definition]

    var description: String {
        "user_version = \(version)\n"
            + tables.map(\.description).joined(separator: "\n")
            + "\n"
            + definitions.map { "  \($0)" }.joined(separator: "\n")
    }

    // MARK: - Reading

    init(of database: Database) throws {
        version = try database.userVersion

        let tableNames = try database.all(
            """
            SELECT name FROM sqlite_master
             WHERE type = 'table' AND name NOT LIKE 'sqlite_%'
             ORDER BY name;
            """
        ) { try $0.string("name") }

        tables = try tableNames.map { name in
            Table(
                name: name,
                columns: try Self.columns(of: name, in: database),
                foreignKeys: try Self.foreignKeys(of: name, in: database)
            )
        }

        definitions = try database.all(
            """
            SELECT type, name, sql FROM sqlite_master
             WHERE type IN ('index', 'trigger', 'view')
               AND name NOT LIKE 'sqlite_%'
               AND sql IS NOT NULL
             ORDER BY type, name;
            """
        ) { row in
            Definition(
                kind: try row.string("type"),
                name: try row.string("name"),
                sql: Self.normalise(try row.string("sql"))
            )
        }
    }

    private static func columns(of table: String, in database: Database) throws -> [Column] {
        // PRAGMA does not take bound parameters, and the table names come from
        // sqlite_master rather than from anything a user typed.
        try database.all("PRAGMA table_info(\"\(table)\");") { row in
            Column(
                name: try row.string("name"),
                type: try row.string("type"),
                notNull: try row.bool("notnull"),
                defaultValue: try row.optionalString("dflt_value"),
                primaryKeyPosition: try row.int("pk")
            )
        }
        .sorted { $0.name < $1.name }
    }

    private static func foreignKeys(of table: String, in database: Database) throws -> [ForeignKey] {
        try database.all("PRAGMA foreign_key_list(\"\(table)\");") { row in
            ForeignKey(
                column: try row.string("from"),
                referencesTable: try row.string("table"),
                referencesColumn: try row.optionalString("to"),
                onDelete: try row.string("on_delete"),
                onUpdate: try row.string("on_update")
            )
        }
        .sorted { ($0.column, $0.referencesTable) < ($1.column, $1.referencesTable) }
    }

    /// Strips `--` comments and collapses whitespace, so a definition that was
    /// only reformatted still compares equal.
    private static func normalise(_ sql: String) -> String {
        sql
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                guard let commentStart = line.range(of: "--") else { return line }
                return line[line.startIndex..<commentStart.lowerBound]
            }
            .joined(separator: " ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }
}
