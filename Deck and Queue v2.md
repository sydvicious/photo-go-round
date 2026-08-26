# Summary

Split the deck and the cache into two machines that do not know about each other: a cache that refreshes itself by drawing at random from everything not on the local filesystem, and a bounded deck that shuffles only what the cache and the local filesystem already hold.

# Rationale

The current design works, and it took a fortnight of measured failures to make it work. Every one of those failures came from the same place: a card is dealt before its bytes exist, so serving has to warm the cache, the filler has to count fetches in flight, the deck needs a servable-only twin of every query, and a launch bridge exists to break the deadlock all of that creates. None of that machinery is about shuffling photographs or about caching them — it is about keeping two populations in step. Make the cache *be* the deck's pool and the gap they were bridging is gone, and the machinery goes with it.

# Phases

**All eight were built on 2026-08-26 and the agent has been run on the real
library.** What running it found is at the end of *Detailed discussions*; the
phases are left as written, because the order they were done in is the part
worth keeping.

- **Phase 1 — Residency becomes a fact in the database.** `photo.cached_at`, written by the byte store, reconciled from the filesystem at launch. No behaviour change; this is what lets the deck's pool be a `WHERE` clause.
  - Three readers: the deck's pool predicate, the eviction order's tiebreak, and the refresher's stop-condition count.
  - Schema v7: `cached_at INTEGER`, index on `(source_enabled, media_type, cached_at)`.
  - `PhotoStore.adopt`/`remove`/`removeSource`/`removeAll` write it through.
  - `indexCache` reconciles the column against the walk it already does.
  - Prove: after a rebuild the column and `PhotoStore.residentPhotoUUIDs` agree exactly.
- **Phase 2 — The cache refreshes itself.** A `CacheRefresher` that picks a remote asset uniformly at random, does nothing if it already holds it, and spends a download credit when it does not.
  - A wasted draw spends no credit and the refresher draws again; the round ends on credits, on the disk bounds, or when nothing remote is left un-held.
  - Budget: twice the deck's maximum size at launch, one credit back per card drawn, capped at the same figure.
  - A held photograph lost involuntarily — gone at its source, so its bytes go too — also returns a credit.
  - **Only launch and a card being drawn start a round.** Credits returned any other way are banked, so a refresh that removes hundreds of photographs does not set an unattended agent downloading.
  - Stops on the byte ceiling and on the free-space floor regardless of credits — the cache is bound by disk before it is bound by anything else.
  - Reuses `claimed_at` so two lanes never fetch the same photograph.
  - Keeps the lane pool's concurrency, per-photograph deadline, and source benching; drops its backlog list.
  - Prove: a cold library with no client fetches its allowance and stops; each draw releases exactly one more; a cache holding nine in ten still fetches the full allowance; a full disk stops it whatever the credits say. Parameterised on deck size, so the tests keep holding when the number moves.
- **Phase 3 — The deck deals only what is servable.** One predicate change — `cached_at IS NOT NULL OR storage = 'referenced'` — and the servable-only twin path is deleted.
  - Out: `nextServableCandidate`, `withServableSet`, the `servable_now` temp table, `servablePopulationSQL`, `dealablePopulation(servableOnly:)`, `dealServable`.
  - Prove: with an empty cache and no referenced source the deck deals nothing; one landed download makes it deal exactly that photograph.
- **Phase 4 — Serving stops doing the cache's job.** A request takes the head of the deck and serves it.
  - Out: `lookAhead`, `lookAheadDepth`, `wantCached`, `wantsCaching`, `walkBudget`, the walk's two bounds, `queueCameUpEmpty`.
  - The one remaining skip loop is a photograph that will not render or whose cached file has disappeared. The second drops its own stale reference, returns a credit, answers nil, and the deck moves on.
  - **The hook already exists and is half-wired.** `PhotoStore.url(for:)` stats the file and calls `forget(key)` when it is missing — that is the discovery. Phase 1 leaves it dropping the in-memory entry only, so `cached_at` stays set until the next launch walk, because there was no credit counter yet to return anything to. When the counter lands, that path clears the column and returns the credit in the same breath.
  - Prove: a served request does one existence check, not a look-ahead window's worth.
- **Phase 5 — The deck sheds what serving no longer needs.** Nothing rejoins from a fetch any more, so placement stops being random and the filler stops counting.
  - Schema v7 also drops `sort_key` and `queue_order`; `respaceIfCollapsing` and the gap arithmetic go.
  - `FillerBox` reduces to *top up to the deck's maximum when short*: no gauge in-flight accounting, no bridge, no `seedServableFirst`, no `dealWhatIsAlreadyHere`, no `topUpIfShort(force:)`.
  - Prove: the existing filler tests still pass against a filler with two closures and no state.
