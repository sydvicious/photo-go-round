import SwiftUI

/// The window's whole contents: the photograph, and the words that appear when
/// there has never been one.
struct ContentView: View {
    @State private var shuffle = Shuffle()

    /// The name, and what is wrong with it when something is.
    private var title: String {
        guard case .noAgent = shuffle.trouble else { return Bundle.main.displayName }
        return "\(Bundle.main.displayName) - No agent"
    }

    var body: some View {
        ZStack {
            // Always mounted, even with nothing to show. It is the thing that
            // knows how big the window is, and nothing is asked for until it
            // has said so.
            PictureDisplay(frame: shuffle.shown) { pixels, screen in
                shuffle.draws(at: pixels, on: screen)
            }

            // Over the photograph while the agent cannot be reached.
            //
            // A flat grey at three-tenths: the photograph stays the thing you
            // are looking at, veiled rather than hidden. Nothing is *written* on
            // it — the words are in the title bar, where they have a background
            // to be legible against.
            if shuffle.shown != nil, case .noAgent = shuffle.trouble {
                Color.gray
                    .opacity(0.3)
                    .transition(.opacity)
            }

            // Only when there has never been a picture. A stale photograph is a
            // better answer than a blank window, so trouble that arrives after
            // one is showing stays out of the way.
            if shuffle.shown == nil, let trouble = shuffle.trouble {
                Text(trouble.words)
                    .font(.system(size: 64, weight: .thin))
                    .foregroundStyle(.white)
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
