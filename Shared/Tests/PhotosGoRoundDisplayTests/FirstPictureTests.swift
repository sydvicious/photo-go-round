import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import PhotosGoRoundAgentAPI
@testable import PhotosGoRoundDisplay

/// A surface's first picture of a session.
///
/// **Written 2026-09-23, after a screensaver started a minute after a reboot
/// showed nothing for 75 seconds.** It gave up on a cold agent at five seconds,
/// seven times running, and had nothing of its own to put up meanwhile. Two
/// things answer that: the first request waits longer, and the surface opens
/// with the picture its last session left.
@Suite("A surface's first picture")
@MainActor
struct FirstPictureTests {

    /// Records whether each request was patient, and answers as told.
    private final class Recorder: PictureSource, @unchecked Sendable {
        enum Answer {
            case picture(Data)
            case failure(PictureClient.Failure)
            case never
        }

        private let lock = NSLock()
        private var answer: Answer
        private var asked: [Bool] = []

        init(_ answer: Answer) { self.answer = answer }

        var patience: [Bool] { lock.withLock { asked } }

        func answers(_ next: Answer) { lock.withLock { answer = next } }

        func next(
            consumer: String, displayID: String?, fitting box: PixelSize?
        ) async throws -> ServedPicture? {
            try await next(consumer: consumer, displayID: displayID, fitting: box, patient: false)
        }

        func next(
            consumer: String, displayID: String?, fitting box: PixelSize?, patient: Bool
        ) async throws -> ServedPicture? {
            let answer = lock.withLock { () -> Answer in
                asked.append(patient)
                return self.answer
            }
            switch answer {
            case .picture(let data): return ServedPicture(data: data, contentType: "image/png", card: 7)
            case .failure(let failure): throw failure
            case .never:
                try await Task.sleep(for: .seconds(300))
                return nil
            }
        }
    }

    private static func png(width: Int = 4, height: Int = 3) throws -> Data {
        let context = try #require(
            CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())
        let bytes = NSMutableData()
        let destination = try #require(
            CGImageDestinationCreateWithData(bytes, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return bytes as Data
    }

    private static func image(width: Int = 40, height: Int = 30) throws -> CGImage {
        let data = try png(width: width, height: height)
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        return try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    private static func scratchDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "FirstPictureTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    private static func shuffle(_ source: some PictureSource, memory: PictureMemory? = nil) -> Shuffle {
        Shuffle(
            source: source, consumer: "test", dwellFrom: { .milliseconds(20) },
            whenEmpty: .milliseconds(20), whenAbsent: .milliseconds(20), memory: memory)
    }

    /// Waits for something to become true, rather than sleeping a guess.
    private static func until(
        _ reached: @MainActor () -> Bool, _ what: String, within limit: Duration = .seconds(10)
    ) async throws {
        let deadline = ContinuousClock.now + limit
        while ContinuousClock.now < deadline {
            if reached() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("\(what) did not happen within \(limit)")
    }

    // MARK: - Patience

    @Test("The first request of a run is patient, and the ones after an answer are not")
    func patientUntilAnswered() async throws {
        let source = Recorder(.picture(try Self.png()))
        let shuffle = Self.shuffle(source)
        shuffle.draws(at: PixelSize(width: 100, height: 100), on: nil)
        try await Self.until({ source.patience.count >= 3 }, "three requests")
        shuffle.stop()

        let asked = source.patience
        #expect(asked.first == true)
        #expect(asked.dropFirst().allSatisfy { !$0 })
    }

    /// An agent that is not yet listening fails at once; the request that
    /// finally reaches it is the one that needs the patience.
    @Test("A failure leaves the next request patient")
    func patientThroughFailures() async throws {
        let source = Recorder(.failure(.unreachable(port: 1, reason: "refused")))
        let shuffle = Self.shuffle(source)
        shuffle.draws(at: PixelSize(width: 100, height: 100), on: nil)
        try await Self.until({ source.patience.count >= 3 }, "three failed requests")
        shuffle.stop()

        #expect(source.patience.allSatisfy { $0 })
    }

    @Test("A new run is patient again")
    func patientAfterRestart() async throws {
        let source = Recorder(.picture(try Self.png()))
        let shuffle = Self.shuffle(source)
        shuffle.draws(at: PixelSize(width: 100, height: 100), on: nil)
        try await Self.until({ source.patience.count >= 2 }, "two requests")
        shuffle.stop()
        try await Task.sleep(for: .milliseconds(100))
        let before = source.patience.count

        shuffle.draws(at: PixelSize(width: 100, height: 100), on: nil)
        try await Self.until({ source.patience.count > before }, "a request after the restart")
        shuffle.stop()

        #expect(source.patience[before] == true)
    }

    // MARK: - The remembered picture

    @Test("A remembered picture comes back with what the agent said about it")
    func memoryRoundTrip() async throws {
        let directory = Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let memory = PictureMemory(directory: directory, key: "37D8832A-2D66")

        try await memory.remember(
            try Self.image(),
            as: ServedPicture(
                data: Data(), contentType: "image/png", card: 8129, deal: 1883, source: 1,
                name: "IMG_5143", sourceName: "Photos › Favorites"))

        let recalled = try #require(await memory.recall())
        #expect(recalled.image.width == 40)
        #expect(recalled.image.height == 30)
        #expect(recalled.picture.card == 8129)
        #expect(recalled.picture.deal == 1883)
        #expect(recalled.picture.name == "IMG_5143")
        #expect(recalled.picture.sourceName == "Photos › Favorites")
        #expect(recalled.picture.contentType == "image/heic")
    }

    @Test("Nothing remembered, or something unreadable, is no picture")
    func memoryAbsentOrDamaged() async throws {
        let directory = Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let memory = PictureMemory(directory: directory, key: "A")
        #expect(await memory.recall() == nil)

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not a picture".utf8).write(
            to: directory.appending(path: PictureMemory.fileName(for: "A") + ".heic"))
        #expect(await memory.recall() == nil)
    }

