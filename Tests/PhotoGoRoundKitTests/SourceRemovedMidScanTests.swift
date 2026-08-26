import Foundation
import Testing

@testable import PhotoGoRoundAgentAPI
@testable import PhotoGoRoundKit

/// Removing a source while its scan is still walking it.
///
/// A walk of a large folder runs for minutes and writes in batches. Removing
/// that source deletes its row, and the next batch inserts a `source_id` that
/// names nothing. Seen on 2026-08-26, in the log, as a page of raw SQL beside
/// the words "source 8 unavailable".
@Suite("A source removed while it is being scanned")
struct SourceRemovedMidScanTests {

    private static func found(_ externalID: String) -> DiscoveredPhoto {
        DiscoveredPhoto(
            externalID: externalID, mediaType: .image, storage: .materialized, byteSize: 1)
    }

    /// **The reason `OR IGNORE` was never enough.** SQLite's conflict clause
    /// covers `NOT NULL`, `UNIQUE`, `CHECK` and primary keys — a foreign key is
    /// not a conflict to be resolved, and goes straight to the caller however
    /// forgivingly the insert was written.
    @Test("A photo written for a source that is gone throws rather than being ignored")
    func foreignKeysAreNotIgnored() throws {
        let library = try TestLibrary()
        let pool = PhotoPool(database: library.database)
        let ghost = Source(
            id: 9999, uuid: "GHOST", kind: .folder, locator: "/gone/",
            addedAt: Date(timeIntervalSince1970: 0))

        do {
            try pool.upsert([Self.found("a.heic")], to: ghost)
            Issue.record("expected the insert to be refused")
        } catch let error as SQLiteError {
            #expect(error.isForeignKeyViolation)
        }
    }

    @Test("A busy database is not mistaken for a missing parent row")
    func busyIsNotAForeignKeyFailure() {
        #expect(SQLiteError.busyAfterWaiting.isForeignKeyViolation == false)
    }

    /// Everything a provider must implement, plus the one thing this test is
    /// about: the source going away in the middle of the walk.
    private final class Vanishing: SourceProvider, @unchecked Sendable {
        let kind = SourceKind("vanishing")
        let database: Database
        let sourceID: Int64

        init(database: Database, sourceID: Int64) {
            self.database = database
            self.sourceID = sourceID
        }

        func enumerate(
            _ source: Source, into sink: (DiscoveredPhoto) async throws -> Void
        ) async throws -> SourceReachability {
            // A full batch, so the first flush happens and succeeds — this has
            // to be a scan interrupted part way, not one that never started.
            for index in 0..<PhotoPool.batchSize {
                try await sink(found("first-\(index).heic"))
            }
            // The user presses `−` in the panel.
            try database.run(
                "DELETE FROM source WHERE id = :id;", ["id": .int(sourceID)])
            for index in 0..<PhotoPool.batchSize {
                try await sink(found("second-\(index).heic"))
            }
            return .reachable
        }

        func existence(of externalID: String, in source: Source) async -> PhotoExistence {
            .unknown(reason: "cannot say")
        }

        func materialize(
            externalID: String, from source: Source, to destination: URL
        ) async throws -> MaterializedFile {
            throw SourceProviderError.photoMissing(externalID: externalID)
        }
    }

    @Test("The scan stops quietly instead of reporting the source unavailable")
    func removedMidScanIsNotAFault() async throws {
        let library = try TestLibrary()
        let kind = SourceKind("vanishing")
        let bare = SourceStore(database: library.database)
        let source = try bare.add(kind: kind, locator: "/pictures/")

        let store = SourceStore(
            database: library.database,
            providers: [Vanishing(database: library.database, sourceID: source.id)])
        let result = await store.refresh(source)

        // **The distinction that matters.** `sourceUnavailable` is how this
        // system says *these photographs cannot be reached* — it is for an
        // unplugged drive. A source the user has deleted has no photographs to
        // be unreachable, and saying otherwise writes a status onto a row that
        // is not there.
        #expect(result.sourceUnavailable == false)
        #expect(result.reason == "refresh abandoned: the source was removed")
    }

    @Test("Nothing survives the source it belonged to")
    func theRowsGoWithIt() async throws {
        let library = try TestLibrary()
        let kind = SourceKind("vanishing")
        let source = try SourceStore(database: library.database)
            .add(kind: kind, locator: "/pictures/")

        let store = SourceStore(
            database: library.database,
            providers: [Vanishing(database: library.database, sourceID: source.id)])
        await store.refresh(source)

        #expect(try library.database.scalarInt("SELECT COUNT(*) FROM photo;") == 0)
        #expect(try library.database.scalarInt("SELECT COUNT(*) FROM source;") == 0)
    }
}
