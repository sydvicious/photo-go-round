import CoreGraphics
import Foundation
import ImageIO
import PhotosGoRoundAgentAPI
import UniformTypeIdentifiers

/// The last picture a surface showed, kept on disk so the next session opens
/// with it.
///
/// **Because the first request of a session is the slowest one there is.** A
/// `Shuffle` keeps its picture across a stop, but only for as long as its
/// process lives, and `legacyScreenSaver` is a new process more often than not.
/// On 2026-09-23 a screensaver started a minute after a reboot showed nothing
/// for 75 seconds while the agent, cold, took four to seven seconds a picture.
/// A picture read off this disk is up in milliseconds, whatever state the
/// agent is in, and the first fresh one replaces it.
///
/// **What is kept is what was drawn**: the decoded image, already fitted to the
/// display and turned upright, written as HEIC. A few hundred kilobytes rather
/// than an original that can be tens of megabytes, and nothing to fit again on
/// the way back. Beside it goes what the agent said about the picture, so a
/// log line about the remembered picture can still name it.
///
/// One per `key`, which the caller makes the display: two screens remember two
/// pictures. A file that is missing, partly written, or unreadable is simply
/// no picture — this is a convenience and never a reason to show nothing.
public struct PictureMemory: Sendable {
    private let image: URL
    private let details: URL

    public init(directory: URL, key: String) {
        let name = Self.fileName(for: key)
        image = directory.appending(path: name + ".heic")
        details = directory.appending(path: name + ".json")
    }

    /// What the agent said about a picture, less its bytes.
    struct Details: Codable, Equatable {
        var card: Int64?
        var deal: Int64?
        var source: Int64?
        var name: String?
        var sourceName: String?
    }

    /// The remembered picture, or nil when there is none worth showing.
    ///
    /// The picture's `data` is the remembered HEIC and its `pixels` its size,
    /// so it describes the bytes it carries, as a served picture does.
    public func recall() async -> (image: CGImage, picture: ServedPicture)? {
        let image = self.image
        let details = self.details
        return await Task.detached(priority: .userInitiated) { () -> Recalled? in
            guard let data = try? Data(contentsOf: image),
                let source = CGImageSourceCreateWithData(data as CFData, nil),
                let decoded = CGImageSourceCreateImageAtIndex(source, 0, nil)
            else { return nil }
            let said =
                (try? Data(contentsOf: details)).flatMap {
                    try? JSONDecoder().decode(Details.self, from: $0)
                } ?? Details()
            let picture = ServedPicture(
                data: data, contentType: "image/heic",
                pixels: PixelSize(width: decoded.width, height: decoded.height),
                card: said.card, deal: said.deal, source: said.source,
                name: said.name, sourceName: said.sourceName)
            return Recalled(image: decoded, picture: picture)
        }.value.map { ($0.image, $0.picture) }
    }

    /// Keeps `image` as the picture to open with next time.
    ///
    /// Written whole and then moved into place, so a session that ends part way
    /// through leaves the previous picture rather than half of this one.
    public func remember(_ image: CGImage, as picture: ServedPicture) async throws {
        let target = self.image
        let details = self.details
        let said = Details(
            card: picture.card, deal: picture.deal, source: picture.source,
            name: picture.name, sourceName: picture.sourceName)
        let held = Recalled(image: image, picture: picture)
        try await Task.detached(priority: .utility) {
            try FileManager.default.createDirectory(
                at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            let bytes = NSMutableData()
            guard
                let destination = CGImageDestinationCreateWithData(
                    bytes, UTType.heic.identifier as CFString, 1, nil)
            else { throw Failure.cannotEncode }
            CGImageDestinationAddImage(
                destination, held.image,
                [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { throw Failure.cannotEncode }
            try (bytes as Data).write(to: target, options: .atomic)
            try JSONEncoder().encode(said).write(to: details, options: .atomic)
        }.value
    }

    enum Failure: Error {
        case cannotEncode
    }

    /// A display's identifier is a UUID, but the key is whatever the caller
    /// says, so anything that is not safe in a file name becomes `_`.
    static func fileName(for key: String) -> String {
        let safe = key.map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "_" }
        return "last-" + String(safe)
    }

    /// `CGImage` crosses into and out of the detached task the way
    /// `Shuffle.decode` carries it: immutable once made, so safe to hand over.
    private struct Recalled: @unchecked Sendable {
        let image: CGImage
        let picture: ServedPicture
    }
}
