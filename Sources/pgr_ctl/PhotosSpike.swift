import Console
import Foundation
import ImageIO
import Photos

/// Phase 1 of the Apple Photos plan: measurements, and no change to the kit.
///
/// Everything here answers a question that reading documentation cannot. Does
/// `PHAssetResourceManager` hand back a true original for an asset whose
/// full-resolution copy lives in iCloud, or a downscaled derivative that is a
/// valid JPEG and quietly wrong? Is `PHFetchResult` actually lazy at the size
/// this project's scanner was designed around? Does `writeData` stream, or does
/// it buffer the whole resource into our address space? What does an edited
/// photograph's resource list look like next to an unedited one, and what does a
/// Live Photo's look like?
///
/// **It runs in the wrong process on purpose.** `pgr_ctl` invoked from a
/// terminal is not a bundle, so TCC attributes the request to Terminal and the
/// grant lands there rather than on `com.sydpolk.photogoround.server`. For these
/// numbers that is irrelevant — PhotoKit does not care which bundle got the
/// grant, only that one did. For the product it is the whole question, and it is
/// Phase 4's to answer from the installed agent.
///
/// Nothing here writes to the library, opens the database, or rings a doorbell.
/// The originals it pulls go to a temporary directory and are deleted as soon as
/// they have been measured.
@MainActor
enum PhotosSpike {

    /// How long the local probe is given before it is called inconclusive.
    ///
    /// **This exists because the probe does not fail fast.** The plan's
    /// classification assumes `isNetworkAccessAllowed = false` either succeeds
    /// or errors promptly on an optimized asset. Measured against a real
    /// library it did neither: the first call sat for four and a half minutes
    /// with no file created and no CPU burned. A local read is a disk read and
    /// is over in milliseconds, so anything past this is not a local read
    /// whatever else it turns out to be.
    static let localProbe = Duration.seconds(5)

    /// **Measured, not guessed, and larger than anyone would have guessed.** A
    /// 76 kB 640×480 original took 301.5 seconds to arrive — about 250 bytes a
    /// second, which is not a transfer rate but a queue. A 300-second bound,
    /// which sounded absurdly generous when it was written, would have killed
    /// that very asset. This is a bound rather than a budget: what it prevents
    /// is one asset holding the whole run forever.
    static let downloadLimit = Duration.seconds(900)

    // MARK: - The run

    static func run(
        count: Int, probing probeCount: Int, album requested: String?, listing: Bool
    ) async throws {
        Console.banner(
            """
            photos-spike — PhotoKit measured before any of it enters the kit

            Nothing is written to the library. Originals are copied out to a
            scratch directory, measured, and deleted. The TCC grant this raises belongs to Terminal, not to
            the agent's bundle — see the Phase 4 note in Apple Photos Plan.md.
            """
        )

        try await authorize()

        let footprint = FootprintSampler()
        await footprint.begin()
        defer { Task { await footprint.end() } }

        let collections = collections()
        guard !collections.isEmpty else {
            Console.alert("no albums and no smart albums — nothing here can be measured")
            throw ExitCode(1)
        }
        report(collections, listing: listing)

        guard let target = target(in: collections, requested: requested) else {
            Console.alert("no album named \(requested ?? "") — `photos-spike` lists them above")
            throw ExitCode(1)
        }
        Console.banner("target: \(target.title)  ·  \(target.images) photographs")

        let assets = laziness(of: target)
        resourceLists(across: assets)

        // **The pull selection is computed first so the probe can cover it.**
        // The pulls are the only ground truth available — they find out whether
        // an asset was really here by fetching it — so a probe that did not
        // include them could never be checked against anything.
        let pulling = sample(from: assets, count: count)
        var probing = sample(from: assets, count: probeCount)
        let sampled = Set(probing.map(\.localIdentifier))
        probing.append(contentsOf: pulling.filter { !sampled.contains($0.localIdentifier) })

        let probes = await probeAvailability(
            of: probing, across: assets.count, peak: footprint)
        try await pulls(pulling, peak: footprint, probes: probes)

        let peak = await footprint.end()
        Console.banner(
            "peak phys_footprint across the run: \(Library.bytes(Int64(peak)))"
        )
    }

    // MARK: - Authorization

    /// **`.readWrite`, because there is no read-only access level.** The plan's
    /// *`.readWrite` authorization* decision cannot be implemented as written:
    /// `PHAccessLevel` has exactly two values, `.addOnly` and `.readWrite`, and
    /// `.addOnly` is write-only — it grants saving into the library and nothing
    /// else. Reading an album at all requires `.readWrite`, so the choice this
    /// project actually has is between asking for more than it needs and not
    /// working. `Info.plist` still carries `NSPhotoLibraryUsageDescription`,
    /// which is the correct key for that level, and the usage string is where
    /// the asymmetry gets explained to the person being asked.
    ///
    /// The prompt is raised only when the status is `.notDetermined`, which is
    /// the discipline the provider will follow: never speculatively, and never
    /// from a timer.
    private static func authorize() async throws {
        let existing = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        Console.note("authorization  \(name(existing)) before asking")

        let status =
            existing == .notDetermined
            ? await PHPhotoLibrary.requestAuthorization(for: .readWrite)
            : existing

        switch status {
        case .authorized:
            Console.recovered("authorized — .readWrite, the only level that can read")
        case .limited:
            // An iOS concept macOS does not offer, but it is expressible and a
            // limited grant still returns whatever it returns.
            Console.recovered("limited access — the numbers describe whatever is visible")
        case .denied, .restricted, .notDetermined:
            Console.failure(
                """
                Photos access is \(name(status)).

                System Settings › Privacy & Security › Photos, then run this again.
                The entry to look for is Terminal, not Photo-Go-Round: a command
                run from a shell is not a bundle, and TCC records the grant
                against the process responsible for it.
                """)
            throw ExitCode(1)
        @unknown default:
            Console.failure("Photos access is \(name(status)), which this build does not know")
            throw ExitCode(1)
        }
    }

    // MARK: - The collections

    /// One album, with the two counts and what each cost.
    ///
    /// Both counts are here because Phase 4 has a decision resting on the
    /// difference: `GET /v1/photos/albums` wants an image count per album, the
    /// honest one is a fetch per album, and `estimatedAssetCount` is the cheap
    /// answer that includes videos and is sometimes `NSNotFound`. Printing both
    /// with the fetch's cost is how that choice gets made against evidence
    /// rather than against a worry.
    struct Album {
        let collection: PHAssetCollection
        let identifier: String
        let title: String
        let group: String
        let subtype: String
        let subtypeCode: Int
        let images: Int
        let estimated: Int
        let countCost: Duration
    }

