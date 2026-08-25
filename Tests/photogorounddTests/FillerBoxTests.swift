import Foundation
import Testing

@testable import PhotoGoRoundKit
@testable import photogoroundd

/// The daemon's queue pacing, tested through the closures it actually runs.
///
/// `QueueTopUpTests` pins the policy with hand-built closures, and the history
/// this suite exists for is a regression that lived in exactly the layer those
/// cannot see: the wiring between the gauge, the seed, and the filler. These
/// drive `FillerBox` itself, against a real database.
@Suite("FillerBox")
struct FillerBoxTests {

    /// A file-backed library the box can open its own connections against.
    private final class Fixture {
        let directory: URL
        let databasePath: String
        let database: Database

        init(photos: Int) throws {
            directory = URL.temporaryDirectory.appending(path: "pgr-filler-\(UUID().uuidString)")
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            databasePath = directory.appending(path: "photogoround.sqlite")
                .path(percentEncoded: false)
            database = try Database(path: databasePath)
            try Migrator.migrate(database)

            try database.run(
                """
                INSERT INTO source (uuid, kind, locator, enabled, added_at)
                VALUES (:uuid, 'folder', '/photos/', 1, 0);
                """,
                ["uuid": .text(UUID().uuidString.lowercased())]
            )
            let source = database.lastInsertRowID
            for index in 0..<photos {
                try database.run(
                    """
                    INSERT INTO photo (uuid, source_id, external_id, media_type, source_enabled,
                                       storage, shuffle_key, added_at)
                    VALUES (:uuid, :source, :external, 'image', 1, 'materialized', :key, 0);
                    """,
                    [
                        "uuid": .text(UUID().uuidString.lowercased()),
                        "source": .int(source),
                        "external": .text("photo-\(index).heic"),
                        "key": .double(Double.random(in: 0..<1)),
                    ]
                )
            }
        }

        deinit { try? FileManager.default.removeItem(at: directory) }

        func box() -> FillerBox {
            let filler = FillerBox()
            filler.configure(
                databasePath: databasePath,
                cacheRoot: directory.appending(path: "cache"),
                store: PhotoStore(root: directory.appending(path: "cache"))
            )
            return filler
        }

        func queueSize() throws -> Int {
            try PhotoQueue(database: database).size()
        }
    }

    /// An empty suite, so every number read is the shipped default.
    private static func preferences() -> Preferences {
        Preferences(suiteName: "com.sydpolk.photogoround.tests.filler-\(UUID().uuidString)")
    }

    @Test("The seed fills an empty queue and leaves a short one alone")
    func seedFillsOnlyAnEmptyQueue() async throws {
        // Fewer photos than the nominal 20, so "full" means "everything there
        // is" and the round reports the deck ran dry.
        let fixture = try Fixture(photos: 5)
        let box = fixture.box()
        let preferences = Self.preferences()

        let seeded = await box.seedIfEmpty(preferences: preferences)
        #expect(try fixture.queueSize() == 5)
        #expect(seeded.produced == 5)
        #expect(seeded.exhausted)

        // Serving is what tops up a merely short queue; the heartbeat filling
        // one was the churn the rework removed. A card popped and a seed asked
        // for must leave the queue exactly as the pop left it.
        _ = try await PhotoQueue(database: fixture.database).serve()
        let reseeded = await box.seedIfEmpty(preferences: preferences)
        #expect(try fixture.queueSize() == 4, "the seed topped up a queue that was not empty")
        #expect(reseeded.skipped)
    }

    @Test("A served picture deals the queue back toward its target")
    func servedOneTopsBackUp() async throws {
        let fixture = try Fixture(photos: 5)
        let box = fixture.box()
        let preferences = Self.preferences()

        _ = await box.seedIfEmpty(preferences: preferences)
        _ = try await PhotoQueue(database: fixture.database).serve()
        #expect(try fixture.queueSize() == 4)

        let round = await box.servedOne(preferences: preferences)
        #expect(try fixture.queueSize() == 5)
        #expect(round.produced == 1, "the steady state deals exactly the card that was served")
    }

    @Test("The gauge counts a card out for fetching as the queue's")
    func gaugeCountsInFlight() throws {
        let fixture = try Fixture(photos: 3)
        let rows = try fixture.database.all("SELECT id, source_id FROM photo;") { row in
            (id: try row.int64("id"), source: try row.int64("source_id"))
        }
        for id in rows {
            _ = try PhotoQueue(database: fixture.database).append(
                photoID: id.id, sourceID: id.source)
        }

        let gauge = FillerBox.Gauge(databasePath: fixture.databasePath)
        // Three queued. A fetch in flight fills the queue's dip, so dealing to
        // cover it would be the churn pacing-by-serving exists to remove.
        #expect(gauge.isShort(nominalSize: 5, inFlight: 1))
        #expect(!gauge.isShort(nominalSize: 4, inFlight: 1))
        #expect(!gauge.isShort(nominalSize: 3, inFlight: 0))
    }
}
