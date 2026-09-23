import Foundation
import Testing

@testable import PhotosGoRoundAgentAPI
@testable import pgr_ctl

/// `status` says whether the secret is published beside the port, and never
/// what it is. `Plans/Multi-user Support.md`, *Clients*.
@Suite("pgr_ctl status and the secret")
struct StatusSecretTests {

    private final class Scratch {
        let name = scratchSuiteName("status-secret")
        var preferences: Preferences { Preferences(suiteName: name) }
        deinit { discardScratchSuite(name) }
    }

    @Test("A published secret is said to be there, and not shown")
    func publishedIsNotShown() throws {
        let scratch = Scratch()
        let secret = try #require(scratch.preferences.establishServiceSecret())
        let line = InspectCommands.describeSecret(scratch.preferences)

        #expect(line.contains("secret published"))
        #expect(!line.contains(secret))
    }

    @Test("A missing secret is said to mean every request will be refused")
    func missingIsSaid() {
        let scratch = Scratch()
        #expect(InspectCommands.describeSecret(scratch.preferences).contains("no secret published"))
    }
}
