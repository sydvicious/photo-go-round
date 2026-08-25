import Foundation
import Testing

@testable import PhotoGoRoundKit

/// How much to deal after a picture is served, which is not the same question as
/// how the filler deals.
///
/// **These exist because a test at the wrong layer passed.** `QueueFiller.fill`
/// has always topped up to whatever target it was given, and a test of it was
/// green throughout. The defect was in what the agent *asked for* — one card per
/// picture served, which can hold a depth but can never raise one — so raising
/// `queueSize` left a live queue pinned at its old size while lowering it worked
/// fine. Nothing at the filler's own level could have caught that.
@Suite("Topping the queue up after a picture is served")
struct QueueTopUpTests {

    /// A queue and a supply of cards, shared with the `@Sendable` closures the
    /// filler takes.
    private final class Table: @unchecked Sendable {
        let library: TestLibrary
        let queue: PhotoQueue
        let source: Int64
        private let lock = NSLock()
        private var remaining: [Int64]

        init(photos: Int, nominal: Int) throws {
            library = try TestLibrary()
            source = try library.addSource()
            remaining = try library.addPhotos(photos, to: source)
            queue = PhotoQueue(database: library.database, nominalSize: nominal)
        }

        func deal() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !remaining.isEmpty else { return false }
            let id = remaining.removeFirst()
            return ((try? queue.append(photoID: id, sourceID: source)) ?? false)
        }

        var depth: Int {
            lock.lock()
            defer { lock.unlock() }
            return (try? queue.size()) ?? 0
        }
    }

    /// **Deals exactly one card, the way the first attempt did.** Kept so the
    /// tests below fail against the shape that was wrong rather than merely
    /// passing against the shape that is right.
    private func dealingOnePerPicture(_ table: Table, target: @escaping @Sendable () -> Int)
        -> QueueFiller
    {
        let once = Once()
        return QueueFiller(
            isShort: { !once.spent && table.depth < target() },
            produce: {
                once.spend()
                return table.deal()
            })
    }

    /// One card and no more, per round.
    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var used = false
        var spent: Bool {
            lock.lock()
            defer { lock.unlock() }
            return used
        }
        func spend() {
            lock.lock()
            used = true
            lock.unlock()
        }
    }

    private func toppingUpToTarget(
        _ table: Table, target: @escaping @Sendable () -> Int,
        inFlight: @escaping @Sendable () -> Int = { 0 }
    ) -> QueueFiller {
        QueueFiller(
            isShort: { table.depth + inFlight() < target() }, produce: { table.deal() })
    }

    /// The agent's loop: serve a picture, then top up once.
    private func serveAndTopUp(_ table: Table, times: Int, using filler: () -> QueueFiller) async {
        for _ in 0..<times {
            _ = try? await table.queue.serve()
            await filler().fill()
        }
    }

    @Test("Dealing one card per picture cannot raise the queue to a new target")
    func onePerPictureCannotGrow() async throws {
        let table = try Table(photos: 200, nominal: 10)
        for _ in 0..<10 { _ = table.deal() }
        #expect(table.depth == 10)

        // Twenty pictures served with the target at twenty, and the queue never
        // moves. This is what a live agent did: preference set to 20, queue
        // sitting at 10, a `DEAL:` line after every serve saying "10 queued".
        await serveAndTopUp(table, times: 20) { dealingOnePerPicture(table, target: { 20 }) }
        #expect(table.depth == 10, "one per picture grew the queue; the reproduction is stale")
    }

    @Test("Topping up to the target does raise it")
    func toppingUpGrows() async throws {
        let table = try Table(photos: 200, nominal: 10)
        for _ in 0..<10 { _ = table.deal() }

        await serveAndTopUp(table, times: 20) { toppingUpToTarget(table, target: { 20 }) }
        #expect(table.depth == 20)
    }

    @Test("Lowering the target drains without dealing, which always worked")
    func loweringDrains() async throws {
        let table = try Table(photos: 200, nominal: 30)
        for _ in 0..<30 { _ = table.deal() }

        await serveAndTopUp(table, times: 10) { toppingUpToTarget(table, target: { 20 }) }
        #expect(table.depth == 20)
    }

    @Test("A card out being fetched still counts as the queue's")
    func inFlightCardsCountTowardTheTarget() async throws {
        // The other half, and the reason the fix is not simply "fill to
        // nominal". A skipped card has left the table and is coming back;
        // dealing to cover the gap replaces a card that is about to return, and
        // the queue overshoots by exactly the number of fetches — the churn that
        // pacing the deal to serving exists to remove.
        let table = try Table(photos: 200, nominal: 20)
        for _ in 0..<20 { _ = table.deal() }
        for _ in 0..<5 { _ = try await table.queue.serve() }
        #expect(table.depth == 15)

        await serveAndTopUp(table, times: 1) {
            toppingUpToTarget(table, target: { 20 }, inFlight: { 5 })
        }

        // One picture served, so one card dealt to replace it — and the five in
        // flight are not replaced, because they are coming back.
        #expect(table.depth == 15, "dealt cards to cover fetches that were about to return")
    }
}
