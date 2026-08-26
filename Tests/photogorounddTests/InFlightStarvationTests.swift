import Foundation
import Testing

@testable import PhotoGoRoundKit
@testable import photogoroundd
@testable import PhotoGoRoundAgentAPI

/// The queue emptying because everything it held is out being fetched.
///
/// Observed live on 2026-08-25 over a slow hotel network, with several network
/// folder sources newly added and nothing yet cached:
///
/// ```
/// 14:25:51  CACHE: asked for Joe Newman … — 11 waiting
/// 14:26:15  CACHE: asked for Roy Acuff  … — 12 waiting
///           CACHE: looked ahead 1 cards
/// …
/// 14:28:52  SERVE: nothing to show — out of cards, walked 0
/// ```
///
/// Serving skips a card whose bytes are not local, which takes it *off* the
/// queue and hands it to the cache queue. On a cold library over a slow link
/// every card goes that way, so the depth falls while the in-flight count
/// climbs. `Gauge.isShort` counts a card in flight as still the queue's — right,
/// for pacing — and the sum reaches nominal while the depth is zero.
///
/// **At that moment dealing stops, and nothing dealing can do will restart it.**
/// `depth + inFlight < nominal` can only become true again when a *fetch*
/// finishes. The queue is empty, so every request answers `walked 0`, and the
/// outage lasts exactly as long as the slowest outstanding download — or
/// forever, if one never lands.
@Suite("In-flight starvation")
struct InFlightStarvationTests {

    /// **The gauge must never conclude "not short" about an empty queue.**
    ///
    /// In-flight accounting exists to stop the queue overshooting: a card
    /// skipped while its bytes arrive is coming back, so dealing a replacement
    /// would leave the queue long by exactly the number of fetches. That
    /// argument is about a queue that has something in it. It says nothing about
    /// a queue at zero, which cannot serve, cannot advance the deck, and cannot
    /// therefore trigger the top-up that serving is supposed to drive.
    @Test("An empty queue is short no matter how many fetches are outstanding")
    func emptyQueueIsShortEvenWithEveryCardInFlight() throws {
        let folder = URL.temporaryDirectory.appending(path: "pgr-gauge-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appending(path: "photogoround.sqlite").path(percentEncoded: false)
        let database = try Database(path: path)
        try Migrator.migrate(database)

        // Nothing queued: every card that was there has been skipped for want of
        // bytes and is now somewhere in the cache queue.
        #expect(try PhotoQueue(database: database, nominalSize: 20).size() == 0)

        let gauge = FillerBox.Gauge(databasePath: path)
        #expect(
            gauge.isShort(nominalSize: 20, inFlight: 20),
            "an empty queue was called long enough because 20 fetches were outstanding"
        )
    }

    /// The same rule stated where it bites hardest: a fetch that never lands.
    ///
    /// A download that fails permanently, or a volume that goes away mid-fetch,
    /// leaves its card counted as in flight. If that alone can hold the queue at
    /// zero, one wedged fetch takes the whole library down.
    @Test("A queue at zero deals again even when more fetches are outstanding than it holds")
    func emptyQueueIsShortWhenInFlightExceedsNominal() throws {
        let folder = URL.temporaryDirectory.appending(path: "pgr-gauge-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appending(path: "photogoround.sqlite").path(percentEncoded: false)
        let database = try Database(path: path)
        try Migrator.migrate(database)

        let gauge = FillerBox.Gauge(databasePath: path)
        #expect(
            gauge.isShort(nominalSize: 20, inFlight: 200),
            "200 stuck fetches held an empty queue empty"
        )
    }

