import Foundation
import PhotoGoRoundAgentAPI
import Testing

@testable import Photo_Go_Round

/// The collection picker's behaviour, without the picker.
///
/// Two real bugs have come out of this type already — a recursion SwiftUI
/// cannot express, and sources read once into a model that outlives the window
/// — and neither would have been caught by looking at it.
@Suite("Collections model")
@MainActor
struct CollectionsModelTests {

    /// A throwaway preference domain that leaves nothing behind.
    ///
    /// **A path domain from `scratchSuiteName`, not a dotted one.** A dotted
    /// name lands in `~/Library/Preferences`, which `cfprefsd` owns and writes
    /// on its own schedule — including after the process that asked is gone.
    /// That is how the `removePersistentDomain` teardown that used to be here
    /// lost its race and left one plist per test behind, until a later
    /// `swift test` failed on them. See `ScratchPreferences`.
    private nonisolated final class Scratch {
        let name = scratchSuiteName("collections-model")
        var preferences: Preferences { Preferences(defaults: UserDefaults(suiteName: name)!) }

        init() { preferences.publishServicePort(9999) }

        deinit { discardScratchSuite(name) }
    }

    /// An agent that answers by path, and remembers what it was asked in the
    /// order it was asked — which is what "adds before removes" is a claim
    /// about.
    private nonisolated final class Agent: @unchecked Sendable {
        private let lock = NSLock()
        private var sources = Data("[]".utf8)
        private var library = Data("{}".utf8)
        private var asked: [String] = []

        var requests: [String] { lock.withLock { asked } }

        func holds(sources entries: [[String: Any]]) {
            let encoded = (try? JSONSerialization.data(withJSONObject: entries)) ?? Data()
            lock.withLock { sources = encoded }
        }

        func holds(library value: [String: Any]) {
            let encoded = (try? JSONSerialization.data(withJSONObject: value)) ?? Data()
            lock.withLock { library = encoded }
        }

        /// Takes every request and answers none of them — an agent whose
        /// cooperative threads are parked inside a photo library that has
        /// stopped answering. Distinct from refusing, which is quick.
        func goesSilent() {
            lock.withLock { silent = true }
        }

        func speaksAgain() {
            lock.withLock { silent = false }
        }

        private var silent = false

        func transport() -> @Sendable (URLRequest) async throws -> (Data, URLResponse) {
            { [self] request in
                let method = request.httpMethod ?? "GET"
                let path = request.url?.path ?? ""
                let (body, quiet) = lock.withLock { () -> (Data, Bool) in
                    asked.append("\(method) \(path)")
                    if path.hasPrefix("/v2/photos") { return (library, silent) }
                    return (method == "GET" ? sources : Data("[]".utf8), silent)
                }
                if quiet {
                    // Far longer than any bound these tests set, so the deadline
                    // is always what ends the wait.
                    try await Task.sleep(for: .seconds(300))
                }
                return (
                    body,
                    HTTPURLResponse(
                        url: request.url!, statusCode: method == "DELETE" ? 204 : 200,
                        httpVersion: nil, headerFields: nil)!
                )
            }
        }
    }

    // MARK: - Building what the agent says into a library

    private static func album(
        _ identifier: String, _ title: String, folders: [String] = [], count: Int? = nil,
        kind: String = "userAlbum"
    ) -> [String: Any] {
        var entry: [String: Any] = [
            "identifier": identifier, "title": title, "kind": kind, "folders": folders,
        ]
        if let count { entry["count"] = count }
        return entry
    }

    private static func library(
        _ sections: [(String, String, [[String: Any]])],
        authorization: String = "authorized"
    ) -> [String: Any] {
        let total = sections.reduce(0) { $0 + $1.2.count }
        return [
            "authorization": authorization,
            "counted": 0,
            "total": total,
            "sections": sections.map {
                ["section": $0.0, "title": $0.1, "collections": $0.2]
            },
        ]
    }

    private static func source(uuid: String, locator: String) -> [String: Any] {
        [
            "uuid": uuid, "kind": "photos_collection", "locator": locator, "enabled": true,
            "available": true, "photos": 4, "addedAt": "2026-08-26T12:00:00Z",
            "scannedAt": "2026-08-26T12:00:01Z",
        ]
    }

