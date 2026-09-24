import Foundation
import Testing

@testable import PhotosGoRoundAgentAPI
@testable import PhotosGoRoundKit

/// The first asset of a walk has a bound of its own.
///
/// **Because the first asset waits on the fetch.** On 2026-09-23, forty seconds
/// after a reboot, a cold `photolibraryd` took more than the ten-second gap
/// bound to produce the first asset of either album, and both went dark for
/// five minutes. See `BoundedPhotoLibrary.firstAssetLimit`.
///
/// **Neither test races a clock it can lose.** The slow first answer is bounded
/// by a minute, far above anything a loaded machine adds; the silent one never
/// answers, so the only outcome is the bound firing.
@Suite("A walk's first asset")
struct FirstAssetBoundTests {

    /// A library that takes its time before the walk begins, then finds an
    /// empty album — so the whole walk is the first gap.
    private struct SlowToStart: PhotoLibrary {
        let delay: Duration

        @discardableResult
        func enumerateImages(
            inCollection identifier: String, _ body: (LibraryAsset) async throws -> Void
        ) async throws -> Bool {
            try await Task.sleep(for: delay)
            return true
        }

        var authorization: LibraryAuthorization { get async throws { .authorized } }
        func requestAuthorization() async -> LibraryAuthorization { .authorized }
        func collections() async throws -> [LibraryCollection] { [] }
        func folderPaths() async throws -> [String: [String]] { [:] }
        func imageCount(ofCollection identifier: String) async throws -> Int? { nil }
        func title(ofCollection identifier: String) async throws -> String? { "Album" }
        func assetExists(_ identifier: String) async throws -> Bool { true }
        func resources(ofAsset identifier: String) async throws -> [LibraryResource] { [] }
        func write(
            _ resource: LibraryResource, ofAsset identifier: String, to destination: URL
        ) async throws -> Int64 { 0 }
    }

    /// **The case from the boot, stated as a property.** A first answer slower
    /// than the gap bound is still an answer.
    @Test("A walk slower to start than the gap bound still finishes")
    func aSlowStartIsNotSilence() async throws {
        let library = BoundedPhotoLibrary(
            SlowToStart(delay: .milliseconds(500)),
            metadata: .milliseconds(100), firstAsset: .seconds(60))

        #expect(try await library.enumerateImages(inCollection: "A") { _ in })
    }

    /// And the first bound is a bound: a library that never starts is caught
    /// by it, not by the gap bound after it.
    @Test("A walk that never starts is ended by the first-asset bound")
    func silenceAtTheStartIsBounded() async {
        let library = BoundedPhotoLibrary(
            SlowToStart(delay: .seconds(300)),
            metadata: .seconds(300), firstAsset: .milliseconds(100))

        await #expect(throws: PhotoLibraryError.self) {
            try await library.enumerateImages(inCollection: "A") { _ in }
        }
    }

    @Test("A walk's line says how long the first asset took")
    func theWalkLine() {
        #expect(
            BoundedPhotoLibrary.walkLine(
                "EE63/L0/040", firstAnswer: .milliseconds(11_250), delivered: 8552,
                took: .milliseconds(21_400), finished: true)
                == "WALK: EE63/L0/040 · first asset 11250ms · 8552 assets · 21400ms")
        #expect(
            BoundedPhotoLibrary.walkLine(
                "A", firstAnswer: nil, delivered: 0, took: .seconds(60), finished: false)
                == "WALK: A · first asset none · 0 assets · 60000ms · stopped")
    }
}
