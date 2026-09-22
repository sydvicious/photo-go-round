import Foundation
import Testing

@testable import PhotoGoRoundAgentAPI

/// Whose bell rings.
///
/// `notify_post` broadcasts machine-wide on a name alone, so a fixed topic name
/// makes every library on the Mac share one set of doorbells. Observed
/// 2026-08-25: the test suite's scratch agents, each on a throwaway database,
/// made the development agent re-enumerate all eleven of its sources three times
/// in five minutes.
@Suite("Doorbells belong to one library")
struct DoorbellScopeTests {

    private func doorbells(_ path: String) -> DarwinNotification.Doorbells {
        DarwinNotification.Doorbells(database: URL(filePath: path))
    }

    @Test("Two databases do not share a bell")
    func differentDatabasesRingDifferently() {
        let agent = doorbells("/Users/someone/Library/Containers/pgr/photogoround.sqlite")
        let scratch = doorbells("/tmp/test-9f3a/photogoround.sqlite")

        for topic in DarwinNotification.Topic.allCases {
            #expect(
                agent.name(topic) != scratch.name(topic),
                "\(topic.rawValue) is the same bell for both")
        }
    }

    @Test("The same database is the same bell, in any process and any run")
    func theSameDatabaseAgrees() {
        // The agent posts and `pgr_ctl` observes from a different process, so a
        // per-process seed — which is what `Hasher` gives you — would hand each
        // participant its own private set of bells and nothing would ever be
        // heard. This is why the hash is written out by hand.
        let one = doorbells("/var/pgr/photogoround.sqlite")
        let two = doorbells("/var/pgr/photogoround.sqlite")
        #expect(one == two)
        #expect(one.name(.sourcesChanged) == two.name(.sourcesChanged))
        #expect(one.namespace == DarwinNotification.Doorbells.namespace(for: "/var/pgr/photogoround.sqlite"))
    }

    @Test("A path is standardized first, so two spellings are one library")
    func spellingDoesNotMatter() {
        #expect(doorbells("/var/pgr/../pgr/photogoround.sqlite") == doorbells("/var/pgr/photogoround.sqlite"))
    }

    @Test("Every topic keeps its one-word name inside the scoped one")
    func topicsStayReadable() {
        // `pgr_ctl notify <topic>` takes the word, and a person reading a
        // notification name should still be able to see which bell it is.
        let bells = doorbells("/var/pgr/photogoround.sqlite")
        #expect(bells.name(.sourcesChanged).hasPrefix("com.sydpolk.photogoround."))
        #expect(bells.name(.sourcesChanged).hasSuffix(".sources"))
        #expect(DarwinNotification.Topic(rawValue: "cache") == .cacheChanged)
    }

    @Test("A Preferences built by hand rings nothing")
    func handMadePreferencesAreSilent() {
        // The default has to be silence. A test that announced a source change
        // would be telling every agent on the machine to go and rescan, which is
        // the bug this suite exists for.
        let preferences = Preferences(defaults: UserDefaults.standard)
        #expect(preferences.doorbells == nil)
    }
}
