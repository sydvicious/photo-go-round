import Foundation
import PhotosGoRoundKit

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
///
/// **An actor with a queue of its own since 2026-09-17**, where it was a class
/// around a `DispatchQueue` and a continuation. `PhotoCache.deal` became
/// `async` when `PhotoStore` became an actor — Syd: "I flatout don't want
/// NSLocks", and "I don't mind everything being async; I prefer it" — and a
/// synchronous body could no longer call it. The executor is the same serial
/// queue it always was, so the connection is still touched by one thread at a
/// time, and the package's `NonisolatedNonsendingByDefault` keeps the work on
/// that thread across the awaits inside it.
actor ConfinedDatabase {
    /// Serial, so the connection is only ever touched by one thread at a time —
    /// which is the guarantee `Database` asks for and does not enforce.
    private let queue: DispatchSerialQueue
    /// Reachable only from this actor. Never handed out, never captured
    /// elsewhere.
    private let database: Database

    nonisolated var unownedExecutor: UnownedSerialExecutor {
        queue.asUnownedSerialExecutor()
    }

    init(path: String, label: String) throws {
        queue = DispatchSerialQueue(label: "com.sydpolk.photosgoround.\(label)", qos: .utility)
        database = try Database(path: path)
    }

    /// Runs `body` against the connection and returns what it produced.
    ///
    /// **What it must not do is suspend on something unbounded** while holding
    /// SQLite's single writer — awaiting the byte index is bounded and fine;
    /// awaiting a network fetch would not be.
    func run<T: Sendable>(_ body: (Database) async throws -> T) async throws -> T {
        try await body(database)
    }
}
