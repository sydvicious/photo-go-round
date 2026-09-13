/// What serving found when it looked for a queued card's bytes.
///
/// **Materialized cards only.** A referenced photograph is its own file on the
/// boot volume and never passes through the cache, so counting it as a hit
/// would be counting a cache that was not consulted.
///
/// **One per card met, not one per request.** A request can walk past several
/// cold cards before it serves one, and each of them was a miss — so hits and
/// misses together exceed pictures served, and the difference is the walking.
public enum CacheLookup: Sendable, Equatable {
    /// The original was here when the card reached the head.
    case hit
    /// It was not, and this is how that ended.
    case miss(Miss)

    public enum Miss: Sendable, Equatable {
        /// The request waited and the bytes arrived: served, late.
        case landed
        /// The request waited and they did not: the card was dropped.
        case timedOut
        /// The card left the queue while it was being waited for — its fetch
        /// failed and the fetcher dropped it, or its source confirmed it gone.
        case leftDuringWait
        /// Dropped on sight: the request's one wait was already spent, or the
        /// card's source is benched.
        case droppedWithoutWaiting
    }
}

/// The fetch side of the cache's hit rate: what dealing found when it put a
/// materialized card on the queue.
///
/// **Counted at the deal, not at the fetcher**, because the fetcher only ever
/// asks for queued cards whose originals are *not* held — it never sees a hit.
/// On a large library most of these are misses; that is the number this exists
/// to show, beside a serve side that almost always hits.
public enum DealLookup: Sendable, Equatable {
    /// The original was already in the cache; nothing needs fetching.
    case hit
    /// It was not, and the card goes to the queue's fetcher.
    case miss
}
