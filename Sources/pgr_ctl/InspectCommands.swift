import Console
import Foundation
import PhotoGoRoundKit

/// Looking at the library: what it holds, what is ready, and what it has been
/// doing.
///
/// None of these change anything, which is why they are grouped together and why
/// none of them ring a doorbell.
enum InspectCommands {

    // MARK: - Everything at once

    /// The one command to run when something is wrong and you do not yet know
    /// what.
    static func status(environment: MacHostEnvironment) throws {
        let context = try Library.context(environment)
        let preferences = context.preferences
        let stats = try context.deck.stats(settings: preferences.deckSettings)
        let cache = try context.cache.status()
        let sources = try context.sources.all()

        Console.banner(
            """
            database   \(environment.databaseURL.path(percentEncoded: false))
            cache      \(environment.cacheRoot.path(percentEncoded: false))
            roots from \(environment.origin.rawValue)
            """
        )
        Console.note(
            "sources    \(sources.count) (\(sources.count { $0.enabled }) enabled, "
                + "\(sources.count { !$0.available }) unavailable)")
        Console.note("pool       \(stats.totalPhotos) photos, \(stats.dealablePhotos) dealable")
        Console.note("queue      \(cache.queued)/\(preferences.queueSize) ready to serve")
        Console.note("cache      \(describeCache(cache))")
        Console.note(
            "shuffle    pass began at \(stats.passStartSeq), \(stats.unusedInCurrentPass) left in it, "
                + "\(stats.currentDealSeq) shown all time")
        Console.note(
            "showings   min \(stats.timesShownMin), max \(stats.timesShownMax), "
                + "\(stats.neverDealt) never shown")
        print()
        Console.note(
            "window \(preferences.deckSettings.repeatWindowFraction)  ·  "
                + "scan every \(Int(preferences.scanInterval.totalSeconds))s  ·  "
                + "top up every \(Int(preferences.queueRefreshInterval.totalSeconds))s  ·  "
                + "\(preferences.downloadConcurrency) fetches per source")

        let events = try context.deck.recentEvents(limit: 5)
        if !events.isEmpty {
            print()
            for event in events {
                Console.note("  \(event.kind): \(event.detail ?? "")")
            }
        }
    }

    /// A cap some libraries can never approach reads like a stalled fetch, so
    /// say what is true instead. A boot-volume library is referenced in place
    /// and never copied: there is nothing to cache, which is not the same fact
    /// as `0/1000 cached`.
    private static func describeCache(_ status: PhotoCache.Status) -> String {
        let bytes = Library.bytes(status.bytesOnDisk)
        guard status.residentCount > 0 || status.pendingCount > 0 else {
            return status.referencedCount > 0
                ? "nothing to cache — \(status.referencedCount) photos are referenced in place"
                : "empty"
        }
        return "\(status.residentCount)/\(status.cap) cached, "
            + "\(status.referencedCount) referenced, \(bytes) on disk"
    }

    // MARK: - Pool

    /// Rows per source, and the two splits that explain everything else: what
    /// is dealable, and what has bytes.
    static func poolStats(environment: MacHostEnvironment) throws {
        let context = try Library.context(environment)
        let sources = try context.sources.all()
        guard !sources.isEmpty else {
            Console.note("no sources, so no pool")
            return
        }

        for source in sources {
            let counts = try context.sources.pool.stats(forSource: source.id)
            var traits = ["\(counts.referenced) referenced", "\(counts.resident) resident"]
            if counts.videos > 0 { traits.append("\(counts.videos) video (never dealt)") }
            // In-flight producers. A handful is normal; a lot means producers
            // are dying mid-fetch, and the claims expire on their own either
            // way — so it is worth seeing rather than worth acting on.
            if counts.claimed > 0 { traits.append("\(counts.claimed) claimed") }
            Console.note(
                "#\(source.id)  \(counts.total) photos  ("
                    + traits.joined(separator: ", ") + ")\n     \(source.locator)")
        }

        let pool = context.sources.pool
        print()
        Console.note("\(try pool.size()) photos in the pool, \(try pool.dealableSize()) from enabled sources")
    }

    // MARK: - Queue

    static func queuePeek(count: Int, environment: MacHostEnvironment) throws {
        let context = try Library.context(environment)
        let ready = try context.cache.queue.peek(count)
        guard !ready.isEmpty else {
            Console.note("queue is empty — nothing has been produced yet")
            return
        }
        for (index, card) in ready.enumerated() {
            Console.note(
                "\(index + 1). \(card.externalID)  [source \(card.sourceID), \(card.storage)]")
        }
        Console.note("\(try context.cache.queue.size()) queued in total")
    }

    /// Asks every enabled source for a picture, synchronously, and says what
    /// each round produced.
    ///
    /// The agent does this on a timer and concurrently. This is the same work
    /// done in one thread so you can watch it happen — and it is the only way to
    /// fill a queue with no agent running.
    static func queueFill(rounds: Int, environment: MacHostEnvironment) async throws {
        let context = try Library.context(environment)
        try context.cache.prepare()

        for round in 1...max(1, rounds) {
            var produced = 0
            for source in try context.sources.enabled() {
                if try await context.cache.produce(
                    forSource: source.id, settings: context.preferences.deckSettings)
                {
                    produced += 1
                }
            }
            Console.note(
                "round \(round): \(produced) produced, \(try context.cache.queue.size()) queued")
            if produced == 0 {
                Console.note("nothing left to offer; stopping")
                break
            }
        }
        environment.announce(.cacheChanged)
    }

