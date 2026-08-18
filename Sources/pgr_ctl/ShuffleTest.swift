import Console
import Foundation
import PhotoGoRoundKit

/// The statistical assertions, which are the thing a command line can do that a
/// window cannot.
///
/// "Does this feel random?" is not a question a GUI can answer. *Deal fifty
/// thousand cards across four thousand photos and assert every pass contains
/// every photo exactly once, then report the distribution of gaps between
/// consecutive showings of the same photo* is a question this answers in a
/// script, in a second, repeatably. Being unshipped does not make it a scratch
/// script: these are the project's real correctness checks for the deck, and
/// they exit non-zero so CI can run them exactly as a person does.
///
/// **It never touches your library.** The rig is a throwaway folder of empty
/// files and an in-memory database, built and discarded per run — because fifty
/// thousand deals against the real deck would leave the rotation somewhere
/// nobody asked for, and because a test that depends on what happens to be in
/// your Pictures folder asserts nothing.
enum ShuffleTest {

    static func run(photos: Int, deals: Int, fraction: Double) async throws {
        let settings = DeckSettings(repeatWindowFraction: fraction)
        let directory = URL.temporaryDirectory.appending(
            path: "pgr-shuffle-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        Console.banner(
            """
            \(photos) photos · \(deals) deals · window fraction \(fraction)
            throwaway library at \(directory.path(percentEncoded: false))
            """
        )

        let (deck, sourceID) = try await buildLibrary(photos: photos, at: directory)
        let pool = try deck.poolSize()
        guard pool == photos else {
            Console.failure("built \(photos) files but the pool holds \(pool)")
            throw ExitCode(1)
        }

        let started = ContinuousClock.now
        let sequence = try deal(deck: deck, source: sourceID, count: deals, settings: settings)
        let elapsed = (ContinuousClock.now - started).totalSeconds

        guard sequence.count == deals else {
            Console.failure("asked for \(deals) cards and the deck offered \(sequence.count)")
            throw ExitCode(1)
        }
        Console.note(
            "dealt \(deals) cards in \(Library.number(elapsed, places: 2))s "
                + "(\(Library.number(Double(deals) / max(elapsed, 0.001), places: 0))/s)")

        var failures = 0
        failures += report(showings: sequence, photos: photos, fraction: fraction)
        failures += report(
            gaps: sequence,
            window: settings.repeatWindow(poolSize: photos),
            // At fraction 1.0 the window is the whole pool and is therefore
            // unsatisfiable by construction — the pass is the only rule, and a
            // photo dealt as the last card of one pass may be dealt again as
            // the first card of the next. That boundary is accepted rather than
            // patched, so asserting a minimum gap there would be asserting
            // against the design.
            enforced: fraction < 1.0)
        if fraction >= 1.0 {
            failures += reportPasses(sequence, photos: photos)
        }

        print()
        if failures == 0 {
            Console.recovered("all assertions passed")
        } else {
            Console.failure("\(failures) assertion\(failures == 1 ? "" : "s") failed")
            throw ExitCode(1)
        }
    }

    // MARK: - The rig

    /// A folder of empty files, scanned by the real provider into a real pool.
    ///
    /// Empty is enough: nothing here decodes an image, and the classifier reads
    /// the type from the extension. Going through `SourceStore.refresh` rather
    /// than inserting rows by hand is the point — a harness that bypasses the
    /// interface tests nothing.
    private static func buildLibrary(
        photos: Int, at directory: URL
    ) async throws -> (deck: Deck, sourceID: Int64) {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for index in 0..<photos {
            let file = directory.appending(path: String(format: "photo-%06d.jpg", index))
            FileManager.default.createFile(atPath: file.path(percentEncoded: false), contents: nil)
        }

        let database = try Database.inMemory()
        try Migrator.migrate(database)
        let sources = SourceStore(database: database)
        let source = try sources.add(
            kind: .folder, locator: directory.path(percentEncoded: false), recursive: false)
        let result = await sources.refresh(source)
        guard !result.sourceUnavailable else {
            Console.failure("the throwaway source went unavailable: \(result.reason ?? "unknown")")
            throw ExitCode(1)
        }
        return (Deck(database: database), source.id)
    }

