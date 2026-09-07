import Foundation
import PhotoGoRoundAgentAPI

/// A photo library that always answers, even when the real one will not.
///
/// **`SystemPhotoLibrary` gives every PhotoKit call a thread it is allowed to
/// block. This decides how long anybody waits on one.** The split is the same
/// one that file states about itself: translation lives there, rules live where
/// a test can reach them — and a fake that hangs is the only way to exercise
/// this without somebody's real photographs and a wedged `photolibraryd`.
///
/// **What expires is never a fact about an album.** Every call below can answer
/// *no* — `nil`, `[]`, `false` — and every one of those means the library
/// looked. A timeout means it did not look, and it throws
/// `PhotoLibraryError.noAnswer` so no caller can mistake the two. That
/// distinction is the whole reason this type exists: `title(ofCollection:)`
/// answering `nil` is what `availability` reads as `.missing`, which is what
/// offers a person the button that removes an album and its photographs. A
/// library that is slow, rebuilding, or migrating to a spinning disk must not be
/// able to reach that button.
public struct BoundedPhotoLibrary: PhotoLibrary {
    private let library: any PhotoLibrary
    private let metadata: Duration
    private let fetch: Duration
    private let consent: Duration

    /// Asking the library about itself: what it holds, what something is called,
    /// whether an asset is there.
    ///
    /// **Ten seconds against calls measured in milliseconds.** Listing 439
    /// collections is a handful of milliseconds and the most expensive of these,
    /// `imageCount`, is ~78 ms; the bound is not a performance budget but the
    /// line past which the daemon is not answering rather than being slow. It
    /// sits under the app's own ten-second read bound so the agent gets to say
    /// *the library did not answer* rather than going silent and making the app
    /// guess.
    public static let metadataLimit = Duration.seconds(10)

    /// Copying a photograph's bytes out, which may cross the network.
    ///
    /// The existing number, unchanged: `CacheSettings.libraryFetchLimit`, which
    /// is the same sixty seconds a file fetch gets and is documented there.
    public static let fetchLimit = CacheSettings.libraryFetchLimit

    /// Raising the consent prompt, which waits on a person rather than a daemon.
    ///
    /// **Two minutes, because somebody has to read a dialog and decide.** Any of
    /// the bounds above would fire while the TCC prompt was still on screen and
    /// report a failure against a library behaving perfectly. It is bounded all
    /// the same: a prompt nobody ever answers must not hold a request for the
    /// life of the agent.
    public static let consentLimit = Duration.seconds(120)

    public init(
        _ library: any PhotoLibrary,
        metadata: Duration = BoundedPhotoLibrary.metadataLimit,
        fetch: Duration = BoundedPhotoLibrary.fetchLimit,
        consent: Duration = BoundedPhotoLibrary.consentLimit
    ) {
        self.library = library
        self.metadata = metadata
        self.fetch = fetch
        self.consent = consent
    }

    /// Runs one call against its bound, and turns an expiry into the one error
    /// that means *the library did not answer*.
    ///
    /// `what` is the call's name, so a log line and a source's
    /// `unavailableReason` say which question went unanswered rather than only
    /// that one did.
    private func bounded<T: Sendable>(
        _ what: String, within limit: Duration, _ work: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        do {
            return try await Deadline.run(within: limit, work)
        } catch let expired as Deadline.Expired {
            Log.photos.error(
                "library did not answer \(what, privacy: .public) within \(expired.limit.totalSeconds, privacy: .public)s"
            )
            throw PhotoLibraryError.noAnswer(what: what, within: expired.limit)
        }
    }

    // MARK: - Authorization

    public var authorization: LibraryAuthorization {
        get async throws {
            try await bounded("authorization", within: metadata) { [library] in
                try await library.authorization
            }
        }
    }

    /// **The one call whose bound is about a person.** It raises a TCC prompt
    /// and does not return until somebody clicks; a metadata bound here would
    /// report a failure while the dialog was still up.
    ///
    /// It does not throw, because the protocol's own answer already covers
    /// every outcome a caller acts on: a prompt that never came back is
    /// `notDetermined`, which is exactly what it was before anybody was asked.
    public func requestAuthorization() async -> LibraryAuthorization {
        do {
            return try await bounded("requestAuthorization", within: consent) { [library] in
                await library.requestAuthorization()
            }
        } catch {
            return .notDetermined
        }
    }

    // MARK: - Collections

    public func collections() async throws -> [LibraryCollection] {
        try await bounded("collections", within: metadata) { [library] in
            try await library.collections()
        }
    }

    public func folderPaths() async throws -> [String: [String]] {
        try await bounded("folderPaths", within: metadata) { [library] in
            try await library.folderPaths()
        }
    }

    public func imageCount(ofCollection identifier: String) async throws -> Int? {
        try await bounded("imageCount", within: metadata) { [library] in
            try await library.imageCount(ofCollection: identifier)
        }
    }