- **Phase 6 — Eviction by most-recently-viewed.** `PhotoStore.evictIfNeeded` orders by `COALESCE(last_shown_at, cached_at)` rather than by write time, and nothing is exempt.
  - Out: the `protecting:` argument, `queuedPhotoUUIDs`, and `EvictionResult.protectedFromEviction`.
  - Prove: a cache at its ceiling evicts the longest-unseen photograph, keeps the one that just landed, and reaches the ceiling even when every entry is a card the deck is holding.
- **Phase 7 — Remove what no longer means anything.** The `Out:` lists above are the deletions each change forces; this is the sweep for what only becomes dead once all of them have landed, and for the tests that encode the design being replaced.
  - Code: anything left with no callers after phases 3–6, found by build warnings and by grep rather than by memory. Deleted outright — git has the history — and named in the phase's summary so the removal is a recorded event rather than a silent one.
  - **Tests are the point of this phase, not an afterthought.** A test asserting v1 behaviour that still passes is worse than one that fails: it locks in a design decision that was deliberately reversed, and the next person reads it as a requirement. Every test whose subject is gone goes with its subject.
  - Candidates by name: `ServableSeedTests`, `StarvedQueueTests`, `InFlightStarvationTests`, `DealPacingTests`, and the look-ahead and walk-budget cases in `ServeWalkTests` and `QueueTopUpTests`.
  - Rewritten rather than deleted: `QueueFillerTests` and `FillerBoxTests` keep their subjects and lose their state; `DeckTests` loses the servable-only twin and keeps the pass and window; `SchemaSnapshot` and `MigratorTests` take the new columns.
  - **Coverage must not fall silently.** Anything a deleted test was the only assertion of either moves to a new test or is written down here as deliberately no longer guaranteed.
  - Prove: the suite is green, and no test names a symbol that no longer exists.
- **Phase 8 — The ledger.** Man pages, `pgr_ctl deck stats`, the Mac panel's numbers, and a note to Syd on which PLAN.md sections this plan supersedes.

# Design Decisions

- **Always have something to show, whenever possible.** The first duty, and it outranks fairness and evenness both. It is why the deck deals only what can be shown right now, and why a cold start serves whatever is already on disk rather than waiting for anything.
- **The cache is the deck's pool.** The deck shuffles what is resident or referenced and nothing else, so a dealt card is servable by construction. This is the whole change; everything else on this list follows from it.
- **Two selections over two populations.** The cache draws from everything `materialized` — the remote assets — and downloads whatever it does not already hold. The deck draws from `cached OR referenced`. Downloading is what moves a photograph into the deck's reach; eviction is what takes it back out.
- **The deck's algorithm is unchanged, and `repeatWindowFraction` stays deck-only.** Pass, window, random offset, `shuffle_key` — exactly what ships today, deciding what goes in the deck's card slots. The only thing that moves is the population it runs over.
- **The cache picks a remote asset at random and does nothing if it already holds it.** No eligibility predicate, no window, no pass, no `shuffle_key`. A wasted draw costs an indexed row read and a dictionary lookup, and the miss rate rising as the cache fills is a rate limiter rather than a defect.
- **The remote half keeps its share of the screen, because the cache rotates.** A small resident set is a turnstile rather than a small pool: each photograph enters it never-dealt, and never-dealt is always eligible. Measured at two ratios, the remote share of the screen matched its share of the library. What bounds it is fetch latency, not library composition.
- **Residency moves back into the database.** The deck's pool is now residency, so residency has to be something a `WHERE` clause can say. The byte store stays the writer of that fact and the filesystem stays the truth; `cached_at` is the projection, reconciled at launch.
- **The download budget is a credit counter, not a queue.** Twice the deck's maximum size at launch, one back per draw, capped at that figure. Always expressed relative to the deck rather than as a constant, because the deck size is a number we expect to move. It bounds the *rate* of fetching and nothing else.
- **The credit counter lives in memory and does not survive a restart.** It is a rate limiter for one process's session, so persisting it would only create a way for it to be wrong. Every launch grants a fresh allowance; a cache that is already full finds nothing to spend it on.
- **The cache is still bound by disk space.** The byte ceiling and the free-space floor decide how large the cache gets; the credit counter decides only how fast it gets there. Either bound stops the refresher on its own, whatever the other says.
- **The deck keeps its configured maximum size — twenty today — and stays a FIFO.** Random placement existed only because completed fetches rejoined the queue out of deck order. Nothing rejoins now, so `sort_key` and its respacing are deleted rather than kept for a reason that no longer applies.
- **`claimed_at` changes owner rather than leaving.** It exists because a fetch happens between choosing and storing — which is now true of the cache and false of the deck.
- **The lane pool keeps its hard-won parts.** Per-photograph deadlines, the detached-and-abandoned fetch, `BlockingWork`, and exponential source benching all stay: they answer a hostile provider, and v2 does not make providers less hostile.
- **Eviction becomes LRU by view, and nothing is exempt.** The order is `COALESCE(last_shown_at, cached_at)`, so a photograph that has never been shown counts as of the moment it landed — the newest thing in the cache rather than the oldest. Nothing is protected, so the ceiling is always reachable.

