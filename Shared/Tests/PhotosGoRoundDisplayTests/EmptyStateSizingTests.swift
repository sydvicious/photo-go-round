#if canImport(AppKit)

import CoreGraphics
import Testing

@testable import PhotosGoRoundDisplay

/// How wide the empty state's words are made.
///
/// Syd, 2026-09-26: "Size it to fill the image size if the image size is
/// small, like for previews in wallpapers and screensavers."
@Suite("Sizing the empty state's words")
struct EmptyStateSizingTests {

    /// Syd, 2026-09-26, choosing 80% everywhere: the previews are full-size
    /// views shrunk, so a rule for small views never reached them.
    @Test("The words are 80% of the width at every size")
    func eightyPercentEverywhere() {
        for width in [CGFloat(200), 600, 1800, 6016] {
            #expect(EmptyStateWords.targetWidth(in: width) == width * 0.8)
        }
    }

    /// A short line would grow past the view's height before it reached 80% of
    /// a wide one; the cap at a fifth of the height stops it first.
    @Test("A short line stops at a fifth of the height")
    func shortLineIsCapped() {
        let size = CGSize(width: 1800, height: 1169)
        #expect(EmptyStateWords.font(for: "Starting…", in: size).pointSize <= size.height / 5)
    }

    // MARK: - The wallpaper's still

    /// The first pixel's brightness and the brightest anywhere, read back.
    private static func brightness(of image: CGImage) throws -> (corner: UInt8, brightest: UInt8) {
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = try #require(
            CGContext(
                data: &pixels, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let brightest = stride(from: 0, to: pixels.count, by: 4).map { pixels[$0] }.max() ?? 0
        return (pixels[0], brightest)
    }

    @Test("The still is the size it was asked for, black, with white words on it")
    func stillIsWordsOnBlack() throws {
        let image = try #require(EmptyStateWords.still("Please Add Photos", pixels: CGSize(width: 1920, height: 1080)))

        #expect(image.width == 1920)
        #expect(image.height == 1080)
        let (corner, brightest) = try Self.brightness(of: image)
        #expect(corner == 0, "the background is not black")
        #expect(brightest > 200, "no words were drawn")
    }

    /// A pane preview is a few hundred pixels across; the words must still be
    /// drawn there, not rounded away.
    @Test("A small still still has its words")
    func smallStillHasWords() throws {
        let image = try #require(EmptyStateWords.still("No Photos Available", pixels: CGSize(width: 214, height: 130)))
        #expect(try Self.brightness(of: image).brightest > 100)
    }

    @Test("A still of no size is nothing")
    func emptyStillIsNil() {
        #expect(EmptyStateWords.still("Please Add Photos", pixels: .zero) == nil)
    }
}

/// The words the view draws, as they change.
@Suite("The empty state's words changing")
@MainActor
struct EmptyStateWordsChangeTests {

    /// **Measured on screen 2026-09-26.** The window said *Waiting for Photos*
    /// after the agent had answered *no sources*: the view laid out again only
    /// when its size changed, and the window's had not.
    @Test("New words are drawn at the same size")
    func newWordsAreDrawn() {
        let view = EmptyStateView(frame: CGRect(x: 0, y: 0, width: 800, height: 500))
        view.show(words: "Starting…")
        view.layoutSubtreeIfNeeded()
        #expect(view.drawnWords == "Starting…")

        view.show(words: "Please Add Photos")
        view.layoutSubtreeIfNeeded()
        #expect(view.drawnWords == "Please Add Photos")
    }
}

#endif
