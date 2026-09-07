import Foundation

/// How long the agent may take to answer, and how long a client waits for it.
///
/// **Both numbers, in one file, because the bug was that they were in two.**
///
/// Measured 2026-09-07 against a Mac migrating a large photo library onto a
/// spinning disk: the agent bounded its library work at ten seconds and replied
/// at 10.0–10.7, and the app's read bound was also ten. The app therefore gave
/// up a few hundred milliseconds before every single answer arrived. Its panel
/// said *the agent is not answering* — about an agent that was answering
/// perfectly, and whose reply named the photo library as the culprit. Nobody
/// ever saw that sentence.
///
/// Neither number was wrong on its own. What was wrong is that they were equal,
/// which is a race the client always loses: it starts its clock first and pays
/// the request's overhead as well. And nothing could notice, because the two
/// lived in modules that do not see each other — the agent's bound in the
/// service, the client's in the app.
///
/// So the relationship lives here, in the module both ends already share, and
/// `BoundOrderingTests` asserts it. **The invariant is one sentence: the agent
/// always answers before the client stops listening.** A client that gives up
/// first turns a specific, actionable fault into a vague one.
public enum ServiceTiming {

    /// What the agent allows itself, in total, for the library work a single
    /// response needs.
    ///
    /// Per response rather than per call: a reply that asks the library three
    /// questions must not take three times as long as one that asks one, and a
    /// source list must not cost more because somebody has more albums.
    public static let responseBudget = Duration.seconds(8)

    /// What a client waits for a read before deciding nobody is home.
    ///
    /// **A backstop for an agent that has died, not a competitor with one that
    /// is alive.** It has to clear `responseBudget` with room for the reply to
    /// be written and read, which is why it is more than double rather than a
    /// second or two above.
    ///
    /// The cost is that a genuinely dead agent takes this long to report. That
    /// is the right trade: an agent that is gone stays gone and every surface
    /// keeps showing what it last had, while a library in trouble is something a
    /// person can act on — and only the longer bound lets them be told which of
    /// the two they have.
    public static let clientReadLimit = Duration.seconds(20)
}
