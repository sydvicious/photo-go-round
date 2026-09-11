#!/usr/bin/env swift
//
// The two questions `Wallpaper Plan.md` Phase 1 answers before anything is
// built, asked of the real desktop:
//
//   1. Does leaving `.fillColor` out keep the fill colour chosen in System
//      Settings? (*The fit*)
//   2. Does setting the same URL again, with new contents, redraw the desktop?
//      (*The file on disk*)
//
// Run it with `swift`, which compiles into a temporary location and leaves
// nothing in the checkout:
//
//   swift Scripts/wallpaper-probe.swift show      what every screen reports now
//   swift Scripts/wallpaper-probe.swift fill      a tall yellow picture, no .fillColor
//   swift Scripts/wallpaper-probe.swift redraw    blue, then yellow, at one URL
//   swift Scripts/wallpaper-probe.swift restore   put back what was there
//
// The first command that changes anything saves every screen's URL and options
// first, and `restore` puts them back. Blue and yellow because they stay
// distinguishable for red-green colour blindness.

import AppKit
import ImageIO
import UniformTypeIdentifiers

let work = FileManager.default.temporaryDirectory.appending(path: "pgr-wallpaper-probe")
let saved = work.appending(path: "original.plist")

func identifier(of screen: NSScreen) -> String {
    guard
        let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
        let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue()
    else { return "unknown" }
    return CFUUIDCreateString(nil, uuid) as String
}

func describe(_ color: NSColor) -> String {
    guard let rgb = color.usingColorSpace(.sRGB) else { return "\(color)" }
    return String(
        format: "sRGB %.3f %.3f %.3f alpha %.3f",
        rgb.redComponent, rgb.greenComponent, rgb.blueComponent, rgb.alphaComponent)
}

func show() {
    for screen in NSScreen.screens {
        let pixels = screen.convertRectToBacking(screen.frame).size
        print("\(screen.localizedName) — \(identifier(of: screen)) — \(Int(pixels.width))x\(Int(pixels.height)) pixels")
        print("  url:     \(NSWorkspace.shared.desktopImageURL(for: screen)?.path(percentEncoded: false) ?? "none")")
        let options = NSWorkspace.shared.desktopImageOptions(for: screen) ?? [:]
        if options.isEmpty { print("  options: none reported") }
        for (key, value) in options.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            let shown = (value as? NSColor).map(describe) ?? "\(value)"
            print("  \(key.rawValue): \(shown)")
        }
    }
}

/// Once only, so a second run does not save the probe's own picture as the
/// thing to restore.
func saveOriginals() throws {
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    guard !FileManager.default.fileExists(atPath: saved.path(percentEncoded: false)) else { return }
    var record: [String: [String: Any]] = [:]
    for screen in NSScreen.screens {
        var entry: [String: Any] = [:]
        if let url = NSWorkspace.shared.desktopImageURL(for: screen) {
            entry["url"] = url.path(percentEncoded: false)
        }
        let options = NSWorkspace.shared.desktopImageOptions(for: screen) ?? [:]
        if let scaling = options[.imageScaling] as? NSNumber { entry["scaling"] = scaling }
        if let clipping = options[.allowClipping] as? NSNumber { entry["clipping"] = clipping }
        if let fill = (options[.fillColor] as? NSColor)?.usingColorSpace(.sRGB) {
            entry["fill"] = [fill.redComponent, fill.greenComponent, fill.blueComponent, fill.alphaComponent]
        }
        record[identifier(of: screen)] = entry
    }
    let data = try PropertyListSerialization.data(fromPropertyList: record, format: .xml, options: 0)
    try data.write(to: saved)
    print("saved every screen's wallpaper; put it back with: swift Scripts/wallpaper-probe.swift restore")
}

