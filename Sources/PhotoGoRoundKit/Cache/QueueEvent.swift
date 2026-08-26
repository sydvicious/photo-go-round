import Foundation
import PhotoGoRoundAgentAPI

/// What the two queues did, and why.
///
/// **Both queues say what they put on themselves and what they decided at every
/// step**, prefixed so a console with two of them interleaved stays readable:
/// `DEAL:` for a card going onto the queue of pictures to show, `SERVE:` for
/// what that queue then decided, `CACHE:` for anything written to the cache,
/// `CONFIG:` for a setting that changed underneath them.
///
/// Dealing gets its own prefix rather than sharing `SERVE:` because the two run
/// on different clocks and in different volumes: cards are dealt in bursts when
/// the queue runs short, and served one at a time. Filtering a console to one or
/// the other is the common thing to want.
///
/// `CACHE:` covers both kinds of write, and the distinction matters when reading
/// a console: an original *fetched* onto the queue of pictures to cache, and a
/// resize *kept* on the serving path. Only the first has a queue behind it, so
/// only the first ends in a depth.
///
/// A value rather than a formatted line, for the same reason a served request is
/// one: what happened can be asserted without asserting how it is worded.
/// **Every line about a queue carries that queue's depth**, so a size that
/// changed can never change without saying so: `SERVE:` lines end in how many
/// cards are queued, and the `CACHE:` lines that come off the fetch queue in how
/// many photographs are waiting. Both queues move on almost every request — a
/// card is taken, another is skipped, a fetch is asked for, one lands — and a
/// depth printed only when something is *added* leaves the reader inferring the
/// rest. `rendered` is the exception and has no depth, because keeping a resize
/// happens on the serving path and touches neither queue.
public enum QueueEvent: Sendable, Equatable {

    // MARK: The queue of pictures to show

    /// A card was dealt onto the serve queue. Costs nothing — the queue holds
    /// cards, not bytes. Prefixed `DEAL:` rather than `SERVE:`, because a burst
    /// of twenty deals is noise in the middle of reading what serving decided.
    case dealt(photo: String, source: Int64?, queued: Int)
    /// Its bytes are here, so it is the picture. `rendering` is true when they
    /// are a resize kept earlier rather than the original — the moment a kept
    /// resize pays for itself.
    ///
    /// `unconfirmed` carries the reason when the source could not say whether the
    /// photograph is still there and the copy we hold went out anyway. That is
    /// the offline case, and it is the one moment the deleted-photo guarantee is
    /// knowingly relaxed, so it is said out loud rather than left to inference.
    case serving(
        photo: String, source: Int64?, rendering: Bool, unconfirmed: String?, queued: Int)
    /// Not here. The fetch is now somebody else's problem and the queue moves on.
    case skipped(photo: String, source: Int64?, because: String, queued: Int)
    /// A photograph that is not supposed to be there at all: gone from a source
    /// that is right there, or from one that is itself gone.
    case dropped(photo: String, source: Int64?, because: String, queued: Int)
    /// The walk ended with nothing to hand over, and why it ended.
    ///
    /// Two bounds stop it and they mean opposite things: `out of cards` is a
    /// queue that is genuinely cold, and `out of time` is a queue whose cards
    /// are mostly uncached and slow to check. Reading a console, the first
    /// says wait for the cache to fill and the second says the request budget
    /// is the thing being hit.
    case nothingToShow(walked: Int, because: String)

    // MARK: The queue of pictures to cache

    /// Somebody asked for a photograph to be fetched.
    case cacheRequested(photo: String, source: Int64?, pending: Int)
    /// It was already here when the request came off the queue, which is what
    /// stops two requests fetching the same photograph twice.
    case cacheUnnecessary(photo: String, source: Int64?, pending: Int)
    case caching(photo: String, source: Int64?, pending: Int)
    /// Fetched, and back on the queue at a random place.
    ///
    /// It used to stay off and wait to be dealt again. That is a uniform draw
    /// from the whole library, so the photograph just paid for was almost never
    /// the next one — see `PLAN.md`, *Why a fetched picture rejoins the queue
    /// after all*.
    case cached(photo: String, source: Int64?, bytes: Int64, pending: Int)
    case cacheFailed(photo: String, source: Int64?, because: String, pending: Int)
    /// A fetch that never answered and had its lane taken back.
    ///
    /// **Its own case, so it can be red.** A provider that fails says so; a
    /// provider that simply never returns says nothing at all, and the only
    /// visible trace was a queue permanently one card short. `occurrence`
    /// counts how many times this photograph has done it in this run, because
    /// the same file timing out repeatedly is a different problem from a slow
    /// afternoon and needs to be told apart at a glance.
    case cacheTimedOut(
        photo: String, source: Int64?, after: Duration, occurrence: Int, pending: Int)
    /// A source that produced nothing but timeouts, and is being left alone
    /// for a while.
    ///
    /// **Timeouts on their own are not the problem; a source that only produces
    /// them is.** Every fetch slot spent on a source that never answers is a
    /// slot the healthy sources never get, and the queue starves while the
    /// photographs it needs sit on local disk.
    case sourcePaused(source: Int64?, after: Int, until: Duration)
    /// Turned away because the backlog is full. Not a failure and not a
    /// blacklisting — the photograph is simply not asked for this time, and the
    /// next look-ahead that reaches it will ask again.
    case cacheRefused(photo: String, source: Int64?, pending: Int)
    /// A resize was made and written to the cache.
    ///
    /// **The other half of what the cache holds, and the half that was silent.**
    /// Fetching an original is the only thing the cache *queue* does, so those
    /// were the only `CACHE:` lines; but a referenced photograph is never
    /// fetched — its original is the file on disk — and the only thing ever kept
    /// for one is this. A source of referenced photographs could fill gigabytes
    /// of renderings without printing a line.
    case rendered(photo: String, source: Int64?, at: String, bytes: Int)
    /// Bytes asked for in advance, for cards still sitting in the serve queue.
    ///
    /// Prefixed `CACHE:` because it is about filling the cache, not about what
    /// was shown — the cards it names keep their places and their turn.
    case lookedAhead(cards: Int, asked: Int, pending: Int)

