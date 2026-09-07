import Foundation
import PhotoGoRoundAgentAPI
import Testing

@testable import Photo_Go_Round

/// The panel's behaviour, without the panel.
///
/// Everything here is a decision the Settings window makes and a person would
/// otherwise have to catch by looking: whether Configure is offered for what is
/// selected, what a refusal leaves on screen, and what happens to the selection
/// when the row under it stops existing because something else removed it.
@Suite("Sources model")
@MainActor
struct SourcesModelTests {

    /// A throwaway preference domain that leaves nothing behind.
    ///
    /// **A path domain from `scratchSuiteName`, not a dotted one.** A dotted
    /// name lands in `~/Library/Preferences`, which `cfprefsd` owns and writes
    /// on its own schedule — including after the process that asked is gone.
    /// That is how the `removePersistentDomain` teardown that used to be here
    /// lost its race and left one plist per test behind, until a later
    /// `swift test` failed on them. See `ScratchPreferences`.
    private nonisolated final class Scratch {
        let name = scratchSuiteName("sources-model")
        var preferences: Preferences { Preferences(defaults: UserDefaults(suiteName: name)!) }

        init() { preferences.publishServicePort(9999) }

        deinit { discardScratchSuite(name) }
    }

    /// An agent that answers however a test needs it to, and counts what it was
    /// asked.
    /// `nonisolated` because the transport answers from wherever the client is,
    /// and this target defaults to `MainActor` isolation. The answers are held
    /// as encoded JSON rather than as dictionaries so that nothing non-`Sendable`
    /// has to cross out of it.
    nonisolated final class Agent: @unchecked Sendable {
        private let lock = NSLock()
        private var listing = Data("[]".utf8)
        private var refusal: (status: Int, body: String)?
        private var asked: [String] = []

        var methods: [String] { lock.withLock { asked.map { String($0.split(separator: " ")[0]) } } }
        /// Every request as "METHOD path", for a test that cares where it went.
        var requests: [String] { lock.withLock { asked } }
        var listCount: Int { methods.filter { $0 == "GET" }.count }

        func holds(_ sources: [[String: Any]]) {
            let encoded = (try? JSONSerialization.data(withJSONObject: sources)) ?? Data("[]".utf8)
            lock.withLock { listing = encoded }
        }

        func refuses(status: Int, body: String) {
            lock.withLock { refusal = (status, body) }
        }

        func stopsRefusing() {
            lock.withLock { refusal = nil }
        }

        /// Takes every request and answers none of them.
        ///
        /// **Not the same as refusing.** A refusal is the agent saying no,
        /// quickly; this is an agent whose cooperative threads are parked inside
        /// a photo library that has stopped answering, so it accepts the
        /// connection and then nothing happens at all.
        func goesSilent() {
            lock.withLock { silent = true }
        }

        func speaksAgain() {
            lock.withLock { silent = false }
        }

        private var silent = false

        /// Holds every change open until released, so a test can look at the
        /// panel while a request is still in flight — which is what a slow
        /// delete looks like to somebody clicking the button again.
        private var openGate: Gate?

        func holdsChangesOpen() -> Gate {
            let gate = Gate()
            lock.withLock { openGate = gate }
            return gate
        }

        final class Gate: @unchecked Sendable {
            private let semaphore = DispatchSemaphore(value: 0)
            private let lock = NSLock()
            private var arrived = false

            var hasArrived: Bool { lock.withLock { arrived } }

            func waitHere() async {
                lock.withLock { arrived = true }
                await withCheckedContinuation { continuation in
                    DispatchQueue.global().async {
                        // Bounded: a gate nobody opens fails the test rather
                        // than hanging the suite.
                        _ = self.semaphore.wait(timeout: .now() + 5)
                        continuation.resume()
                    }
                }
            }

            func release() { semaphore.signal() }
        }

        func transport() -> @Sendable (URLRequest) async throws -> (Data, URLResponse) {
            { [self] request in
                let method = request.httpMethod ?? "GET"
                let path = request.url?.path(percentEncoded: false) ?? ""
                let (refusing, held, quiet) = lock.withLock {
                    asked.append("\(method) \(path)")
                    return (refusal, listing, silent)
                }
                if quiet {
                    // Far longer than any bound these tests set, so the deadline
                    // is always what ends the wait.
                    try await Task.sleep(for: .seconds(300))
                }

                if method != "GET", let gate = lock.withLock({ openGate }) { await gate.waitHere() }

                // A refusal applies to changes; the list keeps working, which is
                // what lets a test assert that a failed change left the list
                // alone.
                if let refusing, method != "GET" {
                    return (
                        Data(refusing.body.utf8),
                        HTTPURLResponse(
                            url: request.url!, statusCode: refusing.status, httpVersion: nil,
                            headerFields: nil)!
                    )
                }
                // A reconnect answers with the one source it moved, so the
                // fake answers with that source as the listing now describes
                // it — the agent re-reads afterwards anyway, but a body that
                // cannot be decoded is a failure the model would show.
                var body = method == "GET" ? held : Data("[]".utf8)
                if method == "POST", path.hasSuffix("/reconnect"),
                    let uuid = path.split(separator: "/").dropLast().last,
                    let listed = try? JSONSerialization.jsonObject(with: held) as? [[String: Any]],
                    let moved = listed.first(where: { $0["uuid"] as? String == String(uuid) }),
                    let encoded = try? JSONSerialization.data(withJSONObject: moved)
                {
                    body = encoded
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

    static func entry(
        uuid: String, kind: String = "folder", locator: String = "/x/Pictures",
        recursive: Bool? = true, photos: Int = 3, available: Bool = true,
        scanned: Bool = true, title: String? = nil, missing: Bool? = nil,
        reconnectable: Bool? = nil
    ) -> [String: Any] {
        var entry: [String: Any] = [
            "uuid": uuid, "kind": kind, "locator": locator, "enabled": true,
            "available": available, "photos": photos, "addedAt": "2026-08-23T18:04:11Z",
        ]
        if let recursive { entry["recursive"] = recursive }
        if scanned { entry["scannedAt"] = "2026-08-23T18:04:12Z" }
        if let title { entry["title"] = title }
        if let missing { entry["missing"] = missing }
        if let reconnectable { entry["reconnectable"] = reconnectable }
        return entry
    }

    /// A Photos album as the v2 list describes one.
    static func album(
        uuid: String, title: String?, missing: Bool = false, reconnectable: Bool? = nil,
        photos: Int = 40
    ) -> [String: Any] {
        entry(
            uuid: uuid, kind: "photos_collection", locator: "LIB-\(uuid)/L0/0\(uuid)",
            recursive: nil, photos: photos, available: !missing, title: title, missing: missing,
            reconnectable: missing ? (reconnectable ?? false) : nil)
    }

    /// Intervals in milliseconds, not the panel's minutes: these tests are
    /// about *whether* it polls and stops, and waiting three real minutes to
    /// find out is a test nobody runs.
    /// Waits for something to become true, rather than sleeping a guess.
    ///
    /// The panel polls on a timer and the machine does not promise to let it —
    /// a fixed sleep long enough to be reliable under load is far longer than
    /// the wait usually needed, and a short one fails whenever something else
    /// is running.
    private static func until(
        _ reached: @MainActor () -> Bool,
        _ what: String,
        within limit: Duration = .seconds(10)
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + limit
        while clock.now < deadline {
            if reached() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("\(what) did not happen within \(limit)")
    }

    /// **The bounds default to the panel's real ones**, because most tests
    /// here are about what the panel does with an answer rather than about
    /// giving up on one — and a short bound would cut off the tests that
    /// deliberately hold a change open with a gate. Only the tests about
    /// silence shorten them, and they say so.
    private func model(
        _ agent: Agent, _ scratch: Scratch,
        read: Duration = SourceService.defaultReadLimit,
        write: Duration = SourceService.defaultWriteLimit
    ) -> SourcesModel {
        SourcesModel(
            service: SourceService(
                preferences: scratch.preferences, read: read, write: write,
                transport: agent.transport()),
            interval: .milliseconds(20), retry: .milliseconds(20))
    }

    // MARK: - An agent that is running and stuck

    /// **The guarantee: the panel cannot be locked for ever.**
    ///
    /// Every change sets `isWorking`, which disables the controls and shows a
    /// spinner, and clears it when the request comes back. Against an agent that
    /// never answers, "comes back" used to mean fifteen seconds at best and
    /// never at worst — a Settings window with every button dead and no
    /// explanation. The bound is what makes the lockout end.
    @Test("A change against a silent agent gives the panel back")
    func aSilentAgentDoesNotLockThePanel() async {
        let scratch = Scratch()
        let agent = Agent()
        agent.holds([Self.entry(uuid: "a")])
        // **Both bounds, because a change spends both.** `change` asks, and then
        // re-reads whatever happened — so against an agent that answers neither,
        // the lockout lasts the write bound plus the read bound. In the shipping
        // panel that is thirty seconds and then ten: bounded, which is the
        // point, but not short. Naming both here is what keeps that fact in a
        // test rather than in somebody's afternoon.
        let model = model(agent, scratch, read: .milliseconds(50), write: .milliseconds(50))
        await model.load()
        agent.goesSilent()

        model.selection = "a"
        let clock = ContinuousClock()
        let started = clock.now
        await model.removeSelected()

        #expect(!model.isWorking)
        #expect(model.trouble != nil)
        // Both bounds and no more: a third wait in here would mean `change`
        // had grown an ask nobody counted.
        #expect(clock.now - started < .milliseconds(500))
    }

    // MARK: - Opening the panel again

    /// **A `Window` scene's model outlives its window**, so without this the
    /// second visit draws showing why the first one failed — and against a
    /// silent agent it would keep saying so for the whole read bound before the
    /// fresh answer replaced it.
    @Test("Reopening the panel forgets the last visit's trouble and asks again")
    func reopeningForgetsTheLastFailure() async {
        let scratch = Scratch()
        let agent = Agent()
        agent.holds([Self.entry(uuid: "a")])
        let model = model(agent, scratch, read: .milliseconds(50))
        agent.goesSilent()
        await model.load()
        #expect(model.trouble != nil)

        // The window closes and opens again, against an agent that is fine now.
        agent.speaksAgain()
        await model.load()

        #expect(model.trouble == nil)
        #expect(model.sources.count == 1)
    }

    /// **A doorbell is a read, not a visit.** The picker announcing a change
    /// must not blank a refusal the person is still reading — `refresh` replaces
    /// it only when a read actually succeeds.
    @Test("A read leaves a refusal on screen until it has something to replace it with")
    func aReadDoesNotBlankARefusalUpFront() async {
        let scratch = Scratch()
        let agent = Agent()
        agent.holds([Self.entry(uuid: "a")])
        let model = model(agent, scratch, read: .milliseconds(50))
        await model.load()

        agent.refuses(status: 400, body: "{\"error\": \"no\"}")
        model.selection = "a"
        await model.removeSelected()
        #expect(model.trouble == "no")

        // The agent goes quiet before the doorbell's read can land, so there is
        // nothing to replace the refusal with — and it must still be there.
        agent.goesSilent()
        async let reading: Void = model.refresh()
        #expect(model.trouble == "no")
        await reading
    }

    /// **Not "the agent is not running".** It is, and it took the connection.
    /// Sending somebody to start an agent whose process is right there in
    /// Activity Monitor is worse than saying nothing.
    @Test("A silent agent is described as running and stuck, not as absent")
    func silenceIsNotAbsence() async {
        let scratch = Scratch()
        let agent = Agent()
        agent.goesSilent()
        let model = model(agent, scratch, read: .milliseconds(50))

        await model.load()

        let trouble = model.trouble ?? ""
        #expect(trouble.contains("not answering"))
        #expect(!trouble.contains("is not running"))
    }

    /// The panel keeps asking, so an agent that comes back is picked up without
    /// anybody closing and reopening the window.
    @Test("The panel recovers on its own when the agent starts answering again")
    func recoversWhenTheAgentReturns() async throws {
        let scratch = Scratch()
        let agent = Agent()
        agent.holds([Self.entry(uuid: "a")])
        agent.goesSilent()
        let model = model(agent, scratch, read: .milliseconds(50))

        model.beginPolling()
        // Waited for rather than slept through: the retry interval is 20 ms and
        // a loaded machine does not promise to honour it, so a fixed sleep here
        // is either slow or flaky and usually both.
        try await Self.until({ model.trouble != nil }, "the silence being noticed")

        agent.speaksAgain()
        try await Self.until({ model.trouble == nil }, "the panel recovering")
        model.endPolling()

        #expect(model.sources.count == 1)
    }

    // MARK: - Reading

    @Test("Loading shows what the agent has")
    func loadShowsTheList() async {
        let scratch = Scratch()
        let agent = Agent()
        agent.holds([Self.entry(uuid: "a"), Self.entry(uuid: "b", locator: "/x/More")])

        let model = model(agent, scratch)
        await model.load()

        #expect(model.sources.map(\.uuid) == ["a", "b"])
        #expect(model.trouble == nil)
    }

    @Test("With no agent the panel says so rather than showing an empty library")
    func noAgentIsExplained() async {
        let scratch = Scratch()
        let agent = Agent()
        // No port published: an unstarted agent, which is not the same fact as
        // "you have configured nothing".
        scratch.preferences.withdrawServicePort()

        let model = model(agent, scratch)
        await model.load()

        #expect(model.sources.isEmpty)
        #expect(model.trouble?.contains("agent is not running") == true)
    }

    // MARK: - The selection, and what the buttons read from it

    @Test("Configure is offered for a folder and not for a file")
    func configureIsForFoldersOnly() async {
        let scratch = Scratch()
        let agent = Agent()
        agent.holds([
            Self.entry(uuid: "folder"),
            Self.entry(uuid: "file", kind: "file", locator: "/x/one.png", recursive: nil),
        ])

        let model = model(agent, scratch)
        await model.load()

        model.selection = "folder"
        #expect(model.canConfigureSelection)
        #expect(model.canRemoveSelection)

        model.selection = "file"
        #expect(!model.canConfigureSelection, "a file has no options, so there is nothing to open")
        #expect(model.canRemoveSelection, "but it can still be removed")

        model.selection = nil
        #expect(!model.canConfigureSelection)
        #expect(!model.canRemoveSelection)
    }

    @Test("A source removed by something else clears the selection pointing at it")
    func selectionDoesNotOutliveItsRow() async {
        let scratch = Scratch()
        let agent = Agent()
        agent.holds([
            Self.entry(uuid: "a", locator: "/x/Pictures"),
            Self.entry(uuid: "b", locator: "/x/Elsewhere"),
        ])

        let model = model(agent, scratch)
        await model.load()
        model.selection = "b"

        // `pgr_ctl` removed it, or another window did. The panel finds out on
        // its next poll, and every button reads the selection to decide what it
        // does — so a selection naming nothing is a button that acts on nothing.
        agent.holds([Self.entry(uuid: "a")])
        await model.load()

        #expect(model.selection == nil)
        #expect(!model.canRemoveSelection)
    }

    @Test("A selection that is still there survives a reload")
    func selectionSurvivesWhenTheRowDoes() async {
        let scratch = Scratch()
        let agent = Agent()
        agent.holds([
            Self.entry(uuid: "a", locator: "/x/Pictures"),
            Self.entry(uuid: "b", locator: "/x/Elsewhere"),
        ])

        let model = model(agent, scratch)
        await model.load()
        model.selection = "b"
        await model.load()

        #expect(model.selection == "b")
    }

    // MARK: - Changing

    @Test("Adding asks, and then re-reads rather than trusting its own answer")
    func addingRereads() async {
        let scratch = Scratch()
        let agent = Agent()
        agent.holds([])

        let model = model(agent, scratch)
        await model.load()
        #expect(model.sources.isEmpty)

        agent.holds([Self.entry(uuid: "new")])
        await model.add(folder: URL(filePath: "/x/Pictures"), recursive: true)

        #expect(model.sources.map(\.uuid) == ["new"])
        #expect(agent.methods.contains("POST"))
        // The list is what the agent says it is, every time — a `POST` answer
        // says what was created but not what else has changed since.
        #expect(agent.listCount == 2)
    }

    @Test("A refusal is shown and the list is left as it was")
    func refusalsAreShownWithoutLosingTheList() async {
        let scratch = Scratch()
        let agent = Agent()
        agent.holds([Self.entry(uuid: "a")])

        let model = model(agent, scratch)
        await model.load()

        agent.refuses(status: 400, body: #"{"error": "not found", "missing": ["/gone"]}"#)
        await model.add(files: [URL(filePath: "/gone")])

        #expect(model.trouble?.contains("/gone") == true)
        // Still there: nothing was added, and nothing was taken away either.
        #expect(model.sources.map(\.uuid) == ["a"])
    }

    @Test("The next thing that works clears what the last failure said")
    func successClearsTrouble() async {
        let scratch = Scratch()
        let agent = Agent()
        agent.holds([Self.entry(uuid: "a")])

        let model = model(agent, scratch)
        agent.refuses(status: 400, body: #"{"error": "no"}"#)
        await model.add(files: [URL(filePath: "/gone")])
        #expect(model.trouble != nil)

        agent.stopsRefusing()
        await model.add(folder: URL(filePath: "/x"), recursive: false)
        #expect(model.trouble == nil)
    }

    @Test("Removing the selection sends a DELETE and forgets the row first")
    func removingSends() async {
        let scratch = Scratch()
        let agent = Agent()
        agent.holds([Self.entry(uuid: "a")])

        let model = model(agent, scratch)
        await model.load()
        model.selection = "a"

        agent.holds([])
        await model.removeSelected()

        #expect(agent.methods.contains("DELETE"))
        #expect(model.selection == nil)
        #expect(model.sources.isEmpty)
    }

    @Test("Removing nothing asks nothing")
    func removingWithNoSelectionIsANoOp() async {
        let scratch = Scratch()
        let agent = Agent()
        let model = model(agent, scratch)

        await model.removeSelected()
        #expect(agent.methods.isEmpty)
    }

    // MARK: - Albums the library no longer has

    @Test("A missing album leaves the chosen line and is listed as missing, by name")
    func missingAlbumsArePartitioned() async {
        // **The picker cannot show these**, because it lists what the library
        // holds now, so the panel is the only place they can be seen. And an
        // album shown as chosen *and* as missing would be "Kids 2019" twice.
        let scratch = Scratch()
        let agent = Agent()
        agent.holds([
            Self.album(uuid: "1", title: "Favorites"),
            Self.album(uuid: "2", title: "Trip to Maine", missing: true),
            Self.album(uuid: "3", title: "Kids 2019", missing: true),
            Self.entry(uuid: "f"),
        ])

        let model = model(agent, scratch)
        await model.load()

        #expect(model.photoCollections.map(\.name) == ["Favorites"])
        #expect(model.missingCollections.map(\.name) == ["Kids 2019", "Trip to Maine"])
        #expect(model.fileSources.map(\.uuid) == ["f"], "a folder is never missing")
        #expect(
            model.missingAlbumsMessage
                == "There are missing albums: Kids 2019, Trip to Maine. Do you want to remove these references?")
    }

    @Test("One missing album is asked about in the singular, and none is not asked about")
    func missingAlbumsMessageCounts() async {
        let scratch = Scratch()
        let agent = Agent()
        let model = model(agent, scratch)

        agent.holds([Self.album(uuid: "1", title: "Favorites")])
        await model.load()
        #expect(model.missingAlbumsMessage == nil)

        agent.holds([Self.album(uuid: "2", title: "Kids 2019", missing: true)])
        await model.load()
        #expect(
            model.missingAlbumsMessage
                == "There is a missing album: Kids 2019. Do you want to remove its reference?")
    }

    @Test("An album from before names were stored still reads as something, not as nothing")
    func aNamelessMissingAlbumStillHasAName() async {
        // The two albums that started this were added before the agent kept
        // names, and the library cannot name them now. The identifier's tail
        // is a poor name, but it is a name, and the line still asks the
        // question — which is the whole reason the line exists.
        let scratch = Scratch()
        let agent = Agent()
        agent.holds([Self.album(uuid: "40", title: nil, missing: true)])

        let model = model(agent, scratch)
        await model.load()

        #expect(model.missingCollections.map(\.name) == ["040"])
        #expect(model.missingAlbumsMessage?.contains("040") == true)
    }

    @Test("Removing the missing albums sends a DELETE for each, as one change, and re-reads")
    func removingMissingAlbums() async {
        let scratch = Scratch()
        let agent = Agent()
        agent.holds([
            Self.album(uuid: "1", title: "Favorites"),
            Self.album(uuid: "2", title: "Trip to Maine", missing: true),
            Self.album(uuid: "3", title: "Kids 2019", missing: true),
        ])
        let model = model(agent, scratch)
        await model.load()

        agent.holds([Self.album(uuid: "1", title: "Favorites")])
        await model.removeMissing()

        #expect(agent.methods.filter { $0 == "DELETE" }.count == 2)
        #expect(model.missingCollections.isEmpty)
        #expect(model.photoCollections.map(\.name) == ["Favorites"], "the album that is there is untouched")
        #expect(model.trouble == nil)
    }

    @Test("Reconnect is offered when the agent found a successor for at least one missing album")
    func reconnectIsOfferedForReconnectableAlbums() async {
        let scratch = Scratch()
        let agent = Agent()
        let model = model(agent, scratch)

        agent.holds([Self.album(uuid: "2", title: "Trip to Maine", missing: true)])
        await model.load()
        #expect(!model.canReconnect, "missing, but nothing to reconnect it to")

        agent.holds([
            Self.album(uuid: "2", title: "Trip to Maine", missing: true),
            Self.album(uuid: "3", title: "Kids 2019", missing: true, reconnectable: true),
        ])
        await model.load()
        #expect(model.canReconnect)
        #expect(model.reconnectableCollections.map(\.name) == ["Kids 2019"])
        #expect(model.missingCollections.count == 2, "the other one is still listed")
    }

    @Test("Reconnecting posts to each reconnectable album, leaves the rest, and re-reads")
    func reconnectingSends() async {
        let scratch = Scratch()
        let agent = Agent()
        agent.holds([
            Self.album(uuid: "2", title: "Trip to Maine", missing: true),
            Self.album(uuid: "3", title: "Kids 2019", missing: true, reconnectable: true),
        ])
        let model = model(agent, scratch)
        await model.load()

        agent.holds([
            Self.album(uuid: "2", title: "Trip to Maine", missing: true),
            Self.album(uuid: "3", title: "Kids 2019"),
        ])
        await model.reconnectMissing()

        #expect(agent.requests.filter { $0.hasPrefix("POST") } == ["POST /v2/sources/3/reconnect"])
        #expect(model.photoCollections.map(\.name) == ["Kids 2019"], "back among the chosen")
        #expect(model.missingCollections.map(\.name) == ["Trip to Maine"], "still listed")
        #expect(model.trouble == nil)
    }

    @Test("Reconnecting with nothing reconnectable asks nothing")
    func reconnectingNothingIsANoOp() async {
        let scratch = Scratch()
        let agent = Agent()
        agent.holds([Self.album(uuid: "2", title: "Trip to Maine", missing: true)])
        let model = model(agent, scratch)
        await model.load()

        await model.reconnectMissing()
        #expect(!agent.methods.contains("POST"))
    }

    @Test("Removing missing albums when none are missing asks nothing")
    func removingNoMissingAlbumsIsANoOp() async {
        let scratch = Scratch()
        let agent = Agent()
        agent.holds([Self.album(uuid: "1", title: "Favorites")])
        let model = model(agent, scratch)
        await model.load()

        await model.removeMissing()
        #expect(!agent.methods.contains("DELETE"))
    }

    @Test("Removing missing albums is one change: busy throughout, and a second press is ignored")
    func removingMissingAlbumsIsOneChange() async {
        let scratch = Scratch()
        let agent = Agent()
        agent.holds([
            Self.album(uuid: "2", title: "Trip to Maine", missing: true),
            Self.album(uuid: "3", title: "Kids 2019", missing: true),
        ])
        let model = model(agent, scratch)
        await model.load()

        let gate = agent.holdsChangesOpen()
        let first = Task { await model.removeMissing() }
        while !gate.hasArrived { await Task.yield() }
        #expect(model.isWorking, "the panel says it is busy while the first delete is in flight")

        await model.removeMissing()
        gate.release()
        await first.value

        #expect(agent.methods.filter { $0 == "DELETE" }.count == 2, "the second press sent nothing")
        #expect(!model.isWorking)
    }

    @Test("Configure sends the change and the list comes back with it applied")
    func configureApplies() async {
        let scratch = Scratch()
        let agent = Agent()
        agent.holds([Self.entry(uuid: "a", recursive: true)])

        let model = model(agent, scratch)
        await model.load()
        #expect(model.sources.first?.recursive == true)

        agent.holds([Self.entry(uuid: "a", recursive: false)])
        await model.setRecursive(false, of: "a")

        #expect(agent.methods.contains("PATCH"))
        #expect(model.sources.first?.recursive == false)
    }

    // MARK: - Polling

    @Test("Polling asks again while the panel is open, and stops when it closes")
    func pollingAsksAndStops() async throws {
        let scratch = Scratch()
        let agent = Agent()
        agent.holds([Self.entry(uuid: "a")])
        let model = model(agent, scratch)

        model.beginPolling()
        // Bounded: it either asks or this fails. A poll that never fires is a
        // panel that shows a count of zero for ever after adding a folder.
        try await confirm(within: .seconds(2)) { agent.listCount >= 1 }
        model.endPolling()

        let settled = agent.listCount
        try await Task.sleep(for: .milliseconds(120))
        #expect(agent.listCount == settled, "it kept asking after the panel went away")
    }

    @Test("Asking to poll twice does not poll twice")
    func pollingIsIdempotent() async throws {
        let scratch = Scratch()
        let agent = Agent()
        agent.holds([])
        // A long interval, so what is counted is how many *timers* were
        // started rather than how fast they tick.
        let model = SourcesModel(
            service: SourceService(
                preferences: scratch.preferences, transport: agent.transport()),
            interval: .seconds(60), retry: .seconds(60))

        // `onAppear` fires again every time the window is reopened.
        model.beginPolling()
        model.beginPolling()
        try await confirm(within: .seconds(2)) { agent.listCount >= 1 }
        try await Task.sleep(for: .milliseconds(200))
        model.endPolling()

        #expect(agent.listCount == 1, "two timers were running, so the agent was asked twice over")
    }

    /// Waits for a condition, and fails rather than hanging when it never comes.
    private func confirm(
        within limit: Duration, _ condition: @escaping () -> Bool
    ) async throws {
        let giveUp = ContinuousClock.now + limit
        while ContinuousClock.now < giveUp {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("the condition never became true within \(limit)")
    }
}

/// What the panel does while a change is still in flight.
///
/// Reported as "I hit `−` and nothing is happening". A change blocks every other
/// change until it finishes, and until this suite there was nothing that said so
/// — the button simply stopped responding, which is indistinguishable from a
/// button that is broken.
@Suite("While a change is in flight")
@MainActor
struct InFlightTests {

    /// A throwaway preference domain that leaves nothing behind.
    ///
    /// **A path domain from `scratchSuiteName`, not a dotted one.** A dotted
    /// name lands in `~/Library/Preferences`, which `cfprefsd` owns and writes
    /// on its own schedule — including after the process that asked is gone.
    /// That is how the `removePersistentDomain` teardown that used to be here
    /// lost its race and left one plist per test behind, until a later
    /// `swift test` failed on them. See `ScratchPreferences`.
    private nonisolated final class Scratch {
        let name = scratchSuiteName("in-flight")
        var preferences: Preferences { Preferences(defaults: UserDefaults(suiteName: name)!) }
        init() { preferences.publishServicePort(9999) }
        deinit { discardScratchSuite(name) }
    }

    @Test("A second press while the first is still going is ignored, and the panel says it is busy")
    func aSecondPressIsIgnoredWhileWorking() async throws {
        let scratch = Scratch()
        let agent = SourcesModelTests.Agent()
        agent.holds([SourcesModelTests.entry(uuid: "a"), SourcesModelTests.entry(uuid: "b")])
        let model = SourcesModel(
            service: SourceService(
                preferences: scratch.preferences, transport: agent.transport()),
            interval: .seconds(60), retry: .seconds(60))
        await model.load()

        let gate = agent.holdsChangesOpen()
        model.selection = "a"
        let first = Task { await model.removeSelected() }

        // Wait for the delete to be in flight rather than for a duration.
        try await confirm(within: .seconds(2)) { gate.hasArrived }

        // **This is what "nothing is happening" is.** The panel is working and
        // the second press does nothing at all.
        #expect(model.isWorking, "the panel does not know it is busy")
        model.selection = "b"
        await model.removeSelected()
        #expect(agent.methods.filter { $0 == "DELETE" }.count == 1)

        gate.release()
        await first.value
        #expect(!model.isWorking)
    }

    @Test("Removing with nothing selected does nothing, and says nothing")
    func removingWithNoSelectionIsSilent() async throws {
        let scratch = Scratch()
        let agent = SourcesModelTests.Agent()
        agent.holds([SourcesModelTests.entry(uuid: "a")])
        let model = SourcesModel(
            service: SourceService(
                preferences: scratch.preferences, transport: agent.transport()),
            interval: .seconds(60), retry: .seconds(60))
        await model.load()

        model.selection = nil
        await model.removeSelected()

        #expect(agent.methods.filter { $0 == "DELETE" }.isEmpty)
        #expect(model.trouble == nil, "it should not report trouble for a button nobody could press")
    }

    /// Bounded waiting, so a stuck panel fails rather than hangs.
    private func confirm(
        within: Duration, _ condition: @escaping @Sendable () -> Bool
    ) async throws {
        let giveUp = ContinuousClock.now + within
        while ContinuousClock.now < giveUp {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("timed out")
    }
}
