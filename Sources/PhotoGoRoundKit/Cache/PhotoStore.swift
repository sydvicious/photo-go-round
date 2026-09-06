import Foundation
import PhotoGoRoundAgentAPI

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
public final class PhotoStore: @unchecked Sendable {

    public struct Entry: Sendable, Equatable {
        public let url: URL
        public let byteCount: Int64
    }

    public let root: URL
    /// The only bound. A photograph count was always a poor proxy for the disk
    /// this exists to protect, and one file per photograph does not bring it
    /// back: the files differ in size by more than an order of magnitude.
    public var byteCeiling: Int64

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    /// Which source each photograph belongs to, so a key can be turned into a
    /// path without asking the database.
    private var sourceOfPhoto: [String: String] = [:]

    public init(root: URL, byteCeiling: Int64 = CacheSettings.default.byteCeiling) {
        self.root = root
        self.byteCeiling = byteCeiling
    }

    static let originalDirectory = ".original"

    // MARK: - Where a file goes

    public func url(forPhoto photoUUID: String, sourceUUID: String, pathExtension: String) -> URL {
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

        lock.lock()
        entries = found
        sourceOfPhoto = photos
        lock.unlock()

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
        lock.lock()
        sourceOfPhoto[photoUUID] = sourceUUID
        lock.unlock()
    }

    // MARK: - Reading

    /// The bytes for this photograph, or nil when they are not held.
    ///
    /// A missing file is treated as a miss and forgotten, so a purge or a
    /// tidied directory costs a fetch rather than a broken answer.
    public func url(forPhoto photoUUID: String) -> URL? {
        lock.lock()
        let entry = entries[photoUUID]
        lock.unlock()
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
        lock.lock()
        defer { lock.unlock() }
        return Set(entries.keys)
    }

    private func forget(_ photoUUID: String) {
        lock.lock()
        entries.removeValue(forKey: photoUUID)
        lock.unlock()
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

        lock.lock()
        let previous = entries[photoUUID]
        entries[photoUUID] = Entry(url: destination, byteCount: Int64(data.count))
        sourceOfPhoto[photoUUID] = sourceUUID
        lock.unlock()
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

        lock.lock()
        entries[photoUUID] = Entry(url: destination, byteCount: byteCount)
        sourceOfPhoto[photoUUID] = sourceUUID
        lock.unlock()
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
        lock.lock()
        let entry = entries.removeValue(forKey: photoUUID)
        sourceOfPhoto.removeValue(forKey: photoUUID)
        lock.unlock()

        guard let entry else { return 0 }
        try? FileManager.default.removeItem(at: entry.url)
        return entry.byteCount
    }

    /// One source's whole directory, which is why the layout has that level.
    @discardableResult
    public func removeSource(_ sourceUUID: String) -> Int64 {
        lock.lock()
        let mine = entries.filter { sourceOfPhoto[$0.key] == sourceUUID }
        for uuid in mine.keys {
            entries.removeValue(forKey: uuid)
            sourceOfPhoto.removeValue(forKey: uuid)
        }
        lock.unlock()

        try? FileManager.default.removeItem(at: root.appending(path: sourceUUID))
        return mine.values.reduce(0) { $0 + $1.byteCount }
    }

    @discardableResult
    public func removeAll() -> Int64 {
        lock.lock()
        let bytes = entries.values.reduce(Int64(0)) { $0 + $1.byteCount }
        entries.removeAll()
        lock.unlock()
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return bytes
    }

    // MARK: - Eviction

    public struct Eviction: Sendable, Equatable {
        public let evicted: Int
        public let bytesFreed: Int64
        /// Photographs that went, so the caller can clear their `cached_at`.
        /// One file per photograph, so this is simply what was evicted.
        public let releasedOriginals: Set<String>

        init(evicted: Int, bytesFreed: Int64, releasedOriginals: Set<String> = []) {
            self.evicted = evicted
            self.bytesFreed = bytesFreed
            self.releasedOriginals = releasedOriginals
        }
    }

