import Foundation
import Testing

@testable import PhotoGoRoundKit

@Suite("Sources")
struct SourceTests {

    private static func store(_ database: Database) -> SourceStore {
        SourceStore(database: database)
    }

    // MARK: - What a folder provider finds

    @Test("Images are found, everything else is ignored")
    func folderFiltersByType() async throws {
        let folder = TemporaryFolder()
        folder.write("one.png")
        folder.write("two.jpeg")
        folder.write("three.heic")
        folder.write("four.tiff")
        folder.write("notes.txt")
        folder.write("archive.zip")

        let library = try TestLibrary()
        let store = Self.store(library.database)
        let source = try store.add(kind: .folder, locator: folder.path)
        let found = try await FolderSourceProvider().enumerate(source)

        #expect(found.isAvailable)
        #expect(
            Set(found.photos.map(\.externalID))
                == ["one.png", "two.jpeg", "three.heic", "four.tiff"]
        )
        #expect(found.photos.allSatisfy { $0.mediaType == .image })
    }

    @Test("Videos are excluded deliberately, by conformance rather than by a list")
    func videosAreExcluded() async throws {
        let folder = TemporaryFolder()
        folder.write("still.png")
        folder.write("clip.mov")
        folder.write("clip.mp4")
        folder.write("clip.m4v")

        let library = try TestLibrary()
        let source = try Self.store(library.database).add(kind: .folder, locator: folder.path)
        let found = try await FolderSourceProvider().enumerate(source)
        #expect(found.photos.map(\.externalID) == ["still.png"])
    }

    @Test("Subfolders are walked only when asked, and paths are folder-relative")
    func recursionIsOptionalAndPathsAreRelative() async throws {
        let folder = TemporaryFolder()
        folder.write("top.png")
        folder.write("holiday/beach.png")
        folder.write("holiday/2019/pier.png")

        let library = try TestLibrary()
        let store = Self.store(library.database)

        let flat = try store.add(kind: .folder, locator: folder.path, recursive: false)
        let flatFound = try await FolderSourceProvider().enumerate(flat)
        #expect(flatFound.photos.map(\.externalID) == ["top.png"])

        let deep = try store.add(kind: .folder, locator: folder.path, recursive: true)
        let deepFound = try await FolderSourceProvider().enumerate(deep)
        // Relative to the source's own path, which is what makes recovering a
        // moved folder one row to repair rather than fifty thousand.
        #expect(
            Set(deepFound.photos.map(\.externalID))
                == ["top.png", "holiday/beach.png", "holiday/2019/pier.png"]
        )
    }

    @Test("A folder that is not there reports why, rather than reporting nothing")
    func missingFolderIsUnavailable() async throws {
        let library = try TestLibrary()
        let source = try Self.store(library.database).add(
            kind: .folder, locator: "/nowhere/at/all/photos"
        )
        let found = try await FolderSourceProvider().enumerate(source)
        #expect(!found.isAvailable)
        #expect(found.unavailableReason != nil)
        #expect(found.photos.isEmpty)
    }

    @Test("A file on the boot volume is referenced in place, never copied")
    func bootVolumeFilesAreReferenced() async throws {
        let folder = TemporaryFolder()
        folder.write("one.png")

        let library = try TestLibrary()
        let source = try Self.store(library.database).add(kind: .folder, locator: folder.path)
        let found = try await FolderSourceProvider().enumerate(source)
        // Always mounted, so copying it would be pure waste.
        #expect(found.photos.first?.storage == .referenced)
        #expect(found.photos.first?.byteSize == 32)
    }

    @Test("An unplugged drive is told apart from a deleted folder")
    func unmountedVolumeIsDistinguishedFromDeletion() {
        let mounts = ["/", "/Volumes/Backup", "/System/Volumes/Data"]

        // The volume a path lives on is the *deepest* mount point containing
        // it. Getting this wrong makes every missing path look like a deletion,
        // because "/" prefixes everything — and the difference is what tells
        // the user to plug the drive back in rather than that their photos are
        // gone.
        #expect(FileClassifier.volumeIsMounted(path: "/Volumes/Backup/photos", mountPoints: mounts))
        #expect(!FileClassifier.volumeIsMounted(path: "/Volumes/Ejected/photos", mountPoints: mounts))

        // A missing path on the boot volume really is a missing path.
        #expect(FileClassifier.volumeIsMounted(path: "/Users/syd/Pictures", mountPoints: mounts))

        // Prefix matching is on path components, not characters: a volume named
        // "Backup2" must not satisfy a lookup for "Backup".
        #expect(!FileClassifier.volumeIsMounted(path: "/Volumes/Backup2/x", mountPoints: ["/", "/Volumes/Backup"]))
    }

    // MARK: - Single files

    @Test("A pinned file is one photo, named by its filename")
    func fileSourceIsOnePhoto() async throws {
        let folder = TemporaryFolder()
        let file = folder.write("pinned.png")

        let library = try TestLibrary()
        let source = try Self.store(library.database).add(
            kind: .file, locator: file.path(percentEncoded: false)
        )
        let found = try await FileSourceProvider().enumerate(source)
        #expect(found.photos.count == 1)
        #expect(found.photos.first?.externalID == "pinned.png")
    }

    @Test("A pinned file that is not a still image says so")
    func fileSourceRejectsNonImages() async throws {
        let folder = TemporaryFolder()
        let file = folder.write("clip.mov")

        let library = try TestLibrary()
        let source = try Self.store(library.database).add(
            kind: .file, locator: file.path(percentEncoded: false)
        )
        let found = try await FileSourceProvider().enumerate(source)
        #expect(!found.isAvailable)
        #expect(found.unavailableReason == "not a still image")
    }

    @Test("A provider handed the wrong kind of source refuses it")
    func providersCheckTheirKind() async throws {
        let library = try TestLibrary()
        let source = try Self.store(library.database).add(kind: .file, locator: "/tmp/x.png")
        await #expect(throws: SourceProviderError.self) {
            try await FolderSourceProvider().enumerate(source)
        }
    }

    // MARK: - Scanning

    @Test("A first scan inserts rows that are eligible immediately")
    func firstScanInsertsEligibleRows() async throws {
        let folder = TemporaryFolder()
        for name in ["a.png", "b.png", "c.png"] { folder.write(name) }

        let library = try TestLibrary()
        let store = Self.store(library.database)
        let source = try store.add(kind: .folder, locator: folder.path)
        let result = await store.refresh(source)

        #expect(result.added == 3)
        #expect(result.removed == 0)
        #expect(!result.sourceUnavailable)
        #expect(try library.deck.poolSize() == 3)
        // Null deal ordinal means eligible by definition.
        #expect(
            try library.database.scalarInt(
                "SELECT COUNT(*) FROM photo WHERE last_dealt_seq IS NULL;") == 3
        )
    }

    @Test("A rescan reports what changed and nothing else")
    func rescanIsIncremental() async throws {
        let folder = TemporaryFolder()
        for name in ["a.png", "b.png"] { folder.write(name) }

        let library = try TestLibrary()
        let store = Self.store(library.database)
        let source = try store.add(kind: .folder, locator: folder.path)
        await store.refresh(source)

        folder.write("c.png")
        folder.remove("a.png")

        var changes: [ScanChange] = []
        let result = await store.refresh(try store.source(id: source.id)!) { changes.append($0) }

        #expect(result.added == 1)
        #expect(result.removed == 1)
        #expect(result.unchanged == 1)
        #expect(changes.contains(.added(externalID: "c.png")))
        #expect(changes.contains(.removed(externalID: "a.png")))
    }

    @Test("A photo that goes away leaves the pool, and comes back as a new entry")
    func vanishedPhotosLeaveThePool() async throws {
        let folder = TemporaryFolder()
        for name in ["a.png", "b.png"] { folder.write(name) }

        let library = try TestLibrary()
        let store = Self.store(library.database)
        let source = try store.add(kind: .folder, locator: folder.path)
        await store.refresh(source)

        _ = try library.drawSequence(count: 6, settings: .default)

        // Removed means removed. The row goes, and its queue entries cascade
        // with it — these are transient images, and the per-photo history is
        // not worth a flag column and a second lifecycle to preserve.
        folder.remove("a.png")
        await store.refresh(try store.source(id: source.id)!)

        #expect(try library.deck.poolSize() == 1)
        #expect(try library.database.scalarInt("SELECT COUNT(*) FROM photo;") == 1)

        // Putting it back makes it a genuinely new entry: new row, null deal
        // ordinal, no history. It competes immediately rather than resuming a
        // place in a rotation it was absent from.
        folder.write("a.png")
        let back = await store.refresh(try store.source(id: source.id)!)
        #expect(back.added == 1)
        #expect(back.removed == 0)
        #expect(try library.deck.poolSize() == 2)

        // Identity is asserted by the absence of history rather than by the row
        // id: SQLite hands back the same rowid when the deleted row held the
        // maximum, so a new entry can legitimately land on an old number. That
        // is harmless here only because removal cascades — no consumer can be
        // holding a card for the id that got reused.
        let revived = try library.database.first(
            "SELECT times_shown, last_dealt_seq FROM photo WHERE external_id = 'a.png';"
        ) {
            (shown: try $0.int("times_shown"), seq: try $0.optionalInt64("last_dealt_seq"))
        }
        let entry = try #require(revived)
        #expect(entry.shown == 0)
        #expect(entry.seq == nil)
    }

    @Test("Removing from the pool takes its queue entries with it")
    func poolRemovalCascadesToTheQueue() async throws {
        let folder = TemporaryFolder()
        for name in ["a.png", "b.png", "c.png"] { folder.write(name) }

        let library = try TestLibrary()
        let store = Self.store(library.database)
        let source = try store.add(kind: .folder, locator: folder.path)
        await store.refresh(source)

        // Queue everything, so removal has something to cascade through.
        for id in try library.database.all("SELECT id FROM photo;", [:], { try $0.int64("id") }) {
            try library.enqueue(id, sourceID: source.id)
        }
        #expect(try PhotoQueue(database: library.database).size() == 3)

        let doomed = try #require(
            try library.database.first("SELECT id FROM photo WHERE external_id = 'b.png';") {
                try $0.int64("id")
            }
        )
        try store.pool.remove(doomed)

        // No separate step, and no window in which the queue holds a picture
        // the pool no longer has.
        let queue = PhotoQueue(database: library.database)
        #expect(try queue.size() == 2)
        #expect(!(try queue.peek(10).map(\.id).contains(doomed)))
    }

    @Test("A source that lost everything keeps its rotation, unlike one lost file")
    func bulkReturnKeepsItsPlaceInTheRotation() async throws {
        // The distinction that protects an unplugged drive: ten thousand photos
        // coming back at once must not all become immediately eligible, or
        // reconnecting a drive would flood the shuffle. One returning photo has
        // nothing to flood, so it rejoins as new; a whole source never had its
        // photos marked in the first place.
        let folder = TemporaryFolder()
        for name in ["a.png", "b.png", "c.png"] { folder.write(name) }

        let library = try TestLibrary()
        let store = Self.store(library.database)
        let source = try store.add(kind: .folder, locator: folder.path)
        await store.refresh(source)
        _ = try library.drawSequence(count: 3, settings: .default)

        let ordinalsBefore = try library.database.all(
            "SELECT external_id, last_dealt_seq FROM photo ORDER BY external_id;"
        ) { (try $0.string("external_id"), try $0.optionalInt64("last_dealt_seq")) }
        #expect(ordinalsBefore.allSatisfy { $0.1 != nil })

        for name in ["a.png", "b.png", "c.png"] { folder.remove(name) }
        await store.refresh(try store.source(id: source.id)!)
        for name in ["a.png", "b.png", "c.png"] { folder.write(name) }
        await store.refresh(try store.source(id: source.id)!)

        let ordinalsAfter = try library.database.all(
            "SELECT external_id, last_dealt_seq FROM photo ORDER BY external_id;"
        ) { (try $0.string("external_id"), try $0.optionalInt64("last_dealt_seq")) }
        #expect(ordinalsAfter.map(\.1) == ordinalsBefore.map(\.1))
    }

    @Test("A vanished photo leaves the queue rather than being shown")
    func vanishingReleasesOutstandingCards() async throws {
        let folder = TemporaryFolder()
        for name in ["a.png", "b.png", "c.png"] { folder.write(name) }

        let library = try TestLibrary()
        let store = Self.store(library.database)
        let source = try store.add(kind: .folder, locator: folder.path)
        await store.refresh(source)

        // Queue everything, so removal has something to cascade through.
        for id in try library.database.all("SELECT id FROM photo;", [:], { try $0.int64("id") }) {
            try library.enqueue(id, sourceID: source.id)
        }
        #expect(try PhotoQueue(database: library.database).size() == 3)

        folder.remove("b.png")
        await store.refresh(try store.source(id: source.id)!)

        // A refresh that removes an entry takes its queue place with it, so no
        // consumer can be handed a picture the pool no longer has.
        let queue = PhotoQueue(database: library.database)
        #expect(try queue.size() == 2)
        #expect(!(try queue.peek(10).map(\.externalID).contains("b.png")))
    }

    // MARK: - Losing everything at once

    @Test("A source that loses everything is unavailable, not emptied")
    func wholeSourceMissingIsUnavailability() async throws {
        let folder = TemporaryFolder()
        for name in ["a.png", "b.png", "c.png"] { folder.write(name) }

        let library = try TestLibrary()
        let store = Self.store(library.database)
        let source = try store.add(kind: .folder, locator: folder.path)
        await store.refresh(source)
        _ = try library.drawSequence(count: 3, settings: .default)

        // The folder is still there and readable — it just has nothing in it.
        // That is the same shape as an unmounted drive or a switched Photos
        // library, and it gets the same treatment.
        for name in ["a.png", "b.png", "c.png"] { folder.remove(name) }
        let result = await store.refresh(try store.source(id: source.id)!)

        #expect(result.sourceUnavailable)
        #expect(result.removed == 0)
        #expect(try library.database.scalarInt("SELECT COUNT(*) FROM photo;") == 3)

        let after = try #require(try store.source(id: source.id))
        #expect(!after.available)
        #expect(after.unavailableReason != nil)
        #expect(after.unavailableAt != nil)

        // Putting them back makes the source available again.
        for name in ["a.png", "b.png", "c.png"] { folder.write(name) }
        let recovered = await store.refresh(try store.source(id: source.id)!)
        #expect(!recovered.sourceUnavailable)
        #expect(try store.source(id: source.id)?.available == true)
        #expect(try store.source(id: source.id)?.unavailableReason == nil)
    }

    @Test("A source that has always been empty is not unavailable")
    func newEmptySourceIsJustEmpty() async throws {
        let folder = TemporaryFolder()
        let library = try TestLibrary()
        let store = Self.store(library.database)
        let source = try store.add(kind: .folder, locator: folder.path)

        let result = await store.refresh(source)
        #expect(!result.sourceUnavailable)
        #expect(result.added == 0)
        #expect(try store.source(id: source.id)?.available == true)
    }

    @Test("An unreachable folder leaves every row untouched")
    func unreachableFolderTouchesNothing() async throws {
        let folder = TemporaryFolder()
        for name in ["a.png", "b.png"] { folder.write(name) }

        let library = try TestLibrary()
        let store = Self.store(library.database)
        let source = try store.add(kind: .folder, locator: folder.path)
        await store.refresh(source)

        // Simulate the drive going away by pointing the source somewhere gone.
        try library.database.run(
            "UPDATE source SET locator = :locator WHERE id = :id;",
            ["locator": "/nowhere/at/all", "id": .int(source.id)]
        )
        let result = await store.refresh(try store.source(id: source.id)!)

        #expect(result.sourceUnavailable)
        #expect(result.removed == 0)
        #expect(try library.deck.poolSize() == 2)
    }

    // MARK: - Enabling and removing

    @Test("Disabling a source drops it from the deck and returns its cards")
    func disablingUpdatesTheDeckAndHands() async throws {
        let folder = TemporaryFolder()
        for name in ["a.png", "b.png", "c.png"] { folder.write(name) }

        let library = try TestLibrary()
        let store = Self.store(library.database)
        let source = try store.add(kind: .folder, locator: folder.path)
        await store.refresh(source)

        
        try store.setEnabled(false, for: source.id)
        #expect(try library.deck.poolSize() == 0)
        #expect(try store.source(id: source.id)?.enabled == false)

        // Re-enabling brings them back with their history rather than
        // restarting the shuffle.
        try store.setEnabled(true, for: source.id)
        #expect(try library.deck.poolSize() == 3)
    }

    @Test("Removing a source removes its photos and their queue entries")
    func removingCascades() async throws {
        let folder = TemporaryFolder()
        for name in ["a.png", "b.png"] { folder.write(name) }

        let library = try TestLibrary()
        let store = Self.store(library.database)
        let source = try store.add(kind: .folder, locator: folder.path)
        await store.refresh(source)
        
        try store.remove(id: source.id)
        #expect(try library.database.scalarInt("SELECT COUNT(*) FROM photo;") == 0)
        #expect(try library.database.scalarInt("SELECT COUNT(*) FROM queue;") == 0)
        #expect(try store.all().isEmpty)
    }

    @Test("Mixed source kinds coexist in one deck")
    func mixedKindsCoexist() async throws {
        let folder = TemporaryFolder()
        for name in ["a.png", "b.png"] { folder.write(name) }
        let loose = TemporaryFolder()
        let pinned = loose.write("favourite.png")

        let library = try TestLibrary()
        let store = Self.store(library.database)
        try store.add(kind: .folder, locator: folder.path)
        try store.add(kind: .file, locator: pinned.path(percentEncoded: false))

        let results = await store.refreshAll()
        #expect(results.count == 2)
        #expect(results.map(\.added).reduce(0, +) == 3)
        // The deck is the union, and nothing anywhere branched on which kind.
        #expect(try library.deck.poolSize() == 3)
    }

    // MARK: - Materialization

    @Test("Materializing copies the bytes and reports the size")
    func materializationCopiesBytes() async throws {
        let folder = TemporaryFolder()
        folder.write("holiday/beach.png", bytes: 128)
        let destination = TemporaryFolder()

        let library = try TestLibrary()
        let source = try Self.store(library.database).add(
            kind: .folder, locator: folder.path, recursive: true
        )
        let target = destination.url.appending(path: "3/000000124.png")
        let file = try await FolderSourceProvider().materialize(
            externalID: "holiday/beach.png", from: source, to: target
        )

        #expect(file.byteSize == 128)
        #expect(FileManager.default.fileExists(atPath: target.path(percentEncoded: false)))
        // The original is untouched — we never write to photos the user did not
        // hand us directly.
        #expect(
            FileManager.default.fileExists(
                atPath: folder.url.appending(path: "holiday/beach.png").path(percentEncoded: false))
        )
    }

    @Test("Materializing something that is gone says so")
    func materializingAMissingPhotoThrows() async throws {
        let folder = TemporaryFolder()
        let destination = TemporaryFolder()
        let library = try TestLibrary()
        let source = try Self.store(library.database).add(kind: .folder, locator: folder.path)

        await #expect(throws: SourceProviderError.self) {
            try await FolderSourceProvider().materialize(
                externalID: "ghost.png", from: source,
                to: destination.url.appending(path: "1/1.png")
            )
        }
    }

    // MARK: - FileAccess

    @Test("Photo URLs resolve through the access seam, not from raw paths")
    func fileAccessResolvesPhotoURLs() throws {
        let folder = TemporaryFolder()
        folder.write("holiday/beach.png")

        let library = try TestLibrary()
        let store = Self.store(library.database)
        let source = try store.add(kind: .folder, locator: folder.path, recursive: true)

        let access = UnsandboxedFileAccess()
        let exists = try access.withPhotoURL(in: source, externalID: "holiday/beach.png") {
            FileManager.default.fileExists(atPath: $0.path(percentEncoded: false))
        }
        #expect(exists)

        // A file source's locator *is* the photo, so the external id is not
        // appended to it.
        let pinned = try store.add(
            kind: .file, locator: folder.url.appending(path: "holiday/beach.png").path(percentEncoded: false)
        )
        let pinnedExists = try access.withPhotoURL(in: pinned, externalID: "beach.png") {
            FileManager.default.fileExists(atPath: $0.path(percentEncoded: false))
        }
        #expect(pinnedExists)
    }

    @Test("A source with no file behind it cannot be given a URL")
    func fileAccessRefusesNonFileSources() throws {
        let library = try TestLibrary()
        let source = try Self.store(library.database).add(
            kind: .photosCollection, locator: "ABC-123"
        )
        #expect(throws: FileAccessError.self) {
            try UnsandboxedFileAccess().withSourceURL(source) { _ in }
        }
    }
}