    /// **The bounds default to the picker's real ones**, because most tests
    /// here are about what it does with an answer rather than about giving up
    /// on one. Only the tests about silence shorten them, and they say so.
    private static func model(
        _ agent: Agent, _ scratch: Scratch,
        read: Duration = SourceService.defaultReadLimit,
        write: Duration = SourceService.defaultWriteLimit
    ) -> CollectionsModel {
        CollectionsModel(
            service: SourceService(
                preferences: scratch.preferences, read: read, write: write,
                transport: agent.transport()))
    }

    // MARK: - An agent that is running and stuck

    /// **Applying must never leave the picker locked.** `apply` sets
    /// `isWorking`, which disables Apply and the ticks and shows a spinner. An
    /// agent that never answers used to mean that state had no end.
    @Test("Applying against a silent agent gives the picker back")
    func silenceDoesNotLockThePicker() async {
        let scratch = Scratch()
        let agent = Agent()
        agent.holds(library: Self.library([("albums", "Albums", [Self.album("A1", "Sunsets")])]))
        // Milliseconds rather than the picker's thirty seconds: this is about
        // *whether* the lockout ends, not how long it takes.
        let model = Self.model(agent, scratch, write: .milliseconds(50))
        await model.load()
        agent.goesSilent()

        model.chosen = ["A1"]
        let applied = await model.apply()

        #expect(!applied)
        #expect(!model.isWorking)
        #expect(model.trouble != nil)
    }

    /// **What is already on screen stays on screen**, which is the picker's
    /// half of the rule the window follows for a stale photograph: a list of
    /// three hundred albums that blanked because one poll went unanswered would
    /// read as *your library is empty*.
    @Test("A silent agent does not blank the albums the picker already had")
    func silenceKeepsWhatIsAlreadyShown() async {
        let scratch = Scratch()
        let agent = Agent()
        agent.holds(library: Self.library([("albums", "Albums", [Self.album("A1", "Sunsets")])]))
        let model = Self.model(agent, scratch, read: .milliseconds(50))
        await model.load()
        #expect(model.visible.count == 1)

        agent.goesSilent()
        await model.load()

        #expect(model.trouble != nil)
        // Still there, and still named.
        #expect(model.visible.first?.collections.first?.title == "Sunsets")
    }

    // MARK: - The tree

    @Test("Sections come through as the top of the tree, in the order the agent sent them")
    func sectionsAreTheTop() async {
        let scratch = Scratch()
        let agent = Agent()
        agent.holds(
            library: Self.library([
                ("albums", "Albums", [Self.album("A", "Holiday")]),
                ("sharing", "Sharing", [Self.album("B", "Family")]),
            ]))
        let model = Self.model(agent, scratch)

        await model.load()

        #expect(model.tree.map(\.id) == ["albums", "sharing"])
        #expect(model.tree.map(\.title) == ["Albums", "Sharing"])
        #expect(model.tree.allSatisfy { !$0.isAlbum })
    }

    @Test("An album with no folders hangs directly off its section")
    func topLevelAlbums() async {
        let scratch = Scratch()
        let agent = Agent()
        agent.holds(library: Self.library([("albums", "Albums", [Self.album("A", "Holiday")])]))
        let model = Self.model(agent, scratch)

        await model.load()

        let children = model.tree[0].children
        #expect(children.count == 1)
        #expect(children[0].isAlbum)
        #expect(children[0].title == "Holiday")
        #expect(children[0].depth == 1)
    }

    @Test("An album inside folders is nested under them, one node per level")
    func foldersNest() async {
        let scratch = Scratch()
        let agent = Agent()
        agent.holds(
            library: Self.library([
                ("albums", "Albums", [Self.album("A", "Finals", folders: ["Baseball", "2024"])])
            ]))
        let model = Self.model(agent, scratch)

        await model.load()

        let baseball = model.tree[0].children[0]
        #expect(baseball.title == "Baseball")
        #expect(!baseball.isAlbum)
        let year = baseball.children[0]
        #expect(year.title == "2024")
        #expect(year.children[0].title == "Finals")
        #expect(year.children[0].depth == 3)
    }

