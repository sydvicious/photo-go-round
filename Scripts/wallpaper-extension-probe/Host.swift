// The host for the wallpaper extension probe. `Wallpaper Plan.md`, *The
// extension probe*; built by `Scripts/make-wallpaper-extension-probe.sh`.
//
// An ExtensionKit extension ships inside an app, and launching that app once is
// what registers it. So the host does nothing else: it says it ran, names the
// extensions it carries, and quits.

import AppKit
import OSLog

private let probeLog = Logger(subsystem: "com.sydpolk.photogoround", category: "wallpaper-probe")

@main
@MainActor
enum ProbeHost {
    static let delegate = HostDelegate()

    static func main() {
        let app = NSApplication.shared
        app.delegate = delegate
        app.run()
    }
}

final class HostDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        let bundle = Bundle.main.bundleURL
        probeLog.notice(
            "probe: host launched from folder \(bundle.deletingLastPathComponent().lastPathComponent, privacy: .public)")
        let folder = bundle.appending(path: "Contents/Extensions")
        let found = (try? FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false))) ?? []
        probeLog.notice(
            "probe: host carries \(found.isEmpty ? "no extensions" : found.sorted().joined(separator: ", "), privacy: .public); quitting")
        NSApp.terminate(nil)
    }
}
