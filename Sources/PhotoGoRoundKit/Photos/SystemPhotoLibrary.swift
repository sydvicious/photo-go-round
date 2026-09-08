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
///
/// **Every PhotoKit call goes through `BlockingWork`, without exception.**
/// Three of them did as of 2026-08-26; the rest ran synchronously on the
/// cooperative pool, which is the fault `BlockingWork`'s own doc comment
/// describes — a thread parked in a system call is one the runtime cannot use,
/// and enough of them and nothing runs at all. `title(ofCollection:)`,
/// `assetExists`, `resources(ofAsset:)`, and every index of `enumerateImages`
/// were each a way for a wedged `photolibraryd` to take the agent down with it,
/// which reaches a person as an app that has stopped showing photographs.
///
/// **The bound is not here.** That is `BoundedPhotoLibrary`, because a bound is
/// a rule and rules live where a test can reach them. This file gives the calls
/// a thread they are allowed to block; that one decides how long anybody waits.
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
    ///
    /// **On `BlockingWork` like everything else.** It looks like a property
    /// read and it is a round trip to `photolibraryd`; on a library that has
    /// stopped answering it blocks exactly as the fetches do, and it is asked
    /// first by every call in the provider — so a wedge here wedges everything
    /// behind it.
    public var authorization: LibraryAuthorization {
        get async throws {
            try await BlockingWork.run {
                Self.map(PHPhotoLibrary.authorizationStatus(for: .readWrite))
            }
        }
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
    public func title(ofCollection identifier: String) async throws -> String? {
        try await BlockingWork.run {
            guard let collection = Self.resolve(identifier) else { return nil }
            return collection.localizedTitle ?? ""
        }
    }

    /// **Off the cooperative pool**, because this is 439 PhotoKit round trips
    /// on a real library and every one of them blocks. Parking a cooperative
    /// thread for that is how four concurrent walks stopped the agent answering
    /// picture requests on 2026-08-25.
    public func collections() async throws -> [LibraryCollection] {
        try await BlockingWork.run { Self.everyCollection() }
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

    public func folderPaths() async throws -> [String: [String]] {
        try await BlockingWork.run { Self.walkFolders() }
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
    public func imageCount(ofCollection identifier: String) async throws -> Int? {
        try await BlockingWork.run {
            guard let collection = Self.resolve(identifier) else { return nil }
            return PHAsset.fetchAssets(in: collection, options: Self.imagesOnly()).count
        }
    }

    private static func resolve(_ identifier: String) -> PHAssetCollection? {
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

    /// How many assets one trip onto the blocking queue collects.
    ///
    /// **A compromise between two costs, and neither is memory.** One hop per
    /// asset would put a queue round trip between every photograph in a 95,901
    /// asset library; one hop for the whole album would hold a blocking thread
    /// for the entire walk and hand back the collection this is written not to
    /// build. Five hundred `LibraryAsset` values is on the order of tens of
    /// kilobytes.
    static let enumerationBatch = 500

    @discardableResult
    public func enumerateImages(
        inCollection identifier: String,
        _ body: (LibraryAsset) async throws -> Void
    ) async throws -> Bool {
        // The fetch happens once, off the cooperative pool. `PHFetchResult` is
        // lazy — measured at 111 ms and no footprint movement for 95,901 assets
        // — so this is not the album, it is the handle to it.
        let album = try await BlockingWork.run { () -> Album? in
            guard let collection = Self.resolve(identifier) else { return nil }
            return Album(PHAsset.fetchAssets(in: collection, options: Self.imagesOnly()))
        }
        // Nil is the collection not resolving, which the provider reports as
        // unavailable. A library that could not answer at all threw above and
        // never reaches here — which is the distinction this whole change is
        // about.
        guard let album else { return false }

        let total = await album.count
        var index = 0
        while index < total {
            // **Read in batches on the album's own queue, handed to the sink on
            // the cooperative pool.** `object(at:)` faults its window in from
            // `photolibraryd`; doing that from an async context is what put a
            // cooperative thread inside PhotoKit for every photograph in the
            // library.
            let batch = await album.assets(from: index)
            guard !batch.isEmpty else { break }
            index += batch.count
            for asset in batch { try await body(asset) }
        }
        return true
    }

    /// The fetch result, and the thread it is allowed to block.
    ///
    /// **An actor with a dispatch queue for an executor**, which is the one
    /// construct that gives both halves of what this needs. The actor is what
    /// lets a `PHFetchResult` — which is not `Sendable` — be held safely across
    /// the whole walk, with no unchecked promise to the compiler: the value
    /// never leaves, and only flattened `LibraryAsset` values come out. The
    /// custom executor is what keeps `object(at:)` off the cooperative pool,
    /// since faulting a window in from `photolibraryd` blocks whatever thread
    /// asks. A plain actor would run on the cooperative pool and reintroduce
    /// exactly the fault this file is being changed to remove.
    ///
    /// One queue per album, so two enumerations never wait on each other.
    private actor Album {
        private let fetched: PHFetchResult<PHAsset>
        private let queue: DispatchSerialQueue

        nonisolated var unownedExecutor: UnownedSerialExecutor {
            queue.asUnownedSerialExecutor()
        }

        init(_ fetched: PHFetchResult<PHAsset>) {
            self.fetched = fetched
            self.queue = DispatchSerialQueue(
                label: "com.sydpolk.photogoround.album", qos: .utility)
        }

        var count: Int { fetched.count }

        /// One batch, flattened to values before anything leaves the actor.
        func assets(from start: Int) -> [LibraryAsset] {
            let end = min(start + SystemPhotoLibrary.enumerationBatch, fetched.count)
            guard start < end else { return [] }
            return (start..<end).map { position in
                let asset = fetched.object(at: position)
                return LibraryAsset(
                    identifier: asset.localIdentifier,
                    pixelWidth: asset.pixelWidth,
                    pixelHeight: asset.pixelHeight)
            }
        }
    }

    public func assetExists(_ identifier: String) async throws -> Bool {
        try await BlockingWork.run { Self.asset(identifier) != nil }
    }

    private static func asset(_ identifier: String) -> PHAsset? {
        PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject
    }

    // MARK: - Resources

    public func resources(ofAsset identifier: String) async throws -> [LibraryResource] {
        try await BlockingWork.run {
            guard let asset = Self.asset(identifier) else { return [] }
            return PHAssetResource.assetResources(for: asset).map(Self.describe)
        }
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
        try? FileManager.default.removeItem(at: destination)
        guard FileManager.default.createFile(atPath: destination.path(percentEncoded: false), contents: nil)
        else { throw PhotoLibraryError.writeFailed("could not create \(destination.lastPathComponent)") }
        let handle = try FileHandle(forWritingTo: destination)
        let sink = ChunkSink(handle: handle)

        do {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                let once = ResumeOnce(continuation)
                let request = RequestHandle()
                // **Detached, so the limit is not a child of whatever called
                // this.** It is the only thing that ends a request PhotoKit has
                // stopped making progress on.
                let deadline = Task.detached {
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

                // **The lookup and the request together, on a thread that is
                // allowed to block, and nothing PhotoKit hands back leaves this
                // closure.** A `PHAssetResource` is not `Sendable`, so finding
                // it and starting the stream cannot be split across a hop; and
                // both `fetchAssets` and `assetResources` are round trips into
                // `photolibraryd` that answer at their leisure or not at all.
                //
                // **This is the fault that cost sixteen minutes of dead agent
                // on 2026-09-07, and the file's own header had already
                // forbidden it.** The lookup was hoisted into `BlockingWork` on
                // 2026-08-26 and then done a second time underneath it, bare, on
                // the cooperative thread. With `downloadConcurrency` at 8 and a
                // pool of about ten threads, eight lanes parked eight of them
                // inside a wedged `photolibraryd` and the runtime had nothing
                // left to run anything on. It is not a deadlock and does not
                // look like one: no lock is held, no cycle exists, the process
                // simply stops. What names it unmistakably is that the *timers*
                // stopped — the 60-second limit above was measured firing at
                // 961 seconds, and the unified log was blank for the whole of
                // the interval.
                BlockingWork.detached {
                    guard let asset = Self.asset(identifier) else {
                        deadline.cancel()
                        once.finish(PhotoLibraryError.assetMissing(identifier))
                        return
                    }
                    guard
                        let match = PHAssetResource.assetResources(for: asset).first(where: {
                            Self.kind(of: $0.type) == resource.kind
                                && $0.originalFilename == resource.originalFilename
                        })
                    else {
                        deadline.cancel()
                        once.finish(PhotoLibraryError.noUsableResource(identifier))
                        return
                    }
                    let options = PHAssetResourceRequestOptions()
                    options.isNetworkAccessAllowed = true
                    request.track(
                        PHAssetResourceManager.default().requestData(
                            for: match, options: options,
                            dataReceivedHandler: received, completionHandler: completed))
                }
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
