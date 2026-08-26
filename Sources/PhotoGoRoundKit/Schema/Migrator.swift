import Foundation
import PhotoGoRoundAgentAPI

/// Applies the schema's history to a database.
///
/// A `user_version` pragma, an ordered array of migrations, and a loop that
/// applies the ones above the current version inside a transaction. This is the
/// single place a hand-rolled database layer most often goes wrong later, which
/// is why it has tests from the first commit.
public enum Migrator {

    /// Append-only. A migration that has run anywhere is never edited.
    static let migrations: [Migration] = [
        Migration(version: 1, name: "initial schema", sql: SchemaV1.sql),
        Migration(version: 2, name: "claim at selection", sql: SchemaV2.sql),
        Migration(version: 3, name: "render blacklist", sql: SchemaV3.sql),
        Migration(version: 4, name: "cache leaves the database", sql: SchemaV4.sql),
        Migration(version: 5, name: "count what reached a client", sql: SchemaV5.sql),
        Migration(version: 6, name: "the queue is not a queue", sql: SchemaV6.sql),
        Migration(version: 7, name: "residency is the deck's pool", sql: SchemaV7.sql),
        Migration(version: 8, name: "the queue is a queue again", sql: SchemaV8.sql),
    ]

    /// The version a fully migrated database reports.
    public static var latestVersion: Int {
        migrations.last?.version ?? 0
    }

    /// Brings `database` up to `latestVersion`, applying only what it is
    /// missing. A database already at the latest version is untouched.
    ///
    /// Each migration runs in its own transaction along with the version bump,
    /// so a failure part way through a sequence leaves the database at the last
    /// version that fully applied rather than somewhere in between.
    @discardableResult
    public static func migrate(_ database: Database) throws -> Int {
        assertVersionsAreSaneInDebug()

        let startingVersion = try database.userVersion
        guard startingVersion <= latestVersion else {
            // A database written by a newer build. Refusing is the only honest
            // answer: we cannot know what the extra columns mean.
            throw MigrationError.databaseIsNewerThanCode(
                databaseVersion: startingVersion,
                codeVersion: latestVersion
            )
        }

        let pending = migrations.filter { $0.version > startingVersion }
        guard !pending.isEmpty else { return startingVersion }

        Log.sql.notice(
            "migrating database from version \(startingVersion, privacy: .public) to \(latestVersion, privacy: .public)"
        )

        for migration in pending {
            let state = Log.signposter.beginInterval("migration")
            do {
                try database.transaction {
                    try migration.apply(database)
                    try database.setUserVersion(migration.version)
                }
            } catch {
                Log.signposter.endInterval("migration", state)
                Log.sql.error(
                    "migration \(migration.version, privacy: .public) failed: \(String(describing: error), privacy: .public)"
                )
                throw MigrationError.migrationFailed(
                    version: migration.version,
                    name: migration.name,
                    underlying: String(describing: error)
                )
            }
            Log.signposter.endInterval("migration", state)
            Log.sql.notice(
                "applied migration \(migration.version, privacy: .public): \(migration.name, privacy: .public)"
            )
        }

        // Statements prepared against the old schema may no longer be valid.
        database.forgetPreparedStatements()

        return try database.userVersion
    }

    /// Cheap invariants that would otherwise fail confusingly at runtime: a
    /// duplicated version, an out-of-order array, or a version below 1.
    private static func assertVersionsAreSaneInDebug() {
        #if DEBUG
        var previous = 0
        for migration in migrations {
            assert(
                migration.version == previous + 1,
                "migrations must be numbered from 1 with no gaps; \(migration.version) follows \(previous)"
            )
            previous = migration.version
        }
        #endif
    }
}

public enum MigrationError: Error, CustomStringConvertible, Sendable {
    case databaseIsNewerThanCode(databaseVersion: Int, codeVersion: Int)
    case migrationFailed(version: Int, name: String, underlying: String)

    public var description: String {
        switch self {
        case .databaseIsNewerThanCode(let databaseVersion, let codeVersion):
            "database is at schema version \(databaseVersion) but this build only knows version \(codeVersion)"
        case .migrationFailed(let version, let name, let underlying):
            "migration \(version) (\(name)) failed: \(underlying)"
        }
    }
}