    /// What Photos does, and what somebody scanning for a name expects.
    @Test("Folders come before albums, and each is sorted by name")
    func foldersBeforeAlbums() async {
        let scratch = Scratch()
        let agent = Agent()
        agent.holds(
            library: Self.library([
                (
                    "albums", "Albums",
                    [
                        Self.album("A", "Zebra"),
                        Self.album("B", "Apple"),
                        Self.album("C", "x", folders: ["Zoo"]),
                        Self.album("D", "y", folders: ["Attic"]),
                    ]
                )
            ]))
        let model = Self.model(agent, scratch)

        await model.load()

        #expect(model.tree[0].children.map(\.title) == ["Attic", "Zoo", "Apple", "Zebra"])
    }

    @Test("Numbers in names sort the way a person reads them")
    func naturalOrder() async {
        let scratch = Scratch()
        let agent = Agent()
        agent.holds(
            library: Self.library([
                ("albums", "Albums", [Self.album("A", "Set 10"), Self.album("B", "Set 2")])
            ]))
        let model = Self.model(agent, scratch)

        await model.load()

        #expect(model.tree[0].children.map(\.title) == ["Set 2", "Set 10"])
    }

    /// It is an album by every technical measure and is not one by any other.
    /// Photos puts it above its sidebar sections; so does this.
    @Test("Favorites sits at the top of the box, above every heading")
    func favoritesIsPinned() async {
        let scratch = Scratch()
        let agent = Agent()
        agent.holds(
            library: Self.library([
                (
                    "albums", "Albums",
                    [
                        Self.album("A", "Apples"),
                        Self.album("F", "Favorites", kind: "favorites"),
                    ]
                )
            ]))
        let model = Self.model(agent, scratch)

        await model.load()

        #expect(model.tree.first?.title == "Favorites")
        #expect(model.tree.first?.isAlbum == true)
        #expect(model.tree.first?.depth == 0)
    }

    /// At the top *instead of*, not as well as — a collection offered twice is
    /// a collection somebody can tick once and see still unticked.
    @Test("Favorites does not also appear among the albums")
    func favoritesIsNotListedTwice() async {
        let scratch = Scratch()
        let agent = Agent()
        agent.holds(
            library: Self.library([
                (
                    "albums", "Albums",
                    [
                        Self.album("A", "Apples"),
                        Self.album("F", "Favorites", kind: "favorites"),
                    ]
                )
            ]))
        let model = Self.model(agent, scratch)

        await model.load()

        let albums = model.tree.first { !$0.isAlbum }
        #expect(albums?.title == "Albums")
        #expect(albums?.albums.map(\.identifier) == ["A"])
    }

    // MARK: - Flattening, which is what the view draws

    @Test("An open folder contributes its own row and everything under it")
    func openFolderYieldsItsAlbums() async {
        let scratch = Scratch()
        let agent = Agent()
        agent.holds(
            library: Self.library([
                (
                    "albums", "Albums",
                    [Self.album("A", "One", folders: ["Box"]), Self.album("B", "Two", folders: ["Box"])]
                )
            ]))
        let model = Self.model(agent, scratch)
        await model.load()

        #expect(model.rows(under: model.tree[0]).map(\.title) == ["Box", "One", "Two"])
    }

    /// The laziness this replaced a recursive view for: a closed folder must
    /// build nothing beneath it.
    @Test("A closed folder contributes its own row and nothing beneath")
    func closedFolderYieldsOnlyItself() async {
        let scratch = Scratch()
        let agent = Agent()
        agent.holds(
            library: Self.library([
                ("albums", "Albums", [Self.album("A", "One", folders: ["Box"])])
            ]))
        let model = Self.model(agent, scratch)
        await model.load()

        model.toggle("albums/Box")

        #expect(model.rows(under: model.tree[0]).map(\.title) == ["Box"])
    }

    @Test("Twisting a section shut and open again leaves the tree as it was")
    func collapsingIsReversible() async {
        let scratch = Scratch()
        let agent = Agent()
        agent.holds(library: Self.library([("albums", "Albums", [Self.album("A", "One")])]))
        let model = Self.model(agent, scratch)
        await model.load()

        #expect(!model.isCollapsed("albums"))
        model.toggle("albums")
        #expect(model.isCollapsed("albums"))
        model.toggle("albums")
        #expect(!model.isCollapsed("albums"))
    }

