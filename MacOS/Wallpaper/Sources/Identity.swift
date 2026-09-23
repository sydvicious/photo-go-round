// Which build of the wallpaper this is. `Wallpaper Plan.md`, *Debug builds under
// their own identity*.
//
// **Read from the bundle, not decided by `#if DEBUG`.** Release, Syd's Debug
// builds and Claude's builds each have their own identifier and name, and
// Claude's builds are Debug too, so only the build settings that made the bundle
// can tell them apart: `WALLPAPER_ID_SUFFIX` in the identifier, and
// `WALLPAPER_NAME_SUFFIX` in the names in `Info.plist`.
//
// **Nothing falls back to the Release names.** A bundle built without them would
// otherwise pass for the Release wallpaper in the pane; instead the launch line
// says what is missing and the pane is refused its view models.

import Foundation

enum Identity {
    /// The extension's bundle identifier — also the provider `WallpaperAgent`
    /// looks the item up by.
    static let bundleID = Bundle.main.bundleIdentifier

    /// The pane's item identifier: `photos-go-round`, with the identifier's
    /// suffix. **Measured 2026-09-16:** with the same item and section identifier
    /// in two builds, both answered the pane and it showed one section.
    static let itemID = infoString("PGRWallpaperItemID")

    /// The item's name in the pane, *Photos-Go-Round Wallpaper* with the suffix,
    /// and the title on the placeholder picture.
    static let itemName = infoString("PGRWallpaperName")

    /// One line for the launch log: every part, or what is missing.
    static var summary: String {
        let parts = [
            ("identifier", bundleID), ("item identifier", itemID), ("item name", itemName)
        ]
        let missing = parts.filter { $0.1 == nil }.map(\.0)
        guard missing.isEmpty else {
            return "identity incomplete, missing \(missing.joined(separator: ", ")); the pane will be refused its view models"
        }
        return parts.map { "\($0.0) \($0.1 ?? "")" }.joined(separator: ", ")
    }

    private static func infoString(_ key: String) -> String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String, !value.isEmpty else { return nil }
        return value
    }
}
