import Foundation
import PhotoGoRoundAgentAPI
import Testing

@testable import Photo_Go_Round

/// Where a source stands, decided by the app rather than reported to it.
///
/// The agent's answer is a round trip old before it is drawn, and it is only as
/// fresh as the last scan besides — a drive remounted a minute ago still reads
/// "volume not mounted" on the row for up to five minutes. This app is
/// unsandboxed and already has the path, so it asks the filesystem itself, with
/// the kit's own rule so the two ends cannot disagree about what unavailable
/// means.
@Suite("Where a source stands")
struct SourceStandingTests {

    private func source(
        kind: String = "folder", locator: String, available: Bool = true, reason: String? = nil
    ) throws -> SourceService.Source {
        var entry: [String: Any] = [
            "uuid": "u", "kind": kind, "locator": locator, "enabled": true,
            "available": available, "photos": 1, "addedAt": "2026-08-23T18:04:11Z",
        ]
        if let reason { entry["unavailableReason"] = reason }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(
            SourceService.Source.self, from: try JSONSerialization.data(withJSONObject: entry))
    }

    @Test("A folder that is there is available, whatever the agent last concluded")
    func aPresentFolderIsAvailable() throws {
        let directory = URL.temporaryDirectory.appending(path: "pgr-standing-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        // The agent says it is unavailable, because that is what the last scan
        // found while the drive was out. The folder is right there now.
        let stale = try source(
            locator: directory.path(percentEncoded: false),
            available: false, reason: "volume not mounted")

        let standing = SourcesModel.state(of: stale)
        #expect(standing.available)
        #expect(standing.reason == nil)
    }

    /// **"Not online" rather than "volume not mounted".** A laptop leaves the
    /// house and a NAS goes to sleep; that is the ordinary case, not an error,
    /// and the machine's phrasing of it reads like something has gone wrong.
    /// The noun matches the row, which says *folder* everywhere else.
    @Test("A folder on an unmounted volume says it is not online")
    func anUnmountedVolumeIsOffline() throws {
        let standing = SourcesModel.state(of: try source(locator: "/Volumes/NotMounted/Pictures"))
        #expect(!standing.available)
        #expect(standing.reason == "Folder is not online.")
    }

    /// The same fact about a file says *file*, because that is what its row
    /// calls it.
    @Test("A file on an unmounted volume says file, not folder")
    func anUnmountedFileSaysFile() throws {
        let standing = SourcesModel.state(
            of: try source(kind: "file", locator: "/Volumes/NotMounted/One.jpg"))
        #expect(!standing.available)
        #expect(standing.reason == "File is not online.")
    }

    @Test("A folder deleted from a volume that is mounted says something different")
    func aDeletedFolderIsGone() throws {
        let directory = URL.temporaryDirectory.appending(path: "pgr-standing-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let inside = directory.appending(path: "Pictures")
        // Its parent exists and is readable, so its absence means something.
        defer { try? FileManager.default.removeItem(at: directory) }

        let standing = SourcesModel.state(of: try source(locator: inside.path(percentEncoded: false)))
        #expect(!standing.available)
        // Deleted from a volume that is right there is a different fact from a
        // volume that is away, and must not read as temporary.
        #expect(standing.reason == "Folder is no longer there.")
    }

    @Test("A single file is checked the same way")
    func aFileIsCheckedToo() throws {
        let directory = URL.temporaryDirectory.appending(path: "pgr-standing-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "pinned.png")
        try Data([1, 2, 3]).write(to: file)

        #expect(
            SourcesModel.state(
                of: try source(kind: "file", locator: file.path(percentEncoded: false))
            ).available)

        try FileManager.default.removeItem(at: file)
        #expect(
            !SourcesModel.state(
                of: try source(kind: "file", locator: file.path(percentEncoded: false))
            ).available)
    }

    @Test("A kind this process cannot see keeps whatever the agent said")
    func unseeableKindsKeepTheAgentsAnswer() throws {
        // A Photos album is not a path, and only the agent can put the question.
        // Checking it here would report every one of them as missing.
        let album = try source(
            kind: "photos_collection", locator: "album-identifier",
            available: false, reason: "photo library access was refused")

        let standing = SourcesModel.state(of: album)
        #expect(!standing.available)
        #expect(standing.reason == "photo library access was refused")
    }
}
