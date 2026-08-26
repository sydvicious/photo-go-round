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
/// cache/<source-uuid>/3840x2160/<photo-uuid>.heic
/// ```
///
/// **The names carry durable identities, never row ids.** The database is
/// disposable and a rebuilt one renumbers from 1, so a surviving cache keyed by
/// row id would be silently mis-attributed — photograph 412's bytes served as
/// photograph 412, which is now a different picture. A UUID that is not in the
/// database is a file that gets deleted, which is the same rule that cleans up
/// after a removed source, a deleted photograph, and a rebuilt library.
///
/// `.original` is a reserved directory rather than the photograph's native pixel
/// size. Otherwise every original lands in a directory named for its own
/// dimensions and hundreds of one-off directories sit mixed in with the handful
/// of live display sizes. The leading dot makes the reservation structural: a
/// size directory is `<w>x<h>` and can never begin with one.
public final class PhotoStore: @unchecked Sendable {

    /// A rendering's dimensions, or `nil` for the original.
    public struct Size: Hashable, Sendable, CustomStringConvertible {
        public let width: Int
        public let height: Int

        public init(width: Int, height: Int) {
            self.width = width
            self.height = height
        }

        public var description: String { "\(width)x\(height)" }

        static func parse(_ name: String) -> Size? {
            let parts = name.split(separator: "x")
            guard parts.count == 2, let width = Int(parts[0]), let height = Int(parts[1]),
                width > 0, height > 0
            else { return nil }
            return Size(width: width, height: height)
        }
    }

    public struct Key: Hashable, Sendable {
        public let photoUUID: String
        /// `nil` is the original.
        public let size: Size?

        public init(photoUUID: String, size: Size? = nil) {
            self.photoUUID = photoUUID
            self.size = size
        }
    }

    public struct Entry: Sendable, Equatable {
        public let url: URL
        public let byteCount: Int64
        /// Ordering for eviction: FIFO by write time, never updated on a
        /// hit. Write order stopped tracking display order when fetches began
        /// landing in completion order — kept because a shuffle has no hot set
        /// for anything cleverer to protect.
        public let createdAt: Date
    }

    public let root: URL
    /// The only bound. A photograph count stopped meaning anything once one
    /// photograph became an original plus several renderings, and it was always
    /// a poor proxy for the disk it exists to protect.
    public var byteCeiling: Int64

    private let lock = NSLock()
    private var entries: [Key: Entry] = [:]
    /// Which source each photograph belongs to, so a key can be turned into a
    /// path without asking the database.
    private var sourceOfPhoto: [String: String] = [:]

    public init(root: URL, byteCeiling: Int64 = CacheSettings.default.byteCeiling) {
        self.root = root
        self.byteCeiling = byteCeiling
    }

    static let originalDirectory = ".original"

    // MARK: - Where a file goes

