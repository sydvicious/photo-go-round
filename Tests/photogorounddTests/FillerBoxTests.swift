import Foundation
import Testing

@testable import PhotoGoRoundKit
@testable import photogoroundd
@testable import PhotoGoRoundAgentAPI

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

    @Test("The heartbeat fills a queue that is merely short, not only an empty one")
    func heartbeatTopsUpAShortQueue() async throws {
        // **This reverses an earlier decision, on evidence that decision did not
        // have.** The heartbeat used to fill only an empty queue and leave a
        // short one to the next serve, to stop it churning. That was affordable
        // while every fetch was a local file read: a queue one card short was
        // one card short for a few seconds.
        //
        // A Photos fetch can take five minutes, and the queue is only refilled
        // when a picture is served — so an idle agent leaves the gap open for
        // as long as nobody is looking, and the first picture after idle waits
        // on a cold fetch. Dealing has to happen whether or not anybody asked.
        let fixture = try Fixture(photos: 5)
        let box = fixture.box()
        let preferences = Self.preferences()

        // Fewer photos than the nominal 20, so "full" means "everything there
        // is" and the round reports the deck ran dry.
        let seeded = await box.topUpIfShort(preferences: preferences)
        #expect(try fixture.queueSize() == 5)
        #expect(seeded.produced == 5)
        #expect(seeded.exhausted)

        _ = try await PhotoQueue(database: fixture.database).serve()
        #expect(try fixture.queueSize() == 4)

        let again = await box.topUpIfShort(preferences: preferences)
        #expect(try fixture.queueSize() == 5, "a short queue was left short")
        #expect(again.produced == 1)
    }

    @Test("A queue already at its target is left alone")
    func aFullQueueIsNotChurned() async throws {
        // The other half of the same rule: topping up must be a top-*up*. A
        // heartbeat that dealt on every tick regardless would claim cards
        // nobody is going to see, which is the churn the earlier design was
        // right to avoid.
        let fixture = try Fixture(photos: 5)
        let box = fixture.box()
        let preferences = Self.preferences()

        _ = await box.topUpIfShort(preferences: preferences)
        #expect(try fixture.queueSize() == 5)

        let again = await box.topUpIfShort(preferences: preferences)
        #expect(try fixture.queueSize() == 5)
        #expect(again.produced == 0)
    }

    @Test("The last resort fills the queue, rather than dealing a handful")
    func theLastResortFillsTheQueue() async throws {
        // **The bridge deals three; this deals a queueful, and the difference
        // is what is on screen in between.** The bridge runs at launch, where
        // the ordinary cards are seconds away and twenty consecutive pictures
        // from one warm folder would be the opposite of a shuffle. This runs
        // when a walk has already found nothing, so the alternative is a blank
        // wall — and dealing three produced *empty answer, three pictures,
        // empty again*. Measured 2026-08-26 against a wedged iCloud Drive:
        // fifteen served, thirty-two empty.
        let fixture = try Fixture(photos: 200)
        // Referenced photographs need no fetch, so every one of them is
        // servable without the cache holding anything.
        try fixture.database.run("UPDATE photo SET storage = 'referenced';")
        let box = fixture.box()
        let preferences = Self.preferences()

        let round = await box.dealWhatIsAlreadyHere(preferences: preferences)

        #expect(try fixture.queueSize() == preferences.queueSize)
        #expect(round.produced == preferences.queueSize)
    }

    @Test("It stops when the cache runs out, rather than spinning")
    func theLastResortTerminates() async throws {
        // Slow is acceptable; endless is not. With fewer servable photographs
        // than the queue wants, it deals what there is and returns.
        let fixture = try Fixture(photos: 5)
        try fixture.database.run("UPDATE photo SET storage = 'referenced';")
        let box = fixture.box()

        let round = await box.dealWhatIsAlreadyHere(preferences: Self.preferences())

        #expect(try fixture.queueSize() == 5)
        #expect(round.produced == 5)
    }

    @Test("With nothing servable at all it answers nothing, and says so")
    func theLastResortCanBeEmpty() async throws {
        // Every photograph materialized and none cached: there is genuinely
        // nothing to show, and inventing something would be worse.
        let fixture = try Fixture(photos: 5)
        let box = fixture.box()

        let round = await box.dealWhatIsAlreadyHere(preferences: Self.preferences())

        #expect(try fixture.queueSize() == 0)
        #expect(round.produced == 0)
        #expect(round.exhausted)
    }

    @Test("A served picture deals the queue back toward its target")
    func servedOneTopsBackUp() async throws {
        let fixture = try Fixture(photos: 5)
        let box = fixture.box()
        let preferences = Self.preferences()

        _ = await box.topUpIfShort(preferences: preferences)
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