    private static func collections() -> [Album] {
        var albums: [Album] = []
        for (group, type) in [("album", PHAssetCollectionType.album), ("smart", .smartAlbum)] {
            let fetched = PHAssetCollection.fetchAssetCollections(
                with: type, subtype: .any, options: nil)
            fetched.enumerateObjects { collection, _, _ in
                albums.append(describe(collection, group: group))
            }
        }
        return albums
    }

    private static func describe(_ collection: PHAssetCollection, group: String) -> Album {
        let clock = ContinuousClock()
        var images = 0
        let cost = clock.measure {
            images = PHAsset.fetchAssets(in: collection, options: imagesOnly()).count
        }
        return Album(
            collection: collection,
            identifier: collection.localIdentifier,
            title: collection.localizedTitle ?? "(untitled)",
            group: group,
            subtype: name(collection.assetCollectionSubtype),
            subtypeCode: collection.assetCollectionSubtype.rawValue,
            images: images,
            estimated: collection.estimatedAssetCount,
            countCost: cost
        )
    }

    /// **By subtype, not by collection.** Four hundred and thirty-nine
    /// collections at three lines apiece is thirteen hundred lines of scrollback
    /// to reach the four numbers underneath it, and the per-collection detail
    /// answers a question nobody asked twice. What the Phase 4 allowlist needs
    /// is the subtypes — `smartAlbumVideos` and its siblings can only ever offer
    /// an empty source, and `smartAlbumAllHidden` would offer to put hidden
    /// photographs on a wall, neither of which is a decision to make by
    /// omission. That is two dozen rows. `--albums` prints all of them when the
    /// identifier of a particular album is what is actually wanted.
    private static func report(_ albums: [Album], listing: Bool) {
        Console.banner("\(albums.count) collections")

        if listing {
            for album in albums.sorted(by: { $0.images > $1.images }) {
                let estimate =
                    album.estimated == NSNotFound
                    ? "estimate unavailable" : "\(album.estimated) estimated (with video)"
                Console.note(
                    "\(album.images.formatted().paddedLeft(6))  \(album.title)"
                        + "\n        \(album.group) · \(album.subtype) (\(album.subtypeCode)) · "
                        + "\(estimate) · counted in \(milliseconds(album.countCost))"
                        + "\n        \(album.identifier)")
            }
            print()
        } else {
            bySubtype(albums)
        }

        let total = albums.map(\.countCost).reduce(Duration.zero, +)
        print()
        Console.note(
            "counting every album by fetch cost \(milliseconds(total)) in total — the number "
                + "GET /v1/photos/albums would pay per request")

        // Titles are not unique: the same album appears as `albumRegular` and
        // again as `albumCloudShared`. A picker showing titles shows duplicates.
        let repeated = Dictionary(grouping: albums, by: \.title).filter { $0.value.count > 1 }
        if !repeated.isEmpty {
            Console.note(
                "\(repeated.count) titles belong to more than one collection — a picker showing "
                    + "titles alone cannot tell them apart")
        }
        if !listing {
            Console.note("`--albums` lists every collection with its identifier")
        }
    }

    /// The rows the allowlist is chosen from.
    private static func bySubtype(_ albums: [Album]) {
        struct Row {
            var collections = 0
            var photos = 0
            var withoutEstimate = 0
            var name = ""
            var group = ""
        }
        var rows: [Int: Row] = [:]
        for album in albums {
            var row = rows[album.subtypeCode] ?? Row()
            row.collections += 1
            row.photos += album.images
            if album.estimated == NSNotFound { row.withoutEstimate += 1 }
            row.name = album.subtype
            row.group = album.group
            rows[album.subtypeCode] = row
        }

        Console.note(
            "\("subtype".paddedRight(34))\("of".paddedLeft(5))"
                + "\("photos".paddedLeft(10))   estimate")
        for (code, row) in rows.sorted(by: { $0.value.photos > $1.value.photos }) {
            let estimate =
                row.withoutEstimate == row.collections
                ? "none" : (row.withoutEstimate == 0 ? "all" : "\(row.collections - row.withoutEstimate)/\(row.collections)")
            Console.note(
                "\("\(row.name) (\(code))".paddedRight(34))"
                    + "\(row.collections.formatted().paddedLeft(5))"
                    + "\(row.photos.formatted().paddedLeft(10))   \(estimate)")
        }
    }

    /// The largest album, or the one named on the command line.
    ///
    /// `smartAlbumAllHidden` is never chosen automatically. It is listed above,
    /// because deciding the allowlist needs to see it, but pulling originals out
    /// of somebody's hidden photographs because it happened to be the biggest
    /// album is not a thing to do by accident.
    private static func target(in albums: [Album], requested: String?) -> Album? {
        if let requested {
            return albums.first {
                $0.identifier == requested || $0.title.caseInsensitiveCompare(requested) == .orderedSame
            }
        }
        return albums
            .filter { $0.collection.assetCollectionSubtype != .smartAlbumAllHidden }
            .filter { $0.images > 0 }
            .max { $0.images < $1.images }
    }

    // MARK: - Enumeration laziness

    /// `PLAN.md`'s *Cold start* asserts that `PHAsset.fetchAssets` is lazy, and
    /// the constant-memory scanner depends on it for a hundred-thousand-asset
    /// library. `PHFetchResult` is documented to fetch lazily and in practice it
    /// does — "in practice it does" being exactly what a spike is for.
    ///
    /// What we want: a fetch that returns in milliseconds with a flat footprint,
    /// and a walk that costs the time. A fetch that takes seconds and moves the
    /// footprint means the result materialized, and the provider needs
    /// `enumerateObjects` over a batched range rather than index access.
    private static func laziness(of album: Album) -> PHFetchResult<PHAsset> {
        let clock = ContinuousClock()
        let before = Footprint.current()

        var result: PHFetchResult<PHAsset>!
        let fetch = clock.measure {
            result = PHAsset.fetchAssets(in: album.collection, options: imagesOnly())
        }
        let afterFetch = Footprint.current()

        var walked = 0
        let walk = clock.measure {
            result.enumerateObjects { _, _, _ in walked += 1 }
        }
        let afterWalk = Footprint.current()

        Console.banner(
            """
            enumeration
              fetch  \(milliseconds(fetch))   footprint \(delta(before, afterFetch))
              walk   \(milliseconds(walk))   footprint \(delta(afterFetch, afterWalk))  · \(walked) assets
            """
        )
        return result
    }

    // MARK: - Resource lists

