import Foundation
import PhotoGoRoundAgentAPI
import Photos

/// The one file in this project that imports PhotoKit.
///
/// **Deliberately thin, and readable in one sitting.** Everything that can be
/// decided is decided in `PhotosCollectionSourceProvider`, where a test can
/// reach it; what is left here is translation, because translation is the part
/// that cannot be tested without somebody's real photographs and a TCC grant.
/// If a rule appears in this file, it is in the wrong file.
public struct SystemPhotoLibrary: PhotoLibrary {

    /// The bound this binding gives one fetch. See `CacheSettings`.
    public static let fetchLimit = CacheSettings.libraryFetchLimit

    public init() {}

    // MARK: - Authorization

    /// **`.readWrite`, because PhotoKit has no read-only level.** `PHAccessLevel`
    /// is exactly `.addOnly` and `.readWrite`, and `.addOnly` grants *writing*
    /// and nothing else — so reading an album at all requires asking for more
    /// than this project will ever use. `NSPhotoLibraryUsageDescription` is
    /// where that asymmetry gets explained to the person being asked.
    ///
    /// Read, never requested. `availability` is called from the scanner, on a
    /// timer, in a background process; raising a prompt from there is the
    /// unattributed prompt the whole design exists to avoid.
    public var authorization: LibraryAuthorization {
        get async { Self.map(PHPhotoLibrary.authorizationStatus(for: .readWrite)) }
    }

    /// `.readWrite` for the same reason reading does: PhotoKit has no
    /// read-only level, and `.addOnly` grants writing and nothing else.
    public func requestAuthorization() async -> LibraryAuthorization {
        Self.map(await PHPhotoLibrary.requestAuthorization(for: .readWrite))
    }

    static func map(_ status: PHAuthorizationStatus) -> LibraryAuthorization {
        switch status {
        case .notDetermined: .notDetermined
        case .restricted: .restricted
        case .denied: .denied
        case .authorized: .authorized
        case .limited: .limited
        @unknown default: .denied
        }
    }

    // MARK: - Collections

    /// Nil means it does not resolve — which is both "deleted" and "somebody
    /// switched system libraries", and PhotoKit cannot tell them apart either.
    /// An untitled collection that *does* resolve answers empty, not nil.
    public func title(ofCollection identifier: String) async -> String? {
        guard let collection = collection(identifier) else { return nil }
        return collection.localizedTitle ?? ""
    }

    /// **Off the cooperative pool**, because this is 439 PhotoKit round trips
    /// on a real library and every one of them blocks. Parking a cooperative
    /// thread for that is how four concurrent walks stopped the agent answering
    /// picture requests on 2026-08-25.
    public func collections() async -> [LibraryCollection] {
        (try? await BlockingWork.run { Self.everyCollection() }) ?? []
    }

    private static func everyCollection() -> [LibraryCollection] {
        var found: [LibraryCollection] = []
        for type in [PHAssetCollectionType.album, .smartAlbum] {
            let fetched = PHAssetCollection.fetchAssetCollections(
                with: type, subtype: .any, options: nil)
            fetched.enumerateObjects { collection, _, _ in
                found.append(
                    LibraryCollection(
                        identifier: collection.localIdentifier,
                        // Empty rather than nil: a collection that resolves and
                        // has no title is not the same as one that is missing.
                        title: collection.localizedTitle ?? "",
                        kind: Self.kind(of: collection)))
            }
        }
        return found
    }

    /// Translation, and nothing else — what these cases *mean* is decided in
    /// `LibraryCollection`, where a test can reach it.
    ///
    /// The `default` arms are not oversights. A subtype Apple adds after this
    /// ships arrives as `.otherSmartAlbum` or `.userAlbum` and is listed, which
    /// is the failure worth having: a collection somebody can see in Photos and
    /// not here is a bug they cannot diagnose.
    static func kind(of collection: PHAssetCollection) -> LibraryCollectionKind {
        switch collection.assetCollectionType {
        case .album:
            switch collection.assetCollectionSubtype {
            case .albumCloudShared: .sharedAlbum
            case .albumMyPhotoStream: .photoStream
            case .albumImported: .imported
            case .albumSyncedEvent, .albumSyncedFaces, .albumSyncedAlbum: .syncedAlbum
            default: .userAlbum
            }
        case .smartAlbum:
            // **The list below is every smart-album subtype the SDK names, and
            // a real library has more than that.** Measured 2026-08-26: subtypes
            // 221 and the whole 1000000218–1000000220 range came back from a
            // 439-collection library and appear nowhere in `PhotosTypes.h`. One
            // of them is *Recently Saved*, holding 37,550 photographs, which
            // Photos shows and PhotoKit will not name. They arrive as
            // `.otherSmartAlbum` and are listed rather than dropped — an
            // unnamed collection somebody can see in Photos is still theirs to
            // choose.
            switch collection.assetCollectionSubtype {
            case .smartAlbumUserLibrary: .wholeLibrary
            case .smartAlbumFavorites: .favorites
            case .smartAlbumRecentlyAdded: .recentlyAdded
            case .smartAlbumAllHidden: .hidden
            case .smartAlbumUnableToUpload: .unableToUpload
            case .smartAlbumPanoramas, .smartAlbumVideos, .smartAlbumTimelapses,
                .smartAlbumBursts, .smartAlbumSlomoVideos, .smartAlbumSelfPortraits,
                .smartAlbumScreenshots, .smartAlbumDepthEffect, .smartAlbumLivePhotos,
                .smartAlbumAnimated, .smartAlbumLongExposures, .smartAlbumRAW,
                .smartAlbumCinematic, .smartAlbumSpatial, .smartAlbumScreenRecordings:
                .mediaType
            default: .otherSmartAlbum
            }
        @unknown default: .otherSmartAlbum
        }
    }

