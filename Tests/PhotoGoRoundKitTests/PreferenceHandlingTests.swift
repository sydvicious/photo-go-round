import Foundation
import Testing

@testable import PhotoGoRoundKit

/// The source list in preferences, audited.
///
/// It is the one piece of state that cannot be rebuilt from anything, so every
/// fault here loses something a person chose. Each test below demonstrates a
/// defect found by reading this code on 2026-08-23, and was written to fail
/// before the fix that follows it.
@Suite("Preference handling")
struct PreferenceHandlingTests {

    private final class Scratch {
        let name = "com.sydpolk.photogoround.tests.\(UUID().uuidString)"
        var defaults: UserDefaults { UserDefaults(suiteName: name)! }
        var preferences: Preferences { Preferences(suiteName: name) }

        /// The raw array, which is what a `defaults read` would show — as
        /// against what `Preferences.sources` is willing to parse.
        var stored: [Any] { defaults.array(forKey: "sources") ?? [] }

        func store(_ entries: [[String: Any]]) { defaults.set(entries, forKey: "sources") }

        deinit {
            let defaults = UserDefaults(suiteName: name)
            defaults?.removePersistentDomain(forName: name)
            defaults?.removeSuite(named: name)
            try? FileManager.default.removeItem(
                at: URL.homeDirectory.appending(path: "Library/Preferences/\(name).plist"))
        }
    }

    // MARK: - 1. An entry it cannot read is destroyed by the next write

    /// **Data loss.** `sources` drops what it cannot parse and every mutation is
    /// read-modify-write, so one malformed entry — a hand-edited plist missing a
    /// locator — costs you that source permanently the next time anything is
    /// added or removed. The comment promised it "should cost you the bad entry,
    /// not the library"; it costs the entry, silently and for ever.
    @Test("A malformed entry survives a write it had nothing to do with")
    func unreadableEntriesAreNotDestroyed() {
        let scratch = Scratch()
        scratch.store([
            ["kind": "folder", "locator": "/tmp/one", "recursive": false, "enabled": true],
            ["kind": "folder", "recursive": true, "enabled": true],
            ["kind": "folder", "locator": "/tmp/three", "recursive": false, "enabled": true],
        ])
        #expect(scratch.stored.count == 3)
        #expect(scratch.preferences.sources.count == 2, "the bad entry should not be readable")

        scratch.preferences.addSource(.folder("/tmp/four"))

        #expect(
            scratch.stored.count == 4,
            "the entry it could not read was thrown away by an unrelated write")
    }

    // MARK: - 2. Re-adding a folder discards the options it was asked for

    /// `addSources` skips any spec whose locator is already listed, so the
    /// recursion asked for is dropped on the floor and the caller is told
    /// "nothing new".
    @Test("Adding a folder already listed applies the options it was given")
    func reAddingAppliesItsOptions() {
        let scratch = Scratch()
        scratch.preferences.addSource(.folder("/tmp/photos", recursive: false))

        scratch.preferences.addSources([.folder("/tmp/photos", recursive: true)])

        #expect(scratch.preferences.sources.count == 1)
        #expect(
            scratch.preferences.sources.first?.recursive == true,
            "the recursion that was asked for was discarded")
    }

    // MARK: - 3. A folder stored without a trailing slash strands

    /// The locator is the identity and it is matched as a bare string. Entries
    /// written before folders were normalised are stored without the slash;
    /// removing one by the normalised spelling silently fails, and the source
    /// comes straight back at the next reconcile.
    @Test("A folder stored the old way is still found by the normalised path")
    func oldSpellingsAreStillFound() {
        let scratch = Scratch()
        // What was stored before folders gained their trailing slash.
        scratch.store([
            ["kind": "folder", "locator": "/tmp/photos", "recursive": false, "enabled": true]
        ])

        #expect(
            scratch.preferences.sources.first?.locator == "/tmp/photos/",
            "an entry stored the old way reads back in the old spelling")
        #expect(
            scratch.preferences.removeSource(locator: "/tmp/photos/"),
            "removing it by the spelling everything else uses does not find it")
        #expect(scratch.preferences.sources.isEmpty)
    }

    // MARK: - 4. Forcing a re-read synchronises the wrong domain

    /// `reload` calls `CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication)`,
    /// which names *this process's own* domain — never the suite the agent's
    /// preferences live in. The agent calls it once per tick precisely to pick up
    /// a `defaults write` from another process, and it has never done that.
    @Test("Reloading names the domain the preferences are actually in")
    func reloadingUsesTheRightDomain() {
        let scratch = Scratch()
        #expect(
            Preferences(suiteName: scratch.name).synchronisedDomain == scratch.name,
            "it synchronises some other domain than the one it reads")
    }

    /// Fires once, because the other writer writes once — not on every retry.
    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func first() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if done { return false }
            done = true
            return true
        }
    }

    // MARK: - 5. A concurrent writer's change is silently lost

    /// Every mutation is read, modify, write-the-whole-array, and `UserDefaults`
    /// has no compare-and-swap. Two writers — the agent on a client's behalf and
    /// `pgr_ctl` — can each read the same list and write over each other, and the
    /// loser's source simply never appears.
    @Test("A write that lands underneath a read-modify-write is not lost")
    func concurrentWritesAreNotLost() {
        let scratch = Scratch()
        scratch.preferences.addSource(.folder("/tmp/first"))

        // Somebody else adds a source in the window between this one reading the
        // list and writing it back.
        let name = scratch.name
        let once = Once()
        let interfering = Preferences(
            suiteName: name,
            onReadingSources: {
                guard once.first() else { return }
                let other = UserDefaults(suiteName: name)!
                other.set(
                    (other.array(forKey: "sources") ?? [])
                        + [[
                            "kind": "folder", "locator": "/tmp/other/",
                            "recursive": false, "enabled": true,
                        ]],
                    forKey: "sources")
            })

        interfering.addSource(.folder("/tmp/mine"))

        let locators = Set(scratch.preferences.sources.map(\.locator))
        #expect(
            locators == ["/tmp/first/", "/tmp/other/", "/tmp/mine/"],
            "one of the two writers lost its source: \(locators.sorted())")
    }

}