# Background

Today the deck deals from every photograph in the library, whatever state its source is in, and serving finds out by trying. That inversion was deliberate — it replaced a per-source pump that had to track which sources were mounted and which photographs were cached — and it removed real bookkeeping. What it added, one measured failure at a time between 2026-08-23 and 2026-08-26, is a second body of bookkeeping in a different place: look-ahead so a healthy source cannot starve a sick one, a walk budget so a cold queue cannot hold a socket for two minutes, a gauge that counts fetches in flight so dealing does not overshoot, an exception in that gauge because an empty queue is short whatever is in flight, a launch bridge that prefers servable cards, a second bridge for when a walk comes up empty, and a servable-only twin of the deck's population arithmetic because the population a question is asked about has to be the population it is answered from.

Each of those is correct and each has a test. Together they are the reason this plan exists.

# Detailed discussions

## The two halves

**Cache.** Picks uniformly at random from the total asset catalog that is not part of the local filesystem, and does nothing if what it picks is already held. Evicts based on most-recently-viewed. Starts downloading at launch. Stops after downloading twice the maximum size of the deck, so that an agent with no client attached does not burn the network. Starts again as cards are drawn from the deck. Bound by disk space throughout.

**Deck.** Shuffles only what is in the cache or what is available via the local filesystem. Maximum size currently 20, but we may refine as we tinker. The shuffle is the one that ships today, unchanged — pass, repeat window, random offset, `shuffle_key` — and `repeatWindowFraction` is its setting and no one else's.

Everything below is what those statements imply for the code that exists.

## What "2× the size of the deck" bounds, and what it does not

The allowance is **twice the deck's maximum size**, and it is written that way everywhere rather than as a constant, because the deck size is a number we expect to play with. Twenty today, so forty downloads today, and neither figure should appear anywhere a change of the first does not carry to the second.

It is a **lead**, never a cache size. It is spent down as photographs land and earned back as cards are drawn, so the cache runs at most a lead's worth of photographs ahead of what has been shown.

The credit rule in full, with *N* the deck's maximum size:

- At launch, credits = 2*N*.
- A completed download spends one. A download that fails or times out does not — the photograph was not obtained, so the allowance was not used.
- A draw that lands on something already held spends nothing, and the refresher draws again.
- A card drawn from the deck grants one, capped at 2*N*.
- A held photograph lost involuntarily grants one, capped the same way. The cache paid for a photograph and no longer has it. Two paths reach this: its original goes from its source and the refresh takes the row and the bytes together, or its cached file simply disappears and the deck finds out by asking for it.
- The refresher runs while credits > 0 and the not-yet-held remote population is non-empty.

**A cached file that has disappeared is discovered by the request that wanted it.** Nothing scans for this. The deck asks for the photograph's bytes; the lookup finds its own reference stale; it drops that reference — the in-memory entry and `cached_at` together — returns one credit, answers nil, and the deck moves on to the next card. No re-request, no repair pass, no `wantsCaching`: the photograph is simply not held any more, which puts it back among the remote assets for the cache to draw at random like any other.

That is also the only place the two grants can coincide — the card was drawn *and* a held photograph was lost, so both lines fire. They are counting different things, one pacing and one replacement, and the cap bounds the pair regardless.

**Only two things start a round: launch, and a card being drawn.** Credits granted any other way are banked and sit there. That is not a detail — a refresh that finds five hundred photographs gone would otherwise hand back five hundred credits and set an unattended agent downloading, which is precisely what the allowance exists to prevent. The cap holds it to 2*N* in any case, but the round must not begin at all until somebody asks for a picture.

Ordinary eviction at the ceiling grants nothing. Making room for a download is the cost of that download, and refunding it would be a credit-neutral download–evict loop that never stops.

Steady state is therefore exactly one download per picture shown, which is the same pacing the current design reaches through `Gauge.isShort` counting fetches in flight — arrived at by counting draws instead, which needs no shared counter between the fetcher and the filler. What the launch grant buys is the gap before anybody asks: enough photographs on disk that the deck has something to shuffle, and few enough that an agent sitting idle overnight is not pulling a library down a hotel link.

**Why 2*N* rather than *N* or 4*N*.** *N* would be a lead of one deck, which is spent the moment the deck fills for the first time and leaves no margin for the pictures shown while the fetches are still in flight. Beyond 2*N* the extra is not a lead any more — it is speculative downloading against a client that may never connect, which is the exact thing the stop condition exists to prevent. Two decks is one deck to fill and one to be filling while the first is played.

**Credits do not survive a restart.** Every launch grants 2*N* afresh. A cache that is already full simply finds nothing to spend them on, so there is no case where restarting causes a burst that was not wanted.

