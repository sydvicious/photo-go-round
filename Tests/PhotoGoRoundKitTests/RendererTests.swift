import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import PhotoGoRoundKit

@Suite("Rendering")
struct RendererTests {

    /// A real image on disk, since the renderer's whole job is reading one.
    private func write(width: Int, height: Int, to url: URL) throws {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = context.makeImage()!
        let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
    }

    private func temporary() -> URL {
        URL.temporaryDirectory.appending(path: "pgr-render-\(UUID().uuidString)")
    }

    // MARK: - The fit

    @Test("A landscape photo fits a landscape box by its height")
    func landscapeIntoLandscape() {
        // 4000×3000 into 3840×2160 is height-limited: 2880×2160, not 3840×2880.
        let fitted = PhotoRenderer.fit(
            sourceWidth: 4000, sourceHeight: 3000, intoWidth: 3840, byHeight: 2160)
        #expect(fitted.width == 2880)
        #expect(fitted.height == 2160)
    }

    @Test("The same photo fits a portrait box by its width")
    func landscapeIntoPortrait() {
        // The case a single maximum dimension would get wrong: same photo, same
        // longest edge, a different answer.
        let fitted = PhotoRenderer.fit(
            sourceWidth: 4000, sourceHeight: 3000, intoWidth: 2160, byHeight: 3840)
        #expect(fitted.width == 2160)
        #expect(fitted.height == 1620)
    }

    @Test("Nothing is ever enlarged")
    func neverUpscaled() {
        let fitted = PhotoRenderer.fit(
            sourceWidth: 800, sourceHeight: 600, intoWidth: 3840, byHeight: 2160)
        #expect(fitted.width == 800)
        #expect(fitted.height == 600)
    }

    @Test("A box that exactly matches leaves the image alone")
    func exactFit() {
        let fitted = PhotoRenderer.fit(
            sourceWidth: 1920, sourceHeight: 1080, intoWidth: 1920, byHeight: 1080)
        #expect(fitted.width == 1920)
        #expect(fitted.height == 1080)
    }

    // MARK: - Rendering a real file

    @Test("Rendering fits the box and keeps the aspect ratio")
    func renderFitsTheBox() throws {
        let directory = temporary()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let source = directory.appending(path: "wide.png")
        try write(width: 4000, height: 3000, to: source)

        let rendered = try PhotoRenderer.render(
            contentsOf: source, fitting: 3840, by: 2160, as: .jpeg)
        #expect(rendered.width == 2880)
        #expect(rendered.height == 2160)
        #expect(rendered.format == .jpeg)
        #expect(!rendered.bytes.isEmpty)

        // What came back is a real image of the size claimed, which is the
        // promise the client draws against.
        let check = CGImageSourceCreateWithData(rendered.bytes as CFData, nil)!
        let properties =
            CGImageSourceCopyPropertiesAtIndex(check, 0, nil) as! [CFString: Any]
        #expect(properties[kCGImagePropertyPixelWidth] as? Int == 2880)
        #expect(properties[kCGImagePropertyPixelHeight] as? Int == 2160)
    }

