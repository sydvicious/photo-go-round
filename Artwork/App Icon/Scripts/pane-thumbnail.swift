// Draws the wallpaper extension's pane picture from the app icon's own layers:
// the ring and the house card, with no icon frame, filling a 16:9 picture on
// the icon's fill. `Plans/App Icon.md`, *The wallpaper pane's picture*.
//
//     swift "Artwork/App Icon/Scripts/pane-thumbnail.swift"
//
// Run from the repository root. Writes `MacOS/Wallpaper/Sources/PaneThumbnail.png`,
// which is committed: the sandboxed extension cannot read the app's icon, so it
// carries this picture instead. Run it again whenever the icon changes.
//
// The layers are read from `PhotosGoRound.icon` itself, so the picture is made
// from exactly what the icon is made from. Syd, 2026-09-24: "What I really want
// is the ring and photo on the gradient, but without the icon frame."

import AppKit

let width = 1920, height = 1080
let margin: CGFloat = 40  // around the ring and card together
let icon = "Artwork/PhotosGoRound.icon"
let output = "MacOS/Wallpaper/Sources/PaneThumbnail.png"

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

// 1. The layers, bottom first, as `icon.json` lists them top first.
struct Manifest: Decodable {
    struct Group: Decodable { let layers: [Layer] }
    struct Layer: Decodable { let imageName: String; enum CodingKeys: String, CodingKey { case imageName = "image-name" } }
    let groups: [Group]
}
guard let json = FileManager.default.contents(atPath: "\(icon)/icon.json"),
    let manifest = try? JSONDecoder().decode(Manifest.self, from: json)
else { fail("could not read \(icon)/icon.json") }
let layers: [NSImage] = manifest.groups.flatMap(\.layers).reversed().map { layer in
    guard let image = NSImage(contentsOfFile: "\(icon)/Assets/\(layer.imageName)") else {
        fail("could not read \(layer.imageName)")
    }
    return image
}

// 2. Where the layers actually draw, found from their pixels, so the picture
// can be cropped to them however the icon's layout changes.
let canvas = 1024
func render(_ size: CGSize, _ place: CGRect, shadow: Bool) -> CGContext {
    let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
    guard
        let context = CGContext(
            data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
            space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)
    else { fail("could not make a drawing context") }
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    for (index, layer) in layers.enumerated() {
        context.saveGState()
        // Icon Composer puts a neutral shadow under the group; the top layer,
        // the house card, is the one that needs lifting off the ring.
        if shadow && index == layers.count - 1 {
            context.setShadow(
                offset: CGSize(width: 0, height: -place.height / 80), blur: place.height / 40,
                color: CGColor(srgbRed: 0.18, green: 0.29, blue: 0.45, alpha: 0.35))
        }
        layer.draw(in: place)
        context.restoreGState()
    }
    NSGraphicsContext.current = nil
    return context
}
let probe = render(CGSize(width: canvas, height: canvas), CGRect(x: 0, y: 0, width: canvas, height: canvas), shadow: false)
guard let pixels = probe.data?.assumingMemoryBound(to: UInt8.self) else { fail("no pixels") }
var minX = canvas, minY = canvas, maxX = -1, maxY = -1
for y in 0..<canvas {
    for x in 0..<canvas where pixels[y * probe.bytesPerRow + x * 4] > 8 {  // alpha, first byte
        minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
    }
}
guard maxX >= minX else { fail("the layers draw nothing") }
// Memory rows run top down; Core Graphics counts up from the bottom.
let content = CGRect(x: minX, y: canvas - 1 - maxY, width: maxX - minX + 1, height: maxY - minY + 1)

// 3. Scale the layers so their drawn part fills the picture, less the margin.
let scale = min((CGFloat(width) - 2 * margin) / content.width, (CGFloat(height) - 2 * margin) / content.height)
let place = CGRect(
    x: (CGFloat(width) - content.width * scale) / 2 - content.minX * scale,
    y: (CGFloat(height) - content.height * scale) / 2 - content.minY * scale,
    width: CGFloat(canvas) * scale, height: CGFloat(canvas) * scale)

// 4. The icon's fill, top to bottom, from `icon.json`, then the layers on it.
let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
guard
    let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue),
    let fill = CGGradient(
        colorsSpace: sRGB,
        colors: [
            CGColor(srgbRed: 0.99953, green: 0.98836, blue: 0.47266, alpha: 1),
            CGColor(srgbRed: 0.46202, green: 0.83828, blue: 1.00000, alpha: 1),
        ] as CFArray,
        locations: [0, 1])
else { fail("could not make the drawing context") }
context.drawLinearGradient(fill, start: CGPoint(x: 0, y: height), end: .zero, options: [])
guard let layered = render(CGSize(width: width, height: height), place, shadow: true).makeImage() else {
    fail("could not draw the layers")
}
context.draw(layered, in: CGRect(x: 0, y: 0, width: width, height: height))

guard let picture = context.makeImage(),
    let destination = CGImageDestinationCreateWithURL(
        URL(fileURLWithPath: output) as CFURL, "public.png" as CFString, 1, nil)
else { fail("could not write \(output)") }
CGImageDestinationAddImage(destination, picture, nil)
guard CGImageDestinationFinalize(destination) else { fail("could not write \(output)") }
print("wrote \(output)")
