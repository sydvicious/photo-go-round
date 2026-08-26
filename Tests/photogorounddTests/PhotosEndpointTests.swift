import Foundation
import Testing

@testable import PhotoGoRoundAgentAPI
@testable import PhotoGoRoundKit
@testable import photogoroundd

/// The one route a client cannot do without: what is in the photo library.
///
/// **Driven through `route`**, because everything this endpoint decides only
/// exists at the wiring — that authorization travels in the body rather than in
/// a status code, that a refusal is still a 200, that names arrive before
/// counts. The catalog beneath it has its own tests and every one of them
/// passed while this could still have answered 404.
@Suite("Photos endpoint")
struct PhotosEndpointTests {

    /// A library that is not one. Only the two collection calls do anything —
    /// nothing here materializes a photograph.
    private struct Library: PhotoLibrary {
        var authorizationValue: LibraryAuthorization = .authorized
        /// What asking would yield. Nil means asking changes nothing, which is
        /// what happens for anybody who has already decided.
        var grantedOnRequest: LibraryAuthorization?
        var collectionList: [LibraryCollection] = []
        var counts: [String: Int] = [:]

        var authorization: LibraryAuthorization { get async { authorizationValue } }
        func requestAuthorization() async -> LibraryAuthorization {
            grantedOnRequest ?? authorizationValue
        }
        var folderTree: [String: [String]] = [:]

        func collections() async -> [LibraryCollection] { collectionList }
        func folderPaths() async -> [String: [String]] { folderTree }
        func imageCount(ofCollection identifier: String) async -> Int? { counts[identifier] }
        func title(ofCollection identifier: String) async -> String? {
            collectionList.first { $0.identifier == identifier }?.title
        }

        @discardableResult
        func enumerateImages(
            inCollection identifier: String, _ body: (LibraryAsset) async throws -> Void
        ) async throws -> Bool { false }
        func assetExists(_ identifier: String) async -> Bool { false }
        func resources(ofAsset identifier: String) async -> [LibraryResource] { [] }
        func write(
            _ resource: LibraryResource, ofAsset identifier: String, to destination: URL
        ) async throws -> Int64 { 0 }
    }

    private static func collection(
        _ id: String, _ title: String, _ kind: LibraryCollectionKind
    ) -> LibraryCollection {
        LibraryCollection(identifier: id, title: title, kind: kind)
    }

    private static let stocked = Library(
        collectionList: [
            collection("A", "Holiday", .userAlbum),
            collection("B", "Live Photos", .mediaType),
            collection("C", "Family", .sharedAlbum),
        ],
        counts: ["A": 12, "B": 340, "C": 7])

    private static func endpoint(_ library: Library) -> PhotosEndpoint {
        PhotosEndpoint(
            catalog: PhotosCollectionCatalog(library: library), library: library)
    }

    private static func get(
        _ path: String = PhotosEndpoint.albumsPath
    ) -> HTTPListener.Request {
        HTTPListener.Request(
            method: "GET", path: path, query: [:], headers: [:], receivedAt: .now)
    }

    private func wire(_ response: HTTPListener.Response) throws -> PhotosEndpoint.Wire {
        guard case .data(let data) = response.body else {
            Issue.record("the response carried no body")
            throw CancellationError()
        }
        return try JSONDecoder().decode(PhotosEndpoint.Wire.self, from: data)
    }

    // MARK: - Claiming

    @Test("It owns the whole photos prefix, so a mistyped path under it is not a picture request")
    func claimsThePrefix() {
        #expect(PhotosEndpoint.claims("/v2/photos"))
        #expect(PhotosEndpoint.claims("/v2/photos/albums"))
        #expect(PhotosEndpoint.claims("/v2/photos/nonsense"))
        #expect(!PhotosEndpoint.claims("/v2/sources"))
        #expect(!PhotosEndpoint.claims("/v1/picture"))
        // The prefix is a path component, not a string prefix.
        #expect(!PhotosEndpoint.claims("/v2/photosomething"))
    }

