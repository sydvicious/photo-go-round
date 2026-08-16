import Foundation
import PhotoGoRoundKit

// The headless agent. It owns the library and does all the work; every other
// surface is a consumer that reads the deck and displays cards.
//
// Fleshed out in the last slice of Phase 1. For now it exists so the package
// has its executable product and so the bundle script has something to wrap.

Log.deck.notice("PhotoGoRoundServer starting")
