import Observation

/// One window telling the others that the source list just moved.
///
/// **Not a doorbell, and deliberately smaller than one.** The agent rings
/// `.sourcesChanged` when anything edits the library, and this app does not
/// listen — `FEATURES.md` records why the panel polls instead. What this covers
/// is the narrower case that polling handles badly: a change *this app* just
/// made, in one of its own windows, which another of its own windows is
/// displaying. The picker applies a set of collections and the settings panel
/// is showing the list they belong to; waiting up to a minute to redraw
/// something we did ourselves reads as a panel that has broken.
///
/// A counter rather than a payload, because every reader's response is the same
/// — ask the agent again. Nothing here says *what* changed, so nothing here can
/// disagree with what the agent would answer.
@MainActor
@Observable
final class SourceChanges {
    static let shared = SourceChanges()

    private(set) var revision = 0

    private init() {}

    func announce() { revision += 1 }
}
