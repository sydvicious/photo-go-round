import Foundation
import Synchronization
import Testing

@testable import PhotosGoRoundAgentAPI
@testable import PhotosGoRoundKit

/// The `REFRESH:` line: where one refresh batch's time went.
///
/// A probe for `Agent Performance Overhaul.md`, Phase 4. Syd, 2026-09-16: "yes,
/// add the timing probe first."
@Suite("Refresh batch timing")
struct RefreshBatchTimingTests {

    private static func source(in library: TestLibrary) throws -> Source {
        let id = try library.addSource(kind: SourceKind.folder.rawValue, locator: "/pictures/")
        return Source(
            id: id, uuid: "SOURCE-\(id)", kind: .folder, locator: "/pictures/",
            addedAt: Date(timeIntervalSince1970: 0))
    }

    private static func found(_ externalID: String, bytes: Int64 = 1) -> DiscoveredPhoto {
        DiscoveredPhoto(
            externalID: externalID, mediaType: .image, storage: .materialized, byteSize: bytes)
    }

    /// A pool whose reports are kept rather than logged.
    private static func pool(in library: TestLibrary) -> (PhotoPool, Mutex<[RefreshBatchTiming]>) {
        let heard = Mutex<[RefreshBatchTiming]>([])
        var pool = PhotoPool(database: library.database, changes: LibraryChanges(recording: true))
        pool.reportBatch = { timing in heard.withLock { $0.append(timing) } }
        return (pool, heard)
    }

    @Test("An upsert's line names the source, the lookups, each part of the lock, and what changed")
    func upsertWording() {
        var timing = RefreshBatchTiming(work: .upsert, rows: 100, source: 5)
        timing.lookups = .milliseconds(12)
        timing.locked = true
        timing.waited = .milliseconds(3)
        timing.inserts = .milliseconds(812)
        timing.updates = .milliseconds(40)
        timing.callbacks = .milliseconds(1)
        timing.commit = .milliseconds(2)
        timing.held = .milliseconds(856)
        timing.added = 12
        timing.changed = 3

        #expect(
            timing.text
                == "REFRESH: upsert 100 into source 5 · lookups 12ms · waited 3ms · held 856ms · inserts 812ms · updates 40ms · commit 2ms · callbacks 1ms · 12 added · 3 changed")
    }

    @Test("A page with nothing to write says it took no lock")
    func unlockedWording() {
        var upsert = RefreshBatchTiming(work: .upsert, rows: 100, source: 5)
        upsert.lookups = .milliseconds(9)
        #expect(upsert.text == "REFRESH: upsert 100 into source 5 · lookups 9ms · no lock · 0 added · 0 changed")

        var removal = RefreshBatchTiming(work: .remove, rows: 2, source: nil)
        removal.lookups = .milliseconds(1)
        #expect(removal.text == "REFRESH: remove 2 · lookups 1ms · no lock")
    }

    @Test("A removal's line puts the reads before the lock apart from the deletes under it")
    func removalWording() {
        var timing = RefreshBatchTiming(work: .remove, rows: 100, source: nil)
        timing.locked = true
        timing.waited = .zero
        timing.lookups = .milliseconds(20)
        timing.deletes = .milliseconds(812)
        timing.commit = .milliseconds(2)
        timing.held = .milliseconds(834)

        #expect(
            timing.text
                == "REFRESH: remove 100 · lookups 20ms · waited 0ms · held 834ms · deletes 812ms · commit 2ms")
    }

    @Test("The walk's bookkeeping and the query for what left have lines of their own")
    func walkWording() {
        #expect(
            RefreshBatchTiming.walkSeen(rows: 100, source: 5, took: .milliseconds(12))
                == "REFRESH: walk_seen 100 for source 5 · 12ms")
        #expect(
            RefreshBatchTiming.departedQuery(source: 5, found: 0, took: .milliseconds(30))
                == "REFRESH: departed query for source 5 · 30ms · 0 found")
    }

    @Test("Each upsert batch reports once, with what it added and changed")
    func upsertReportsPerBatch() async throws {
        let library = try TestLibrary()
        let source = try Self.source(in: library)
        let (pool, heard) = Self.pool(in: library)

        try await pool.upsert([Self.found("a.heic"), Self.found("b.heic")], to: source)
        try await pool.upsert(
            [Self.found("a.heic"), Self.found("b.heic", bytes: 2), Self.found("c.heic")], to: source)

        let timings = heard.withLock { $0 }
        #expect(timings.map(\.work) == [.upsert, .upsert])
        #expect(timings.map(\.rows) == [2, 3])
        #expect(timings.map(\.added) == [2, 1])
        #expect(timings.map(\.changed) == [0, 1])
        #expect(timings.allSatisfy { $0.source == source.id })
        #expect(timings.allSatisfy { $0.held >= $0.inserts + $0.updates })
    }

    @Test("Each removal batch reports once, with how many rows it covered")
    func removalReportsPerBatch() async throws {
        let library = try TestLibrary()
        let source = try Self.source(in: library)
        let (pool, heard) = Self.pool(in: library)
        try await pool.upsert([Self.found("a.heic"), Self.found("b.heic")], to: source)
        let ids = try library.database.all("SELECT id FROM photo;") { try $0.int64("id") }

        try await pool.remove(ids)

        let removals = heard.withLock { $0 }.filter { $0.work == .remove }
        #expect(removals.map(\.rows) == [2])
        #expect(removals.allSatisfy { $0.held >= $0.deletes })
    }
}
