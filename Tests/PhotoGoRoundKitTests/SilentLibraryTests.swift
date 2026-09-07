import Foundation
import Testing

@testable import PhotoGoRoundAgentAPI
@testable import PhotoGoRoundKit

/// A photo library that will not answer.
///
/// **The rule under test is one sentence: a timeout is never a fact about an
/// album.** Every call in the seam can answer *no* — `nil`, `[]`, `false` — and
/// each of those means the library looked. Silence means it did not look, and
/// the difference decides whether somebody keeps their photographs.
///
/// Written 2026-09-07, against a machine migrating a large library onto a
/// spinning disk. A library that is slow, rebuilding, or wedged is exactly the
/// one most likely to be asked about an album — and, before this, most likely to
/// be believed when it said nothing.
@Suite("A photo library that will not answer")
struct SilentLibraryTests {

    /// A library that hangs on everything, so the bound is what ends the wait.
    private struct Hanging: PhotoLibrary {
        var authorization: LibraryAuthorization {
            get async throws { try await Self.never() }
        }
        func requestAuthorization() async -> LibraryAuthorization {
            (try? await Self.never()) ?? .denied
        }
        func collections() async throws -> [LibraryCollection] { try await Self.never() }
        func folderPaths() async throws -> [String: [String]] { try await Self.never() }
        func imageCount(ofCollection identifier: String) async throws -> Int? {
            try await Self.never()
        }
        func title(ofCollection identifier: String) async throws -> String? {
            try await Self.never()
        }
        func assetExists(_ identifier: String) async throws -> Bool { try await Self.never() }
        func resources(ofAsset identifier: String) async throws -> [LibraryResource] {
            try await Self.never()
        }
        @discardableResult
        func enumerateImages(
            inCollection identifier: String, _ body: (LibraryAsset) async throws -> Void
        ) async throws -> Bool {
            try await Self.never()
        }
        func write(
            _ resource: LibraryResource, ofAsset identifier: String, to destination: URL
        ) async throws -> Int64 {
            try await Self.never()
        }

        /// Far longer than any bound a test sets, so the deadline always wins.
        private static func never<T>() async throws -> T {
            try await Task.sleep(for: .seconds(300))
            fatalError("unreachable")
        }
    }

    private static func bounded(_ library: any PhotoLibrary) -> BoundedPhotoLibrary {
        BoundedPhotoLibrary(
            library, metadata: .milliseconds(50), fetch: .milliseconds(50),
            consent: .milliseconds(50))
    }

    private static func silentProvider() -> PhotosCollectionSourceProvider {
        PhotosCollectionSourceProvider(library: bounded(Hanging()))
    }

    // MARK: - The bound itself

    @Test("A call that never answers throws noAnswer rather than waiting")
    func theBoundFires() async {
        let library = Self.bounded(Hanging())
        await #expect(throws: PhotoLibraryError.self) { try await library.title(ofCollection: "A") }
    }

    /// The error names the call, so a log line and a source's reason say which
    /// question went unanswered rather than only that one did.
    @Test("The failure says which question went unanswered")
    func theFailureNamesItsCall() async {
        do {
            _ = try await Self.bounded(Hanging()).collections()
            Issue.record("expected a failure")
        } catch let error as PhotoLibraryError {
            guard case .noAnswer(let what, _) = error else {
                Issue.record("expected noAnswer, got \(error)")
                return
            }
            #expect(what == "collections")
            #expect(error.isNoAnswer)
        } catch {
            Issue.record("expected PhotoLibraryError, got \(error)")
        }
    }

    @Test("A library that answers is not reported as silent")
    func aWorkingLibraryIsUntouched() async throws {
        let library = Self.bounded(FakePhotoLibrary(titles: ["A": "Sunsets"]))
        #expect(try await library.title(ofCollection: "A") == "Sunsets")
        // Still `nil` for a collection that genuinely is not there — the answer
        // this whole change exists to keep distinguishable from silence.
        #expect(try await library.title(ofCollection: "GONE") == nil)
    }

    // MARK: - What silence must never become

    /// **The one that costs photographs.** `.missing` is what puts *Remove
    /// missing albums* in front of somebody — a button that removes the source,
    /// its photograph rows, and their cached bytes. A library that is merely
    /// slow must not be able to reach it.
    @Test("A silent library is offline, never missing")
    func silenceIsNeverMissing() async {
        let answer = await Self.silentProvider().availability(of: photosSource(locator: "A"))

        guard case .offline = answer else {
            Issue.record("a silent library answered \(answer) — only .offline is safe here")
            return
        }
    }

