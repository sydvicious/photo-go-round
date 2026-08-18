import Foundation
import Testing

@testable import PhotoGoRoundKit

@Suite("Migrator")
struct MigratorTests {

    /// A database with migrations 1...`version` applied and nothing else.
    /// `version` 0 gives an empty database.
    private static func database(atVersion version: Int) throws -> Database {
        let database = try Database.inMemory()
        for migration in Migrator.migrations where migration.version <= version {
            try database.transaction {
                try migration.apply(database)
                try database.setUserVersion(migration.version)
            }
        }
        return database
    }

    private static func fullyMigratedDatabase() throws -> Database {
        let database = try Database.inMemory()
        try Migrator.migrate(database)
        return database
    }

    // MARK: - The three the plan asks for

    @Test("Applying from empty reaches the latest version")
    func migratesFromEmpty() throws {
        let database = try Database.inMemory()
        #expect(try database.userVersion == 0)
        let reached = try Migrator.migrate(database)
        #expect(reached == Migrator.latestVersion)
        #expect(try database.userVersion == Migrator.latestVersion)
    }

    @Test("Migrating an already-current database changes nothing")
    func migrationIsIdempotent() throws {
        let database = try Self.fullyMigratedDatabase()
        let before = try SchemaSnapshot(of: database)
        _ = try Migrator.migrate(database)
        let after = try SchemaSnapshot(of: database)
        #expect(before == after)
    }

    /// The assertion that actually matters, and the one that will start earning
    /// its keep the moment there is a migration 2: whatever version a database
    /// is at, migrating it forward must produce the same schema as creating one
    /// from scratch.
    @Test(
        "Migrating from every intermediate version produces a freshly-created schema",
        arguments: 0...Migrator.latestVersion
    )
    func migratesFromEveryIntermediateVersion(startingVersion: Int) throws {
        let fresh = try Self.fullyMigratedDatabase()
        let expected = try SchemaSnapshot(of: fresh)

        let upgraded = try Self.database(atVersion: startingVersion)
        try Migrator.migrate(upgraded)
        let actual = try SchemaSnapshot(of: upgraded)

        #expect(actual == expected, "starting from version \(startingVersion)")
    }

    // MARK: - Refusing what it cannot understand

