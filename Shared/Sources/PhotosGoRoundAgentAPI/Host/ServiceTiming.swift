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

    /// What a picture client waits for one picture. `PictureClient.defaultLimit`
    /// is this, and the reasoning for five seconds is written there.
    ///
    /// **Moved here on 2026-09-16** so `serveCheckBudget` could be held against
    /// it. While it lived only in `PhotosGoRoundDisplay`, nothing on the agent's
    /// side could see it, which is the same drift this file exists to stop.
    ///
    /// **It went to fifteen for one night and came back.** Measuring the render
    /// distribution needed `resizeBudget` at ten seconds, and
    /// `BoundOrderingTests` holds the sum of the three serving waits under this
    /// one, so it had to move with it. Both are back as of 2026-09-19: the p95
    /// came in at 1,406 ms, `resizeBudget` is 1.5 s, and 2 + 1 + 1.5 fits under
    /// five with room.
    ///
    /// **It is a client's number, which is why that mattered.** The app, the
    /// screensaver and the wallpaper extension each compile their own copy, so
    /// a change here is only real once all three are reinstalled. Landing the
    /// budget under the original five is what let the agent carry the whole
    /// change alone.
    public static let pictureReadLimit = Duration.seconds(5)

    /// What serving allows itself, in total, to ask a source whether the picture
    /// going out is still there.
    ///
    /// **Measured 2026-09-16.** `photolibraryd` stopped answering and serving a
    /// cached Photos picture took 21 seconds: `existence` waited out a
    /// ten-second library bound, came back *unknown*, and `availability` waited
    /// out another. The picture then went out anyway, as *unknown* always lets
    /// it — to a client that had given up sixteen seconds earlier.
    ///
    /// **One second, against questions measured in milliseconds.** It is spent
    /// after `Preferences.serveWait`'s two, and the two together have to finish
    /// inside `pictureReadLimit`. What running out costs is an unconfirmed
    /// picture: one we hold, shown without checking that nobody deleted it in
    /// the minutes since the last scan.
    public static let serveCheckBudget = Duration.seconds(1)

    /// How long a request waits for its resize — its turn on the resizer and
    /// the resize together — before it sends the original instead.
    ///
    /// **Measured 2026-09-16.** One resize took 89 s inside Apple's HEIC
    /// decoder at 17:02, with nothing ahead of it on the queue, and the
    /// wallpaper and the app waited 92 s and 93 s behind it. Syd: "just serve
    /// the original image if the resizer stalls."
    ///
    /// **One second was Claude's number**, and it was set from the healthy case:
    /// a resize measured 0.10–0.24 s one at a time. The field disagrees. Over
    /// 2,257 deals on 2026-09-18 the renders that finished ran to a median of
    /// 334 ms and a p99 of **997 ms** — the distribution runs flat into the
    /// wall — and 242 of them, better than one in nine, were cut at the budget
    /// and went out as originals instead.
    ///
    /// **Why a give-up is worth so little.** Syd, 2026-09-18: "the calling
    /// client is going to resize them anyway; no sense in abandoning a
    /// mostly-done resize just to redo it again on the client side." The
    /// arithmetic agrees — cutting a resize does not save that second, it moves
    /// it to the client and adds a 6.4 MB mean transfer on top. The budget is
    /// not here to make slow pictures fast. It is here for the 89-second
    /// decoder, and a generous number does that job as well as a tight one.
    ///
    /// **One and a half seconds, and it is the p95 of 3,573 measured renders.**
    /// Syd's rule, 2026-09-18: "we should set the limit to the p95 of our
    /// measurements." Overnight into 2026-09-19, with this set to ten seconds
    /// so nothing was cut and `RENDER:` could see the whole distribution:
    /// median 357 ms, p90 927 ms, **p95 1,406 ms**, p99 4,489 ms, worst
    /// **26,683 ms**. Sixteen of the 3,573 were abandoned, so that is the real
    /// shape and not its left half — which is what the old one-second number
    /// had been read from, a p99 of 997 ms that was only ever the wall it was
    /// hitting.
    ///
    /// One picture in twenty is served as its original at this number, against
    /// better than one in nine at a second. The 26-second monster is still cut,
    /// which was always the point.
    ///
    /// **Measured on an M1 Max, and that is the caveat to carry.** Syd, the
    /// same day: "on slower machines it might not be enough. Oh, well. M1 Max
    /// is 6 years old now." A slower Mac renders slower, so its own p95 is
    /// higher and it will serve more originals than this machine does —
    /// degrading toward the old behaviour rather than toward a blank frame,
    /// which is the right direction to be wrong in.
    ///
    /// **Slow does not mean big**, which is worth knowing before anyone tunes
    /// this by looking at file sizes. The first night's lines had a 10.9 MB
    /// JPEG render in 124 ms and a 1.8 MB one take 5,997 ms. Whatever the tail
    /// is, it is the decoder, not the disk.
    ///
    /// **Measured on an M1 Max, and that is the caveat to carry.** Syd, the
    /// same day: "on slower machines it might not be enough. Oh, well. M1 Max
    /// is 6 years old now." A slower Mac renders slower, so its own p95 is
    /// higher and it will serve more originals than this machine does —
    /// degrading toward the old behaviour rather than toward a blank frame,
    /// which is the right direction to be wrong in.
    ///
    /// Spent after `Preferences.serveWait`'s two and `serveCheckBudget`'s one,
    /// and the three together have to finish inside `pictureReadLimit`:
    /// 2 + 1 + 1.5 = 4.5 against five. `BoundOrderingTests` holds that sum, and
    /// it is what stops this number drifting upward on its own — the p95 of a
    /// slower machine would not fit, and the test is where that gets noticed.
    public static let resizeBudget = Duration.milliseconds(1500)
}