    /// **The router asks the sources first.** If `SourceEndpoint` ever claimed
    /// anything under `/v2/photos`, these routes would be unreachable and the
    /// only symptom would be a 404 from an endpoint that never saw the request.
    @Test("The source endpoint does not claim the photos routes out from under it")
    func sourcesDoNotShadowPhotos() {
        #expect(!SourceEndpoint.claims(PhotosEndpoint.albumsPath))
        #expect(!SourceEndpoint.claims("/v2/photos"))
    }

    // MARK: - Listing

    @Test("The albums arrive grouped, in Photos' section order")
    func albumsAreGrouped() async throws {
        let response = await Self.endpoint(Self.stocked).route(Self.get())
        #expect(response.status == 200)

        let body = try wire(response)
        #expect(body.authorization == "authorized")
        #expect(body.sections.map(\.section) == ["albums", "sharing", "mediaTypes"])
        #expect(body.sections.map(\.title) == ["Albums", "Sharing", "Media Types"])
        #expect(body.sections.first?.collections.map(\.title) == ["Holiday"])
    }

    @Test("A collection carries the identifier a source would be added with")
    func identifiersAreCarried() async throws {
        let body = try wire(await Self.endpoint(Self.stocked).route(Self.get()))
        let holiday = body.sections.flatMap(\.collections).first { $0.title == "Holiday" }
        #expect(holiday?.identifier == "A")
        #expect(holiday?.kind == "userAlbum")
    }

    /// The whole reason listing and counting are separate: 34 seconds for a real
    /// library, and nobody waits for that to see the names.
    @Test("Names come back before any counts do")
    func namesBeforeCounts() async throws {
        let body = try wire(await Self.endpoint(Self.stocked).route(Self.get()))
        #expect(body.sections.flatMap(\.collections).allSatisfy { $0.count == nil })
        #expect(body.counted == 0)
        #expect(body.total == 3)
    }

    @Test("Counts appear once the background pass has run, and say so in the progress")
    func countsAppearAfterwards() async throws {
        let catalog = PhotosCollectionCatalog(library: Self.stocked)
        let endpoint = PhotosEndpoint(catalog: catalog, library: Self.stocked)

        _ = await endpoint.route(Self.get())
        await catalog.countEverything()
        let body = try wire(await endpoint.route(Self.get()))

        let counts = Dictionary(
            uniqueKeysWithValues: body.sections.flatMap(\.collections).map { ($0.title, $0.count) })
        #expect(counts["Holiday"] == 12)
        #expect(counts["Live Photos"] == 340)
        #expect(body.counted == 3)
        #expect(body.total == 3)
    }

    // MARK: - Authorization

    /// **A refusal is a 200, and the reason is in the body.** A client that got
    /// an empty array could not tell "this library has no albums" from "you may
    /// not look at it", and would draw the first over the second.
    @Test(
        "A library we may not read answers with the reason rather than an error",
        arguments: [
            (LibraryAuthorization.denied, "denied"),
            (.notDetermined, "notDetermined"),
            (.restricted, "restricted"),
        ])
    func refusalsCarryTheirReason(state: LibraryAuthorization, name: String) async throws {
        var library = Self.stocked
        library.authorizationValue = state

        let response = await Self.endpoint(library).route(Self.get())
        #expect(response.status == 200)

        let body = try wire(response)
        #expect(body.authorization == name)
        #expect(body.sections.isEmpty)
        #expect(body.total == 0)
    }

    /// Less of the library is still some of it. Treating it as a refusal would
    /// show nothing to somebody who has granted something.
    @Test("Limited access is readable")
    func limitedIsReadable() async throws {
        var library = Self.stocked
        library.authorizationValue = .limited

        let body = try wire(await Self.endpoint(library).route(Self.get()))

        #expect(body.authorization == "limited")
        #expect(body.sections.isEmpty == false)
    }

    @Test("An empty library is an answer, not an absence")
    func anEmptyLibraryAnswers() async throws {
        let body = try wire(await Self.endpoint(Library()).route(Self.get()))

        #expect(body.authorization == "authorized")
        #expect(body.sections.isEmpty)
        #expect(body.total == 0)
    }

    // MARK: - Refusing

    @Test("Only GET is served")
    func onlyGet() async throws {
        let request = HTTPListener.Request(
            method: "POST", path: PhotosEndpoint.albumsPath, query: [:], headers: [:],
            receivedAt: .now)

        let response = await Self.endpoint(Self.stocked).route(request)

        #expect(response.status == 405)
    }