    /// The edited-photo question `PLAN.md` leaves open, and the Live Photo trap.
    ///
    /// Taking `.pairedVideo` by mistake is not a subtle failure: it writes a
    /// `.mov` under a key the renderer hands to `CGImageSourceCreateThumbnail`,
    /// which returns nil, which retires the photograph as unrenderable — so the
    /// symptom is pictures quietly vanishing, three deals at a time. Printing
    /// the whole list rather than probing for one type is what makes the rule
    /// obvious before it can be got wrong.
    ///
    /// `.fullSizePhoto` is the adjusted render, but `.adjustmentData` is what
    /// indicates an edit exists — an asset can carry the former for other
    /// reasons, so the edited candidate is chosen by the latter.
    private static func resourceLists(across assets: PHFetchResult<PHAsset>) {
        var edited: PHAsset?
        var unedited: PHAsset?
        var live: PHAsset?

        // Bounded: this reads a resource list per asset, which is a local
        // database hit but not a free one, and three examples is the point.
        let horizon = min(assets.count, 500)
        for index in 0..<horizon {
            let asset = assets.object(at: index)
            let types = Set(PHAssetResource.assetResources(for: asset).map(\.type))
            if edited == nil, types.contains(.adjustmentData) { edited = asset }
            if unedited == nil, !types.contains(.adjustmentData) { unedited = asset }
            if live == nil, asset.mediaSubtypes.contains(.photoLive) { live = asset }
            if edited != nil, unedited != nil, live != nil { break }
        }

        Console.banner("resource lists  (first \(horizon) assets examined)")
        show(edited, called: "edited — carries .adjustmentData")
        show(unedited, called: "unedited")
        show(live, called: "Live Photo")
        if edited == nil {
            Console.note("no edited asset in the first \(horizon) — "
                + "run again with --album naming one that has edits")
        }
    }

    private static func show(_ asset: PHAsset?, called label: String) {
        guard let asset else {
            Console.note("\(label): none found")
            return
        }
        Console.note(
            "\(label)  \(asset.pixelWidth)×\(asset.pixelHeight)  \(asset.localIdentifier)")
        for resource in PHAssetResource.assetResources(for: asset) {
            Console.note(
                "        \(name(resource.type).paddedRight(26))"
                    + "\(resource.uniformTypeIdentifier)   \(resource.originalFilename)")
        }
        print()
    }


    // MARK: - Is it already here?

    /// What one probe concluded about one asset, and what it cost.
    struct Probe {
        let identifier: String
        /// `PHImageManager` handed back bytes without touching the network.
        let imageSaysLocal: Bool
        /// …and the flag it is documented to set when it did not.
        let imageSaysInCloud: Bool
        /// Bytes `requestImageDataAndOrientation` put in our address space.
        /// **This is the hazard `PLAN.md` avoids on principle**, measured.
        let imageBytes: Int64
        let imageElapsed: Duration
        let imagePeak: Int64

        /// `requestData` delivered a first chunk before we cancelled it.
        let resourceSaysLocal: Bool
        let resourceElapsed: Duration
        let resourcePeak: Int64

        /// The two probes reached the same conclusion.
        var agree: Bool { imageSaysLocal == resourceSaysLocal }
    }

    /// There is no bulk answer, so this measures what the per-asset answers cost.
    ///
    /// **No list of locally-available assets exists in the public API.** Local
    /// availability is not a `PHAsset` property, so no `PHFetchOptions`
    /// predicate can select on it, and `PHAssetResource`'s `locallyAvailable`
    /// is reachable only through `value(forKey:)`, which is private API wearing
    /// a hat. What does exist is two per-asset probes, and the question worth
    /// measuring is what each costs and whether they agree:
    ///
    /// - **`PHImageManager.requestImageDataAndOrientation`** with the network
    ///   disallowed. Documented to set `PHImageResultIsInCloudKey` when a
    ///   network request would be needed. Its cost is that a *local* asset
    ///   hands back the whole original as `Data` — the exact address-space
    ///   problem `PLAN.md` chose `PHAssetResourceManager` to avoid. Measured
    ///   here rather than assumed.
    /// - **`PHAssetResourceManager.requestData`** with the network disallowed,
    ///   cancelled the instant a first chunk arrives. First byte means local,
    ///   an error means iCloud, and nothing large is ever held. This one is
    ///   cancellable — `writeData` is not — which is why it is a candidate for
    ///   the provider's `materialize` and not only for this probe.
    ///
    /// **It runs before the pulls, and it must.** A pull downloads the asset
    /// and makes it local, so probing afterwards would be asking a question the
    /// measurement itself already answered.
    private static func probeAvailability(
        of assets: [PHAsset], across album: Int, peak: FootprintSampler
    ) async -> [String: Probe] {
        Console.banner(
            """
            availability, per asset  ·  \(assets.count) sampled

            There is no bulk query. Both of these are one call per asset, which
            is affordable for an agent on a timer and not for a picker.
            """
        )

        var probes: [String: Probe] = [:]
        for asset in assets {
            let probe = await probe(asset, peak: peak)
            probes[asset.localIdentifier] = probe
            describe(probe)
        }
        summarize(probes, over: album)
        return probes
    }

    private static func probe(_ asset: PHAsset, peak: FootprintSampler) async -> Probe {
        let clock = ContinuousClock()

        var imageBase = await peak.openWindow()
        var start = clock.now
        let image = await probeViaImageManager(asset)
        let imageElapsed = clock.now - start
        let imagePeak = Int64(bitPattern: await peak.closeWindow()) - Int64(bitPattern: imageBase)

        imageBase = await peak.openWindow()
        start = clock.now
        let resourceLocal = await probeViaResourceManager(asset)
        let resourceElapsed = clock.now - start
        let resourcePeak = Int64(bitPattern: await peak.closeWindow()) - Int64(bitPattern: imageBase)

        return Probe(
            identifier: asset.localIdentifier,
            imageSaysLocal: image.bytes > 0,
            imageSaysInCloud: image.inCloud,
            imageBytes: image.bytes,
            imageElapsed: imageElapsed,
            imagePeak: imagePeak,
            resourceSaysLocal: resourceLocal,
            resourceElapsed: resourceElapsed,
            resourcePeak: resourcePeak
        )
    }

