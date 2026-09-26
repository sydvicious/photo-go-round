// The last photograph the desktop was given, kept so a preview can show it.
// `Wallpaper Plan.md`, *The real extension, inside the app*.
//
// **The extension's own storage, not anybody else's.** Syd, 2026-09-15: "the
// wallpaper extension has its own preference domain and can do with it what it
// pleases." A sandboxed extension's standard defaults live inside its own
// container, so this needs no entitlement and touches nothing the app or the
// agent owns. The app's wallpaper domain stays read-only to us.
//
// **Why it exists.** A preview starts from whatever the desktop is showing, and
// there may be no desktop surface at all — the screen-saver preview with the
// wallpaper set to something else is exactly that case, and it drew the mark
// forever. Now the last photograph outlives the surfaces, and the process:
// choosing Photos-Go-Round in either picker shows a photograph straight away.
//
// The picture is a file because preferences are the wrong place for a few
// megabytes; the identifier sits beside it so the log and the pane agree on
// which photograph it is.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum LastPicture {
    /// Per slot, so the desktop and the screen saver remember different
    /// photographs rather than one overwriting the other.
    private static func key(_ name: String, _ slot: Slot) -> String { "\(name).\(slot.rawValue)" }

    private static func url(for slot: Slot) -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appending(path: "last-picture-\(slot.rawValue).heic")
    }

    /// What the desktop is showing now, remembered for the next preview.
    ///
    /// **Written beside and moved into place.** A preview may read while this
    /// writes, and half a file reads as no picture at all.
    static func remember(_ image: CGImage, card: String?, for slot: Slot) {
        guard let url = url(for: slot) else { return }
        let folder = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            wallpaperLog("last picture: \(folder.path(percentEncoded: false)) could not be made: \(error)")
            return
        }
        let beside = folder.appending(path: "last-picture-\(slot.rawValue)-writing.heic")
        guard
            let destination = CGImageDestinationCreateWithURL(
                beside as CFURL, UTType.heic.identifier as CFString, 1, nil)
        else {
            wallpaperLog("last picture: no HEIC encoder")
            return
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            wallpaperLog("last picture: could not be written")
            return
        }
        do {
            if FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: beside)
            } else {
                try FileManager.default.moveItem(at: beside, to: url)
            }
        } catch {
            wallpaperLog("last picture: could not be put in place: \(error)")
            return
        }

        let defaults = UserDefaults.standard
        defaults.set(card ?? "", forKey: key("lastCard", slot))
        defaults.set(Date(), forKey: key("lastShownAt", slot))
        defaults.set("\(image.width)x\(image.height)", forKey: key("lastPixels", slot))
        wallpaperLog("last \(slot.name) picture: kept card \(card ?? "unknown"), \(image.width)x\(image.height)")
    }

    /// Keeps nothing for this slot, so the next surface starts without a
    /// photograph rather than with one that can no longer be served.
    ///
    /// **For when the agent says there is nothing to show.** Syd, 2026-09-26,
    /// of the screensaver's remembered picture and then of this one: delete it.
    /// Said in the log only when there was something to delete, since this runs
    /// on every ask while the message is up.
    static func forget(for slot: Slot) {
        guard let url = url(for: slot), FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
        else { return }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            wallpaperLog("last picture: could not be removed: \(error)")
            return
        }
        let defaults = UserDefaults.standard
        for name in ["lastCard", "lastShownAt", "lastPixels"] { defaults.removeObject(forKey: key(name, slot)) }
        wallpaperLog("last \(slot.name) picture: forgotten, since the agent has nothing to show")
    }

    /// The photograph this slot last showed, or nil where none has been served.
    static func image(for slot: Slot) -> CGImage? {
        guard let url = url(for: slot), FileManager.default.fileExists(atPath: url.path(percentEncoded: false)),
            let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        return image
    }

    /// What is known about a slot's picture, for the log.
    static func summary(for slot: Slot) -> String {
        let defaults = UserDefaults.standard
        let card = defaults.string(forKey: key("lastCard", slot)) ?? ""
        let pixels = defaults.string(forKey: key("lastPixels", slot)) ?? "unknown size"
        return card.isEmpty ? pixels : "card \(card), \(pixels)"
    }
}