**And the disk is the real bound.** The credit counter decides the *rate*; the byte ceiling and the free-space floor decide the *size*, and they are what actually stop the cache growing. The refresher checks both before every fetch and stops on either — a cache at its ceiling holds still with a full allowance in hand and evicts one photograph for each one it takes, and a volume below `minimumFreeBytes` stops it dead. That check exists today in `PhotoCache.cache` and moves across unchanged. Nothing in the credit arithmetic can override it, which is the property worth asserting in a test: credits full, disk full, nothing fetched.

## The cache draws at random and skips what it already holds

The deck's shuffle machinery does not carry over, and it is worth saying why rather than leaving it as an omission.

**The pass has nothing to guarantee.** A pass exists so that everyone gets a turn before anyone repeats. A photograph that has been downloaded is resident, so it cannot be downloaded again while others are still waiting — the guarantee is structural, and there is no starvation for a pass to prevent.

**The repeat window would measure a wait that is already enforced.** The deck needs one because showing a photograph leaves it sitting in the pool, eligible again immediately. Downloading does not. For a photograph to become worth downloading again it has to be evicted first, and eviction takes the longest-unseen entry — a photograph that has just landed is the *newest* thing in the cache and has to wait out an entire turnover to qualify. A window on top of that counts the same wait twice, and it costs a `last_fetched_seq` column and a second ordinal to do it.

**And `shuffle_key` is not needed, because the draw has no memory.** The random offset exists on the deck side to defeat a specific failure: `ORDER BY shuffle_key LIMIT 1` takes the minimum, only the winner's key is re-rolled, so a photograph whose key lands high loses, keeps its high key *because* it never won, and loses again — measured at 3 to 391 showings over twenty thousand deals. A fresh uniform draw every time cannot do that. There is no persistent per-photograph quantity for a photograph to be unlucky in.

So the whole of the cache's selection is: **pick a remote asset uniformly at random; if it is already held, do nothing and draw again.**

```sql
-- The population: everything that is not read in place. Residency is not in
-- this predicate — it is checked after the draw, against the in-memory index.
SELECT p.id, p.uuid, p.source_id, s.uuid AS source_uuid, p.external_id
  FROM photo p JOIN source s ON s.id = p.source_id
 WHERE p.source_enabled = 1
   AND p.media_type = 'image'
   AND p.storage = 'materialized'
   AND p.render_failures < 3
   AND (p.claimed_at IS NULL OR p.claimed_at <= :claimExpiry)
 LIMIT 1 OFFSET :offset;
```

`:offset` is a uniform draw over the count of that predicate — a count and an indexed seek, not `ORDER BY RANDOM()`, which would scan the table.

**A wasted draw does not spend a download credit, and the refresher tries again.** That is what makes the miss rate self-correcting rather than self-defeating: the budget buys *photographs*, not attempts, so a cache that already holds most of the library still fetches the whole allowance it is owed — it just takes more draws to find them.

The cost of a miss is an indexed row read and a dictionary lookup against `PhotoStore`. At 90% cached that is ten draws per download; at 99%, a hundred. Both are microseconds against a fetch measured in seconds.

**Two stop conditions, so the terminal state does not spin.** A library entirely resident would otherwise draw forever and find nothing to do. The round ends when the credits are gone, when the disk bounds say stop, or when a `COUNT` of not-yet-resident remote assets reaches zero — one scalar query, run when a round begins and when a run of misses passes the population size, not per draw.

**What this gives up, stated plainly.** A uniform draw with replacement offers no guarantee about *order*: a particular remote photograph can wait a long time to be picked, where the deck's pass guarantees a turn. That is the right trade here — the cache is not what the user is watching. Fairness over the library is a long-run property of many draws, and fairness over what is *shown* is the deck's job, which it does exactly as it does today.

## Residency has to be in the database, and that reverses a decision

PLAN.md records that as of Phase 1.5 "the cache's index lives in the service's memory, rebuilt from the filesystem at launch; the database records nothing about which bytes are present." That was right when residency was a hint — something serving discovered and acted on. It is wrong now, because residency *is* the deck's pool, and a pool that cannot be expressed as a `WHERE` clause has to be shipped into one. That is precisely what `withServableSet` does today: it writes the whole resident set into a temp table on every servable deal, eight hundred rows on a warm restart, per connection.

So `photo.cached_at` comes back. Three properties keep it honest:

- **The filesystem remains the truth, and two mechanisms keep it so.** A photograph deleted at its *source* is caught by the next refresh — eventually by FSEvents, once watching lands — and the row and its bytes leave together, which returns a download credit. A cached *file* deleted under the cache root without the row going is corrected by the request that wanted it: the lookup drops its own stale reference, returns a credit, and answers nil. `indexCache` still walks the disk at launch, which corrects in bulk what nobody has asked for yet.
- **The byte store remains the only writer.** `adopt`, `remove`, `removeSource`, and `removeAll` write the column in the same breath as the in-memory entry. Nothing else touches it.
- **It is a projection, so a disagreement is a bug in one place.** A test that asserts the column and `residentPhotoUUIDs` agree after every store operation is cheap and catches the whole class.

