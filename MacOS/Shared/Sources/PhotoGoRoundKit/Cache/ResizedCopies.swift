import Foundation
import PhotoGoRoundAgentAPI
import Synchronization

/// The resize cache: copies of photographs resized to a box a client asked for.
///
/// **Back since 2026-09-16.** It was removed on 2026-09-06, when resizing was
/// cheap enough to redo on every request. Once the agent resized one picture at
/// a time and a stalled HEIC decoder could hold that resize for minutes, Syd:
/// "we should start caching the resized images again to reduce the workload on
/// the resize queue." Designed question by question the same day;
/// `Agent Performance Overhaul.md`, *The resize cache, proposed*.
///
/// - **One file for each photograph, box asked for, and format**, in
///   `.resized/` at the cache's root, with a row in `resized` for each. A
///   photograph shown by the app, the screensaver and the dashboard has three.
/// - **Keyed by the box asked for**, so a lookup needs nothing but the request.
/// - **A hit is served before the resizer is asked**; that is the point of it.
/// - **Copies share `cacheByteCeiling` with originals**, and eviction takes the
///   oldest file first by when it was made. See `PhotoCache.evictIfNeeded`.
/// - **A row whose file has gone is deleted by the lookup that finds it.** A
///   file with no row is cleared at the first eviction after launch.
public enum ResizedCopies {

    /// The folder under the cache root. A dot, like `.staging`, so the walk that
    /// indexes originals by source never mistakes it for a source.
    public static let directoryName = ".resized"

    public static func directory(in root: URL) -> URL {
        root.appending(path: directoryName, directoryHint: .isDirectory)
    }

    /// What a request asked for: the box, and the format it will take.
    public struct Request: Sendable, Equatable {
        public let width: Int
        public let height: Int
        public let format: PhotoRenderer.Format

        public init(width: Int, height: Int, format: PhotoRenderer.Format) {
            self.width = width
            self.height = height
            self.format = format
        }
    }

    /// One copy, as its row describes it.
    public struct Copy: Sendable, Equatable {
        public let id: Int64
        public let photoID: Int64
        public let pixelWidth: Int
        public let pixelHeight: Int
        public let byteSize: Int64
        public let file: String
        public let url: URL
    }

    /// `<photo uuid>_<box w>x<box h>_<pixels w>x<pixels h>.<heic|jpg>`
    public static func fileName(
        photoUUID: String, boxWidth: Int, boxHeight: Int, rendered: PhotoRenderer.Rendered
    ) -> String {
        let ext = rendered.format == .heic ? "heic" : "jpg"
        return "\(photoUUID)_\(boxWidth)x\(boxHeight)_\(rendered.width)x\(rendered.height).\(ext)"
    }

    // MARK: - Hit or miss