    /// `.original` and `.highQualityFormat` deliberately: a thumbnail request
    /// can be satisfied from a cache for an asset whose original is in iCloud,
    /// which would make the answer true about the wrong thing.
    private static func probeViaImageManager(
        _ asset: PHAsset
    ) async -> (bytes: Int64, inCloud: Bool) {
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = false
        options.isSynchronous = false
        options.version = .original
        options.deliveryMode = .highQualityFormat

        return await withCheckedContinuation {
            (continuation: CheckedContinuation<(bytes: Int64, inCloud: Bool), Never>) in
            let once = ResumeOnceValue(continuation)
            let request = ImageRequest()
            // **The deadline this call went without.** Network access is
            // disallowed so it ought to refuse immediately — but "ought to" is
            // what a fixed 300-second stall already made a fool of once, and
            // there was nothing here to stop it happening 200 times.
            let deadline = Task {
                try? await Task.sleep(for: localProbe)
                request.cancel()
                once.finish((0, false))
            }
            let handler:
                @Sendable (Data?, String?, CGImagePropertyOrientation, [AnyHashable: Any]?) -> Void =
                { data, _, _, info in
                    deadline.cancel()
                    let inCloud = (info?[PHImageResultIsInCloudKey] as? NSNumber)?.boolValue ?? false
                    once.finish((Int64(data?.count ?? 0), inCloud))
                }
            request.track(
                PHImageManager.default().requestImageDataAndOrientation(
                    for: asset, options: options, resultHandler: handler))
        }
    }

    /// Cancelled on the first chunk, so nothing large is ever held and the
    /// answer arrives as early as it can.
    private static func probeViaResourceManager(_ asset: PHAsset) async -> Bool {
        guard let resource = preferred(PHAssetResource.assetResources(for: asset)) else {
            return false
        }
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = false

        return await withCheckedContinuation {
            (continuation: CheckedContinuation<Bool, Never>) in
            let probe = ResourceProbe(continuation)
            let deadline = Task {
                try? await Task.sleep(for: localProbe)
                probe.giveUp()
            }
            // **Both handlers are explicitly `@Sendable`, and that is load-bearing.**
            //
            // PhotoKit invokes them on a dispatch queue of its own. Written as
            // bare closures inside a `@MainActor` function, against a block
            // parameter the importer does not mark sendable, Swift infers them
            // as main-actor-isolated and emits an isolation assertion into each
            // one — which then trips `dispatch_assert_queue` and takes the
            // process down the first time a chunk arrives. Annotating the type
            // removes the inference rather than papering over the check.
            let received: @Sendable (Data) -> Void = { _ in
                deadline.cancel()
                probe.sawBytes()
            }
            let completed: @Sendable ((any Error)?) -> Void = { error in
                deadline.cancel()
                probe.completed(error)
            }
            let id = PHAssetResourceManager.default().requestData(
                for: resource, options: options,
                dataReceivedHandler: received, completionHandler: completed)
            probe.track(id)
        }
    }

    /// The first chunk is the answer, so the request is cancelled the moment it
    /// arrives rather than being allowed to deliver a whole original.
    ///
    /// The request id arrives *after* the handlers may already have fired —
    /// `requestData` can deliver synchronously — so the cancel is issued either
    /// when the id lands or when the bytes do, whichever is second.
    private final class ResourceProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Bool, Never>?
        private var id: PHAssetResourceDataRequestID = PHInvalidAssetResourceDataRequestID
        private var wantsCancel = false

        init(_ continuation: CheckedContinuation<Bool, Never>) {
            self.continuation = continuation
        }

        func track(_ requestID: PHAssetResourceDataRequestID) {
            lock.lock()
            id = requestID
            let cancelNow = wantsCancel
            lock.unlock()
            if cancelNow { PHAssetResourceManager.default().cancelDataRequest(requestID) }
        }

        func sawBytes() {
            lock.lock()
            wantsCancel = true
            let requestID = id
            let pending = continuation
            continuation = nil
            lock.unlock()
            if requestID != PHInvalidAssetResourceDataRequestID {
                PHAssetResourceManager.default().cancelDataRequest(requestID)
            }
            pending?.resume(returning: true)
        }

        /// An error means the bytes are not here. A cancellation error after we
        /// already saw bytes is our own doing and never reaches this, because
        /// the continuation is spent by then.
        func completed(_ error: (any Error)?) {
            lock.lock()
            let pending = continuation
            continuation = nil
            lock.unlock()
            pending?.resume(returning: error == nil)
        }

