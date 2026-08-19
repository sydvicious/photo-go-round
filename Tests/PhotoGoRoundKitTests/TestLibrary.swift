import Foundation

@testable import PhotoGoRoundKit

/// A migrated database plus the handful of inserts the deck tests need.
///
/// It writes rows directly rather than going through the source providers,
/// because those arrive in a later slice and the deck should be testable
/// without them.
struct TestLibrary {
    let database: Database

    init() throws {
        database = try Database.inMemory()
        try Migrator.migrate(database)
    }

    /// A file-backed library, for the tests that need two connections to the
    /// same database. The caller owns the directory.
    static func onDisk(at directory: URL) throws -> TestLibrary {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let database = try Database(path: Self.path(in: directory))
        try Migrator.migrate(database)
        return TestLibrary(database: database)
    }

    static func path(in directory: URL) -> String {
        directory.appending(path: "photogoround.sqlite").path(percentEncoded: false)
    }

    private init(database: Database) {
        self.database = database
    }

    var deck: Deck { Deck(database: database) }

    /// A deck whose shuffle keys come from a fixed sequence, for the tests that
    /// need the ordering to be predictable rather than merely fair.
    func deck(keys: [Double]) -> Deck {
        var index = 0
        return Deck(database: database) {
            defer { index += 1 }
            return keys[index % keys.count]
        }
    }

    @discardableResult
    func addSource(kind: String = "folder", locator: String = "/photos", enabled: Bool = true) throws -> Int64 {
        try database.run(
            """
            INSERT INTO source (uuid, kind, locator, enabled, added_at)
            VALUES (:uuid, :kind, :locator, :enabled, 0);
            """,
            [
                "uuid": .text(UUID().uuidString.lowercased()), "kind": .text(kind),
                "locator": .text(locator), "enabled": SQLValue(enabled),
            ]
        )
        return database.lastInsertRowID
    }

    @discardableResult
    func addPhotos(
        _ count: Int,
        to sourceID: Int64,
        mediaType: MediaType = .image,
        sourceEnabled: Bool = true,
        namePrefix: String = "photo"
    ) throws -> [Int64] {
        var ids: [Int64] = []
        try database.transaction {
            for index in 0..<count {
                try database.run(
                    """
                    INSERT INTO photo (uuid, source_id, external_id, media_type, source_enabled,
                                       storage, shuffle_key, added_at)
                    VALUES (:uuid, :source, :external, :media, :enabled,
                            'materialized', :key, 0);
                    """,
                    [
                        "uuid": .text(UUID().uuidString.lowercased()),
                        "source": .int(sourceID),
                        "external": .text("\(namePrefix)-\(index).heic"),
                        "media": .text(mediaType.rawValue),
                        "enabled": SQLValue(sourceEnabled),
                        "key": .double(Double.random(in: 0..<1)),
                    ]
                )
                ids.append(database.lastInsertRowID)
            }
        }
        return ids
    }

    /// A library of `count` photos in one enabled folder source.
    @discardableResult
    static func withPhotos(_ count: Int) throws -> (library: TestLibrary, photoIDs: [Int64]) {
        let library = try TestLibrary()
        let source = try library.addSource()
        let ids = try library.addPhotos(count, to: source)
        return (library, ids)
    }

    func setLastDealt(_ photoID: Int64, seq: Int64?) throws {
        try database.run(
            "UPDATE photo SET last_dealt_seq = :seq WHERE id = :id;",
            ["seq": SQLValue(seq), "id": .int(photoID)]
        )
    }

    func setDealSeq(_ seq: Int64) throws {
        try database.run("UPDATE deck_state SET deal_seq = :seq WHERE id = 1;", ["seq": .int(seq)])
    }

    func setSourceEnabled(_ sourceID: Int64, _ enabled: Bool) throws {
        try database.transaction {
            try database.run(
                "UPDATE source SET enabled = :e WHERE id = :id;",
                ["e": SQLValue(enabled), "id": .int(sourceID)]
            )
            try database.run(
                "UPDATE photo SET source_enabled = :e WHERE source_id = :id;",
                ["e": SQLValue(enabled), "id": .int(sourceID)]
            )
        }
    }

    /// Puts a photo in the queue directly, without going through a provider.
    func enqueue(_ photoID: Int64, sourceID: Int64) throws {
        try database.run(
            "INSERT INTO queue (photo_id, source_id, queued_at) VALUES (:p, :s, 0);",
            ["p": .int(photoID), "s": .int(sourceID)]
        )
    }

    @discardableResult
    func addConsumer(kind: String, displayID: String? = nil) throws -> Int64 {
        try database.run(
            """
            INSERT INTO consumer (kind, display_id, seen_at, created_at)
            VALUES (:kind, :display, 0, 0);
            """,
            ["kind": .text(kind), "display": SQLValue(displayID)]
        )
        return database.lastInsertRowID
    }
}

/// Draws `count` pictures and records what came out, exercising the deck the way
/// the queue does — pick a candidate, mark it shown — without the cache or any
/// file I/O in the way.
///
/// Sources are visited in turn, so a single-source library (which is what the
/// statistical tests use) sees exactly the pass-and-window behaviour the deck
/// promises.
extension TestLibrary {
    func drawSequence(count: Int, settings: DeckSettings) throws -> [Int64] {
        let sourceIDs = try database.all("SELECT id FROM source WHERE enabled = 1 ORDER BY id;") {
            try $0.int64("id")
        }
        guard !sourceIDs.isEmpty else { return [] }

        var drawn: [Int64] = []
        drawn.reserveCapacity(count)
        var next = 0
        while drawn.count < count {
            var madeProgress = false
            for _ in sourceIDs.indices {
                let sourceID = sourceIDs[next % sourceIDs.count]
                next += 1
                if let card = try deck.nextCandidate(forSource: sourceID, settings: settings) {
                    _ = try deck.markShown(photoID: card.id)
                    drawn.append(card.id)
                    madeProgress = true
                    break
                }
            }
            if !madeProgress { break }
        }
        return drawn
    }
}

/// Gaps between consecutive showings of the same photo, across a deal sequence.
func gapsBetweenRepeats(in sequence: [Int64]) -> [Int] {
    var lastIndex: [Int64: Int] = [:]
    var gaps: [Int] = []
    for (index, id) in sequence.enumerated() {
        if let previous = lastIndex[id] {
            gaps.append(index - previous)
        }
        lastIndex[id] = index
    }
    return gaps
}

/// A minimal lock, for collecting results from several threads. The kit takes no
/// dependencies and neither do its tests.
final class Mutex<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()

    init(_ value: Value) { self.value = value }

    func withLock<T>(_ body: (inout Value) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}
