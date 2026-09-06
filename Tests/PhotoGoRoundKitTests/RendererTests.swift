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
@Suite("The byte store")
struct ByteStoreTests {

    @Test("The index survives a restart, rebuilt from the filenames alone")
    func indexIsRebuiltFromDisk() throws {
        let directory = URL.temporaryDirectory.appending(path: "pgr-rebuild-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let root = directory.appending(path: "cache")
        let first = UUID().uuidString.lowercased()
        let second = UUID().uuidString.lowercased()
        let source = UUID().uuidString.lowercased()

        let writer = PhotoStore(root: root)
        try writer.store(
            Data(count: 128), forPhoto: first, sourceUUID: source, pathExtension: "jpeg")
        try writer.store(
            Data(count: 512), forPhoto: second, sourceUUID: source, pathExtension: "heic")

        // A different process, with nothing in memory and nothing in a database
        // telling it what is here.
        let reader = PhotoStore(root: root)
        #expect(reader.url(forPhoto: first) == nil)

        let rebuilt = reader.rebuild(photos: [first: source, second: source])
        #expect(rebuilt.kept == 2)
        #expect(rebuilt.discarded == 0)
        #expect(rebuilt.bytes == 640)
        #expect(reader.url(forPhoto: first) != nil)
        #expect(reader.url(forPhoto: second) != nil)
    }

    @Test("A file whose photograph is unknown is deleted, not adopted")
    func unknownIdentitiesAreDiscarded() throws {
        let directory = URL.temporaryDirectory.appending(path: "pgr-unknown-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = PhotoStore(root: directory.appending(path: "cache"))
        let known = UUID().uuidString.lowercased()
        let stranger = UUID().uuidString.lowercased()
        let source = UUID().uuidString.lowercased()

        try store.store(
            Data(count: 10), forPhoto: known, sourceUUID: source, pathExtension: "heic")
        try store.store(
            Data(count: 10), forPhoto: stranger, sourceUUID: source, pathExtension: "heic")

        // This is what a rebuilt database looks like from the cache's side: the
        // photographs it held are simply not there any more. Serving them under
        // whatever now owns those row ids would be the corruption UUIDs prevent.
        let result = store.rebuild(photos: [known: source])
        #expect(result.kept == 1)
        #expect(result.discarded == 1)
        #expect(store.url(forPhoto: stranger) == nil)
        #expect(store.url(forPhoto: known) != nil)
    }

    @Test("One photograph is one file: storing again replaces what was there")
    func oneFilePerPhotograph() throws {
        let directory = URL.temporaryDirectory.appending(path: "pgr-onefile-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = PhotoStore(root: directory.appending(path: "cache"))
        let photo = UUID().uuidString.lowercased()
        let source = UUID().uuidString.lowercased()

        try store.store(
            Data(count: 500), forPhoto: photo, sourceUUID: source, pathExtension: "heic")
        // A different extension, which is a different filename: the file it
        // replaces must not be left where no index entry can name it again.
        let second = try store.store(
            Data(count: 300), forPhoto: photo, sourceUUID: source, pathExtension: "jpeg")

        #expect(store.totals.entries == 1)
        #expect(store.totals.byteCount == 300)
        #expect(store.url(forPhoto: photo) == second)
        let rebuilt = PhotoStore(root: directory.appending(path: "cache"))
            .rebuild(photos: [photo: source])
        #expect(rebuilt.kept == 1)
        #expect(rebuilt.bytes == 300)
    }

    /// **Temporary, and goes when the sweep does.** See
    /// `PhotoStore.IndexResult.reclaimedDirectories`.
    @Test("Rendering directories left by the old resize cache are swept at launch")
    func leftoverRenderingDirectoriesAreReclaimed() throws {
        let directory = URL.temporaryDirectory.appending(path: "pgr-sweep-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let root = directory.appending(path: "cache")
        let photo = UUID().uuidString.lowercased()
        let source = UUID().uuidString.lowercased()

        let store = PhotoStore(root: root)
        try store.store(
            Data(count: 500), forPhoto: photo, sourceUUID: source, pathExtension: "heic")

        // What the resize cache used to write, by hand: the photograph is one
        // the database still claims, so the unclaimed-file rule would never
        // have taken these.
        let sized = root.appending(path: source).appending(path: "1800x1066")
        try FileManager.default.createDirectory(at: sized, withIntermediateDirectories: true)
        try Data(count: 90).write(to: sized.appending(path: "\(photo).heic"))
        try Data(count: 10).write(to: sized.appending(path: "\(UUID().uuidString).heic"))

        // A read-only pass removes nothing.
        let peek = PhotoStore(root: root).index(photos: [photo: source])
        #expect(peek.reclaimedDirectories == 0)
        #expect(FileManager.default.fileExists(atPath: sized.path(percentEncoded: false)))

        let swept = PhotoStore(root: root).rebuild(photos: [photo: source])
        #expect(swept.reclaimedDirectories == 1)
        #expect(swept.reclaimedBytes == 100)
        #expect(!FileManager.default.fileExists(atPath: sized.path(percentEncoded: false)))
        // The original is untouched, and is all that is counted.
        #expect(swept.kept == 1)
        #expect(swept.bytes == 500)
        #expect(store.url(forPhoto: photo) != nil)
    }
}