        func giveUp() {
            lock.lock()
            let pending = continuation
            continuation = nil
            let requestID = id
            lock.unlock()
            if requestID != PHInvalidAssetResourceDataRequestID {
                PHAssetResourceManager.default().cancelDataRequest(requestID)
            }
            pending?.resume(returning: false)
        }
    }

    /// Holds an image request id so a deadline can cancel it, with the same
    /// late-arrival handling as `ResourceProbe`: the id is returned only after
    /// the handler may already have run.
    private final class ImageRequest: @unchecked Sendable {
        private let lock = NSLock()
        private var id: PHImageRequestID = PHInvalidImageRequestID
        private var cancelled = false

        func track(_ requestID: PHImageRequestID) {
            lock.lock()
            id = requestID
            let now = cancelled
            lock.unlock()
            if now { PHImageManager.default().cancelImageRequest(requestID) }
        }

        func cancel() {
            lock.lock()
            cancelled = true
            let requestID = id
            lock.unlock()
            if requestID != PHInvalidImageRequestID {
                PHImageManager.default().cancelImageRequest(requestID)
            }
        }
    }

    /// A continuation that cannot be resumed twice, for the non-throwing case.
    private final class ResumeOnceValue<Value: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var pending: CheckedContinuation<Value, Never>?

        init(_ continuation: CheckedContinuation<Value, Never>) { pending = continuation }

        func finish(_ value: Value) {
            lock.lock()
            let continuation = pending
            pending = nil
            lock.unlock()
            continuation?.resume(returning: value)
        }
    }

    private static func describe(_ probe: Probe) {
        let verdict = probe.resourceSaysLocal ? "here" : "iCloud"
        let colour: Console.Colour = probe.resourceSaysLocal ? .cyan : .yellow
        var suffix =
            "resource \(milliseconds(probe.resourceElapsed)) · "
            + "image \(milliseconds(probe.imageElapsed))"
        if probe.imageBytes > 0 {
            suffix += " holding \(Library.bytes(probe.imageBytes))"
        }
        if probe.imageSaysInCloud { suffix += " · PHImageResultIsInCloudKey" }
        if !probe.agree { suffix += " · PROBES DISAGREE" }
        Console.change("·", verdict, colour, suffix: suffix, whole: true)
    }

    /// What the probes cost, whether they agree, and what probing a whole
    /// album would come to.
    private static func summarize(_ probes: [String: Probe], over sampled: Int) {
        let all = Array(probes.values)
        guard !all.isEmpty else { return }

        let here = all.filter(\.resourceSaysLocal).count
        let disagreed = all.filter { !$0.agree }
        let resourceCost = all.map { seconds($0.resourceElapsed) }
        let imageCost = all.map { seconds($0.imageElapsed) }

        print()
        Console.note("\(here) of \(all.count) already here, \(all.count - here) in iCloud")
        Console.note(
            "requestData  median \(Library.number(median(resourceCost) * 1000, places: 1))ms · "
                + "total \(Library.number(resourceCost.reduce(0, +), places: 1))s")
        Console.note(
            "imageData    median \(Library.number(median(imageCost) * 1000, places: 1))ms · "
                + "total \(Library.number(imageCost.reduce(0, +), places: 1))s")

        let held = all.map(\.imageBytes).max() ?? 0
        if held > 0 {
            Console.alert(
                "requestImageDataAndOrientation put up to \(Library.bytes(held)) in our address "
                    + "space for a single asset — this is the cost PLAN.md rejected it for, and "
                    + "it is real")
        }

        if disagreed.isEmpty {
            Console.recovered(
                "both probes agreed on all \(all.count) — the cheap one can be trusted")
        } else {
            Console.alert(
                "\(disagreed.count) of \(all.count) disagreed. requestData is the one that "
                    + "asks about the original resource; PHImageManager answers about a rendition")
        }

        // The number that decides whether an agent can afford to know.
        //
        // `sampled` is the size of the *album*, not of the sample. The first
        // version of this line multiplied by the sample size and so reported
        // the cost of the work it had just finished doing, which is a number
        // nobody needs and which reads as wonderfully cheap.
        let perAsset = median(resourceCost)
        if perAsset > 0, sampled > 0 {
            let whole = perAsset * Double(sampled)
            let rendered =
                whole < 90
                ? "\(Library.number(whole, places: 1))s"
                : "\(Library.number(whole / 60, places: 1)) minutes"
            Console.note(
                "at this median, probing all \(sampled.formatted()) assets in the target album "
                    + "would take \(rendered)")
        }
    }

    // MARK: - Pulling originals

    /// One asset pulled, classified, and checked.
    private struct Pull {
        let identifier: String
        let local: Bool
        /// The local probe neither succeeded nor errored — it ran out of time.
        /// Counted separately, because "we could not tell" is not the same
        /// claim as "this asset is in iCloud".
        let probeTimedOut: Bool
        let elapsed: Duration
        let bytes: Int64
        let expected: (width: Int, height: Int)
        let written: (width: Int, height: Int)?

        /// `phys_footprint` immediately before the write began.
        let baseline: UInt64
        /// The highest reading seen between that moment and the completion
        /// handler firing, and nothing outside it.
        let peak: UInt64
        /// After the write, before the file is deleted. What did not come back.
        let after: UInt64

        /// **The number the whole memory argument turns on.** If `writeData`
        /// streams, this is flat across a 2 MB JPEG and a 100 MB ProRAW alike.
        /// If it buffers, it tracks `bytes`.
        var highWater: Int64 { Int64(bitPattern: peak) - Int64(bitPattern: baseline) }

        /// What the pull left behind once it finished. Distinct from
        /// `highWater`: a write can spike and give it all back, and only the
        /// spike says whether the resource was ever held whole.
        var retained: Int64 { Int64(bitPattern: after) - Int64(bitPattern: baseline) }

        /// Equal, or equal with the axes swapped.
        ///
        /// The swap is not a fudge. `PHAsset` reports the asset's dimensions and
        /// `CGImageSource` reports the file's own axes, and a JPEG carrying an
        /// EXIF orientation of 6 differs between the two by a rotation and
        /// nothing else. Calling that a downscale would be a false alarm on the
        /// one measurement the whole design rests on.
        var fullResolution: Bool {
            guard let written else { return false }
            if written.width == expected.width && written.height == expected.height { return true }
            return written.width == expected.height && written.height == expected.width
        }

        var rotated: Bool {
            guard let written, fullResolution else { return false }
            return written.width != expected.width
        }
    }

    /// Attempt `writeData` with `isNetworkAccessAllowed = false` first. Success
    /// means the asset was local and the elapsed time is a local read; failure
    /// means it was iCloud-optimized, and the retry with `true` times the
    /// download. One classification and two timings out of two calls, with no
    /// private API and no guessing.
    ///
    /// If the first attempt *succeeds* on an optimized asset — handing back the
    /// derivative rather than failing — that is a far more important finding
    /// than any throughput number, because it means the flag is not the guard we
    /// think it is and every materialize needs a dimension check of its own.
    /// That case shows up here as a local pull that is not full resolution.
    private static func pulls(
        _ chosen: [PHAsset], peak: FootprintSampler, probes: [String: Probe]
    ) async throws {
        guard !chosen.isEmpty else {
            Console.alert("the target album has no photographs — nothing to pull")
            return
        }

        let scratch = FileManager.default.temporaryDirectory
            .appending(path: "photos-spike-\(ProcessInfo.processInfo.processIdentifier)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        Console.banner("pulling \(chosen.count) originals into \(scratch.path(percentEncoded: false))")

        var results: [Pull] = []
        for asset in chosen {
            guard let resource = preferred(PHAssetResource.assetResources(for: asset)) else {
                Console.alert("\(asset.localIdentifier) has no .photo or .fullSizePhoto resource")
                continue
            }
            if let pull = try await pull(asset, resource, into: scratch, peak: peak) {
                results.append(pull)
                describe(pull, resource: resource, probe: probes[asset.localIdentifier])
            }
        }
        summarize(results, probes: probes)
    }

    /// Spread across the album rather than taking the first N, because the
    /// first N of an album are usually the same vintage and therefore the same
    /// side of the local/optimized split — which is the split the whole
    /// measurement exists to separate.
    private static func sample(from assets: PHFetchResult<PHAsset>, count: Int) -> [PHAsset] {
        let total = assets.count
        let step = max(1, total / max(1, count))
        var chosen: [PHAsset] = []
        var index = 0
        while index < total && chosen.count < count {
            chosen.append(assets.object(at: index))
            index += step
        }
        return chosen
    }

    /// `.fullSizePhoto` when present, `.photo` otherwise, and never
    /// `.pairedVideo`. The first is the edited render, the second the original.
    private static func preferred(_ resources: [PHAssetResource]) -> PHAssetResource? {
        resources.first { $0.type == .fullSizePhoto } ?? resources.first { $0.type == .photo }
    }

    private static func pull(
        _ asset: PHAsset, _ resource: PHAssetResource, into scratch: URL, peak: FootprintSampler
    ) async throws -> Pull? {
        let destination = scratch.appending(path: UUID().uuidString)
        let clock = ContinuousClock()

        // **The window opens immediately before the write and closes when the
        // completion handler fires**, so what it reports belongs to this one
        // pull. A single peak across the whole run cannot answer the question
        // the peak exists to answer: the enumeration walk moves the footprint
        // by more than a hundred megabytes before the first pull begins, and it
        // would sit above every write forever.
        var local = true
        var timedOut = false
        var elapsed = Duration.zero
        var baseline = await peak.openWindow()
        do {
            let start = clock.now
            try await write(
                resource, to: destination, allowingNetwork: false, within: localProbe,
                reporting: nil)
            elapsed = clock.now - start
        } catch {
            local = false
            timedOut = error is WriteTimedOut
            // **The abandoned write cannot be cancelled.** `writeData` returns
            // no request id and `PHAssetResourceManager` offers no way to stop
            // one, so a probe that timed out is still running and may yet
            // create its destination. The retry therefore writes to a fresh
            // path rather than the same one, and the scratch directory is
            // cleaned as a whole at the end.
            let retry = scratch.appending(path: UUID().uuidString)
            // The abandoned attempt is not part of the measurement. Re-baseline
            // so the download is timed and sampled on its own.
            baseline = await peak.openWindow()
            do {
                let start = clock.now
                try await write(
                    resource, to: retry, allowingNetwork: true, within: downloadLimit,
                    reporting: shortIdentifier(asset))
                elapsed = clock.now - start
            } catch {
                Console.alert("\(shortIdentifier(asset)) could not be written: \(error)")
                return nil
            }
            return finish(
                asset, at: retry, local: false, timedOut: timedOut, elapsed: elapsed,
                baseline: baseline, peak: await peak.closeWindow())
        }
        return finish(
            asset, at: destination, local: local, timedOut: timedOut, elapsed: elapsed,
            baseline: baseline, peak: await peak.closeWindow())
    }

    /// Measures what was written and deletes it.
    private static func finish(
        _ asset: PHAsset, at destination: URL, local: Bool, timedOut: Bool,
        elapsed: Duration, baseline: UInt64, peak windowPeak: UInt64
    ) -> Pull {
        let after = Footprint.current() ?? windowPeak
        defer { try? FileManager.default.removeItem(at: destination) }
        let attributes = try? FileManager.default.attributesOfItem(
            atPath: destination.path(percentEncoded: false))
        let bytes = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        return Pull(
            identifier: asset.localIdentifier,
            local: local,
            probeTimedOut: timedOut,
            elapsed: elapsed,
            bytes: bytes,
            expected: (asset.pixelWidth, asset.pixelHeight),
            written: pixelSize(of: destination),
            baseline: baseline,
            peak: windowPeak,
            after: after
        )
    }

    private static func describe(_ pull: Pull, resource: PHAssetResource, probe: Probe?) {
        let written =
            pull.written.map { "\($0.width)×\($0.height)" } ?? "unreadable by CGImageSource"
        let dimensions =
            pull.fullResolution
            ? (pull.rotated ? "full resolution (rotated)" : "full resolution")
            : "SHORT of \(pull.expected.width)×\(pull.expected.height)"
        let suffix =
            "\(name(resource.type)) · \(Library.bytes(pull.bytes)) · \(written) \(dimensions)"
            + " · \(milliseconds(pull.elapsed)) · peak \(signed(pull.highWater))"
            + ", kept \(signed(pull.retained))"

        let classification =
            pull.local ? "local" : (pull.probeTimedOut ? "downloaded (probe timed out)" : "downloaded")
        var annotated = suffix
        if let probe {
            // **The only check the probe ever gets.** A pull knows the truth,
            // because it went and found out.
            let predicted = probe.resourceSaysLocal
            annotated += predicted == pull.local
                ? " · probe agreed"
                : " · PROBE WAS WRONG (said \(predicted ? "here" : "iCloud"))"
        }
        if pull.fullResolution {
            Console.change(
                "✓", classification, pull.local ? .cyan : .yellow, suffix: annotated, whole: true)
        } else {
            Console.alert("\(classification)  \(annotated)")
        }
    }

    /// The exit gate, stated as numbers.
    ///
    /// An average across both classes describes neither, so the two are never
    /// combined: a library where a third of the assets are optimized behaves
    /// nothing like one where none are.
    private static func summarize(_ pulls: [Pull], probes: [String: Probe]) {
        guard !pulls.isEmpty else { return }

        func throughput(_ group: [Pull], called label: String) {
            guard !group.isEmpty else {
                Console.note("\(label.paddedRight(12))none")
                return
            }
            let bytes = group.reduce(Int64(0)) { $0 + $1.bytes }
            let seconds = group.reduce(0.0) { $0 + self.seconds($1.elapsed) }
            let rate = seconds > 0 ? Double(bytes) / seconds : 0
            Console.note(
                "\(label.paddedRight(12))\(group.count) assets · \(Library.bytes(bytes)) · "
                    + "\(Library.number(seconds, places: 2))s · "
                    + "\(Library.bytes(Int64(rate)))/s")
        }

        Console.banner("throughput")
        throughput(pulls.filter(\.local), called: "local")
        throughput(pulls.filter { !$0.local }, called: "downloaded")

        let inconclusive = pulls.filter(\.probeTimedOut).count
        if inconclusive > 0 {
            Console.note(
                "\(inconclusive) local probes ran out of time rather than answering — "
                    + "counted as downloaded, but the classification is ours, not PhotoKit's")
        }

        // **A per-asset figure, because a bytes-per-second one lies here.** The
        // slowest download measured was 76 kB in 301.5 seconds. Reported as a
        // rate that is 252 bytes a second, which reads like a modem and is not
        // what is happening: the cost is per asset and barely moves with size.
        // The queue filler's budget is set by this number, not by bandwidth.
        let downloaded = pulls.filter { !$0.local }
        if !downloaded.isEmpty {
            let each = downloaded.map { seconds($0.elapsed) }
            let total = each.reduce(0, +)
            Console.note(
                "per downloaded asset: "
                    + "min \(Library.number(each.min() ?? 0, places: 1))s · "
                    + "median \(Library.number(median(each), places: 1))s · "
                    + "max \(Library.number(each.max() ?? 0, places: 1))s · "
                    + "mean \(Library.number(total / Double(each.count), places: 1))s")
        }

        let short = pulls.filter { !$0.fullResolution }
        print()
        if short.isEmpty {
            Console.recovered(
                "every written file matched its asset's own pixel dimensions — "
                    + "PHAssetResourceManager returns true originals")
        } else {
            Console.alert(
                "\(short.count) of \(pulls.count) written files were smaller than the asset says "
                    + "it is. The design in PLAN.md's *Getting full-resolution originals out of "
                    + "Photos* does not hold as written.")
        }

        // The probe's accuracy, against assets that were actually fetched.
        let checked = pulls.compactMap { pull -> Bool? in
            probes[pull.identifier].map { $0.resourceSaysLocal == pull.local }
        }
        if !checked.isEmpty {
            let right = checked.filter { $0 }.count
            print()
            if right == checked.count {
                Console.recovered(
                    "the availability probe was right about all \(checked.count) assets that "
                        + "were then fetched")
            } else {
                Console.alert(
                    "the availability probe was right about \(right) of \(checked.count) — "
                        + "it cannot be trusted to order the fill")
            }
        }

        memory(pulls)
    }

    /// Does the write stream, or does it buffer?
    ///
    /// The claim that justifies `PHAssetResourceManager` over
    /// `requestImageDataAndOrientation` is that a 100 MB ProRAW is never a
    /// 100 MB `Data` in the agent. That is testable and this is the test: sort
    /// the pulls by file size and look at whether the high-water mark of each
    /// write follows it. Flat means streaming. Tracking means the memory
    /// discipline the scanner was built around does not survive this provider.
    private static func memory(_ pulls: [Pull]) {
        Console.banner("memory, per pull")
        for pull in pulls.sorted(by: { $0.bytes < $1.bytes }) {
            Console.note(
                "\(Library.bytes(pull.bytes).paddedLeft(11))  "
                    + "peak \(signed(pull.highWater).paddedRight(12))"
                    + "kept \(signed(pull.retained).paddedRight(12))"
                    + "\(pull.local ? "local" : "downloaded")")
        }

        guard let smallest = pulls.min(by: { $0.bytes < $1.bytes }),
            let largest = pulls.max(by: { $0.bytes < $1.bytes }),
            largest.bytes > 0
        else { return }

        print()
        let spread = Double(largest.bytes) / Double(max(smallest.bytes, 1))
        Console.note(
            "file size spans \(Library.number(spread, places: 1))× "
                + "(\(Library.bytes(smallest.bytes)) to \(Library.bytes(largest.bytes)))")

        // **Judged on the largest file, and never on the worst ratio.**
        //
        // The worst ratio was the first rule here and it was wrong, loudly: it
        // reported "buffered" against a run whose 2.9 MB write moved the
        // footprint by nothing at all. The pull it fired on was a 76 kB file
        // that cost 246 kB — which is `PHAssetResourceManager` waking up for
        // the first time in the process, not a buffer, and a ratio computed on
        // the smallest file in the set is dominated by exactly that kind of
        // fixed cost.
        //
        // The question is whether the peak *follows the file*, so the honest
        // test is the largest file, with the first pull excluded because it
        // carries the process's one-time setup wherever it happens to land in
        // the size order.
        let steady = pulls.count > 1 ? Array(pulls.dropFirst()) : pulls
        let first = pulls.first
        if let first, pulls.count > 1 {
            Console.note(
                "first pull excluded from the verdict: \(signed(first.highWater)) for "
                    + "\(Library.bytes(first.bytes)) is one-time setup, not a buffer")
        }

        guard let biggest = steady.max(by: { $0.bytes < $1.bytes }) else { return }
        let ratio = Double(max(biggest.highWater, 0)) / Double(max(biggest.bytes, 1))
        let worstHeld = steady.map(\.highWater).max() ?? 0
        Console.note(
            "largest steady write held \(signed(biggest.highWater)) while writing "
                + "\(Library.bytes(biggest.bytes)) — \(Library.number(ratio, places: 3))× the file; "
                + "worst of any was \(signed(worstHeld))")

        if ratio < 0.25 {
            Console.recovered(
                "the write streams: peak footprint does not follow file size across a "
                    + "\(Library.number(spread, places: 1))× range")
        } else {
            Console.alert(
                "the write is buffered somewhere — peak footprint tracks file size, and "
                    + "PLAN.md's case for PHAssetResourceManager rests on it not doing that")
        }
    }

    private static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2)
            ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }

    // MARK: - Writing a resource

    /// The write ran out of time rather than failing.
    ///
    /// A distinct type because the two mean different things about the asset:
    /// an error from the local probe says the bytes are not here, while this
    /// says only that we stopped waiting.
    struct WriteTimedOut: Error, CustomStringConvertible {
        let after: Duration
        var description: String { "no answer within \(after)" }
    }

    /// `writeData` is completion-based, so it is bridged with a continuation —
    /// with the one classic trap guarded rather than commented: a completion
    /// invoked twice would resume twice and crash the measurement.
    ///
    /// **The deadline is enforced here and cannot be honoured by PhotoKit.**
    /// `writeData` returns no request id and `PHAssetResourceManager` has no
    /// cancel for it, so a timed-out write keeps running in the daemon and may
    /// still deliver its file. All the deadline buys is our own control back —
    /// which is the whole of what the queue filler will need from it, and the
    /// reason the caller writes the retry to a fresh path.
    private static func write(
        _ resource: PHAssetResource, to url: URL, allowingNetwork network: Bool,
        within deadline: Duration, reporting label: String?
    ) async throws {
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = network
        if let label {
            let reporter = ProgressReporter(label: label)
            let progress: @Sendable (Double) -> Void = { fraction in reporter.report(fraction) }
            options.progressHandler = progress
        }

        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, any Error>) in
            let once = ResumeOnce(continuation)
            let deadlineTask = Task {
                try? await Task.sleep(for: deadline)
                once.finish(WriteTimedOut(after: deadline))
            }
            // Annotated for the same reason as the `requestData` handlers, even
            // though this one has never tripped the assertion. Which of these
            // blocks the importer marks sendable is not a thing to depend on.
            let completed: @Sendable ((any Error)?) -> Void = { error in
                deadlineTask.cancel()
                once.finish(error)
            }
            PHAssetResourceManager.default().writeData(
                for: resource, toFile: url, options: options, completionHandler: completed)
        }
    }

    /// A download that takes five minutes with no output looks identical to a
    /// hang, and that ambiguity cost an afternoon here before the handler
    /// existed. Deciles only: `progressHandler` fires far too often to print.
    private final class ProgressReporter: @unchecked Sendable {
        private let lock = NSLock()
        private let label: String
        private var reported = 0

        init(label: String) { self.label = label }

        func report(_ fraction: Double) {
            let decile = Int(fraction * 10)
            lock.lock()
            let worth = decile > reported
            if worth { reported = decile }
            lock.unlock()
            guard worth, decile < 10 else { return }
            Console.event("    \(label)  \(decile * 10)%")
        }
    }

    /// The leading field of a local identifier. The `/L0/001` tail is the same
    /// on every one of them and a full identifier does not fit beside anything.
    private static func shortIdentifier(_ asset: PHAsset) -> String {
        String(asset.localIdentifier.prefix(8))
    }

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

    // MARK: - Measuring what was written

    private static func pixelSize(of url: URL) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? Int,
            let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return (width, height)
    }

    // MARK: - Fetch options

    /// Videos are excluded at the fetch, by predicate, so they never enter the
    /// row set at all — which is what the provider will do for the same reason.
    private static func imagesOnly() -> PHFetchOptions {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(
            format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        return options
    }

    // MARK: - Names

    private static func name(_ status: PHAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: "not determined"
        case .restricted: "restricted"
        case .denied: "denied"
        case .authorized: "authorized"
        case .limited: "limited"
        @unknown default: "unknown (\(status.rawValue))"
        }
    }

    private static func name(_ subtype: PHAssetCollectionSubtype) -> String {
        switch subtype {
        case .albumRegular: "albumRegular"
        case .albumSyncedEvent: "albumSyncedEvent"
        case .albumSyncedFaces: "albumSyncedFaces"
        case .albumSyncedAlbum: "albumSyncedAlbum"
        case .albumImported: "albumImported"
        case .albumMyPhotoStream: "albumMyPhotoStream"
        case .albumCloudShared: "albumCloudShared"
        case .smartAlbumGeneric: "smartAlbumGeneric"
        case .smartAlbumPanoramas: "smartAlbumPanoramas"
        case .smartAlbumVideos: "smartAlbumVideos"
        case .smartAlbumFavorites: "smartAlbumFavorites"
        case .smartAlbumTimelapses: "smartAlbumTimelapses"
        case .smartAlbumAllHidden: "smartAlbumAllHidden"
        case .smartAlbumRecentlyAdded: "smartAlbumRecentlyAdded"
        case .smartAlbumBursts: "smartAlbumBursts"
        case .smartAlbumSlomoVideos: "smartAlbumSlomoVideos"
        case .smartAlbumUserLibrary: "smartAlbumUserLibrary"
        case .smartAlbumSelfPortraits: "smartAlbumSelfPortraits"
        case .smartAlbumScreenshots: "smartAlbumScreenshots"
        case .smartAlbumDepthEffect: "smartAlbumDepthEffect"
        case .smartAlbumLivePhotos: "smartAlbumLivePhotos"
        case .smartAlbumAnimated: "smartAlbumAnimated"
        case .smartAlbumLongExposures: "smartAlbumLongExposures"
        case .smartAlbumUnableToUpload: "smartAlbumUnableToUpload"
        case .smartAlbumRAW: "smartAlbumRAW"
        case .smartAlbumCinematic: "smartAlbumCinematic"
        default: "subtype \(subtype.rawValue)"
        }
    }

    private static func name(_ type: PHAssetResourceType) -> String {
        switch type {
        case .photo: ".photo"
        case .video: ".video"
        case .audio: ".audio"
        case .alternatePhoto: ".alternatePhoto"
        case .fullSizePhoto: ".fullSizePhoto"
        case .fullSizeVideo: ".fullSizeVideo"
        case .adjustmentData: ".adjustmentData"
        case .adjustmentBasePhoto: ".adjustmentBasePhoto"
        case .pairedVideo: ".pairedVideo"
        case .fullSizePairedVideo: ".fullSizePairedVideo"
        case .adjustmentBasePairedVideo: ".adjustmentBasePairedVideo"
        case .adjustmentBaseVideo: ".adjustmentBaseVideo"
        case .photoProxy: ".photoProxy"
        default: "type \(type.rawValue)"
        }
    }

    // MARK: - Formatting

    private static func seconds(_ duration: Duration) -> Double {
        let (whole, attoseconds) = duration.components
        return Double(whole) + Double(attoseconds) / 1e18
    }

    private static func milliseconds(_ duration: Duration) -> String {
        "\(Library.number(seconds(duration) * 1000, places: 1))ms"
    }

    /// A change, with its direction, because a footprint that came back down
    /// is the answer we are hoping for and "12 MB" cannot say that.
    private static func signed(_ change: Int64) -> String {
        change == 0 ? "0" : (change < 0 ? "−" : "+") + Library.bytes(abs(change))
    }

    private static func delta(_ before: UInt64?, _ after: UInt64?) -> String {
        guard let before, let after else { return "unavailable" }
        let change = Int64(bitPattern: after) - Int64(bitPattern: before)
        let sign = change < 0 ? "−" : "+"
        return "\(Library.bytes(Int64(after)))  (\(sign)\(Library.bytes(abs(change))))"
    }
}

