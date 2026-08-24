import SwiftUI

/// The Mac app: a window, a photograph in it sized to fit, standard full-screen
/// support — and one panel for saying where the photographs come from.
///
/// It is a *consumer* first: it asks the agent for a picture and draws what it
/// is handed, opening neither the database nor the cache. **Settings is the one
/// place it asks for something other than a picture**, and it asks over the same
/// HTTP the pictures come over. `pgr_ctl` does all of this and more from a
/// terminal, but `pgr_ctl` never ships — so without this panel there is no way
/// for anybody else to add a photograph to their own library.
@main
struct PhotoGoRoundApp: App {
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        WindowGroup("Photo-Go-Round") {
            ContentView()
        }
        // Replacing rather than adding: the standard item opens AppKit's own
        // panel, and two About boxes is one too many.
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About \(Bundle.main.displayName)") {
                    openWindow(id: AboutView.windowID)
                }
            }
        }
        // An ordinary title bar, and the photograph strictly below it. The
        // controls are not allowed to sit on top of the picture — a window is
        // not the screensaver, and chrome overlapping the image is the one
        // thing this window must not do.
        //
        // Nothing bespoke about the presentation otherwise: the green button
        // and `toggleFullScreen:` are the whole of it, and full screen takes
        // the title bar away on its own, which is when the photograph does get
        // the whole surface.
        .defaultSize(width: 1280, height: 800)

        Window("About \(Bundle.main.displayName)", id: AboutView.windowID) {
            AboutView()
        }
        // It is exactly as big as its text, and nothing about it is resizable.
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        // The standard scene, which puts "Settings…" in the application menu
        // under About and takes ⌘, — rather than a window of our own that would
        // have to reimplement both and would sit in the wrong menu.
        Settings {
            SourcesSettingsView()
        }
        .windowResizability(.contentSize)
    }
}