    // MARK: - Three states

    private static func folderLibrary() -> [String: Any] {
        library([
            (
                "albums", "Albums",
                [
                    Self.album("A", "One", folders: ["Box"]),
                    Self.album("B", "Two", folders: ["Box"]),
                    Self.album("C", "Three", folders: ["Box"]),
                ]
            )
        ])
    }

    @Test("A folder reports none, some, or all of what is under it")
    func threeStates() async {
        let scratch = Scratch()
        let agent = Agent()
        agent.holds(library: Self.folderLibrary())
        let model = Self.model(agent, scratch)
        await model.load()
        let box = model.tree[0].children[0]

        #expect(model.chosen(under: box) == .none)
        model.chosen.insert("A")
        #expect(model.chosen(under: box) == .some)
        model.chosen.formUnion(["B", "C"])
        #expect(model.chosen(under: box) == .all)
    }

    /// The platform convention: a partly-ticked checkbox completes the set.
    @Test("Clicking a mixed folder fills it rather than emptying it")
    func mixedFills() async {
        let scratch = Scratch()
        let agent = Agent()
        agent.holds(library: Self.folderLibrary())
        let model = Self.model(agent, scratch)
        await model.load()
        let box = model.tree[0].children[0]
        model.chosen.insert("A")

        model.chooseAll(under: box)

        #expect(model.chosen(under: box) == .all)
        #expect(model.chosen == ["A", "B", "C"])
    }

    @Test("Clicking a full folder empties it")
    func fullEmpties() async {
        let scratch = Scratch()
        let agent = Agent()
        agent.holds(library: Self.folderLibrary())
        let model = Self.model(agent, scratch)
        await model.load()
        let box = model.tree[0].children[0]
        model.chooseAll(under: box)

        model.chooseAll(under: box)

        #expect(model.chosen(under: box) == .none)
        #expect(model.chosen.isEmpty)
    }

    @Test("A folder counts everything beneath it, not just its own children")
    func countsThroughTheSubtree() async {
        let scratch = Scratch()
        let agent = Agent()
        agent.holds(
            library: Self.library([
                (
                    "albums", "Albums",
                    [
                        Self.album("A", "One", folders: ["Box"]),
                        Self.album("B", "Two", folders: ["Box", "Inner"]),
                    ]
                )
            ]))
        let model = Self.model(agent, scratch)
        await model.load()
        let box = model.tree[0].children[0]
        model.chosen.formUnion(["A", "B"])

        #expect(box.albums.count == 2)
        #expect(model.chosenCount(under: box) == 2)
    }

    // MARK: - Seeding, and the bug that came of getting it wrong

    @Test("Opening the picker ticks what is already a source")
    func ticksStartOutTrue() async {
        let scratch = Scratch()
        let agent = Agent()
        agent.holds(sources: [Self.source(uuid: "S1", locator: "A")])
        agent.holds(library: Self.library([("albums", "Albums", [Self.album("A", "One")])]))
        let model = Self.model(agent, scratch)

        await model.load()

        #expect(model.chosen == ["A"])
        #expect(!model.hasChanges)
    }

    /// **The bug.** `existing` used to be read once, guarded on the library
    /// being nil — and a `Window` scene's model outlives the window closing, so
    /// the second open still held the first open's sources. Unticking anything
    /// added since found no source to name and skipped it silently.
    @Test("A source added since the last read can still be removed")
    func laterSourcesCanBeRemoved() async {
        let scratch = Scratch()
        let agent = Agent()
        agent.holds(library: Self.library([("albums", "Albums", [Self.album("A", "One")])]))
        let model = Self.model(agent, scratch)
        await model.load()
        #expect(model.chosen.isEmpty)

        // Something adds it while this model is alive — another window, or an
        // earlier trip through this same picker.
        agent.holds(sources: [Self.source(uuid: "S1", locator: "A")])
        await model.load()
        model.chosen.remove("A")

        #expect(await model.apply())
        #expect(agent.requests.contains("DELETE /v2/sources/S1"))
    }

