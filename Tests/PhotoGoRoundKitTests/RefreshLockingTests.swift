import Foundation
import Synchronization
import Testing

@testable import PhotoGoRoundAgentAPI
@testable import PhotoGoRoundKit

/// The refresh takes the write lock only to write, a page of 100 at a time.
///
/// `Agent Performance Overhaul.md`, Phase 4, *The refresh locks only to write*.
/// Syd: "long locks in the database are death", "pages of 100", "as the walk
/// goes, 100 at a time", and "pages of 100, accept the count". The probe that
/// preceded it measured 500-row batches holding the writer up to 1,114 ms while
/// adding nothing: every millisecond was lookups for rows already there.
@Suite("The refresh locks only to write")
struct RefreshLockingTests {

    private final class Fixture {
        let folder = TemporaryFolder(name: "pgr-locking-src")
        let cacheRoot = TemporaryFolder(name: "pgr-locking-dst")
        let library: TestLibrary
        let bytes: PhotoStore
        let changes = LibraryChanges(recording: true)
        var store: SourceStore
        let heard = Mutex<[RefreshBatchTiming]>([])

        init(photographs: Int) throws {
            for index in 0..<photographs { folder.write(String(format: "photo-%04d.png", index)) }
            library = try TestLibrary()
            bytes = PhotoStore(root: cacheRoot.url.appending(path: "cache"))
            store = SourceStore(database: library.database, bytes: bytes, changes: changes)
            let heard = heard
            store.pool.reportBatch = { timing in heard.withLock { $0.append(timing) } }
        }

        func add() throws -> Source {
            try store.add(kind: .folder, locator: folder.path)
        }

        func timings(_ work: RefreshBatchTiming.Work) -> [RefreshBatchTiming] {
            heard.withLock { $0 }.filter { $0.work == work }
        }

        func forget() { heard.withLock { $0.removeAll() } }

        var photos: Int { (try? library.database.scalarInt("SELECT COUNT(*) FROM photo;")) ?? 0 }
    }

    // MARK: - Pages

    @Test("A walk adds its photographs a page of 100 at a time, as it goes")
    func additionsInPagesOf100() async throws {
        let fixture = try Fixture(photographs: 250)
        let source = try fixture.add()

        let result = await fixture.store.refresh(source)

        #expect(result.added == 250)
        #expect(fixture.photos == 250)
        #expect(fixture.timings(.upsert).map(\.rows) == [100, 100, 50])
        #expect(fixture.timings(.upsert).map(\.added) == [100, 100, 50])
        #expect(fixture.timings(.upsert).allSatisfy { $0.locked })
    }

    /// The case the probe measured: a refresh that finds everything where it
    /// was spent its whole lock looking.
    @Test("A walk that finds nothing new or changed takes no write lock for its photographs")
    func unchangedRefreshTakesNoLock() async throws {
        let fixture = try Fixture(photographs: 250)
        let source = try fixture.add()
        _ = await fixture.store.refresh(source)
        fixture.forget()

        let result = await fixture.store.refresh(source)

        #expect(result.added == 0 && result.removed == 0)
        #expect(fixture.timings(.upsert).count == 3)
        #expect(fixture.timings(.upsert).allSatisfy { !$0.locked }, "a page with nothing to write took the lock")
        #expect(fixture.timings(.upsert).allSatisfy { $0.held == .zero })
    }

    @Test("A page locks for what changed in it, and only that")
    func aChangedPageLocks() async throws {
        let fixture = try Fixture(photographs: 150)
        let source = try fixture.add()
        _ = await fixture.store.refresh(source)
        fixture.forget()
        // One new photograph, and one that grew. Which pages they land in is
        // the folder's enumeration order, so the test does not assume it.
        fixture.folder.write("photo-0000.png", bytes: 64)
        fixture.folder.write("photo-new.png")

        let result = await fixture.store.refresh(source)

        #expect(result.added == 1)
        let pages = fixture.timings(.upsert)
        #expect(pages.map(\.rows).reduce(0, +) == 151)
        #expect(pages.map(\.added).reduce(0, +) == 1)
        #expect(pages.map(\.changed).reduce(0, +) == 1)
        #expect(
            pages.allSatisfy { $0.locked == ($0.added + $0.changed > 0) },
            "a page locked with nothing to write, or wrote without the lock")
    }

    @Test("What a walk no longer finds goes a page of 100 at a time, after the walk")
    func removalsInPagesOf100() async throws {
        let fixture = try Fixture(photographs: 250)
        let source = try fixture.add()
        _ = await fixture.store.refresh(source)
        fixture.forget()
        for index in 0..<230 {
            try FileManager.default.removeItem(
                at: fixture.folder.url.appending(path: String(format: "photo-%04d.png", index)))
        }

        let result = await fixture.store.refresh(source)

        #expect(result.removed == 230)
        #expect(fixture.photos == 20)
        #expect(fixture.timings(.remove).map(\.rows) == [100, 100, 30])
        #expect(fixture.changes.bySource[source.id]?.removed == 230)
    }

    // MARK: - Removing a source

    /// Syd: "pages of 100, accept the count".
    @Test("Removing a source deletes its photographs in pages of 100, then the row, and counts them once")
    func sourceRemovalInPages() async throws {
        let fixture = try Fixture(photographs: 250)
        let source = try fixture.add()
        _ = await fixture.store.refresh(source)
        fixture.forget()

        try fixture.store.remove(id: source.id)

        #expect(fixture.photos == 0)
        #expect(try fixture.store.source(id: source.id) == nil)
        #expect(fixture.timings(.remove).map(\.rows) == [100, 100, 50])
        #expect(fixture.changes.bySource[source.id]?.removed == 250, "counted per page and again for the source")
    }

    // MARK: - A removal page

    @Test("A removal page reads before the lock, and counts only the rows it deleted")
    func removalCountsWhatItDeleted() async throws {
        let fixture = try Fixture(photographs: 3)
        let source = try fixture.add()
        _ = await fixture.store.refresh(source)
        fixture.forget()
        let ids = try fixture.library.database.all("SELECT id FROM photo ORDER BY id;") { try $0.int64("id") }

        let removal = try await fixture.store.pool.remove(ids + [999_999])

        #expect(removal.count == 3)
        #expect(removal.orphaned.count == 3)
        let page = try #require(fixture.timings(.remove).first)
        #expect(page.rows == 4)
        #expect(page.locked)
        #expect(page.held >= page.deletes)
    }

    @Test("A removal page that finds none of its rows takes no lock")
    func removalOfNothingTakesNoLock() async throws {
        let fixture = try Fixture(photographs: 0)

        let removal = try await fixture.store.pool.remove([999_998, 999_999])

        #expect(removal.count == 0)
        #expect(fixture.timings(.remove).map(\.locked) == [false])
    }
}
