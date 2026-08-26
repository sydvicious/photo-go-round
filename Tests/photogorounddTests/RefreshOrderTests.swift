import Foundation
import Testing

@testable import PhotoGoRoundKit
@testable import photogoroundd

/// Which sources get walked first on the pass after launch.
///
/// On 2026-08-25 this library held one local folder — `~/Pictures/Desktop
/// Pictures/`, 8,287 photographs, every one readable in place — and ten network
/// folders on `/Volumes/home` holding about 10,700 between them. The local one
/// had the highest id, so in the order sources were added it was walked *last*,
/// behind minutes of network traffic. The one source that could have put a
/// picture on screen in milliseconds was the last one the agent looked at.
@Suite("Refresh order")
struct RefreshOrderTests {

    private func library() throws -> (URL, SourceStore) {
        let directory = URL.temporaryDirectory.appending(path: "pgr-order-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appending(path: "photogoround.sqlite").path(percentEncoded: false)
        let database = try Database(path: path)
        try Migrator.migrate(database)
        return (directory, SourceStore(database: database))
    }

    @Test("The local folder is walked first, however late it was added")
    func localSourceGoesFirst() async throws {
        let (directory, store) = try library()
        defer { try? FileManager.default.removeItem(at: directory) }

        // Network folders added first, exactly as this library had them, and the
        // local one added last so it has the highest id.
        for name in ["Negatives", "Prints", "Slides"] {
            try await store.add(kind: .folder, locator: "/Volumes/home/Archive/Pictures/\(name)/")
        }
        let local = directory.appending(path: "Desktop Pictures")
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        let localSource = try await store.add(
            kind: .folder, locator: local.path(percentEncoded: false) + "/")

        let ordered = RunCommand.localFirst(try store.all())
        #expect(
            ordered.first?.id == localSource.id,
            "the local folder was not walked first: \(ordered.map(\.locator))"
        )
    }

    /// The network sources keep the order they were added in, so the walk stays
    /// predictable and two runs agree.
    @Test("Ordering is stable within each group")
    func orderIsStableWithinGroups() async throws {
        let (directory, store) = try library()
        defer { try? FileManager.default.removeItem(at: directory) }

        for name in ["A", "B", "C"] {
            try await store.add(kind: .folder, locator: "/Volumes/home/\(name)/")
        }
        let ordered = RunCommand.localFirst(try store.all())
        #expect(ordered.map(\.locator) == ["/Volumes/home/A/", "/Volumes/home/B/", "/Volumes/home/C/"])
    }

    @Test("A folder that is only network keeps every source, none dropped")
    func nothingIsLost() async throws {
        let (directory, store) = try library()
        defer { try? FileManager.default.removeItem(at: directory) }

        for name in ["A", "B"] {
            try await store.add(kind: .folder, locator: "/Volumes/home/\(name)/")
        }
        let local = directory.appending(path: "here")
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        try await store.add(kind: .folder, locator: local.path(percentEncoded: false) + "/")

        let all = try store.all()
        let ordered = RunCommand.localFirst(all)
        #expect(Set(ordered.map(\.id)) == Set(all.map(\.id)))
        #expect(ordered.count == all.count)
    }

    /// A path that is not there at all must not be guessed as local. An
    /// unmounted share resolves to nothing, and treating it as fast would put
    /// the slowest possible source at the front of the pass.
    @Test("An unreachable path is not treated as local")
    func unreachablePathIsNotLocal() async throws {
        let (directory, store) = try library()
        defer { try? FileManager.default.removeItem(at: directory) }

        try await store.add(kind: .folder, locator: "/Volumes/not-mounted-\(UUID().uuidString)/")
        let source = try #require(try store.all().first)
        #expect(!RunCommand.isOnBootVolume(source))
    }

    @Test("A real local directory is recognised")
    func localDirectoryIsRecognised() async throws {
        let (directory, store) = try library()
        defer { try? FileManager.default.removeItem(at: directory) }

        let local = directory.appending(path: "pictures")
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        try await store.add(kind: .folder, locator: local.path(percentEncoded: false) + "/")
        let source = try #require(try store.all().first)
        #expect(RunCommand.isOnBootVolume(source))
    }
}
