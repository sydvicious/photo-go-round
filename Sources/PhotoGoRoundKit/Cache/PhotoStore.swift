import Foundation

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
        /// Ordering for eviction. Creation time, since entries are written in
        /// deck order and never rewritten.
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
    public func rebuild(photos: [String: String]) -> (kept: Int, discarded: Int, bytes: Int64) {
        index(photos: photos, discardingUnclaimed: true)
    }

    /// Reads the disk into the index and **deletes nothing**.
    ///
    /// For anything that wants to *report* what is cached rather than take
    /// ownership of it. `pgr_ctl status` is the case that forced it: it opens a
    /// library the agent is using, and a read-only question must not delete a
    /// file because this process happens to disagree about what is claimed.
    @discardableResult
    public func index(photos: [String: String]) -> (kept: Int, discarded: Int, bytes: Int64) {
        index(photos: photos, discardingUnclaimed: false)
    }

    private func index(
        photos: [String: String], discardingUnclaimed: Bool
    ) -> (kept: Int, discarded: Int, bytes: Int64) {
        var found: [Key: Entry] = [:]
        var discarded = 0
        var bytes: Int64 = 0

        let manager = FileManager.default
        for sourceDirectory in (try? manager.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil)) ?? []
        {
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
                }
            }
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
        Log.cache.notice(
            "cache index rebuilt: \(found.count, privacy: .public) entries, \(bytes, privacy: .public) bytes"
        )
        return (found.count, discarded, bytes)
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
        entries[key] = Entry(url: destination, byteCount: Int64(data.count), createdAt: now)
        sourceOfPhoto[key.photoUUID] = sourceUUID
        lock.unlock()
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

    /// One source's whole directory, which is why the layout has that level.
    @discardableResult
    /// The photographs of one source whose **original** is held right now.
    ///
    /// Asked when a source cannot supply bytes, so that producing can pick from
    /// what we have rather than picking blind and failing. Read from the index
    /// rather than the disk: it is a set intersection, on the path that decides
    /// what to show next.
    public func heldOriginals(ofSource sourceUUID: String) -> Set<String> {
        lock.lock()
        defer { lock.unlock() }
        var held: Set<String> = []
        for (key, _) in entries where key.size == nil {
            if sourceOfPhoto[key.photoUUID] == sourceUUID { held.insert(key.photoUUID) }
        }
        return held
    }

    public func removeSource(_ sourceUUID: String) -> Int64 {
        lock.lock()
        let mine = entries.filter { sourceOfPhoto[$0.key.photoUUID] == sourceUUID }
        for key in mine.keys { entries.removeValue(forKey: key) }
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
        /// Entries over the ceiling that were left alone because their
        /// photograph is queued.
        public let protected: Int
    }

    /// FIFO by creation time, over `(photo, resolution)` entries rather than
    /// over photographs — so a photograph can outlive its own original while a
    /// rendering of it survives.
    ///
    /// That is a feature rather than a defect: a rendering is a fraction of the
    /// bytes, so the same budget holds far more display-ready pictures, and a
    /// client asking again at a size already held never needs the original back.
    /// It costs only when a size nobody has rendered is asked for.
    @discardableResult
    public func evictIfNeeded(protecting protectedPhotos: Set<String> = []) -> Eviction {
        lock.lock()
        var total = entries.values.reduce(Int64(0)) { $0 + $1.byteCount }
        guard total > byteCeiling else {
            lock.unlock()
            return Eviction(evicted: 0, bytesFreed: 0, protected: 0)
        }

        var going: [(Key, Entry)] = []
        var protectedCount = 0
        for (key, entry) in entries.sorted(by: { $0.value.createdAt < $1.value.createdAt }) {
            guard total > byteCeiling else { break }
            // Anything queued is about to be shown, whatever its age.
            guard !protectedPhotos.contains(key.photoUUID) else {
                protectedCount += 1
                continue
            }
            going.append((key, entry))
            entries.removeValue(forKey: key)
            total -= entry.byteCount
        }
        lock.unlock()

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
        return Eviction(evicted: going.count, bytesFreed: freed, protected: protectedCount)
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
