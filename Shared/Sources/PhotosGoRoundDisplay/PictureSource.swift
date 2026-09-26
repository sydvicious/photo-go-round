import Foundation

/// Asking for a picture, with the transport left open.
///
/// There is one implementation today — `PictureClient`, over HTTP to the Mac
/// agent — and the seam exists because Phase 4 already knows about a second.
/// *The iOS family* rejects a local HTTP server on iOS for a reason that still
/// holds, so iOS is service-and-client in one process talking to itself. That
/// is a different transport under the same question, and the retry policy above
/// it should be written once rather than four times.
///
/// It also lets a window be driven by a stub, which is the only way to see an
/// empty state without emptying a library.
public protocol PictureSource: Sendable {
    /// The next picture, or `nil` when the queue is empty.
    ///
    /// **`nil` is an ordinary answer rather than an error.** A fresh library
    /// replies this way until the agent has produced something, and so does a
    /// small one asked faster than it can refill. Only a service that cannot be
    /// reached at all throws.
    ///
    /// - Parameter box: the size the caller is about to draw at, in pixels. Both
    ///   numbers are maximums and neither is a target: what comes back is the
    ///   largest that fits inside them with its aspect ratio intact, and nothing
    ///   is ever enlarged. `nil` asks for the original bytes untouched.
    func next(
        consumer: String, displayID: String?, fitting box: PixelSize?
    ) async throws -> ServedPicture?

    /// The same, with `patient` saying whether the caller can afford to wait
    /// longer than usual — true until the agent has answered it once. See
    /// `ServiceTiming.firstPictureReadLimit`.
    func next(
        consumer: String, displayID: String?, fitting box: PixelSize?, patient: Bool
    ) async throws -> ServedPicture?

    /// The same again, with an empty answer saying why when the agent knows.
    ///
    /// **This is what a surface asks; `next` is what a stub finds easiest to
    /// write.** A source that implements only `next` answers every empty queue
    /// as plain `.empty`, which is what it always meant.
    func answer(
        consumer: String, displayID: String?, fitting box: PixelSize?, patient: Bool
    ) async throws -> PictureAnswer
}

/// What one ask comes back with.
public enum PictureAnswer: Sendable, Equatable {
    case picture(ServedPicture)
    /// Nothing right now. A queue turning over says this, and so does a
    /// library with nothing in it; only a streak of them tells the two apart.
    case empty
    /// Nothing, because no source is enabled — which the agent knows outright,
    /// so one answer is enough to say it. See `EmptyReason`.
    case noSources
    /// Nothing, and nothing coming: every source is scanned or offline, and
    /// none has a photograph that could be shown. Also known outright.
    case noPhotos
}

extension PictureSource {
    /// A source with only one speed ignores the difference.
    public func next(
        consumer: String, displayID: String?, fitting box: PixelSize?, patient: Bool
    ) async throws -> ServedPicture? {
        try await next(consumer: consumer, displayID: displayID, fitting: box)
    }

    /// A source that cannot say why it is empty never says so.
    public func answer(
        consumer: String, displayID: String?, fitting box: PixelSize?, patient: Bool
    ) async throws -> PictureAnswer {
        try await next(consumer: consumer, displayID: displayID, fitting: box, patient: patient)
            .map(PictureAnswer.picture) ?? .empty
    }
}