    /// The same fact from the other side: a library that *does* answer, and says
    /// the album is not there, still reports missing. The fix must not have
    /// bought safety by disabling the feature.
    @Test("A library that answers still reports a genuinely missing album")
    func aRealMissingAlbumStillReportsMissing() async {
        let library = Self.bounded(FakePhotoLibrary(titles: ["OTHER": "Something else"]))
        let provider = PhotosCollectionSourceProvider(library: library)

        let answer = await provider.availability(of: photosSource(locator: "GONE"))

        guard case .missing = answer else {
            Issue.record("expected missing, got \(answer)")
            return
        }
    }

    /// `.absent` deletes a photograph and the bytes behind it. It is only ever
    /// said when the library was readable, the album resolved, and the asset was
    /// looked for and not found.
    @Test("A silent library says unknown about a photograph, never absent")
    func silenceIsNeverAbsent() async {
        let answer = await Self.silentProvider()
            .existence(of: "ASSET-1", in: photosSource(locator: "A"))

        guard case .unknown = answer else {
            Issue.record("a silent library answered \(answer) — only .unknown is safe here")
            return
        }
    }

    /// A library that will not answer has said nothing about the album's
    /// contents. Reading that as an empty enumeration would delete every row the
    /// source has.
    @Test("A silent library is unavailable, not an empty album")
    func silenceIsNeverAnEmptyAlbum() async throws {
        var received = 0
        let reachability = try await Self.silentProvider()
            .enumerate(photosSource(locator: "A")) { _ in received += 1 }

        #expect(received == 0)
        guard case .unavailable = reachability else {
            Issue.record("expected unavailable, got \(reachability)")
            return
        }
    }

    /// Empty means *nothing to reconnect to*, which disables a button. Guessing
    /// would enable the wrong one.
    @Test("A silent library offers no successors and no name of its own")
    func silenceOffersNothing() async {
        let provider = Self.silentProvider()
        let source = photosSource(locator: "A")

        #expect(await provider.successors(of: source).isEmpty)
        #expect(await provider.title(of: source) == nil)
        #expect(await provider.describe(source) == nil)
    }

    // MARK: - Walking an album

    /// A library that hands over some assets and then stops.
    ///
    /// **The realistic shape on a library being migrated**: it answers, it is
    /// working, and part way through a large album it stops coming back. A
    /// bound that only looked at the call as a whole would never fire on this,
    /// and one that only looked between assets would never be reached.
    private struct StallsPartWay: PhotoLibrary {
        let deliver: Int

        @discardableResult
        func enumerateImages(
            inCollection identifier: String, _ body: (LibraryAsset) async throws -> Void
        ) async throws -> Bool {
            for index in 0..<deliver {
                try await body(LibraryAsset(identifier: "ASSET-\(index)"))
            }
            try await Task.sleep(for: .seconds(300))
            return true
        }

        var authorization: LibraryAuthorization { get async throws { .authorized } }
        func requestAuthorization() async -> LibraryAuthorization { .authorized }
        func collections() async throws -> [LibraryCollection] { [] }
        func folderPaths() async throws -> [String: [String]] { [:] }
        func imageCount(ofCollection identifier: String) async throws -> Int? { nil }
        func title(ofCollection identifier: String) async throws -> String? { "Album" }
        func assetExists(_ identifier: String) async throws -> Bool { true }
        func resources(ofAsset identifier: String) async throws -> [LibraryResource] { [] }
        func write(
            _ resource: LibraryResource, ofAsset identifier: String, to destination: URL
        ) async throws -> Int64 { 0 }
    }

    /// **Everything is delivered, exactly once, in order.** The walk and the
    /// sink are in different tasks now, handing assets over one at a time — so
    /// the first thing to prove is that nothing is dropped, duplicated, or
    /// reordered by the machinery that made the bound possible.
    @Test("A walk that works delivers every asset, once, in order")
    func theHandoffDeliversEverything() async throws {
        let assets = (0..<250).map { LibraryAsset(identifier: "ASSET-\($0)") }
        let library = Self.bounded(
            FakePhotoLibrary(titles: ["A": "Big"], assets: ["A": assets]))

        var seen: [String] = []
        let resolved = try await library.enumerateImages(inCollection: "A") {
            seen.append($0.identifier)
        }

        #expect(resolved)
        #expect(seen == assets.map(\.identifier))
    }

    /// A collection that does not resolve is still `false` rather than a throw —
    /// the library answered, and the answer was *no such album*.
    @Test("A collection that does not resolve is answered, not thrown")
    func anUnresolvedCollectionIsAnAnswer() async throws {
        let library = Self.bounded(FakePhotoLibrary(titles: ["A": "Sunsets"]))
        #expect(try await library.enumerateImages(inCollection: "GONE") { _ in } == false)
    }

