import Foundation
import UniformTypeIdentifiers

/// Decides what a file on disk is, and whether its bytes can go away.
///
/// Volume properties are memoised per volume, because a fifty-thousand-photo
/// folder would otherwise ask the same question of the same mount point fifty
/// thousand times.
struct FileClassifier {
    /// Keys worth prefetching on the enumerator, so each file is one stat
    /// rather than several.
    static let resourceKeys: [URLResourceKey] = [
        .isRegularFileKey,
        .isDirectoryKey,
        .isSymbolicLinkKey,
        .contentTypeKey,
        .fileSizeKey,
        .isPackageKey,
        .volumeURLKey,
        .isUbiquitousItemKey,
    ]

    private var storageByVolume: [URL: PhotoStorage] = [:]

    /// What kind of media this is, or nil if it is not media we track at all.
    ///
    /// Conformance rather than an extension allowlist. That excludes `.mov` and
    /// `.mp4` without enumerating video formats, and it correctly *includes*
    /// image formats nobody remembered to list — HEIC, AVIF, JPEG XL, and the
    /// whole `.rawImage` family.
    ///
    /// A Live Photo is an image with a movie attached and lands here as
    /// `.image`, which is right: it should display as its still. An animated
    /// GIF also lands as `.image` and displays as its first frame, permanently.
    static func mediaType(of url: URL, values: URLResourceValues?) -> MediaType? {
        let type =
            values?.contentType
            ?? UTType(filenameExtension: url.pathExtension.lowercased())
        guard let type else { return nil }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return .video }
        return nil
    }

    /// Whether this file's bytes can disappear on us.
    ///
    /// The default when a property cannot be read is `.materialized`: copying a
    /// file we did not need to copy wastes disk, whereas referencing one that
    /// vanishes blanks a screen.
    mutating func storage(of url: URL, values: URLResourceValues?) -> PhotoStorage {
        if values?.isUbiquitousItem == true { return .materialized }

        guard let volume = values?.volume ?? (try? url.resourceValues(forKeys: [.volumeURLKey]).volume)
        else { return .materialized }

        if let known = storageByVolume[volume] { return known }

        let volumeValues = try? volume.resourceValues(forKeys: [
            .volumeIsInternalKey,
            .volumeIsRemovableKey,
            .volumeIsEjectableKey,
            .volumeIsLocalKey,
        ])
        let storage = PhotoStorage.classify(
            volumeIsInternal: volumeValues?.volumeIsInternal,
            volumeIsRemovable: volumeValues?.volumeIsRemovable,
            volumeIsEjectable: volumeValues?.volumeIsEjectable,
            volumeIsLocal: volumeValues?.volumeIsLocal,
            isUbiquitous: values?.isUbiquitousItem
        )
        storageByVolume[volume] = storage
        return storage
    }

    static func byteSize(of url: URL, values: URLResourceValues?) -> Int64? {
        if let size = values?.fileSize { return Int64(size) }
        return (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
    }

    /// Why a path could not be reached, phrased for a person reading
    /// `pgr source list` in red.
    ///
    /// The distinction that matters is an unplugged drive versus a deleted
    /// folder: the first is temporary and must not cost anyone their deal
    /// history, and the second is the user's own doing.
    static func unavailableReason(for url: URL) -> String {
        if !volumeIsMounted(for: url) { return "volume not mounted" }
        if FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
            return "not readable"
        }
        return "no longer at this path"
    }

    static func volumeIsMounted(for url: URL) -> Bool {
        guard
            let mounted = FileManager.default.mountedVolumeURLs(
                includingResourceValuesForKeys: nil, options: []
            )
        else { return true }

        let path = url.standardizedFileURL.path(percentEncoded: false)
        return volumeIsMounted(
            path: path,
            mountPoints: mounted.map { $0.standardizedFileURL.path(percentEncoded: false) }
        )
    }

    /// Split out so the awkward part is testable without mounting anything.
    ///
    /// The subtlety is that `/` prefixes every path, so a naive "does any mount
    /// point contain this" is always true and the answer is always "the file was
    /// deleted". The volume a path lives on is the *deepest* mount point
    /// containing it — and a path under `/Volumes` whose deepest match is the
    /// root volume is a path on a volume that is not there.
    static func volumeIsMounted(path: String, mountPoints: [String]) -> Bool {
        let containing = mountPoints.filter { mount in
            path == mount || path.hasPrefix(mount.hasSuffix("/") ? mount : mount + "/")
        }
        guard let deepest = containing.max(by: { $0.count < $1.count }) else { return false }
        if deepest == "/", path.hasPrefix("/Volumes/") { return false }
        return true
    }
}
