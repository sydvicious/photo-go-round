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
}
