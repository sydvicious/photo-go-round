import SwiftUI

/// The Mac app, which is deliberately almost nothing: a window, a photograph in
/// it sized to fit, and standard full-screen support.
///
/// It manages no sources and exposes no settings, because `pgr_ctl` shipped a
/// phase earlier and already does both. What it is, is a *consumer* — it asks
/// the agent for a picture and draws what it is handed, opening neither the
/// database nor the cache.
@main
struct PhotoGoRoundApp: App {
    var body: some Scene {
        WindowGroup("Photo-Go-Round") {
            ContentView()
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
    }
}