    @Test("`w` and `h` are maximums, and nothing returned exceeds either")
    func nothingExceedsTheBox() throws {
        // The man page states this flatly, so it is checked flatly: across
        // shapes that are wider, taller, and squarer than the box, and against
        // the *rendered image*, not against the fit — the two disagree by a
        // pixel, since `fit` rounds where the decoder truncates.
        let directory = temporary()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let shapes = [(4000, 3000), (3000, 4000), (1200, 900), (1000, 1000), (2001, 999)]
        let boxes = [(3840, 2160), (101, 101), (100, 1000), (1000, 100), (1, 1)]

        for (index, shape) in shapes.enumerated() {
            let source = directory.appending(path: "shape-\(index).png")
            try write(width: shape.0, height: shape.1, to: source)
            for box in boxes {
                let rendered = try PhotoRenderer.render(
                    contentsOf: source, fitting: box.0, by: box.1, as: .jpeg)
                #expect(
                    rendered.width <= box.0,
                    "\(shape.0)x\(shape.1) into \(box.0)x\(box.1) came back \(rendered.width) wide")
                #expect(
                    rendered.height <= box.1,
                    "\(shape.0)x\(shape.1) into \(box.0)x\(box.1) came back \(rendered.height) tall")
            }
        }
    }

    @Test("A rendering is a fraction of the original's bytes")
    func renderingIsSmaller() throws {
        let directory = temporary()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let source = directory.appending(path: "big.png")
        try write(width: 4000, height: 3000, to: source)
        let original = try FileManager.default.attributesOfItem(
            atPath: source.path(percentEncoded: false))[.size] as! Int

        let rendered = try PhotoRenderer.render(
            contentsOf: source, fitting: 400, by: 400, as: .jpeg)
        #expect(rendered.bytes.count < original)
    }

    @Test("A file that is not an image is refused rather than served")
    func garbageIsRefused() throws {
        let directory = temporary()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let source = directory.appending(path: "not-a-photo.png")
        try Data("this is not an image".utf8).write(to: source)

        #expect(throws: (any Error).self) {
            try PhotoRenderer.render(contentsOf: source, fitting: 100, by: 100, as: .jpeg)
        }
    }

    // MARK: - Upright

    /// The same image, written with an EXIF orientation tag.
    ///
    /// Orientation 6 is "rotate 90° clockwise to display": the stored pixels
    /// are landscape and the photograph is portrait. A camera held on its side
    /// produces exactly this, and it is most of a real library.
    private func write(
        width: Int, height: Int, orientation: Int, to url: URL
    ) throws {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(
            destination, context.makeImage()!,
            [kCGImagePropertyOrientation: orientation] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
    }

    @Test("A sideways photograph comes back upright, and the box is applied to what is drawn")
    func orientationIsApplied() throws {
        let directory = temporary()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appending(path: "sideways.jpg")
        // Stored 400×200; displayed 200×400 once the tag is honoured.
        try write(width: 400, height: 200, orientation: 6, to: source)

        // The pixel size is what the file says it holds, before any rotation.
        let stored = try #require(PhotoRenderer.pixelSize(of: source))
        #expect(stored.width == 400)
        #expect(stored.height == 200)

        // The client draws what it is handed, 1:1 and never resampled, so the
        // rotation has to happen here — a portrait photograph handed over
        // landscape would be drawn on its side.
        let rendered = try PhotoRenderer.render(
            contentsOf: source, fitting: 1000, by: 1000, as: .jpeg)
        #expect(rendered.height > rendered.width, "the photograph was handed over sideways")
        #expect(rendered.width == 200)
        #expect(rendered.height == 400)
    }

    @Test("The box bounds the upright photograph, not the stored pixels")
    func orientationIsAppliedBeforeTheFit() throws {
        let directory = temporary()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appending(path: "sideways.jpg")
        try write(width: 400, height: 200, orientation: 6, to: source)

        // A 200×400 photograph into a 100×100 box is width-limited at 100×200
        // if the rotation were ignored, and height-limited at 50×100 once it is
        // honoured. **No image returned may exceed either bound**, which is the
        // claim the man page makes and the one a sideways photograph breaks
        // when orientation is applied after the fit rather than before it.
        let rendered = try PhotoRenderer.render(
            contentsOf: source, fitting: 100, by: 100, as: .jpeg)
        #expect(rendered.width <= 100)
        #expect(rendered.height <= 100)
        #expect(rendered.height > rendered.width)
    }

    // MARK: - Content negotiation

    @Test("HEIC unless the client will only take JPEG")
    func formatNegotiation() {
        #expect(PhotoRenderer.Format.negotiated(accept: nil) == .heic)
        #expect(PhotoRenderer.Format.negotiated(accept: "*/*") == .heic)
        #expect(PhotoRenderer.Format.negotiated(accept: "image/*") == .heic)
        #expect(PhotoRenderer.Format.negotiated(accept: "image/heic, image/jpeg") == .heic)
        #expect(PhotoRenderer.Format.negotiated(accept: "image/jpeg") == .jpeg)
        #expect(PhotoRenderer.Format.negotiated(accept: "IMAGE/JPEG") == .jpeg)
        // Neither format is a refusal, not a fallback the client never asked
        // for — the endpoint turns nil into a 406.
        #expect(PhotoRenderer.Format.negotiated(accept: "image/png") == nil)
        #expect(PhotoRenderer.Format.negotiated(accept: "text/html") == nil)
    }

    @Test("Admission is broader than negotiation: held bytes serve if the client accepts them")
    func admissionIsBroaderThanNegotiation() {
        // Negotiation picks what to produce; admission asks whether bytes
        // already held may go out as they are. A permissive client admits a
        // held JPEG even though negotiation would have produced HEIC.
        #expect(PhotoRenderer.Format.jpeg.admitted(by: "image/heic, image/jpeg"))
        #expect(PhotoRenderer.Format.jpeg.admitted(by: nil))
        #expect(PhotoRenderer.Format.jpeg.admitted(by: "*/*"))
        #expect(PhotoRenderer.Format.heic.admitted(by: "image/*"))
        #expect(!PhotoRenderer.Format.heic.admitted(by: "image/jpeg"))
        #expect(!PhotoRenderer.Format.jpeg.admitted(by: "image/heic"))
        #expect(!PhotoRenderer.Format.heic.admitted(by: "image/png"))
    }

    @Test("The format asked for is the format returned")
    func formatIsHonoured() throws {
        let directory = temporary()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let source = directory.appending(path: "photo.png")
        try write(width: 600, height: 400, to: source)

        for format in PhotoRenderer.Format.allCases {
            let rendered = try PhotoRenderer.render(
                contentsOf: source, fitting: 300, by: 300, as: format)
            let check = CGImageSourceCreateWithData(rendered.bytes as CFData, nil)!
            #expect(
                CGImageSourceGetType(check) as String? == format.contentType.identifier,
                "\(format) came back as \(String(describing: CGImageSourceGetType(check)))")
        }
    }
}