    /// **The clock is on the gap, not the total.** A large album is allowed to
    /// take as long as it takes; a library that goes quiet in the middle of one
    /// is not.
    @Test("A walk that stalls part way is bounded, and keeps what it received")
    func aStalledWalkIsBounded() async throws {
        let library = Self.bounded(StallsPartWay(deliver: 3))

        var seen: [String] = []
        await #expect(throws: PhotoLibraryError.self) {
            try await library.enumerateImages(inCollection: "A") { seen.append($0.identifier) }
        }

        // What arrived before the silence arrived properly.
        #expect(seen == ["ASSET-0", "ASSET-1", "ASSET-2"])
    }

    /// The provider turns that into an unavailable source rather than an empty
    /// one — the same rule as a walk that never started, and for the same
    /// reason: a partial answer is not a statement that the rest is gone.
    @Test("A stalled walk leaves the source unavailable, not emptied")
    func aStalledWalkDoesNotEmptyTheSource() async throws {
        let provider = PhotosCollectionSourceProvider(
            library: Self.bounded(StallsPartWay(deliver: 3)))

        var received = 0
        let reachability = try await provider
            .enumerate(photosSource(locator: "A")) { _ in received += 1 }

        #expect(received == 3)
        guard case .unavailable = reachability else {
            Issue.record("expected unavailable, got \(reachability)")
            return
        }
    }

    // MARK: - The catalog

    /// **The listing it holds is the last one that worked.** Replacing it with
    /// the empty array a failed fetch used to produce would say *this library
    /// has no collections* about a library full of photographs, and would drop
    /// every count paid for so far.
    @Test("A listing that fails leaves the last good one in place")
    func aFailedListingKeepsWhatItHad() async throws {
        let library = FakePhotoLibrary(titles: ["A": "Sunsets", "B": "Kids"])
        let catalog = PhotosCollectionCatalog(library: library)
        _ = try await catalog.sections()
        await catalog.countEverything()
        let counted = await catalog.progress()
        #expect(counted.counted == 2)

        // The library stops answering, and the picker asks again.
        let silent = PhotosCollectionCatalog(library: Self.bounded(Hanging()))
        await #expect(throws: PhotoLibraryError.self) { try await silent.sections() }

        // The one that had answers still has them.
        #expect(await catalog.progress() == counted)
        #expect(try await catalog.sections().count > 0)
    }

    /// **Recording zero would be a lie that outlives the agent** — counts do not
    /// expire, so an album holding thirty thousand photographs would read as
    /// empty for the rest of the session.
    @Test("A count that goes unanswered is not recorded as zero")
    func anUnansweredCountIsNotZero() async throws {
        let library = FakePhotoLibrary(
            titles: ["A": "Sunsets"], assets: ["A": [LibraryAsset(identifier: "1")]],
            unanswered: [.imageCount])
        let catalog = PhotosCollectionCatalog(library: library)

        _ = try await catalog.sections()
        await catalog.countEverything()

        // Nothing counted, and nothing claimed.
        #expect(await catalog.progress() == (counted: 0, total: 1))
        #expect(try await catalog.sections().first?.collections.first?.count == nil)
    }

    /// A pass that neither records nor stops would ask the same album for ever.
    @Test("A library that stops answering ends the counting pass")
    func countingStopsRatherThanSpinning() async throws {
        let library = FakePhotoLibrary(
            titles: ["A": "One", "B": "Two", "C": "Three"], unanswered: [.imageCount])
        let catalog = PhotosCollectionCatalog(library: library)
        _ = try await catalog.sections()

        // Returns at all, which is the assertion: an unbounded retry would hang
        // the suite here rather than fail it.
        await catalog.countEverything()
        #expect(await catalog.progress() == (counted: 0, total: 3))
    }

    /// Folders only disambiguate two albums of the same name. A listing without
    /// them is worth far more than no listing.
    @Test("A folder walk that fails still yields the collections")
    func foldersDegradeRatherThanFail() async throws {
        let library = FakePhotoLibrary(
            titles: ["A": "Sunsets"], folders: ["A": ["Trips"]], unanswered: [.folderPaths])
        let catalog = PhotosCollectionCatalog(library: library)

        let groups = try await catalog.sections()

        let album = groups.flatMap(\.collections).first { $0.identifier == "A" }
        #expect(album?.title == "Sunsets")
        #expect(album?.folders.isEmpty == true)
    }
}
