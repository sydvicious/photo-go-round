import CoreGraphics
import Testing

@testable import PhotoGoRoundDisplay

@Suite("Fitting a photograph to a view")
struct AspectFitTests {

    @Test("A photograph wider than the view fits its width and leaves black above and below")
    func wideIntoNarrower() {
        // 3:2 into 16:10 is width-limited: 1600 wide, 1066.6 tall, so 33 points
        // of black split between the top and the bottom.
        let fitted = AspectFit.size(of: CGSize(width: 3000, height: 2000), in: CGSize(width: 1600, height: 1100))
        #expect(fitted.width == 1600)
        #expect(abs(fitted.height - 1066.666) < 0.01)
    }

    @Test("A photograph taller than the view fits its height and leaves black at the sides")
    func tallIntoWider() {
        let fitted = AspectFit.size(of: CGSize(width: 2000, height: 3000), in: CGSize(width: 1600, height: 1200))
        #expect(fitted.height == 1200)
        #expect(fitted.width == 800)
    }

    @Test("A photograph smaller than the view is enlarged, which the service would not do")
    func smallIsEnlarged() {
        let fitted = AspectFit.size(of: CGSize(width: 640, height: 480), in: CGSize(width: 2560, height: 1920))
        #expect(fitted.width == 2560)
        #expect(fitted.height == 1920)
    }

    @Test("Matching ratios fill the view exactly, with no black on either axis")
    func exactRatio() {
        let bounds = CGSize(width: 1920, height: 1080)
        #expect(AspectFit.size(of: CGSize(width: 3840, height: 2160), in: bounds) == bounds)
        #expect(AspectFit.letterbox(of: CGSize(width: 3840, height: 2160), in: bounds) == .zero)
    }

    @Test("The fitted rectangle is centred")
    func centred() {
        let rect = AspectFit.rect(of: CGSize(width: 2000, height: 3000), in: CGSize(width: 1600, height: 1200))
        #expect(rect.width == 800)
        #expect(rect.origin.x == 400)
        #expect(rect.origin.y == 0)
    }

    @Test("Only one axis ever carries black")
    func oneAxisOnly() {
        let black = AspectFit.letterbox(of: CGSize(width: 3000, height: 2000), in: CGSize(width: 1600, height: 1100))
        #expect(black.width == 0)
        #expect(black.height > 0)
    }

    /// A view is zero-sized before its first layout, and a photograph whose
    /// pixel size could not be read is zero too. Neither should be arithmetic
    /// on a divide by zero.
    @Test("Degenerate sizes fit to nothing rather than dividing by zero", arguments: [
        (CGSize(width: 0, height: 100), CGSize(width: 100, height: 100)),
        (CGSize(width: 100, height: 0), CGSize(width: 100, height: 100)),
        (CGSize(width: 100, height: 100), CGSize(width: 0, height: 100)),
        (CGSize(width: 100, height: 100), CGSize(width: 100, height: 0)),
    ])
    func degenerate(photo: CGSize, bounds: CGSize) {
        #expect(AspectFit.size(of: photo, in: bounds) == .zero)
        #expect(AspectFit.letterbox(of: photo, in: bounds) == .zero)
    }
}
