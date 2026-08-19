import Foundation

/// A size in pixels, which is the only unit the service and a view agree on.
///
/// Points are what a window is measured in and what varies with the display's
/// backing scale; the box in a request and the size in an answer are both
/// pixels, and keeping the type distinct from `CGSize` is what stops the two
/// being mixed up in a call.
public struct PixelSize: Sendable, Equatable {
    public let width: Int
    public let height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
}

/// One picture, as the service handed it over.
///
/// Bytes and the facts about them, and deliberately not a decoded image: the
/// module that knows about `CGImage` is the one drawing, and a value that can
/// cross an actor boundary without dragging a decode with it is easier to hold
/// than one that cannot.
public struct ServedPicture: Sendable, Equatable {
    /// What was served, in the format `contentType` names.
    public let data: Data
    public let contentType: String
    /// What the service actually produced, which is not the box that was asked
    /// for: nothing is enlarged, so a box larger than the original comes back
    /// at the original's pixels. Absent when the original bytes were served
    /// untouched, since nothing measured them.
    public let pixels: PixelSize?
    /// The photograph's row id, and its ordinal in the shuffle.
    public let card: Int64?
    public let deal: Int64?
    public let source: Int64?
    /// `referenced` or `materialized`, as the cache sees it.
    public let storage: String?
    /// Whether the service had this rendering already. Absent for originals,
    /// which are not rendered and therefore neither hit nor missed.
    public let cache: CacheState?

    public enum CacheState: String, Sendable {
        case hit
        case miss
    }

    public init(
        data: Data,
        contentType: String,
        pixels: PixelSize? = nil,
        card: Int64? = nil,
        deal: Int64? = nil,
        source: Int64? = nil,
        storage: String? = nil,
        cache: CacheState? = nil
    ) {
        self.data = data
        self.contentType = contentType
        self.pixels = pixels
        self.card = card
        self.deal = deal
        self.source = source
        self.storage = storage
        self.cache = cache
    }
}

extension ServedPicture {
    /// Reads the `X-PGR-` headers the endpoint sets.
    ///
    /// Separated from the request so the parse can be asserted without a
    /// listener: every one of these is optional on the wire, and a client that
    /// insisted on any of them would break the first time the endpoint gained
    /// or lost one.
    public static func from(
        data: Data, headers: [String: String], defaultContentType: String = "application/octet-stream"
    ) -> ServedPicture {
        // Header names are case-insensitive, and nothing guarantees which case
        // a response arrives in — `URLHTTPResponse` normalises, a raw socket
        // does not.
        let fields = Dictionary(
            headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { _, last in last }
        )
        func pixels() -> PixelSize? {
            guard let raw = fields["x-pgr-pixels"] else { return nil }
            let parts = raw.split(separator: "x")
            guard parts.count == 2, let width = Int(parts[0]), let height = Int(parts[1])
            else { return nil }
            return PixelSize(width: width, height: height)
        }
        return ServedPicture(
            data: data,
            contentType: fields["content-type"] ?? defaultContentType,
            pixels: pixels(),
            card: fields["x-pgr-card"].flatMap(Int64.init),
            deal: fields["x-pgr-deal"].flatMap(Int64.init),
            source: fields["x-pgr-source"].flatMap(Int64.init),
            storage: fields["x-pgr-storage"],
            cache: fields["x-pgr-cache"].flatMap(CacheState.init(rawValue:))
        )
    }
}
