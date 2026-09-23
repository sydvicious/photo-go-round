import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import PhotosGoRoundDisplay

/// What `Shuffle` makes of the bytes it is handed.
///
/// **Since 2026-09-16 those bytes may be an original.** The agent sends the
/// original when a resize stalls (`Agent Performance Overhaul.md`, Phase 2a),
/// and an original is as large as the camera made it and carries its
/// orientation as EXIF rather than in its pixels. The resized pictures the agent
/// used to send were already upright and already the box's size, so decoding
/// them as-is was enough; an original needs both applied here.
@Suite("Shuffle decoding")
struct ShuffleDecodeTests {

    /// A 40×20 JPEG whose EXIF says it was taken rotated — orientation 6, so
    /// upright it is 20 wide and 40 tall.
    static func rotatedJPEG() throws -> Data {
        let context = try #require(
            CGContext(
                data: nil, width: 40, height: 20, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 0.9, green: 0.6, blue: 0.3, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 40, height: 20))
        let data = NSMutableData()
        let destination = try #require(
            CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(
            destination, try #require(context.makeImage()),
            [kCGImagePropertyOrientation: 6] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    @Test("A photograph taken rotated is decoded upright")
    func orientationIsApplied() async throws {
        let image = try #require(
            await Shuffle.decode(try Self.rotatedJPEG(), fitting: PixelSize(width: 1000, height: 1000)))
        #expect(image.width == 20)
        #expect(image.height == 40)
    }

    /// An original can be forty-eight megapixels; the view it goes into is a
    /// window or a display. Decoding to the box is what keeps the full-size
    /// bitmap out of memory, the screensaver's included.
    @Test("An original larger than the box is decoded no larger than the box")
    func decodedToTheBox() async throws {
        let image = try #require(
            await Shuffle.decode(try Self.rotatedJPEG(), fitting: PixelSize(width: 10, height: 10)))
        #expect(max(image.width, image.height) <= 10)
        #expect(image.height > image.width, "and still upright")
    }
}
