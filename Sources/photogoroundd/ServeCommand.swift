import Foundation
import PhotoGoRoundKit

/// Serves pictures as a named consumer, and reports how long each one took.
///
/// This is what a display does, reduced to a terminal. A precursor to `pgr
/// serve`, and the thing that answers questions no test can: does the queue stay
/// responsive while a refresh runs in another process, does a deleted photo
/// really never appear, does an unplugged drive really keep serving.
struct ServeCommand {
    var environment: MacHostEnvironment
    var consumerName: String
    var count: Int
    var repeatWindowFraction: Double
    var quiet: Bool

    func run() async throws {
        let database = try Database(path: environment.databaseURL.path(percentEncoded: false))
        try Migrator.migrate(database)
        let deck = Deck(database: database)
        let sources = SourceStore(database: database)
        let settings = DeckSettings(repeatWindowFraction: repeatWindowFraction)
        let cache = PhotoCache(
            database: database, root: environment.cacheRoot, sources: sources, deck: deck,
            queueSize: environment.preferences.queueSize)
        let consumer = try deck.register(kind: .commandLine, displayID: consumerName)

        var latencies: [Double] = []
        latencies.reserveCapacity(count)
        var dealt = 0

        for _ in 0..<count {
            let start = ContinuousClock.now

            // Serving is what notices the queue is short, so top up first —
            // the same shape the agent's loop uses.
            if try cache.queue.needsTopUp() {
                for source in try sources.enabled() {
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
                    suffix: "deal #\(card.dealSeq ?? 0) · \(elapsed.formatted(.number.precision(.fractionLength(1))))ms"
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
        func format(_ value: Double) -> String {
            value.formatted(.number.precision(.fractionLength(1))) + "ms"
        }

        Console.note(
            """
            served \(dealt) pictures as \(consumerName)
              median \(format(percentile(0.5)))  p95 \(format(percentile(0.95)))  \
            max \(format(sorted.last!))
            """
        )
    }
}

extension Duration {
    var totalSeconds: Double {
        let (whole, attoseconds) = components
        return Double(whole) + Double(attoseconds) / 1e18
    }
}