    /// Selecting and showing, which is exactly what the queue does either side
    /// of a fetch — minus the fetch, which is what makes fifty thousand of them
    /// take a second rather than a week.
    private static func deal(
        deck: Deck, source: Int64, count: Int, settings: DeckSettings
    ) throws -> [Int64] {
        var drawn: [Int64] = []
        drawn.reserveCapacity(count)
        while drawn.count < count {
            guard let card = try deck.nextCandidate(forSource: source, settings: settings) else {
                break
            }
            _ = try deck.markShown(photoID: card.id)
            drawn.append(card.id)
        }
        return drawn
    }

    // MARK: - What it found

    /// Showing counts. Zero variance is the promise at fraction 1.0 and a bug
    /// below it — the spread *is* the liveliness being bought.
    private static func report(showings: [Int64], photos: Int, fraction: Double) -> Int {
        var counts: [Int64: Int] = [:]
        for id in showings { counts[id, default: 0] += 1 }

        let values = counts.values.sorted()
        let seen = counts.count
        print()
        Console.note("photos shown  \(seen) of \(photos)")
        Console.note("showings      min \(values.first ?? 0), max \(values.last ?? 0)")

        var failures = 0
        if showings.count >= photos, seen != photos {
            // The starvation bug this deck was rewritten to remove: a photo with
            // an unlucky shuffle key that loses, keeps its key *because* it lost,
            // and loses again, permanently.
            Console.failure("\(photos - seen) photos were never shown at all")
            failures += 1
        }
        if fraction >= 1.0, showings.count % photos == 0, values.first != values.last {
            Console.failure(
                "fraction 1.0 promises exact fairness; showings ranged \(values.first ?? 0)…\(values.last ?? 0)")
            failures += 1
        }
        if fraction < 1.0, seen == photos, values.first == values.last, showings.count > photos * 2 {
            Console.failure(
                "fraction \(fraction) produced zero variance, which means the window is not doing anything")
            failures += 1
        }
        return failures
    }

    /// The distribution of gaps between consecutive showings of one photo. The
    /// hard guarantee is the minimum; the rest is the shape of the shuffle, and
    /// it is what a person actually feels.
    private static func report(gaps sequence: [Int64], window: Int, enforced: Bool) -> Int {
        var lastIndex: [Int64: Int] = [:]
        var gaps: [Int] = []
        for (index, id) in sequence.enumerated() {
            if let previous = lastIndex[id] { gaps.append(index - previous) }
            lastIndex[id] = index
        }
        guard !gaps.isEmpty else {
            Console.note("no photo was shown twice, so there are no gaps to report")
            return 0
        }

        let sorted = gaps.sorted()
        func percentile(_ p: Double) -> Int {
            sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))]
        }

        print()
        Console.note("gaps          window is \(window) cards, \(gaps.count) repeats measured")
        Console.note(
            "              min \(sorted.first!)  p5 \(percentile(0.05))  median \(percentile(0.5))  "
                + "p95 \(percentile(0.95))  max \(sorted.last!)")

        guard enforced else {
            Console.note(
                "              the window is unsatisfiable at fraction 1.0, so a short gap here is "
                    + "a pass boundary rather than a fault")
            return 0
        }
        guard sorted.first! > window else {
            Console.failure(
                "closest repeat was \(sorted.first!) deals apart, inside the \(window)-card window")
            return 1
        }
        return 0
    }

    /// Exactly once per pass, stated per block rather than per total. This is
    /// the classic shuffle, and it is the only claim fraction 1.0 makes that the
    /// showing counts do not already cover.
    private static func reportPasses(_ sequence: [Int64], photos: Int) -> Int {
        var offending = 0
        for start in stride(from: 0, to: sequence.count - photos + 1, by: photos) {
            if Set(sequence[start..<(start + photos)]).count != photos { offending += 1 }
        }
        print()
        if offending > 0 {
            Console.failure("\(offending) passes repeated a photo inside themselves")
            return 1
        }
        Console.note("passes        every \(photos)-card pass held every photo exactly once")
        return 0
    }
}
