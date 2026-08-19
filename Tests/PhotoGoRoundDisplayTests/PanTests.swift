import CoreGraphics
import Testing

@testable import PhotoGoRoundDisplay

@Suite("The pan")
struct PanTests {

    @Test("A photograph relatively wider than the view travels up and down")
    func widePhotoTravelsVertically() throws {
        // 3:2 in 16:10: 33 points of black, which clears the threshold.
        let pan = try #require(Pan.plan(photo: CGSize(width: 3000, height: 2000), in: CGSize(width: 1600, height: 1100)))
        #expect(pan.axis == .vertical)
        #expect(abs(pan.travel - 33.333) < 0.01)
    }

    @Test("A photograph relatively taller than the view travels left and right")
    func tallPhotoTravelsHorizontally() throws {
        let pan = try #require(Pan.plan(photo: CGSize(width: 2000, height: 3000), in: CGSize(width: 1600, height: 1200)))
        #expect(pan.axis == .horizontal)
        #expect(pan.travel == 800)
    }

    @Test("Travel is the letterbox thickness, not the overflow of a fill")
    func travelIsTheBlack() throws {
        let photo = CGSize(width: 2000, height: 3000)
        let bounds = CGSize(width: 1600, height: 1200)
        let pan = try #require(Pan.plan(photo: photo, in: bounds))
        #expect(pan.travel == AspectFit.letterbox(of: photo, in: bounds).width)
    }

    @Test("Matching ratios do not pan at all")
    func noBlackNoPan() {
        #expect(Pan.plan(photo: CGSize(width: 3840, height: 2160), in: CGSize(width: 1920, height: 1080)) == nil)
    }

    @Test("A sliver of black is left alone rather than jittered across")
    func belowThreshold() {
        // 12 points of black, which the plan names as the case that must not
        // manufacture motion.
        let pan = Pan.plan(photo: CGSize(width: 1000, height: 1000), in: CGSize(width: 1000, height: 1012))
        #expect(pan == nil)
    }

    @Test("Speed is constant, so duration follows travel")
    func constantSpeed() throws {
        let short = try #require(Pan.plan(photo: CGSize(width: 2000, height: 3000), in: CGSize(width: 1600, height: 1200)))
        let long = try #require(Pan.plan(photo: CGSize(width: 2000, height: 6000), in: CGSize(width: 1600, height: 1200)))
        #expect(long.travel > short.travel)
        // 10 pt/s either way: the panorama does not streak past.
        #expect(abs(short.duration - Double(short.travel / Pan.speed)) < 0.001)
        #expect(abs(long.duration - Double(long.travel / Pan.speed)) < 0.001)
    }

    @Test("A view with no size yet does not pan")
    func degenerate() {
        #expect(Pan.plan(photo: CGSize(width: 3000, height: 2000), in: .zero) == nil)
    }
}
