import Foundation
import Testing

@testable import PhotoGoRoundKit

/// The consumer registry: a row per surface and a heartbeat, and deliberately
/// nothing more.
///
/// Untested until now, which is worth saying plainly — every request registers,
/// so this runs on the hottest path in the service, and identity being
/// `(kind, displayID)` is what keeps a monitor one consumer across a sleep
/// rather than a new row every time it wakes.
@Suite("Consumers")
struct ConsumerTests {

    private func library() throws -> TestLibrary { try TestLibrary() }

    @Test("First sight creates the row; every sight after it is the same row")
    func registrationIsFindOrCreate() throws {
        let library = try library()
        let deck = library.deck
        let first = try deck.register(
            kind: .screensaver, displayID: "display-1",
            now: Date(timeIntervalSince1970: 100))

        #expect(first.kind == .screensaver)
        #expect(first.displayID == "display-1")
        #expect(first.seenAt == Date(timeIntervalSince1970: 100))

        // No register call, no session, nothing to reap: asking again is the
        // heartbeat.
        let again = try deck.register(
            kind: .screensaver, displayID: "display-1",
            now: Date(timeIntervalSince1970: 500))
        #expect(again.id == first.id, "a second sight minted a second consumer")
        #expect(again.seenAt == Date(timeIntervalSince1970: 500))
        #expect(again.createdAt == first.createdAt, "creation time moved under the heartbeat")
        #expect(try deck.consumers().count == 1)
    }

    @Test("Identity is kind and display together, so two monitors are two consumers")
    func identityIsKindAndDisplay() throws {
        let library = try library()
        let deck = library.deck
        let left = try deck.register(kind: .screensaver, displayID: "left")
        let right = try deck.register(kind: .screensaver, displayID: "right")
        // A widget has no display, so a surface with several instances
        // discriminates in the kind instead.
        let small = try deck.register(kind: ConsumerKind("widget.small"))
        let large = try deck.register(kind: ConsumerKind("widget.large"))

        #expect(Set([left.id, right.id, small.id, large.id]).count == 4)
        #expect(try deck.consumers().count == 4)
    }

    @Test("A consumer with no display is one consumer, not a new one each time")
    func displaylessConsumersAreStable() throws {
        let library = try library()
        let deck = library.deck
        let first = try deck.register(kind: .commandLine)
        let second = try deck.register(kind: .commandLine)
        #expect(first.id == second.id)
        #expect(try deck.consumers().count == 1)
    }

    @Test("The heartbeat moves on its own, without re-registering")
    func touchUpdatesTheHeartbeat() throws {
        let library = try library()
        let deck = library.deck
        let consumer = try deck.register(
            kind: .app, now: Date(timeIntervalSince1970: 10))

        try deck.touch(consumerID: consumer.id, at: Date(timeIntervalSince1970: 999))
        let seen = try #require(try deck.consumer(id: consumer.id))
        #expect(seen.seenAt == Date(timeIntervalSince1970: 999))
        #expect(seen.createdAt == consumer.createdAt)
    }

    @Test("Forgetting a consumer removes it and leaves the others alone")
    func forgettingRemovesOne() throws {
        let library = try library()
        let deck = library.deck
        let going = try deck.register(kind: .screensaver, displayID: "old-monitor")
        let staying = try deck.register(kind: .wallpaper)

        try deck.forget(consumerID: going.id)
        #expect(try deck.consumer(id: going.id) == nil)
        #expect(try deck.consumers().map(\.id) == [staying.id])
    }

    @Test("An unknown id is nil rather than an error")
    func unknownConsumerIsNil() throws {
        #expect(try library().deck.consumer(id: 4242) == nil)
    }

    @Test("Registering does not touch the deck")
    func registrationIsNotADeal() throws {
        let (library, _) = try TestLibrary.withPhotos(3)
        let before = try library.deck.currentDealSeq()
        _ = try library.deck.register(kind: .app, displayID: "display-1")
        // A registry and a heartbeat: asking who is watching cannot spend a
        // card or move the shuffle.
        #expect(try library.deck.currentDealSeq() == before)
        #expect(try library.deck.poolSize() == 3)
    }
}
