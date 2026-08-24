import Foundation
import PhotoGoRoundKit
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

    private nonisolated final class Scratch {
        let name = "com.sydpolk.photogoround.tests.\(UUID().uuidString)"
        var preferences: Preferences { Preferences(defaults: UserDefaults(suiteName: name)!) }

        init() { preferences.publishServicePort(9999) }

        deinit {
            let defaults = UserDefaults(suiteName: name)
            defaults?.removePersistentDomain(forName: name)
            defaults?.removeSuite(named: name)
            try? FileManager.default.removeItem(
                at: URL.homeDirectory.appending(path: "Library/Preferences/\(name).plist"))
        }
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

        var methods: [String] { lock.withLock { asked } }
        var listCount: Int { lock.withLock { asked.filter { $0 == "GET" }.count } }

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
                let (refusing, held) = lock.withLock {
                    asked.append(method)
                    return (refusal, listing)
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
                return (
                    method == "GET" ? held : Data("[]".utf8),
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
        scanned: Bool = true
    ) -> [String: Any] {
        var entry: [String: Any] = [
            "uuid": uuid, "kind": kind, "locator": locator, "enabled": true,
            "available": available, "photos": photos, "addedAt": "2026-08-23T18:04:11Z",
        ]
        if let recursive { entry["recursive"] = recursive }
        if scanned { entry["scannedAt"] = "2026-08-23T18:04:12Z" }
        return entry
    }

    /// Intervals in milliseconds, not the panel's minutes: these tests are
    /// about *whether* it polls and stops, and waiting three real minutes to
    /// find out is a test nobody runs.
    private func model(_ agent: Agent, _ scratch: Scratch) -> SourcesModel {
        SourcesModel(
            service: SourceService(
                preferences: scratch.preferences, transport: agent.transport()),
            interval: .milliseconds(20), retry: .milliseconds(20))
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

    private nonisolated final class Scratch {
        let name = "com.sydpolk.photogoround.tests.\(UUID().uuidString)"
        var preferences: Preferences { Preferences(defaults: UserDefaults(suiteName: name)!) }
        init() { preferences.publishServicePort(9999) }
        deinit {
            let defaults = UserDefaults(suiteName: name)
            defaults?.removePersistentDomain(forName: name)
            defaults?.removeSuite(named: name)
            try? FileManager.default.removeItem(
                at: URL.homeDirectory.appending(path: "Library/Preferences/\(name).plist"))
        }
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