    public func folderPaths() async -> [String: [String]] {
        (try? await BlockingWork.run { Self.walkFolders() }) ?? [:]
    }

    /// Descends the folder tree, recording where each album came out.
    ///
    /// **Folders are `PHCollectionList`; albums are `PHAssetCollection`.** Both
    /// are `PHCollection`, and which one a child is is the whole of the
    /// recursion: a list is descended into, anything else is a leaf and gets
    /// the path that reached it.
    private static func walkFolders() -> [String: [String]] {
        var paths: [String: [String]] = [:]

        func descend(into folder: PHCollectionList, at path: [String]) {
            PHCollection.fetchCollections(in: folder, options: nil)
                .enumerateObjects { child, _, _ in
                    if let nested = child as? PHCollectionList {
                        descend(into: nested, at: path + [nested.localizedTitle ?? ""])
                    } else {
                        paths[child.localIdentifier] = path
                    }
                }
        }

        // Top-level *user* collections: the only place folders can be, and the
        // only collections that can be in one.
        PHCollectionList.fetchTopLevelUserCollections(with: nil)
            .enumerateObjects { item, _, _ in
                guard let folder = item as? PHCollectionList else { return }
                descend(into: folder, at: [folder.localizedTitle ?? ""])
            }
        return paths
    }

    /// ~78 ms per collection, measured, whatever its size — so this is called
    /// deliberately and never in a loop that somebody is waiting on.
    public func imageCount(ofCollection identifier: String) async -> Int? {
        try? await BlockingWork.run {
            guard let collection = Self.resolve(identifier) else { return nil }
            return PHAsset.fetchAssets(in: collection, options: Self.imagesOnly()).count
        }
    }

    private static func resolve(_ identifier: String) -> PHAssetCollection? {
        PHAssetCollection.fetchAssetCollections(
            withLocalIdentifiers: [identifier], options: nil
        ).firstObject
    }

    private func collection(_ identifier: String) -> PHAssetCollection? {
        PHAssetCollection.fetchAssetCollections(
            withLocalIdentifiers: [identifier], options: nil
        ).firstObject
    }