    /// The behaviour that must survive the fix.
    ///
    /// With cards actually *in* the queue, in-flight accounting still applies —
    /// otherwise the churn it was written to prevent comes straight back, and a
    /// skipped photograph is swapped for a fresh cold one while its bytes are
    /// still arriving.
    @Test("A queue holding its nominal is still not short with fetches outstanding")
    func fullQueueIsNotShortWithFetchesOutstanding() throws {
        let folder = URL.temporaryDirectory.appending(path: "pgr-gauge-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appending(path: "photogoround.sqlite").path(percentEncoded: false)
        let database = try Database(path: path)
        try Migrator.migrate(database)

        try database.run(
            """
            INSERT INTO source (uuid, kind, locator, enabled, added_at)
            VALUES (:uuid, 'folder', '/photos/', 1, 0);
            """,
            ["uuid": .text(UUID().uuidString.lowercased())]
        )
        let source = database.lastInsertRowID
        for index in 0..<15 {
            try database.run(
                """
                INSERT INTO photo (uuid, source_id, external_id, media_type, source_enabled,
                                   storage, shuffle_key, added_at)
                VALUES (:uuid, :source, :external, 'image', 1, 'materialized', :key, 0);
                """,
                [
                    "uuid": .text(UUID().uuidString.lowercased()), "source": .int(source),
                    "external": .text("photo-\(index).heic"), "key": .double(0.5),
                ]
            )
            try database.run(
                "INSERT INTO queue (photo_id, source_id, queued_at) VALUES (:p, :s, 0);",
                ["p": .int(database.lastInsertRowID), "s": .int(source)]
            )
        }

        let gauge = FillerBox.Gauge(databasePath: path)
        // 15 queued and 5 in flight is exactly nominal: the five are coming back,
        // so dealing now would overshoot. This is the case the accounting exists
        // for and it must keep working.
        #expect(!gauge.isShort(nominalSize: 20, inFlight: 5))
    }

    // MARK: - The empty answer has to restart the thing that fills the queue

    /// **A 204 rings the filler.**
    ///
    /// Dealing is paced by pictures actually served, which is right until the
    /// queue is empty — at which point the one event that restarts dealing is
    /// the one event that cannot happen. Nothing is served, so nothing asks for
    /// more, so nothing is dealt, so nothing is served.
    ///
    /// The heartbeat's `topUpIfShort` is the only other way out, and it runs on a
    /// several-minute clock behind a refresh that can hold the loop for longer
    /// than that. So the empty answer itself has to ask.
    @Test("Answering no photos asks for the queue to be filled again")
    func emptyAnswerRestartsTheFiller() async throws {
        let directory = URL.temporaryDirectory.appending(path: "pgr-204-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appending(path: "photogoround.sqlite").path(percentEncoded: false)
        try Migrator.migrate(Database(path: path))

        let asked = Mutex(0)
        // **Two events, not one.** Running short means deal more, and dealing
        // draws uniformly from the library. Coming up empty means the cards on
        // hand all need bytes that are not here, so dealing uniformly hands
        // back another cold one. The empty answer rings its own bell.
        let cameUpEmpty = Mutex(0)
        let cacheRoot = directory.appending(path: "cache")
        let endpoint = PictureEndpoint(
            databasePath: path,
            cacheRoot: cacheRoot,
            preferences: Preferences(defaults: UserDefaults(suiteName: "pgr.204.\(UUID())")!),
            store: PhotoStore(root: cacheRoot),
            queueRanShort: { asked.withLock { $0 += 1 } },
            queueCameUpEmpty: { cameUpEmpty.withLock { $0 += 1 } }
        )

        let head = try #require(
            HTTPListener.parse("GET /v1/next?consumer=app&w=100&h=100 HTTP/1.1"))
        let response = await endpoint.route(head)

        #expect(response.status == 204)
        #expect(
            cameUpEmpty.withLock({ $0 }) == 1,
            "a 204 left the filler unrung, so nothing would ever deal again"
        )
        #expect(
            asked.withLock({ $0 }) == 0,
            "an empty answer asked for more of the same rather than for what is here")
    }
}

/// A minimal lock, matching the kit's own test helper. The daemon's tests take
/// no dependencies either.
final class Mutex<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()

    init(_ value: Value) { self.value = value }

    func withLock<T>(_ body: (inout Value) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}
