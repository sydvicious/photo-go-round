import Foundation
import Testing

@testable import PhotoGoRoundAgentAPI
@testable import PhotoGoRoundKit

/// One photograph is one row, whichever source found it.
///
/// The rule is written twice on purpose — in Swift, in `PhotoPool.identity`,
/// for rows being inserted now; and in SQL, in `SchemaV9`, to backfill rows
/// that predate the column. Nothing but this suite would notice the two
/// drifting apart, and a drift would be silent: rows would still insert, and
/// the ones the migration had already written would simply stop matching the
/// ones intake writes afterwards.
@Suite("One photograph, one row")
struct PhotoIdentityTests {

    // MARK: - Building the fixtures

    private static func source(
        _ kind: SourceKind, at locator: String, in library: TestLibrary
    ) throws -> Source {
        let id = try library.addSource(kind: kind.rawValue, locator: locator)
        return Source(
            id: id, uuid: "SOURCE-\(id)", kind: kind, locator: locator,
            addedAt: Date(timeIntervalSince1970: 0))
    }

    private static func found(_ externalID: String) -> DiscoveredPhoto {
        DiscoveredPhoto(
            externalID: externalID, mediaType: .image, storage: .materialized, byteSize: 1)
    }

    private static func photoCount(in library: TestLibrary) throws -> Int {
        try library.database.scalarInt("SELECT COUNT(*) FROM photo;") ?? 0
    }

    // MARK: - The rule itself

    @Test("A folder's identity is the absolute path, not the relative one it is stored under")
    func folderIdentityIsAbsolute() {
        let source = Source(
            id: 1, uuid: "u", kind: .folder, locator: "/pictures/",
            addedAt: Date(timeIntervalSince1970: 0))
        #expect(PhotoPool.identity(of: "2024/trip.heic", in: source) == "/pictures/2024/trip.heic")
    }

    /// The branch that has to agree with `FileAccess.withPhotoURL`, which takes
    /// the same one: *a file source's locator is the photograph*. If this
    /// joined the external id the way a folder does, one file added twice —
    /// once on its own, once inside a folder — would be two rows.
    @Test("A file source is its locator, and ignores the external id entirely")
    func fileIdentityIsTheLocator() {
        let source = Source(
            id: 1, uuid: "u", kind: .file, locator: "/pictures/2024/trip.heic",
            addedAt: Date(timeIntervalSince1970: 0))
        #expect(PhotoPool.identity(of: "anything at all", in: source) == "/pictures/2024/trip.heic")
        #expect(PhotoPool.identity(of: "", in: source) == "/pictures/2024/trip.heic")
    }