    // MARK: Settings

    /// A preference the agent acts on has changed underneath it.
    case configurationChanged(what: String)

    /// A photograph, and which source it came from.
    ///
    /// **The row id rather than the `uuid`**, because these lines are read by a
    /// person: `source 6` is what `pgr_ctl sources list` prints beside the path,
    /// and a uuid is thirty-six characters of nothing to hold on to. A client
    /// naming a source still uses the `uuid`, which is the identity that is
    /// stable across a rebuilt database; this one is not, and does not need to
    /// be for a line somebody is reading now.
    /// Bytes as a person reads them. The cache lines used to print raw counts
    /// while every status line printed `332.6 MB`.
    static func bytes(_ count: Int64) -> String {
        count == 0 ? "0 bytes" : count.formatted(.byteCount(style: .file))
    }

    static func name(_ photo: String, _ source: Int64?) -> String {
        source.map { "\(photo) (source \($0))" } ?? photo
    }

    /// The line a person reads. The prefix is the queue it belongs to.
    public var line: String {
        switch self {
        case .dealt(let photo, let source, let queued):
            "DEAL: \(Self.name(photo, source)) — \(queued) queued"
        case .serving(let photo, let source, let rendering, let unconfirmed, let queued):
            "SERVE: \(Self.name(photo, source)) is here as \(rendering ? "a kept resize" : "its original"), "
                + (unconfirmed.map { "unconfirmed (\($0)), showing it anyway" } ?? "showing it")
                + " — \(queued) queued"
        case .skipped(let photo, let source, let because, let queued):
            "SERVE: \(Self.name(photo, source)) skipped — \(because), \(queued) queued"
        case .dropped(let photo, let source, let because, let queued):
            "SERVE: \(Self.name(photo, source)) dropped — \(because), \(queued) queued"
        case .nothingToShow(let walked, let because):
            "SERVE: nothing to show — \(because), walked \(walked)"
        case .cacheRequested(let photo, let source, let pending):
            "CACHE: asked for \(Self.name(photo, source)) — \(pending) waiting"
        case .cacheUnnecessary(let photo, let source, let pending):
            "CACHE: \(Self.name(photo, source)) is already here, skipping it — \(pending) waiting"
        case .caching(let photo, let source, let pending):
            "CACHE: fetching \(Self.name(photo, source)) — \(pending) waiting"
        case .cached(let photo, let source, let bytes, _):
            // **One line, one event: the original is now in the cache.** It
            // used to say "fetched, N bytes, back on the queue", which is three
            // facts about the network and the queue and never the word anybody
            // reading a console is looking for.
            "CACHE: \(Self.name(photo, source)) original cached, \(Self.bytes(Int64(bytes)))"
        case .cacheFailed(let photo, let source, let because, let pending):
            "CACHE: \(Self.name(photo, source)) failed — \(because), \(pending) waiting"
        case .cacheTimedOut(let photo, let source, let after, let occurrence, let pending):
            "CACHE: \(Self.name(photo, source)) did not answer in \(after) — put back in the pool"
                + (occurrence > 1 ? "; \(occurrence) times now for this file" : "")
                + ", \(pending) waiting"
        case .sourcePaused(let source, let after, let until):
            "CACHE: source \(source.map(String.init) ?? "?") paused for \(until)"
                + " — \(after) fetches in a row did not answer"
        case .cacheRefused(let photo, let source, let pending):
            "CACHE: \(Self.name(photo, source)) not asked for — backlog full at \(pending) waiting"
        case .rendered(let photo, let source, let at, let bytes):
            "CACHE: resized \(Self.name(photo, source)) to \(at), \(Self.bytes(Int64(bytes)))"
        case .lookedAhead(let cards, let asked, let pending):
            "CACHE: looked ahead \(cards) cards, asked for \(asked) — \(pending) waiting"
        case .configurationChanged(let what):
            "CONFIG: \(what)"
        }
    }

    /// Where these go when nobody has asked for them on a console. The unified
    /// log takes every one; a host that wants them in a terminal supplies its
    /// own sink and prints `line`.
    public func report() {
        Log.cache.notice("\(self.line, privacy: .public)")
    }
}
