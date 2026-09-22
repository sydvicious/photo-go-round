// The wallpaper extension. `Wallpaper Plan.md`, *The real extension, inside the
// app*.
//
// It lives in System Settings › Wallpaper: one Photo-Go-Round section holding one
// item, and a photograph from the agent on the desktop when that item is chosen.
// Phosphene's shape, measured over four probes — sandboxed, no private
// entitlement, `dlopen` of the private `WallpaperExtensionKit` for the classes
// that cross the connection.
//
// Everything it does is logged, category `system-wallpaper`, lines prefixed
// `system-wallpaper:` — beside the app's `wallpaper:` and the saver's `saver:`,
// so one word filters any of them.

import ExtensionFoundation
import Foundation
import OSLog
import PhotoGoRoundAgentAPI
import Synchronization

let extensionLog = Logger(subsystem: Log.subsystem, category: "system-wallpaper")

/// One `.notice` line. Public: nothing here is private, and the log is how a
/// process with no window is diagnosed at all.
func wallpaperLog(_ line: String) {
    extensionLog.notice("system-wallpaper: \(line, privacy: .public)")
}

/// What each standing fact last said, so it is logged when it changes rather
/// than every time it is read.
private let lastSaid = Mutex<[String: String]>([:])

/// A line about a fact rather than an event: written the first time, and then
/// only when the fact itself changes.
///
/// **The port line is why this exists.** `port 9428 from the … suite` was
/// written on every wake — six times in thirty minutes, measured 2026-09-19 —
/// saying exactly the same thing each time, in a log whose whole job is to be
/// read by a person. The value is worth a line; re-reading it is not.
/// `Plans/Logging.md`, Phase 2.
func wallpaperLogWhenChanged(_ fact: String, _ line: String) {
    let changed = lastSaid.withLock { said in
        guard said[fact] != line else { return false }
        said[fact] = line
        return true
    }
    if changed { wallpaperLog(line) }
}

@main
final class WallpaperExtension: AppExtension {
    init() {
        let info = ProcessInfo.processInfo
        let sandbox = info.environment["APP_SANDBOX_CONTAINER_ID"] ?? "none"
        wallpaperLog("extension started, pid \(info.processIdentifier), sandbox container \(sandbox)")
        wallpaperLog(Identity.summary)

        // The private classes `WallpaperAgent` sends, and expects back, live
        // here. Nothing can be decoded or answered until it is loaded.
        let framework = "/System/Library/PrivateFrameworks/WallpaperExtensionKit.framework/WallpaperExtensionKit"
        if dlopen(framework, RTLD_LAZY) != nil {
            wallpaperLog("WallpaperExtensionKit loaded")
        } else {
            let reason = dlerror().map { String(cString: $0) } ?? "no reason given"
            wallpaperLog("WallpaperExtensionKit would not load: \(reason). The pane will show nothing.")
        }
        let missing = PrivateTypes.names.filter { NSClassFromString($0) == nil }
        if !missing.isEmpty {
            wallpaperLog("missing private classes: \(missing.joined(separator: ", "))")
        }

        if let thumbnail = PaneThumbnail.url {
            wallpaperLog("thumbnail at \(thumbnail.path(percentEncoded: false))")
        } else {
            wallpaperLog("no thumbnail could be written; the pane's item will have no picture")
        }
    }

    var configuration: WallpaperConfiguration { WallpaperConfiguration() }
}

struct WallpaperConfiguration: AppExtensionConfiguration {
    nonisolated func accept(connection: NSXPCConnection) -> Bool {
        let caller = connection.processIdentifier
        wallpaperLog("connection from pid \(caller)")
        connection.exportedInterface = PrivateTypes.exportedInterface()
        connection.exportedObject = PaneHandler(caller: caller)
        connection.interruptionHandler = { wallpaperLog("connection from pid \(caller) interrupted") }
        connection.invalidationHandler = { wallpaperLog("connection from pid \(caller) invalidated") }
        connection.resume()
        return true
    }
}
