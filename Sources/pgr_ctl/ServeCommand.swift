import Console
import Foundation
import PhotoGoRoundKit

/// Serves pictures as a named consumer, and reports how long each one took.
///
/// This is what a display does, reduced to a terminal, and it is the thing that
/// answers questions no unit test can: does the queue stay responsive while a
/// refresh runs in another process, does a deleted photo really never appear,
/// does an unplugged drive really keep serving from cache. Several of these run
/// at once is also how the queue pop is shown to serialise — run four and assert
/// the union of what they got has no duplicates.
struct ServeCommand {
    var environment: MacHostEnvironment
    var consumerName: String
    var count: Int
    var repeatWindowFraction: Double
    var quiet: Bool

    func run() async throws {
        let context = try Library.context(environment)
        let settings = DeckSettings(repeatWindowFraction: repeatWindowFraction)
        let cache = PhotoCache(
            database: context.database,
            root: environment.cacheRoot,
            settings: context.preferences.cacheSettings,
            sources: context.sources,
            deck: context.deck,
            queueSize: context.preferences.queueSize
        )
        let consumer = try context.deck.register(kind: .commandLine, displayID: consumerName)

        var latencies: [Double] = []
        latencies.reserveCapacity(count)
        var dealt = 0

        for _ in 0..<count {
            let start = ContinuousClock.now

            // Serving is what notices the queue is short, so top up first — the
            // same shape the agent's loop uses. With no agent running this is
            // the only thing filling the queue at all.
            if try cache.queue.needsTopUp() {
                for source in try context.sources.enabled() {
                    _ = try? await cache.produce(forSource: source.id, settings: settings)
                }
            }
            guard let served = try await cache.serve(to: consumer.id) else { break }
            let card = served.card

            let elapsed = (ContinuousClock.now - start).totalSeconds * 1000
            latencies.append(elapsed)
            dealt += 1

            if !quiet {
                Console.change(
                    "▸", card.externalID, .yellow,
                    suffix: "deal #\(card.dealSeq ?? 0) · \(Library.number(elapsed))ms"
                )
            }
        }

        guard !latencies.isEmpty else {
            Console.alert("nothing to serve — the queue is empty and no source offered anything")
            return
        }

        let sorted = latencies.sorted()
        func percentile(_ p: Double) -> Double {
            sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))]
        }
        func format(_ value: Double) -> String { Library.number(value) + "ms" }

        Console.note(
            """
            served \(dealt) pictures as \(consumerName)
              median \(format(percentile(0.5)))  p95 \(format(percentile(0.95)))  \
            max \(format(sorted.last!))
            """
        )
        if dealt < count {
            Console.alert("asked for \(count) and the queue ran dry after \(dealt)")
        }
    }
}