/// A flat picture, taller than it is wide, so a landscape screen has to show
/// the fill down both sides.
func picture(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) throws -> Data {
    let width = 900, height = 1600
    guard
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { throw ProbeError("could not make a drawing context") }
    context.setFillColor(red: red, green: green, blue: blue, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    guard let image = context.makeImage() else { throw ProbeError("could not make the picture") }
    let bytes = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(bytes, UTType.png.identifier as CFString, 1, nil)
    else { throw ProbeError("could not encode the picture") }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw ProbeError("could not encode the picture") }
    return bytes as Data
}

/// Aspect fit, as the wallpaper will set it — and `.fillColor` left out, which
/// is the first question.
func set(_ file: URL) throws {
    for screen in NSScreen.screens {
        try NSWorkspace.shared.setDesktopImageURL(
            file, for: screen,
            options: [
                .imageScaling: NSNumber(value: NSImageScaling.scaleProportionallyUpOrDown.rawValue),
                .allowClipping: NSNumber(value: false),
            ])
    }
}

/// Yellow, not blue: the fill measured on 2026-09-10 is a mid blue, and a blue
/// picture would be indistinguishable from the bands the question is about.
func fill() throws {
    try saveOriginals()
    let file = work.appending(path: "fill-yellow.png")
    try picture(0.95, 0.80, 0.10).write(to: file, options: .atomic)
    try set(file)
    print("set a tall yellow picture on every screen, with no .fillColor.")
    print("look at the bands either side of it: is that the fill colour chosen in System Settings?")
    print("what the system reports now:")
    show()
}

func redraw() throws {
    try saveOriginals()
    let file = work.appending(path: "same-name.png")
    try picture(0.10, 0.35, 0.85).write(to: file, options: .atomic)
    try set(file)
    print("blue is set at \(file.lastPathComponent). in 5 seconds the same file becomes yellow and is set again.")
    Thread.sleep(forTimeInterval: 5)
    // Atomic, exactly as the wallpaper will write it: a new file renamed over
    // the old one, under the same name.
    try picture(0.95, 0.80, 0.10).write(to: file, options: .atomic)
    try set(file)
    print("yellow has been written to the same name and set again.")
    print("if the desktop is now yellow, setting the same URL redraws. if it is still blue, it does not.")
}

func restore() throws {
    guard let data = try? Data(contentsOf: saved) else {
        print("nothing saved to restore")
        return
    }
    guard let record = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: [String: Any]]
    else { throw ProbeError("the saved record could not be read: \(saved.path(percentEncoded: false))") }
    for screen in NSScreen.screens {
        let id = identifier(of: screen)
        guard let entry = record[id], let path = entry["url"] as? String else {
            print("\(screen.localizedName): nothing saved for \(id); left as it is")
            continue
        }
        var options: [NSWorkspace.DesktopImageOptionKey: Any] = [:]
        if let scaling = entry["scaling"] { options[.imageScaling] = scaling }
        if let clipping = entry["clipping"] { options[.allowClipping] = clipping }
        if let fill = entry["fill"] as? [Double], fill.count == 4 {
            options[.fillColor] = NSColor(srgbRed: fill[0], green: fill[1], blue: fill[2], alpha: fill[3])
        }
        // **A folder is not restored, only pointed at.** When System Settings
        // is rotating through a folder, that folder is what the desktop URL
        // reports — and setting it back left the Golden Gate default on
        // 2026-09-10 rather than resuming the rotation.
        var isFolder: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &isFolder), isFolder.boolValue {
            print("\(screen.localizedName): the saved desktop was the folder \(path).")
            print("  setting a folder does not restart its rotation; choose it again in System Settings › Wallpaper.")
        }
        try NSWorkspace.shared.setDesktopImageURL(URL(filePath: path), for: screen, options: options)
        print("\(screen.localizedName): set \(path) back")
    }
    try FileManager.default.removeItem(at: saved)
}

struct ProbeError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

do {
    switch CommandLine.arguments.dropFirst().first {
    case "show": show()
    case "fill": try fill()
    case "redraw": try redraw()
    case "restore": try restore()
    default:
        print("usage: swift Scripts/wallpaper-probe.swift show | fill | redraw | restore")
        exit(64)
    }
} catch {
    print("wallpaper-probe: \(error)")
    exit(1)
}