    @Test("A database from a newer build is refused rather than guessed at")
    func refusesNewerDatabase() throws {
        let database = try Self.fullyMigratedDatabase()
        try database.setUserVersion(Migrator.latestVersion + 5)
        #expect(throws: MigrationError.self) {
            try Migrator.migrate(database)
        }
    }

    @Test("A failing migration leaves the version where it was")
    func failedMigrationDoesNotAdvanceTheVersion() throws {
        let database = try Database.inMemory()
        // Reuse the real first migration, then a deliberately broken one.
        try database.transaction {
            try Migrator.migrations[0].apply(database)
            try database.setUserVersion(1)
        }
        let broken = Migration(version: 2, name: "broken", sql: "CREATE TABLE photo (oops INTEGER);")
        #expect(throws: (any Error).self) {
            try database.transaction {
                try broken.apply(database)
                try database.setUserVersion(2)
            }
        }
        #expect(try database.userVersion == 1)
        // And the table the broken migration collided with is intact.
        #expect(try database.scalarInt("SELECT COUNT(*) FROM photo;") == 0)
    }

    // MARK: - What the schema guarantees

    @Test("Every v1 table is present")
    func allTablesExist() throws {
        let database = try Self.fullyMigratedDatabase()
        let snapshot = try SchemaSnapshot(of: database)
        let names = Set(snapshot.tables.map(\.name))
        #expect(names == ["source", "photo", "queue", "consumer", "deck_state", "deck_event"])

        // No `available` flag on photo: a picture gone from a reachable source is
        // deleted, and a source that lost everything keeps its rows untouched.
        let photo = try #require(snapshot.tables.first { $0.name == "photo" })
        #expect(!photo.columns.contains { $0.name == "available" })
    }

    @Test("The deal ordinal starts at zero and there can only ever be one of it")
    func deckStateIsASingleton() throws {
        let database = try Self.fullyMigratedDatabase()
        #expect(try database.scalarInt("SELECT deal_seq FROM deck_state WHERE id = 1;") == 0)
        #expect(throws: SQLiteError.self) {
            try database.run("INSERT INTO deck_state (id, deal_seq) VALUES (:id, :seq);", ["id": 2, "seq": 0])
        }
    }

    @Test("A photo reachable from two sources is two rows; the same one twice is not")
    func photoUniquenessIsPerSource() throws {
        let database = try Self.fullyMigratedDatabase()
        let a = try Self.insertSource(named: "/a", into: database)
        let b = try Self.insertSource(named: "/b", into: database)

        try Self.insertPhoto(externalID: "holiday.heic", source: a, into: database)
        // Same relative path, different source: accepted, and it will be dealt
        // twice. Deduplication is out of scope for v1.
        try Self.insertPhoto(externalID: "holiday.heic", source: b, into: database)
        #expect(try database.scalarInt("SELECT COUNT(*) FROM photo;") == 2)

        #expect(throws: SQLiteError.self) {
            try Self.insertPhoto(externalID: "holiday.heic", source: a, into: database)
        }
    }

    @Test("Videos are expressible and audio is not")
    func mediaTypeIsAClosedSet() throws {
        let database = try Self.fullyMigratedDatabase()
        let source = try Self.insertSource(named: "/a", into: database)
        try Self.insertPhoto(externalID: "clip.mov", source: source, into: database, mediaType: "video")
        #expect(throws: SQLiteError.self) {
            try Self.insertPhoto(externalID: "song.m4a", source: source, into: database, mediaType: "audio")
        }
    }

    @Test("Storage is either referenced or materialized")
    func storageIsAClosedSet() throws {
        let database = try Self.fullyMigratedDatabase()
        let source = try Self.insertSource(named: "/a", into: database)
        try Self.insertPhoto(externalID: "one.heic", source: source, into: database, storage: "referenced")
        #expect(throws: SQLiteError.self) {
            try Self.insertPhoto(externalID: "two.heic", source: source, into: database, storage: "cloned")
        }
    }

    @Test("Deleting a source takes its photos and their queue entries with it")
    func deletingASourceCascades() throws {
        let database = try Self.fullyMigratedDatabase()
        let source = try Self.insertSource(named: "/a", into: database)
        try Self.insertPhoto(externalID: "one.heic", source: source, into: database)
        let photoID = database.lastInsertRowID

        try database.run(
            """
            INSERT INTO consumer (kind, display_id, seen_at, created_at)
            VALUES ('screensaver', NULL, 0, 0);
            """
        )
        let consumerID = database.lastInsertRowID
        try database.run(
            "INSERT INTO queue (photo_id, source_id, queued_at) VALUES (:p, :s, 0);",
            ["p": .int(photoID), "s": .int(source)]
        )

        try database.run("DELETE FROM source WHERE id = :id;", ["id": .int(source)])
        #expect(try database.scalarInt("SELECT COUNT(*) FROM photo;") == 0)
        #expect(try database.scalarInt("SELECT COUNT(*) FROM queue;") == 0)
        // The consumer survives — a display does not stop existing because a
        // folder was removed.
        #expect(try database.scalarInt("SELECT COUNT(*) FROM consumer;") == 1)
    }

    @Test("A consumer is identified by kind and display, with NULL a value like any other")
    func consumerIdentityIsUnique() throws {
        let database = try Self.fullyMigratedDatabase()
        try database.run(
            "INSERT INTO consumer (kind, display_id, seen_at, created_at) VALUES ('wallpaper', :d, 0, 0);",
            ["d": "DISPLAY-A"]
        )
        // A different display is a different consumer.
        try database.run(
            "INSERT INTO consumer (kind, display_id, seen_at, created_at) VALUES ('wallpaper', :d, 0, 0);",
            ["d": "DISPLAY-B"]
        )
        #expect(throws: SQLiteError.self) {
            try database.run(
                "INSERT INTO consumer (kind, display_id, seen_at, created_at) VALUES ('wallpaper', :d, 0, 0);",
                ["d": "DISPLAY-A"]
            )
        }

        // And two NULLs collide, which is why a surface with several instances
        // discriminates them in `kind`.
        try database.run(
            "INSERT INTO consumer (kind, display_id, seen_at, created_at) VALUES ('widget', NULL, 0, 0);"
        )
        #expect(throws: SQLiteError.self) {
            try database.run(
                "INSERT INTO consumer (kind, display_id, seen_at, created_at) VALUES ('widget', NULL, 0, 0);"
            )
        }
    }

    @Test("The deal is served by an index rather than a scan and a sort")
    func dealUsesTheDeckIndex() throws {
        let database = try Self.fullyMigratedDatabase()
        let plan = try database.all(
            """
            EXPLAIN QUERY PLAN
            SELECT id FROM photo
             WHERE source_enabled = 1 AND media_type = 'image'
               AND (last_dealt_seq IS NULL OR last_dealt_seq <= 100)
             ORDER BY shuffle_key
             LIMIT 1;
            """
        ) { $0.string(at: 3) ?? "" }
            .joined(separator: "\n")

        #expect(plan.contains("photo_deck") || plan.contains("photo_window"), "plan was:\n\(plan)")
        // The point of leading the index with the equality columns and ending at
        // shuffle_key: no sort of half the library on every deal.
        #expect(!plan.contains("USE TEMP B-TREE FOR ORDER BY"), "plan was:\n\(plan)")
    }

    @Test("A fully migrated database passes integrity_check")
    func migratedDatabaseIsSound() throws {
        let database = try Self.fullyMigratedDatabase()
        #expect(try database.integrityCheck().isEmpty)
    }

    // MARK: - Fixtures

    @discardableResult
    private static func insertSource(named locator: String, into database: Database) throws -> Int64 {
        try database.run(
            "INSERT INTO source (kind, locator, added_at) VALUES ('folder', :locator, 0);",
            ["locator": .text(locator)]
        )
        return database.lastInsertRowID
    }

    private static func insertPhoto(
        externalID: String,
        source: Int64,
        into database: Database,
        mediaType: String = "image",
        storage: String = "materialized"
    ) throws {
        try database.run(
            """
            INSERT INTO photo (source_id, external_id, media_type, storage, shuffle_key, added_at)
            VALUES (:source, :external, :media, :storage, :key, 0);
            """,
            [
                "source": .int(source),
                "external": .text(externalID),
                "media": .text(mediaType),
                "storage": .text(storage),
                "key": .double(0.5),
            ]
        )
    }
}
