import Foundation
import PhotosGoRoundAgentAPI

/// The bytes on disk, and the only record of them.
///
/// **The filesystem is the index.** Nothing in the database describes what is
/// cached; this walks the cache root at launch and rebuilds what it knows from
/// the paths themselves. Reconstruction is a walk and a `stat` per file, which
/// is milliseconds for a few thousand entries — and it cannot disagree with the
/// disk the way a second record could.
///
/// ```
/// cache/<source-uuid>/.original/<photo-uuid>.heic
/// ```
///
/// **The names carry durable identities, never row ids.** The database is
/// disposable and a rebuilt one renumbers from 1, so a surviving cache keyed by
/// row id would be silently mis-attributed — photograph 412's bytes served as
/// photograph 412, which is now a different picture. A UUID that is not in the
/// database is a file that gets deleted, which is the same rule that cleans up
/// after a removed source, a deleted photograph, and a rebuilt library.
///
/// **One photograph is one file.** The store held renderings alongside originals
/// until 2026-09-06, keyed by `(photo, resolution)`; a photograph's UUID is now
/// the whole key. `.original` survives as the directory name because keeping it
/// leaves every cached original where it already is, and because a sweep that
/// recognises exactly one directory name is what reclaims the sized directories
/// left behind — see `index(photos:discardingUnclaimed:)`.
public actor PhotoStore {

    public struct Entry: Sendable, Equatable {
        public let url: URL
        public let byteCount: Int64
    }

    public nonisolated let root: URL
    /// The only bound. A photograph count was always a poor proxy for the disk
    /// this exists to protect, and one file per photograph does not bring it
    /// back: the files differ in size by more than an order of magnitude.
    public private(set) var byteCeiling: Int64

    /// The ceiling the next eviction aims at. `PhotoCache` sets it from its
    /// settings, and halves it when the volume is nearly full.
    public func setByteCeiling(_ bytes: Int64) {
        byteCeiling = bytes
    }

    private var entries: [String: Entry] = [:]
    /// Whether an eviction is running in this process. See `claimEviction()`.
    private var evicting = false
    /// Which source each photograph belongs to, so a key can be turned into a
    /// path without asking the database.
    private var sourceOfPhoto: [String: String] = [:]

    /// Who to tell that a file was written to the cache, when evicting is
    /// somebody else's job.
    ///
    /// **The one place every writer already shares.** A `PhotoCache` is built
    /// wherever a connection is — a request, a fetch lane, the resizer's thread
    /// — but all of them are handed this one store, so the bell reaches every
    /// one of them by being here rather than by being threaded through each.
    ///
    /// Nil is the honest default: a cache with nobody to ring evicts on the
    /// thread that wrote, which is what `pgr_ctl` and the tests want. The agent
    /// sets it, and its `Evictor` rings.
    public nonisolated let evictionBell: (@Sendable () -> Void)?

    public init(
        root: URL, byteCeiling: Int64 = CacheSettings.default.byteCeiling,
        evictionBell: (@Sendable () -> Void)? = nil
    ) {
        self.root = root
        self.byteCeiling = byteCeiling
        self.evictionBell = evictionBell
    }

    static let originalDirectory = ".original"

    // MARK: - Where a file goes

    public nonisolated func url(forPhoto photoUUID: String, sourceUUID: String, pathExtension: String) -> URL {
        root
            .appending(path: sourceUUID)
            .appending(path: Self.originalDirectory)
            .appending(path: pathExtension.isEmpty
                ? photoUUID : "\(photoUUID).\(pathExtension.lowercased())")
    }

    // MARK: - Rebuilding from the disk

    /// Walks the cache and rebuilds the index, deleting anything the database
    /// does not claim.
    ///
    /// `photos` maps a photograph's UUID to its source's. A file whose UUID is
    /// absent has no owner — its photograph was deleted, its source removed, or
    /// the whole database rebuilt — and there is nothing left that could name it
    /// correctly, so it goes.
    @discardableResult
    public func rebuild(photos: [String: String]) -> IndexResult {
        index(photos: photos, discardingUnclaimed: true)
    }

    /// Reads the disk into the index and **deletes nothing**.
    ///
    /// For anything that wants to *report* what is cached rather than take
    /// ownership of it. `pgr_ctl status` is the case that forced it: it opens a
    /// library the agent is using, and a read-only question must not delete a
    /// file because this process happens to disagree about what is claimed.
    @discardableResult
    public func index(photos: [String: String]) -> IndexResult {
        index(photos: photos, discardingUnclaimed: false)
    }

    /// **Any directory under a source that is not `.original` is swept — and
    /// this is temporary.** Delete it once every cache in use has launched at
    /// least once against this build; after that it can only ever sweep zero
    /// directories, and reading it later would suggest renderings are something
    /// the store still expects to find. Until
    /// 2026-09-06 the store also held renderings, in directories named `<w>x<h>`
    /// beside it. Those files belong to photographs the database still claims,
    /// so the unclaimed-file rule below would never have taken them and they
    /// would have sat on disk for ever — a gigabyte of them in the development
    /// cache on the day this changed. Recognising one directory name and
    /// deleting the rest is what reclaims them, once, on the next launch.
    public struct IndexResult: Sendable, Equatable {
        public let kept: Int
        public let discarded: Int
        public let bytes: Int64
        public let emptied: Int
        /// Leftover rendering directories swept, and the bytes they held.
        ///
        /// **Temporary, and meant to be deleted.** It exists to reclaim what
        /// the resize cache left behind on 2026-09-06 and has nothing to do
        /// once every cache in use has been through one launch. See
        /// `index(photos:discardingUnclaimed:)`.
        public let reclaimedDirectories: Int
        public let reclaimedBytes: Int64
    }

    private func index(
        photos: [String: String], discardingUnclaimed: Bool
    ) -> IndexResult {
        var found: [String: Entry] = [:]
        var discarded = 0
        var bytes: Int64 = 0

        let manager = FileManager.default
        var emptied = 0
        var reclaimedDirectories = 0
        var reclaimedBytes: Int64 = 0
        for sourceDirectory in (try? manager.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        {
            // The resize cache is not a source, and its files are accounted for
            // by their rows rather than by this walk.
            guard sourceDirectory.lastPathComponent != ResizedCopies.directoryName else { continue }
            // Files kept from this one source, so a directory left holding
            // nothing can be recognised below.
            var keptHere = 0
            for child in (try? manager.contentsOfDirectory(
                at: sourceDirectory, includingPropertiesForKeys: nil)) ?? []
            {
                guard child.lastPathComponent == Self.originalDirectory else {
                    // A leftover rendering directory. Only a sweep that is
                    // allowed to delete takes it; a read-only caller such as
                    // `pgr_ctl status` counts nothing here and removes nothing.
                    guard discardingUnclaimed else { continue }
                    let leftovers = (try? manager.contentsOfDirectory(
                        at: child, includingPropertiesForKeys: [.fileSizeKey])) ?? []
                    guard !leftovers.isEmpty || Self.isDirectory(child, manager) else { continue }
                    for file in leftovers {
                        reclaimedBytes += Int64(
                            (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
                    }
                    try? manager.removeItem(at: child)
                    reclaimedDirectories += 1
                    continue
                }

                for file in (try? manager.contentsOfDirectory(
                    at: child, includingPropertiesForKeys: [.fileSizeKey])) ?? []
                {
                    let uuid = file.deletingPathExtension().lastPathComponent
                    guard photos[uuid] != nil else {
                        if discardingUnclaimed {
                            try? manager.removeItem(at: file)
                            discarded += 1
                        }
                        continue
                    }
                    let byteCount = Int64(
                        (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
                    found[uuid] = Entry(url: file, byteCount: byteCount)
                    bytes += byteCount
                    keptHere += 1
                }
            }

            // **A source directory holding nothing goes with its contents.**
            // `removeSource` unlinks the whole directory, so an *empty* one can
            // only have come from this sweep taking its files on some earlier
            // launch — which is how 28 husks accumulated in a real cache by
            // 2026-08-26 while nothing was ever wrong enough to notice.
            //
            // Safe to take: a directory is created by the first file written
            // into it, so an empty one is not a source waiting for bytes.
            guard discardingUnclaimed, keptHere == 0 else { continue }
            guard Self.isDirectory(sourceDirectory, manager) else { continue }
            try? manager.removeItem(at: sourceDirectory)
            emptied += 1
        }

        entries = found
        sourceOfPhoto = photos

        if discarded > 0 {
            Log.cache.notice(
                "discarded \(discarded, privacy: .public) cached files that nothing claims"
            )
        }
        if emptied > 0 {
            Log.cache.notice(
                "removed \(emptied, privacy: .public) cache directories holding nothing"
            )
        }
        // **Said out loud, because the last silent reclaim went unnoticed for
        // weeks** — see the plan on `prepare()` discarding its own result.
        if reclaimedDirectories > 0 {
            Log.cache.notice(
                """
                reclaimed \(reclaimedDirectories, privacy: .public) leftover rendering \
                directories holding \(reclaimedBytes, privacy: .public) bytes; the cache \
                stopped keeping renderings on 2026-09-06
                """
            )
        }
        Log.cache.notice(
            "cache index rebuilt: \(found.count, privacy: .public) entries, \(bytes, privacy: .public) bytes"
        )
        return IndexResult(
            kept: found.count, discarded: discarded, bytes: bytes, emptied: emptied,
            reclaimedDirectories: reclaimedDirectories, reclaimedBytes: reclaimedBytes)
    }

    private static func isDirectory(_ url: URL, _ manager: FileManager) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
    }

    /// Tells the store about a photograph it may not have seen, so a file
    /// written for it can be placed.
    public func note(photoUUID: String, sourceUUID: String) {
        sourceOfPhoto[photoUUID] = sourceUUID
    }

    // MARK: - Reading

    /// The bytes for this photograph, or nil when they are not held.
    ///
    /// A missing file is treated as a miss and forgotten, so a purge or a
    /// tidied directory costs a fetch rather than a broken answer.
    public func url(forPhoto photoUUID: String) -> URL? {
        let entry = entries[photoUUID]
        guard let entry else { return nil }
        guard FileManager.default.fileExists(atPath: entry.url.path(percentEncoded: false)) else {
            forget(photoUUID)
            return nil
        }
        return entry.url
    }

    public func contains(photo photoUUID: String) -> Bool { url(forPhoto: photoUUID) != nil }

    /// Every photograph whose bytes are held right now.
    ///
    /// For the startup seed, which wants to fill the queue with pictures that
    /// can be shown *this second* rather than ones that will need fetching. A
    /// set rather than a per-photo question because the deck asks about the
    /// whole pool at once, and a call per candidate would be a lock acquisition
    /// per row.
    ///
    /// Deliberately does **not** stat each file the way `url(for:)` does. This
    /// is a hint used to order the queue, not a promise: a photograph whose file
    /// vanished since the index was built costs one skipped card, which is
    /// exactly what the serve walk already handles.
    public var residentPhotoUUIDs: Set<String> {
        return Set(entries.keys)
    }

    private func forget(_ photoUUID: String) {
        entries.removeValue(forKey: photoUUID)
    }

    // MARK: - Writing

    /// Writes bytes for a key, atomically.
    ///
    /// **Rename rather than write-in-place**, because with no database to
    /// cross-check, a half-written file left by a crash would be indexed as real
    /// and served as garbage. Atomic rename is what makes *present* mean
    /// *complete*.
    @discardableResult
    public func store(
        _ data: Data, forPhoto photoUUID: String, sourceUUID: String, pathExtension: String
    ) throws -> URL {
        let destination = url(
            forPhoto: photoUUID, sourceUUID: sourceUUID, pathExtension: pathExtension)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)

        let temporary = destination.deletingLastPathComponent()
            .appending(path: ".\(UUID().uuidString).partial")
        try data.write(to: temporary)
        _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)

        let previous = entries[photoUUID]
        entries[photoUUID] = Entry(url: destination, byteCount: Int64(data.count))
        sourceOfPhoto[photoUUID] = sourceUUID
        // One entry per photograph means one file: bytes re-fetched in another
        // format land under another extension, and the file they replace would
        // otherwise sit on disk where no index entry can ever name it again.
        if let previous, previous.url != destination {
            try? FileManager.default.removeItem(at: previous.url)
        }
        return destination
    }

    /// The same, for bytes a provider has already written somewhere.
    @discardableResult
    public func adopt(
        fileAt origin: URL, forPhoto photoUUID: String, sourceUUID: String, pathExtension: String
    ) throws -> URL {
        let destination = url(
            forPhoto: photoUUID, sourceUUID: sourceUUID, pathExtension: pathExtension)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if origin != destination {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: origin, to: destination)
        }
        let byteCount =
            (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0

        entries[photoUUID] = Entry(url: destination, byteCount: byteCount)
        sourceOfPhoto[photoUUID] = sourceUUID
        return destination
    }

    // MARK: - Removing

    /// What is held for one photograph, bytes and index together.
    ///
    /// **One method where there were two.** While the store held renderings,
    /// taking a photograph and taking a single entry were different operations,
    /// and a caller undoing its own half-finished adoption needed the narrow
    /// one. A photograph is one file now, so both were the same call.
    @discardableResult
    public func remove(photoUUID: String) -> Int64 {
        let entry = entries.removeValue(forKey: photoUUID)
        sourceOfPhoto.removeValue(forKey: photoUUID)

        guard let entry else { return 0 }
        try? FileManager.default.removeItem(at: entry.url)
        return entry.byteCount
    }

    /// One source's whole directory, which is why the layout has that level.
    /// **The one place a deleted photograph's bytes go**: its original, and its
    /// resized copies. A photograph found absent, one a refresh no longer finds,
    /// and a removed source all end here, so a copy can never outlive a
    /// photograph that was actually deleted. Syd, 2026-09-16: "delete them
    /// straight away", and "only if they are actually deleted. if the source is
    /// offline, don't" — which is why nothing about an offline source calls it.
    @discardableResult
    public func discard(_ removal: PhotoPool.Removal) -> Int64 {
        var freed: Int64 = 0
        for uuid in removal.orphaned { freed += remove(photoUUID: uuid) }
        freed += ResizedCopies.removeFiles(removal.orphanedCopies, root: root)
        return freed
    }

    /// A removed source's originals, and its photographs' resized copies,
    /// whose files the caller read before the rows went.
    @discardableResult
    public func removeSource(_ sourceUUID: String, copies: [String]) -> Int64 {
        removeSource(sourceUUID) + ResizedCopies.removeFiles(copies, root: root)
    }

    @discardableResult
    public func removeSource(_ sourceUUID: String) -> Int64 {
        let mine = entries.filter { sourceOfPhoto[$0.key] == sourceUUID }
        for uuid in mine.keys {
            entries.removeValue(forKey: uuid)
            sourceOfPhoto.removeValue(forKey: uuid)
        }

        try? FileManager.default.removeItem(at: root.appending(path: sourceUUID))
        return mine.values.reduce(0) { $0 + $1.byteCount }
    }

    @discardableResult
    public func removeAll() -> Int64 {
        let bytes = entries.values.reduce(Int64(0)) { $0 + $1.byteCount }
        entries.removeAll()
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return bytes
    }

    // MARK: - Eviction

    public struct Eviction: Sendable, Equatable {
        public let evicted: Int
        public let bytesFreed: Int64
        public let releasedOriginals: Set<String>
        /// The files of the resized copies whose files were deleted. Their rows
        /// are the caller's to delete.
        public let evictedCopies: [String]

        init(
            evicted: Int, bytesFreed: Int64, releasedOriginals: Set<String> = [],
            evictedCopies: [String] = []
        ) {
            self.evicted = evicted
            self.bytesFreed = bytesFreed
            self.releasedOriginals = releasedOriginals
            self.evictedCopies = evictedCopies
        }
    }

    /// What the database said this cache held, believed without looking.
    ///
    /// **The index at launch, since 2026-09-17.** Syd: "the agent can ask the
    /// database what the cache was the last time it was alive, and can just try
    /// to get things out of the cache and return it." Every read still stats
    /// the file — `url(forPhoto:)` forgets one that is gone — so believing the
    /// database costs at worst a miss, where walking the disk first cost the
    /// port 8.9 to 39 seconds after a restart.
    public func believe(_ held: [Believed]) {
        for photograph in held {
            entries[photograph.uuid] = Entry(url: photograph.url, byteCount: photograph.byteCount)
            sourceOfPhoto[photograph.uuid] = photograph.sourceUUID
        }
    }

    public struct Believed: Sendable, Equatable {
        public let uuid: String
        public let sourceUUID: String
        public let url: URL
        public let byteCount: Int64

        public init(uuid: String, sourceUUID: String, url: URL, byteCount: Int64) {
            self.uuid = uuid
            self.sourceUUID = sourceUUID
            self.url = url
            self.byteCount = byteCount
        }
    }

    /// Whether the disk has been walked in this process yet.
    ///
    /// **Eviction waits for it.** A total nobody has checked against the disk is
    /// not a total worth deleting photographs over: the database's byte sizes
    /// are what a fetch recorded, and a file changed or lost behind the agent's
    /// back is only found by the walk.
    public private(set) var hasWalked = false

    func walked() {
        hasWalked = true
    }

    /// Claims the one eviction this process runs at a time. False when another
    /// holds it; `endEviction()` gives it back.
    ///
    /// **Skipped rather than waited for.** Eviction follows every file written,
    /// and fetches run several at a time beside the resizer, so two can finish
    /// together. Side by side, each would count what the other is already
    /// taking and take it again. Waiting would hold a thread for the length of
    /// somebody else's pass; skipping leaves the cache over its ceiling until
    /// the next write, which Syd accepted on 2026-09-16: "you might temporarily
    /// exceed the space, but that's fine".
    func claimEviction() -> Bool {
        defer { evicting = true }
        return !evicting
    }

    func endEviction() {
        evicting = false
    }

    /// One file eviction may take.
    public enum EvictionCandidate: Sendable, Equatable {
        /// An original, by its photograph's UUID.
        case original(String)
        /// A resized copy, by its file name, with its size from its row.
        case copy(file: String, bytes: Int64)
    }

    /// Takes files in `order` until the originals held and `copyBytes` together
    /// are under the ceiling.
    ///
    /// `order` is oldest file first, originals and copies mixed —
    /// `PhotoCache.evictionOrder`. An original the order does not name has no
    /// row claiming it, so nothing will miss it: it goes before anything named.
    ///
    /// **The last original is never taken**, so there is always something to
    /// show; copies carry no such protection, since a copy is never the only
    /// way to show a photograph.
    @discardableResult
    public func evictIfNeeded(
        inOrder order: [EvictionCandidate], copyBytes: Int64 = 0
    ) -> Eviction {
        var total = entries.values.reduce(Int64(0)) { $0 + $1.byteCount } + copyBytes
        guard total > byteCeiling else {
            return Eviction(evicted: 0, bytesFreed: 0)
        }

        var named = Set<String>()
        for case .original(let uuid) in order { named.insert(uuid) }
        let unranked = entries.keys.filter { !named.contains($0) }
            .map { EvictionCandidate.original($0) }

        var surviving = entries.count
        var goingOriginals: [(String, Entry)] = []
        var goingCopies: [(file: String, bytes: Int64)] = []
        for candidate in unranked + order {
            guard total > byteCeiling else { break }
            switch candidate {
            case .original(let uuid):
                guard surviving > 1, let entry = entries[uuid] else { continue }
                goingOriginals.append((uuid, entry))
                entries.removeValue(forKey: uuid)
                surviving -= 1
                total -= entry.byteCount
            case .copy(let file, let bytes):
                goingCopies.append((file, bytes))
                total -= bytes
            }
        }
        let remaining = total

        if remaining > byteCeiling {
            Log.cache.notice(
                """
                cache holds \(remaining, privacy: .public) bytes against a ceiling of \
                \(self.byteCeiling, privacy: .public): what is left is bigger than the whole \
                budget and is kept rather than leaving nothing to show
                """
            )
        }

        var freed: Int64 = 0
        for (_, entry) in goingOriginals {
            try? FileManager.default.removeItem(at: entry.url)
            freed += entry.byteCount
        }
        let copyFiles = goingCopies.map(\.file)
        ResizedCopies.removeFiles(copyFiles, root: root)
        freed += goingCopies.reduce(0) { $0 + $1.bytes }
        let evicted = goingOriginals.count + goingCopies.count
        if evicted > 0 {
            Log.cache.info(
                """
                evicted \(goingOriginals.count, privacy: .public) originals and \
                \(goingCopies.count, privacy: .public) resized copies, freeing \
                \(freed, privacy: .public) bytes
                """
            )
        }
        return Eviction(
            evicted: evicted, bytesFreed: freed,
            releasedOriginals: Set(goingOriginals.lazy.map(\.0)), evictedCopies: copyFiles)
    }

    // MARK: - What it holds

    public struct Totals: Sendable, Equatable {
        public let entries: Int
        public let byteCount: Int64
    }

    public var totals: Totals {
        return Totals(
            entries: entries.count,
            byteCount: entries.values.reduce(0) { $0 + $1.byteCount }
        )
    }

    /// How many bytes are held for these photographs.
    public func byteCount(ofPhotos photoUUIDs: Set<String>) -> Int64 {
        return entries.reduce(Int64(0)) {
            photoUUIDs.contains($1.key) ? $0 + $1.value.byteCount : $0
        }
    }
}
