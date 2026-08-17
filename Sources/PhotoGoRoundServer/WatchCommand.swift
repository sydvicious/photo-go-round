import Foundation
import PhotoGoRoundKit

/// Watches a real folder and narrates what the deck does about it.
///
/// This exists to make Phase 1 observable before Phase 2 has a command-line
/// tool and before Phase 3 has a window. Add photos to the folder, remove them,
/// unplug the drive, put them back — and watch the rows appear, vanish, and
/// come back with their deal history intact.
///
/// **It caches nothing.** No bytes are copied anywhere: the cache does not exist
/// yet, and when it does this mode will still be the one that leaves it alone.
/// The only thing on disk besides your photos is the database, and `--database`
/// puts that wherever you want it.
struct WatchCommand {
    var folder: URL
    var databasePath: String
    var interval: Duration
    var recursive: Bool
    var deal: Bool
    var repeatWindowFraction: Double

    func run() async throws {
        let database = try Database(path: databasePath)
        try Migrator.migrate(database)
        let sources = SourceStore(database: database)
        let deck = Deck(database: database)
        let settings = DeckSettings(repeatWindowFraction: repeatWindowFraction)

        let source = try existingSource(in: sources) ?? sources.add(
            kind: .folder,
            locator: folder.standardizedFileURL.path(percentEncoded: false),
            recursive: recursive
        )

        Console.banner(
            """
            watching  \(folder.path(percentEncoded: false))
            database  \(databasePath)
            source    #\(source.id)\(recursive ? ", recursive" : "")
            interval  \(interval.totalSeconds.formatted(.number.precision(.fractionLength(0...1))))s
            caching   none — no bytes are copied anywhere
            """
        )
        Console.note("add or remove photos in that folder and watch. ^C to stop.")

        var lastSummary = ""
        var consumerID: Int64?
        if deal {
            consumerID = try deck.register(
                kind: .commandLine, displayID: "watch", handSize: 4
            ).id
        }

        while !Task.isCancelled {
            let current = try sources.source(id: source.id) ?? source
            let wasAvailable = current.available

            let result = try await sources.scan(current) { change in
                switch change {
                case .added(let id): Console.change("+", id, .green)
                case .returned(let id): Console.change("~", id, .cyan)
                case .vanished(let id): Console.change("-", id, .red)
                }
            }

            if result.sourceUnavailable {
                if wasAvailable {
                    Console.alert("source unavailable: \(result.reason ?? "unknown")")
                    Console.event("photo rows and deal history left untouched")
                }
            } else if !wasAvailable {
                Console.recovered("source is readable again")
            }

            if let consumerID, !result.sourceUnavailable {
                try await dealOne(deck: deck, consumerID: consumerID, settings: settings)
            }

            let stats = try deck.stats(settings: settings)
            let summary = Self.summary(stats)
            if summary != lastSummary {
                Console.summary(summary)
                lastSummary = summary
            }

            try? await Task.sleep(for: interval)
        }
    }

    /// Reuses the source row if this folder has been watched before, so deal
    /// history survives restarting the watcher.
    private func existingSource(in sources: SourceStore) throws -> Source? {
        let wanted = folder.standardizedFileURL.path(percentEncoded: false)
        return try sources.all().first { $0.kind == .folder && $0.locator == wanted }
    }

    private func dealOne(deck: Deck, consumerID: Int64, settings: DeckSettings) async throws {
        let reservation = try deck.reserveHand(for: consumerID, settings: settings)
        for relaxation in reservation.relaxations {
            Console.event("deck relaxed: \(String(describing: relaxation))")
        }
        if reservation.startedNewPass {
            Console.event("deck reshuffled — new pass")
        }
        guard let card = try deck.playNext(for: consumerID) else { return }
        Console.change("▸", card.externalID, .yellow, suffix: "deal #\(card.dealSeq ?? 0)")
    }

    private static func summary(_ stats: DeckStats) -> String {
        """
        \(stats.dealablePhotos) in deck · \(stats.totalPhotos) rows · \
        \(stats.neverDealt) never shown · window \(stats.repeatWindow) · \
        \(stats.unusedInCurrentPass) left in pass
        """
    }
}
