import PhotosGoRoundAgentAPI
import PhotosGoRoundDisplay
import SwiftUI

/// The window's whole contents: the photograph, the words that appear when
/// there has never been one, and the ways to reach Window Settings — the gear,
/// the right-click menu, and the View menu through `WindowCommands`.
struct ContentView: View {
    /// **The consumer name is the app's, and it is a parameter now.** The loop
    /// moved into `PhotosGoRoundDisplay` in Phase 2 of `Screensaver Plan.md` so
    /// the screensaver could run the same one; the deck keys a consumer's
    /// history on this string, so the two must not share it.
    ///
    /// **Its interval is a copy of the screensaver's, taken when the window is
    /// made.** Syd, 2026-09-14: "the app window will read the current
    /// screensaver internal when it is created, and it will stay there with its
    /// own copy of the setting even if the screensaver interval is changed." A
    /// window's preferences are never stored.
    @State private var shuffle: Shuffle
    /// This window's *Shuffle All*, changed from Window Settings and never
    /// stored.
    @State private var interval: ShuffleInterval
    /// Whether the Window Settings sheet is up.
    @State private var showingSettings = false

    @Environment(\.openWindow) private var openWindow

    init() {
        let interval = ScreensaverPreferences(deployment: .development).interval
        _interval = State(initialValue: interval)
        _shuffle = State(initialValue: Shuffle(consumer: "app", dwell: interval.duration))
    }

    /// The name, and what is wrong with it when something is.
    ///
    /// **The trouble supplies its own words.** They used to be spelled here, so
    /// adding *Not answering* beside *No agent* would have meant writing the
    /// distinction down twice and letting the two copies drift.
    private var title: String {
        guard let trouble = shuffle.trouble, trouble.isAgentTrouble else {
            return Bundle.main.displayName
        }
        return "\(Bundle.main.displayName) - \(trouble.words)"
    }

    var body: some View {
        ZStack {
            // Always mounted, even with nothing to show. It is the thing that
            // knows how big the window is, and nothing is asked for until it
            // has said so.
            PictureDisplay(frame: shuffle.shown) { pixels, display in
                shuffle.draws(at: pixels, on: display)
            }

            // Over the photograph while the agent cannot be reached.
            //
            // A flat grey at three-tenths: the photograph stays the thing you
            // are looking at, veiled rather than hidden. Nothing is *written* on
            // it — the words are in the title bar, where they have a background
            // to be legible against.
            if shuffle.shown != nil, shuffle.trouble?.isAgentTrouble == true {
                Color.gray
                    .opacity(0.3)
                    .transition(.opacity)
            }

            // Only when there has never been a picture. A stale photograph is a
            // better answer than a blank window, so trouble that arrives after
            // one is showing stays out of the way.
            if shuffle.shown == nil, let trouble = shuffle.trouble {
                // The same view the screensaver mounts. It moves, which matters
                // less in a window than on a panel left on all night — but one
                // empty state built once is the point, and this is where it can
                // be looked at with a debugger attached.
                EmptyStateDisplay(words: trouble.words, detail: trouble.detail)
            }

            // **A layer of nothing, above the picture and the words, for the
            // right-click menu to land on.** Both of those are AppKit views, and
            // a right-click on one is not certain to reach a SwiftUI context
            // menu.
            Color.clear
                .contentShape(.rect)
        }
        .overlay(alignment: .topTrailing) {
            SettingsGear { showingSettings = true }
                .disabled(Installer.shared.isBusy)
        }
        // While the app installs what it carries, which may restart the agent.
        .overlay(alignment: .topLeading) {
            InstallingBadge()
        }
        // After the gear, so the gear has the menu too. Syd, 2026-09-14:
        // "Right click anywhere in the window will invoke context menu, even
        // the gear."
        // With ellipses, which the View menu's item does not have: Syd,
        // 2026-09-14, "Put the elipsis back for both items in the context menu."
        .contextMenu {
            Button("\(Bundle.main.displayName) Settings…") {
                openWindow(id: SourcesSettingsView.windowID)
            }
            Button("Window Settings…") { showingSettings = true }
        }
        .disabled(Installer.shared.isBusy)
        .sheet(isPresented: $showingSettings) {
            WindowSettingsSheet(interval: $interval)
        }
        .onChange(of: interval) {
            shuffle.setDwell(interval.duration)
        }
        // How the View menu's Window Settings finds this window's sheet.
        .focusedSceneValue(\.windowSettings, $showingSettings)
        .background(.black)
        // **The window's own title, never over the picture.** Words on the
        // photograph would have to stay legible against whatever happens to be
        // behind them, and `PLAN.md`'s *Showing unavailability* forbids
        // annotating a photograph to report a problem elsewhere. A title has its
        // own background and costs the window no chrome it did not already have.
        .navigationTitle(title)
        .animation(.easeInOut(duration: 0.25), value: shuffle.trouble)
        .animation(.easeInOut(duration: 0.25), value: Installer.shared.isBusy)
    }
}

#Preview {
    ContentView()
}
