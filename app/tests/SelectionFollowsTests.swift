import Foundation
import PhotoGoRoundKit
import Testing

@testable import Photo_Go_Round

/// A row that looks selected must *be* selected.
///
/// Reported as "I hit `−` once and nothing happened". The button is enabled only
/// when the model has something selected, and a source can keep its place in the
/// list while changing identity — anything that takes it out of the durable list
/// and puts it back mints a new `uuid`. The row then still looked chosen while
/// every control read *nothing selected*, so the one click went nowhere and
/// there was no way to tell why.
@Suite("The selection follows its source")
@MainActor
struct SelectionFollowsTests {

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

    private func model(_ agent: SourcesModelTests.Agent, _ scratch: Scratch) -> SourcesModel {
        SourcesModel(
            service: SourceService(
                preferences: scratch.preferences, transport: agent.transport()),
            interval: .seconds(60), retry: .seconds(60))
    }

    @Test("A source that comes back with a new identity keeps the selection")
    func selectionFollowsANewUUID() async throws {
        let scratch = Scratch()
        let agent = SourcesModelTests.Agent()
        agent.holds([SourcesModelTests.entry(uuid: "before", locator: "/x/Pictures")])
        let model = model(agent, scratch)
        await model.load()

        model.selection = "before"
        #expect(model.canRemoveSelection)

        // Same folder, new identity — what removing it from the durable list and
        // putting it back produces.
        agent.holds([SourcesModelTests.entry(uuid: "after", locator: "/x/Pictures")])
        await model.load()

        #expect(model.selection == "after", "the selection was dropped, so the row went dead")
        #expect(model.canRemoveSelection, "the row still looks selected but nothing can act on it")
    }

    @Test("A source that is genuinely gone clears the selection")
    func selectionClearsWhenItIsReallyGone() async throws {
        let scratch = Scratch()
        let agent = SourcesModelTests.Agent()
        agent.holds([
            SourcesModelTests.entry(uuid: "a", locator: "/x/Pictures"),
            SourcesModelTests.entry(uuid: "b", locator: "/x/More"),
        ])
        let model = model(agent, scratch)
        await model.load()
        model.selection = "a"

        // Removed for real: no source at that path any more.
        agent.holds([SourcesModelTests.entry(uuid: "b", locator: "/x/More")])
        await model.load()

        #expect(model.selection == nil)
        #expect(!model.canRemoveSelection)
    }

    @Test("It does not wander onto a different source")
    func selectionDoesNotWander() async throws {
        let scratch = Scratch()
        let agent = SourcesModelTests.Agent()
        agent.holds([
            SourcesModelTests.entry(uuid: "a", locator: "/x/Pictures"),
            SourcesModelTests.entry(uuid: "b", locator: "/x/More"),
        ])
        let model = model(agent, scratch)
        await model.load()
        model.selection = "a"

        // `a`'s folder is gone and only `b` remains. Following by locator must
        // not land on `b` — that would delete something the user never chose.
        agent.holds([SourcesModelTests.entry(uuid: "b", locator: "/x/More")])
        await model.load()

        #expect(model.selection == nil)
    }
}
