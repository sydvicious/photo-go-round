// The picture on the pane's item, and the picture shown before the agent answers.
// `Wallpaper Plan.md`, *The real extension, inside the app*.
//
// **A fixed mark, which becomes the app icon.** Syd, 2026-09-15: "the icon in
// system settings is stupid", and then, having considered showing the current
// photograph instead, "actually, don't do it that way. This will match the app
// icon once we have one." So the pane's item is a stable identity rather than a
// changing picture, and what is drawn here is a placeholder until that icon
// exists.
//
// It also has to be something: the pane asks for a thumbnail before any
// photograph has been served, and a wallpaper that spent a card every time
// somebody opened System Settings would empty the queue into a picture nobody
// chose. Drawn in the project's blue and yellow, the axis that survives
// red-green colour blindness.

import CoreGraphics
import CoreText
import Foundation
import ImageIO

enum PaneThumbnail {
    private static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    /// The full-size mark, shown on the desktop until the first photograph
    /// arrives, so the desktop is never blank.
    static let image: CGImage? = draw(width: 1920, height: 1080, title: true)

    /// A PNG in the extension's container, which is where the pane reads it from.
    static let url: URL? = write()


    private static func draw(width: Int, height: Int, title: Bool) -> CGImage? {
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
        guard title else { return context.makeImage() }

        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, CGFloat(height) / 14, nil)
        let text = NSAttributedString(
            string: "Photo-Go-Round",
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

    private static func write() -> URL? {
        guard let small = draw(width: 480, height: 270, title: false),
            let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        else { return nil }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            wallpaperLog("thumbnail: \(folder.path(percentEncoded: false)) could not be made: \(error)")
            return nil
        }
        let url = folder.appending(path: "photo-go-round-thumbnail.png")
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, small, nil)
        return CGImageDestinationFinalize(destination) ? url : nil
    }
}
