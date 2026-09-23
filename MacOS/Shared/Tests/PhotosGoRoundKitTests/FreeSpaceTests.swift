import Foundation
import Testing

@testable import PhotosGoRoundKit

/// Free space on the cache's volume, read with `statfs(2)` so that no other
/// process can hold the answer up. See `PhotoCache.freeBytes(onVolumeOf:)`.
@Suite("Free space on the cache's volume")
struct FreeSpaceTests {

    @Test("A directory that exists reports what statfs reports")
    func existingDirectory() throws {
        let url = URL.temporaryDirectory
        var info = statfs()
        try #require(statfs(url.path(percentEncoded: false), &info) == 0)
        let expected = Int64(UInt64(info.f_bavail) * UInt64(info.f_bsize))

        let free = PhotoCache.freeBytes(onVolumeOf: url)
        #expect(free > 0)
        #expect(free < .max)
        // Other processes write meanwhile; the same volume, read twice, is
        // within a gigabyte of itself.
        #expect(abs(free - expected) < 1 << 30)
    }

    /// The cache root is made on first use, and its volume is its parent's.
    @Test("A root that does not exist yet reports its nearest existing ancestor's volume")
    func missingRoot() {
        let missing = URL.temporaryDirectory
            .appending(path: "pgr-free-\(UUID().uuidString)")
            .appending(path: "cache")
        let free = PhotoCache.freeBytes(onVolumeOf: missing)
        #expect(free > 0)
        #expect(free < .max)
        #expect(abs(free - PhotoCache.freeBytes(onVolumeOf: .temporaryDirectory)) < 1 << 30)
    }
}
