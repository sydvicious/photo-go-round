import AppKit
import PhotoGoRoundDisplay

/// The one thing SwiftUI's scenes give no moment for: starting the wallpaper
/// once the application has finished launching, and keeping it for as long as
/// the app runs.
///
/// **The app hosts the wallpaper; it is not the wallpaper.** Everything it does
/// is `Wallpaper`, in the display library, so a binary of its own can host the
/// same loop later. See `Wallpaper Plan.md`, *Where the loop runs*.
final class AppDelegate: NSObject, NSApplicationDelegate {
    let wallpaper = Wallpaper.desktop()

    func applicationDidFinishLaunching(_ notification: Notification) {
        wallpaper.watchTheSystem()
        // Runs only if *Also set wallpapers* is ticked.
        wallpaper.resume()
    }
}
