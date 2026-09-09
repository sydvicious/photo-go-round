import PhotoGoRoundDisplay
import SwiftUI

/// The window's whole contents: the photograph, and the words that appear when
/// there has never been one.
struct ContentView: View {
    /// **The consumer name is the app's, and it is a parameter now.** The loop
    /// moved into `PhotoGoRoundDisplay` in Phase 2 of `Screensaver Plan.md` so
    /// the screensaver could run the same one; the deck keys a consumer's
    /// history on this string, so the two must not share it.
    @State private var shuffle = Shuffle(consumer: "app")

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
        }
        .background(.black)
        // **The window's own title, never over the picture.** Words on the
        // photograph would have to stay legible against whatever happens to be
        // behind them, and `PLAN.md`'s *Showing unavailability* forbids
        // annotating a photograph to report a problem elsewhere. A title has its
        // own background and costs the window no chrome it did not already have.
        .navigationTitle(title)
        .animation(.easeInOut(duration: 0.25), value: shuffle.trouble)
    }
}

#Preview {
    ContentView()
}