    @Test("An unknown route under the prefix is a 404 from here, not a picture")
    func unknownRouteIsRefusedHere() async throws {
        let response = await Self.endpoint(Self.stocked).route(Self.get("/v2/photos/nonsense"))
        #expect(response.status == 404)
    }

    @Test("The folder path reaches the wire, so a client can tell two same-named albums apart")
    func foldersReachTheWire() async throws {
        var library = Library(
            collectionList: [
                Self.collection("A", "Christmas", .userAlbum),
                Self.collection("B", "Christmas", .userAlbum),
                Self.collection("C", "Holiday", .userAlbum),
            ])
        library.folderTree = ["A": ["Family"], "B": ["Trips", "2024"]]

        let body = try wire(await Self.endpoint(library).route(Self.get()))
        let byIdentifier = Dictionary(
            uniqueKeysWithValues: body.sections.flatMap(\.collections).map {
                ($0.identifier, $0.folders)
            })

        #expect(byIdentifier["A"] == ["Family"])
        #expect(byIdentifier["B"] == ["Trips", "2024"])
        // Top level, and empty rather than absent — a client should not have to
        // treat "no folders" as a missing field.
        #expect(byIdentifier["C"] == [])
    }

    // MARK: - Consent

    private func consent(_ response: HTTPListener.Response) throws -> PhotosEndpoint.Consent {
        guard case .data(let data) = response.body else {
            Issue.record("the response carried no body")
            throw CancellationError()
        }
        return try JSONDecoder().decode(PhotosEndpoint.Consent.self, from: data)
    }

    @Test("Reading the authorization state does not ask for anything")
    func readingConsentAsksNobody() async throws {
        var library = Self.stocked
        library.authorizationValue = .notDetermined
        // If the route asked, this is what would come back — and it must not.
        library.grantedOnRequest = .authorized

        let response = await Self.endpoint(library).route(Self.get(PhotosEndpoint.authorizationPath))

        #expect(response.status == 200)
        #expect(try consent(response).authorization == "notDetermined")
    }

    @Test("Posting raises the prompt and answers with what came back")
    func postingAsks() async throws {
        var library = Self.stocked
        library.authorizationValue = .notDetermined
        library.grantedOnRequest = .authorized

        let request = HTTPListener.Request(
            method: "POST", path: PhotosEndpoint.authorizationPath, query: [:], headers: [:],
            receivedAt: .now)
        let response = await Self.endpoint(library).route(request)

        #expect(response.status == 200)
        #expect(try consent(response).authorization == "authorized")
    }

    /// Somebody who said no is changed in System Settings and nowhere else.
    /// This route must not become a way to ask them again.
    @Test("Asking again after a refusal returns the refusal rather than a second prompt")
    func askingTwiceIsNotASecondPrompt() async throws {
        var library = Self.stocked
        library.authorizationValue = .denied

        let request = HTTPListener.Request(
            method: "POST", path: PhotosEndpoint.authorizationPath, query: [:], headers: [:],
            receivedAt: .now)
        let response = await Self.endpoint(library).route(request)

        #expect(try consent(response).authorization == "denied")
    }

    @Test("The authorization route refuses a verb it does not serve")
    func consentRefusesOtherVerbs() async throws {
        let request = HTTPListener.Request(
            method: "DELETE", path: PhotosEndpoint.authorizationPath, query: [:], headers: [:],
            receivedAt: .now)

        let response = await Self.endpoint(Self.stocked).route(request)

        #expect(response.status == 405)
    }

    @Test("Both routes live under the prefix the endpoint claims")
    func bothRoutesAreClaimed() {
        #expect(PhotosEndpoint.claims(PhotosEndpoint.authorizationPath))
        #expect(PhotosEndpoint.authorizationPath == "/v2/photos/authorization")
        #expect(!SourceEndpoint.claims(PhotosEndpoint.authorizationPath))
    }

    @Test("Every answer is JSON")
    func answersAreJSON() async throws {
        for request in [Self.get(), Self.get("/v2/photos/nonsense")] {
            let response = await Self.endpoint(Self.stocked).route(request)
            #expect(response.headers["Content-Type"] == "application/json; charset=utf-8")
        }
    }
}