The in-memory index does not go away — it is still what answers "where are this photograph's bytes" for the request that is serving one, and it is still what holds the byte counts eviction adds up. What changes is that the *set* of resident photographs is now also queryable, and `cached_at` has three readers: the deck's pool predicate, the eviction order's tiebreak for a photograph that has never been shown, and the refresher's stop-condition count. Note which one is *not* on that list — the refresher's draw itself, which asks the in-memory index whether it already holds what it picked rather than filtering the query. The column is for the questions that need a count or an order.

That second job moves eviction's *ordering* out of the index and into the database. `PhotoStore.Entry.createdAt` is a file's modification date and says nothing about when anybody looked at the photograph; the order now comes from a query, and the index supplies the sizes. It is one `SELECT uuid ORDER BY COALESCE(last_shown_at, cached_at)` against an indexed column, run only when the cache is over its ceiling.

## What the deck stops having to do

Serving becomes: take the head of the deck, confirm the photograph still exists with its source, hand over the bytes. One existence check, one card.

Gone with it:

- **`lookAhead` and `lookAheadDepth`.** They exist because warming was a side effect of stepping past a cold card, so a healthy referenced source stopped the walk on the first card and warmed nothing — cache requests measured falling from ~130 per five minutes to 19 the moment such a source returned. The cache warms itself now; nothing about serving decides what gets fetched.
- **`walkBudget`.** Two seconds, to stop a cold queue on a network volume producing a 125-second request. A walk of one card cannot do that.
- **`wantsCaching` and `wantCached`.** The whole demand-driven path from serving into the fetcher.
- **`queueCameUpEmpty`.** A walk that goes through every card without finding one it can serve is not a state that exists any more. An empty deck means an empty pool, which means the cache has nothing yet — and the answer to that is the refresher, which is already running.
- **The launch bridge**: `seedServableFirst`, `servableBridge`, `isBridging`, `stopBridging`, and `dealWhatIsAlreadyHere`. All four exist to prefer servable cards at moments when the ordinary deck would deal cold ones. The ordinary deck deals nothing else now.
- **`Gauge.isShort`'s in-flight accounting** and the empty-queue exception written into it. Short is `count < 20`.
- **`CacheQueue.waiting`, `known`, `maximumWaiting`, and `Pending`.** The refresher's work list is a SQL query it re-runs, not a list it accumulates; there is no backlog to bound, nothing to deduplicate against, and no `cacheRefused` event because nothing is ever refused.

## Random placement goes, and the column goes with it

`sort_key` (migration 6) was added because two things arrived in the queue and wanted opposite ends of a FIFO: a card freshly dealt from a new source, and a card returning from a completed fetch. Putting either at the head made the order pictures appeared in the order they were *fetched* in, so the fastest source owned the front; putting either at the tail cost a full traversal.

In v2 only one thing arrives — a card from the deck, in deck order — because a completed fetch does not put anything in the deck. It makes a photograph *eligible*, and the deck picks it up on its own terms or does not. So the tail is the only end there is, and FIFO is an honest description rather than a silent reversion.

The measured cost of FIFO in the current design was 8m 38s from deal to display against 4m 46s for random placement, on a queue of fifty. At today's twenty cards and ten seconds a picture the whole traversal is 200 seconds, and it scales with the deck size — worth remembering if that number goes up, since a FIFO's worst case is the whole deck. The number that mattered in that measurement, the *lead* from deal to fetch-requested, does not exist any more: a dealt card's bytes are already here.

`respaceIfCollapsing` goes with it, and so does the `n / (n - 1)` widening that keeps the gap above the highest key reachable. Both were consequences of the sort key, not of the queue.

**The column is dropped rather than kept unused.** An unused column costs a few bytes a row and does not grow, so the argument for leaving it is that it is nearly free. That is the wrong measure: it is dead code, and dead code is read by whoever comes next as something that must mean something. If a later design wants a placement key it can add a column then, on the evidence that made it want one.

## Two-level fairness, and what it costs

This is the substantive behaviour change, and it is worth stating plainly rather than discovering later.

Today one shuffle covers the library, so fairness is a single property: every photograph gets a turn against every other. In v2 fairness is a composition. The cache's random draw decides which *remote* photographs are available to be shown, giving each of them the same chance on every draw. The deck's shuffle decides which of the available ones is shown next, with the pass and the window intact.