    @Test("Each display remembers its own picture")
    func memoryIsPerDisplay() {
        #expect(PictureMemory.fileName(for: "one") != PictureMemory.fileName(for: "two"))
        #expect(PictureMemory.fileName(for: "../evil") == "last-___evil")
    }

    /// **The point of it.** An agent that has not answered yet does not keep
    /// the screen empty.
    @Test("A surface opens with the remembered picture while the agent is silent")
    func opensWithRemembered() async throws {
        let directory = Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let memory = PictureMemory(directory: directory, key: "display")
        try await memory.remember(
            try Self.image(), as: ServedPicture(data: Data(), contentType: "image/png", card: 42))

        let shuffle = Self.shuffle(Recorder(.never), memory: memory)
        shuffle.draws(at: PixelSize(width: 100, height: 100), on: "display")
        try await Self.until({ shuffle.shown != nil }, "the remembered picture going up")
        shuffle.stop()

        #expect(shuffle.shown?.remembered == true)
        #expect(shuffle.shown?.picture.card == 42)
    }

    /// Answers that there is nothing to show, every time.
    private final class Nothing: PictureSource, Sendable {
        func next(
            consumer: String, displayID: String?, fitting box: PixelSize?
        ) async throws -> ServedPicture? { nil }

        func answer(
            consumer: String, displayID: String?, fitting box: PixelSize?, patient: Bool
        ) async throws -> PictureAnswer { .noSources }
    }

    /// Syd, 2026-09-26: a screensaver starting after a reboot must not put up a
    /// photograph that can no longer be served while a cold agent starts.
    @Test("Nothing to show forgets the remembered picture")
    func nothingToShowForgets() async throws {
        let directory = Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let memory = PictureMemory(directory: directory, key: "display")
        try await memory.remember(
            try Self.image(), as: ServedPicture(data: Data(), contentType: "image/png", card: 42))

        let shuffle = Self.shuffle(Nothing(), memory: memory)
        shuffle.draws(at: PixelSize(width: 100, height: 100), on: "display")
        try await Self.until({ shuffle.trouble == .noSources }, "no sources being said")
        shuffle.stop()

        var remembered = true
        let deadline = ContinuousClock.now + .seconds(10)
        while remembered, ContinuousClock.now < deadline {
            remembered = await memory.recall() != nil
            if remembered { try await Task.sleep(for: .milliseconds(10)) }
        }
        #expect(!remembered, "the remembered picture outlived no sources")
        #expect(shuffle.shown == nil)
    }

    @Test("A fresh picture is remembered for next time")
    func freshPictureIsRemembered() async throws {
        let directory = Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let memory = PictureMemory(directory: directory, key: "display")

        let shuffle = Self.shuffle(Recorder(.picture(try Self.png())), memory: memory)
        shuffle.draws(at: PixelSize(width: 100, height: 100), on: "display")
        try await Self.until({ shuffle.shown?.remembered == false }, "a fresh picture")
        shuffle.stop()

        var recalled: (image: CGImage, picture: ServedPicture)?
        let deadline = ContinuousClock.now + .seconds(10)
        while recalled == nil, ContinuousClock.now < deadline {
            recalled = await memory.recall()
            if recalled == nil { try await Task.sleep(for: .milliseconds(10)) }
        }
        #expect(recalled?.picture.card == 7)
    }
}