    public func title(ofCollection identifier: String) async throws -> String? {
        try await bounded("title", within: metadata) { [library] in
            try await library.title(ofCollection: identifier)
        }
    }

    // MARK: - Assets

    public func assetExists(_ identifier: String) async throws -> Bool {
        try await bounded("assetExists", within: metadata) { [library] in
            try await library.assetExists(identifier)
        }
    }

    public func resources(ofAsset identifier: String) async throws -> [LibraryResource] {
        try await bounded("resources", within: metadata) { [library] in
            try await library.resources(ofAsset: identifier)
        }
    }

    /// **Bounded per asset, on the gap rather than on the total.**
    ///
    /// A hundred-thousand-asset album takes as long as it takes and that is not
    /// a fault; a library that stops answering part way through one is. So the
    /// clock restarts every time an asset arrives, and what expires is silence.
    ///
    /// **The sink is not `Sendable`, which is the whole difficulty.** It cannot
    /// cross into the task `Deadline` needs, so the walk cannot simply be
    /// wrapped. What crosses instead is a handoff actor: the walk runs in its
    /// own task and offers one asset at a time, this side takes them under the
    /// bound and calls the sink here, on the caller's isolation, exactly as
    /// before.
    @discardableResult
    public func enumerateImages(
        inCollection identifier: String,
        _ body: (LibraryAsset) async throws -> Void
    ) async throws -> Bool {
        let handoff = Handoff()
        let walking = Task { [library] in
            do {
                let resolved = try await library.enumerateImages(inCollection: identifier) {
                    await handoff.put($0)
                }
                await handoff.finish(.success(resolved))
            } catch {
                await handoff.finish(.failure(error))
            }
        }
        // **Both halves matter.** Cancelling asks the walk to stop; releasing is
        // what unparks a producer waiting for an asset nobody will ever take,
        // which is the shape a leak would otherwise have on every timeout.
        defer {
            walking.cancel()
            Task { await handoff.release() }
        }

        while true {
            let next = try await bounded("enumerateImages", within: metadata) {
                await handoff.take()
            }
            guard let next else { break }
            try await body(next)
        }
        return try await handoff.outcome()
    }

    /// One asset at a time, from the walk to the sink, with real backpressure.
    ///
    /// **`AsyncStream` cannot do this job.** Its buffering policies either drop
    /// values or grow without bound — and dropping one means losing a
    /// photograph, while buffering without bound materialises the album, which
    /// is the single thing enumeration exists not to do. So the walk waits until
    /// what it offered has been taken.
    ///
    /// An actor rather than a lock: the two continuations are the state, and
    /// having them under isolation is what makes "resumed exactly once" a thing
    /// the compiler helps with rather than a thing to be careful about.
    private actor Handoff {
        private var slot: LibraryAsset?
        private var waitingConsumer: CheckedContinuation<LibraryAsset?, Never>?
        private var waitingProducer: CheckedContinuation<Void, Never>?
        private var ended: Result<Bool, any Error>?
        private var released = false

        /// Offers one asset, and returns once somebody has taken it.
        func put(_ asset: LibraryAsset) async {
            guard !released else { return }
            if let consumer = waitingConsumer {
                waitingConsumer = nil
                consumer.resume(returning: asset)
                return
            }
            slot = asset
            await withCheckedContinuation { waitingProducer = $0 }
        }

        /// The next asset, or nil when the walk is over.
        func take() async -> LibraryAsset? {
            if let asset = slot {
                slot = nil
                waitingProducer?.resume()
                waitingProducer = nil
                return asset
            }
            if ended != nil { return nil }
            return await withCheckedContinuation { waitingConsumer = $0 }
        }

        /// The walk finished, one way or the other.
        func finish(_ result: Result<Bool, any Error>) {
            ended = result
            waitingConsumer?.resume(returning: nil)
            waitingConsumer = nil
        }

        /// Nobody is listening any more. Unparks a producer that would otherwise
        /// wait for ever on an asset no one will take.
        func release() {
            released = true
            waitingProducer?.resume()
            waitingProducer = nil
        }

        /// Whether the collection resolved, or whatever the walk threw.
        ///
        /// Reached only when `take` answered nil, which happens only after
        /// `finish` — so an outcome is always there by now.
        func outcome() throws -> Bool {
            guard let ended else {
                throw PhotoLibraryError.noAnswer(what: "enumerateImages", within: .zero)
            }
            return try ended.get()
        }
    }

    // MARK: - Materialize

    public func write(
        _ resource: LibraryResource, ofAsset identifier: String, to destination: URL
    ) async throws -> Int64 {
        try await bounded("write", within: fetch) { [library] in
            try await library.write(resource, ofAsset: identifier, to: destination)
        }
    }
}
