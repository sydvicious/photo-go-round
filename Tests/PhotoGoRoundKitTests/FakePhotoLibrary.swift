import Foundation
import Synchronization

@testable import PhotoGoRoundAgentAPI
@testable import PhotoGoRoundKit

/// A photo library that is not one.
///
/// **A class rather than an actor, deliberately.** `enumerate` takes a
/// non-`Sendable` sink closure, and handing one across an actor boundary is a
/// data race by Swift 6's reckoning — so the fake keeps the caller's isolation
/// and guards its own state with a lock, exactly as the real binding will have
/// to. An actor here would have forced the seam's shape to bend around the
/// test, which is the wrong way round.
final class FakePhotoLibrary: PhotoLibrary, @unchecked Sendable {

    /// **A class rather than an actor, deliberately.** `enumerate` takes a
    /// non-`Sendable` sink closure, and handing one across an actor boundary is
    /// a data race by Swift 6's reckoning — so the fake keeps the caller's
    /// isolation, exactly as the real binding will have to. An actor here would
    /// have bent the seam's shape around the test, which is the wrong way round.
    ///
    /// Everything it is configured with is immutable, so the only thing needing
    /// a lock is the record of what was written.
    struct Write: Sendable, Equatable {
        let asset: String
        let resource: LibraryResource
    }

    private let authorizationValue: LibraryAuthorization
    /// Collection identifier to title. Absent means it does not resolve, which
    /// is both "deleted" and "different library" and is deliberately not
    /// distinguishable — because in PhotoKit it is not.
    private let titles: [String: String]
    private let assets: [String: [LibraryAsset]]
    private let resourcesByAsset: [String: [LibraryResource]]

    /// Every resource written, so a test can assert *which* one was taken
    /// rather than only that something was.
    private let writes = Mutex<[Write]>([])
    var written: [Write] { writes.withLock { $0 } }

    init(
        authorization: LibraryAuthorization = .authorized,
        titles: [String: String] = [:],
        assets: [String: [LibraryAsset]] = [:],
        resources: [String: [LibraryResource]] = [:]
    ) {
        self.authorizationValue = authorization
        self.titles = titles
        self.assets = assets
        self.resourcesByAsset = resources
    }

    var authorization: LibraryAuthorization { get async { authorizationValue } }

    func title(ofCollection identifier: String) async -> String? { titles[identifier] }

    @discardableResult
    func enumerateImages(
        inCollection identifier: String,
        _ body: (LibraryAsset) async throws -> Void
    ) async throws -> Bool {
        guard titles[identifier] != nil else { return false }
        for asset in assets[identifier] ?? [] { try await body(asset) }
        return true
    }

    func assetExists(_ identifier: String) async -> Bool {
        assets.values.contains { $0.contains { $0.identifier == identifier } }
    }

    func resources(ofAsset identifier: String) async -> [LibraryResource] {
        resourcesByAsset[identifier] ?? []
    }

    func write(
        _ resource: LibraryResource, ofAsset identifier: String, to destination: URL
    ) async throws -> Int64 {
        writes.withLock { $0.append(Write(asset: identifier, resource: resource)) }
        let bytes = Data(repeating: 0x2A, count: 1024)
        try bytes.write(to: destination)
        return Int64(bytes.count)
    }
}

extension FakePhotoLibrary {
    /// The resource list of an **edited Live Photo**, in the order PhotoKit
    /// gave it on 2026-08-25. Two of the five are QuickTime movies and the one
    /// that most resembles what we want is one of them.
    static let editedLivePhoto: [LibraryResource] = [
        LibraryResource(kind: .photo, uniformTypeIdentifier: "public.heic", originalFilename: "IMG_2650.HEIC"),
        LibraryResource(kind: .adjustmentData, uniformTypeIdentifier: "com.apple.property-list", originalFilename: "Adjustments.plist"),
        LibraryResource(kind: .pairedVideo, uniformTypeIdentifier: "com.apple.quicktime-movie", originalFilename: "IMG_2650.MOV"),
        LibraryResource(kind: .fullSizePairedVideo, uniformTypeIdentifier: "com.apple.quicktime-movie", originalFilename: "FullSizeRender.mov"),
        LibraryResource(kind: .fullSizePhoto, uniformTypeIdentifier: "public.heic", originalFilename: "FullSizeRender.heic"),
    ]

    /// An unedited Live Photo: the still and its movie, nothing else.
    static let uneditedLivePhoto: [LibraryResource] = [
        LibraryResource(kind: .photo, uniformTypeIdentifier: "public.jpeg", originalFilename: "IMG_3309.JPG"),
        LibraryResource(kind: .pairedVideo, uniformTypeIdentifier: "com.apple.quicktime-movie", originalFilename: "IMG_3309.MOV"),
    ]
}

/// A Photos source, as the store would have stored one.
func photosSource(locator: String, id: Int64 = 1) -> Source {
    Source(
        id: id, uuid: "SOURCE-\(id)", kind: .photosCollection, locator: locator,
        addedAt: Date(timeIntervalSince1970: 0))
}
