import Foundation
import Testing

@testable import PhotoGoRoundDisplay

@Suite("Reading what the service said about a picture")
struct PictureTests {

    /// Exactly the headers `PictureEndpoint.headers(for:contentType:)` sets on a
    /// rendered answer.
    private let served = [
        "Content-Type": "image/heic",
        "X-PGR-Card": "417",
        "X-PGR-Deal": "5312",
        "X-PGR-Source": "2",
        "X-PGR-Storage": "referenced",
        "X-PGR-Pixels": "3840x2160",
        "X-PGR-Cache": "miss",
    ]

    @Test("Every header the endpoint sets is read back")
    func fullSet() {
        let picture = ServedPicture.from(data: Data([0xAB]), headers: served)
        #expect(picture.contentType == "image/heic")
        #expect(picture.card == 417)
        #expect(picture.deal == 5312)
        #expect(picture.source == 2)
        #expect(picture.storage == "referenced")
        #expect(picture.pixels == PixelSize(width: 3840, height: 2160))
        #expect(picture.cache == .miss)
    }

    /// `URLHTTPResponse` normalises header names and a raw socket does not, so
    /// nothing may depend on the case they arrive in.
    @Test("Header names are matched without regard to case")
    func caseInsensitive() {
        let lowered = Dictionary(uniqueKeysWithValues: served.map { ($0.key.lowercased(), $0.value) })
        #expect(ServedPicture.from(data: Data(), headers: lowered).card == 417)
        #expect(ServedPicture.from(data: Data(), headers: lowered).pixels?.width == 3840)
    }

    /// The original bytes are served with neither a size nor a cache state,
    /// because nothing rendered them.
    @Test("An original carries no pixels and no cache state")
    func original() {
        let picture = ServedPicture.from(
            data: Data(),
            headers: ["Content-Type": "image/png", "X-PGR-Card": "9", "X-PGR-Deal": "1", "X-PGR-Storage": "materialized"])
        #expect(picture.pixels == nil)
        #expect(picture.cache == nil)
        #expect(picture.contentType == "image/png")
    }

    /// Every one of these is optional on the wire. A client that insisted on any
    /// of them would break the first time the endpoint gained or lost one — and
    /// `X-PGR-Name` is already on the list of headers it is going to gain.
    @Test("A response with nothing but bytes still parses")
    func bare() {
        let picture = ServedPicture.from(data: Data([1, 2, 3]), headers: [:])
        #expect(picture.data.count == 3)
        #expect(picture.contentType == "application/octet-stream")
        #expect(picture.card == nil)
    }

    @Test("A malformed pixel size is ignored rather than guessed at", arguments: ["3840", "wide x tall", "3840x", "3840x2160x1"])
    func malformedPixels(raw: String) {
        #expect(ServedPicture.from(data: Data(), headers: ["X-PGR-Pixels": raw]).pixels == nil)
    }
}
