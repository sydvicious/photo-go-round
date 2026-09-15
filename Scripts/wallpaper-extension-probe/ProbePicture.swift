// The picture the probe shows. `Wallpaper Plan.md`, *The second probe*.
//
// Drawn rather than carried as a file: a blue-to-yellow gradient, which reads
// the same to red-green colour blindness, with the probe's name across it, so
// nobody mistakes it for a real wallpaper.

import CoreGraphics
import CoreMedia
import CoreText
import CoreVideo
import Foundation
import ImageIO

enum ProbePicture {
    static let image: CGImage? = draw(width: 1920, height: 1080)

    /// A PNG the pane shows as the item's thumbnail, written once into the
    /// extension's container, which is where Phosphene keeps its own.
    static let thumbnailURL: URL? = writeThumbnail()

    private static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    private static func draw(width: Int, height: Int) -> CGImage? {
        guard
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue),
            let gradient = CGGradient(
                colorsSpace: sRGB,
                colors: [
                    CGColor(srgbRed: 0.10, green: 0.30, blue: 0.75, alpha: 1),
                    CGColor(srgbRed: 0.98, green: 0.80, blue: 0.15, alpha: 1),
                ] as CFArray,
                locations: [0, 1])
        else { return nil }
        context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: width, y: height), options: [])

        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, CGFloat(height) / 12, nil)
        let text = NSAttributedString(
            string: "Photo-Go-Round wallpaper probe",
            attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1),
            ])
        let line = CTLineCreateWithAttributedString(text)
        let bounds = CTLineGetImageBounds(line, context)
        context.setShadow(offset: CGSize(width: 0, height: -4), blur: 12, color: CGColor(gray: 0, alpha: 0.6))
        context.textPosition = CGPoint(
            x: (CGFloat(width) - bounds.width) / 2 - bounds.minX,
            y: (CGFloat(height) - bounds.height) / 2 - bounds.minY)
        CTLineDraw(line, context)
        return context.makeImage()
    }

    private static func writeThumbnail() -> URL? {
        guard let image,
            let context = CGContext(
                data: nil, width: 480, height: 270, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)
        else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: 480, height: 270))
        guard let small = context.makeImage(),
            let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        else { return nil }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            probe("thumbnail: could not create \(folder.path(percentEncoded: false)): \(error)")
            return nil
        }
        let url = folder.appending(path: "probe-thumbnail.png")
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, small, nil)
        return CGImageDestinationFinalize(destination) ? url : nil
    }

    /// The picture as one IOSurface-backed sample buffer, marked to display at
    /// once, for an `AVSampleBufferDisplayLayer`.
    static func stillSample(of image: CGImage) -> CMSampleBuffer? {
        let attributes: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
        ]
        var created: CVPixelBuffer?
        guard
            CVPixelBufferCreate(
                kCFAllocatorDefault, image.width, image.height, kCVPixelFormatType_32BGRA,
                attributes as CFDictionary, &created) == kCVReturnSuccess,
            let buffer = created
        else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        let drew: Bool = {
            guard
                let context = CGContext(
                    data: CVPixelBufferGetBaseAddress(buffer), width: image.width, height: image.height,
                    bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: sRGB,
                    bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }()
        CVPixelBufferUnlockBaseAddress(buffer, [])
        guard drew else { return nil }

        var format: CMVideoFormatDescription?
        guard
            CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: kCFAllocatorDefault, imageBuffer: buffer, formatDescriptionOut: &format) == noErr,
            let format
        else { return nil }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard
            CMSampleBufferCreateReadyWithImageBuffer(
                allocator: kCFAllocatorDefault, imageBuffer: buffer, formatDescription: format,
                sampleTiming: &timing, sampleBufferOut: &sample) == noErr,
            let sample
        else { return nil }

        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
            CFArrayGetCount(attachments) > 0
        {
            let first = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(
                first,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sample
    }
}