The two are not the same kind of fairness, and the difference is worth keeping straight. The deck's is a *guarantee* — a pass promises every card a turn. The cache's is a *distribution* — uniform on each draw, with no promise about any particular photograph over any finite stretch. That asymmetry is deliberate: a guarantee costs an ordinal and a pass boundary, and it buys nothing where nobody is looking.

### The cache rotates, so the remote half keeps its share

**Read this before concluding that local sources crowd out remote ones.** They
do not. This section predicted that they would, the prediction was wrong, and
the measurement that corrected it is below — because the reasoning is seductive
and somebody will reach for it again.

**The argument that looked right.** A referenced photograph is in the deck's
pool at full strength the moment it is scanned; it needs no bytes, so nothing
throttles it. A materialized one is in the pool only while the byte-bounded
cache holds it. So the pool is the whole of every local source plus a small
window onto every remote one, the deck deals uniformly over that, and the local
folder should take a share far above its share of the library. On this library —
8,287 referenced against 5,899 materialized, with a cache holding a thousand of
them — that arithmetic says the network sources fall from 41% of the screen to
about 11%.

**Measured 2026-08-26, and it does not happen.** Two runs against a real agent,
a folder on the boot volume and a folder on a volume the classifier calls
removable:

| library | cache held | remote share of library | remote share of screen |
| --- | ---: | ---: | ---: |
| 30 local / 30 remote | 7 of 30 | 50.0% | 50.0% |
| 90 local / 10 remote | 3 of 10 | 10.0% | 10.3% |

Per-photograph fairness held inside each half as well: 2.99 showings on average
for the local photographs against 3.10 for the remote ones, both spanning two to
four.

**What the argument missed is that the cache rotates.** One credit per card
drawn means remote photographs cycle through the resident set continuously, and
each one enters it as a photograph that has **never been dealt** — which is
eligible by definition, while the referenced photographs are waiting out the
repeat window. A small cache is therefore not a small pool; it is a turnstile.
In the second run the resident set was three photographs out of a pool of
ninety-three — a standing share of 3.2% — and it delivered 10.3% of the screen,
which is exactly the remote half's share of the *library*.

So the composition is right without anything being weighted, and the deck's
window is doing the work: it holds the local photographs back exactly as much as
they need holding back.

**The real bound is fetch latency, not library composition.** Every fetch in
those runs was a local file copy, so one download per draw was never the binding
constraint. It is the constraint that decides this: the remote half can only be
shown as fast as it can be fetched, so on a slow share or a metered provider the
share falls below the library share by however much the downloads lag. A library
that is 40% remote on a link that manages one fetch per four pictures shown
cannot put remote photographs on 40% of the screen, and no amount of shuffling
will change that.

**What to watch, and what to do about it.** The signal is the remote half's
share of `pgr_ctl deck stats`' showing histogram falling below its share of the
library. The lever is the download rate — the credit rule — not a weighting on
the deck's draw. Weighting the draw would make the deck ask for photographs the
cache has not got, which is the v1 mistake this design exists to remove.

Two further consequences follow.

**The repeat window now measures against the cache, not the library.** `repeatWindowFraction` stays exactly what it is — the deck's setting, deciding what may go in the deck's card slots — but the pool it is a fraction of is now the servable set rather than the fourteen thousand rows. On a library where most photographs need fetching, a cache of a thousand means a photograph can come back after five hundred showings instead of after seven thousand. That is a change a person will feel, and it is arguably what the fraction was always trying to express — *how much has to go by before I see this again* is a question about what could have been shown, not about what exists. The man page has to say so.

**A photograph in a source that is offline for a week is not shown that week.** That is already true and stays true. What changes is that it also stops being *dealt* — today it is dealt and skipped, which costs a card; in v2 it is simply not in the pool.

## Cold start, and the deadlock that stops existing

Today: with nothing dealt, nothing can be served; with nothing served, nothing is dealt. Every piece of the launch bridge exists to break that circle.

In v2 the circle does not close, because the refresher does not wait for anybody. Launch grants a full allowance and the fetcher starts immediately. On a library that is entirely referenced the deck is full within a tick and the refresher finds nothing to do. On a library that is entirely network-backed the deck is empty and the endpoint answers `204` until the first download lands — which is the honest answer, and is the same answer today's system gives, arrived at without a bridge.

## Eviction, and where a photograph that has never been shown sorts

"Evicts based on most-recently-viewed" needs one thing said about it that it does not say itself: where a photograph that has never been viewed goes in that order.

The order is `COALESCE(last_shown_at, cached_at)` ascending. A photograph that has never been shown counts as of the moment it arrived, which puts it at the *front* of the MRU list — the newest thing in the cache, last to go — and it walks toward the back on its own as everything around it gets shown. A download that never gets picked is eventually evicted like anything else, on the same rule, with no special case for it.

