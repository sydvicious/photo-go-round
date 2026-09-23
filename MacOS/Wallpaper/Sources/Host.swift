// A shell app whose only job is to be a bundle the wallpaper extension can live
// inside during development. `Build Plan.md`, *The install phases*.
//
// **Why it exists.** An appex registers only from inside an app bundle — measured
// 2026-09-15: `pluginkit -a` on a bare `.appex` exits 0 and registers nothing,
// while the same appex inside an app registers at once with nothing launched. The
// real app deliberately does not carry the extension in development, so that
// building or running `Photos-Go-Round` never installs or re-registers it. This is
// the bundle that carries it instead.
//
// **It ships in nothing.** In release the extension goes inside the app wrapper
// and the app installs it — Syd, 2026-09-15 — and this target is not part of that.
//
// Running it is not how the extension is installed; `pluginkit -a` on the built
// bundle is. It is launchable only so that double-clicking it does something
// truthful rather than nothing.

import AppKit
import OSLog

let hostLog = Logger(subsystem: "com.sydpolk.photosgoround", category: "system-wallpaper")

@main
enum WallpaperHost {
    static func main() {
        let bundle = Bundle.main.bundleURL.path(percentEncoded: false)
        hostLog.notice(
            """
            system-wallpaper: host bundle at \(bundle, privacy: .public). \
            It carries the wallpaper extension for development and does nothing else; \
            choose Photos-Go-Round in System Settings › Wallpaper.
            """)
        // No window, no menu, nothing to interact with: quit rather than sit in
        // the process list pretending to be an application.
        NSApplication.shared.terminate(nil)
    }
}
