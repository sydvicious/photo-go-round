import Foundation
import PhotoGoRoundKit

/// A connection that lives on a thread of its own, and the only way to reach it.
///
/// **`Database` is deliberately not `Sendable`** — the kit's rule is one
/// connection per isolation domain, and multi-thread access is avoided rather
/// than locked around. This gives a connection a domain of its own: a serial
/// queue that owns it, and an `async` door that hops onto that queue and comes
/// back with the answer.
///
/// **Why it exists is the blocking, not the isolation.** Talking to SQLite means
/// waiting sometimes — for the single writer under WAL, or for a page to come
/// off disk — and waiting means occupying a thread. On the cooperative pool
/// those threads number about as many as the machine has cores, and they are
/// what every other `async` operation in the process needs in order to run at
/// all. A handful of contended transactions there is enough to stall serving,
/// caching and refreshing at once, which is how a single picture request came to
/// take 122 seconds on 2026-08-25.
///
/// Here the waiting happens on a thread this type owns and nothing else wants.
/// The pool keeps its threads, the caller merely suspends, and the kit's
/// synchronous API stays synchronous — which is the point. `RunCommand`'s own
/// header says the kit has no opinion about when it is called and that
/// everything here is scheduling. Which thread runs a query is scheduling.
final class ConfinedDatabase: @unchecked Sendable {
    /// Serial, so the connection is only ever touched by one thread at a time —
    /// which is the guarantee `Database` asks for and does not enforce.
    private let queue: DispatchQueue
    /// Reachable only from `queue`. Never handed out, never captured elsewhere.
    private let database: Database

    init(path: String, label: String) throws {
        queue = DispatchQueue(label: "com.sydpolk.photogoround.\(label)", qos: .utility)
        database = try Database(path: path)
    }

    /// Runs `body` against the connection and returns what it produced.
    ///
    /// `body` is synchronous on purpose. Awaiting inside it would hold SQLite's
    /// single writer across a suspension of unbounded length, which is the one
    /// deadlock this project would least enjoy finding.
    func run<T: Sendable>(_ body: @escaping @Sendable (Database) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    continuation.resume(returning: try body(self.database))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
