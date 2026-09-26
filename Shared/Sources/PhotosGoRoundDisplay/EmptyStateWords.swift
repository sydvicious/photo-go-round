#if canImport(AppKit)

import AppKit
import CoreText

/// How the empty state's words are set — shared by the view that bounces them
/// in the window and the screensaver, and the still the wallpaper shows.
///
/// **The wallpaper cannot draw; it hands the pane finished pictures.** So its
/// empty state is a picture of the words, made here by the same rule the view
/// follows, which keeps the three surfaces from drifting apart. Syd,
/// 2026-09-26: "for wallpaper and screensaver, can you generate an image and
/// give it to them rather than direct drawing?" — the screensaver kept its
/// drawing, which moves, and the wallpaper is still anyway.
public enum EmptyStateWords {

    /// How wide the words are made in a view this wide: **80% of it, whatever
    /// its size.**
    ///
    /// Syd, 2026-09-26: "Size it to fill the image size if the image size is
    /// small, like for previews in wallpapers and screensavers." **But no
    /// preview is small to the code.** The Screen Saver pane's is an ordinary
    /// 1800-point instance shrunk into the pane, and the Wallpaper pane's is
    /// the desktop's picture shrunk — so a rule for small views never reached
    /// either, and at the 55% the words had until then they arrived as thin
    /// text nine or ten points high. The only lever is the share everywhere,
    /// and Syd chose 80% over leaving it. Full screen gets larger words, and
    /// the bounce less room across; `font(for:in:)`'s cap at a fifth of the
    /// height still holds, so a short line like *Starting…* stops there first.
    static func targetWidth(in width: CGFloat) -> CGFloat {
        width * 0.8
    }

    /// The largest thin system font at which `line` fits `targetWidth(in:)` of
    /// `size`, and no taller than a fifth of it so it cannot swallow the view
    /// vertically either. **No floor**: the 16-point floor there was until
    /// 2026-09-26 could only ever push words past the edges of a view too small
    /// to hold them.
    static func font(for line: String, in size: CGSize) -> NSFont {
        let width = targetWidth(in: size.width)
        let cap = size.height / 5
        let probe = NSFont.systemFont(ofSize: 100, weight: .thin)
        let measured = Self.width(of: line, in: probe)
        guard measured > 0, width > 0, cap > 0 else { return NSFont.systemFont(ofSize: 24, weight: .thin) }
        let scaled = 100 * width / measured
        return NSFont.systemFont(ofSize: max(1, min(scaled, cap)), weight: .thin)
    }

    /// The words, white and centred on black, as a picture `pixels` in size.
    ///
    /// **In pixels, at a scale of one**, since that is what the wallpaper asks
    /// the agent for and what the pane is given. CoreText rather than AppKit's
    /// string drawing, because the wallpaper makes this on a URL session's
    /// queue and not on the main thread.
    public static func still(_ words: String, pixels: CGSize) -> CGImage? {
        let width = Int(pixels.width.rounded()), height = Int(pixels.height.rounded())
        guard width > 0, height > 0,
            let space = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        // Black, as the view's letterbox is: genuinely black on OLED and XDR.
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        let font = font(for: words, in: pixels)
        let line = Self.line(words, in: font, color: CGColor(gray: 1, alpha: 1))
        let bounds = CTLineGetBoundsWithOptions(line, [])
        context.textPosition = CGPoint(
            x: (pixels.width - bounds.width) / 2 - bounds.minX,
            y: (pixels.height - bounds.height) / 2 - bounds.minY)
        CTLineDraw(line, context)
        return context.makeImage()
    }

    private static func line(_ text: String, in font: NSFont, color: CGColor? = nil) -> CTLine {
        var attributes: [NSAttributedString.Key: Any] = [.font: font]
        // CoreText's own key: it reads a `CGColor` there, and not AppKit's.
        if let color { attributes[NSAttributedString.Key(kCTForegroundColorAttributeName as String)] = color }
        return CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
    }

    private static func width(of text: String, in font: NSFont) -> CGFloat {
        CTLineGetBoundsWithOptions(line(text, in: font), []).width
    }
}

#endif