    // MARK: - Deck

    /// Where the shuffle stands, and the distribution it has actually produced.
    ///
    /// `times_shown` is a statistic and nothing orders by it, which is exactly
    /// what makes it the honest measure of whether the deck is behaving: a
    /// spread of one to three across a library is a healthy fraction below 1.0,
    /// and a spread of three to four hundred is the starvation bug this deck was
    /// rewritten to remove.
    static func deckStats(environment: MacHostEnvironment) throws {
        let context = try Library.context(environment)
        let stats = try context.deck.stats(settings: context.preferences.deckSettings)

        Console.note("pool          \(stats.dealablePhotos) dealable of \(stats.totalPhotos)")
        Console.note("window        \(stats.repeatWindow) cards "
            + "(fraction \(context.preferences.deckSettings.repeatWindowFraction))")
        Console.note("deal ordinal  \(stats.currentDealSeq)")
        Console.note("pass          began at \(stats.passStartSeq), "
            + "\(stats.unusedInCurrentPass) cards left unused in it")
        Console.note("showings      min \(stats.timesShownMin), max \(stats.timesShownMax), "
            + "\(stats.timesShownTotal) total, \(stats.neverDealt) never shown")
        Console.note("resident      \(stats.residentPhotos) photos have bytes")

        let histogram = try context.deck.showingHistogram()

        if histogram.count > 1 {
            print()
            Console.note("showings   photos")
            let widest = histogram.map(\.photos).max() ?? 1
            for row in histogram {
                let bar = String(repeating: "▪", count: max(1, row.photos * 40 / widest))
                Console.note(
                    "\(String(row.shown).padding(toLength: 8, withPad: " ", startingAt: 0))   "
                        + "\(String(row.photos).padding(toLength: 7, withPad: " ", startingAt: 0)) \(bar)")
            }
        }

        let events = try context.deck.recentEvents(limit: 10)
        if !events.isEmpty {
            print()
            for event in events {
                Console.note("  \(event.at.formatted(date: .omitted, time: .standard))  "
                    + "\(event.kind): \(event.detail ?? "")")
            }
        }
    }

    // MARK: - Cache

    static func cacheStatus(environment: MacHostEnvironment) throws {
        let context = try Library.context(environment)
        let status = try context.cache.status()
        Console.note("resident     \(status.residentCount)/\(status.cap) materialized photos")
        Console.note("referenced   \(status.referencedCount) photos, never copied, no budget")
        Console.note("pending      \(status.pendingCount) materialized photos with no bytes yet")
        Console.note("on disk      \(Library.bytes(status.bytesOnDisk))")
        Console.note("ceiling      \(Library.bytes(context.preferences.cacheSettings.byteCeiling))")
        Console.note("free         \(Library.bytes(status.freeBytesOnVolume)) on the cache volume")
        Console.note("queued       \(status.queued) pictures, none of which can be evicted")
        Console.note("root         \(environment.cacheRoot.path(percentEncoded: false))")
    }

    static func cacheEvict(environment: MacHostEnvironment) throws {
        let context = try Library.context(environment)
        let result = try context.cache.evictIfNeeded()
        guard result.evicted > 0 else {
            Console.note("nothing to evict — the cache is inside its cap and its ceiling")
            return
        }
        Console.recovered(
            "evicted \(result.evicted) photos, freed \(Library.bytes(result.bytesFreed))"
                + (result.protectedFromEviction > 0
                    ? " (\(result.protectedFromEviction) left alone because they are queued)" : ""))
        environment.announce(.cacheChanged)
    }

    /// Discards bytes, never shuffle state.
    ///
    /// Ordinary eviction is incremental, continuous, and invisible. This is the
    /// other thing entirely: everything cleared has to be fetched again, which
    /// for an iCloud-optimized library is tens of gigabytes over a connection
    /// that may be metered. So it states its price before charging it.
    static func cacheClear(
        scope: Options.ClearScope, confirmed: Bool, environment: MacHostEnvironment
    ) throws {
        let context = try Library.context(environment)
        let kitScope: PhotoCache.ClearScope =
            switch scope {
            case .everything: .everything
            case .source(let id): .source(id)
            case .unavailable: .unavailableSources
            }

        let cost = try context.cache.costOfClearing(kitScope)
        guard cost.needingRefetch > 0 || cost.referencedAndFree > 0 else {
            Console.note("nothing cached in that scope")
            return
        }

        Console.note(
            "would discard \(cost.needingRefetch) photos (\(Library.bytes(cost.bytesFreed))), "
                + "all of which must be fetched again")
        if cost.referencedAndFree > 0 {
            Console.note(
                "\(cost.referencedAndFree) referenced photos are in scope and cost nothing to reopen")
        }

        if !confirmed, !cost.costsNothingToRefetch {
            guard isInteractive, askToProceed() else {
                Console.failure("not clearing. Pass --yes if you mean it.")
                throw ExitCode(1)
            }
        }

        let result = try context.cache.clear(kitScope)
        Console.recovered(
            "cleared \(result.cleared) photos, freed \(Library.bytes(result.bytesFreed))"
                + (result.queueCleared > 0 ? ", emptied \(result.queueCleared) queue entries" : ""))
        environment.announce(.cacheChanged)
    }

    private static var isInteractive: Bool { isatty(STDIN_FILENO) == 1 }

    private static func askToProceed() -> Bool {
        print("  proceed? [y/N] ", terminator: "")
        guard let answer = readLine() else { return false }
        return answer.lowercased() == "y" || answer.lowercased() == "yes"
    }
}