    public func url(for key: Key, sourceUUID: String, pathExtension: String) -> URL {
        root
            .appending(path: sourceUUID)
            .appending(path: key.size.map(\.description) ?? Self.originalDirectory)
            .appending(path: pathExtension.isEmpty
                ? key.photoUUID : "\(key.photoUUID).\(pathExtension.lowercased())")
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
    public func rebuild(
        photos: [String: String]
    ) -> (kept: Int, discarded: Int, bytes: Int64, emptied: Int) {
        index(photos: photos, discardingUnclaimed: true)
    }

    /// Reads the disk into the index and **deletes nothing**.
    ///
    /// For anything that wants to *report* what is cached rather than take
    /// ownership of it. `pgr_ctl status` is the case that forced it: it opens a
    /// library the agent is using, and a read-only question must not delete a
    /// file because this process happens to disagree about what is claimed.
    @discardableResult
    public func index(
        photos: [String: String]
    ) -> (kept: Int, discarded: Int, bytes: Int64, emptied: Int) {
        index(photos: photos, discardingUnclaimed: false)
    }

    private func index(
        photos: [String: String], discardingUnclaimed: Bool
    ) -> (kept: Int, discarded: Int, bytes: Int64, emptied: Int) {
        var found: [Key: Entry] = [:]
        var discarded = 0
        var bytes: Int64 = 0

        let manager = FileManager.default
        var emptied = 0
        for sourceDirectory in (try? manager.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        {
            // Files kept from this one source, so a directory left holding
            // nothing can be recognised below.
            var keptHere = 0
            for sizeDirectory in (try? manager.contentsOfDirectory(
                at: sourceDirectory, includingPropertiesForKeys: nil)) ?? []
            {
                let name = sizeDirectory.lastPathComponent
                let size = name == Self.originalDirectory ? nil : Size.parse(name)
                guard name == Self.originalDirectory || size != nil else { continue }

                for file in (try? manager.contentsOfDirectory(
                    at: sizeDirectory,
                    includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])) ?? []
                {
                    let uuid = file.deletingPathExtension().lastPathComponent
                    guard photos[uuid] != nil else {
                        if discardingUnclaimed {
                            try? manager.removeItem(at: file)
                            discarded += 1
                        }
                        continue
                    }
                    let values = try? file.resourceValues(
                        forKeys: [.fileSizeKey, .contentModificationDateKey])
                    let byteCount = Int64(values?.fileSize ?? 0)
                    found[Key(photoUUID: uuid, size: size)] = Entry(
                        url: file,
                        byteCount: byteCount,
                        createdAt: values?.contentModificationDate ?? .distantPast
                    )
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
            let isDirectory = (try? sourceDirectory.resourceValues(forKeys: [.isDirectoryKey]))?
                .isDirectory ?? false
            guard isDirectory else { continue }
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
        Log.cache.notice(
            "cache index rebuilt: \(found.count, privacy: .public) entries, \(bytes, privacy: .public) bytes"
        )
        return (found.count, discarded, bytes, emptied)
    }

    /// Tells the store about a photograph it may not have seen, so a file
    /// written for it can be placed.
    public func note(photoUUID: String, sourceUUID: String) {
        lock.lock()
        sourceOfPhoto[photoUUID] = sourceUUID
        lock.unlock()
    }

    // MARK: - Reading

    /// The bytes for this key, or nil when they are not held.
    ///
    /// A missing file is treated as a miss and forgotten, so a purge or a
    /// tidied directory costs a re-render rather than a broken answer.
    public func url(for key: Key) -> URL? {
        lock.lock()
        let entry = entries[key]
        lock.unlock()
        guard let entry else { return nil }
        guard FileManager.default.fileExists(atPath: entry.url.path(percentEncoded: false)) else {
            forget(key)
            return nil
        }
        return entry.url
    }

    public func contains(_ key: Key) -> Bool { url(for: key) != nil }

    /// Every photograph whose **original** is held right now.
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
        return Set(entries.keys.filter { $0.size == nil }.map(\.photoUUID))
    }

    private func forget(_ key: Key) {
        lock.lock()
        entries.removeValue(forKey: key)
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
        _ data: Data, for key: Key, sourceUUID: String, pathExtension: String,
        now: Date = Date()
    ) throws -> URL {
        let destination = url(for: key, sourceUUID: sourceUUID, pathExtension: pathExtension)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)

        let temporary = destination.deletingLastPathComponent()
            .appending(path: ".\(UUID().uuidString).partial")
        try data.write(to: temporary)
        _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)

        lock.lock()
        let previous = entries[key]
        entries[key] = Entry(url: destination, byteCount: Int64(data.count), createdAt: now)
        sourceOfPhoto[key.photoUUID] = sourceUUID
        lock.unlock()
        // One entry per key means one file: a rendering re-made in another
        // format lands under another extension, and the file it replaces would
        // otherwise sit on disk where no index entry can ever name it again.
        if let previous, previous.url != destination {
            try? FileManager.default.removeItem(at: previous.url)
        }
        return destination
    }

    /// The same, for bytes a provider has already written somewhere.
    @discardableResult
    public func adopt(
        fileAt origin: URL, for key: Key, sourceUUID: String, pathExtension: String,
        now: Date = Date()
    ) throws -> URL {
        let destination = url(for: key, sourceUUID: sourceUUID, pathExtension: pathExtension)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if origin != destination {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: origin, to: destination)
        }
        let byteCount =
            (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0

        lock.lock()
        entries[key] = Entry(url: destination, byteCount: byteCount, createdAt: now)
        sourceOfPhoto[key.photoUUID] = sourceUUID
        lock.unlock()
        return destination
    }

    // MARK: - Removing

    /// Everything held for one photograph, original and renderings alike.
    @discardableResult
    public func remove(photoUUID: String) -> Int64 {
        lock.lock()
        let mine = entries.filter { $0.key.photoUUID == photoUUID }
        for key in mine.keys { entries.removeValue(forKey: key) }
        sourceOfPhoto.removeValue(forKey: photoUUID)
        lock.unlock()

        for entry in mine.values { try? FileManager.default.removeItem(at: entry.url) }
        return mine.values.reduce(0) { $0 + $1.byteCount }
    }

    /// One entry, bytes and index together.
    ///
    /// For a caller undoing its own half-finished work — bytes adopted, the
    /// bookkeeping that records them failed — where `remove(photoUUID:)` would
    /// be too broad: it would take renderings that were never in question.
    @discardableResult
    public func remove(_ key: Key) -> Int64 {
        lock.lock()
        let entry = entries.removeValue(forKey: key)
        lock.unlock()

        guard let entry else { return 0 }
        try? FileManager.default.removeItem(at: entry.url)
        return entry.byteCount
    }

    /// One source's whole directory, which is why the layout has that level.
    @discardableResult
    public func removeSource(_ sourceUUID: String) -> Int64 {
        lock.lock()
        let mine = entries.filter { sourceOfPhoto[$0.key.photoUUID] == sourceUUID }
        for key in mine.keys { entries.removeValue(forKey: key) }
        for uuid in Set(mine.keys.map(\.photoUUID)) { sourceOfPhoto.removeValue(forKey: uuid) }
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
        /// Photographs whose **original** went, so the caller can clear their
        /// `cached_at`. Renderings are not residency — a photograph that keeps
        /// a rendering and loses its original is no longer held, and one that
        /// loses only a rendering still is.
        public let releasedOriginals: Set<String>

        init(evicted: Int, bytesFreed: Int64, releasedOriginals: Set<String> = []) {
            self.evicted = evicted
            self.bytesFreed = bytesFreed
            self.releasedOriginals = releasedOriginals
        }
    }

    /// Evicts in the order the caller gives, until the ceiling is met.
    ///
    /// **Least-recently-viewed first, and the last photo standing is exempt.** `order` is
    /// photographs oldest-first by `COALESCE(last_shown_at, cached_at)`, which
    /// only the database can answer — `Entry.createdAt` is a file's
    /// modification date and says nothing about when anybody looked at the
    /// photograph.
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
    /// **A rendering is a photo somebody can be shown**, which is what decides
    /// where the floor sits. One photograph here is an original plus whatever
    /// renderings were made from it, so dropping the original while keeping a
    /// rendering leaves the frame filled *and* meets a ceiling that holding
    /// both would have missed. The floor is one servable file, and the rule
    /// gives up exactly as little as it has to.
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
    /// Within one photograph the **original goes before its renderings**. A
    /// rendering is a fraction of the bytes and is display-ready, so the same
    /// budget holds far more pictures that can be served without a decode; an
    /// original whose rendering survives can still answer a client asking at
    /// that size.
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
            let leftRank = rank[left.key.photoUUID] ?? -1
            let rightRank = rank[right.key.photoUUID] ?? -1
            if leftRank != rightRank { return leftRank < rightRank }
            // Original before rendering, within one photograph.
            return (left.key.size == nil ? 0 : 1) < (right.key.size == nil ? 0 : 1)
        }