**And nothing is exempt.** An exemption is a ceiling that cannot be reached: set `byteCeiling` low, or let the volume fill from something outside the agent, and we sit over the limit holding entries we are forbidden to touch. That includes today's `evictIfNeeded(protecting: queuedPhotoUUIDs())`, which skips the photographs the deck is holding and reports the count in `EvictionResult.protectedFromEviction` — the same hole at a deck's scale. It goes.

Dropping that protection is safe rather than merely acceptable. `PictureEndpoint` opens the file and takes a `StreamedFile` handle *before* it writes any header, so unlinking a file mid-serve does not disturb the transfer — the handle keeps the bytes whatever happens to the name. And the cards the deck holds are among the most-recently-shown entries anyway, so ordinary eviction reaches them last without being told to. The protection was buying an ordering it already had.

## Failure modes this design still has

- **A single hostile source can still starve the cache.** The refresher draws uniformly, so a source that is 98% of the library gets 98% of the draws — which is what happened on 2026-08-26 with the iCloud Drive folder. Source benching still answers it: a source that produces nothing but timeouts is benched with exponential backoff, and its draws are put back. Worth checking that "put back" is cheap now that there is no backlog to put anything back *into* — the answer is that the refresher just picks again.
- **Eviction churn at the ceiling.** Once the cache is full, one download per draw means one eviction per draw. That is the intended rotation, but it means a library much larger than the ceiling is continuously paying for bytes. The credit rule bounds it to picture rate, which is the right bound; there is no separate throttle and probably should not be one.
- **A photograph downloaded and then evicted before it is shown.** Possible, and correct: it means everything else in the cache has been shown more recently than that photograph arrived, which is the rotation working.

## What running it found

Five faults, and the split between how they were found is the part worth
keeping: **two came from writing the tests, three came from running it.** None
of the five was visible by reading the code.

**Found by writing a test.**

- **Lanes over-spent the allowance.** `spendable()` then `spend()` is a check
  and a decrement with a gap between them, so four lanes each saw the last
  credit and each took it — every round overshot by up to `concurrency - 1`.
  Caught only because the concurrency test asserted an exact fetch count; a
  looser assertion sails past it. Now one locked claim, refunded for anything
  that is not a landed photograph.
- **A dead source spun a round for ever.** A failed fetch spends no credit,
  which is right, and means failures alone can never end a round: the budget is
  untouched, the population still has work in it, the disk is fine. Bounded at
  eight consecutive failures. Found while deleting the in-flight starvation
  tests, whose subject was exactly a link that was not answering.

**Found by running it.**

- **Eviction discarded every rendering on a boot-volume library.** The eviction
  order asked for `WHERE cached_at IS NOT NULL`, which reads as "what the cache
  holds" and is wrong on the ordinary library: a referenced photograph has no
  `cached_at` and never will, and what the cache holds for it is a *rendering*.
  Unranked entries sort first, so on a library of local folders every rendering
  went the moment the ceiling was reached. Live, after the fix: 105 hits against
  15 misses in 120 requests.
- **The launch allowance fired before the library existed.** `begin()` ran
  before `reconcile` and the first scan, so it asked an empty `photo` table how
  much was un-held, got nought, and ended the round. On a library with no
  referenced photographs that is the cold-start deadlock exactly, reintroduced
  by doing the right thing in the wrong order. The grant now waits for the first
  scan.
- **An empty answer rang nothing.** `queueCameUpEmpty` was deleted in phase 4 on
  the reasoning that an empty walk now means an empty pool and the answer is the
  ordinary top-up — and then the hook was removed without being pointed at the
  ordinary top-up. Removing a source on the real library emptied the deck by
  cascade and left it empty for **thirty seconds**, the length of a network
  source's walk, with 592 servable photographs cached and the window blank
  throughout. It is a *separate* hook from the one a served picture rings:
  refilling the deck must not also buy the cache a download credit, or a stalled
  agent mints credits for pictures nobody saw.

**And one thing the plan never covered.** The refresh pass was awaited inside
the tick, so a slow source stalled everything else in the loop — maintenance,
eviction, the preference re-read. Measured at 30.9 seconds on a network share of
4,510 photographs. The pass is detached now, admitted one at a time, and reports
back so the loop stamps its own heartbeat; a `--once` run still waits, having
nothing else to do. Serving was never affected, and since the empty-answer fix
above neither is refilling the deck.

**One thing was found by reading a log line.** The deck took claims it no longer
honoured — dealing set `claimed_at` while the deck's own predicate had stopped
excluding claimed rows, so every card dealt hid that photograph from the cache's
draw for the full five-minute timeout. Harmless in the common case and
invisible; caught because the claim tests had to be repointed and the question
"who owns this column now" had to be answered out loud.

**What the real library measured.** 177 requests, all 200, ~2ms each, no `204`s.
Showing counts spread 2–4 across 60 photographs over 177 deals. `times_shown`
and `times_delivered` equal, so nothing the deck believed it showed went unseen.
Two sources of equal size took 88 and 89 showings.

