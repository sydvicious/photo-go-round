import Foundation
import PhotoGoRoundKit
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

    @Test("A folder on an unmounted volume says so")
    func anUnmountedVolumeIsOffline() throws {
        let standing = SourcesModel.state(of: try source(locator: "/Volumes/NotMounted/Pictures"))
        #expect(!standing.available)
        #expect(standing.reason == "volume not mounted")
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
        #expect(standing.reason == "no longer at this path")
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
