import Foundation
import Testing

@testable import PhotoGoRoundKit
@testable import photogoroundd
@testable import PhotoGoRoundAgentAPI

/// What a run does to the published port, over its whole life.
///
/// The port is the one piece of state a run leaves behind in a domain another
/// agent may be using, so these pin the two edges: a one-pass run must not
/// touch it, and a signalled stop must take it down.
@Suite("Agent lifecycle", .serialized)
struct AgentLifecycleTests {

    /// A throwaway preference domain, torn down with the test.
    private final class Suite_ {
        let name: String
        init() { name = "com.sydpolk.photogoround.tests.lifecycle-\(UUID().uuidString)" }
        deinit {
            UserDefaults(suiteName: name).map { $0.removePersistentDomain(forName: name) }
        }
    }

    @Test("A --once run never publishes or disturbs the published port")
    func oncePublishesNothing() async throws {
        let suite = Suite_()
        let directory = URL.temporaryDirectory.appending(path: "pgr-once-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        // A couple of files to scan, so the pass does real work while any
        // listener that was wrongly started has every chance to become ready.
        let folder = directory.appending(path: "photos")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for index in 0..<2 {
            FileManager.default.createFile(
                atPath: folder.appending(path: "photo-\(index).jpg").path(percentEncoded: false),
                contents: Data([0xFF, 0xD8, 0xFF]))
        }

        let environment = MacHostEnvironment(
            deployment: .development,
            containerOverride: directory.appending(path: "container"),
            cacheOverride: directory.appending(path: "cache"),
            environment: ["PGR_PREFS_SUITE": suite.name]
        )

        // A long-running agent has already published its address in this
        // domain. The one-pass run must leave it exactly as it found it.
        environment.preferences.publishServicePort(4242)

        try await RunCommand(
            environment: environment,
            foldersToAdd: [(url: folder, recursive: false)],
            tick: .milliseconds(10),
            once: true,
            scanIntervalOverride: nil,
            servicePort: nil
        ).run()

        // A wrongly started listener publishes from its own queue, so give a
        // late ready callback every chance to land before looking.
        try await Task.sleep(for: .milliseconds(300))
        environment.preferences.reload()
        #expect(environment.preferences.servicePort == 4242)
    }

    @Test("SIGTERM withdraws the published port on the way out")
    func sigtermWithdrawsThePort() async throws {
        let suite = Suite_()
        let directory = URL.temporaryDirectory.appending(path: "pgr-term-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        // The built agent sits beside the test bundle's parent directory.
        let binary = Bundle(for: Marker.self).bundleURL
            .deletingLastPathComponent()
            .appending(path: "photogoroundd")
        try #require(
            FileManager.default.fileExists(atPath: binary.path(percentEncoded: false)),
            "photogoroundd binary not found next to the test bundle")

        let process = Process()
        process.executableURL = binary
        process.environment = [
            "PGR_CONTAINER": directory.path(percentEncoded: false),
            "PGR_PREFS_SUITE": suite.name,
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()

        // The agent publishes once its listener is ready; wait for that fact to
        // cross the process boundary.
        let preferences = Preferences(suiteName: suite.name)
        var published: UInt16?
        for _ in 0..<200 {
            preferences.reload()
            if let port = preferences.servicePort { published = port; break }
            try await Task.sleep(for: .milliseconds(50))
        }
        guard published != nil else {
            process.terminate()
            process.waitUntilExit()
            Issue.record("the agent never published a port")
            return
        }

        process.terminate()  // SIGTERM
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)

        preferences.reload()
        #expect(preferences.servicePort == nil, "the published port outlived the agent")
    }

    /// Only here so the test bundle can be located on disk.
    private final class Marker {}
}
