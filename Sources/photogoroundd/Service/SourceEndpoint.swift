import Console
import Foundation
import PhotoGoRoundKit

/// Managing sources over HTTP, so that a client never opens the database.
///
/// ```
/// GET    /v1/sources           the list, with counts and availability
/// POST   /v1/sources           add an array, all or none
/// GET    /v1/sources/<uuid>    one source, and the options it was added with
/// DELETE /v1/sources/<uuid>    remove one
/// ```
///
/// **Every change goes through preferences, exactly as `pgr_ctl`'s does.** The
/// `source` table is a projection of the durable list, so a row written straight
/// into the database is deleted again at the agent's next reconcile. What is new
/// here is only *who* writes preferences: the service, on behalf of a client
/// that cannot meaningfully reach them — a sandboxed surface, a panel that wants
/// a status code back, anything that would otherwise be two writers racing over
/// one array with no compare-and-swap. See `PLAN.md`, *The database is private
/// to the service*.
///
/// **A source is named by its `uuid`, never by its row id.** The database is
/// disposable and a rebuilt one renumbers from 1; the UUID is minted once and
/// already names where that source's bytes live in the cache.
///
/// **Adding does not wait for the scan.** A folder of eight thousand
/// photographs takes seconds to walk, and a request that blocked on it would
/// look like a hang in exactly the case that matters most. The write rings the
/// doorbell, the agent refreshes, and the count arrives on a later `GET`.
struct SourceEndpoint {
    let databasePath: String
    let preferences: Preferences
    /// The collection route. The member routes are this plus a `uuid`.
    static let path = "/v1/sources"

    /// Where a handled request is recorded, injected for the same reason
    /// `PictureEndpoint`'s is: `os_log` lands in a store no test can read back
    /// while the assertion is still interesting.
    var log: @Sendable (Handled) -> Void = { $0.report() }

    /// One request, as it happened.
    struct Handled: Sendable, Equatable {
        var method: String
        var path: String
        var status: Int
        /// What was done, or what was wrong with the asking.
        var detail: String
        var milliseconds: Double

        func report() {
            let line = "\(status) \(method) \(path) · \(detail)"
            switch status {
            case 200...299: Console.event(line)
            case 500...599: Console.alert(line)
            default: Console.event(line)
            }
            Log.sources.notice(
                """
                \(method, privacy: .public) \(path, privacy: .public) \
                status=\(status, privacy: .public) \(detail, privacy: .public)
                """
            )
        }
    }

    // MARK: - What a client sees

    /// A source as it goes over the wire.
    ///
    /// One joined representation — the row, plus the photo count that lives in
    /// another table — because "every reader reimplements the join" was one of
    /// the five things that sank publishing this through preferences.
    struct Wire: Codable, Equatable {
        var uuid: String
        var kind: String
        var locator: String
        /// Folders only, and absent for every other kind rather than false.
        var recursive: Bool?
        var enabled: Bool
        var available: Bool
        var unavailableReason: String?
        /// How many photographs this source has put in the pool. Zero for a
        /// source added a moment ago, because the scan has not run yet.
        var photos: Int
        var addedAt: Date
        var scannedAt: Date?
    }

    /// A source a client is asking for, before anything has checked it is there.
    ///
    /// `path` rather than `locator`, matching `SourceRequest`: a locator is what
    /// a source that exists has, and this is a path somebody picked in a dialog.
    struct Requested: Codable, Equatable {
        /// `folder` when unstated, which is what a dialog most often produces.
        var kind: String?
        var path: String
        var recursive: Bool?
    }

    /// What went wrong, in the same shape every time so a client can read one
    /// field rather than parse prose.
    struct Failure: Codable, Equatable {
        var error: String
        /// The paths that were not there, when that is what was wrong.
        var missing: [String]?
    }

    // MARK: - Routing

    /// Whether this endpoint owns the path, asked by the router before the
    /// method is looked at — so a `POST` to a source route is answered here
    /// rather than by the picture endpoint's "only GET is served".
    static func claims(_ path: String) -> Bool {
        path == Self.path || path.hasPrefix(Self.path + "/")
    }

    /// The `uuid` in a member route, or nil for the collection.
    static func identifier(in path: String) -> String? {
        guard path.hasPrefix(Self.path + "/") else { return nil }
        let rest = path.dropFirst(Self.path.count + 1)
        let trimmed = rest.hasSuffix("/") ? rest.dropLast() : rest
        return trimmed.isEmpty ? nil : String(trimmed)
    }

    func route(_ request: HTTPListener.Request) async -> HTTPListener.Response {
        let store: SourceStore
        do {
            let database = try Database(path: databasePath)
            try Migrator.migrate(database)
            store = SourceStore(database: database)
        } catch {
            Log.sources.error(
                "could not open the library: \(String(describing: error), privacy: .public)")
            return answer(
                request, .text("library unavailable\n", status: 503, reason: "Service Unavailable"),
                detail: "library unavailable")
        }

        switch (request.method, Self.identifier(in: request.path)) {
        case ("GET", nil):
            return list(request, store: store)
        case ("POST", nil):
            return add(request, store: store)
        case ("GET", .some(let uuid)):
            return one(request, uuid: uuid, store: store)
        case ("DELETE", .some(let uuid)):
            return remove(request, uuid: uuid, store: store)
        default:
            return answer(
                request,
                .text(
                    "\(request.method) is not served on \(request.path)\n", status: 405,
                    reason: "Method Not Allowed"),
                detail: "\(request.method) is not served here")
        }
    }

    // MARK: - Reading

