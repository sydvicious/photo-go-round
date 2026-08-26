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

    /// A topic. Half a dozen of these is the whole protocol.
    public enum Topic: String, Sendable, CaseIterable {
        /// A preference changed, from `pgr set` or from a raw `defaults write`.
        case preferencesChanged = "prefs"
        /// A card was played; the deck moved.
        case deckAdvanced = "deck"
        /// Sources were added, removed, enabled, or rescanned.
        case sourcesChanged = "sources"
        /// The cache filled, evicted, or was cleared.
        case cacheChanged = "cache"
    }

    /// The doorbells for one library.
    ///
    /// **`notify_post` is scoped to nothing.** It broadcasts machine-wide on a
    /// name alone — no container, no user, no port — so every process on the Mac
    /// listening for `com.sydpolk.photogoround.sources` hears every other one
    /// ring it. With a fixed name that means a development agent, a production
    /// agent, and a test agent with a throwaway database all ring each other's
    /// bells while agreeing about nothing else.
    ///
    /// Observed 2026-08-25: running the test suite made the development agent
    /// re-enumerate all eleven of its sources three times in five minutes,
    /// because scratch agents on temporary databases were announcing changes to
    /// libraries it had never seen.
    ///
    /// **The database is the key**, not the container: the container can be
    /// pointed one way and `PGR_DATABASE` another, and the library a process
    /// belongs to is the one it has open. Two processes agreeing on the database
    /// are exactly the two that should hear each other.
    public struct Doorbells: Sendable, Equatable {
        public let namespace: String

        public init(database: URL) {
            self.namespace = Self.namespace(
                for: database.standardizedFileURL.path(percentEncoded: false))
        }

        /// For a caller that has a namespace already — the tests, mostly.
        public init(namespace: String) { self.namespace = namespace }

        public func name(_ topic: Topic) -> String {
            "com.sydpolk.photogoround.\(namespace).\(topic.rawValue)"
        }

        /// Rings the bell. Cheap, and safe to call when nobody is listening.
        public func post(_ topic: Topic) {
            let name = name(topic)
            let status = notify_post(name)
            if status != NOTIFY_STATUS_OK {
                Log.prefs.error(
                    "could not post \(name, privacy: .public): status \(status, privacy: .public)"
                )
            }
        }

        /// Listens for a topic. Cancels itself when the returned token is released.
        public func observe(
            _ topic: Topic,
            on queue: DispatchQueue = .main,
            handler: @escaping @Sendable () -> Void
        ) -> Observation? {
            var token: Int32 = NOTIFY_TOKEN_INVALID
            let name = name(topic)
            let status = notify_register_dispatch(name, &token, queue) { _ in handler() }
            guard status == NOTIFY_STATUS_OK else {
                Log.prefs.error(
                    "could not observe \(name, privacy: .public): status \(status, privacy: .public)"
                )
                return nil
            }
            return Observation(token: token)
        }

        /// FNV-1a, because the hash has to be **identical in every process and
        /// every run**. `Hasher` is seeded per process and would give each
        /// participant its own private set of bells. Hand-written rather than
        /// reached for: this is a dozen lines and a dependency is not.
        static func namespace(for path: String) -> String {
            var hash: UInt64 = 0xcbf2_9ce4_8422_2325
            for byte in path.utf8 {
                hash ^= UInt64(byte)
                hash = hash &* 0x0000_0100_0000_01b3
            }
            return String(hash, radix: 16)
        }
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