// MARK: - Footprint

/// `phys_footprint` from `task_vm_info`, which is what Instruments and jetsam
/// both mean by a process's memory.
enum Footprint {
    static func current() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return info.phys_footprint
    }
}

/// The peak, sampled rather than inferred.
///
/// The claim that justifies `PHAssetResourceManager` over
/// `requestImageDataAndOrientation` is that it streams to a file and never holds
/// the resource in our address space. That is the reason a 100 MB ProRAW is not
/// a 100 MB `Data` in the agent, and it has never been tested here. What we want
/// to see is a peak that does not track the largest file pulled. What would be
/// alarming is one that rises with file size, which would mean the write is
/// buffered somewhere and the memory discipline the scanner was built around
/// does not survive this provider.
///
/// Sampling on a timer rather than at named points, because the write suspends
/// the caller and a peak that happens inside it would otherwise be invisible.
actor FootprintSampler {
    private var peak: UInt64 = 0
    private var window: UInt64 = 0
    private var running = false

    func begin() {
        guard !running else { return }
        running = true
        peak = max(peak, Footprint.current() ?? 0)
        Task { await self.poll() }
    }

    private func poll() async {
        while running {
            let now = Footprint.current() ?? 0
            peak = max(peak, now)
            window = max(window, now)
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    func mark() {
        peak = max(peak, Footprint.current() ?? 0)
    }

    /// Starts a fresh window and returns the reading it starts from.
    ///
    /// The poll alone is not enough: a local read can finish inside 20 ms and
    /// take no sample at all, so both ends are read directly and the poll only
    /// catches what happens between them.
    func openWindow() -> UInt64 {
        let now = Footprint.current() ?? 0
        window = now
        peak = max(peak, now)
        return now
    }

    /// The highest reading seen since `openWindow`, both ends included.
    func closeWindow() -> UInt64 {
        let now = Footprint.current() ?? 0
        window = max(window, now)
        peak = max(peak, now)
        return window
    }

    @discardableResult
    func end() -> UInt64 {
        running = false
        peak = max(peak, Footprint.current() ?? 0)
        return peak
    }
}

// MARK: - Column padding

extension String {
    fileprivate func paddedRight(_ width: Int) -> String {
        count >= width ? self + " " : self + String(repeating: " ", count: width - count)
    }

    fileprivate func paddedLeft(_ width: Int) -> String {
        count >= width ? self : String(repeating: " ", count: width - count) + self
    }
}
