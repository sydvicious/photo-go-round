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
        directory.appending(path: "library.sqlite").path(percentEncoded: false)
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
            "INSERT INTO source (kind, locator, enabled, added_at) VALUES (:kind, :locator, :enabled, 0);",
            ["kind": .text(kind), "locator": .text(locator), "enabled": SQLValue(enabled)]
        )
        return database.lastInsertRowID
    }

    @discardableResult
    func addPhotos(
        _ count: Int,
        to sourceID: Int64,
        mediaType: MediaType = .image,
        available: Bool = true,
        sourceEnabled: Bool = true,
        namePrefix: String = "photo"
    ) throws -> [Int64] {
        var ids: [Int64] = []
        try database.transaction {
            for index in 0..<count {
                try database.run(
                    """
                    INSERT INTO photo (source_id, external_id, media_type, source_enabled, available,
                                       storage, cache_path, shuffle_key, added_at)
                    VALUES (:source, :external, :media, :enabled, :available,
                            'materialized', :path, :key, 0);
                    """,
                    [
                        "source": .int(sourceID),
                        "external": .text("\(namePrefix)-\(index).heic"),
                        "media": .text(mediaType.rawValue),
                        "enabled": SQLValue(sourceEnabled),
                        "available": SQLValue(available),
                        "path": .text("\(sourceID)/\(namePrefix)-\(index).heic"),
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

    func setAvailable(_ photoID: Int64, _ available: Bool) throws {
        try database.run(
            "UPDATE photo SET available = :a WHERE id = :id;",
            ["a": SQLValue(available), "id": .int(photoID)]
        )
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

    /// Reserves a card into an outstanding hand, without going through the
    /// hand API — which is the next slice.
    func reserve(_ photoID: Int64, consumerID: Int64, position: Int) throws {
        try database.run(
            "INSERT INTO hand (consumer_id, photo_id, position, reserved_at) VALUES (:c, :p, :n, 0);",
            ["c": .int(consumerID), "p": .int(photoID), "n": .int(Int64(position))]
        )
    }

    @discardableResult
    func addConsumer(kind: String, displayID: String? = nil, handSize: Int = 10) throws -> Int64 {
        try database.run(
            """
            INSERT INTO consumer (kind, display_id, hand_size, seen_at, created_at)
            VALUES (:kind, :display, :size, 0, 0);
            """,
            ["kind": .text(kind), "display": SQLValue(displayID), "size": .int(Int64(handSize))]
        )
        return database.lastInsertRowID
    }
}

/// Deals `count` cards and records what came out, for the statistical
/// assertions. Returns the photo id of each deal, in order.
extension Deck {
    func dealSequence(count: Int, settings: DeckSettings) throws -> [Int64] {
        var dealt: [Int64] = []
        dealt.reserveCapacity(count)
        for _ in 0..<count {
            guard let deal = try deal(settings: settings) else { break }
            dealt.append(deal.card.id)
        }
        return dealt
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