    /// Evicts in the order the caller gives, until the ceiling is met.
    ///
    /// **Least-recently-viewed first, and the last photo standing is exempt.**
    /// `order` is photographs oldest-first by
    /// `COALESCE(last_shown_at, cached_at, added_at)`, which only the database
    /// can answer. `Entry` carried a `createdAt` — the file's modification date
    /// — until 2026-09-06; nothing ever read it, because a write time says
    /// nothing about when anybody looked at the photograph.
    ///
    /// A photograph that has never been shown counts as of the moment it
    /// arrived, so it is the *newest* thing in the cache and the last to go. It
    /// moves up the queue on its own as everything around it is shown; a
    /// download nobody ever picks is eventually evicted on the same rule, with
    /// no special case for it.
    ///
    /// **The cache is never emptied.** A cache holding nothing meets any
    /// ceiling perfectly and makes the product do the one thing it must never
    /// do, which is show a blank frame. So eviction stops at one entry and the
    /// ceiling is missed rather than the frame — a single file larger than the
    /// whole budget is simply held. It also makes a very small cache a usable
    /// setting instead of a way to switch the product off.
    ///
    /// **What it kept is released by the ordinary order, with no rule for it.**
    /// A cache down to one entry has held that entry while it was the only
    /// thing servable, so it has been shown, and it carries a real
    /// `last_shown_at`. Anything arriving afterwards has never been shown and
    /// counts as of the moment it arrived — newer by construction. So the
    /// survivor is always first out the next time anything else is cached, and
    /// a budget that had room for one picture has room for many again without
    /// anybody deciding to let go of it.
    ///
    /// **This is not the `protecting:` set coming back.** That held back every
    /// photograph the deck was carrying, which made the ceiling unreachable in
    /// the ordinary case: set `byteCeiling` low, or let the volume fill from
    /// outside, and we sat over the limit holding entries we were forbidden to
    /// touch. It was also unnecessary — the endpoint opens the file before it
    /// writes any header, so unlinking a file mid-serve does not disturb the
    /// transfer. This is exactly one photograph, and only ever the last one, so
    /// the ceiling is met in every case where meeting it is possible at all.
    ///
    @discardableResult
    public func evictIfNeeded(inOrder order: [String]) -> Eviction {
        lock.lock()
        var total = entries.values.reduce(Int64(0)) { $0 + $1.byteCount }
        guard total > byteCeiling else {
            lock.unlock()
            return Eviction(evicted: 0, bytesFreed: 0)
        }

        var rank: [String: Int] = [:]
        for (index, uuid) in order.enumerated() { rank[uuid] = index }

        // A photograph the caller did not rank has no row claiming it, so
        // nothing will miss it: it goes first.
        let queue = entries.sorted { left, right in
            (rank[left.key] ?? -1) < (rank[right.key] ?? -1)
        }

        // Whatever survives is the tail of the queue, which is the most
        // recently shown — `order` runs oldest-first.
        var surviving = entries.count

        var going: [(String, Entry)] = []
        for (uuid, entry) in queue {
            guard total > byteCeiling else { break }
            guard surviving > 1 else { break }
            going.append((uuid, entry))
            entries.removeValue(forKey: uuid)
            surviving -= 1
            total -= entry.byteCount
        }
        let remaining = total
        lock.unlock()

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
        for (_, entry) in going {
            try? FileManager.default.removeItem(at: entry.url)
            freed += entry.byteCount
        }
        if !going.isEmpty {
            Log.cache.info(
                "evicted \(going.count, privacy: .public) cache entries, freeing \(freed, privacy: .public) bytes"
            )
        }
        return Eviction(
            evicted: going.count, bytesFreed: freed,
            releasedOriginals: Set(going.lazy.map(\.0)))
    }

    // MARK: - What it holds

    public struct Totals: Sendable, Equatable {
        public let entries: Int
        public let byteCount: Int64
    }

    public var totals: Totals {
        lock.lock()
        defer { lock.unlock() }
        return Totals(
            entries: entries.count,
            byteCount: entries.values.reduce(0) { $0 + $1.byteCount }
        )
    }

    /// How many bytes are held for these photographs.
    public func byteCount(ofPhotos photoUUIDs: Set<String>) -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        return entries.reduce(Int64(0)) {
            photoUUIDs.contains($1.key) ? $0 + $1.value.byteCount : $0
        }
    }
}
