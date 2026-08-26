import Foundation
import Testing

@testable import PhotoGoRoundKit
@testable import PhotoGoRoundAgentAPI

/// The source state machine, and what serving does in each square of it.
///
/// A source is in one of **three** states, and the third is the one a two-state
/// model gets wrong:
///
/// | source    | we hold a copy            | we hold nothing            |
/// | --------- | ------------------------- | -------------------------- |
/// | available | serve it                  | skip; it can be made again |
/// | offline   | serve it                  | skip; it cannot be asked   |
/// | gone      | remove the row and the bytes, then skip                 |
///
/// **Offline and gone look identical to `stat` and mean opposite things.** An
/// unplugged drive must change nothing, because everything returns when it does.
/// A folder deleted while its drive sat right there is never coming back, and
/// holding its rows and bytes helps nobody. The distinction is whether the
/// *volume* is mounted, which `FileClassifier` has always been able to answer
/// and nothing used to ask.
@Suite("Source states")
struct SourceStateTests {

    /// A library with real bytes in a real cache, so "we hold a copy" is a fact
    /// rather than a fixture's claim.
    private struct Fixture {
        let folder: TemporaryFolder
        let cacheRoot: TemporaryFolder
        let library: TestLibrary
        let bytes: PhotoStore
        let store: SourceStore
        let cache: PhotoCache
        let source: Source

        init(photos: [String], materialized: Bool = true) async throws {
            folder = TemporaryFolder(name: "pgr-state-src")
            cacheRoot = TemporaryFolder(name: "pgr-state-dst")
            for name in photos { folder.write(name, bytes: 2048) }

            library = try TestLibrary()
            bytes = PhotoStore(root: cacheRoot.url.appending(path: "cache"))
            store = SourceStore(database: library.database, bytes: bytes)
            cache = PhotoCache(
                database: library.database, root: cacheRoot.url.appending(path: "cache"),
                sources: store, store: bytes)
            try cache.prepare()

            source = try store.add(kind: .folder, locator: folder.path)
            _ = await store.refresh(source)
            // Materialized means we copied the bytes, which is the only way
            // "the source is unreachable but we can still serve" is possible.
            if materialized {
                try library.database.run("UPDATE photo SET storage = 'materialized';")
            }
            _ = try await cache.fillCompletely()
        }

        /// Moves the source's locator onto a volume that is not mounted, which
        /// is what an unplugged drive looks like from here.
        func goOffline() throws {
            try library.database.run(
                "UPDATE source SET locator = :locator WHERE id = :id;",
                ["locator": "/Volumes/NotMounted/photos", "id": .int(source.id)]
            )
        }

        /// Deletes the folder itself, leaving its volume — the boot disk —
        /// exactly where it was. This is *gone*.
        func goAway() throws {
            try FileManager.default.removeItem(at: folder.url)
        }

        func reread() throws -> Source {
            try #require(try store.source(id: source.id))
        }

        var pooled: Int { (try? library.deck.poolSize()) ?? 0 }
        var held: Int64 { (try? cache.status())?.bytesOnDisk ?? 0 }

        /// Everything the queue will give up, in order.
        func serveEverything() async throws -> [String] {
            var served: [String] = []
            while let next = try await cache.serve() { served.append(next.card.externalID) }
            return served
        }
    }

    // MARK: - Which state is which

    @Test("A folder that is there is available")
    func availableIsAvailable() async throws {
        let fixture = try await Fixture(photos: ["a.png"])
        let source = try fixture.reread()
        #expect(await FolderSourceProvider().availability(of: source) == .available)
    }

