import SwiftUI

/// The window's whole contents: the photograph, and the words that appear when
/// there has never been one.
struct ContentView: View {
    @State private var shuffle = Shuffle()

    var body: some View {
        ZStack {
            // Always mounted, even with nothing to show. It is the thing that
            // knows how big the window is, and nothing is asked for until it
            // has said so.
            PictureDisplay(frame: shuffle.shown) { pixels, screen in
                shuffle.draws(at: pixels, on: screen)
            }

            // Only when there has never been a picture. A stale photograph is a
            // better answer than a blank window, so trouble that arrives after
            // one is showing stays out of the way.
            if shuffle.shown == nil, let trouble = shuffle.trouble {
                VStack(spacing: 12) {
                    Text(trouble.words)
                        .font(.system(size: 64, weight: .thin))
                    if let detail = trouble.detail {
                        Text(detail)
                            .font(.system(size: 14, weight: .regular))
                            .foregroundStyle(.secondary)
                    }
                }
                .foregroundStyle(.white)
            }
        }
        .background(.black)
    }
}

#Preview {
    ContentView()
}
