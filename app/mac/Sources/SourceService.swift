import Foundation
import PhotoGoRoundAgentAPI

/// The agent's source endpoints, over HTTP and nothing else.
///
/// **The app is a client.** It does not open the database, it does not read the
/// source list out of preferences, and it does not link anything the agent
/// links to do this work — it asks, and it decodes the answer. The one thing it
/// takes from preferences is where the agent is listening, because a port cannot
/// be discovered from an endpoint you need the port to reach.
///
/// The types below are this app's reading of the wire, declared here rather than
/// shared with the service. That is the point of there being a wire at all: the
/// two ends agree on a shape, not on a module.
struct SourceService {
    /// Read fresh on every request rather than resolved once, for the same
    /// reason `PictureClient` does it: the agent may have restarted onto a
    /// different port, and a client holding the old one fails for ever against a
    /// service that is running perfectly well.
    private let preferences: Preferences
    /// The one seam. `URLSession` in the app, a stub in a test — so the panel's
    /// behaviour can be exercised without an agent to talk to.
    private let transport: @Sendable (URLRequest) async throws -> (Data, URLResponse)

    init(
        preferences: Preferences,
        transport: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse) = {
            try await URLSession.shared.data(for: $0)
        }
    ) {
        self.preferences = preferences
        self.transport = transport
    }

    // MARK: - What comes back

    /// A source as the agent describes it. Extra fields it may grow are ignored
    /// rather than fatal, which is what keeps a newer agent from breaking an
    /// older panel.
    struct Source: Decodable, Equatable, Identifiable, Sendable {
        var uuid: String
        var kind: String
        var locator: String
        /// Folders only. Absent for a file, which has no such option — and the
        /// absence is what the panel reads to decide that Configure is not
        /// available.
        var recursive: Bool?
        var enabled: Bool
        var available: Bool
        var unavailableReason: String?
        /// What to call this source when its locator does not name itself.
        ///
        /// **v2 only, which is why the panel is on v2.** A folder is named by
        /// its last path component; a Photos album's locator is
        /// `A1B2C3D4-.../L0/040`, whose last component is `040` — worse than
        /// showing the whole identifier, because it looks like it means
        /// something. Only the agent can ask the library what an album is
        /// called.
        var title: String?
        var photos: Int
        var scannedAt: Date?

        var id: String { uuid }

        /// What to call it in a list: the last path component, which is the part
        /// a person recognises. The full path is shown underneath and in
        /// Configure.
        var name: String {
            if let title, !title.isEmpty { return title }
            let leaf = URL(filePath: locator).lastPathComponent
            return leaf.isEmpty ? locator : leaf
        }

        var isFolder: Bool { kind == "folder" }
        /// An album, smart album, or Favorites in the system Photos library.
        /// These are listed in their own panel and are not added, removed, or
        /// configured by the controls that serve the file-backed ones.
        var isPhotosCollection: Bool { kind == "photos_collection" }
    }

    /// Why an ask did not work, in the terms the panel has something to say
    /// about.
    enum Failure: Error, Equatable {
        /// Nothing has published a port: the agent is not running. The panel
        /// says so rather than showing an empty list, which would read as
        /// "you have no sources".
        case noAgent
        /// A port is published and nothing answered there.
        case unreachable(String)
        /// The service refused, and said why. The string is its `error` field,
        /// which is written to be shown.
        case refused(status: Int, reason: String)
        /// Paths the service could not find. Named, because the whole point of
        /// asking synchronously is being told which one was wrong.
        case notFound([String])
        /// The answer did not decode. A newer agent, or something else on the
        /// port.
        case unreadable
    }

    /// What is in the photo library, as the picker needs it.
    ///
    /// **Only the agent can answer this.** The app does not link PhotoKit and
    /// holds no grant of its own; see `Apple Photos Plan.md`, *The agent owns
    /// the Photos grant*.
    struct Library: Decodable, Equatable, Sendable {
        var authorization: String
        var sections: [Section]
        /// How far the agent's background count has got. Listing is
        /// milliseconds and counting a real library is about half a minute, so
        /// the names arrive first and the numbers follow.
        var counted: Int
        var total: Int

        /// Whether the agent is allowed to look at all. Anything else is a
        /// state to *show* — with the button that changes it — rather than an
        /// error to report.
        var isReadable: Bool { authorization == "authorized" || authorization == "limited" }
        /// True while numbers are still arriving, so the picker can say so
        /// instead of leaving blanks to be guessed at.
        var isCounting: Bool { counted < total }

        struct Section: Decodable, Equatable, Sendable, Identifiable {
            var section: String
            var title: String
            var collections: [Collection]

            var id: String { section }
        }

        struct Collection: Decodable, Equatable, Sendable, Identifiable {
            /// What `POST /v2/sources` takes as a locator.
            var identifier: String
            var title: String
            var kind: String
            /// Absent until the agent's background pass reaches it, which is
            /// not the same as zero.
            var count: Int?
            /// The folders containing it, outermost first; empty at the top
            /// level of the library.
            var folders: [String] = []

            var id: String { identifier }

            /// What Photos would call the path to it, for a row that has to
            /// say which of two same-named albums it is.
            var folderPath: String { folders.joined(separator: " › ") }
        }
    }

    // MARK: - Asking

    func collections() async throws -> Library {
        try await send(decoding: Library.self, "GET", "/v2/photos/albums")
    }

    /// Raises the consent prompt on the agent, and answers with what came back.
    ///
    /// **Only ever from a press.** The agent never asks on its own — see
    /// `PhotoLibrary.requestAuthorization` — so this is the call that makes a
    /// TCC dialog attributable to something the user just did.
    @discardableResult
    func requestPhotoAccess() async throws -> String {
        struct Consent: Decodable { var authorization: String }
        return try await send(
            decoding: Consent.self, "POST", "/v2/photos/authorization", body: Data()
        ).authorization
    }

    @discardableResult
    func add(collections identifiers: [String]) async throws -> [Source] {
        try await add(identifiers.map { ["kind": "photos_collection", "path": $0] })
    }

    func list() async throws -> [Source] {
        try await send(decoding: [Source].self, "GET", "/v2/sources")
    }

    /// Adds every path in one request, so a selection of two hundred files is
    /// one write and one doorbell rather than two hundred of each.
    ///
    /// **All of them or none of them**, which is the service's rule rather than
    /// this one: a path that stopped resolving between the dialog and the
    /// request refuses the batch and names itself.
    @discardableResult
    func add(files: [URL]) async throws -> [Source] {
        try await add(files.map { ["kind": "file", "path": $0.path(percentEncoded: false)] })
    }

    @discardableResult
    func add(folder: URL, recursive: Bool) async throws -> [Source] {
        try await add([
            [
                "kind": "folder", "path": folder.path(percentEncoded: false),
                "recursive": recursive,
            ]
        ])
    }

    private func add(_ entries: [[String: Any]]) async throws -> [Source] {
        guard let body = try? JSONSerialization.data(withJSONObject: entries) else {
            throw Failure.unreadable
        }
        return try await send(decoding: [Source].self, "POST", "/v2/sources", body: body)
    }

    @discardableResult
    func setRecursive(_ recursive: Bool, of uuid: String) async throws -> Source {
        let body = try JSONEncoder().encode(["recursive": recursive])
        return try await send(
            decoding: Source.self, "PATCH", "/v2/sources/\(uuid)", body: body)
    }

    /// Answers `204`, so there is nothing to decode — the absence of a refusal
    /// is the whole answer.
    func remove(_ uuid: String) async throws {
        _ = try await send("DELETE", "/v2/sources/\(uuid)", body: nil)
    }

    // MARK: - The one request shape

    @discardableResult
    private func send<T: Decodable>(
        decoding type: T.Type, _ method: String, _ path: String, body: Data? = nil
    ) async throws -> T {
        let data = try await send(method, path, body: body)
        guard let decoded = try? Self.decoder().decode(T.self, from: data) else {
            throw Failure.unreadable
        }
        return decoded
    }

    private func send(_ method: String, _ path: String, body: Data?) async throws -> Data {
        guard let port = preferences.servicePort,
            let url = URL(string: "http://localhost:\(port)\(path)")
        else { throw Failure.noAgent }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 15
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await transport(request)
        } catch let error as URLError {
            throw Failure.unreachable(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw Failure.unreadable }
        guard (200...299).contains(http.statusCode) else {
            throw Self.refusal(status: http.statusCode, body: data)
        }
        return data
    }

    /// The service answers every refusal in one shape, so this reads one field
    /// rather than parsing prose.
    private static func refusal(status: Int, body: Data) -> Failure {
        struct Refusal: Decodable {
            var error: String
            var missing: [String]?
        }
        guard let refusal = try? JSONDecoder().decode(Refusal.self, from: body) else {
            return .refused(status: status, reason: "the service answered \(status)")
        }
        if let missing = refusal.missing, !missing.isEmpty { return .notFound(missing) }
        return .refused(status: status, reason: refusal.error)
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
