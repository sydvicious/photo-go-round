import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

import PhotoGoRoundDisplay
@testable import Photo_Go_Round

/// What the window does when the agent stops answering.
///
/// **The rule being defended is that a picture already on screen is never taken
/// down.** It is the deck's first duty: a stale photograph is a better answer
/// than a blank window, and a person looking at one has no way to tell a slow
/// agent from a broken one — so the trouble is reported *beside* the picture
/// rather than instead of it.
@Suite("The window when the agent goes quiet")
@MainActor
struct ShuffleTests {

    /// A source that answers however a test needs it to, one call at a time.
    private final class Stub: PictureSource, @unchecked Sendable {
        enum Answer {
            case picture(Data)
            case empty
            case failure(PictureClient.Failure)
        }

        private let lock = NSLock()
        private var answer: Answer
        private var calls = 0

        init(_ answer: Answer) { self.answer = answer }

        var callCount: Int { lock.withLock { calls } }

        func answers(_ next: Answer) { lock.withLock { answer = next } }

        func next(
            consumer: String, displayID: String?, fitting box: PixelSize?
        ) async throws -> ServedPicture? {
            let answer = lock.withLock { () -> Answer in
                calls += 1
                return self.answer
            }
            switch answer {
            case .picture(let data):
                return ServedPicture(data: data, contentType: "image/png")
            case .empty:
                return nil
            case .failure(let failure):
                throw failure
            }
        }
    }

