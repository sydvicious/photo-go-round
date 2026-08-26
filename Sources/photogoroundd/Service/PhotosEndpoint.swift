import Console
import Foundation
import PhotoGoRoundAgentAPI
import PhotoGoRoundKit

/// What is in the photo library, for a client that cannot look for itself.
///
/// **v2 only, and that is the whole reason it exists.** A v1 client has no way
/// to draw a Photos collection — it would name an album `040`, the last
/// component of its identifier — so these routes live where a client that
/// understands them can find them and nowhere else.
///
/// The app never links PhotoKit. Only the agent holds the grant, so only the
/// agent can say what the library contains; see `Apple Photos Plan.md`, *The
/// agent owns the Photos grant*.
struct PhotosEndpoint: Sendable {
    /// Everything this endpoint owns sits under here, so the router can hand it
    /// a path it does not serve and get an honest 404 rather than a picture.
    static let prefix = "/v2/photos"
    static let albumsPath = "\(prefix)/albums"
    /// **v2, like everything Photos.** `Apple Photos Plan.md` Phase 4 named
    /// these `/v1/photos/authorization`, written before the versioning decision
    /// settled: v1 is the file-backed set, and a v1 client has no business with
    /// Photos consent because it cannot draw a Photos source at all.
    static let authorizationPath = "\(prefix)/authorization"

    let catalog: PhotosCollectionCatalog
    let library: any PhotoLibrary

    static func claims(_ path: String) -> Bool {
        path == prefix || path.hasPrefix(prefix + "/")
    }

    // MARK: - What a client sees

    /// **Authorization travels with the list, in one body.** "No albums" and
    /// "not allowed to look" are opposite facts and a client that received an
    /// empty array could not tell them apart — it would draw *this library is
    /// empty* over a library full of photographs somebody simply has not
    /// granted access to.
    struct Wire: Codable, Equatable {
        var authorization: String
        var sections: [Section]
        /// How far the background count has got. A client can say "still
        /// counting" without guessing from the nulls, and can stop asking once
        /// these are equal.
        var counted: Int
        var total: Int

        struct Section: Codable, Equatable {
            /// The stable name, for a client deciding what to do.
            var section: String
            /// What to put on screen, matching Photos' own sidebar.
            var title: String
            var collections: [Collection]
        }

        struct Collection: Codable, Equatable {
            /// The `PHAssetCollection` local identifier, which is what
            /// `POST /v2/sources` takes as a locator.
            var identifier: String
            var title: String
            var kind: String
            /// **Absent while it is still being counted**, which is not the
            /// same as zero. Counting a real library takes about half a minute
            /// and the names arrive first — see `PhotosCollectionCatalog`.
            var count: Int?
            /// The folders containing it, outermost first; empty at the top
            /// level. Thirty-one titles in a real library of 439 collections
            /// belong to more than one of them, and this is how Photos itself
            /// tells those apart.
            var folders: [String]
        }
    }

    /// What both authorization routes answer with. One field, because there is
    /// one fact: a client asks what it may do and is told.
    struct Consent: Codable, Equatable {
        var authorization: String
    }

    struct Failure: Codable, Equatable {
        var error: String
    }

    // MARK: - Routing

    func route(_ request: HTTPListener.Request) async -> HTTPListener.Response {
        let started = Date()
        switch (request.path, request.method) {
        case (Self.albumsPath, "GET"):
            return await albums(request, from: started)
        case (Self.authorizationPath, "GET"):
            return report(
                request, json(Consent(authorization: Self.name(await library.authorization))),
                detail: "authorization read", from: started)
        case (Self.authorizationPath, "POST"):
            // **The only call in this project that can raise a prompt**, and it
            // is here because this is the one place a person has just asked for
            // it. It is also a no-op for anybody who has already decided — see
            // `PhotoLibrary.requestAuthorization`.
            let granted = await library.requestAuthorization()
            return report(
                request, json(Consent(authorization: Self.name(granted))),
                detail: "authorization asked: \(Self.name(granted))", from: started)
        case (Self.albumsPath, _), (Self.authorizationPath, _):
            return report(
                request,
                json(
                    Failure(error: "\(request.method) is not served on \(request.path)"),
                    status: 405, reason: "Method Not Allowed"),
                detail: "method not allowed", from: started)
        default:
            return report(
                request, json(Failure(error: "no such endpoint"), status: 404, reason: "Not Found"),
                detail: "unknown photos route", from: started)
        }
    }

    private func albums(
        _ request: HTTPListener.Request, from started: Date
    ) async -> HTTPListener.Response {
        let authorization = await library.authorization
        guard Self.canRead(authorization) else {
            // **Nothing is asked of PhotoKit here.** A library we may not read
            // answers empty anyway, and asking would spend round trips to be
            // told what the authorization status already said.
            let wire = Wire(
                authorization: Self.name(authorization), sections: [], counted: 0, total: 0)
            return report(
                request, json(wire),
                detail: "not readable: \(Self.name(authorization))", from: started)
        }

        let groups = await catalog.sections()
        let progress = await catalog.progress()
        let wire = Wire(
            authorization: Self.name(authorization),
            sections: groups.map { group in
                Wire.Section(
                    section: group.section.rawValue,
                    title: group.section.title,
                    collections: group.collections.map {
                        Wire.Collection(
                            identifier: $0.identifier, title: $0.title,
                            kind: $0.kind.rawValue, count: $0.count, folders: $0.folders)
                    })
            },
            counted: progress.counted,
            total: progress.total)

        let total = groups.reduce(0) { $0 + $1.collections.count }
        return report(
            request, json(wire),
            detail: "\(total) collections, \(progress.counted) of \(progress.total) counted",
            from: started)
    }

    /// `.limited` is an iOS concept macOS does not offer, and it is readable —
    /// less of the library, but readable. Treating it as a refusal would show
    /// nothing to somebody who has granted something.
    static func canRead(_ authorization: LibraryAuthorization) -> Bool {
        authorization == .authorized || authorization == .limited
    }

    static func name(_ authorization: LibraryAuthorization) -> String {
        switch authorization {
        case .notDetermined: "notDetermined"
        case .restricted: "restricted"
        case .denied: "denied"
        case .authorized: "authorized"
        case .limited: "limited"
        }
    }

    // MARK: - Answering

    private func json<T: Encodable>(
        _ value: T, status: Int = 200, reason: String = "OK"
    ) -> HTTPListener.Response {
        guard let bytes = try? SourceEndpoint.encoder().encode(value) else {
            Log.photos.error("a photos response would not encode")
            return .text(
                "the library could not answer\n", status: 500, reason: "Internal Server Error")
        }
        return HTTPListener.Response(
            status: status, reason: reason,
            headers: ["Content-Type": "application/json; charset=utf-8"],
            body: .data(bytes))
    }

    /// Every path answers through here, so no route can reply without the
    /// request appearing in the log a person is watching.
    private func report(
        _ request: HTTPListener.Request,
        _ response: HTTPListener.Response,
        detail: String,
        from started: Date
    ) -> HTTPListener.Response {
        let milliseconds = Date().timeIntervalSince(started) * 1000
        let line = "\(response.status) \(request.method) \(request.path) · \(detail)"
        if response.status >= 500 { Console.alert(line) } else { Console.event(line) }
        Log.photos.notice(
            """
            \(request.method, privacy: .public) \(request.path, privacy: .public) \
            status=\(response.status, privacy: .public) \(detail, privacy: .public) \
            in \(Int(milliseconds), privacy: .public) ms
            """
        )
        return response
    }
}