    @Test("A Photos asset is identified by itself, whichever collection found it")
    func photosIdentityIsTheAsset() {
        let favorites = Source(
            id: 1, uuid: "u1", kind: .photosCollection, locator: "COLLECTION-FAVORITES",
            addedAt: Date(timeIntervalSince1970: 0))
        let livePhotos = Source(
            id: 2, uuid: "u2", kind: .photosCollection, locator: "COLLECTION-LIVE",
            addedAt: Date(timeIntervalSince1970: 0))
        let asset = "A1B2C3D4-1111-2222-3333-444455556666/L0/001"
        #expect(PhotoPool.identity(of: asset, in: favorites) == asset)
        #expect(
            PhotoPool.identity(of: asset, in: favorites)
                == PhotoPool.identity(of: asset, in: livePhotos))
    }

    @Test("Two folders that resolve to different files stay different")
    func differentFilesStayDifferent() {
        let source = Source(
            id: 1, uuid: "u", kind: .folder, locator: "/pictures/",
            addedAt: Date(timeIntervalSince1970: 0))
        #expect(
            PhotoPool.identity(of: "a.heic", in: source)
                != PhotoPool.identity(of: "b.heic", in: source))
    }

    // MARK: - What intake does with it

    @Test("One asset in two collections is one row, and it stays with the collection that found it")
    func sameAssetInTwoCollections() throws {
        let library = try TestLibrary()
        let pool = PhotoPool(database: library.database)
        let favorites = try Self.source(.photosCollection, at: "COLLECTION-FAVORITES", in: library)
        let live = try Self.source(.photosCollection, at: "COLLECTION-LIVE", in: library)
        let asset = "A1B2C3D4-1111-2222-3333-444455556666/L0/001"

        let first = try pool.upsert([Self.found(asset)], to: favorites)
        let second = try pool.upsert([Self.found(asset)], to: live)

        #expect(first.added == 1)
        #expect(second.added == 0)
        #expect(try Self.photoCount(in: library) == 1)
        #expect(
            try library.database.scalarInt("SELECT source_id FROM photo;")
                == Int(favorites.id))
    }

    /// The case that made this worth doing at all: a parent walked recursively
    /// and a child added beside it. The two store the same file under two
    /// different relative paths, so `UNIQUE (source_id, external_id)` never
    /// saw a conflict.
    @Test("A file reached through two overlapping folders is one row")
    func overlappingFolders() throws {
        let library = try TestLibrary()
        let pool = PhotoPool(database: library.database)
        let parent = try Self.source(.folder, at: "/pictures/", in: library)
        let child = try Self.source(.folder, at: "/pictures/2024/", in: library)

        try pool.upsert([Self.found("2024/trip.heic")], to: parent)
        let second = try pool.upsert([Self.found("trip.heic")], to: child)

        #expect(second.added == 0)
        #expect(try Self.photoCount(in: library) == 1)
    }

    @Test("A file added on its own and again inside a folder is one row")
    func fileAlsoInsideAFolder() throws {
        let library = try TestLibrary()
        let pool = PhotoPool(database: library.database)
        let alone = try Self.source(.file, at: "/pictures/2024/trip.heic", in: library)
        let folder = try Self.source(.folder, at: "/pictures/", in: library)

        try pool.upsert([Self.found("trip.heic")], to: alone)
        let second = try pool.upsert([Self.found("2024/trip.heic")], to: folder)

        #expect(second.added == 0)
        #expect(try Self.photoCount(in: library) == 1)
    }

    /// The guard against over-dedup. A constraint that collapsed everything
    /// would pass every test above.
    @Test("Different photographs from one source all land")
    func differentPhotosAllLand() throws {
        let library = try TestLibrary()
        let pool = PhotoPool(database: library.database)
        let folder = try Self.source(.folder, at: "/pictures/", in: library)

        let counts = try pool.upsert(
            [Self.found("a.heic"), Self.found("b.heic"), Self.found("c.heic")], to: folder)

        #expect(counts.added == 3)
        #expect(try Self.photoCount(in: library) == 3)
    }

    @Test("Rescanning the same source adds nothing the second time")
    func rescanningAddsNothing() throws {
        let library = try TestLibrary()
        let pool = PhotoPool(database: library.database)
        let folder = try Self.source(.folder, at: "/pictures/", in: library)

        try pool.upsert([Self.found("a.heic")], to: folder)
        let again = try pool.upsert([Self.found("a.heic")], to: folder)

        #expect(again.added == 0)
        #expect(try Self.photoCount(in: library) == 1)
    }
}

/// What migration 9 does to a database that already has duplicates in it.
///
/// These run against a database built to version 8 and then migrated, because
/// that is the only way to reach the backfill: once the unique index exists,
/// a duplicate cannot be inserted to be collapsed.
@Suite("Migration 9 collapses what is already there")
struct PhotoIdentityMigrationTests {

    private static func databaseAtVersionEight() throws -> Database {
        let database = try Database.inMemory()
        for migration in Migrator.migrations where migration.version <= 8 {
            try database.transaction {
                try migration.apply(database)
                try database.setUserVersion(migration.version)
            }
        }
        return database
    }