    /// **The poll, which is what a read in flight actually is.** It used to say
    /// this with `load`, back when the two were the same call; they are not any
    /// more, because opening the window has to forget the last visit and a poll
    /// must not.
    @Test("A poll does not undo a tick made while it was in flight")
    func pollingDoesNotReseed() async {
        let scratch = Scratch()
        let agent = Agent()
        agent.holds(library: Self.library([("albums", "Albums", [Self.album("A", "One")])]))
        let model = Self.model(agent, scratch)
        await model.load()

        model.chosen.insert("A")
        await model.refresh()

        #expect(model.chosen == ["A"])
        #expect(model.hasChanges)
    }

    // MARK: - Opening the window again

    /// **A `Window` scene's model outlives its window**, so without this the
    /// second visit opens showing why the first one failed — *the agent is not
    /// answering*, about an agent that is answering fine now.
    @Test("Reopening the picker forgets the last visit's trouble and asks again")
    func reopeningForgetsTheLastFailure() async {
        let scratch = Scratch()
        let agent = Agent()
        agent.holds(library: Self.library([("albums", "Albums", [Self.album("A", "One")])]))
        let model = Self.model(agent, scratch, read: .milliseconds(50))
        agent.goesSilent()
        await model.load()
        #expect(model.trouble != nil)

        // The window closes and opens again, against an agent that is fine now.
        agent.speaksAgain()
        await model.load()

        #expect(model.trouble == nil)
        #expect(model.visible.count == 1)
    }

    /// The ticks described the source list as it stood when the last window
    /// opened. Anything could have changed it since — including this same
    /// picker, on its last trip.
    @Test("Reopening seeds the ticks from what the agent has now")
    func reopeningReseedsTheTicks() async {
        let scratch = Scratch()
        let agent = Agent()
        agent.holds(library: Self.library([("albums", "Albums", [Self.album("A", "One")])]))
        let model = Self.model(agent, scratch)
        await model.load()
        #expect(model.chosen.isEmpty)

        // Something adds it while this model is alive — `pgr_ctl`, another
        // window, or an earlier trip through this same picker.
        agent.holds(sources: [Self.source(uuid: "S1", locator: "A")])
        await model.load()

        #expect(model.chosen == ["A"])
        // Seeded from reality, so there is nothing to apply.
        #expect(!model.hasChanges)
    }

    // MARK: - Applying

    /// A batch the agent refuses must not have already deleted things.
    @Test("Adds are sent before removes")
    func addsBeforeRemoves() async {
        let scratch = Scratch()
        let agent = Agent()
        agent.holds(sources: [Self.source(uuid: "S1", locator: "A")])
        agent.holds(
            library: Self.library([
                ("albums", "Albums", [Self.album("A", "One"), Self.album("B", "Two")])
            ]))
        let model = Self.model(agent, scratch)
        await model.load()

        model.chosen = ["B"]
        #expect(await model.apply())

        let changes = agent.requests.filter { $0 != "GET /v2/sources" && !$0.hasPrefix("GET /v2/photos") }
        #expect(changes == ["POST /v2/sources", "DELETE /v2/sources/S1"])
    }

    @Test("Nothing ticked and nothing unticked asks the agent for nothing")
    func noChangesAskNothing() async {
        let scratch = Scratch()
        let agent = Agent()
        agent.holds(sources: [Self.source(uuid: "S1", locator: "A")])
        agent.holds(library: Self.library([("albums", "Albums", [Self.album("A", "One")])]))
        let model = Self.model(agent, scratch)
        await model.load()

        #expect(await model.apply())

        #expect(!agent.requests.contains { $0.hasPrefix("POST") || $0.hasPrefix("DELETE") })
    }

    @Test("A library we may not read says so rather than looking empty")
    func unreadableSaysSo() async {
        let scratch = Scratch()
        let agent = Agent()
        agent.holds(library: Self.library([], authorization: "denied"))
        let model = Self.model(agent, scratch)

        await model.load()

        #expect(model.library?.isReadable == false)
        #expect(model.library?.authorization == "denied")
    }
}
