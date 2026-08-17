import Foundation
import notify

/// The doorbell.
///
/// Between our own components the database is the transport and a Darwin
/// notification is the doorbell. There is no HTTP server, no socket, and no XPC:
/// shared state lives in SQLite and every process reads and writes it directly,
/// so there is no message format to design, no serialization, and no process
/// that has to be running for another to make progress.
///
/// A Darwin notification carrying no payload is exactly right for this. It says
/// "go look"; SQLite holds what there is to look at. That also means it can
/// never be mistaken for a transport — nobody can smuggle state into it.
public enum DarwinNotification {

    /// A notification name. Half a dozen of these is the whole protocol.
    public struct Topic: RawRepresentable, Sendable, Hashable {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        public init(_ suffix: String) { self.rawValue = "com.sydpolk.photogoround.\(suffix)" }

        /// A preference changed, from `pgr set` or from a raw `defaults write`.
        public static let preferencesChanged = Topic("prefs")
        /// A card was played; the deck moved.
        public static let deckAdvanced = Topic("deck")
        /// Sources were added, removed, enabled, or rescanned.
        public static let sourcesChanged = Topic("sources")
        /// The cache filled, evicted, or was cleared.
        public static let cacheChanged = Topic("cache")
    }

    /// Rings the bell. Cheap, and safe to call when nobody is listening.
    public static func post(_ topic: Topic) {
        let status = notify_post(topic.rawValue)
        if status != NOTIFY_STATUS_OK {
            Log.prefs.error(
                "could not post \(topic.rawValue, privacy: .public): status \(status, privacy: .public)"
            )
        }
    }

    /// Listens for a topic. Cancels itself when the returned token is released.
    public static func observe(
        _ topic: Topic,
        on queue: DispatchQueue = .main,
        handler: @escaping @Sendable () -> Void
    ) -> Observation? {
        var token: Int32 = NOTIFY_TOKEN_INVALID
        let status = notify_register_dispatch(topic.rawValue, &token, queue) { _ in handler() }
        guard status == NOTIFY_STATUS_OK else {
            Log.prefs.error(
                "could not observe \(topic.rawValue, privacy: .public): status \(status, privacy: .public)"
            )
            return nil
        }
        return Observation(token: token)
    }

    /// Owns a registration. Cancelling is what stops the callback firing, and
    /// letting this go out of scope does it for you.
    public final class Observation: @unchecked Sendable {
        private var token: Int32
        private let lock = NSLock()

        init(token: Int32) { self.token = token }

        public func cancel() {
            lock.lock()
            defer { lock.unlock() }
            guard token != NOTIFY_TOKEN_INVALID else { return }
            notify_cancel(token)
            token = NOTIFY_TOKEN_INVALID
        }

        deinit { cancel() }
    }
}