/// The rendering cache, which is what makes a second request for a size already
/// held a file read rather than a decode.
@Suite("Rendering cache")
struct RenderCacheTests {

    private func image(width: Int, height: Int, at url: URL) throws {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(red: 0.9, green: 0.4, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        #expect(CGImageDestinationFinalize(destination))
    }

    @Test("The same photograph is held at two sizes at once, and both keep serving")
    func twoSizesCoexist() throws {
        let directory = URL.temporaryDirectory.appending(path: "pgr-two-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let original = directory.appending(path: "photo.png")
        try image(width: 2000, height: 2000, at: original)

        let store = PhotoStore(root: directory.appending(path: "cache"))
        let photo = UUID().uuidString.lowercased()
        let source = UUID().uuidString.lowercased()
        let small = PhotoStore.Size(width: 100, height: 100)
        let large = PhotoStore.Size(width: 1000, height: 1000)

        // Neither held yet: both are misses.
        #expect(store.url(for: .init(photoUUID: photo, size: small)) == nil)
        #expect(store.url(for: .init(photoUUID: photo, size: large)) == nil)

        for size in [small, large] {
            let rendered = try PhotoRenderer.render(
                contentsOf: original, fitting: size.width, by: size.height, as: .jpeg)
            try store.store(
                rendered.bytes, for: .init(photoUUID: photo, size: size),
                sourceUUID: source, pathExtension: "jpeg")
        }

        // Switching back and forth, repeatedly: every request is a hit, and each
        // size keeps its own pixels. One did not overwrite the other.
        for _ in 0..<4 {
            for size in [small, large, large, small] {
                let held = try #require(store.url(for: .init(photoUUID: photo, size: size)))
                let source = CGImageSourceCreateWithURL(held as CFURL, nil)!
                let properties =
                    CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as! [CFString: Any]
                #expect(properties[kCGImagePropertyPixelWidth] as? Int == size.width)
                #expect(properties[kCGImagePropertyPixelHeight] as? Int == size.height)
            }
        }

        #expect(Set(store.sizes(forPhoto: photo)) == [small, large])
        #expect(store.totals.renderings == 2)
        #expect(store.totals.originals == 0)
    }

    @Test("The index survives a restart, rebuilt from the filenames alone")
    func indexIsRebuiltFromDisk() throws {
        let directory = URL.temporaryDirectory.appending(path: "pgr-rebuild-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let root = directory.appending(path: "cache")
        let photo = UUID().uuidString.lowercased()
        let source = UUID().uuidString.lowercased()
        let size = PhotoStore.Size(width: 640, height: 480)

        let first = PhotoStore(root: root)
        try first.store(
            Data(count: 128), for: .init(photoUUID: photo, size: size),
            sourceUUID: source, pathExtension: "jpeg")
        try first.store(
            Data(count: 512), for: .init(photoUUID: photo),
            sourceUUID: source, pathExtension: "heic")

        // A different process, with nothing in memory and nothing in a database
        // telling it what is here.
        let second = PhotoStore(root: root)
        #expect(second.url(for: .init(photoUUID: photo, size: size)) == nil)

        let rebuilt = second.rebuild(photos: [photo: source])
        #expect(rebuilt.kept == 2)
        #expect(rebuilt.discarded == 0)
        #expect(rebuilt.bytes == 640)
        #expect(second.url(for: .init(photoUUID: photo, size: size)) != nil)
        #expect(second.url(for: .init(photoUUID: photo)) != nil)
    }

    @Test("A file whose photograph is unknown is deleted, not adopted")
    func unknownIdentitiesAreDiscarded() throws {
        let directory = URL.temporaryDirectory.appending(path: "pgr-unknown-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let root = directory.appending(path: "cache")
        let store = PhotoStore(root: root)
        let known = UUID().uuidString.lowercased()
        let stranger = UUID().uuidString.lowercased()
        let source = UUID().uuidString.lowercased()

        try store.store(
            Data(count: 10), for: .init(photoUUID: known), sourceUUID: source,
            pathExtension: "heic")
        try store.store(
            Data(count: 10), for: .init(photoUUID: stranger), sourceUUID: source,
            pathExtension: "heic")

        // This is what a rebuilt database looks like from the cache's side: the
        // photographs it held are simply not there any more. Serving them under
        // whatever now owns those row ids would be the corruption UUIDs prevent.
        let result = store.rebuild(photos: [known: source])
        #expect(result.kept == 1)
        #expect(result.discarded == 1)
        #expect(store.url(for: .init(photoUUID: stranger)) == nil)
        #expect(store.url(for: .init(photoUUID: known)) != nil)
    }

    @Test("A photograph can outlive its own original")
    func renderingSurvivesTheOriginal() throws {
        let directory = URL.temporaryDirectory.appending(path: "pgr-outlive-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = PhotoStore(root: directory.appending(path: "cache"), byteCeiling: 600)
        let photo = UUID().uuidString.lowercased()
        let source = UUID().uuidString.lowercased()
        let size = PhotoStore.Size(width: 200, height: 200)

        // The original is written first, so it is the oldest and goes first.
        try store.store(
            Data(count: 500), for: .init(photoUUID: photo), sourceUUID: source,
            pathExtension: "heic")
        try store.store(
            Data(count: 400), for: .init(photoUUID: photo, size: size), sourceUUID: source,
            pathExtension: "jpeg")
        _ = store.rebuild(photos: [photo: source])

        // **The original goes before its own renderings**, which used to be an
        // accident of write order — the file was backdated here to force it —
        // and is now the stated rule. A rendering is a fraction of the bytes
        // and is display-ready, so the same budget holds more pictures that can
        // be served without a decode.
        let result = store.evictIfNeeded(inOrder: [photo])
        #expect(result.evicted == 1)
        // The rendering is still serviceable on its own: a client asking at that
        // size never needs the original back.
        #expect(store.url(for: .init(photoUUID: photo)) == nil)
        #expect(store.url(for: .init(photoUUID: photo, size: size)) != nil)
    }
}