    @discardableResult
    private static func addSource(
        _ kind: SourceKind, at locator: String, to database: Database
    ) throws -> Source {
        try database.run(
            """
            INSERT INTO source (uuid, kind, locator, enabled, added_at)
            VALUES (:uuid, :kind, :locator, 1, 0);
            """,
            [
                "uuid": .text(UUID().uuidString.lowercased()),
                "kind": .text(kind.rawValue), "locator": .text(locator),
            ])
        let id = database.lastInsertRowID
        return Source(
            id: id, uuid: "SOURCE-\(id)", kind: kind, locator: locator,
            addedAt: Date(timeIntervalSince1970: 0))
    }

    @discardableResult
    private static func addPhoto(
        _ externalID: String, to source: Source, in database: Database,
        cached: Bool = false, delivered: Int64 = 0
    ) throws -> Int64 {
        try database.run(
            """
            INSERT INTO photo (uuid, source_id, external_id, media_type, source_enabled,
                               storage, shuffle_key, added_at, cached_at, times_delivered)
            VALUES (:uuid, :source, :external, 'image', 1, 'materialized', 0.5, 0,
                    :cached, :delivered);
            """,
            [
                "uuid": .text(UUID().uuidString.lowercased()),
                "source": .int(source.id),
                "external": .text(externalID),
                "cached": cached ? .int(1) : .null,
                "delivered": .int(delivered),
            ])
        return database.lastInsertRowID
    }

    private static func identity(ofPhoto id: Int64, in database: Database) throws -> String? {
        try database.scalarString(
            "SELECT identity FROM photo WHERE id = :id;", ["id": .int(id)])
    }

    private static func photoCount(in database: Database) throws -> Int {
        try database.scalarInt("SELECT COUNT(*) FROM photo;") ?? 0
    }