**And one measurement corrected the plan** rather than confirming it — see *The
cache rotates, so the remote half keeps its share*, which replaced a section
predicting a bias that does not occur.

## Verification

Per phase, and end to end.

- **Unit.** The refresher's credit arithmetic and its draw, with a fake fetcher, parameterised on deck size rather than written against today's twenty: launch spends its allowance and stops; a draw releases one; a failed fetch releases none; **a draw that lands on something already held spends nothing and draws again**; a cache holding nine in ten still fetches the full allowance; a library entirely resident ends the round instead of spinning; **credits full and disk full fetches nothing**; a refresh that removes held photographs banks their credits and starts no round until a card is drawn; a card whose cached file was deleted under the agent drops its reference, returns a credit, and lets the deck move on rather than answering an error. The deck's pool predicate against a database with one resident, one referenced, and one neither. Eviction ordering by `COALESCE(last_shown_at, cached_at)`: the just-landed photograph survives, the longest-unseen goes, and a cache whose every entry is a deck card still reaches its ceiling. Residency reconciliation after a store operation and after a hand-deleted file.
- **Integration.** `photogoroundd --once` against a temporary container with a folder source on the boot volume (all referenced — the refresher must do nothing and the deck must fill) and against one with a folder source made materialized (the refresher must fetch its allowance and stop).
- **From nothing, against a mix.** Delete the database and let the system rebuild itself with a **heterogeneous set of sources** — at least one referenced folder on the boot volume and at least one materialized source on a network share, removable volume, or iCloud Drive. This is the case every phase can break and no unit test covers, because the two halves only diverge when the library has both kinds in it: a library that is all referenced never exercises the cache, and one that is all remote never exercises the bias.
  - Migration 7 runs on the empty database and `cached_at` starts NULL for everything.
  - A surviving cache directory is reconciled back into the column by the first launch walk, so a deleted database does not mean re-fetching what is already on disk.
  - The deck fills from the referenced source immediately and the refresher starts on the remote one without waiting for a client.
  - The source mix on screen settles where *Referenced sources bypass the cache* says it will — check it against that section's arithmetic rather than against an expectation of proportionality.
  - **Needs an isolated preference domain, not just `--container`.** Storage is isolated by the flag; the source list is not, so a scratch agent otherwise reconciles against the real configured sources and walks the real library.
- **Live.** Run the agent against the real library with a client attached and watch three numbers on the console: cache requests per five minutes, the deck's depth, and the eviction line. The regression to look for is the one that motivated look-ahead — a healthy referenced source coexisting with a slow network one, and the network one still getting its share of the screen.
- **The measurement that settles it.** `pgr_ctl deck stats`' showing histogram, over a night. A spread of one to three is healthy; a spread of three to four hundred is starvation, and it is invisible in every other number.

## Migration and rollout

**Two migrations, not one.** The plan had them as a single step; they landed in
different phases and migrations are append-only, so they are v7 and v8.

```sql
-- 7, "residency is the deck's pool"
ALTER TABLE photo ADD COLUMN cached_at INTEGER;
CREATE INDEX photo_resident ON photo(source_enabled, media_type, cached_at);

-- 8, "the queue is a queue again"
DROP INDEX queue_order;
ALTER TABLE queue DROP COLUMN sort_key;
```

`cached_at` starts NULL for every row and is filled by the launch reconciliation, so an upgraded database has an empty-looking cache for exactly as long as `indexCache` takes to walk it. Dropping a column needs SQLite 3.35, which the 26.0 baseline comfortably exceeds.

There is no rollback path and none is wanted: a v6 build reading a v7 database is refused by `Migrator` on the version check, which is the honest answer.

# References

- `PLAN.md` — *The deck algorithm*, *The repeat window*, *Selecting at a random offset*, *Deal over everything, and try at the moment of need*, *Dealing is paced by serving*, *The queue is not a queue*, *The queue-size sweep*, *The caps, and the arithmetic that will break them*, *Surviving a source that will not answer*, *Cold start*, *Eviction*. This plan supersedes the second half of that list; the first half survives unchanged.
- `2026-08-24 Fable Audit.md` — the still-open list, and the bugs whose fixes this plan deletes along with their machinery.
- `Sources/PhotoGoRoundKit/Deck/Deck.swift`, `Deck+Consumers.swift` — the shuffle, the pass, the window, the claim.
- `Sources/PhotoGoRoundKit/Cache/PhotoCache.swift`, `PhotoQueue.swift`, `CacheQueue.swift`, `QueueFiller.swift`, `PhotoStore.swift` — everything this plan rearranges.
- `Sources/photogoroundd/RunCommand.swift` — `FillerBox`, the gauge, the bridge.
- `Sources/photogoroundd/Service/PictureEndpoint.swift` — `queueRanShort` and `queueCameUpEmpty`.
