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
            // **Replacing the standard item, not adding beside it.** A `Window`
            // scene puts nothing in the application menu and answers to no
            // keyboard shortcut, so both are restated here. `replacing:` keeps
            // the item where every Mac app has it — under About, above Quit —
            // and `⌘,` is the shortcut `Settings` would have taken for free.
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    openWindow(id: SourcesSettingsView.windowID)
                }
                .keyboardShortcut(",", modifiers: .command)
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

        // **A `Window` of our own rather than the `Settings` scene.** `Settings`
        // gives the menu item and `⌘,` for free, and this gave both of them
        // back to get one thing it would not yield: a window the user can
        // resize. `.windowResizability(.contentMinSize)` was declared on the
        // `Settings` scene and ignored — the window came up pinned to its
        // content whatever the content said its maximum was. The two lines in
        // `.commands` above are the whole price.
        Window("\(Bundle.main.displayName) Settings", id: SourcesSettingsView.windowID) {
            SourcesSettingsView()
        }
        // The content names a floor and the rest is the user's. A list of
        // sources has no natural length: somebody with forty should be able to
        // see forty.
        .windowResizability(.contentMinSize)
        .defaultPosition(.center)

        // **Its own window, like Settings and for the same reason.** A list of
        // several hundred collections has to be resizable, and a sheet on macOS
        // is not. It asks the agent for the sources it needs rather than being
        // handed them, so nothing has to be threaded through a scene.
        Window("Choose Collections", id: CollectionPickerView.windowID) {
            CollectionPickerView()
        }
        .windowResizability(.contentMinSize)
        .defaultPosition(.center)
    }
}