    /// Videos are excluded **at the fetch**, by predicate, so they never enter
    /// the row set at all — rather than being enumerated and then discarded.
    static func imagesOnly() -> PHFetchOptions {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(
            format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        return options
    }

    @discardableResult
    public func enumerateImages(
        inCollection identifier: String,
        _ body: (LibraryAsset) async throws -> Void
    ) async throws -> Bool {
        guard let collection = collection(identifier) else { return false }

        // Walked by index rather than collected. `PHFetchResult` is lazy on the
        // fetch — measured at 111 ms and no footprint movement for 95,901
        // assets — so this never materialises the album.
        let assets = PHAsset.fetchAssets(in: collection, options: Self.imagesOnly())
        for index in 0..<assets.count {
            let asset = assets.object(at: index)
            try await body(
                LibraryAsset(
                    identifier: asset.localIdentifier,
                    pixelWidth: asset.pixelWidth,
                    pixelHeight: asset.pixelHeight))
        }
        return true
    }

    public func assetExists(_ identifier: String) async -> Bool {
        asset(identifier) != nil
    }

    private func asset(_ identifier: String) -> PHAsset? {
        PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject
    }

    // MARK: - Resources

    public func resources(ofAsset identifier: String) async -> [LibraryResource] {
        guard let asset = asset(identifier) else { return [] }
        return PHAssetResource.assetResources(for: asset).map(Self.describe)
    }

    static func describe(_ resource: PHAssetResource) -> LibraryResource {
        LibraryResource(
            kind: kind(of: resource.type),
            uniformTypeIdentifier: resource.uniformTypeIdentifier,
            originalFilename: resource.originalFilename)
    }

    /// **Only the kinds the rule names, plus the two it must refuse.**
    ///
    /// Everything else becomes `.other` carrying its raw value, so a resource
    /// type this build has never heard of shows up in a log rather than
    /// quietly becoming a candidate for the bytes we hand to the renderer.
    static func kind(of type: PHAssetResourceType) -> LibraryResourceKind {
        switch type {
        case .photo: .photo
        case .fullSizePhoto: .fullSizePhoto
        case .adjustmentData: .adjustmentData
        case .pairedVideo: .pairedVideo
        case .fullSizePairedVideo: .fullSizePairedVideo
        default: .other(type.rawValue)
        }
    }

    // MARK: - Materialize

    /// Streams one resource to a file.
    ///
    /// **`requestData` rather than `writeData`, and the difference is
    /// cancellation.** Both stream, so neither holds a large original whole —
    /// measured: 3.4 MB written for a 16 kB footprint change, and 2.9 MB for no
    /// measurable change at all. But `writeData` returns no request id and
    /// `PHAssetResourceManager` offers no way to stop one, so a fetch abandoned
    /// on a deadline keeps running inside the daemon and may still deliver its
    /// file. A source that timed out repeatedly would accumulate work nobody
    /// can see or stop. This one has an id and a cancel.
    public func write(
        _ resource: LibraryResource, ofAsset identifier: String, to destination: URL
    ) async throws -> Int64 {
        guard let asset = asset(identifier) else {
            throw PhotoLibraryError.assetMissing(identifier)
        }
        guard
            let match = PHAssetResource.assetResources(for: asset).first(where: {
                Self.kind(of: $0.type) == resource.kind
                    && $0.originalFilename == resource.originalFilename
            })
        else { throw PhotoLibraryError.noUsableResource(identifier) }

        try? FileManager.default.removeItem(at: destination)
        guard FileManager.default.createFile(atPath: destination.path(percentEncoded: false), contents: nil)
        else { throw PhotoLibraryError.writeFailed("could not create \(destination.lastPathComponent)") }
        let handle = try FileHandle(forWritingTo: destination)

        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true

        let sink = ChunkSink(handle: handle)
        do {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                let once = ResumeOnce(continuation)
                let request = RequestHandle()
                let deadline = Task {
                    try? await Task.sleep(for: Self.fetchLimit)
                    request.cancel()
                    once.finish(PhotoLibraryError.writeFailed("no answer within \(Self.fetchLimit)"))
                }
                // **Both handlers are explicitly `@Sendable`, and that is
                // load-bearing.** PhotoKit invokes them on a dispatch queue of
                // its own; written as bare closures inside isolated code, Swift
                // infers them as isolated to the enclosing actor and emits an
                // isolation assertion into each, which trips
                // `dispatch_assert_queue` and takes the process down on the
                // first chunk. Annotating the type removes the inference rather
                // than suppressing the check. No test against a fake catches
                // this, because a fake never calls back from a dispatch queue.
                let received: @Sendable (Data) -> Void = { sink.append($0) }
                let completed: @Sendable ((any Error)?) -> Void = { error in
                    deadline.cancel()
                    once.finish(error)
                }
                request.track(
                    PHAssetResourceManager.default().requestData(
                        for: match, options: options,
                        dataReceivedHandler: received, completionHandler: completed))
            }
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
        try? handle.close()
        return sink.written
    }
}

/// Writes each chunk as it arrives, so nothing accumulates.
private final class ChunkSink: @unchecked Sendable {
    private let lock = NSLock()
    private let handle: FileHandle
    private var count: Int64 = 0

    init(handle: FileHandle) { self.handle = handle }

    func append(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        try? handle.write(contentsOf: data)
        count += Int64(data.count)
    }

    var written: Int64 {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

/// Holds a request id so a deadline can cancel it. The id is returned only
/// after the handlers may already have fired, so the cancel is issued by
/// whichever of the two arrives second.
private final class RequestHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var id: PHAssetResourceDataRequestID = PHInvalidAssetResourceDataRequestID
    private var wanted = false

    func track(_ requestID: PHAssetResourceDataRequestID) {
        lock.lock()
        id = requestID
        let now = wanted
        lock.unlock()
        if now { PHAssetResourceManager.default().cancelDataRequest(requestID) }
    }

    func cancel() {
        lock.lock()
        wanted = true
        let requestID = id
        lock.unlock()
        if requestID != PHInvalidAssetResourceDataRequestID {
            PHAssetResourceManager.default().cancelDataRequest(requestID)
        }
    }
}

/// A continuation that cannot be resumed twice. The completion may race the
/// deadline, and resuming twice is a crash rather than a wrong answer.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: CheckedContinuation<Void, any Error>?

    init(_ continuation: CheckedContinuation<Void, any Error>) { pending = continuation }

    func finish(_ error: (any Error)?) {
        lock.lock()
        let continuation = pending
        pending = nil
        lock.unlock()
        guard let continuation else { return }
        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
    }
}
