import Foundation
import Testing

@testable import PhotoGoRoundKit
@testable import pgr_ctl
@testable import PhotoGoRoundAgentAPI

/// `refresh` asks the agent and returns; it does not walk anything.
///
/// The walk it used to do was the same walk the agent does, so a network share
/// was enumerated twice — and because a refresh only prints what *changed*, the
/// terminal sat silent for minutes while it happened.
@Suite("pgr_ctl refresh")
struct RefreshCommandTests {

    /// A throwaway defaults suite, so a test never writes into the preferences
    /// of whoever is running it.
    private final class Scratch {
        let name = scratchSuiteName("refresh")
        var environment: MacHostEnvironment {
            MacHostEnvironment(
                deployment: .development,
                environment: ["PGR_PREFS_SUITE": name, "PGR_CONTAINER": directory.path(percentEncoded: false)])
        }
        let directory = URL.temporaryDirectory.appending(path: "pgr-refresh-\(UUID().uuidString)")

        init() {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        deinit {
            try? FileManager.default.removeItem(at: directory)
            discardScratchSuite(name)
        }
    }

    @Test("It returns without opening the library, so a missing one is not an error")
    func refreshDoesNotNeedALibrary() async throws {
        let scratch = Scratch()
        // No database, no sources, no agent. Every other verb refuses here,
        // because an empty library is almost always the wrong container — but
        // this one is a message, and a message costs nothing to send.
        try await SourceCommands.refresh(sourceID: nil, environment: scratch.environment)
    }

    @Test("Naming one source is refused rather than quietly ignored")
    func perSourceRefreshIsRefused() async throws {
        _ = Refusals.installed
        let scratch = Scratch()
        // The doorbell carries no payload, so "only this one" cannot be said.
        // Accepting the flag and refreshing everything would be worse than
        // refusing it.
        await #expect(throws: ExitCode.self) {
            try await SourceCommands.refresh(sourceID: 3, environment: scratch.environment)
        }

        // **The refusal has to name the way out.** Being told no without being
        // told what to do instead is where a person goes looking in the source.
        #expect(Refusals.all.contains { $0.contains("Drop --source") })
        #expect(Refusals.all.contains { $0.contains("#3") })
    }
}