        // Whatever survives is the tail of the queue, which is the most
        // recently shown — `order` runs oldest-first.
        var surviving = entries.count

        var going: [(Key, Entry)] = []
        for (key, entry) in queue {
            guard total > byteCeiling else { break }
            guard surviving > 1 else { break }
            going.append((key, entry))
            entries.removeValue(forKey: key)
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
            releasedOriginals: Set(going.lazy.filter { $0.0.size == nil }.map(\.0.photoUUID)))
    }

    // MARK: - What it holds

    public struct Totals: Sendable, Equatable {
        public let entries: Int
        public let originals: Int
        public let renderings: Int
        public let byteCount: Int64
    }

    public var totals: Totals {
        lock.lock()
        defer { lock.unlock() }
        let originals = entries.keys.count { $0.size == nil }
        return Totals(
            entries: entries.count,
            originals: originals,
            renderings: entries.count - originals,
            byteCount: entries.values.reduce(0) { $0 + $1.byteCount }
        )
    }

    /// How many bytes are held for these photographs, original and renderings.
    public func byteCount(ofPhotos photoUUIDs: Set<String>) -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        return entries.reduce(Int64(0)) {
            photoUUIDs.contains($1.key.photoUUID) ? $0 + $1.value.byteCount : $0
        }
    }

    /// Every size held for one photograph, for diagnostics.
    public func sizes(forPhoto photoUUID: String) -> [Size] {
        lock.lock()
        defer { lock.unlock() }
        return entries.keys.filter { $0.photoUUID == photoUUID }.compactMap(\.size)
    }
}
