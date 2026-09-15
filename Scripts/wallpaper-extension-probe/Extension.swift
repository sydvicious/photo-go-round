// The wallpaper extension probe. `Wallpaper Plan.md`, *The extension probe* and
// *The second probe*; built by `Scripts/make-wallpaper-extension-probe.sh`.
//
// Phosphene's shape: an extension on `com.apple.wallpaper`, sandboxed, with no
// private entitlement. The first probe answered nothing, and showed that
// `WallpaperAgent` launches it and connects. This one answers: one Photo-Go-Round
// section in System Settings › Wallpaper holding one item, and a generated
// picture on the desktop when that item is chosen. Since the third probe, it also
// answers `snapshot` with that picture, for the export `WallpaperAgent` makes of
// the chosen wallpaper. Since the fourth probe, the desktop asks the agent for a
// photograph as `system-wallpaper` and shows it in place of the generated picture.
//
// Everything `WallpaperAgent` sends is logged, category `wallpaper-probe`, lines
// prefixed `probe:`, so each gate is read against what actually arrived.

import ExtensionFoundation
import Foundation
import OSLog

let probeLog = Logger(subsystem: "com.sydpolk.photogoround", category: "wallpaper-probe")

/// One `.notice` line. Public: nothing here is private, and the lines are the
/// measurement.
func probe(_ line: String) {
    probeLog.notice("probe: \(line, privacy: .public)")
}

@main
final class ProbeExtension: AppExtension {
    init() {
        let info = ProcessInfo.processInfo
        let sandbox = info.environment["APP_SANDBOX_CONTAINER_ID"] ?? "none"
        probe("extension started, pid \(info.processIdentifier), sandbox container \(sandbox)")

        // The private classes `WallpaperAgent` sends, and expects back, live here.
        // Nothing can be decoded or answered until it is loaded.
        let framework = "/System/Library/PrivateFrameworks/WallpaperExtensionKit.framework/WallpaperExtensionKit"
        if dlopen(framework, RTLD_LAZY) != nil {
            probe("dlopen of WallpaperExtensionKit succeeded")
        } else {
            let reason = dlerror().map { String(cString: $0) } ?? "no reason given"
            probe("dlopen of WallpaperExtensionKit failed: \(reason)")
        }
        let missing = PrivateTypes.names.filter { NSClassFromString($0) == nil }
        probe(
            missing.isEmpty
                ? "all \(PrivateTypes.names.count) private XPC classes present"
                : "missing private XPC classes: \(missing.joined(separator: ", "))")

        if let thumbnail = ProbePicture.thumbnailURL {
            probe("thumbnail written to \(thumbnail.path(percentEncoded: false))")
        } else {
            probe("no thumbnail could be written")
        }
    }

    var configuration: ProbeConfiguration { ProbeConfiguration() }
}

struct ProbeConfiguration: AppExtensionConfiguration {
    nonisolated func accept(connection: NSXPCConnection) -> Bool {
        let caller = connection.processIdentifier
        probe("connection from pid \(caller)")
        connection.exportedInterface = PrivateTypes.exportedInterface()
        connection.exportedObject = PaneHandler(caller: caller)
        connection.interruptionHandler = {
            probe("connection from pid \(caller) interrupted")
        }
        connection.invalidationHandler = {
            probe("connection from pid \(caller) invalidated")
        }
        connection.resume()
        return true
    }
}