    /// The copy of `photoID` for this box and format, or nil.
    ///
    /// **A row whose file is gone is not a hit.** Its row is deleted here, and
    /// the caller resizes as for any other miss.
    public static func find(
        photoID: Int64, boxWidth: Int, boxHeight: Int, format: PhotoRenderer.Format,
        root: URL, database: Database
    ) throws -> Copy? {
        let row = try database.first(
            """
            SELECT id, pixel_width, pixel_height, byte_size, file FROM resized
             WHERE photo_id = :photo AND box_width = :w AND box_height = :h AND format = :format;
            """,
            [
                "photo": .int(photoID), "w": .int(Int64(boxWidth)), "h": .int(Int64(boxHeight)),
                "format": .text(format.rawValue),
            ]
        ) {
            (
                id: try $0.int64("id"), width: try $0.int64("pixel_width"),
                height: try $0.int64("pixel_height"), bytes: try $0.int64("byte_size"),
                file: try $0.string("file")
            )
        }
        guard let row else { return nil }
        let url = directory(in: root).appending(path: row.file)
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
            Log.cache.notice(
                "resized copy \(row.file, privacy: .public) has a row and no file; dropping the row")
            try database.run("DELETE FROM resized WHERE id = :id;", ["id": .int(row.id)])
            return nil
        }
        return Copy(
            id: row.id, photoID: photoID, pixelWidth: Int(row.width), pixelHeight: Int(row.height),
            byteSize: row.bytes, file: row.file, url: url)
    }

    // MARK: - Saving

    /// Writes `rendered` as the copy of `photoID` at this box, and records it.
    ///
    /// The file first — a temporary name, then a rename — and the row after, so
    /// a crash between the two leaves a file with no row, which the first
    /// eviction after launch clears, and never a row with no file. A copy
    /// already there for the same key is replaced.
    ///
    /// Answers nil, rather than throwing, when the photograph has gone since the
    /// resize began: its row is not there to hang a copy from.
    @discardableResult
    public static func save(
        _ rendered: PhotoRenderer.Rendered, photoID: Int64, photoUUID: String,
        boxWidth: Int, boxHeight: Int, root: URL, database: Database, now: Date = Date()
    ) throws -> Copy? {
        let folder = directory(in: root)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = fileName(
            photoUUID: photoUUID, boxWidth: boxWidth, boxHeight: boxHeight, rendered: rendered)
        let url = folder.appending(path: file)
        let temporary = folder.appending(path: ".\(UUID().uuidString).partial")
        try rendered.bytes.write(to: temporary)
        do {
            if FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
                try FileManager.default.removeItem(at: url)
            }
            try FileManager.default.moveItem(at: temporary, to: url)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }

        // The key alone for the lookups; the key and the copy for the write —
        // a statement refuses a binding it has no parameter for.
        let key: [String: SQLValue] = [
            "photo": .int(photoID), "w": .int(Int64(boxWidth)), "h": .int(Int64(boxHeight)),
            "format": .text(rendered.format.rawValue),
        ]
        let bindings = key.merging([
            "pw": .int(Int64(rendered.width)), "ph": .int(Int64(rendered.height)),
            "bytes": .int(Int64(rendered.bytes.count)), "file": .text(file), "now": SQLValue(now),
        ]) { $1 }
        let replaced: String?
        do {
            replaced = try database.transaction(.immediate) { () -> String? in
                let previous = try database.first(
                    """
                    SELECT file FROM resized
                     WHERE photo_id = :photo AND box_width = :w AND box_height = :h
                       AND format = :format;
                    """, key, { try $0.string("file") })
                try database.run(
                    """
                    INSERT INTO resized
                        (photo_id, box_width, box_height, format, pixel_width, pixel_height,
                         byte_size, file, created_at)
                    VALUES (:photo, :w, :h, :format, :pw, :ph, :bytes, :file, :now)
                    ON CONFLICT (photo_id, box_width, box_height, format) DO UPDATE SET
                        pixel_width = :pw, pixel_height = :ph, byte_size = :bytes,
                        file = :file, created_at = :now;
                    """, bindings)
                return previous
            }
        } catch let error as SQLiteError where error.isForeignKeyViolation {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        if let replaced, replaced != file {
            try? FileManager.default.removeItem(at: folder.appending(path: replaced))
        }
        let id = try database.scalarInt(
            """
            SELECT id FROM resized
             WHERE photo_id = :photo AND box_width = :w AND box_height = :h AND format = :format;
            """, key) ?? 0
        return Copy(
            id: Int64(id), photoID: photoID, pixelWidth: rendered.width,
            pixelHeight: rendered.height, byteSize: Int64(rendered.bytes.count), file: file, url: url)
    }

    // MARK: - What the cache holds

    /// Every copy's bytes, from the rows.
    public static func byteCount(in database: Database) throws -> Int64 {
        Int64(try database.scalarInt("SELECT COALESCE(SUM(byte_size), 0) FROM resized;") ?? 0)
    }

    /// The files of every copy of these photographs, read before their rows go.
    public static func files(ofPhotos photoIDs: [Int64], in database: Database) throws -> [String] {
        var files: [String] = []
        for id in photoIDs {
            files += try database.all(
                "SELECT file FROM resized WHERE photo_id = :id;", ["id": .int(id)]
            ) { try $0.string("file") }
        }
        return files
    }

    /// The files of every copy of a source's photographs.
    public static func files(ofSource sourceID: Int64, in database: Database) throws -> [String] {
        try database.all(
            """
            SELECT r.file FROM resized r JOIN photo p ON p.id = r.photo_id
             WHERE p.source_id = :source;
            """, ["source": .int(sourceID)]
        ) { try $0.string("file") }
    }

    /// Deletes copy files by name. The rows are the caller's.
    @discardableResult
    public static func removeFiles(_ files: [String], root: URL) -> Int64 {
        let folder = directory(in: root)
        var freed: Int64 = 0
        for file in files {
            let url = folder.appending(path: file)
            freed += Int64(
                (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
            try? FileManager.default.removeItem(at: url)
        }
        return freed
    }

    // MARK: - Files with no row

    /// Whether this launch has cleared files with no row yet.
    ///
    /// **Once per launch, at the first eviction.** Syd: "clear out unaccounted
    /// for files when eviction happens", then "first eviction after launch". A
    /// file with no row comes from dying between writing a copy and recording
    /// it, and dying means a relaunch.
    public final class Sweep: Sendable {
        private let done = Mutex(false)

        public init() {}

        /// The process's own. A test makes one of its own.
        public static let launch = Sweep()

        /// True the first time only.
        func claim() -> Bool {
            done.withLock { already in
                defer { already = true }
                return !already
            }
        }
    }

    /// Deletes every file in `.resized/` that no row names. Answers how many.
    @discardableResult
    public static func removeUnclaimedFiles(root: URL, database: Database) throws -> Int {
        let claimed = Set(try database.all("SELECT file FROM resized;") { try $0.string("file") })
        var removed = 0
        for url in (try? FileManager.default.contentsOfDirectory(
            at: directory(in: root), includingPropertiesForKeys: nil)) ?? []
        // A dot name is a copy still being written, whose row is on its way.
        where !url.lastPathComponent.hasPrefix(".") && !claimed.contains(url.lastPathComponent) {
            try? FileManager.default.removeItem(at: url)
            removed += 1
        }
        if removed > 0 {
            Log.cache.notice(
                "removed \(removed, privacy: .public) resized copies that no row recorded")
        }
        return removed
    }
}
