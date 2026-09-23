import Foundation
import Synchronization
import Testing

@testable import PhotosGoRoundAgentAPI
@testable import PhotosGoRoundKit
@testable import photogoroundd

/// Eviction on a thread the writer is not waiting on.
///
/// Syd, 2026-09-17: "async code is all about getting stuff out of the way", and,
/// of the shape: "eviction actor". The writers ring and carry on; this owns the
/// connection the work needs and answers the rings.
/// `Plans/Agent Performance Overhaul.md`, Phase 5.
@Suite("The evictor")
struct EvictorTests {

    private final class Passes: Sendable {
        private let list = Mutex<[PhotoCache.EvictionResult]>([])
        func record(_ result: PhotoCache.EvictionResult) { list.withLock { $0.append(result) } }
        var all: [PhotoCache.EvictionResult] { list.withLock { $0 } }
        var count: Int { list.withLock { $0.count } }
    }

    /// Four photographs of 2,048 bytes, held, under a ceiling that fits two —
    /// so the first pass has something to take and says so.
    private final class Fixture {
        let directory: URL
        let path: String
        let root: URL
        let store: PhotoStore
        let database: Database
        let settings = CacheSettings(byteCeiling: 4096)
        let bell = Doorbell()
        let passes = Passes()

        init() async throws {
            directory = URL.temporaryDirectory.appending(path: "pgr-evictor-\(UUID().uuidString)")
            let photos = directory.appending(path: "photos")
            try FileManager.default.createDirectory(at: photos, withIntermediateDirectories: true)
            for index in 0..<4 {
                FileManager.default.createFile(
                    atPath: photos.appending(path: "photo-\(index).png")
                        .path(percentEncoded: false),
                    contents: Data(repeating: 0xAB, count: 2048))
            }

            path = directory.appending(path: "photosgoround.sqlite").path(percentEncoded: false)
            root = directory.appending(path: "cache")
            database = try Database(path: path)
            try Migrator.migrate(database)
            store = PhotoStore(root: root)
            let sources = SourceStore(database: database, bytes: store)
            // A ceiling wide enough to get all four in; the evictor's own
            // settings are what bring them back down.
            var filling = PhotoCache(
                database: database, root: root,
                settings: CacheSettings(byteCeiling: 1_000_000), sources: sources,
                queueSize: 10, store: store)
            filling.log = { _ in }
            try await filling.prepare()
            let source = try sources.add(
                kind: .folder, locator: photos.path(percentEncoded: false))
            _ = await sources.refresh(source)
            try database.run("UPDATE photo SET storage = 'materialized';")
            _ = try await filling.fillCompletely(limit: 4)
        }

        deinit { try? FileManager.default.removeItem(at: directory) }

        func evictor() -> Evictor {
            let passes = passes
            return Evictor(
                bell: bell, databasePath: path, root: root, settings: settings,
                store: store, report: { passes.record($0) })
        }

        var held: Int64 {
            get async { await store.totals.byteCount }
        }
    }

    /// Rings, then closes the bell, then waits for the loop to finish.
    ///
    /// **No timer, and nothing polled.** Syd, 2026-09-17: "can you do `await
    /// Task { }.run()` instead of a timer?" — and, of the Indeed version of the
    /// same fix, "we fixed flaky timing tests at Indeed by using await Task
    /// {}.run." `Evictor.run()` returns when the stream finishes, so the task
    /// running it *is* the handoff: when it comes back, every ring that was
    /// going to be answered has been. A test that polled for a pass count
    /// instead would be asserting how fast this machine is.
    private static func rung(
        _ evictor: Evictor, _ bell: Doorbell, times: Int = 1, whileRunning: Bool = true
    ) async {
        if whileRunning {
            // The loop is already consuming when the rings arrive, which is how
            // the agent meets them.
            let running = Task { await evictor.run() }
            for _ in 0..<times { bell.ring() }
            bell.finish()
            await running.value
        } else {
            for _ in 0..<times { bell.ring() }
            bell.finish()
            await evictor.run()
        }
    }

    @Test("A ring evicts, and says what it took")
    func aRingEvicts() async throws {
        let fixture = try await Fixture()
        let evictor = fixture.evictor()
        #expect(await fixture.held == 4 * 2048)

        await Self.rung(evictor, fixture.bell)

        #expect(await evictor.passes == 1)
        #expect(fixture.passes.all.first?.evicted ?? 0 > 0)
        #expect(await fixture.held <= 4096)
    }

    /// **Rings collapse.** Ten cards fetched in a burst must not cost ten passes
    /// over the whole cache; `Doorbell` buffers the newest ring alone, so what
    /// arrives while a pass is running is one more pass, not ten.
    @Test("A burst of rings does not cost a pass each")
    func ringsCollapse() async throws {
        let fixture = try await Fixture()
        let evictor = fixture.evictor()

        // Rung before the loop starts, so every one of the ten is buffered
        // under the same policy and the count is not a race.
        await Self.rung(evictor, fixture.bell, times: 10, whileRunning: false)

        // **Passes, not evictions.** Nine of ten passes would find nothing left
        // to take and report nothing, so counting what was reported would pass
        // whatever the buffering policy was — measured 2026-09-17 by setting
        // the doorbell to `.unbounded`, which this now fails on.
        let passes = await evictor.passes
        #expect(passes == 1, "ten rings were answered \(passes) times")
        #expect(await fixture.held <= 4096)
    }

    /// Nothing over the ceiling means nothing taken, and nothing said — a ring
    /// is cheap enough to send after every write precisely because of this.
    @Test("A ring with room to spare takes nothing and reports nothing")
    func aRingWithRoomTakesNothing() async throws {
        let fixture = try await Fixture()
        let passes = fixture.passes
        let evictor = Evictor(
            bell: fixture.bell, databasePath: fixture.path, root: fixture.root,
            settings: CacheSettings(byteCeiling: 1_000_000), store: fixture.store,
            report: { passes.record($0) })
        await Self.rung(evictor, fixture.bell)

        // **The pass has to have happened**, or this asserts nothing: a run
        // where the ring was never answered reports nothing either, and would
        // pass on the strength of that. The same hole was in the collapse test
        // above until a mutation found it.
        #expect(await evictor.passes == 1)
        #expect(fixture.passes.count == 0, "it took something although there was room")
        #expect(await fixture.held == 4 * 2048)
    }
}
