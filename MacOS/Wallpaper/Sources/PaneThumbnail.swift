// The picture on the pane's item, and the picture shown before the agent answers.
// `Wallpaper Plan.md`, *The real extension, inside the app*.
//
// **A fixed mark: the app icon.** Syd, 2026-09-15: "the icon in system
// settings is stupid", and then, having considered showing the current
// photograph instead, "actually, don't do it that way. This will match the app
// icon once we have one." So the pane's item is a stable identity rather than a
// changing picture: since 2026-09-24, the app icon's ring and house card on
// the icon's own fill, without the icon's frame.
//
// It also has to be something: the pane asks for a thumbnail before any
// photograph has been served, and a wallpaper that spent a card every time
// somebody opened System Settings would empty the queue into a picture nobody
// chose.
//
// **Drawn ahead of time, not here.** `PaneThumbnail.png` is made by
// `Artwork/App Icon/Scripts/pane-thumbnail.swift` and committed. Reading the
// icon from the app we are inside does not work: the sandbox denies it
// (`deny(1) file-read-data …/Photos-Go-Round.app`, 2026-09-24). Syd, the same
// day: "could we predraw that image and store the static asset?"

import CoreGraphics
import Foundation
import ImageIO

enum PaneThumbnail {
    private static let resource = Bundle.main.url(forResource: "PaneThumbnail", withExtension: "png")

    /// The full-size mark, shown on the desktop until the first photograph
    /// arrives, so the desktop is never blank.
    static let image: CGImage? = resource
        .flatMap { CGImageSourceCreateWithURL($0 as CFURL, nil) }
        .flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }

    /// A copy in the extension's container, which is where the pane reads it from.
    static let url: URL? = write()


    private static func write() -> URL? {
        guard let resource else {
            wallpaperLog("thumbnail: PaneThumbnail.png is missing from the extension")
            return nil
        }
        guard let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return nil
        }
        let url = folder.appending(path: "photos-go-round-thumbnail.png")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: url)
            try FileManager.default.copyItem(at: resource, to: url)
        } catch {
            wallpaperLog("thumbnail: could not copy to \(url.path(percentEncoded: false)): \(error)")
            return nil
        }
        return url
    }
}
