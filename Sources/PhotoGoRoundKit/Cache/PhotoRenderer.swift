import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Turns an original into the pixels a client asked for.
///
/// **The client draws what it is handed, 1:1, and never resamples.** That is the
/// whole contract: it names the box it wants filled, and what comes back fits
/// inside that box with its aspect ratio intact, upright, and ready to put on a
/// layer.
///
/// `CGImageSourceCreateThumbnailAtIndex` does not decode fully and then shrink —
/// it decodes at a subsampled scale, so peak memory is bounded by the *output*
/// size rather than by the source's pixel count. A 48-megapixel HEIC rendered for
/// a 6K display costs about what a 6K image costs.
///
/// **Nothing here touches the main thread or AppKit.** These are Core Graphics C
/// APIs, safe off the main thread and safe headless; `NSImage` would drag in both
/// problems and is never needed, because the service encodes bytes rather than
/// drawing anything.
public enum PhotoRenderer {

    /// What a client will accept back. Every client on these platforms decodes
    /// HEIC, and it is roughly half the bytes of the equivalent JPEG, so it is
    /// the default and JPEG is the fallback anything can read.
    public enum Format: String, Sendable, CaseIterable {
        case heic
        case jpeg

        var contentType: UTType { self == .heic ? .heic : .jpeg }
        public var mimeType: String { self == .heic ? "image/heic" : "image/jpeg" }

        /// Picks a format from an `Accept` header, preferring HEIC when the
        /// client will take either and when it says nothing.
        ///
        /// Nil when the header admits neither format — the honest answer there
        /// is a refusal, not a fallback the client never asked for.
        public static func negotiated(accept: String?) -> Format? {
            guard let accept = accept?.lowercased() else { return .heic }
            if accept.contains("image/heic") || accept.contains("image/*") { return .heic }
            if accept.contains("*/*") { return .heic }
            if accept.contains("image/jpeg") || accept.contains("image/jpg") { return .jpeg }
            return nil
        }

        /// Whether an `Accept` header admits this format.
        ///
        /// Broader than `negotiated` on purpose: negotiation picks what to
        /// *produce*, while this asks whether bytes already held may be served
        /// as they are — a rendering in any acceptable format is a hit, and
        /// only a client that genuinely excludes it forces a re-render.
        public func admitted(by accept: String?) -> Bool {
            guard let accept = accept?.lowercased() else { return true }
            if accept.contains("image/*") || accept.contains("*/*") { return true }
            switch self {
            case .heic: return accept.contains("image/heic")
            case .jpeg: return accept.contains("image/jpeg") || accept.contains("image/jpg")
            }
        }
    }

    public struct Rendered: Sendable {
        public let bytes: Data
        public let format: Format
        /// What was produced, which is what the client will draw at.
        public let width: Int
        public let height: Int
    }

    public enum Failure: Error, CustomStringConvertible, Sendable {
        case unreadable
        case noDimensions
        case decodeFailed
        case encodeFailed

        public var description: String {
            switch self {
            case .unreadable: "the file could not be opened as an image"
            case .noDimensions: "the image reports no pixel dimensions"
            case .decodeFailed: "the image could not be decoded"
            case .encodeFailed: "the image could not be encoded"
            }
        }
    }

    /// Renders the file at `url` to fit inside `width` × `height`.
    ///
    /// **Never upscaled.** A client asking for a box larger than the original
    /// gets the original's pixels; enlarging them here would spend bytes on a
    /// connection to deliver no more detail than the display layer could invent
    /// for itself.
    public static func render(
        contentsOf url: URL,
        fitting width: Int,
        by height: Int,
        as format: Format,
        quality: Double = PhotoRenderer.defaultQuality
    ) throws -> Rendered {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            CGImageSourceGetCount(source) > 0
        else { throw Failure.unreadable }

        // Read the dimensions without decoding, because the fitted size decides
        // what to ask the decoder for.
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let sourceWidth = properties[kCGImagePropertyPixelWidth] as? Int,
            let sourceHeight = properties[kCGImagePropertyPixelHeight] as? Int,
            sourceWidth > 0, sourceHeight > 0
        else { throw Failure.noDimensions }

        let fitted = fit(
            sourceWidth: sourceWidth, sourceHeight: sourceHeight,
            intoWidth: width, byHeight: height)

        // One number, because that is the knob the decoder has: the longest edge
        // of the output. The fit above is what makes it the right number.
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: max(fitted.width, fitted.height),
            // Applies the EXIF orientation, so what comes back is upright and no
            // client has to know the original was rotated.
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { throw Failure.decodeFailed }

        let data = NSMutableData()
        guard
            let destination = CGImageDestinationCreateWithData(
                data, format.contentType.identifier as CFString, 1, nil)
        else { throw Failure.encodeFailed }

        CGImageDestinationAddImage(
            destination, image,
            [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw Failure.encodeFailed }

        return Rendered(
            bytes: data as Data,
            format: format,
            width: image.width,
            height: image.height
        )
    }

    /// The pixel dimensions of an image on disk, read from its header without
    /// decoding it.
    ///
    /// Used to answer for bytes that were rendered earlier: what a client is
    /// handed has to be described the same way whether it was just made or was
    /// already held.
    public static func pixelSize(of url: URL) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? Int,
            let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return (width, height)
    }

    /// High enough that the result is indistinguishable at display size, low
    /// enough that the bytes are a fraction of the original's.
    public static let defaultQuality = 0.9

    /// The largest size preserving aspect ratio that fits inside the box, never
    /// larger than the source.
    ///
    /// Two numbers rather than one, because the client names a box rather than a
    /// longest edge — a 4000×3000 photograph fitted into 3840×2160 is 2880×2160,
    /// and into 2160×3840 is 2160×1620. A single maximum would render the same
    /// thing for both and be wrong for each.
    ///
    /// **Only the longer of the two is load-bearing.** It becomes the decoder's
    /// `kCGImageSourceThumbnailMaxPixelSize`, and the decoder derives the other
    /// edge itself — by truncation, where this rounds. A 1200×900 photograph into
    /// a 101×101 box is 101×75 from the decoder and 101×76 from here. What is
    /// served always reports the image's own dimensions, so the difference never
    /// escapes; anyone reaching for the shorter edge of this result should read
    /// it off the rendered image instead.
    static func fit(
        sourceWidth: Int, sourceHeight: Int, intoWidth width: Int, byHeight height: Int
    ) -> (width: Int, height: Int) {
        guard width > 0, height > 0 else { return (sourceWidth, sourceHeight) }
        let scale = min(
            Double(width) / Double(sourceWidth),
            Double(height) / Double(sourceHeight))
        guard scale < 1 else { return (sourceWidth, sourceHeight) }
        return (
            max(1, Int((Double(sourceWidth) * scale).rounded())),
            max(1, Int((Double(sourceHeight) * scale).rounded()))
        )
    }
}
