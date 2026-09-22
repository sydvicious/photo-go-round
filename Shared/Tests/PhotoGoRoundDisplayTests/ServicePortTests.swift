import Foundation
import Testing

@testable import PhotoGoRoundAgentAPI
@testable import PhotoGoRoundDisplay

/// Finding the agent from a process that may not be allowed to ask.
///
/// **These exist because of a measurement rather than a hunch.** The Phase 1
/// screensaver spike, 2026-09-07, found that a sandboxed process is handed a
/// preference suite that opens cleanly and holds nothing — so *refused* and
/// *nothing published* are the same observation, and everything below is about
/// keeping the two apart once the file is consulted.
@Suite("Finding the service port")
struct ServicePortTests {

    // MARK: - Where the file is

    /// The shape `UserDefaults` uses for an ordinary reverse-DNS domain.
    @Test("A dotted domain lives under the real home, not the container")
    func dottedDomainPath() throws {
        let preferences = Preferences(suiteName: "com.sydpolk.photogoround.dev")
        let url = try #require(ServicePort.plistURL(for: preferences))
        #expect(url.lastPathComponent == "com.sydpolk.photogoround.dev.plist")
        #expect(url.deletingLastPathComponent().path().hasSuffix("Library/Preferences/"))
        // **The whole point of `getpwuid`.** Inside a sandbox `NSHomeDirectory()`
        // is the host's container, which holds none of our preferences; this
        // path has to be the real one or the fallback reads nothing.
        #expect(url.path().hasPrefix(ServicePort.realHome()))
    }

    /// The shape the test suites use, and one `CFPreferences` has always
    /// accepted — `defaults read /path/to/file` is the same feature.
    @Test("A path-named domain keeps its plist beside itself")
    func pathDomainPath() throws {
        let name = scratchSuiteName("service-port-shape")
        defer { discardScratchSuite(name) }
        let url = try #require(ServicePort.plistURL(for: Preferences(suiteName: name)))
        #expect(url.path(percentEncoded: false) == "\(name).plist")
    }

    /// Standard defaults are not one file, so there is nothing to fall back to.
    @Test("Standard defaults name no file")
    func noDomainNoFile() {
        #expect(ServicePort.plistURL(for: Preferences(defaults: .standard)) == nil)
    }

    // MARK: - The suite, when it answers

    @Test("A port in the suite is used, and reported as coming from the suite")
    func suiteWins() {
        let name = scratchSuiteName("service-port-suite")
        defer { discardScratchSuite(name) }
        let preferences = Preferences(suiteName: name)
        preferences.publishServicePort(9000)

        #expect(ServicePort.read(preferences) == .published(9000, from: .suite))
    }

    // MARK: - The file, when the suite does not

    /// **A domain nothing ever wrote is not a refusal.** It is the ordinary
    /// state of a machine where the agent has never run, and calling it
    /// unreadable would send somebody hunting a sandbox that is not in the way.
    @Test("A domain with no file at all is none, not unreadable")
    func missingFileIsNone() throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "never-written.plist")

        #expect(ServicePort.readFile(at: url) == .none)
    }

    /// The case the whole type exists for: the suite came back empty and the
    /// file has the answer.
    @Test("A port in the file is used, and reported as coming from the file")
    func fileCarriesThePort() throws {
        let url = try Self.plist(["servicePort": 51234])
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        #expect(ServicePort.readFile(at: url) == .published(51234, from: .file))
    }

    /// A file that parses and simply has no port means the agent stopped
    /// cleanly and withdrew it.
    @Test("A file without the key is none")
    func fileWithoutTheKey() throws {
        let url = try Self.plist(["queueSize": 40])
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        #expect(ServicePort.readFile(at: url) == .none)
    }

    /// `defaults write` accepts anything, and a port outside the range a port
    /// can occupy is not one — the same rule `Preferences` applies to the suite.
    @Test("A port outside the range a port can hold is none")
    func portOutOfRange() throws {
        let url = try Self.plist(["servicePort": 70000])
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        #expect(ServicePort.readFile(at: url) == .none)
    }

    /// **The case that must not be silent.** Something is there, it cannot be
    /// read, and whether a port is published is unknown — which is a different
    /// predicament from there being none, and sends somebody somewhere else.
    @Test("A file that will not parse is unreadable, not empty")
    func unparseableIsUnreadable() throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "junk.plist")
        try Data("this is not a property list".utf8).write(to: url)

        guard case .unreadable = ServicePort.readFile(at: url) else {
            Issue.record("a file of junk read as \(ServicePort.readFile(at: url))")
            return
        }
    }

    // MARK: - Support

    private static func temporaryDirectory() throws -> URL {
        let url = URL.temporaryDirectory.appending(path: "pgr-service-port-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func plist(_ contents: [String: Any]) throws -> URL {
        let directory = try temporaryDirectory()
        let url = directory.appending(path: "domain.plist")
        let data = try PropertyListSerialization.data(
            fromPropertyList: contents, format: .binary, options: 0)
        try data.write(to: url)
        return url
    }
}
