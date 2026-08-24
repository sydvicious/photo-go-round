import AppKit
import CoreGraphics
import Foundation
import ImageIO
import Observation
import PhotoGoRoundDisplay
import PhotoGoRoundKit

/// Asks the agent for a picture, decodes it, and holds the one on screen.
///
/// **A picture already showing is never taken down.** When the queue runs empty
/// or the agent goes away, what is up stays up and the trouble is recorded
/// beside it — the words only appear when there has never been anything to show.
/// Blanking a window because the *next* picture is late would be a worse answer
/// than the stale picture, and the same rule keeps a screensaver from going
/// black mid-session when the cache is cleared under it.
@MainActor
@Observable
final class Shuffle {

    /// The picture on screen, decoded and ready to draw.
    private(set) var shown: Frame?
    /// Why there is nothing new, when there is a reason worth saying. Present
    /// alongside `shown`, which is what lets a stale picture stay up.
    private(set) var trouble: Trouble?

    struct Frame {
        let image: CGImage
        let picture: ServedPicture
        var size: CGSize { CGSize(width: image.width, height: image.height) }
    }

    /// The empty states, of which the wire can distinguish exactly two.
    ///
    /// *The empty state* separates no-sources, sources-that-enumerate-to-nothing,
    /// and cold-start, and all three arrive here as `204` — a client cannot see
    /// the pool, which is the point of the service being the interface. The
    /// fourth is one that section predates: with no agent there is nobody to
    /// answer at all.
    enum Trouble: Equatable {
        case noPhotos
        case noAgent(String)

        /// Bouncing letters are Phase 6's treatment and land with the empty
        /// state proper; this is the words, which is the part that has to be
        /// right first.
        var words: String {
            switch self {
            case .noPhotos: "No photos"
            case .noAgent: "No agent"
            }
        }
    }

    /// How long a picture stays up. Not yet a preference: *Everything
    /// user-settable is a user default* is held back to Beyond 0.1, and a
    /// number nobody has looked at yet is not worth a key.
    static let dwell = Duration.seconds(10)
    /// A cold start answers `204` until the first downloads land, so this is
    /// how quickly a fresh library starts showing something.
    private static let whenEmpty = Duration.seconds(3)
    /// Longer, because a missing agent is not going to fix itself in a tick and
    /// hammering a closed port helps nobody.
    private static let whenAbsent = Duration.seconds(5)
    /// A picture that will not decode costs this much before the next is asked
    /// for — enough that a library of broken files cannot spin.
    private static let whenUndecodable = Duration.milliseconds(250)

    private let source: PictureSource
    /// The size the view is about to draw at, in pixels. Nothing is asked for
    /// until the view has laid out once and said what it is.
    private var box: PixelSize?
    private var displayID: String?
    private var loop: Task<Void, Never>?

    init(source: PictureSource) {
        self.source = source
    }

    /// The ordinary case: the agent this checkout's development runs talk to.
    ///
    /// `MacHostEnvironment` is asked for its preferences rather than a domain
    /// being spelled here, so the app and the agent cannot disagree about which
    /// deployment they are in — including when `PGR_PREFS_SUITE` moves it.
    convenience init() {
        let environment = MacHostEnvironment(deployment: .development)
        self.init(source: PictureClient(preferences: environment.preferences))
    }

    /// The view saying how big it is, in pixels, and which screen it is on.
    ///
    /// Asking at the size actually being drawn is the whole point of the
    /// endpoint taking a box. A resize does not fetch a new picture — that
    /// would spend a card on a window drag — so the one on screen is scaled
    /// until the next arrives at the new size.
    func draws(at pixels: PixelSize, on screen: NSScreen?) {
        guard pixels.width > 0, pixels.height > 0 else { return }
        box = pixels
        displayID = Self.identifier(of: screen)
        if loop == nil { begin() }
    }

    private func begin() {
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let wait = await self.advance()
                try? await Task.sleep(for: wait)
            }
        }
    }

    /// One picture, and how long to wait before the next.
    private func advance() async -> Duration {
        guard let box else { return Self.whenEmpty }
        do {
            guard let picture = try await source.next(
                consumer: "app", displayID: displayID, fitting: box)
            else {
                trouble = .noPhotos
                return Self.whenEmpty
            }
            guard let image = await Self.decode(picture.data) else {
                // The service skips a photograph that will not render and
                // retires it after three tries; this is the same failure on
                // our side of the wire, and the answer is the same — ask for
                // another rather than show nothing.
                return Self.whenUndecodable
            }
            shown = Frame(image: image, picture: picture)
            trouble = nil
            return Self.dwell
        } catch let failure as PictureClient.Failure {
            trouble = .noAgent(Self.explain(failure))
            return Self.whenAbsent
        } catch {
            trouble = .noAgent(error.localizedDescription)
            return Self.whenAbsent
        }
    }

    private static func explain(_ failure: PictureClient.Failure) -> String {
        switch failure {
        case .noPortPublished:
            "nothing has published a port — the agent is not running"
        case .unreachable(let port, let reason):
            "nothing is listening on \(port) — \(reason)"
        case .refused(let status):
            "the service answered \(status)"
        }
    }

    /// `CGImage` is immutable once made and safe to read from anywhere, which
    /// the compiler has no way to know. The box says so once, here, rather than
    /// at every hop.
    private struct Decoded: @unchecked Sendable {
        let image: CGImage
    }

    /// Off the main thread, because a decode during a pan is exactly the moment
    /// a stutter would be noticed.
    private static func decode(_ data: Data) async -> CGImage? {
        await Task.detached(priority: .userInitiated) { () -> Decoded? in
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
            else { return nil }
            return Decoded(image: image)
        }.value?.image
    }

    /// `CGDisplayCreateUUIDFromDisplayID`, which survives reboots and cable
    /// swaps where the transient `CGDirectDisplayID` does not — so a monitor is
    /// one consumer rather than a new row every time it wakes.
    private static func identifier(of screen: NSScreen?) -> String? {
        guard
            let number = screen?.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
            let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue()
        else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }
}