    @Test("An unmounted volume is offline, and says which")
    func unmountedIsOffline() async throws {
        let fixture = try await Fixture(photos: ["a.png"])
        try fixture.goOffline()
        let source = try fixture.reread()
        #expect(
            await FolderSourceProvider().availability(of: source)
                == .offline(reason: "volume not mounted"))
    }

    @Test("A folder deleted from a mounted volume is gone, which is a different answer")
    func deletedIsGone() async throws {
        let fixture = try await Fixture(photos: ["a.png"])
        try fixture.goAway()
        let source = try fixture.reread()
        #expect(
            await FolderSourceProvider().availability(of: source)
                == .gone(reason: "no longer at this path"))
    }

    @Test("A single file is its own source, and answers the same three ways")
    func aFileSourceHasTheSameStates() async throws {
        let folder = TemporaryFolder(name: "pgr-state-file")
        let file = folder.write("pinned.png")
        let library = try TestLibrary()
        let store = SourceStore(database: library.database)
        let source = try store.add(
            kind: .file, locator: file.path(percentEncoded: false))

        #expect(await FileSourceProvider().availability(of: source) == .available)
        folder.remove("pinned.png")
        #expect(
            await FileSourceProvider().availability(of: source)
                == .gone(reason: "no longer at this path"))
    }

    // MARK: - Available

    @Test("Available, and holding a copy: it is served")
    func availableWithACopyIsServed() async throws {
        let fixture = try await Fixture(photos: ["a.png", "b.png"])
        #expect(try await fixture.serveEverything().count == 2)
        #expect(fixture.pooled == 2, "serving does not remove anything from a healthy source")
    }

    @Test("Available, holding nothing: skipped, and left to be made again")
    func availableWithNoCopyIsSkippedNotRemoved() async throws {
        let fixture = try await Fixture(photos: ["a.png"])
        // The bytes are evicted while the rows stay, which is the ordinary
        // outcome of the cache being at its ceiling.
        _ = fixture.bytes.removeAll()

        #expect(try await fixture.serveEverything().isEmpty)
        // Nothing was deleted: the source is right there and can produce it
        // again, which is what makes this different from every other empty
        // answer in this file.
        #expect(fixture.pooled == 1)
    }

    // MARK: - Offline

    @Test("Offline, and holding a copy: it is served, because that copy is all we have")
    func offlineWithACopyIsServed() async throws {
        let fixture = try await Fixture(photos: ["a.png", "b.png"])
        #expect(fixture.held > 0)
        try fixture.goOffline()

        #expect(try await fixture.serveEverything().count == 2)
        #expect(fixture.pooled == 2)
        #expect(fixture.held > 0, "an undock must not cost the bytes we are holding")
    }

    @Test("Offline, holding nothing: skipped, and nothing is deleted")
    func offlineWithNoCopyIsSkipped() async throws {
        let fixture = try await Fixture(photos: ["a.png", "b.png"])
        _ = fixture.bytes.removeAll()
        try fixture.goOffline()

        #expect(try await fixture.serveEverything().isEmpty)
        // The whole point: plugging the drive back in restores every one of
        // these, with its deal history intact.
        #expect(fixture.pooled == 2)
        #expect(try fixture.store.all().count == 1)
    }

    // MARK: - Gone

    @Test("Gone: the rows and the cached bytes are removed, and nothing is served")
    func goneRemovesRowsAndBytes() async throws {
        let fixture = try await Fixture(photos: ["a.png", "b.png"])
        #expect(fixture.held > 0)
        #expect(fixture.pooled == 2)

        try fixture.goAway()

        #expect(try await fixture.serveEverything().isEmpty)
        #expect(fixture.pooled == 0, "a source that is gone leaves nothing behind")
        #expect(fixture.held == 0, "and holding its bytes helps nobody")
        // The *source* stays. It is in preferences, which is the durable list,
        // and it repopulates if the folder ever comes back.
        #expect(try fixture.store.all().count == 1)
    }

    @Test("Gone beats holding a copy, which is the whole difference from offline")
    func goneIsNotOffline() async throws {
        let held = try await Fixture(photos: ["a.png"])
        let lost = try await Fixture(photos: ["a.png"])

        try held.goOffline()
        try lost.goAway()

        // Same library, same cached bytes, same empty-looking `stat` — and
        // opposite outcomes, decided entirely by whether the volume is there.
        #expect(try await held.serveEverything() == ["a.png"])
        #expect(held.pooled == 1)

        #expect(try await lost.serveEverything().isEmpty)
        #expect(lost.pooled == 0)
    }

    // MARK: - The conservative direction

    @Test("A provider that cannot tell never answers gone")
    func aProviderThatCannotTellSaysAvailable() async throws {
        /// Everything a provider must implement, and nothing about
        /// availability — so it takes the protocol's default.
        struct Mute: SourceProvider {
            let kind = SourceKind("mute")
            func enumerate(
                _ source: Source, into sink: (DiscoveredPhoto) async throws -> Void
            ) async throws -> SourceReachability { .reachable }
            func existence(of externalID: String, in source: Source) async -> PhotoExistence {
                .unknown(reason: "cannot say")
            }
            func materialize(
                externalID: String, from source: Source, to destination: URL
            ) async throws -> MaterializedFile {
                throw SourceProviderError.photoMissing(externalID: externalID)
            }
        }

        let library = try TestLibrary()
        let source = try SourceStore(database: library.database)
            .add(kind: SourceKind("mute"), locator: "/wherever")

        // The default has to be the answer that deletes nothing. A provider
        // guessing `.gone` would throw a library away.
        #expect(await Mute().availability(of: source) == .available)
    }
}