    private func list(
        _ request: HTTPListener.Request, store: SourceStore
    ) -> HTTPListener.Response {
        do {
            let sources = try store.all().map { wire($0, store: store) }
            return answer(
                request, json(sources),
                detail: "\(sources.count) source" + (sources.count == 1 ? "" : "s"))
        } catch {
            return answer(request, failed(error), detail: "could not list the sources")
        }
    }

    private func one(
        _ request: HTTPListener.Request, uuid: String, store: SourceStore
    ) -> HTTPListener.Response {
        do {
            guard let source = try store.source(uuid: uuid) else { return missing(request, uuid) }
            return answer(request, json(wire(source, store: store)), detail: source.locator)
        } catch {
            return answer(request, failed(error), detail: "could not read the source")
        }
    }

    // MARK: - Adding

    /// **All of them or none of them**, and through the same kit call `pgr_ctl`
    /// makes: resolve the batch, write preferences once, reconcile the table.
    /// See `SourceStore.add(_:to:)`, which owns every rule this applies.
    ///
    /// The answer describes a library that already contains what was asked for,
    /// including the `uuid` the client will name it by — but it does **not** wait
    /// for the scan. The write rang the doorbell; the agent walks the folder and
    /// the count arrives on a later `GET`.
    private func add(
        _ request: HTTPListener.Request, store: SourceStore
    ) -> HTTPListener.Response {
        let requested: [Requested]
        do {
            requested = try JSONDecoder().decode([Requested].self, from: request.body)
        } catch {
            return answer(
                request,
                json(
                    Failure(error: "expected a JSON array of {kind, path, recursive}"),
                    status: 400, reason: "Bad Request"),
                detail: "unreadable body")
        }

        do {
            let addition = try store.add(
                requested.map {
                    SourceRequest(
                        kind: SourceKind($0.kind ?? SourceKind.folder.rawValue),
                        path: $0.path,
                        recursive: $0.recursive ?? false)
                },
                to: preferences)

            let created = addition.added.map { wire($0, store: store) }
            return answer(
                request,
                json(
                    created, status: created.isEmpty ? 200 : 201,
                    reason: created.isEmpty ? "OK" : "Created"),
                detail: created.isEmpty
                    ? "nothing new; \(addition.alreadyListed.count) already listed"
                    : created.map(\.locator).joined(separator: ", "))
        } catch SourceStore.EditFailure.unsupportedKind(let kind) {
            return answer(
                request,
                json(
                    Failure(error: "\(kind.rawValue) sources cannot be added"), status: 400,
                    reason: "Bad Request"),
                detail: "unsupported kind \(kind.rawValue)")
        } catch SourceStore.EditFailure.pathsNotFound(let paths) {
            return answer(
                request,
                json(
                    Failure(error: "not found", missing: paths), status: 400,
                    reason: "Bad Request"),
                detail: "missing: \(paths.joined(separator: ", "))")
        } catch {
            return answer(request, failed(error), detail: "could not add the sources")
        }
    }

    // MARK: - Removing

    private func remove(
        _ request: HTTPListener.Request, uuid: String, store: SourceStore
    ) -> HTTPListener.Response {
        do {
            guard let source = try store.source(uuid: uuid) else { return missing(request, uuid) }
            try store.remove(source, from: preferences)
            return answer(request, .noContent(), detail: "removed \(source.locator)")
        } catch {
            return answer(request, failed(error), detail: "could not remove the source")
        }
    }

    // MARK: - Answering

    private func wire(_ source: Source, store: SourceStore) -> Wire {
        Wire(
            uuid: source.uuid,
            kind: source.kind.rawValue,
            locator: source.locator,
            recursive: source.recursive,
            enabled: source.enabled,
            available: source.available,
            unavailableReason: source.unavailableReason,
            photos: (try? store.pool.size(forSource: source.id)) ?? 0,
            addedAt: source.addedAt,
            scannedAt: source.scannedAt
        )
    }

    /// Dates as ISO 8601 and slashes unescaped, because a locator is a path and
    /// `\/` in every one of them is unreadable for nobody's benefit.
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    /// Encoding is not a failure a client can be told about usefully — these
    /// are three flat structs and none of them can fail — so it is handled here
    /// rather than propagated into every call site as a `try`.
    private func json<T: Encodable>(
        _ value: T, status: Int = 200, reason: String = "OK"
    ) -> HTTPListener.Response {
        guard let bytes = try? Self.encoder().encode(value) else {
            Log.sources.error("a source response would not encode")
            return .text(
                "the library could not answer\n", status: 500, reason: "Internal Server Error")
        }
        return HTTPListener.Response(
            status: status, reason: reason,
            headers: ["Content-Type": "application/json; charset=utf-8"],
            body: .data(bytes)
        )
    }

    private func missing(_ request: HTTPListener.Request, _ uuid: String) -> HTTPListener.Response {
        answer(
            request, json(Failure(error: "no such source"), status: 404, reason: "Not Found"),
            detail: "no source \(uuid)")
    }

    /// The library answered with an exception. Nothing a client can do about it,
    /// so it says so plainly and the details go to the log.
    private func failed(_ error: any Error) -> HTTPListener.Response {
        Log.sources.error("source request failed: \(String(describing: error), privacy: .public)")
        return json(
            Failure(error: "the library could not answer"), status: 500,
            reason: "Internal Server Error")
    }

    /// Records the request and returns the response, so that no path can answer
    /// without saying what it did.
    private func answer(
        _ request: HTTPListener.Request, _ response: HTTPListener.Response, detail: String
    ) -> HTTPListener.Response {
        log(
            Handled(
                method: request.method,
                path: request.path,
                status: response.status,
                detail: detail,
                milliseconds: (ContinuousClock.now - request.receivedAt).totalSeconds * 1000
            )
        )
        return response
    }
}
