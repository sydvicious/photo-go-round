import Foundation
import Testing

@testable import PhotoGoRoundKit

/// Eviction always leaves one photo, whatever the ceiling says.
///
/// **A never-blank frame outranks the ceiling.** The ceiling exists to bound
/// disk, and a cache holding nothing bounds it perfectly while making the
/// product do the one thing it must never do. So the last photo standing is
/// exempt, and a single file larger than the whole budget is simply held.
///
/// It also makes a very small cache a usable setting rather than a way to
/// switch the product off.
@Suite("The last photo standing")
struct LastPhotoStandingTests {

    private static func temporaryRoot() -> URL {
        URL.temporaryDirectory.appending(path: "pgr-lastphoto-\(UUID().uuidString)")
    }

    @discardableResult
    private static func store(
        _ bytes: Int, as photo: String, in store: PhotoStore
    ) throws -> String {
        try store.store(
            Data(count: bytes), for: .init(photoUUID: photo),
            sourceUUID: "SOURCE", pathExtension: "heic")
        return photo
    }

    @Test("One photo larger than the entire ceiling is kept rather than evicted")
    func oneOversizedPhotoSurvives() throws {
        let root = Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PhotoStore(root: root.appending(path: "cache"), byteCeiling: 100)

        let photo = UUID().uuidString.lowercased()
        try Self.store(5_000, as: photo, in: store)
        _ = store.rebuild(photos: [photo: "SOURCE"])

        let result = store.evictIfNeeded(inOrder: [photo])

        #expect(result.evicted == 0)
        #expect(store.url(for: .init(photoUUID: photo)) != nil)
    }

    @Test("With a ceiling too small for any of them, the most recently shown one stays")
    func theMostRecentlyShownSurvives() throws {
        let root = Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PhotoStore(root: root.appending(path: "cache"), byteCeiling: 100)

        let oldest = UUID().uuidString.lowercased()
        let middle = UUID().uuidString.lowercased()
        let newest = UUID().uuidString.lowercased()
        for photo in [oldest, middle, newest] { try Self.store(5_000, as: photo, in: store) }
        _ = store.rebuild(photos: [oldest: "SOURCE", middle: "SOURCE", newest: "SOURCE"])

        // Oldest-first, which is the order `evictionOrder()` produces.
        let result = store.evictIfNeeded(inOrder: [oldest, middle, newest])

        #expect(result.evicted == 2)
        #expect(store.url(for: .init(photoUUID: oldest)) == nil)
        #expect(store.url(for: .init(photoUUID: middle)) == nil)
        #expect(store.url(for: .init(photoUUID: newest)) != nil)
    }

    /// The guard against an exemption that quietly stops eviction working. A
    /// ceiling that *can* be met must still be met exactly.
    @Test("A ceiling that can be met is still met")
    func ordinaryEvictionIsUnchanged() throws {
        let root = Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PhotoStore(root: root.appending(path: "cache"), byteCeiling: 2_500)

        let photos = (0..<4).map { _ in UUID().uuidString.lowercased() }
        for photo in photos { try Self.store(1_000, as: photo, in: store) }
        _ = store.rebuild(photos: Dictionary(uniqueKeysWithValues: photos.map { ($0, "SOURCE") }))

        let result = store.evictIfNeeded(inOrder: photos)

        // Four thousand bytes against a ceiling of two and a half: two go.
        #expect(result.evicted == 2)
        #expect(store.totals.byteCount <= 2_500)
    }

    /// Where the floor sits. A rendering is a photo somebody can be shown, so
    /// keeping the original as well would have missed a ceiling that dropping
    /// it meets exactly — which is what `RendererTests` had been asserting
    /// since before this exemption existed.
    @Test("An original still goes when its own rendering can survive instead")
    func theRuleIsPerEntryNotPerPhoto() throws {
        let root = Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PhotoStore(root: root.appending(path: "cache"), byteCeiling: 600)

        let photo = UUID().uuidString.lowercased()
        try Self.store(500, as: photo, in: store)
        try store.store(
            Data(count: 400),
            for: .init(photoUUID: photo, size: .init(width: 200, height: 200)),
            sourceUUID: "SOURCE", pathExtension: "jpeg")
        _ = store.rebuild(photos: [photo: "SOURCE"])

        let result = store.evictIfNeeded(inOrder: [photo])

        #expect(result.evicted == 1)
        #expect(store.url(for: .init(photoUUID: photo)) == nil)
        #expect(store.url(for: .init(photoUUID: photo, size: .init(width: 200, height: 200))) != nil)
    }

    /// **The exemption is a floor, not a privilege.** Nothing about the
    /// oversized photo is protected — it was kept only while it was the one
    /// thing standing between the product and a blank frame. The moment
    /// anything else can hold that position, the ceiling applies to it like
    /// everything else, and a cache that had room for one picture has room for
    /// many again.
    @Test("The oversized survivor is evicted as soon as a smaller photo arrives")
    func theOversizedOneMakesWayForNewcomers() throws {
        let root = Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PhotoStore(root: root.appending(path: "cache"), byteCeiling: 1_000)

        let giant = UUID().uuidString.lowercased()
        try Self.store(5_000, as: giant, in: store)
        _ = store.rebuild(photos: [giant: "SOURCE"])
        store.evictIfNeeded(inOrder: [giant])
        #expect(store.url(for: .init(photoUUID: giant)) != nil)

        // Something smaller arrives. The giant is older, so it is first in the
        // eviction order and no longer the last entry standing.
        let small = UUID().uuidString.lowercased()
        try Self.store(200, as: small, in: store)
        _ = store.rebuild(photos: [giant: "SOURCE", small: "SOURCE"])

        let result = store.evictIfNeeded(inOrder: [giant, small])

        #expect(result.evicted == 1)
        #expect(store.url(for: .init(photoUUID: giant)) == nil)
        #expect(store.url(for: .init(photoUUID: small)) != nil)
        #expect(store.totals.byteCount == 200)
    }

    @Test("An empty cache has nothing to protect and does not invent anything")
    func anEmptyCacheStaysEmpty() throws {
        let root = Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PhotoStore(root: root.appending(path: "cache"), byteCeiling: 0)

        let result = store.evictIfNeeded(inOrder: [])

        #expect(result.evicted == 0)
        #expect(store.totals.entries == 0)
    }
}