    /// One real pixel, encoded — `Shuffle` decodes what it is handed and shows
    /// nothing if the decode fails, so a stub picture has to be a picture.
    private static func onePixelPNG() throws -> Data {
        let space = CGColorSpaceCreateDeviceRGB()
        let context = try #require(
            CGContext(
                data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: 0, green: 0, blue: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        let image = try #require(context.makeImage())
        let bytes = NSMutableData()
        let destination = try #require(
            CGImageDestinationCreateWithData(bytes, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return bytes as Data
    }

    private static func shuffle(_ source: some PictureSource) -> Shuffle {
        Shuffle(
            source: source,
            dwell: .milliseconds(20), whenEmpty: .milliseconds(20),
            whenAbsent: .milliseconds(20))
    }

    /// Waits for something to become true, rather than sleeping a guess.
    ///
    /// **The loop turns every twenty milliseconds and the machine does not
    /// promise to let it.** A fixed sleep long enough to be reliable under load
    /// is far longer than the wait usually needed, and one short enough to be
    /// quick fails whenever something else is running — which is what a fixed
    /// 250 ms here did.
    private static func until(
        _ reached: @MainActor () -> Bool,
        _ what: String,
        within limit: Duration = .seconds(10)
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + limit
        while clock.now < deadline {
            if reached() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("\(what) did not happen within \(limit)")
    }

    // MARK: - The picture stays up

    /// **The whole point.** A window that blanked because the agent went quiet
    /// would be a worse answer than the photograph it already had — and the
    /// screensaver, which links the same loop, would go black mid-session.
    @Test("A picture already showing survives the agent going silent")
    func aShownPictureSurvivesSilence() async throws {
        let source = Stub(.picture(try Self.onePixelPNG()))
        let shuffle = Self.shuffle(source)
        shuffle.draws(at: PixelSize(width: 100, height: 100), on: nil)
        try await Self.until({ shuffle.shown != nil }, "a first picture")
        let shown = try #require(shuffle.shown)

        source.answers(.failure(.silent(port: 9000, limit: .seconds(5))))
        try await Self.until({ shuffle.trouble != nil }, "the silence being noticed")

        // Still the same photograph, not a blank window.
        #expect(shuffle.shown?.picture == shown.picture)
        // The words, not the whole sentence: how `Duration` renders itself is
        // not this test's business.
        #expect(shuffle.trouble?.words == "Not answering")
    }

    /// **Not "No agent".** The agent is running and stuck; the words in the
    /// title bar are what send somebody to look in the right place.
    @Test("Silence is titled as not answering, and an absent agent as no agent")
    func silenceAndAbsenceReadDifferently() async throws {
        let source = Stub(.failure(.silent(port: 9000, limit: .seconds(5))))
        let shuffle = Self.shuffle(source)
        shuffle.draws(at: PixelSize(width: 100, height: 100), on: nil)
        try await Self.until({ shuffle.trouble != nil }, "the silence being noticed")
        #expect(shuffle.trouble?.words == "Not answering")

        source.answers(.failure(.noPortPublished))
        try await Self.until(
            { shuffle.trouble?.words == "No agent" }, "the absence being noticed")
        #expect(shuffle.trouble?.words == "No agent")
    }

    /// Both veil the photograph and name themselves in the title; an empty
    /// library does neither, because nothing is broken.
    @Test("Agent trouble veils the picture, an empty library does not")
    func onlyAgentTroubleVeils() async throws {
        #expect(Shuffle.Trouble.silent("x").isAgentTrouble)
        #expect(Shuffle.Trouble.noAgent("x").isAgentTrouble)
        #expect(!Shuffle.Trouble.noPhotos.isAgentTrouble)
    }

    // MARK: - It keeps asking

    /// A silent agent must not stop the loop: the agent may come back, and
    /// nothing else will notice if this one has given up.
    @Test("The loop keeps asking while the agent is silent, and recovers when it answers")
    func theLoopKeepsAskingAndRecovers() async throws {
        let source = Stub(.failure(.silent(port: 9000, limit: .seconds(5))))
        let shuffle = Self.shuffle(source)
        shuffle.draws(at: PixelSize(width: 100, height: 100), on: nil)
        // It keeps asking rather than giving up after the first silence — the
        // agent may come back, and nothing else is watching for it.
        try await Self.until({ source.callCount > 1 }, "a second ask")

        source.answers(.picture(try Self.onePixelPNG()))
        try await Self.until({ shuffle.shown != nil }, "a picture after recovery")

        #expect(shuffle.trouble == nil)
    }

    /// An empty queue is an ordinary answer — a fresh library says it until the
    /// first downloads land — and must never be reported as the agent's fault.
    @Test("An empty queue is no photos, not a silent agent")
    func emptyIsNotSilent() async throws {
        let source = Stub(.empty)
        let shuffle = Self.shuffle(source)
        shuffle.draws(at: PixelSize(width: 100, height: 100), on: nil)
        try await Self.until({ shuffle.trouble != nil }, "the empty queue being noticed")

        #expect(shuffle.trouble == .noPhotos)
        #expect(shuffle.shown == nil)
    }

    /// Answers empty a fixed number of times and then never answers again, so a
    /// test can hold the loop still at a chosen point in the streak.
    ///
    /// **A stub that simply answers empty for ever cannot make this claim.**
    /// The loop turns every twenty milliseconds, so by the time a poll observes
    /// two empties it may already have had five, and an assertion about *how
    /// many it took* would pass against a `Shuffle` that says so on the first.
    /// Stopping the loop dead at the count under test is what makes the
    /// difference observable.
    private final class Countdown: PictureSource, @unchecked Sendable {
        private let lock = NSLock()
        private var remaining: Int

        init(empties: Int) { remaining = empties }

        /// True once every empty answer has been given and the next ask is the
        /// one being held.
        var spent: Bool { lock.withLock { remaining == 0 } }

        func next(
            consumer: String, displayID: String?, fitting box: PixelSize?
        ) async throws -> ServedPicture? {
            let answer = lock.withLock { () -> Bool in
                guard remaining > 0 else { return false }
                remaining -= 1
                return true
            }
            guard answer else {
                try await Task.sleep(for: .seconds(60))
                return nil
            }
            return nil
        }
    }

    /// **One empty answer is a queue turning over, not an empty library.** The
    /// agent's request drops every cold card it meets, so a request that lands
    /// mid-turnover can walk off the end of the queue and answer `204` while
    /// the fetcher is filling it again. Saying *No Photos Available* for that
    /// and taking it back three seconds later tells somebody nothing true.
    @Test("Two empty answers say nothing")
    func twoEmptyAnswersSayNothing() async throws {
        let source = Countdown(empties: 2)
        let shuffle = Self.shuffle(source)
        shuffle.draws(at: PixelSize(width: 100, height: 100), on: nil)

        // Both empties given, and the third ask is held for the rest of the
        // test — so the streak can never reach three and this is a settled
        // state rather than a moment passed through.
        try await Self.until({ source.spent }, "two empty answers")

        #expect(shuffle.trouble == nil, "two empty answers put the words up")
        #expect(shuffle.shown == nil)
    }

    @Test("Three empty answers in a row say No Photos Available")
    func threeEmptyAnswersSayIt() async throws {
        let source = Countdown(empties: 3)
        let shuffle = Self.shuffle(source)
        shuffle.draws(at: PixelSize(width: 100, height: 100), on: nil)

        try await Self.until({ shuffle.trouble != nil }, "the streak being noticed")

        #expect(shuffle.trouble == .noPhotos)
        #expect(shuffle.trouble?.words == "No Photos Available")
        #expect(shuffle.trouble?.isAgentTrouble == false, "an empty library is not the agent's fault")
    }

    /// The other half of the rule: the words come down on the first picture.
    @Test("A picture after the streak takes the words back down")
    func aPictureClearsTheStreak() async throws {
        let source = Stub(.empty)
        let shuffle = Self.shuffle(source)
        shuffle.draws(at: PixelSize(width: 100, height: 100), on: nil)
        try await Self.until({ shuffle.trouble == .noPhotos }, "the streak being noticed")

        source.answers(.picture(try Self.onePixelPNG()))
        try await Self.until({ shuffle.shown != nil }, "a picture after the streak")

        #expect(shuffle.trouble == nil)
    }
}