    /// **The drift guard.** `SchemaV9`'s `CASE` and `PhotoPool.identity` state
    /// one rule in two languages. If either is changed without the other, rows
    /// written before the migration stop matching rows written after it, and
    /// nothing else in the suite would fail.
    @Test("The backfill agrees with the Swift rule, for every kind there is")
    func backfillMatchesTheSwiftRule() throws {
        let database = try Self.databaseAtVersionEight()

        let folder = try Self.addSource(.folder, at: "/pictures/", to: database)
        let file = try Self.addSource(.file, at: "/elsewhere/one.heic", to: database)
        let album = try Self.addSource(.photosCollection, at: "COLLECTION-1", to: database)

        let cases: [(row: Int64, source: Source, external: String)] = [
            (try Self.addPhoto("2024/trip.heic", to: folder, in: database), folder, "2024/trip.heic"),
            (try Self.addPhoto("one.heic", to: file, in: database), file, "one.heic"),
            (try Self.addPhoto("ASSET-1/L0/001", to: album, in: database), album, "ASSET-1/L0/001"),
        ]

        try Migrator.migrate(database)

        for case_ in cases {
            #expect(
                try Self.identity(ofPhoto: case_.row, in: database)
                    == PhotoPool.identity(of: case_.external, in: case_.source),
                "the SQL backfill and PhotoPool.identity disagree for \(case_.source.kind.rawValue)")
        }
    }

    @Test("One asset that reached two collections becomes one row")
    func collapsesDuplicateAssets() throws {
        let database = try Self.databaseAtVersionEight()
        let favorites = try Self.addSource(.photosCollection, at: "COLLECTION-FAV", to: database)
        let live = try Self.addSource(.photosCollection, at: "COLLECTION-LIVE", to: database)
        let asset = "ASSET-1/L0/001"

        try Self.addPhoto(asset, to: favorites, in: database)
        try Self.addPhoto(asset, to: live, in: database)
        #expect(try Self.photoCount(in: database) == 2)

        try Migrator.migrate(database)

        #expect(try Self.photoCount(in: database) == 1)
    }

    /// The row kept is chosen to orphan as few cached files as it can: since
    /// `SchemaV4` the bytes live on disk under the row's uuid, and a row
    /// deleted here does not go through `PhotoPool.remove`, which is what
    /// normally hands back the uuids to unlink.
    @Test("The row it keeps is the one holding cached bytes")
    func keepsTheResidentRow() throws {
        let database = try Self.databaseAtVersionEight()
        let first = try Self.addSource(.photosCollection, at: "COLLECTION-FIRST", to: database)
        let second = try Self.addSource(.photosCollection, at: "COLLECTION-SECOND", to: database)
        let asset = "ASSET-1/L0/001"

        // The one that would win on id alone is deliberately the one that has
        // nothing, so passing this cannot be an accident of ordering.
        try Self.addPhoto(asset, to: first, in: database)
        let resident = try Self.addPhoto(asset, to: second, in: database, cached: true)

        try Migrator.migrate(database)

        #expect(try Self.photoCount(in: database) == 1)
        #expect(try database.scalarInt("SELECT id FROM photo;") == Int(resident))
    }

    @Test("Between two rows with nothing cached, the more delivered one stays")
    func keepsTheMoreDeliveredRow() throws {
        let database = try Self.databaseAtVersionEight()
        let first = try Self.addSource(.photosCollection, at: "COLLECTION-FIRST", to: database)
        let second = try Self.addSource(.photosCollection, at: "COLLECTION-SECOND", to: database)
        let asset = "ASSET-1/L0/001"

        try Self.addPhoto(asset, to: first, in: database, delivered: 0)
        let seen = try Self.addPhoto(asset, to: second, in: database, delivered: 7)

        try Migrator.migrate(database)

        #expect(try database.scalarInt("SELECT id FROM photo;") == Int(seen))
    }

    @Test("Overlapping folders collapse too, which only the SQL join can do")
    func collapsesOverlappingFolders() throws {
        let database = try Self.databaseAtVersionEight()
        let parent = try Self.addSource(.folder, at: "/pictures/", to: database)
        let child = try Self.addSource(.folder, at: "/pictures/2024/", to: database)

        try Self.addPhoto("2024/trip.heic", to: parent, in: database)
        try Self.addPhoto("trip.heic", to: child, in: database)

        try Migrator.migrate(database)

        #expect(try Self.photoCount(in: database) == 1)
    }

    /// The guard against a migration that collapses everything. It would pass
    /// every test above.
    @Test("Photographs that are not duplicates are all still there afterwards")
    func leavesDistinctRowsAlone() throws {
        let database = try Self.databaseAtVersionEight()
        let folder = try Self.addSource(.folder, at: "/pictures/", to: database)
        let album = try Self.addSource(.photosCollection, at: "COLLECTION-1", to: database)

        try Self.addPhoto("a.heic", to: folder, in: database)
        try Self.addPhoto("b.heic", to: folder, in: database)
        try Self.addPhoto("ASSET-1/L0/001", to: album, in: database)
        try Self.addPhoto("ASSET-2/L0/001", to: album, in: database)

        try Migrator.migrate(database)

        #expect(try Self.photoCount(in: database) == 4)
    }

    /// After the migration the index is what stops it happening again, so the
    /// same pair that needed collapsing cannot be re-inserted.
    @Test("A duplicate cannot be inserted again once the index exists")
    func theIndexHoldsAfterwards() throws {
        let database = try Self.databaseAtVersionEight()
        let favorites = try Self.addSource(.photosCollection, at: "COLLECTION-FAV", to: database)
        let live = try Self.addSource(.photosCollection, at: "COLLECTION-LIVE", to: database)
        let asset = "ASSET-1/L0/001"
        try Self.addPhoto(asset, to: favorites, in: database)

        try Migrator.migrate(database)

        let pool = PhotoPool(database: database)
        let counts = try pool.upsert(
            [DiscoveredPhoto(
                externalID: asset, mediaType: .image, storage: .materialized, byteSize: 1)],
            to: live)

        #expect(counts.added == 0)
        #expect(try Self.photoCount(in: database) == 1)
    }
}
