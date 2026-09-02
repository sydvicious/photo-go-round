import Foundation
import Testing

@testable import PhotoGoRoundAgentAPI
@testable import PhotoGoRoundKit

/// Two ways a removed source used to leave something of itself behind.
///
/// Found on 2026-08-26 by counting rather than by anything failing: 253 cached
/// originals against 238 rows, in a cache root holding 36 source directories
/// for a library with 3 sources. Twenty-eight of those directories were empty,
/// which is the shape that gave it away — `removeSource` unlinks a directory
/// whole, so an empty one can only have come from the launch sweep taking its
/// files and leaving the husk.
@Suite("What a removed source leaves behind")
struct CacheDirectorySweepTests {

    private static func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
    }

    // MARK: - The sweep

    @Test("Rebuilding removes a source directory whose files it has just discarded")
    func emptiedDirectoriesGoToo() throws {
        let folder = TemporaryFolder(name: "pgr-sweep")
        let root = folder.url.appending(path: "cache")
        let store = PhotoStore(root: root, byteCeiling: 1_000_000)

        try store.store(
            Data(count: 100), for: .init(photoUUID: "PHOTO"), sourceUUID: "SOURCE",
            pathExtension: "heic")
        #expect(Self.exists(root.appending(path: "SOURCE")))

        // Nothing claims it any more — the source was removed.
        let result = store.rebuild(photos: [:])

        #expect(result.discarded == 1)
        #expect(!Self.exists(root.appending(path: "SOURCE")))
    }

    /// The guard against a sweep that tidies away a live cache.
    @Test("A directory whose files are still claimed is left alone")
    func claimedDirectoriesStay() throws {
        let folder = TemporaryFolder(name: "pgr-sweep-keep")
        let root = folder.url.appending(path: "cache")
        let store = PhotoStore(root: root, byteCeiling: 1_000_000)

        try store.store(
            Data(count: 100), for: .init(photoUUID: "PHOTO"), sourceUUID: "SOURCE",
            pathExtension: "heic")

        let result = store.rebuild(photos: ["PHOTO": "SOURCE"])

        #expect(result.discarded == 0)
        #expect(Self.exists(root.appending(path: "SOURCE")))
    }

    /// **`index` reports; `rebuild` owns.** `pgr_ctl status` opens a library the
    /// agent is using, and a read-only question must not delete anything
    /// because this process disagrees about what is claimed.
    @Test("Indexing without discarding removes no directory either")
    func readingChangesNothing() throws {
        let folder = TemporaryFolder(name: "pgr-sweep-readonly")
        let root = folder.url.appending(path: "cache")
        let store = PhotoStore(root: root, byteCeiling: 1_000_000)

        try store.store(
            Data(count: 100), for: .init(photoUUID: "PHOTO"), sourceUUID: "SOURCE",
            pathExtension: "heic")

        _ = store.index(photos: [:])

        #expect(Self.exists(root.appending(path: "SOURCE")))
    }

    @Test("A cache root with nothing in it survives being swept")
    func anEmptyRootIsFine() throws {
        let folder = TemporaryFolder(name: "pgr-sweep-empty")
        let root = folder.url.appending(path: "cache")
        let store = PhotoStore(root: root, byteCeiling: 1_000_000)

        let result = store.rebuild(photos: [:])

        #expect(result.discarded == 0)
        #expect(result.kept == 0)
    }

    // MARK: - The batch

    private final class Scratch {
        let name = scratchSuiteName("cache-sweep")
        var preferences: Preferences { Preferences(defaults: UserDefaults(suiteName: name)!) }

        deinit { discardScratchSuite(name) }
    }

    /// **A trigger, because the failure has to be real.** Reconciling removes
    /// sources in a loop and each one takes the writer; a busy database or a
    /// scan still walking one of them throws part way through. Nothing else in
    /// a test can make one `DELETE` fail and leave the others able to succeed.
    @Test("A source that refuses to be removed does not strand the ones after it")
    func oneFailureDoesNotStrandTheRest() throws {
        let scratch = Scratch()
        let library = try TestLibrary()
        let store = SourceStore(database: library.database, providers: [])

        try library.addSource(kind: "folder", locator: "/first/")
        try library.addSource(kind: "folder", locator: "/refuses/")
        try library.addSource(kind: "folder", locator: "/last/")

        try library.database.execute(
            """
            CREATE TRIGGER refuse_one BEFORE DELETE ON source
            WHEN OLD.locator = '/refuses/'
            BEGIN SELECT RAISE(ABORT, 'this source is busy'); END;
            """)

        // Preferences list nothing, so all three should go.
        let result = try store.reconcile(with: scratch.preferences)

        // The one that refused is still here; the two either side of it are
        // not. Before this, `/last/` went down with `/refuses/`.
        let left = try store.all().map(\.locator)
        #expect(left == ["/refuses/"])
        #expect(result.removed == 2)
    }

    @Test("The stranded source is retried, and goes as soon as it can")
    func theRefuserIsTriedAgain() throws {
        let scratch = Scratch()
        let library = try TestLibrary()
        let store = SourceStore(database: library.database, providers: [])

        try library.addSource(kind: "folder", locator: "/first/")
        try library.addSource(kind: "folder", locator: "/refuses/")
        try library.database.execute(
            """
            CREATE TRIGGER refuse_one BEFORE DELETE ON source
            WHEN OLD.locator = '/refuses/'
            BEGIN SELECT RAISE(ABORT, 'this source is busy'); END;
            """)
        _ = try store.reconcile(with: scratch.preferences)
        #expect(try store.all().map(\.locator) == ["/refuses/"])

        // Whatever was holding it lets go.
        try library.database.execute("DROP TRIGGER refuse_one;")
        let second = try store.reconcile(with: scratch.preferences)

        #expect(second.removed == 1)
        #expect(try store.all().isEmpty)
    }
}
