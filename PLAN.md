# Summary

Photo-Go-Round is a personal photo-shuffle system: a background agent maintains a SQLite "deck" of photos drawn from Apple Photos albums, arbitrary disk folders, and eventually Google Photos, caches them on disk at full resolution, and hands them to whatever wants to display them — desktop wallpaper, screensaver, widgets, and apps across Apple's platforms.

# Rationale

This is a decades-old itch, chased through a friend's "Desktop Picture" extension on classic Mac OS in 1992 and through Mac OS X's built-ins from 2001 onward. The tooling has been better and worse over the years, but not once in all that time has any of it handled the actual request: *take this giant blob of photos and do something nice with it.* Apple's screensaver still has only the display half solved — the transitions and layouts are genuinely beautiful — while its selection GUI chokes outright on folders holding large numbers of pictures, and what it does show is low-resolution cached thumbnails rather than originals pulled down from iCloud. Splitting the *library* problem (what to show, in what order, cached where) from the *display* problem (how to show it) is the seam where every previous attempt broke; getting it right means one deck feeds every surface, and adding a surface later — a tvOS top shelf, a Vision Pro picture frame — is a display-layer job rather than a rewrite.

# Phases

Each phase carries its own spike rather than front-loading them all, so the first running thing arrives as early as possible. Each new surface is also the first real test of assumptions made before it, so expect sandboxing and architecture decisions to move as the sequence proceeds — the design below is arranged to absorb that rather than to resist it.

- **Phase 1** — **The Mac server for pictures.** `PhotoGoRoundKit` — SQLite schema and migrator, the pool, the deck, the queue, the source protocol and its file-backed providers, the cache — plus the headless macOS process that owns it, **run from the command line**. Folder and explicitly-selected-file sources. No UI at all, and no packaging: registering as a login item is a much later concern, and nothing in Phase 1 should depend on it.
  - **Exit gate: the server is staged and running, and stays running.** Concretely:

    ```
    screen -h 10000
    cd photo-go-round
    ./Scripts/photogoroundd
    ```

    Sources are named at launch, by flag or by environment:

    ```
    PGR_FOLDERS=~/Pictures/A  PGR_FOLDERS_RECURSIVE=~/Pictures/Albums ./Scripts/photogoroundd
    ```

    Colon-separated the way `PATH` is, and adding the same folder twice is a no-op — so the variable describes what should be true rather than what to do, and is safe to leave set across restarts. **First run writes them to preferences**, so every later run needs no arguments at all.

    This is not a stopgap for the missing CLI. Naming initial sources at launch is how a service ought to be configurable, and it would still be right with `pgr_ctl` present.

    Then a long scrollback in a detached `screen`, left alone for a day, and still serving pictures when you come back to it. **Deliberately not launchd** — a login item is packaging, it arrives much later, and making Phase 1 depend on it would mean debugging TCC and code signing before the library is known to work. What this gate tests is that the thing survives being *used*: that it does not leak, wedge, spin, or quietly stop; that its output is readable a thousand lines later; and that a second terminal can add a source and see the agent notice.
  - A library that only ever runs under `swift test` has not been shown to work, it has been shown not to crash. Everything this project has found that the test suite missed — stdout buffering that only bites when stdout is not a terminal, an unavailability reason that said the wrong thing, a schema column deleted along with its neighbour — was found by standing it up.
- **Phase 2** — **`pgr_ctl`, an internal Swift command-line tool to exercise the server.** A **separate binary**, because the service has exactly one job and answering questions is not it. Add sources, refresh them, peek at the queue, serve pictures, inspect the cache, read and write preferences, run the shuffle-quality statistics. This is how the server is proven correct before any window exists, and it stays the rig for everything scriptable afterwards. Never shipped.
  - **Exit gate: `pgr_ctl` builds and drives a running server end to end.** Add a folder, watch the pool fill, watch the queue fill behind it, serve a hundred pictures, remove a photo and confirm it never appears again, unplug a drive and confirm the cached ones keep coming. Every one of those is a thing you do at a prompt against a live agent, and none of them is a unit test.
  - The two gates are the same principle applied twice, and it is worth naming: **a phase ends when you have used it, not when it compiles.** Everything found in this project so far that a test suite missed — stdout buffering under launchd, an unavailability reason that said the wrong thing, a schema column deleted along with its neighbour — was found by running the thing.
- **Phase 3** — **The Mac app that calls it.** Just a window showing the shuffle — sized to fit, with the pan — that can be taken full screen. No source management, no settings: `pgr_ctl` already does that. This is the milestone that proves the whole idea, and it is small.
  - Full screen makes it the screensaver's rehearsal space. The fit, the pan, the transitions, and the empty state all get tuned here, in a window with a debugger attached, long before Phase 6 has to make them work inside someone else's sandbox.
  - **The Apple Photos provider lands here too** — albums, smart albums, Favorites, and individually pinned assets, at full resolution — so the window is showing a real library rather than a test folder. Spike first: confirm `PHAssetResourceManager` returns true originals for iCloud-optimized assets, and measure throughput.
  - **Settle the App Group container before anything else in this phase.** An Xcode-launched sandboxed app does not use `~/Library/Containers`; CoreDevice redirects it. See *Where an Xcode-launched app puts its container*.
  - Diagnostic panels accrete later, as the phases that need them arrive — not in Phase 3.
- **Phase 4** — iOS and iPadOS app, carrying both roles in one process, since iOS has no place to put a separate server.
- **Phase 5** — iOS widget: WidgetKit extension sharing an App Group container, serving from the queue in the timeline provider.
- **Phase 6** — Mac screensaver: a `.saver` bundle, one photo at a time, sized to fit, panning slowly along whichever axis would otherwise be black.
  - Spike first: can a saver inside `legacyScreenSaver` read the cache and write the deck? Direct container access, then localhost HTTP, then XPC, with a consumption journal as fallback.
- **Phase 7** — Mac wallpaper: per-screen `NSWorkspace.setDesktopImageURL`, scheduled by the server.
- **Phase 8** — Mac widget: WidgetKit extension for Notification Center and the desktop.
  - Spike first: confirm an unsandboxed Developer ID server and its sandboxed widget extension can share an App Group container.
- **Phase 9** — Apple Watch: a watchOS app plus its WidgetKit widget, fed photos by the paired iPhone.
  - Spike first: confirm a photo survives the watch's widget rendering modes legibly, and measure what `WCSession.transferFile` costs for a rolling set of small derivatives.
- **Phase 10** — Other platforms: tvOS top shelf, visionOS wall-mounted frame.
- **Phase 11** — Google Photos provider behind the same source protocol. Last because of its OAuth flow, not because of anything structural.

Distribution is a 1.0 concern, not an 0.1 one: 0.1 runs from Xcode and from a locally built binary. What 1.0 needs — packaging, agent registration, screensaver installation, and an update mechanism — is worked out under *Shipping it* below, where the conclusion is that `SMAppService` probably removes the need for an installer altogether.

Everything above is 0.1, and it ships with one fit, one layout, and one transition. Display richness — alternate fits, tiling, transition styles, per-surface timing, more widget families — is deliberately held back and collected under "Beyond 0.1" below, where it is also argued that none of it is architecture.

Phases 1 and 2 run on file-backed sources alone — folders and individually selected photos — so the deck, cache, and hands are proven where there is no permission flow and no network to fail. Apple Photos then arrives with the Mac app, which is the point at which there is somewhere to look at it.

# Design Decisions

*Storage and the deck*

- **The only things outside our own code are Apple's OS frameworks and the photo libraries themselves.** No packages, no SDKs, no vendored source. Since PhotoKit is Apple's, the sole genuine external dependency in the entire project is the Google Photos web API — one optional provider, at the very end.
- **Raw SQLite and hand-written SQL. No ORM, no wrapper.** `libsqlite3` ships in the OS on every Apple platform, so there is nothing to bundle and nothing to vet. It is safe for multi-process access in WAL mode, which Core Data's SQLite store explicitly is not, and the deck is set-based SQL that an ORM would only obscure.
- **The database is disposable; only preferences are durable.** Everything in SQLite — the pool, the queue, cache bookkeeping — is derivable by rescanning and re-fetching. **The source list is the one thing that is not**, which is exactly why it lives in `UserDefaults` and the `source` table is a copy of it. Deleting it and the cache alongside is a legitimate recovery for any problem, and costs one rescan. Preferences live in `UserDefaults` precisely because they are the one thing that cannot be reconstructed. This is why schema changes before 1.0 need no migration, and why nothing in the design pays to protect data that can simply be rebuilt.
- **Rows are cheap and complete; bytes are expensive and windowed.** The database holds an identifier row for *every* photo in every source, however many that is. The cache holds a bounded window of actual image files. Conflating the two would cap the shuffle at the cache size.
- **The deck is a circular queue of eligible cards, with a pass reshuffle as the floor beneath it.** A photo is eligible once *w* deals have gone by since it was dealt, which leaves `N − w` candidates available at every deal and never runs dry; the pass rule catches only the two cases where the window has no answer — fraction 1.0, and a library too small for `N − w` to reach 1. Both rules are one comparison against `max(pass_start_seq, deal_seq - w)`, and the pass is one integer in a one-row table.
- **A photo may repeat across a pass boundary, and we accept it.** This is a photo shuffle, not a casino. Preventing it costs a guard band and a relaxation path, to spare someone who happens to be watching when two passes meet — every few weeks — from seeing a picture twice.
- **Selection takes a uniformly random offset into the eligible set, never its first row.** Ordering by a re-rolled random key and taking the minimum starves photos permanently: a high key loses, is never re-rolled *because* it lost, and loses forever. Measured at fraction 0.5, that gives showings from 3 to 391 where a random offset gives 186 to 217.
- **The window is a configurable fraction of the pool, default 0.5.** At 1.0 the window is unsatisfiable and the pass alone governs: the classic every-photo-once-before-any-repeat shuffle, reshuffled each time through. Lower values let photos recur sooner, which matters on a fifty-thousand-photo library where strict fairness means never seeing a favourite again. Exposed as a user default from day one, and worth a slider later.
- **No deduplication in v1.** A photo reachable from two sources is two rows and gets dealt twice. Content-level identity is genuinely hard — perceptual hashing, edited versions, format conversions — and it is additive to bolt on later.

*Consumers*

- **One deck, shared by every surface.** Wallpaper, screensaver, and widgets all deal from the same sequence, so no photo repeats anywhere until every photo has been shown. Dealing is therefore a cross-process atomic operation, and the cache must stay ahead of the *fastest* consumer, not the average one.
- **The Watch app is a companion and requires the paired iPhone.** Not an independent watchOS app, even though the platform permits one. With no Photos framework and no sources of its own, an unpaired watch has nothing to show — so the dependency is declared up front rather than degraded into at runtime.
- **One global queue of ready pictures, and consumers just take the head.** Producers fill it, clients drain it, and two displays get different pictures because serving *removes* the entry rather than because they were dealt disjoint sets in advance. There are no per-consumer reservations, no hand sizes, and nothing to reclaim from a display that goes away.
- **The queue's size is a target, not a ceiling.** Producers answer independently, so a nominal thousand overshoots by up to `sources × concurrency` and that is fine — refusing work already done, or blocking a provider being helpful, would both be worse than a number that floats. Nothing is evicted when an entry arrives; serving is the only thing that shortens the queue.

*Sources*

- **Any number of sources, of mixed kinds, active simultaneously — from Phase 1.** A source is a row, not a mode. The deck is the union of every enabled source, so nothing in the schema or the deck logic ever assumes there is one.
- **Explicitly selected individual photos are a first-class source kind, not a folder special case.** Pinning one photo and adding a folder of ten thousand are the same operation to the deck.
- **Photos inside a folder source are stored folder-relative.** Only the source's own path is absolute, so moving or renaming a folder is one row to repair rather than fifty thousand — and we only ever write metadata to items the user explicitly handed us, never to the photos inside them.
- **A photo is checked against its source in the moment before it is shown.** A user who deletes a picture must never see it again — not once more, not in the minutes before a refresh notices. A residency check is not enough, because a materialized photo is *our* copy and deleting the original does not touch it. Providers therefore answer *present*, *absent*, or *unknown*, and the third is what stops an unplugged drive being mistaken for a deletion.
- **Removed means removed.** A photo gone from a source that is demonstrably present is deleted from the pool, its queue entries cascade away, and our cached copy is deleted with it. No soft-delete tier, no `available` flag to reason about. These are transient images and per-photo history is not worth a second lifecycle; a file that returns is a new entry.
- **Changes are found by rescanning on an interval for 0.1; watching becomes a 1.0 requirement.** Rescanning is cheap and invisible — measured at 2.4 seconds for twenty thousand photos, with a concurrent consumer's deal latency unchanged at 0.1 ms median. But the play-time check only protects surfaces that render on demand. Widgets and the Watch render ahead of time and cannot be retracted, so before Phase 5 and Phase 9 a deletion has to *arrive*: `FSEventStream` for folders, `PHPhotoLibraryChangeObserver` for Photos. The preferences plist stays polled either way.
- **We survive folder renames and moves; anything else the user does inside a folder is theirs.** A photo reorganized within or between folders is treated as a departure and an arrival, losing its shuffle history. Recognizing it would require stamping every file, which is the cost the narrow scope exists to avoid.
- **Still images only. Videos are out of scope until 2.0.** Scanners filter them out deliberately rather than by omission, and the schema carries a `media_type` column from the first migration — so adding video later is a change to a predicate and a set of display capabilities, not a rescan of every source.
- **Animated GIF and animated HEIC display as their first frame, and always will.** Unlike video, this is a settled non-goal rather than a deferral. It also happens to be free: the subsampled decode already asks for frame 0.
- **Apple Photos is entirely optional; the system is complete without it.** A user who never wants the Photos library involved gets a fully working product from folders and individually selected files alone — and is never shown a Photos permission prompt, because we only ask when a Photos source is actually added.
- **Only the System Photo Library is reachable.** PhotoKit talks to whichever library Photos designates as the system one; there is no public way to open another. If the user switches system libraries, our stored asset identifiers stop resolving *en masse*, which is treated as the source becoming unavailable rather than as the photos being deleted.
- **File-backed sources come first, Apple Photos after the Mac app, Google Photos last.** Prove the deck, cache, and display pipeline against plain files where there is no permission flow and no network to fail before adding the provider that has both.

*Cache*

- **Reference in place on the internal volume; materialize from anywhere that can disappear.** A file on the boot volume is always there, so copying it is pure waste. A file on an external, removable, network, or iCloud Drive volume can vanish without notice, so it is copied into the cache. Whether a photo is referenced or materialized is a property of *where it lives*, not of which kind of source found it.
- **The queue asks each source for one picture at a time, until it is full.** One request yields one picture, bytes and all — there is no batch size and no separate prefetcher. A source runs a few of those at once (four by default, because fetching is nearly all latency) and ignores anything beyond its limit, which is the entire flow control. Serving is what notices the queue has run short and starts the asking again.
- **A photo is dealable if its bytes are local, whatever its source's state.** An unmounted drive removes referenced photos immediately; a vanished Photos library does not, since those were materialized into our cache. Orphans then shuffle out gradually as FIFO evicts them — the cache's ordinary behavior is the garbage collector.
- **The cache is clearable on demand, and guarded against a full disk.** `pgr_ctl cache clear`, optionally per source or restricted to unavailable ones, never touching deck history. Separately, free space is checked before every chunk, because a photo count cannot bound bytes.
- **Unavailable sources are shown as unavailable, in red, with the reason.** A source that has silently stopped contributing to the shuffle is indistinguishable from a bug.
- **The cache is capped by photo count, FIFO, default 1000.** Materialization follows deck order, so oldest-added is also longest-since-dealt — the cache is a sliding window over the deck, expiring off the front and filling at the back. Configurable; the shipping default gets set by measurement, not by guess.

*Display*

- **One display mode in v1: shrink or expand, preserving aspect ratio.** Aspect fit, applied identically by the wallpaper and the screensaver — `scaleProportionallyUpOrDown` with clipping off. It is a setting from the start with exactly one value, so adding fill, center, and tile later is a new case rather than a new concept.
- **Every surface has a defined empty state.** The screensaver bounces "No photos" around the screen; the wallpaper leaves the existing desktop alone; the widget shows a static label. Nothing anywhere renders a blank screen that could be mistaken for a crash.

*Sequencing*

- **Server, then a CLI to exercise it, then the Mac app that calls it, then iOS.** The headless library process is the foundation every surface sits on; the command line proves it correct before any UI exists, and a window showing the shuffle is the shortest proof the idea works. The kit's API is still shaped by iOS's constraints even though iOS arrives third, since retrofitting those is the expensive mistake.
- **`pgr_ctl` and the Mac app are permanent test harnesses, not scaffolding.** The command line covers anything scriptable, statistical, or concurrent; the app covers anything visual or timing-dependent. Every later surface is exercised through one of them before it gets its own home.
- **The Mac app is just a window that can go full screen.** No source management, no settings — `pgr_ctl` owns those. A full-screen window is visually what the screensaver will be, so the display behavior gets designed there and Phase 6 is left with only the sandbox to solve.
- **"Calls it" means the database and a Darwin notification, not a socket.** The server and the app share the SQLite store; the notification says "go look." This follows your own ranking of the options, and it means neither process has to be running for the other to work.

*Platform and distribution*

- **Mac ships Developer ID direct, the iOS family ships App Store.** Your call, and it is the right one — a sandboxed app cannot install a `.saver` bundle, so App Store distribution and a screensaver are mutually exclusive.
- **A LaunchAgent, not a LaunchDaemon.** Photos access is per-user TCC and requires a user session; a system daemon cannot reach the library at all.
- **Installs are fully independent — no cross-device sync at all, with one forced exception.** iCloud Photos already puts the same photos on every device, so each install shuffles the same pool on its own; this buys out of `PHCloudIdentifier` mapping, a CloudKit layer, and deal-time conflict resolution entirely. The Apple Watch is the exception, because watchOS has no Photos framework and no sources of its own — the paired iPhone feeds it, one-directionally.
- **Between our own components: the database is the transport, a Darwin notification is the doorbell.** No HTTP server, no sockets, no XPC. Darwin notifications carry no payload, which is exactly right — they signal "go look" and SQLite holds what there is to look at. Only the screensaver, trapped in someone else's sandbox, may need something else.
- **Minimum deployment target 27.0 on every platform, temporarily held at 26.0 until 27 ships.** The target is 27: no back-deployment guards, no availability checks, no legacy code paths. The hold exists only because this machine is on a 27 seed while the second Mac — the one that has to keep the agent running during a vacation — is on the current public release. 27 will have shipped by the time the server is done, so the hold lifts on its own. Nothing may be designed around it.

*Engineering*

- **The kit owns policy; the hosts own scheduling.** `PhotoGoRoundKit` contains no timers, no run loop, and no opinion about when it is called — the Mac agent drives it from a continuous loop, the iOS widget drives it from a timeline provider. The two backends differ enormously and the boundary is drawn so that difference lives entirely on the host side.
- **Structured logging through `OSLog`, and logs go nowhere.** No crash reporter, analytics, or telemetry — never popular enough to justify it, and addable later if that changes. Unified logging is also the only mechanism that works from inside the screensaver's and widget's sandboxes, where a hand-rolled file logger could not write at all.
- **Swift 6 strict concurrency, shared core as a Swift package.** Every target — agent, app, saver, widget — links the same package.
- **The name is "Photo-Go-Round", hyphenated, for now; the bundle identifier is `com.sydpolk.photogoround`.** The hyphens are user-facing only — display name, Application Support directory. Every bundle hangs off that identifier, Swift modules stay `PhotoGoRoundKit`, and the shared preferences and App Group domains derive from it.
- **The database holds state; `UserDefaults` holds preferences.** Sources, pool, queue, and cache are state. Fits, timings, transitions, and caps are preferences, living in the App Group suite so they are settable from the command line.
- **Raw `defaults write` is noticed, and no preference ever needs the agent restarted.** Cross-process `UserDefaults` observation is unreliable, so the server watches the backing plist's *directory* and re-reads; every preference then has an explicit apply action, timers included.

# Background

The repository is empty apart from a BSD 3-Clause license and an Xcode `.gitignore`. Toolchain on this machine is macOS 27.0, Xcode 27.0, Swift 6.4. This machine runs a 27 seed; 27 has not shipped publicly yet. Minimum deployment target is 27.0 across macOS, iOS, iPadOS, tvOS, and visionOS, held at 26.0 until it does, so the server can run in the meantime on a second Mac on the current public release. No prior implementation exists, so nothing here is constrained by an existing codebase — only by platform rules.

This problem has been pursued for a very long time: a friend's "Desktop Picture" extension on classic Mac OS in 1992, then Mac OS X's built-in wallpaper and screensaver from 2001, from inside Apple. Across three decades and many releases the quality has moved up and down without the core failure ever being fixed — nothing has been able to take a large, unstructured collection of photos and simply do the right thing with it. Every design decision below should be read against that: the thing being built is the part that has been missing the whole time.

The current workaround Syd lives with, and what it demonstrates: selecting a Photos album in Apple's screensaver is unusable past a couple of dozen photos, so he exports to a bespoke folder on disk instead — which the selection UI can barely ingest even once. Adding files to that folder afterwards works fine. *Re-opening the folder selection* does not: the screensaver goes belly up, and recovery means pointing it at a new folder holding only a few photos, letting it settle, then moving thousands of photos in behind it. Once running, the display itself is flawless. The wallpaper picker fails the same way, and additionally reverts to the stock Golden Gate image at random for a while before deciding to work again.

Three things follow. The broken component is selection, not rendering. Enumeration evidently happens once at selection time and is cached, which is why adding files works and re-selecting does not. And wallpaper cannot be treated as something you set — it has to be something you reassert.

Syd built a screensaver from Xcode's built-in template about two years ago. That template emits Objective-C; he has not written Objective-C in nine years and does not intend to. Nothing in this plan requires it — see below.

# Detailed discussions

## The 27.0 baseline, and the temporary 26.0 hold

Targeting 27.0 everywhere removes a whole category of work. `SMAppService`, Swift 6 strict concurrency, `ScreenCaptureKit`-era display APIs, and the modern WidgetKit and SwiftUI surfaces are all simply present; there are no `@available` ladders and no fallback implementations to write or test. Since this is software for you rather than for a market, there is no user base stranded on an older OS to weigh against that.

**The target is held at 26.0 until 27 ships, and the hold expires by itself.** This machine is on a 27 seed; the second Mac — the one that has to keep the agent running while nobody is at a desk — is on the current public release, because that is the only release there is. Building against a seed would mean the server could only run on the machine it was written on, which is precisely the wrong property for a background service. 27 will have shipped well before the server is finished, at which point the target goes to 27 and stays there.

Because the hold is temporary and self-expiring, the important thing is that **nothing may be designed around it.** No availability check, no fallback path, no "the 26 way of doing this" — if a 27-only API is ever the right answer, lift the hold early rather than write a guard that then has to be hunted down and deleted. Lifting it is a one-line change to `Package.swift` precisely because there is nothing to unwind.

So far the hold costs nothing at all: the kit builds and its whole test suite passes against 26 without a single availability check, because everything this project actually uses is far older than either release — `libsqlite3`, `OSLog` and `OSSignposter`, `Duration`, `SMAppService` (13), `NSWorkspace.setDesktopImageURL`, `PHAssetResourceManager`, WidgetKit. The phases where a 27-only API might first be tempting are the Photos provider in Phase 3 and the saver in Phase 6, and the hold will almost certainly have lifted by then.

There is a second reason the hold is comfortable rather than merely tolerable. Phases 1 and 2 are a library and a command-line tool: no windows, no sandboxes, no OS integration points beyond SQLite and the filesystem. That is the part of the project least likely to want anything new from the OS, which is a good match for the only period during which the constraint applies.

One honest caveat: my knowledge runs to roughly mid-2026, and 27.0 shipped after that. Where this plan asserts platform behavior, those assertions describe the 26-and-earlier world. Any of them could have changed. That is why each phase carries its own spike, and I will verify against the installed SDK and current documentation rather than against memory before any of the later surfaces are designed in detail.

## Why SQLite rather than Core Data

You asked whether SQLite is "already embedded in the phone." It is. `libsqlite3.tbd` is part of the SDK on macOS, iOS, tvOS, watchOS, and visionOS, and has been for the entire lifetime of those platforms. There is no binary to vendor and no size cost. The 2014-era hesitation no longer applies.

The stronger argument is multi-process access. On the Mac this system has at least three processes touching the library at once: the agent writing deck state, the screensaver reading the next N photos, and the config app editing sources. Core Data's SQLite store is documented as unsafe for concurrent access from multiple processes — there is no cross-process coordination of its row cache or its change notifications, and the failure mode is silent corruption rather than an error. SQLite in WAL mode is explicitly designed for this: multiple readers concurrent with one writer, coordinated by the OS.

The third argument is that the deck *is* a query — a filter on the repeat window, ordered by a random key. Expressing that through `NSFetchRequest` gains nothing and costs the ability to write the one UPDATE that advances the deck atomically.

## No third-party dependencies, and what that means we write

The project takes no external packages. Everything is the system SDK plus code in this repository, and the only dependencies that reach outside that are the photo libraries themselves.

Worth stating precisely, because the boundary is unusually clean: PhotoKit is an Apple framework, so the Apple Photos provider is not an external dependency in any meaningful sense — it is OS surface, like AppKit or SQLite. That leaves the **Google Photos web API as the single genuine external dependency in the whole project**, and it is one optional provider arriving in the final phase. Everything before it depends on nothing but the operating system.

Two consequences follow from that being true. First, the project must remain entirely functional with Google Photos absent, failing, rate-limited, or removed — it is a source, not infrastructure, and nothing structural may come to depend on it. Second, a supply-chain review before any release is a matter of reading `Package.swift` and finding it empty, rather than auditing a tree.

This is a constraint worth stating as a principle rather than rediscovering per-decision, because it has consequences in at least three places.

**The database layer.** We call `sqlite3_*` directly from Swift, importing the system `SQLite3` module — no `Package.swift` dependency, no vendored source. The plumbing this obliges us to write is well-understood and finite:

- *A connection wrapper.* Open with `SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX`, set `PRAGMA journal_mode = WAL` once at creation, `PRAGMA foreign_keys = ON` and `PRAGMA busy_timeout` on every connection. Perhaps 150 lines.
- *A statement wrapper.* Prepare, bind, step, finalize, with a small typed binding surface so call sites are not writing `sqlite3_bind_int64(stmt, 3, …)` by hand and miscounting indices. Cache prepared statements for the hot queries — the deal, the hand reservation — since those run constantly. Another 150 lines or so.
- *A migrator.* A `user_version` pragma, an ordered array of migration closures, and a loop that applies the ones above the current version inside a transaction. About 40 lines, with tests from the first commit: apply from empty, apply from every intermediate version, and assert the resulting schema matches a freshly-created one.

  Worth knowing what this is *for*, though, given the database is disposable: it exists so that an update does not silently discard a library that took an hour to fetch, not because the data is precious. Before 1.0 the schema is edited in place and the answer to a mismatch is to delete the file. After 1.0 a migration is a courtesy that saves a re-download, and "delete and rescan" remains the fallback for anything a migration gets wrong.
- *Busy handling.* WAL permits one writer, so `SQLITE_BUSY` is a normal outcome under contention rather than an error. `sqlite3_busy_timeout` handles most of it; the deal and reservation paths additionally retry with backoff, because those are the statements two processes actually race on.

There is no in-process change observation to write, because we do not want it. An ORM's observation layer only sees its own process's writes, which in a design with an agent, a screensaver, and a widget all touching the same file would be actively misleading. Darwin notifications are the mechanism, and they were going to be regardless.

**Google Photos, whenever it lands.** The conventional integration pulls in the GoogleSignIn SDK. Without it, the OAuth flow is `ASWebAuthenticationSession` driving the authorization endpoint directly, a token exchange over `URLSession`, refresh tokens in the Keychain, and hand-written `Codable` structs for the Library API's JSON. This is more work than dropping in the SDK, but it is ordinary work — a few hundred lines of well-trodden OAuth — and it avoids taking a dependency on a large framework for one provider.

**Testing.** Swift Testing ships with the toolchain, so the test story needs nothing external either.

The cost of all this is real: a few hundred lines that a package would have provided, plus the obligation to maintain them. The benefit is that the entire shipping surface is code in this repository, there is no supply chain to audit before a Developer ID release or an App Store submission, and nothing can break because an upstream maintainer changed a minimum deployment target.

## The source model

A source is a row in a `source` table, never a setting. That distinction is the whole reason the system can grow a Google Photos provider at the end without touching the deck.

```sql
CREATE TABLE source (
  id          INTEGER PRIMARY KEY,
  kind        TEXT NOT NULL,     -- 'folder' | 'file' | 'photos_collection' | 'photos_asset' | 'google_album'
  locator     TEXT NOT NULL,     -- path, bookmark, PHAssetCollection id, PHAsset id, Google album id
  stamp_uuid  TEXT,              -- file/folder sources only: matches the com.apple.metadata: xattr
  enabled     INTEGER NOT NULL DEFAULT 1,
  recursive   INTEGER,           -- folder only
  added_at    INTEGER NOT NULL,
  scanned_at  INTEGER
);
```

The deck is the union of every enabled source, and every provider answers the same two questions: *what identifiers are in you right now*, and *give me the bytes for this identifier*. Enumeration and materialization, nothing more. A provider knows nothing about the deck, the cache budget, or the display side.

Four consequences worth stating:

- **Mixed kinds coexist without special cases.** Two folders, forty individually pinned photos, your Favorites smart album, and later a Google album are twelve or a hundred rows in one table. Nothing anywhere branches on "which kind of library is this."
- **Individually selected photos are a source kind, not a folder with one entry.** `kind = 'file'` for a loose image on disk, `kind = 'photos_asset'` for one pinned asset in the Photos library. They enumerate to exactly one identifier. Modelling them as degenerate folders would have meant every folder-scan code path carrying a "but what if it is really just one file" branch, and it would have made "pin this specific photo from my library" impossible to express at all, since that photo has no path.
- **Disabling is not deleting.** `enabled = 0` drops a source's photos from the deck without discarding their deal history, so re-enabling a folder resumes where it left off rather than restarting its shuffle.
- **Duplicates across sources are accepted in v1.** The same photo reachable from a folder and from a Photos album is two rows and gets dealt twice. The unique constraint is `(source_id, external_id)`, which permits this by construction; adding a nullable `content_hash` column later is a one-line `ALTER TABLE`, so declining to solve identity now forecloses nothing.

**Recursion is a property of the folder, and it defaults off.** `recursive` is a column on the source row for the same reason `enabled` is: one wallpaper directory is flat and the album tree beside it is fifteen levels deep, and a run that could only pick one answer for both would force a person to add them in two commands or accept the wrong depth for one of them. Off by default because the surprising direction is the expensive one — walking a home directory by accident costs minutes and finds thousands of photos nobody meant to add, while missing a subdirectory costs one flag.

Both interfaces mirror the column. `--add-folder` takes a folder as it finds it and `--add-folder-recursive` walks it; `PGR_FOLDERS` and `PGR_FOLDERS_RECURSIVE` are the environment forms, independent lists that may both be set. The older `-r` still applies to every plain `--add-folder`, because "all of them, recursively" stays the common case and nothing that worked should stop working.

Scanning is incremental. Each source records `scanned_at`; a folder rescan diffs the directory against existing rows and inserts new photos with a null `last_dealt_seq`, which makes them immediately eligible without needing to be placed anywhere special.

## No videos until 2.0

Videos are out of scope. The important thing is that they are excluded *deliberately* — a filter with a name — rather than by simply not writing any video code, because the difference determines whether 2.0 is a feature or an excavation.

**Filtering, per provider.** For folder sources, filter on uniform type identifier conformance rather than an extension allowlist: `UTType(filenameExtension:)?.conforms(to: .image)`. That excludes `.mov` and `.mp4` without enumerating video formats, and it correctly *includes* image formats nobody remembered to list — HEIC, AVIF, JPEG XL, and the whole `.rawImage` family. For Photos sources, `PHFetchOptions.predicate` on `mediaType == PHAssetMediaType.image.rawValue` does it at the fetch, so videos never enter the row set at all.

**Live Photos are photos, and are included.** A Live Photo is `mediaType == .image` with `.photoLive` in its subtypes — a still with a movie attached. It passes the filter, which is right; it should display as its still. The one thing to get right is materialization: `PHAssetResource` for a Live Photo yields both a photo resource and a `.pairedVideo`, and we take only `.photo` or `.fullSizePhoto`. Taking the wrong one means a video file in a cache that has no idea how to display it.

**Animated stills are first frames, permanently.** Animated GIFs and animated HEIC conform to `.image`, so they pass the filter and land in the library. They display as their first frame and never animate — not as a v1 simplification to be revisited, but as a settled non-goal, unlike video. Nobody adds an animated GIF to a photo library so that a wallpaper can loop it.

Pleasingly, this costs nothing to implement and something to *un*-implement. `CGImageSourceCreateThumbnailAtIndex(source, 0, …)` — the subsampled decode this plan already relies on — takes the frame at index 0, so the first frame is what falls out of writing no special code at all. The decision's real value is that a later phase never reaches for `CGAnimateImageAtURLWithBlock` trying to be helpful, which would put a frame animation and the screensaver's pan on the same layer, fighting over it.

**What the `media_type` column buys.** Storing the type on every row from the first migration means the exclusion lives in a query predicate, not in the scanner. Turning videos on in 2.0 becomes a change to what the deck selects rather than a re-enumeration of every source the user has ever added.

**Why 2.0 is genuinely harder, and why the column alone is not the whole answer.** Video is not a photo with extra bytes; it breaks assumptions the current design leans on:

- **Duration versus dwell.** A ten-second screensaver dwell and a three-minute clip disagree. Either the video is truncated, or the dwell becomes per-photo, which changes how hands are sized and how the shared deck paces.
- **Not every surface can show one.** The wallpaper API takes a still image URL. A widget cannot animate. So video is a per-surface capability, which means the `consumer` table gains a capability mask and the deal query starts filtering by what the asking consumer can actually display — the first thing in this design that would make consumers pull from genuinely different subsets of the shared deck.
- **Audio needs a policy,** almost certainly "always muted," and a screensaver that unexpectedly makes noise is a bug people remember.
- **The cache cap stops making sense as a count.** A thousand videos is not a number of gigabytes anyone can predict, which is the point at which the byte ceiling stops being a safety valve and becomes the primary control.

None of that is v1 work. It is recorded here so that the two cheap things — the `media_type` column and the habit of writing per-surface capability as a concept rather than an assumption — happen now, while they cost nothing.

## Photos that disappear

**A photo removed from its source is removed from the pool.** The row is deleted. Its queue entries cascade away with it, and the bytes we were holding are deleted in the same operation.

This used to be a soft delete — `available = 0`, row retained — to keep the deal history, to keep a row for rename tracking to match against, and to survive an unplugged drive. Only the third of those turned out to matter, and it is handled somewhere else entirely.

**To the user these are transient images, and the design can treat them that way.** A photo's individual history is not worth a flag column, a second lifecycle, and a permanent ambiguity about what a row means. "Shown 40 times" is a statistic nobody acts on. Rename recovery is a nice-to-have built on stamps and Spotlight, not on retained rows. What is left is one rule with no exceptions: *removed means removed*, and a file that comes back is a new entry that competes immediately rather than resuming a place in a rotation it was absent from.

**The unplugged drive is handled by never getting there.** A source that loses *everything* at once is marked unavailable and its entries are not touched at all — see *the whole-source rule* below. So the delete path only ever runs for individual photos missing from a source that is demonstrably present, which is the only case where "removed" is unambiguous.

### Never showing a photo the user deleted

This is a requirement rather than a nicety, and it is the reason the display path does more work than it looks like it should.

> A user sees a picture they do not want in the rotation, so they delete it from the source. They must never see it again.

Some reasons a person deletes a photo are benign. Some are not, and those are the ones this exists for — the cost of being wrong is not a stale cache, it is showing somebody a picture they specifically acted to remove.

A periodic refresh cannot promise this on its own, because "eventually" is up to a scan interval. Worse, a *materialized* photo is our own copy: deleting the original does not touch our bytes, so a residency check would sail straight past it and display the photo happily.

**So every card is checked against its source immediately before it is displayed**, including ones we hold a copy of. Providers answer a three-valued question, and the third value is the whole point:

| answer | meaning | what happens |
| --- | --- | --- |
| `present` | still there | shown, from wherever its bytes are |
| `absent` | gone from a source that is *right there* | removed from the pool; our copy deleted with it |
| `unknown` | source unreachable — says nothing about the photo | cached bytes play; an undock costs nothing |

`absent` and `unknown` are one `stat` apart and conflating them is catastrophic in both directions. Treat `unknown` as `absent` and undocking a drive empties the library. Treat `absent` as `unknown` and the photo gets shown, which is the failure this section exists to prevent. When a provider is unsure which it is holding, the honest answer is `unknown` — but it must not reach for `unknown` merely because answering properly would be slow.

**Take the time to be right.** The display path has a generous latency budget: nobody perceives variation in how long a picture takes to change, so a network round trip is an acceptable price for a correct answer.

### Watching, and why it comes back for 1.0

Detection is by rescan for 0.1, and rescanning is genuinely cheap — measured against a twenty-thousand-photo folder rather than assumed:

- A full rescan with nothing changed takes about **2.4 seconds** for twenty thousand photos, call it six at fifty thousand. On a five-minute interval that is a two percent duty cycle.
- It is **invisible to a consumer dealing at the same time**. Dealing alone measured a median of 0.1 ms and a worst case of 19 ms; dealing while a full scan ran in another process measured a median of 0.1 ms and a worst case of 13.7 ms.

That second number is structural rather than lucky. Almost all of the 2.4 seconds is filesystem enumeration with no database lock held at all; writes are batched at about five hundred rows per transaction, each lasting microseconds; and WAL means a reader never blocks on a writer. The queue and the cache genuinely do run independently of refresh.

**`FSEventStream` on folder sources is nonetheless a 1.0 requirement**, and the reason is the deletion rule above rather than latency.

The play-time check fully covers every surface that renders *on demand* — the wallpaper, the screensaver, the Mac app. Each asks for a photo at the moment it needs one, so there is a moment at which to check.

It covers nothing that renders *ahead of time and cannot be retracted*. A WidgetKit timeline provider generates entries in advance; the Watch receives derivatives that then sit on the device. There is no play moment there to intercept, so a deletion cannot be caught on the way out — it has to arrive. That means watching: `FSEventStream` for folder sources, `PHPhotoLibraryChangeObserver` for Photos.

So the sequencing is: polling alone through 0.1, and watching before the widget in Phase 5 and the Watch in Phase 9 ship. Which is a good illustration of why this document expects to be rewritten — the argument that deleted watching was sound on its own terms, and a requirement arriving from a completely different direction reinstated it.

### Tracking selected photos and folders through renames and moves — later

Individually selected photos and folder sources are identified by path today, which means renaming a folder or moving a file breaks the reference and the photo disappears.

**Scope: only what the user explicitly added.** Stamps go on the folders and individual files the user chose as sources — nothing else. Not the thousands of photos discovered by scanning inside a folder, not anything in the Photos library, not anything in our own caches. That is a handful of extended attributes rather than tens of thousands, it means we never write to a photo the user did not personally hand us, and it makes the whole mechanism `source`-level rather than `photo`-level.

**Which is why folder-sourced photos are stored folder-relative.** A photo found inside a folder source records its path *relative to* `source.locator`, not as an absolute path. Recover the folder and every photo inside it is recovered with it, in one update to one row — no per-photo repair, no Spotlight query per file, and correct even for a folder holding fifty thousand images. This is the design decision that makes the narrow scope sufficient rather than merely cheap.

**The technique, plus one refinement.** It comes from a file-syncing client Syd worked on, where users could add arbitrary files and folders to a sync set — the same problem shape as this one, and a strictly harder version of it, since a sync client that loses track of a file can destroy the user's data rather than merely dropping a photo out of a shuffle. It took a couple of weeks to arrive at. Recording it properly here so that time is spent once.

Stamp the source with an identity, then let Spotlight find it again:

1. On adding a folder or file source, generate a UUID and read its inode. Write both into an extended attribute on it — the UUID is what we will search for, the inode is what will tell original from copy.
2. Record the same UUID in the `source` row alongside the locator.
3. When the file is later found missing from its recorded path, run a Spotlight query for that UUID. An index lookup, so it is fast even across a large volume, and exact.
4. Iterate the results and compare each candidate's *current* inode against the inode stored in its stamp. Exactly one will match: the original.
5. Update the stored path and filename to the recovered location.
6. Strip the stamp from the non-matching candidates, since those are copies and their stamps are now lies.

The elegance is in step 4. A copy inherits the extended attribute but gets a fresh inode, so a copy is self-identifying — its stamp no longer describes it. A move preserves the inode, so the original keeps matching wherever it goes. One comparison separates the file we care about from any number of duplicates, without hashing content or comparing bytes.

The UUID is the refinement, and it is doing a different job from the inode rather than replacing it. Searching on the inode alone would work most of the time, but inode numbers are unique only within a volume and are reused after deletion, so the query could surface an unrelated file carrying a stale stamp with that number. A UUID makes the search exact and collision-free; the inode then does what only it can do. The cost is a few extra bytes in the xattr.

**Implementation detail that makes or breaks it:** ordinary extended attributes are not indexed. Spotlight imports xattrs whose names carry the `com.apple.metadata:` prefix and exposes them as queryable metadata attributes; the stamp must be written under that prefix, and queried through `NSMetadataQuery` or `mdfind`, or step 3 finds nothing.

**What this deliberately does not try to recover.** The contract is narrow on purpose: *the user renames or moves a folder, and we cope.* Everything else they do to the files inside is theirs to own.

So a photo renamed within its folder, moved into a subfolder, or moved between two folders that are both sources is not recognized as the same photo. It disappears from where it was and — if it landed somewhere we still watch — reappears as a new row, immediately eligible. Its deal history does not follow it.

That is a real loss and it is the right trade. Recognizing it would require per-photo stamps, which means writing extended attributes to every file in every folder the user ever added — exactly the thing the narrow scope exists to avoid. The failure mode is also benign: the photo is still in the deck, still shown, just treated as newly arrived. Nothing breaks, nothing vanishes permanently, and nobody has to reason about identity across a reorganization we were never asked to survive.

**Known limits**, the first two of which you already named:

- Same volume only. A cross-volume move is a copy-and-delete: new inode, and the original is genuinely gone.
- The volume must be Spotlight-indexed. External drives frequently are not, and network volumes usually are not.
- Some transfer paths strip extended attributes — `rsync` without `-X`, and copies onto filesystems that cannot carry them, such as exFAT.
- It writes to files we do not own — which is why the scope above is narrow. Only items the user explicitly handed us are ever stamped.
- macOS only. iOS has neither arbitrary-file Spotlight search nor xattr access outside the container, so bookmarks remain the mechanism there.
- Hard links produce multiple genuine matches sharing one inode. Any of them is correct; pick the first and do not treat the multiplicity as an error.

For completeness, the mechanisms available on Apple platforms are bookmark data (`URL.bookmarkData()`, which resolves through moves and renames and is the Apple-sanctioned answer), file reference URLs, and raw inode plus volume UUID. All three share a limitation worth knowing before choosing: they track a file within a volume, and none survives a copy-delete across volumes, which is what many applications do when they "move" a file. Whatever the approach, it wants to be a nullable column added to `photo` and `source` alongside the path rather than a replacement for it, so a stale identity falls back to path matching rather than failing outright.

**Does FSEvents make this unnecessary?** It did not, and it is no longer in the plan at all — but the reasoning is worth keeping, because it is what showed the durable identity was load-bearing rather than a nicety.

FSEvents would have given live rename and move events within a watched tree, attributable by file ID, plus the ability to catch up across downtime from a stored event ID. What it never gave, and these are exactly the cases that matter here:

- **A folder moved out of the watched tree.** Rename the source folder itself and `kFSEventStreamEventFlagRootChanged` says the root moved, not where it went. Finding it again means resolving by file ID or bookmark — precisely the mechanism FSEvents was supposed to replace.
- **Downtime beyond log retention.** The event log is finite and can be discarded; a long enough gap, or a volume remounted elsewhere, and history is simply unavailable.
- **Cross-volume moves.** Copy-and-delete produces no rename event and a new inode. Nothing tracks that, by any mechanism.
- **iOS.** There is no FSEvents. Bookmarks are the only option there, so the durable identity is required regardless of what the Mac can do.

Every case FSEvents *could* have covered is one this design had already declined to solve — a photo moved inside a folder loses its history by choice, because per-photo stamps are the cost the narrow scope exists to avoid. So watching was buying attributable renames for files whose renames we do not track, and buying latency on a rescan that turns out to be free. **The durable identity is now the only path, rather than the recovery path behind a fast one**, which is a simplification rather than a loss: one answer to "where did this go" instead of two that have to agree.

## Sources live in preferences, not in the database

The `source` table is a copy. The list of what the user actually chose lives in `UserDefaults`, alongside every other preference.

This falls out of two decisions that were already made, and noticing that they collided is what forced it:

- **The database is disposable.** Deleting it and the cache is a legitimate recovery for any problem, costing one rescan.
- **Only preferences are durable**, because they are the one thing that cannot be reconstructed.

A source list in the database alone breaks both at once. Deleting the database would silently discard the folders someone chose, which turns "delete it and rescan" from a free recovery into a destructive one — and nothing about a path the user typed is derivable from anything else.

**So sources are a preference, and the table is a projection of it.** On launch the agent reconciles: anything in preferences that has no row gets one, anything in the table that is no longer a preference goes. A fresh database rebuilds the source list from preferences and rescans, and the user notices only that it took a moment.

**Configuration at launch writes through.** `--add-folder` and `PGR_FOLDERS` name sources; if they name one that is not yet a preference, it becomes one. So the first run is configured from the outside and every run after that is configured from preferences, without the launcher having to know which case it is in. A launcher that keeps passing the same folders is not doing anything wrong — it is asserting a state that is already true.

**What stays in the database** is everything derived from a source rather than chosen by a person: the photos found inside it, when it was last refreshed, and whether it is currently reachable. None of that survives a delete, and none of it needs to.

### The doorbell rings back at you

The agent posts `.sourcesChanged` so other processes know something moved, and it also *observes* that topic so a terminal adding a source is picked up within a tick. Darwin notifications carry no sender, so those are the same notification and there is no way to tell one from the other.

Left alone that is a cycle: a refresh that finds a change announces it, the announcement schedules a refresh, and around it goes. It surfaced twice. A source that was merely *still* unavailable counted as news, so a missing folder drove the loop at the tick rate for ever — the visible symptom being the same alert printed every few seconds. And a folder being copied into changes truthfully on every pass, so even with that fixed the agent walked the directory continuously for as long as the copy ran.

Two rules settle it. **Announce transitions, not states** — a source that is unavailable now and was unavailable before is not news. And **after any refresh, drop a pending ring**, since the work it would ask for has just been done. A terminal that rang mid-refresh loses its promptness and waits for the next scheduled scan, which is much the cheaper of the two mistakes.

The general form is worth keeping: *a component that both posts and observes a payload-free notification must make its own announcements idempotent, because it cannot recognise them.*

### This is also the control channel

Putting the source list in preferences makes `defaults write` a way to reconfigure a running service, with no cooperation from anything:

```
defaults write <domain> sources -array-add '{kind = folder; locator = "/Users/me/Pictures/Sunsets"; recursive = 1; enabled = 1;}'
```

The agent re-reads preferences on a thirty-second poll — the doorbell only makes it prompt — reconciles the table against the new list, and starts refreshing. Nothing had to be running for the write to work, and nothing had to be restarted for it to take.

That is worth stating plainly because of what it means for `pgr_ctl`: **the command-line tool is a convenience, not a requirement.** It knows the right domain and the right key names, and it rings the doorbell so the change is instant rather than within thirty seconds. But the service is controllable without it, which is the property that keeps the service's one job genuinely one job — it is configured by state it reads, not commanded through an interface it has to expose.

## The pool, the queue, and the refreshers

Three moving parts, and the point of naming them separately is that none of them knows how the others work.

**The pool is every photo the system knows about**, from every source. It has an API — put entries in, take entries out — and that API is the only way anything reaches it.

**The refreshers put things in and take things out.** One task per source, running concurrently, each against its own database connection. A source is enumerated, diffed against what the pool holds for it, and the difference applied. A refresher touches the queue never, and knows about other sources not at all.

**The queue maintainer always runs.** It pulls from the pool whenever the queue runs short, fetches the bytes, and serves the head to whoever asks. It does not know what a provider is. It does not know a refresh is happening.

That separation is what makes the concurrency safe to have. A folder on a dead network share takes its timeout inside its own task; a provider that hangs hangs alone; and the queue goes on dealing throughout, because a refresh is a series of short write transactions against a database that permits readers continuously. It is also why the earlier measurement holds: the queue's latency was unchanged with a full twenty-thousand-photo scan running beside it.

**Concurrency is scheduling, so it belongs to the host.** The kit exposes "refresh this one source" and has no opinion about how many run at once; the Mac agent runs a task group with a cap, and an iOS host with a few hundred milliseconds of background time can run exactly one. That is the same seam that keeps timers out of the kit.

### What a client asks for, and what it gets back

Consumers do not block on any of this. The exchange is:

1. The client posts *it is time for a picture*, and forgets about it.
2. The service takes however long it needs — selecting, fetching bytes, and checking the picture is still in its source.
3. The service posts either *a picture is ready* or *there are no photos available*.
4. On the first, the client reads the card and loads the image. On the second, it shows its empty state.

The database is the transport and the notification is the doorbell, exactly as everywhere else between our own components; this adds topics, not mechanism. What makes fire-and-forget the right shape rather than a compromise is the latency budget: nobody perceives variation in how long a picture takes to change, so the service is free to do a network round trip before answering, and the client never has to model "still working" as a state.

It also means **"no photos" is an ordinary reply rather than an error**. A fresh install has an empty queue and an empty cache, so the first few requests answer *nothing available* and photos begin arriving as downloads succeed. Every surface has a defined empty state already; this just gives it something to be triggered by.

## Rows versus bytes

The single most important thing to keep straight in this design is that there are two populations, and only one of them is bounded.

**Rows are complete and cheap.** Every photo in every enabled source gets a row in `photo` — identifier, source, shuffle key, deal ordinal, a few timestamps. Call it 200 bytes. A 50,000-photo Favorites album is a 10 MB table, and SQLite does not care. Enumeration is cheap on both providers: `PHFetchResult` is lazy and returns identifiers without touching pixels, and a directory walk is I/O-bound but trivial next to reading the files.

**Bytes are windowed and expensive.** The cache holds actual image files for a bounded number of photos — 1000 by default.

Keeping these separate is what makes the shuffle honest. If the database only held the 1000 photos that happen to be cached, the shuffle would be a shuffle of 1000 photos, and the other 49,000 would surface only through whatever refill policy pulled them in. With complete rows, the deck shuffles the entire library and the cache is purely a performance layer — a prediction about which photos are needed soon, wrong at worst, never a constraint on what can appear.

## The deck algorithm

The naive shuffle — one random column, re-rolled when consumed — repeats photos almost immediately, because a fresh random value can land right back at the front. The fix is to make recency a filter rather than trusting the ordering alone.

**In normal operation the deck is a circular queue that never runs dry.** A photo is eligible once *w* deals have gone by since it was last dealt, so at any moment exactly `N − w` of the library's `N` photos are available to choose from — a rotating window of candidates that refills itself as fast as it is consumed. Nothing ever ends; there is no boundary and no reshuffle.

That holds for every fraction below 1.0 on a library of any real size. The **pass** is the floor underneath it, for the two cases where the window has no answer: at fraction 1.0, where `w` is the whole pool by construction, and on a library small enough that `N − w` rounds to nothing. Then, and only then, the deck reshuffles and a new pass begins.

**So: a photo is eligible when *w* deals have gone by since it was dealt, or when it has not been dealt in the current pass.** That is the whole algorithm, and the second clause is the one that almost never fires.

```sql
CREATE TABLE photo (
  id             INTEGER PRIMARY KEY,
  source_id      INTEGER NOT NULL REFERENCES source(id),
  external_id    TEXT NOT NULL,      -- PHAsset localIdentifier, Google media item id, or
                                     -- for folder sources: path RELATIVE to source.locator
  media_type     TEXT NOT NULL,      -- 'image' in v1; 'video' exists but is never selected
  available      INTEGER NOT NULL DEFAULT 1,
  times_shown    INTEGER NOT NULL DEFAULT 0,
  last_dealt_seq INTEGER,            -- global deal ordinal; NULL means never dealt
  shuffle_key    REAL NOT NULL,      -- random, re-rolled on each deal
  last_shown_at  INTEGER,
  ...
);

CREATE TABLE deck_state (
  id             INTEGER PRIMARY KEY CHECK (id = 1),
  deal_seq       INTEGER NOT NULL DEFAULT 0,   -- advances on every card played
  pass_start_seq INTEGER NOT NULL DEFAULT 0    -- the ordinal the current pass began at
);

-- Selection orders by shuffle_key and takes a LIMIT, so the index leads with
-- the equality columns and *ends* at shuffle_key. Putting last_dealt_seq before
-- it would force a temp b-tree sort of half the library on every deal.
CREATE INDEX photo_deck ON photo(source_enabled, available, media_type, shuffle_key);
```

A single monotonic counter — the deal ordinal — advances on every card dealt anywhere in the system. The pass is one more integer beside it: a photo is unused in the current pass while `last_dealt_seq <= pass_start_seq`, and reshuffling means moving `pass_start_seq` up to the current ordinal, which makes every photo unused again. There is no per-photo epoch column and no pass-position column.

The two rules collapse into a single comparison, which is why there is no branch anywhere in the deal:

```
eligible  ⟺  last_dealt_seq IS NULL OR last_dealt_seq <= max(pass_start_seq, deal_seq - w)
```

Photos never dealt are eligible by definition, so a newly added photo joins the pass already in progress rather than waiting for the next one — no placement, no special case.

### The repeat window

*w* is derived from a configurable fraction of the eligible pool: `w = round(fraction × pool_size)`, with **0.5 as the starting default** — a photo can come back once about half the library has gone by, without waiting for the pass to finish.

At **fraction 1.0** the window is the whole pool and is therefore never satisfiable on its own, so the pass is the only rule: exactly one showing per pass, in a fresh random order every time through, which is the classic shuffle. At **0.5** or **0.33** photos recur sooner, which matters most on large libraries — with fifty thousand photos, fraction 1.0 means a picture you loved is effectively never coming back, and that is a strange thing for a system whose purpose is showing you your photos.

The two rules hand off cleanly rather than fighting, and the handoff is lopsided. The eligible set has exactly `N − w` members, so below 1.0 the window always has an answer on any library where `(1 − fraction) × N ≥ 1`: the deck never runs down to nothing, `pass_start_seq` never moves, and the minimum-gap guarantee is exactly *w*. At 1.0 the window contributes nothing and the pass does all the work. Nothing in between needs describing, because the `max()` picks whichever is looser at each deal.

The practical shape of that: at the default 0.5 with four thousand photos, two thousand cards are eligible at every single deal and the pass machinery is dead code that never executes. It earns its place only at the extremes — the slider pushed fully right, or a library of a handful of photos where `w` swallows the pool. Both are real, so the floor stays; neither is the common case, so the circular queue is what the code should read as.

The trade is fairness against liveliness, and it should be stated plainly. Fraction 1.0 gives exact fairness: every photo shown the same number of times, zero variance. Lower fractions equalize only in expectation — over any finite stretch some photos appear three times while others appear once. That variance *is* the feature being bought, and it is why the number is exposed rather than chosen for the user.

It lives in `UserDefaults` as `repeatWindowFraction`, settable by `pgr_ctl set` from day one and worth a slider in the settings GUI later, since it is the one parameter whose effect a person can actually feel.

### Why this removes machinery rather than adding it

An earlier version of this plan used an epoch counter — order by `(epoch, shuffle_key)`, bump the epoch on deal — with a per-photo epoch column, a pass-position column, a key-biasing scheme, and a separate time-based cooldown to patch the boundary. All of that is deleted. What survives is one integer, `pass_start_seq`, in a table that has one row.

**The boundary is accepted rather than patched, and that is the deliberate change.** A photo dealt as the last card of one pass can be dealt again as the first card of the next. The cooldown existed to prevent exactly that, and it is not worth its weight: this is a photo shuffle, not a casino, and someone who happens to be watching at the moment two passes meet — every few weeks, on a real library — sees a picture twice. The alternative costs a guard band, a relaxation path, and a paragraph of explanation, to buy nothing anybody asked for.

A pure sliding window with no pass would have no boundary at all, which is why an earlier draft of this section preferred one. It does not survive contact with fraction 1.0. A window of `pool` cards leaves exactly one photo eligible at every deal after the first pass, so the shuffle key never gets a say and every pass replays the first pass's order forever — exact fairness bought with a fixed rotation. Reshuffling at a pass boundary is what makes 1.0 an actual shuffle, and the boundary is the price.

**The degradation rule is unchanged and still essential: the deal must never fail.** But running out of eligible cards is no longer a failure to degrade around — it is the end of a pass, which is ordinary business, and the reshuffle is strictly more permissive than any window could be. So the progressive halving is gone with the rest of the epoch machinery. And there is nothing left below that: a source with nothing to offer simply offers nothing, the queue stays short, and a client asking gets *no photos available*. That is the whole degradation story now — fewer pictures, never an error.

`times_shown` survives purely as a statistic, for the deck inspector and for `pgr_ctl deck stats`. Nothing orders by it.

### Selecting at a random offset, not at the minimum

**Among the eligible, take a card at a uniformly random offset** in `shuffle_key` order. Not the first one.

This is worth stating explicitly because the obvious formulation — `ORDER BY shuffle_key LIMIT 1`, with the key re-rolled on deal — starves photos permanently, and does so silently. `LIMIT 1` on an ordering takes the *minimum*, and only the winner's key is re-rolled. A photo whose key lands high loses, keeps its high key precisely *because* it never won, and loses again. In simulation at fraction 0.5 over twenty thousand deals of a hundred photos, showings ranged from 3 to 391 and a photo with an initial key of 0.999 was never shown at all. Taking a random offset instead gives 186 to 217.

Fraction 1.0 hides the flaw, because a pass guarantees every photo a turn whatever its key — which is exactly why it is worth a paragraph rather than a footnote. The bug lives only in the range the deck actually ships in.

`shuffle_key` keeps both of its jobs. It supplies the index that makes selection cheap, and its re-roll on showing churns the order so consecutive requests to one source do not walk the same neighbourhood.

### Selecting and showing

Selection and showing are two statements rather than one, and the atomic guarantee sits in a third place entirely.

```sql
-- Pick a candidate from one source. :threshold is max(pass_start_seq, deal_seq - w),
-- and :offset is a uniform draw over the count of eligible pictures.
SELECT id, source_id, external_id, storage, cache_path
  FROM photo p
 WHERE p.source_id = :source
   AND p.source_enabled = 1
   AND p.available = 1
   AND p.media_type = 'image'
   AND (p.last_dealt_seq IS NULL OR p.last_dealt_seq <= :threshold)
   AND NOT EXISTS (SELECT 1 FROM queue q WHERE q.photo_id = p.id)
 ORDER BY p.shuffle_key
 LIMIT 1 OFFSET :offset;

-- …fetch its bytes, append it to the queue, and much later, when it is served:
BEGIN IMMEDIATE;
UPDATE photo
   SET times_shown = times_shown + 1, last_dealt_seq = :seq,
       shuffle_key = <new random>, last_shown_at = :now
 WHERE id = :id;
UPDATE deck_state SET deal_seq = :seq WHERE id = 1;
COMMIT;
```

**Marking shown happens when a picture is served, not when it is queued.** A picture prepared but never shown — because the user quit, or the source went away — costs the rotation nothing.

**The atomicity lives in the queue pop.** An earlier version of this plan fused selection and marking into one `UPDATE … RETURNING`, so that two processes racing were serialised by SQLite and the loser got the next card. That is no longer possible, because fetching bytes happens between the two halves. What replaced it is stronger where it matters and weaker where it does not:

- Two producers *can* pick the same picture. Appending ignores a photo already queued, so the cost is a duplicated download, never a duplicated showing.
- Two consumers *cannot* get the same picture. Serving removes the queue entry under `BEGIN IMMEDIATE`, so exactly one wins.

Counting the eligible pictures to draw the offset is a second statement. Against fifty thousand photos it is an index scan rather than a table scan, and it happens once per picture produced rather than once per photo.

**`source_enabled` is denormalized onto `photo`.** The pool is the union of every *enabled* source, and joining `source` on every selection would cost the index that makes the ordering free. It is maintained in the same transaction that enables or disables a source — one write against that source's rows, on an operation nobody performs in a loop.

## Consumers, and how a picture reaches one

There used to be an elaborate answer here: every display was a virtual consumer that reserved a *hand* — a private, contiguous block of cards taken from the shared deck in one atomic operation and played through locally. Hands carried a per-consumer size derived from the surface's interval, a reservation protocol, a distinction between a card being reserved and being played, and a reaper to reclaim cards from a display that went away mid-hand.

**All of it is gone, replaced by one global queue.** The queue is the reservation. Two displays get different pictures because serving *removes* the entry, not because they were dealt disjoint sets in advance — and that is a much better reason, because it cannot drift, cannot leak, and has no bookkeeping to reconcile.

```sql
CREATE TABLE consumer (
  id         INTEGER PRIMARY KEY,
  kind       TEXT NOT NULL,      -- 'wallpaper' | 'screensaver' | 'widget' | 'app' | 'cli'
  display_id TEXT,               -- stable display identifier, NULL for non-display consumers
  seen_at    INTEGER NOT NULL,   -- heartbeat
  created_at INTEGER NOT NULL
);
```

A registry and a heartbeat. That is the whole of it.

**What the hand design was actually buying, and where each of those went:**

- *It bounded cross-process write contention* — one reservation every sixteen minutes rather than a write every ten seconds. The queue does better: a consumer asking for a picture is one indexed `DELETE`, and producing one happens on the agent's own schedule rather than on the consumer's.
- *It gave the prefetcher a concrete work list* — the union of unplayed cards across outstanding hands. There is no prefetcher now. Producing a picture and fetching its bytes are the same operation, so nothing needs to be predicted.
- *It eased the screensaver's write access*, which was the original motivation: a saver reaching the canonical database every ten seconds is a hard thing to ask of code inside someone else's sandbox. This is the one that still matters, and it is now the Phase 6 spike's problem rather than something the deck design pre-solves. A saver that can serve from the queue is in the same position as any other consumer; one that cannot still needs the journal fallback.

**Displays still want stable identity**, and `CGDisplayCreateUUIDFromDisplayID` is still the right key — not for resuming a private rotation, which no longer exists, but so a monitor is one consumer across sleeps and cable swaps rather than accumulating rows.

## Consequences of one shared queue

Every surface draws from the same queue, so no photo appears on two of them at once and the repeat window applies across all of them together.

**Atomicity lives in the queue pop, not in the deal.** This moved, and it is worth being precise about because the guarantee is unchanged while the mechanism is not. Selecting a candidate and marking it shown are now two statements rather than one fused `UPDATE … RETURNING`, so two producers *can* briefly pick the same picture. Nothing breaks, because appending to the queue ignores a photo already queued and serving removes the entry under `BEGIN IMMEDIATE`. So the cost of a race is a duplicated download, not a duplicated showing.

Worth knowing where that leaves us: today only the agent produces, and a source ignores a request while it is still working on one, so the race cannot happen in practice. That is a property of the deployment rather than of the code. The moment a second process produces — `pgr_ctl`, or the Phase 3 app — duplicated downloads become possible, and the fix is to make selection-and-claim one statement again.

**A fast consumer no longer sets the pace for the cache.** Under hands, the screensaver's ten-second tick determined how deep the prefetch window had to be, and the cache cap had a hard floor at the sum of all hand sizes. Now the queue is filled at whatever rate providers can manage, drained at whatever rate consumers ask, and its size floats. A screensaver that outruns the producers gets *fewer photos*, which is the correct degradation and needs no capacity planning to arrive at.

It remains true that a long screensaver session can roll the entire library over, and that the wallpaper therefore sees a near-random sample rather than a slow walk. That is correct behaviour for a shared sequence, and worth knowing before it looks like a bug.

## Cache design

Two kinds of entry:

- **Referenced.** A file on the internal boot volume. The database stores its path; no bytes are copied. It does not count against the cache cap and eviction is a no-op.
- **Materialized.** Everything else, copied into `~/Library/Application Support/Photo-Go-Round/cache/`. These are what the cap governs.

**The dividing line is whether the bytes can go away, not which provider found them.** A Photos asset or a Google item is obviously materialized — there is no file to point at. But a plain file gets the same treatment whenever it lives somewhere that can disappear:

| Where the file lives | Treatment | Why |
| --- | --- | --- |
| Internal boot volume | Referenced | Always mounted. Copying is pure waste |
| External / removable / ejectable | Materialized | Drives get unplugged |
| Network volume | Materialized | Shares disconnect |
| iCloud Drive or another file provider | Materialized | The local copy can be evicted by the system without notice |

Determined at scan time from `URLResourceValues` — `volumeIsInternal`, `volumeIsRemovable`, `volumeIsEjectable`, `volumeIsLocal`, and `isUbiquitousItem` — and recorded per photo, since a single source could in principle span a mount point.

Two consequences worth stating. First, external-volume photos now consume cache budget, so a 40,000-photo drive is bounded by the cap like any other materialized source: unplugging it leaves the cached window playable, not the whole drive. That is honest and should be visible — "1,200 of 40,000 cached." Second, a same-volume file that the user deletes is genuinely gone, immediately, which is the intended contract rather than a shortcoming.

**Not `clonefile(2)`.** APFS cloning is same-volume only, so it cannot help the cross-volume case, which is the only case where we copy. On the same volume it would work and cost almost no storage — but a clone is an independent inode sharing extents, so deleting the original frees nothing while our clone lives. We would silently retain photos the user deliberately deleted, along with their disk space, in direct contradiction of "gone from the source means gone from the deck." It also requires APFS, so a reference path would be needed anyway.

### Cache layout

Nobody looks at the cache, so it is not designed to be read. The database is the index — nothing ever finds a photo by scanning the filesystem — and at a thousand-photo cap a flat directory would be perfectly fine for APFS. Meaningful filenames, date fanout, and preserved original names would all be effort spent on an audience of nobody.

One level of structure earns its place for mechanical reasons only:

```
cache/
  3/000000124.heic
  3/000000131.heic
  7/000000502.heic
```

Source id at the top, photo id below. `pgr cache clear --source 3` becomes one directory removal instead of a thousand unlinks, and per-source byte totals become a directory size instead of a query plus a stat loop. That is the whole justification; if those two operations did not exist, flat would be correct.

The cache directory is marked `isExcludedFromBackup`. Letting Time Machine copy tens of gigabytes of photos that are already in the Photos library or already in iCloud wastes the user's backup volume on data we can reconstruct.

### Decode on demand; do not store derivatives

The cache stores originals. Scaling is the display engine's job, done at decode time, and there is no on-disk tier of pre-scaled copies.

`CGImageSourceCreateThumbnailAtIndex` with `kCGImageSourceThumbnailMaxPixelSize` does not decode fully and then shrink — it decodes at a subsampled scale, so peak memory is bounded by the *output* size rather than by the source's pixel count. A 48-megapixel HEIC rendered for a 6K display costs about what a 6K image costs. Handing the result to a layer is all the display side needs.

An earlier draft of this plan justified stored derivatives by claiming a large decode would stutter the screensaver. That does not survive the queue: the next several pictures are known and already resident, so a decode happens on a background thread with enormous lead time. Even RAW, the slow case, has orders of magnitude more slack than it needs.

The stronger argument is the one against derivatives. In a shuffle deck each photo is displayed once, then not again for at least a window's worth of deals — hundreds or thousands of cards. A cached derivative therefore serves about one read before the deck moves on, and by the time that photo becomes eligible again the cache has likely evicted it. A cache with a one-to-one write-to-read ratio is not a cache; it is write amplification, plus a second artifact to keep consistent with the first, plus more bytes against the cap.

What the design does keep is a small **in-memory** decoded-image cache — the card being displayed and the next one or two, held as ready `CGImage`s. That is where the latency actually needs to be zero, it costs no disk, and it evicts itself when the process dies.

**Two exceptions, both narrow, and neither of them a "tier":**

- **Widget extensions.** A jetsam argument, not a speed one. A widget extension runs under a hard memory ceiling of roughly 30 MB, and decoder working memory for an arbitrary HEIC is not reliably bounded below it. The answer is not a cleverer decode inside the extension — it is that the server, which has no such ceiling, writes a small file sized to the widget family for the entries a widget is about to render. That is a handful of files, not a parallel copy of the library.
- **Devices that never store the original at all.** On the Watch and on tvOS, the small file is not derived from a local original — it is the only copy that ever arrives, produced by the feeding device before transfer. That is a storage and bandwidth decision about what to *send*, and calling it a derivative tier conflated it with a decode-cost decision it has nothing to do with.

**When a derivative is unavoidable it is fleeting, and if it must persist it is a separate cache.** Three levels, in order of preference:

1. *In memory, at display time.* The decoded `CGImage` for the current and next card. Dies with the process, costs no disk, needs no consistency story.
2. *A separate on-disk derivative cache,* only where a consumer genuinely cannot decode for itself — the widget case. Kept in `~/Library/Caches/`, not in Application Support, and this distinction is the whole point: the system may purge `Caches` whenever it likes, which is *correct* for derivatives, because regenerating one from a local original is cheap. Originals live in Application Support because losing them means re-downloading from iCloud, which is not.
3. *Never a second copy inside the library cache.* Derivatives do not count against the photo-count cap, are not tracked in the deck, and can be deleted wholesale at any moment without the library noticing. Any code path that treats a missing derivative as an error rather than as a cue to regenerate has got the relationship backwards.

**One measurement would close the remaining doubt,** and it belongs in Phase 2 as a `pgr_ctl` subcommand: subsampled decode time to display size for the worst files in a real library — a large ProRAW, a 48-megapixel HEIC, a stitched panorama — on this machine. If those land in the tens of milliseconds, as expected, the case for on-disk derivatives disappears entirely. If a panorama exceeds the GPU's maximum texture dimension, that is a separate problem needing tiling rather than a derivative file.

### Filling: there is no prefetcher

There used to be one — chunks of ten, an elevated first burst, then background chunks walking a work list until the cap. All of it is gone, and what replaced it is one sentence: **producing a picture and fetching its bytes are the same operation.**

A source asked for a picture picks a candidate, fetches it, and appends it to the queue. Nothing is queued before it is ready, so there is no work list to walk, no chunk boundary to resume from, and no window of "reserved but not yet available" for anything to reason about.

What the chunking was buying, and where each part went:

- *Bounded peak memory* — now bounded by per-source concurrency, which is four by default. Four in-flight fetches, not ten.
- *Checkpoints to re-read configuration and notice a disabled source* — every request is its own checkpoint, because every request re-reads the source.
- *A clean stopping point for an iOS `BGProcessingTask`* — a task that runs out of time simply stops asking. Whatever arrived is queued and ready; nothing is half-done.
- *Not issuing fifty thousand concurrent requests* — the concurrency limit does this directly, rather than as a side effect of batch size.

**The cold-start burst is what the queue does anyway.** An empty queue is below nominal, so every source is asked immediately and keeps being asked until it fills. The first pictures arrive in whatever order the providers manage, and the first request from a client is answered *no photos available* until one lands. There is no separate warm-up path to write.

**Asking again is driven by answers, not by the clock**, and getting this wrong was worth the lesson. The first version fired one round of requests per source on each tick of the maintenance loop and then waited for the next tick — which meant the queue filled at *concurrency per source per interval*, observed live as four pictures every five seconds against a folder of eight thousand. A thousand-entry queue would have taken twenty minutes to fill from a local disk that can do it in three seconds. The rate of a pipeline is set by how fast you re-ask, not by how fast each answer arrives.

So each answer re-asks its own source, and the tick is only what gets it started. Filling then runs at whatever the providers can sustain, bounded by per-source concurrency and by nothing else.

**Overshoot is bounded and expected.** The queue's size is a target rather than a ceiling, and the requests already in flight when it crosses that target still land. The bound is *sources × concurrency* — eight for two folders at the default of four — so a nominal thousand settles somewhere under 1008. This is not the earlier "1000 plus one per provider": that was right when a provider had a single request outstanding, and asking for four concurrent fetches each is what widened it.

**When the library is smaller than the queue, a clock takes over.** A pool of two hundred photos against a thousand-entry target can never fill it, and "ask again on every answer" is exactly the wrong rule there — the queue already holds everything there is, every request comes back empty, and the agent spins a core forever discovering that. So when the dealable pool is smaller than the queue's target, the pump stops chasing its own answers and reverts to one round of asks per tick. Small libraries are the normal case for a folder of wallpapers, not an edge case.

**Adding a source is still two phases**, and that part was always right: enumerate identifiers and insert rows first — seconds even for a large album, batched about five hundred rows to a transaction — and only then start fetching bytes. Rows are cheap and complete; bytes are expensive and windowed.

### Eviction

FIFO by materialization time, capped at 1000 photos by default.

The reason plain FIFO is correct here rather than something cleverer is that pictures are fetched in the order the deck offers them, so the order they enter the cache is roughly the order they will be shown. Oldest-added is therefore also longest-since-shown, and evicting from the front is evicting the picture the deck is furthest from reaching again. The cache is a sliding window over the deck: expire off the front, fill at the back.

Two guards on top of it:

- **Never evict a picture that is in the queue.** Anything queued is about to be shown, so it stays regardless of age. This used to be phrased as a guess about the deal horizon; the queue answers it exactly.
- **A byte ceiling as a safety valve, secondary to the count cap.** A thousand photos is somewhere between 2 GB and 100 GB depending on whether they are phone JPEGs or ProRAW, so a count alone cannot bound disk use. The recommendation is a generous byte ceiling — 50 GB, say — that normally never triggers, purely so a library of enormous originals cannot fill the volume. Count remains the primary control; the ceiling only ever evicts early, never late.

### Choosing the shipping default

The 1000 default is explicitly a starting point to be replaced by measurement. The experiment belongs in Phase 2, as a shell loop over `pgr_ctl` against real sources, and it should record, for cache caps of roughly 250 / 500 / 1000 / 2000 / 4000:

- wall-clock time to fill the cache from cold, for a local folder and for an iCloud-optimized Photos album;
- bytes on disk at each cap, for a representative library rather than a synthetic one;
- steady-state agent memory and CPU while filling;
- how often a deal misses the cache during a long screensaver session, which is the number that actually matters — a cap is big enough when the fast consumer never outruns it.

The last measurement is the one that decides it. Everything else is a cost curve; that one is the quality bar.

### The iOS variant

The same policy with much smaller numbers and a different filling schedule. A phone should not carry 1000 originals, so iOS caps lower, and the queue is shorter to match. Filling happens in the foreground and in `BGProcessingTask` windows when charging — and because one request yields one finished picture, a task that runs out of time simply stops asking. Nothing is ever half-done, so there is no boundary to resume from.

## Cold start

**Warm start** — queue populated, pool present. Serving a picture is one indexed read and one delete. Sub-millisecond. Every launch after the first should be this.

**Cold start** — nothing in the pool, nothing queued, nothing cached. The agent enumerates each source's identifiers first (fast: a directory walk is I/O-bound but cheap, and `PHAsset.fetchAssets` is lazy) and inserts all rows, so the *pool* is complete within seconds even though no bytes have moved. Then every source is below the queue's nominal size, so every source is asked, and pictures become servable one at a time as fetches land.

**Until the first one lands, a client asking gets "no photos available".** That is an ordinary answer rather than an error state, and every surface has a defined empty state for it already — the screensaver bounces its label, the wallpaper leaves the desktop alone, a widget shows a static one. There is no separate warm-up path, no readiness signal to design, and no "not ready yet" flag for anything to check: an empty queue answers the question by itself.

## Photos is optional, and there is exactly one of it

Two constraints on the Apple Photos provider, both narrowing.

**The system is complete without Photos.** Someone who does not want their Photos library involved — or does not use Photos at all — gets a fully functional product from folders and individually selected files. That is not a degraded mode with features missing; it is the configuration Phases 1 through 3 are built and tested on before the provider exists.

The practical consequence is that authorization is requested lazily. `PHPhotoLibrary.requestAuthorization` is called when a Photos source is *added*, never at launch and never speculatively. A user who never adds one never sees the prompt, and the app never appears in that list in System Settings. If authorization is denied or later revoked, Photos sources go unavailable and everything else carries on — denial is a state to display, not an error to handle.

**There is one library, and it is the system one.** PhotoKit talks to whichever library Photos has designated as the System Photo Library. There is no public API to open an arbitrary `.photoslibrary` bundle, so multiple libraries are not supported — not as a deferred feature, but as a stated non-goal. A user with several libraries sees the system one; switching which is which is done in Photos, by them, and is not something we offer or track.

**Switching libraries is the failure mode to handle.** `PHAsset` local identifiers are library-scoped, so every stored identifier from library A fails to resolve against library B. The whole Photos source goes dark at once.

That must not be read as "the user deleted forty thousand photos." It is the same shape as an unmounted external drive, and it gets the same rule, generalized:

> **A source that loses *everything* at once has become unavailable; it has not had its contents deleted.**

So the scanner has a threshold: if a scan finds a source's entire population missing, it marks the *source* unavailable and leaves the photo rows and their deal history intact, rather than processing tens of thousands of individual disappearances. Reconnecting the drive, or switching the system library back, restores everything with its shuffle position intact. This one rule covers unmounted volumes, revoked Photos authorization, and library switches, which is a good sign it is the right rule.

What we owe the user is a clear explanation rather than cleverness: the source is shown as unavailable, with the reason, and adding the new library as a fresh source is a deliberate act they take if that is what they meant.

### What happens to a source that never comes back

Unavailability is a state, not an event, so a source that is gone forever needs no special handling — it decays on its own.

**A photo is dealable if its bytes are local, regardless of its source's state.** Because materialization is keyed to volume, this mostly resolves in the user's favour. An unplugged external drive, a disconnected share, a switched Photos library — all of those sources were materialized, so their cached photos keep being dealt from what we hold. Nothing blanks.

The exception is a same-volume file that is genuinely deleted. Those were referenced, so they *are* their bytes and they leave rotation at once. That is the correct behavior: deleting a photo should remove it, not start a countdown.

Then FIFO does the rest. As other photos are materialized, the orphaned ones age toward the front of the cache and are evicted in the ordinary way. They shuffle out gradually rather than vanishing at once, and when the last cached copy goes, the photo simply stops being dealable. No reaping pass, no special case, no code that exists only for this — the cache's normal behavior is the garbage collector.

The one thing to get right is that an orphan must not be re-fetched. A source that is unavailable is not asked to produce, so it never tries and never logs a storm of failures.

### Clearing the cache on purpose

Automatic decay is not enough, because the reasons to want the space back are immediate: a source that is never coming back, a disk filling up, a library that was added by mistake, or simply wanting to start clean.

- **`pgr_ctl cache clear`**, with `--source <id>` to drop one source's bytes, `--unavailable` to drop everything belonging to sources that are gone, and no argument to empty it entirely.
- **A control in the settings UI** when that exists, showing bytes held per source with a way to reclaim them.

**Two kinds of eviction, and only one of them costs anything.** Ordinary eviction — FIFO at the cap, and the disk-space guard — is incremental, continuous, and invisible: it discards the photos furthest from being dealt again, and the prefetcher is already refilling behind it. That is normal operation and needs no warning, no confirmation, and no user awareness at all.

An **explicit clear** is the other thing entirely. It evicts everything, and everything has to be fetched again. That is the whole point of it, and it is the reason it needs a guard rail that ordinary eviction does not. For folder sources the cost is nothing — referenced photos were never copied, so "re-retrieving" them is opening a file. For Photos and Google sources it can be enormous: a thousand materialized originals against an iCloud-optimized library is potentially tens of gigabytes and hours of downloading, on a connection that may be metered.

So the operation states its price before charging it. Both the command and the UI report, before confirming: how many photos will need re-downloading, how many are referenced and therefore free, and roughly how many bytes are implied. A full clear asks for confirmation; `--unavailable` does not need to, because photos whose source is gone can never be re-fetched anyway — that variant frees space at zero future cost, which makes it the one to reach for first.

**Shuffle state survives; only bytes are discarded.** Deal ordinals, shuffle keys, and last-shown times are untouched, so a cleared cache refills into the same rotation rather than reshuffling the library. Clearing is a storage operation, never a shuffle operation — and if even that turns out to be wrong, deleting the database rebuilds everything from the sources at the cost of a rescan.

**Recovery is the cold-start path, which already exists.** The queue is emptied along with the bytes, since its entries no longer point at anything. Every source is then below nominal and gets asked, exactly as on a fresh install. Displays hold their currently decoded image — which is in memory, not in the cache — until the first new picture is ready, so clearing does not blank a screensaver mid-session.

**And a disk-space guard, which is a genuine gap otherwise.** The cache cap is a photo count, and a count cannot bound bytes — so a library of large originals can fill a volume even while nominally under cap. The server therefore checks free space before each chunk: below a floor it stops materializing and logs why; below a lower floor it evicts ahead of the cap until it recovers. Running out of disk should degrade into "the deck stops growing" rather than into a full volume, which on macOS is a genuinely bad day for everything else running.

### Showing unavailability

An unavailable source must look unavailable — this is exactly the state where silence gets read as a bug. But **the photo is never annotated.** No badge, no overlay, no warning drawn on top of an image, on any surface. A cached photo from a missing source displays perfectly and there is nothing wrong with it; defacing it to warn about a future problem would trade the one thing this product is for against a message that belongs somewhere else. Notification goes in the chrome, never on the picture.

- **A menu bar item on the agent that appears only when something needs attention** — the quieter channel the ambient surfaces need. A missing source, a revoked permission, a disk nearly full. Invisible when all is well, which is the well-worn Mac idiom and costs nothing the rest of the time.
- **`pgr_ctl source list`** marks it inline, with the reason and the time it went unavailable.
- **The settings UI**, once there is one, shows it in red or its equivalent, with the reason in plain words — "drive not connected", "photo library changed", "permission revoked" — and the count of photos held in limbo. A source that has quietly stopped contributing to a shuffle is invisible otherwise, and the user's first clue would be a rotation that feels smaller than it should.

## Getting full-resolution originals out of Photos

This is the specific bug you are working around, so it deserves precision. There are two APIs:

- `PHImageManager.requestImageDataAndOrientation` with `PHImageRequestOptions.isNetworkAccessAllowed = true`, `deliveryMode = .highQualityFormat`, `version = .current`. This gives you the rendered current version including edits, as data.
- `PHAssetResourceManager.writeData(for:toFile:options:)` with `PHAssetResourceRequestOptions.isNetworkAccessAllowed = true`. This streams the original resource straight to a file without ever holding it in memory.

The critical flag in both cases is `isNetworkAccessAllowed`. When it is false — the default — and the library is set to "Optimize Mac Storage," Photos hands back whatever low-resolution derivative happens to be local. That is exactly the ugliness you described. Apple's own screensaver appears to make this mistake, or to deliberately avoid the download cost.

`PHAssetResourceManager` is the better choice for cached originals: it writes directly to disk, so a 100 MB ProRAW file never becomes a 100 MB `Data` in the agent's address space. The cost is that it gives you the *original*, not the edited render — a photo you cropped in Photos would come back uncropped. The likely answer is to use `PHAssetResource` of type `.fullSizePhoto` when present (that is the edited render) and fall back to `.photo`, but this needs the Photos provider's spike to measure it against a real library.

Throughput matters because the first fill of a 1000-photo deck against an iCloud-optimized library could be tens of gigabytes. The agent should download at low QoS with a small concurrency limit, respect `NSProcessInfo.thermalState` and low-power mode, and pause entirely on a metered connection.

## Where the two directories go, and `--prod`

The agent writes to exactly two places, and **development is the default**:

| | holds | default | with `--prod` |
| --- | --- | --- | --- |
| storage root | `library.sqlite` and its WAL sidecars | `<repo>/.build/pgr-container/` | `~/Library/Containers/com.sydpolk.photogoround/` |
| cache root | copied photo bytes | `<repo>/.build/pgr-cache/` | `~/Library/Caches/com.sydpolk.photogoround/` |
| preferences | the source list and every setting | a development domain | `com.sydpolk.photogoround` |

**Safe by default, dangerous on purpose.** Running the binary with no arguments cannot touch a real library — it writes into `.build`, which is gitignored and is already the directory you delete for a clean slate. Reaching the real one takes `--prod`, typed deliberately. The inverse default would mean every casual `swift run` was one typo away from a library that took hours to fetch, and every test of a delete path was a live-fire exercise.

**All three switch together, and that is the whole point of the flag.** This was learned the hard way: pointing the storage root at scratch space moved the database and the cache and left *preferences* — and therefore the source list — pointing at the real ones, so a run that believed it was isolated would happily remove somebody's sources for good. Two of the three are obviously per-deployment and the third silently is not. One flag that moves all three is the only version of this that a person can hold in their head.

The individual overrides remain, for the cases that genuinely want them — a cache on another volume, a database somewhere odd — and each still wins over whatever `--prod` would have chosen. `status` prints which rung supplied the roots, so it is never a guess.

**Why the two are separate at all**, rather than the cache living inside the container: `~/Library/Caches` is a place the OS may purge whenever it likes, which is exactly right for bytes we can fetch again and exactly wrong for the database. Nesting the cache inside the container would put it somewhere the system will never reclaim, throwing away the one piece of cooperation macOS offers for free.

**`~/Library/Containers` arrives with the LaunchAgent**, since a container is what a bundle identifier gets you and there is no bundle until something needs one. Until then `--prod` uses the same path anyway, which means nothing has to change when the bundle appears.

### Finding `.build` from Xcode

The development root is found by walking up from the executable looking for `.build`, which a SwiftPM binary carries in its own path — `<repo>/.build/<triple>/<config>/photogoroundd` — so `swift run`, the wrapper script, and a bare invocation all agree without being told anything.

**Xcode is the case that cannot cover**, and it matters because debugging the agent under a debugger has to work without a scheme argument. Xcode builds into DerivedData, which is nowhere near the checkout, so the walk finds nothing and the old fallback — the working directory — resolved to `/.build` and failed outright on a read-only volume.

The second rung is therefore the source tree the binary was compiled from: `#filePath` is a compile-time constant pointing into the checkout, walked up to `Package.swift`. It is exactly the right answer for a *development* default and is never consulted for `--prod`, where the roots are absolute. A shared scheme lives at `.swiftpm/xcode/xcshareddata/xcschemes/`, and it deliberately sets no arguments and no environment — the binary finding its own roots is a property worth keeping true rather than papering over in a scheme.

### Where an Xcode-launched *app* puts its container, which is not where you think

Ahead of Phase 3, and recorded because it is a genuine trap. A sandboxed Mac app launched by Xcode does **not** use `~/Library/Containers/<bundle-id>`. CoreDevice registers the Mac as a device in its own right and redirects the app's data container to:

```
~/Library/Developer/CoreDevice/DeviceFS/device-<UUID>/AppDataContainers/<bundle-id>/
```

Verified against another project on this machine: the live store sits there, while `~/Library/Containers/<bundle-id>/` holds only the container shell. That `device-<UUID>` is a CoreDevice identity, unrelated to `IOPlatformUUID`, and it is what makes "Download Container" work for a Mac app in Devices and Simulators.

None of this touches `photogoroundd`, which has no bundle identifier for CoreDevice to key on. It bites in Phase 3: once the Mac app is sandboxed and shares an App Group with the agent, an Xcode-launched app reads the CoreDevice container while an agent started from a terminal reads the real one, and two processes that are supposed to share one database are silently looking at two. The symptom — an empty window beside an agent insisting it holds eight thousand photos — points nowhere near the cause.

## Documentation lives in the repo as man pages

Every command gets a `Documentation/<command>.md` written as a man page —
`NAME`, `SYNOPSIS`, `DESCRIPTION`, `OPTIONS`, `ENVIRONMENT`, `FILES`, `EXIT STATUS`,
`SEE ALSO`. `Documentation/photogoroundd.md` is the first; `pgr_ctl` gets one in Phase 2.

Markdown rather than roff because these are read in a browser and a diff far more
often than through `man`, and because a format nobody can write is a format that
goes stale. The man-page *structure* is the part that matters: it forces every
option, every environment variable, and every file to be listed somewhere, which is
exactly the material that otherwise only exists in a `usage()` string and in
somebody's memory.

They are not a substitute for PLAN.md and do not explain why anything is the way it
is — that is this document's job. A man page says what the command does; the plan
says why it does it that way. Converting to roff later, if `man photogoroundd` ever
matters, is a mechanical step.

## The service does one thing

`photogoroundd` runs the queue. That is the entire command surface, and the constraint is deliberate rather than incidental.

**It takes no command word, because there is nothing to choose between.** There was a `run` verb for a while, and it was pure ceremony: a program with one behaviour that makes you name the behaviour is asking a question with one answer. It survived only because the inspect verbs bound for `pgr_ctl` were still sharing the binary and made it look like a subcommand among subcommands. A bare invocation now runs the agent; an unrecognised word is still an error rather than a silent start, so a typo cannot launch a server by accident.

A service that also answers questions is a service with two jobs, and the second one grows: first a status verb, then a way to add a source, then a way to change a preference, and now the thing that is supposed to be running unattended for a week has an interactive surface nobody is watching. Worse, it makes the service the *place* those things happen, when the whole architecture says otherwise — the database is the transport, so anything that wants to inspect or change the library opens it directly and never needs the agent's cooperation at all.

**So the service is configured, not commanded.** Everything it needs to know arrives before it starts:

```
PGR_CONTAINER=…  PGR_FOLDERS=…  PGR_RECURSIVE=1  photogoroundd
```

and everything else — what it found, what it has queued, what it will show next, what the preferences are — is answered by `pgr_ctl`, which opens the same database and rings the doorbell when it changes something. Neither process has to be running for the other to work, which is the property that made this design worth having.

**One consequence worth stating**: the service has no consumers of its own, so a staged agent fills the queue and then waits. That is correct and looks like nothing happening. Watching it do something means `pgr_ctl serve` in another terminal, or Phase 3's window.

## `pgr_ctl`, the command-line tool

A Swift executable in the same package, driving the server directly. It is Phase 2 because Phase 1 has no UI, and it keeps earning its place afterward because there are things a command line does that a window cannot.

The obvious value is that the server becomes demonstrable on its own — sources added, a library refreshed, a queue filled, pictures served, all before a single view exists. The less obvious value is that it makes the shuffle *testable in the way shuffles actually need to be tested*, which is statistically. "Does this feel random?" is not a question a GUI can answer. "Deal fifty thousand cards across four thousand photos and assert every pass contains every photo exactly once, then report the distribution of gaps between consecutive showings of the same photo" is a question a command-line tool answers in a script, in a second, repeatably.

A rough shape of the subcommands:

```
pgr_ctl source add --folder <path> | --file <path>
pgr_ctl source list | remove <id> | enable <id> | disable <id>
pgr_ctl refresh [--source <id>]        # diff sources against the pool
pgr_ctl pool stats                     # rows per source, available, media types
pgr_ctl queue peek [--count n]         # what is ready to serve, in order
pgr_ctl queue fill                     # ask every source once, synchronously
pgr_ctl serve [--count n]              # take pictures off the head, with timing
pgr_ctl deck stats                     # showing counts, gap distribution, passes
pgr_ctl cache status | evict | clear [--source <id>] [--unavailable]
pgr_ctl shuffle-test --deals N         # the statistical assertions
pgr_ctl set <key> <value> | get        # preferences, in the right domain
pgr_ctl notify <topic>                 # post a Darwin notification by hand
```

**It is internal and never ships.** It is not in the distributed bundle, gets no signing or notarization pipeline, needs no man page or polished ergonomics, and carries no compatibility promise — subcommands can change shape whenever a phase makes that convenient. It exists for us, on this machine.

Four notes on building it:

- **No argument-parsing package.** `swift-argument-parser` is Apple's, but it is still an SPM dependency, and the no-dependencies rule does not have an Apple exception. Hand-rolled parsing for a dozen subcommands is an afternoon and about two hundred lines.
- **It goes through the same public kit API as every other host.** The temptation to let a debug tool reach past the API into raw SQL should be resisted for the same reason it should be in the app: a harness that bypasses the interface tests nothing.
- **Being unshipped does not make it a scratch script.** No compatibility promise is not the same as no rigor: the assertions it runs are the project's real correctness checks for the deck, so they belong in version control and in CI alongside the unit tests.
- **It doubles as the measurement rig.** The cache-cap experiment — fill times and cache-miss rates across caps of 250 through 4000 — is a shell loop over `pgr_ctl` invocations, not a bespoke benchmark harness. Same for validating that serving actually serialises: run several `pgr_ctl serve` processes concurrently and assert the union of what they got has no duplicates.

**It has a head start.** `source`, `status`, `queue peek`, `serve`, `get` and `set` are written, because standing the agent up needed a way to see what it thought was happening. They live in `pgr_ctl` from the outset rather than as subcommands of the server.

Between them, `pgr_ctl` and the Mac app cover the two halves of the problem: the command line for anything scriptable, statistical, or repeatable, and the app for anything visual, interactive, or timing-dependent.

## The Mac app as instrument panel

**In Phase 3 the app is deliberately almost nothing.** A window, a photo in it sized to fit, the pan, a timer, and standard full-screen support — the green button and `toggleFullScreen:`, no bespoke presentation layer. It manages no sources and exposes no settings, because `pgr_ctl` shipped one phase earlier and already does both. That keeps the milestone small and keeps the app honest: it is a *consumer*, and consumers display cards.

Full screen is worth more than it looks. A full-screen window showing one photo, fit, slowly panning, is visually the same thing the screensaver will be. Every piece of that behavior — the axis choice, the pan speed and easing, the cross-fade, the black bars, the bouncing empty state — gets built and tuned here, in a normal app, with a debugger attached and print statements that work. Phase 6 then has to solve exactly one new problem, which is the sandbox, rather than solving the sandbox and the visual design at the same time.

**The diagnostic surface comes later, and grows one panel at a time.** Every subsequent surface depends on mechanisms that are miserable to debug in their eventual home — a widget you cannot attach a debugger to, a screensaver inside someone else's sandboxed process, a `BGProcessingTask` that fires when it feels like it. Each of those is easier to exercise in a window first, so each phase that needs a panel adds it then. What that eventually amounts to:

- **A deck inspector.** The next *n* cards in order, each photo's deal ordinal, shuffle key, last-shown time, and cache state. Most deck bugs are instantly obvious when you can see the ordering and instantly invisible when you cannot.
- **Consumer simulation.** Spin up two, three, five consumers at configurable rates and watch the queue drain and refill. This is how the shared-queue contention story gets tested — the "screensaver at one photo per ten seconds starves the wallpaper" scenario is a slider in this app long before there is a screensaver.
- **A cache inspector.** Resident count against the cap, bytes on disk, what is materialized versus referenced, and a forced-eviction button. This is also where the cache-cap measurement gets run, rather than in a throwaway script.
- **Spike runners.** Each phase's spike as a menu item that reports pass or fail with the relevant log output — the App Group container resolution check, the `PHAssetResourceManager` originals check. The screensaver sandbox spike is the one exception that genuinely cannot run here, since the whole question is what happens inside a different process.
- **A Darwin notification monitor.** A list of the notification topics with a timestamp for each firing, plus buttons to post them by hand. When the agent arrives in Phase 4 and something does not update, this is what tells you whether the doorbell rang.

None of this ships to a user, and none of it needs to be pretty. It should be behind a debug menu or a separate window, built with whatever SwiftUI is quickest, and it should be allowed to look like a diagnostic tool rather than a product.

The one discipline worth keeping: the harness must drive the kit through the same public API the real surfaces use. The moment it reaches past that API to poke the database directly, it stops being a test of anything.

## Logging

The server — and the backend half of the iOS app — logs structurally, through Apple's unified logging and nothing else. `OSLog`/`Logger`, subsystem `com.sydpolk.photogoround`, one category per subsystem: `deck`, `cache`, `sources`, `photos`, `prefs`, `wallpaper`, `saver`, `widget`.

**Nothing is shipped anywhere.** No crash reporter, no analytics, no log upload, no telemetry endpoint, no third-party SDK — which also keeps the dependency ledger at zero. If this ever becomes popular enough to justify collecting anything, that is a decision to spend money and time on later, from a position of knowing it matters. Until then, logs live on the machine that produced them and are read with Console or `log show`.

**Unified logging is not merely the zero-dependency option, it is the only one that works everywhere we run.** A hand-rolled file logger would fail in exactly the places debugging is hardest: the screensaver inside `legacyScreenSaver`'s sandbox may not be able to write a log file at all, and a widget extension has neither a writable location we control nor a lifetime long enough to flush one. `os_log` crosses those boundaries because the system owns the transport. Every process writes to the same place and `pgr_ctl` can read all of it.

Details that decide whether the logs are useful a week later:

- **Level determines persistence, so choose deliberately.** `.debug` is memory-only and gone by the time you look; `.info` persists only when the subsystem is being actively collected. State transitions worth reconstructing after the fact — source became unavailable, cache cleared, library switch detected, preference changed, wallpaper reasserted — must be `.notice` or higher, or they will not be there.
- **Privacy annotations are on by default, and that is correct here.** Interpolated values are redacted as `<private>` unless marked `.public`. File paths, photo filenames, and album names are the user's business and stay private. Structural values — source ids, counts, durations, error codes, deal ordinals — are marked public, because a log full of `<private>` is not a log.
- **Structured means fields, not prose.** Consistent event names with consistent keys, so `log show --predicate` can filter on them. "Materialized 10 photos in 4.2s for source 3" is a sentence; the same thing with stable keys is queryable.
- **`OSSignposter` for intervals**, not log lines: decode-to-display time, fetch duration, refresh duration, serve latency. These are the numbers the Phase 2 measurements need, and signposts make them readable in Instruments without building a benchmark harness.
- **`pgr_ctl log`** wraps `log show --predicate 'subsystem == "com.sydpolk.photogoround"'` with sensible defaults and a `--follow` mode, because nobody should have to remember predicate syntax to see what the server is doing.

Because the logs are never collected, they have to be self-sufficient on the machine. That argues for logging the *reason* alongside every state change rather than logging that it happened and hoping the cause is inferable from what came before.

## Testing strategy

`PhotoGoRoundKit` is where the logic lives, so that is where the tests live. The deck algorithm is pure and testable against an in-memory database: at fraction 1.0, assert that a thousand deals across a hundred photos produce exactly ten showings each with no repeat inside any hundred-deal stretch; at lower fractions, assert no repeat inside the window and report the gap distribution. The cache is testable with a folder of synthetic files: assert that FIFO eviction holds the cap, that nothing in the queue is ever evicted, that a picture deleted from a reachable source is never served, and that an unreachable source keeps serving from cache. The source providers get integration tests behind a protocol so folder sources test for real and Photos tests against a fixture library.

Above the unit tests sit three layers, each catching what the one below cannot:

- **`pgr_ctl`** for anything scriptable, statistical, or concurrent — shuffle distribution over fifty thousand draws, cache-cap sweeps, and several processes serving at once to prove the queue pop actually serialises. These are assertions a test suite can run in CI as easily as a person can run them by hand.
- **The Mac app's instrument panel** for anything visual or timing-dependent — deck ordering seen at a glance, simulated consumers at different rates, Darwin notifications observed as they fire.
- **Per-phase spikes and manual verification** for what neither can reach: wallpaper application, the saver's sandbox behavior, widget timeline budgets.

That asymmetry is a good reason to keep as much behavior as possible inside the package, where the cheapest layer can reach it.

### A test that writes preferences cannot fully clean up after itself

Worth recording because the obvious fix does not work. Tests that touch preferences each build a throwaway `UserDefaults` suite so they never write into the real domain, and tear it down afterwards. They still left a plist in `~/Library/Preferences` on nearly every run, five hundred of them before anyone counted.

The reason is that `cfprefsd` owns those files and writes them on its own schedule — including *after* the test process has exited. Neither `deinit` nor an `atexit` handler can catch the stragglers, because nothing inside the process is still running when the daemon flushes. Measured directly: zero files two seconds after a run, nine a minute later.

So the sweep runs at the *start* of a run instead, clearing what the previous one left, and removes only files older than the current process so two concurrent runs cannot delete each other's live suites. Per-suite teardown still does its part. Together they bound the leak at one run's worth — under ten files, oscillating — rather than letting it grow without limit.

## The agent: registration and permissions

Package it as an app bundle with `LSUIElement = true` — no Dock icon, no menu bar presence unless we choose one — living in `Contents/Library/LoginItems/` inside the main app, with its LaunchAgent plist in `Contents/Library/LaunchAgents/`. The config app registers it with `SMAppService.agent(plistName:)`, which is the modern replacement for hand-installing plists in `~/Library/LaunchAgents` and for the deprecated `SMLoginItemSetEnabled`. The user can then see and disable it in System Settings → General → Login Items, which is the behavior people expect.

A bundle rather than a bare executable matters for TCC: the Photos permission prompt needs a bundle identifier and an `NSPhotoLibraryUsageDescription`, and the grant is recorded against the code signature. Developer ID signing plus notarization keeps that grant stable across updates.

`KeepAlive` with `SuccessfulExit = false` so it restarts on crash; `RunAtLoad` true. The agent should also handle being launched before the user has granted Photos access — request, and if denied, run with folder sources only rather than dying.

## Talking to the subsystems we do control

The ladder above exists only because `legacyScreenSaver` is someone else's sandbox. Every other Mac component — the agent, the config app, the widget extension — is ours, signed by us, entitled by us. For those, the answer is settled and needs no server of any kind:

- **The database is the transport.** Shared state lives in SQLite in the App Group container, and every process reads and writes it directly. There is no message format to design, no serialization, no versioned protocol between components, and no process that has to be running for another to make progress.
- **A Darwin notification is the doorbell.** Because SQLite gives no cross-process change notification and a payload-free signal is all that is needed — "settings changed", "deck advanced", "sources rescanned" — the receiver re-reads whatever it cares about. Each notification name is a topic, and there are perhaps half a dozen.

That pairing covers every case, and it is the reason the plan has no local HTTP server, no sockets, and no XPC between our own components. It also degrades well: if the agent is not running, the config app still reads and writes the database, and the agent picks up the changes when it starts.

Worth noting the fallback if all three fail: ship the screensaver as a full-screen borderless window from an ordinary app, triggered by an idle timer, rather than as a `.saver` bundle. That loses integration with System Settings and with the lock screen, and I would treat it as a last resort.

## Wallpaper mechanics and their limits

`NSWorkspace.shared.setDesktopImageURL(_:for:options:)` takes an `NSScreen`, so per-display wallpaper is straightforward, and the options dictionary carries fill mode and background color — that is the "control how it was displayed" you asked for. Unsandboxed, there is no entitlement problem.

Two limitations to plan around. First, the call sets the wallpaper for the *current* Space on that screen only; if you use multiple Spaces, the others keep whatever they had until you visit them. There is no public API to enumerate Spaces, so the practical mitigation is for the agent to re-apply on `NSWorkspace.activeSpaceDidChangeNotification`.

### Wallpaper is asserted continuously, never set once

Second, and more seriously: macOS reverts wallpaper on its own. The observed behavior on the current setup is that the desktop drops back to the stock Golden Gate image at random, stays there a while, and later starts working again — with no user action involved. Whatever the cause (a wallpaper agent losing its state, a dynamic-wallpaper interaction, a display reconfiguration racing login), we cannot prevent it and should not try to diagnose it. We can simply refuse to lose.

So the wallpaper consumer does not set an image and consider the job done. It owns an invariant — *this screen should currently be showing this file* — and enforces it:

- **Verify, then correct.** `NSWorkspace.shared.desktopImageURL(for:)` returns what the system believes is current. Compare it against what we last set for that screen; if it does not match and we did not change it, set it again. This is a cheap call and can run on a modest interval — every minute or two costs nothing.
- **Reassert on every event that plausibly disturbs it:** wake from sleep, `NSApplication.didChangeScreenParametersNotification`, `NSWorkspace.activeSpaceDidChangeNotification`, session activation, and agent launch.
- **Do not fight the user.** If someone deliberately sets a wallpaper through System Settings, hammering it back is obnoxious. The distinction is that a user change is a change to something *other* than the Golden Gate default we never chose — a reasonable heuristic is to reassert only when the current image is neither ours nor one the user set within the app, and to expose a "pause wallpaper" control so there is an obvious way to stop us.
- **Log the corrections.** If the reversion turns out to have a pattern, the log is what reveals it. If it is genuinely random, the log is what proves the correction is working.

Scheduling the *rotation* is separate and simpler: an interval from preferences, a `DispatchSourceTimer` that checks wall-clock rather than counting ticks so it survives sleep, and an immediate deal on wake if the interval elapsed while the machine was out.

## Swift everywhere, including the screensaver

The Xcode screensaver template generates Objective-C, which is a fact about the template rather than about screensavers. `ScreenSaverView` is an Objective-C class, but subclassing it from Swift is entirely ordinary — delete the template's `.m` and `.h`, add a Swift file, and write the saver in Swift like anything else. There is no Objective-C anywhere in this project.

Three specific things make a Swift `.saver` fail, and all three are configuration rather than code. They are worth writing down because the failure mode in every case is the same and is maximally unhelpful: the screensaver silently does not appear in System Settings, with no error anywhere.

- **The principal class name must survive Swift name mangling.** A Swift class compiles to a mangled symbol like `_TtC15PhotoGoRoundSaver18PGRScreenSaverView`, which is not what you put in `Info.plist`. Annotate the class `@objc(PGRScreenSaverView)` to give it a stable Objective-C runtime name, and set `NSPrincipalClass` to exactly that string. This one accounts for most "my Swift screensaver doesn't show up" reports.
- **The bundle must be a `.saver`, not a `.bundle`.** The wrapper extension is a build setting, and the target must be a bundle target rather than a framework or app target.
- **The two required initializers must both exist.** `init?(frame:isPreview:)` is the one you write; `init?(coder:)` must also be present because the class is instantiated through the Objective-C runtime.

The rest of the plan is Swift and SwiftUI throughout. A few of the APIs involved are C rather than Objective-C — `sqlite3_*`, and `CFNotificationCenterGetDarwinNotifyCenter` for cross-process signalling — which means some `UnsafePointer` handling at those two boundaries, wrapped once and never touched again. That is not Objective-C and does not require knowing any.

That earlier project was deleted on sight of the `.m` files, so there is nothing to salvage from it and no prior observation of what a saver can read from disk. The Phase 6 sandbox spike stands as the sole source of that answer. It is a stub saver and an afternoon, and nothing stops it being run early — out of order, ahead of the phases before it — if the uncertainty starts to feel expensive.

## The screensaver sandbox problem

This is the largest technical risk in the plan, and the reason Phase 6 opens with a spike rather than with code.

Modern macOS does not run `.saver` bundles in a process of their own. It loads them into `legacyScreenSaver`, an Apple-provided host that is itself sandboxed. Our code inherits that sandbox. So the saver almost certainly cannot open `~/Library/Application Support/Photo-Go-Round/cache/`, no matter that the user owns both.

The options, in your order of preference:

1. **Direct database and file access, via the host's container.** The unsandboxed agent writes the database and cache to `~/Library/Containers/com.apple.ScreenSaver.Engine.legacyScreenSaver/Data/Library/Application Support/Photo-Go-Round/`. From inside the sandbox that path *is* `~/Library/Application Support/Photo-Go-Round/`, so the saver opens it as ordinary local storage — same SQLite calls as everything else, no protocol, no serialization, no server. It is ugly in exactly one way: the container path is an Apple implementation detail that could change under us. Cheapest to test and by far the best outcome, so it goes first.
2. **Darwin notifications.** These almost certainly cross the sandbox — `notify_post` and `notify_register_dispatch` are permitted in most profiles — but they are not an alternative to option 1, because **a Darwin notification carries no payload**. It is a name and nothing else. That makes it a doorbell, not a transport: it can tell the saver "the deck changed, go look," but the looking still has to happen through the database. So options 1 and 2 compose rather than compete, and option 2 alone cannot carry the screensaver.
3. **Localhost HTTP.** The agent binds an HTTP server to `127.0.0.1` on an ephemeral port, publishing the port and a per-launch bearer token through a file the saver can read; the saver fetches images and posts deck advances over it. This works only if `legacyScreenSaver`'s sandbox grants outbound network access, which is unverified. The token matters because any local process can otherwise reach that port.
4. **Unix domain sockets.** Ranked last, and correctly so, but for a sharper reason than general distaste: a Unix socket is a file on disk, so it needs both `network-outbound` permission *and* a path the sandbox permits. That is strictly a superset of what option 1 needs. If the sandbox lets us place a socket somewhere the saver can open it, it would have let us put the database there instead — and the database is simpler. Unix sockets can only ever be the answer in the narrow case where file *reads* are permitted but SQLite's write locking is not, which is unlikely enough not to plan around.

**XPC is absent from your list.** It is the Apple-idiomatic answer — a global Mach service in the agent's LaunchAgent plist, `NSXPCConnection` from the saver — and architecturally the cleanest of the lot. It is also the one with no workaround if it fails: `legacyScreenSaver`'s sandbox may simply deny `mach-lookup` for names it does not recognize, and there is nothing to be done about that from our side. Given it sits below your top two in appeal and above HTTP in cleanliness, the plan tests it only if 1 fails, and treats it as an alternative to 3 rather than a replacement for it. Say if you would rather drop it entirely.

**The fallback if nothing works: a consumption journal.** The saver reads the head of the queue without removing it, appends what it showed to a file in its own container, and the agent applies those removals to the real queue. Eventually consistent rather than atomic, so two savers on two displays could briefly show the same picture — acceptable, and far cheaper than the alternative.

The spike is small: a stub `.saver` that tries each in order and logs results, installed and run for real. A day at most, and it determines the shape of Phase 5.

## Screensaver v1: one photo, fit, with a slow pan

The first layout is deliberately the simplest one that looks good: a single photo at a time, sized to fit the display, and when the photo's aspect ratio does not match the display's, a slow pan back and forth along the mismatched axis instead of a static image sitting in dead black.

**Sizing is "shrink or expand, preserving aspect ratio" — aspect fit.** The photo scales up if it is smaller than the display and down if it is larger, until it fits entirely on screen. The whole photo is always visible and nothing is ever cropped. Where the ratios differ there is black, and the pan slides the fitted photo within that black field: the bar migrates from one side to the other and back. This is the one display mode in v1; others come later.

**Choosing the axis.** Compare the photo's aspect ratio to the display's. A photo relatively *wider* than the display fits to the screen's width and leaves black above and below, so it travels up and down; a photo relatively *taller* fits to the height and leaves black at the sides, so it travels left and right. When the two ratios are within a percent or so of each other, there is no bar and nothing to pan, and the photo simply sits there — which is correct. The code should not manufacture motion where none is warranted.

**Travel distance is the bar, and it is often small.** Unlike a fill-and-overflow pan, the distance available here is exactly the letterbox thickness, which for a 3:2 photo on a 16:10 display is only a few percent of the screen. That is a feature — the motion is meant to be barely perceptible, not a ride — but it means the pan should be skipped entirely below some threshold rather than jittering a photo back and forth across twelve points.

**Constant speed, not constant duration.** The pan should move at a fixed rate in screen points per second — somewhere around 10 pt/s, to be tuned by eye — rather than traversing the full overflow in a fixed time. If speed were derived from overflow divided by dwell time, a panorama would streak across the screen while a nearly-square photo would creep, and the inconsistency reads as a glitch. With constant speed, some photos complete their traverse and reverse, and some do not finish; both look intentional.

**Ping-pong with easing.** "Back and forth" means the motion reverses at the extremes rather than jumping. Ease in and out at each reversal — a linear pan that instantly reverses looks mechanical. `CABasicAnimation` with `autoreverses = true`, `repeatCount = .infinity`, and an ease-in-ease-out timing function is exactly this, declaratively.

**Use Core Animation, not `animateOneFrame()`.** `ScreenSaverView` offers a per-frame callback, and it is the wrong tool here. A layer-backed image with a declarative animation runs on the render server, so the pan stays perfectly smooth even while the saver's own thread is busy decoding the next photo or reserving a new hand. Per-frame drawing would stutter at exactly the moments the user is most likely to notice.

**Resolution, and the cost of "expand."** Because the photo only ever fits, the subsampled decode targets the display's pixel dimensions and no more — there is no overflow to cover. The saver asks `CGImageSource` for the screen's long dimension and gets back exactly what it needs.

The "expand" half of the requirement carries a quality caveat worth stating plainly: a 640×480 image scaled up to fill a 6K display's height will look soft, and no amount of interpolation fixes missing detail. The requirement is explicit, so v1 expands anyway. But an upscale cap — refuse to enlarge beyond, say, 2× native and let the small photo sit smaller with more black around it — is an obvious later option, and it belongs in the same settings group as the other display modes.

**Transitions between photos.** A cross-fade, with the incoming photo's pan already in motion underneath, so the arrival does not read as a jump cut into a static frame. Decode and prepare the next photo during the current one's dwell, which the hand makes easy — the next card is already known.

**Black is black.** Any remaining letterbox area is pure black rather than a dark gray, which matters on OLED and on the XDR displays where it is genuinely black. A blurred-and-scaled fill of the photo behind the letterbox is the obvious future alternative and is explicitly not v1.

**Preview mode must not consume the queue.** `ScreenSaverView` is instantiated with `isPreview: true` for the thumbnail in System Settings. That instance must not serve — if it did, idly browsing screensaver settings would consume pictures nobody ever sees, and with a shared queue those are then spent for the wallpaper too. Preview peeks at the queue without draining it, which the queue supports directly.

**One instance per display, and each is its own consumer.** macOS creates a separate `ScreenSaverView` for every attached screen. Each serves from the same queue, so the displays show different photos simply because serving removes the entry, and each computes its own pan against its own aspect ratio.

## The empty state

With no photos at all, the screensaver shows the words "No photos" bouncing around the screen — constant velocity, reflecting off each edge, the way a breakout brick or a DVD logo does.

This is the right call for three reasons beyond it being fun. It is unmistakably *our* screensaver rather than a black screen that looks like a crash or a display asleep. It moves, so it cannot burn in on the OLED and XDR panels where a static centered label would be a genuine hazard over hours. And it appears in the System Settings preview thumbnail too, which means a misconfigured install announces itself at exactly the moment the user is looking at the settings pane.

Implementation notes:

- **Constant velocity, pure reflection.** No gravity, no damping, no acceleration — position advances linearly and the velocity component flips sign at each wall. Speed in points per second so it looks the same on a laptop panel and a 6K display.
- **Avoid degenerate angles.** An initial direction too close to horizontal or vertical traces the same boring line forever. Pick the starting angle randomly from a band away from the axes, roughly 30–60° and its reflections.
- **Core Animation again,** for the same reason as the pan: the motion should not stutter because something else is busy. A `CAKeyframeAnimation` over an analytically-computed reflecting path covering several minutes is simpler and smoother than per-bounce chaining.
- **`CATextLayer` sized relative to the screen,** on the order of an eighth of the width, so it is legible across the whole display range without a hardcoded point size.

**Three distinct empty states, one treatment.** It is worth distinguishing *no sources configured at all*, *sources configured but they enumerate to nothing* — an emptied folder, an album you deleted — and *photos exist but none are cached yet*, which is the cold-start case and is transient. The bouncing treatment suits all three; only the words differ, and the third should say something like "Loading photos" so a first run does not look broken. Whether to bother with that distinction in v1 is a judgment call I would make in favor of, since the code is the same and the third case is the one a new user hits first.

**Other surfaces need an answer too, and it is not the same one.** The wallpaper should leave whatever wallpaper is already there rather than replacing your desktop with a "No photos" image — an empty deck is not a reason to vandalize the desktop. A widget has no room to bounce anything and should show a static label with a tap target that opens the configuration screen. Both are defaults I would pick rather than requirements you stated; say so if either is wrong.

## Widgets on macOS, and where the store actually lives

macOS has widgets — Notification Center and, since Sonoma, sitting on the desktop — and they use the same WidgetKit API as iOS. That makes a Mac widget nearly free in code terms, and it is another consumer with its own hand. But it has one consequence that reaches all the way back into the storage design.

**A widget extension is sandboxed even though the Mac agent is not.** App extensions on macOS require the sandbox; there is no opting out. So the unsandboxed agent writing to `~/Library/Application Support/Photo-Go-Round/` produces a store the widget cannot open, for exactly the same reason the screensaver cannot open it.

The fix is an App Group container, and it is worth adopting as *the* storage root on both platforms rather than as a Mac special case:

- `containerURL(forSecurityApplicationGroupIdentifier:)` resolves for sandboxed and unsandboxed processes alike, landing in `~/Library/Group Containers/<group>/` on macOS.
- Using it everywhere makes the Mac and iOS layouts symmetric, which is worth something given the kit has to run on both.
- On macOS, App Group identifiers for Developer ID applications must be prefixed with the team identifier — `TEAMID.com.sydpolk.photogoround` rather than `group.com.sydpolk.photogoround`. This differs from iOS convention and is a classic afternoon lost to a `nil` container URL. It also means the group identifier is not portable between the Mac and iOS builds, so it belongs in the `HostEnvironment` rather than in a shared constant.

This spike opens Phase 8 because it gates the Mac widget entirely, and because the combination — unsandboxed Developer ID host, sandboxed extension, shared group — is common enough to expect to work but specific enough to be worth ten minutes of proving rather than assuming.

**It does not help the screensaver.** A `.saver` bundle runs under `legacyScreenSaver`'s code signature and sandbox, not ours, so our App Group entitlement does not apply to it. The screensaver remains its own problem with its own spike in Phase 6.

**Everything else about Mac widgets follows the iOS design.** Same timeline provider, same refresh budget, same archived-image size ceiling, same "reserve a hand covering the entries about to be generated." The small widget-sized files that iOS writes for its widget's hand are needed on the Mac for the same jetsam reason, and live in `Caches` on both.

## What the Mac and iOS actually share

Building both hosts against one kit is only worth doing if the shared part is real. The backends are genuinely different, so it is worth being precise about where the seam falls.

**Identical on both platforms, and therefore in the kit:**

- The schema and its migrations. One set of tables, one migration sequence, byte-identical files.
- The deck algorithm. It is SQL over that schema — a window filter ordered by a random key, then one UPDATE to advance. Nothing about it is platform-specific.
- The source-provider protocol, the folder provider, and the Photos provider. PhotoKit is substantially the same API on macOS and iOS; the differences are permission flow and library availability, not asset fetching.
- Cache *policy*: which photos deserve to be resident, in what order to fetch them, what to evict when over the cap. Pure functions of deck state and a cache cap.

**Different, and therefore pushed onto the host:**

- **Execution model.** The Mac agent is a long-lived process that can fetch continuously for an hour. The iOS widget is invoked, gets a few hundred milliseconds to produce a `TimelineEntry`, and dies. There is no shared abstraction over those two things that is not a lie, so the kit exposes work as discrete callable units — `refresh(source)`, `produce(forSource:)`, `serve()`, `evictIfNeeded()` — and never schedules anything itself. Concurrency is scheduling too: the kit produces one picture at a time and the host decides how many of those to run at once.
- **Storage roots.** An App Group container on both platforms — because macOS has widgets too, and a widget extension is sandboxed even when its host is not — plus possibly the `legacyScreenSaver` container for the Mac screensaver. The host supplies these through a `HostEnvironment` protocol; the kit never constructs a path from a hardcoded root.
- **Caps and what gets stored.** 1000 originals on the Mac, decoded to size on demand; a far smaller cap on iOS, plus the one place a small file is written to disk — the widget's upcoming entries, because the rendered-entry memory ceiling makes handing a widget a full-resolution image an outright crash rather than a slowdown.
- **Change notification.** Darwin notifications on the Mac, `WidgetCenter.reloadTimelines` on iOS. Same protocol method, unrelated implementations.
- **Fetch aggressiveness.** The Mac can saturate the network at low QoS. iOS fetches opportunistically in the foreground plus a `BGProcessingTask` when charging, so its cache fills over days rather than minutes — a real behavioral difference the config UI should state plainly rather than hide.

The payoff for accepting this complexity up front is that the deck can never diverge between platforms, and that a bug in the shuffle is fixed once. The cost is that Phase 1 takes longer than a Mac-only kit would, because every kit API has to be designed to be callable from a process that is about to be killed — a cost paid up front even though iOS itself does not arrive until Phase 4.

## What a folder source means on iOS

On the Mac a folder source is a path, and an unsandboxed server reads it directly. iOS has no such thing, so the same source kind resolves differently — and it resolves into machinery that already exists.

**The locator is a security-scoped bookmark; the container copy is the cache.** `UIDocumentPickerViewController` or SwiftUI's `fileImporter` gets the user to their file in the Files app, and the resulting URL is preserved as bookmark data in `source.locator`. Reading it means resolving the bookmark inside `startAccessingSecurityScopedResource()`. The app then copies the bytes into the App Group container — and that copy is a cache entry, not a separate category of thing.

This is the volume rule again rather than a new rule. On iOS nothing outside the container is guaranteed to stay put: a file provider can evict a local copy, iCloud Drive can dematerialize it, the provider app can be offline or uninstalled. Everything reachable through the picker is therefore in the "can go away" column, and everything in that column is materialized. macOS reference-in-place has no iOS analogue because iOS has no equivalent of the always-mounted internal volume.

Everything downstream then works unchanged. Cached copies count against the cap, are evicted FIFO like anything else, and are re-materialized by resolving the bookmark and reading again. If the bookmark goes stale — file deleted, provider gone, access revoked — the source goes unavailable and its cached photos decay exactly as an unplugged drive's do. No new eviction rule, no new failure path.

**One honest caveat, and it is a UI wording problem rather than a design one.** Because the container copy is a cache, a user who picks a file, then deletes the original in Files, will eventually lose that photo when the cache entry is evicted — where they may well have expected the app to have "imported" it permanently, the way Photos does. The contract is the same as everywhere else in this system, *gone from the source means gone from the deck*, and it is the right contract. But the interface should say **"added from Files"** rather than "imported," and should not use language implying a copy was kept. Retaining our own permanent copies instead would mean holding photos the user deliberately deleted, which is the same thing already rejected for `clonefile`.

Whole-folder sources work on iOS too, since the picker can return a directory URL. Enumerating one is subject to the same eviction caveats, so a directory source rescans in the foreground only, never from a widget timeline provider — which is a bad place to discover a file needs downloading from iCloud Drive.

## The iOS family

The widget is the execution model, as you correctly identified — it is the only thing that runs on a schedule without the user opening the app. But WidgetKit's model is narrower than you may be assuming: the widget extension does not run continuously and does not get to do meaningful background work. It gets woken to produce a `TimelineEntry`, with a budget of a few dozen refreshes a day, and it must return quickly.

So the deck advance on iOS happens *inside the timeline provider*: each entry generation deals the next photo, updates the row, and returns an entry pointing at a file in the App Group container. Bulk fetching from Photos happens in the app, when the app is foregrounded, plus a `BGProcessingTask` scheduled for when the device is charging. That is a real behavioral difference from the Mac — the iOS cache fills opportunistically rather than continuously — and the config UI should be honest about it.

No HTTP server. The widget extension shares an App Group container with the app; it can read image files and the SQLite database directly. A local HTTP server on iOS would be suspended along with the app the moment it backgrounds, so it would solve nothing while adding an entitlement and a security surface.

Note that widget images have a memory ceiling (roughly 30 MB for the rendered entry, and archived images well below that). This is the one consumer that cannot decode for itself, so the app writes small files sized to the widget family for the widget's outstanding hand — into `Caches`, regenerable, uncounted by the deck.

## Apple Watch, and why it breaks two of our rules

The Watch is the most constrained surface in the plan and the only one that violates decisions taken everywhere else. Both violations are forced, not chosen.

**It has no photo sources of its own.** watchOS has no Photos framework and no meaningful notion of user-visible folders, so there is nothing for a source provider to enumerate. The watch cannot build a library; it can only be handed one.

**It therefore cannot be an independent install.** The "no cross-device sync" decision holds because iCloud Photos already puts the same photos on every device — but it does not put them on the Watch. So the Watch is a genuine dependent of the paired iPhone, which becomes its feeder. This is the one place in the design where two devices have a relationship, and it is worth being explicit that it is a *feeding* relationship rather than a sync one: the phone decides, the watch displays. No deck lives on the watch, no shuffle happens there, and nothing on the watch is authoritative about anything.

So the Watch app is built as a companion and declares that dependency rather than degrading into it. watchOS permits independent apps that run without a paired phone; this one deliberately is not, because an unpaired watch would have an empty library and no way to fill it. Declaring the requirement means the failure is a clear "needs the iPhone app" at install time instead of a mysteriously blank widget later.

The mechanism is `WCSession.transferFile`, which queues transfers opportunistically and survives the app not running on either end. The phone keeps a small rolling set of watch-sized derivatives on the watch — a handful, not a thousand — replacing the oldest as the deck advances. Practically, the phone serves a few pictures on the watch's behalf and pushes derivatives for them; the watch plays through what it has and shows the most recent if a transfer is late.

**The rendering mode is the thing most likely to disappoint.** WidgetKit on watchOS renders through `widgetRenderingMode`, and on most watch faces complications render accented or vibrant rather than full color — which turns a photograph into a luminance mask. A photo complication on a watch face will not look like a photo. The Smart Stack is the surface where full color is actually available, so that is the realistic target, and `.accessoryRectangular` is the only family with enough room for an image to read as an image at all.

This is exactly the sort of thing worth ten minutes of proving before designing around, hence the spike: put a real photograph in each family on a real watch, look at it, and decide whether the watch face families are worth supporting at all or whether the Smart Stack is the whole feature.

**Everything else is smaller versions of known problems.** What the watch stores is tiny — watch-screen-sized, well under the widget memory ceiling — and it is the only copy there, not a derivative of a local original. Complication timeline reloads are budgeted more strictly than on iOS, so the watch advances its own display on the phone's schedule rather than trying to run a clock of its own. And storage on the watch is small enough that the rolling set is measured in single-digit megabytes.

*Caveat, as elsewhere in this plan: the rendering-mode behavior described here is what held through the watchOS versions I know. Verify against the installed SDK before designing Phase 9 in detail.*

## tvOS storage

tvOS is the awkward one. Apps get a small persistent container and everything else lives in `Caches`, which the system purges under pressure without asking. A 1000-photo cache of full-resolution originals is not something tvOS will let you keep. The realistic tvOS design is a much smaller rolling cache (a few hundred megabytes), refilled from either iCloud Photos directly or from a Mac on the same network, plus a Top Shelf extension for the pretty part. Worth confirming this is acceptable before Phase 10 rather than discovering it during.

## Why nothing syncs between devices

Each install is its own world: its own database, its own cache, its own shuffle. This is a decision, not an omission, and it is worth recording why it is the right one.

`PHAsset.localIdentifier` is not stable across devices — the same iCloud photo has a different local identifier on your Mac and your iPhone. Any shared deck would therefore need `PHCloudIdentifier` and `PHPhotoLibrary.cloudIdentifierMappings(forLocalIdentifiers:)` to establish that two rows are the same photo. That call is slow enough to need batching and caching, and it simply fails for assets that have not finished uploading. Every row in the schema would have to carry a second identity that is sometimes absent, and every join would have to tolerate that.

Against that cost, the benefit is nearly zero. iCloud Photos already guarantees both devices see the same photos, so both are shuffling the same pool. Two independent shuffles of the same pool are indistinguishable from one shared shuffle unless you are staring at a Mac and an iPad side by side and comparing. The only case where independence is visibly worse is that you re-pick your albums on each device — a one-time cost of about a minute.

There is a second, quieter benefit: no sync means no CloudKit account state to handle, no "sync is paused because you are out of storage," no merge conflicts when two devices deal simultaneously, and no schema versioning contract between an old iPhone build and a new Mac build. The database on each device answers only to the code on that device.

The folder sources make this cleaner still. Folder sources are inherently local — a path on your Mac has no meaning on an iPad — so even a configuration-only sync would have been partial, syncing album picks but not folder picks. Independence makes that asymmetry disappear rather than requiring an explanation in the UI.

If this ever changes, the migration is additive: a nullable cloud-identity column and a sync table. It is not a schema the current design forecloses, just one it declines to pay for now.

## Configuration, and noticing external `defaults write`

Preferences live in the App Group's `UserDefaults` suite; the database holds state. `pgr_ctl set` is the blessed way to change a preference because it knows the right domain and posts the change notification afterwards. But raw `defaults write` must work too, from any terminal, with no cooperation — that was an original requirement and it is the harder half.

**The mechanism, because "observe `UserDefaults`" is not one.** `UserDefaults.didChangeNotification` and KVO on a defaults key are documented for in-process changes. Cross-process they are unreliable — sometimes they fire, sometimes late, sometimes not at all — so nothing may depend on them. What actually works is watching the backing store and re-reading:

- **Poll, and do not watch.** A re-read every thirty seconds is the mechanism, not the backstop. This follows the same conclusion as folder scanning, for the same reason: the cost is nil and the only thing bought by watching is latency nobody can perceive on a setting like a dwell time or a cache cap.

  The watcher this replaces was not cheap to get right, which is most of the argument. `defaults` writes through `cfprefsd`, which replaces the plist atomically via rename — so a `DispatchSource.makeFileSystemObjectSource` on a file descriptor is invalidated by the very event we care about, its descriptor now pointing at an unlinked inode. Getting it right meant watching the *containing directory* with an FSEvents stream, or re-arming the vnode source on every `.rename` and `.delete`. That is the single most common way to implement this wrong and have it work in testing, then silently stop after the first write. Deleting it removes a whole class of bug we would only have discovered weeks later.
- **Force a re-read before reading.** `cfprefsd` caches aggressively, and a stale value in our process is the default outcome. Call `CFPreferencesAppSynchronize` for the domain — or `UserDefaults.synchronize()`, deprecated but still the mechanism — before pulling values, or we will faithfully notice a change and then read the old number. This matters *more* without a watcher, not less: the poll is only as good as the read it performs.
- **`pgr_ctl set` rings the doorbell, so the blessed path stays instant.** Polling is the floor, not the ceiling. A write through `pgr_ctl` posts the Darwin notification immediately and the change lands at once; only a raw `defaults write` from a terminal waits for the next poll, and that is the path nobody uses when they are in a hurry.
- **Then broadcast.** Having noticed, the server posts the Darwin notification so the app, the widget, and the saver re-read too. The server is the reconciler: external writes come in through it, and everything else learns about them the same way it learns about `pgr_ctl set`.

**No preference ever requires restarting the agent.** This is a hard requirement, and it does not follow automatically from noticing the change — noticing is only half. Every preference needs a defined *apply* action, and "it will pick that up next time it starts" is never one of them.

The trap is timers. The obvious implementation reads the interval once at launch and schedules a `DispatchSourceTimer`; changing the interval from thirty minutes to five then does nothing until the next launch, or at best takes effect in thirty minutes. Correct behavior is to cancel and reschedule on change, computing the next fire from the *last deal* rather than from now — so shortening an interval that has already elapsed deals immediately, and lengthening one does not fire twice.

The rest of the apply table:

| Preference | Applied by |
| --- | --- |
| Rotation interval / dwell | Cancel and reschedule the timer against the last deal time |
| Cache cap | Run an eviction pass now if lowered; otherwise let the queue fill toward the new cap |
| Download concurrency | Next top-up. Fetches already in flight finish on the old setting |
| Repeat window fraction | Next deal; recomputed from the current pool size, no state to rebuild |
| Queue size | Next top-up. Raising it lets the queue grow; lowering it stops producers being asked until serving brings it under |
| Fit, transition, pan speed | The consumer re-renders the *current* photo immediately, so the effect is visible while you are still looking at it |
| Source enabled / disabled | Deck query changes on the next deal; a rescan is queued if the source was newly enabled |

A corollary for the code: nothing reads a preference into a stored property at initialization. Values are read through accessors that reflect current state, so there is no cached copy to go stale and no init-order dependency to reason about. The only thing held across a change is an outstanding hand, deliberately.

**Validate everything read from a preference.** `defaults write` accepts anything — a string where a number belongs, a negative cache cap, a dwell time of zero, a transition name that does not exist. Every preference read is therefore a parse with a default and a clamp, and an invalid value is logged and ignored rather than accepted. This is not defensive programming for its own sake; it is the direct consequence of exposing a typed configuration surface to an untyped command.

**Three domains, which is the part that will waste an afternoon if not written down.** Shared settings live in the App Group suite, backed by a plist inside `~/Library/Group Containers/`. The screensaver reads its own settings from inside the `legacyScreenSaver` container, via `ScreenSaverDefaults(forModuleWithName:)`. And anything written to `com.sydpolk.photogoround` directly — the obvious thing for a person to type — lands in `~/Library/Preferences/` where nothing reads it. The server watches all three, treats the group suite as authoritative, and logs loudly when it sees a value in the third, since that means someone guessed the domain and the guess was reasonable.

On iOS the same App Group suite carries app-to-widget settings, with `WidgetCenter.shared.reloadTimelines` as the wake mechanism. There is no external `defaults write` to worry about there.

## Sandboxing and entitlements ledger

| Target | Sandbox | Notable entitlements / permissions |
| --- | --- | --- |
| Mac agent | No | `NSPhotoLibraryUsageDescription`; App Group (team-ID prefixed); Developer ID + notarization; hardened runtime |
| Mac config app | No | Same; registers the agent via `SMAppService` |
| Mac widget | Yes — extensions must be | App Group; sandboxed despite its host not being |
| `.saver` bundle | Inherited from host | Whatever the Phase 6 spike determines; our entitlements do not apply |
| iOS/iPadOS app | Yes | Photos read, App Group, background processing |
| iOS widget | Yes | App Group |
| tvOS | Yes | App Group; no meaningful persistent storage |
| visionOS | Yes | Photos read, App Group |

The Mac side being unsandboxed is what makes arbitrary folder access, wallpaper setting, and cross-container cache writes possible without security-scoped bookmark ceremony. The iOS side is sandboxed regardless, but there the container model is a natural fit anyway.

## The sandbox contingency

The plan runs the Mac app and agent unsandboxed, which is what Developer ID distribution allows and what makes arbitrary folder access, wallpaper setting, and cross-container cache writes straightforward. But sandboxing may turn out to be forced rather than chosen, and it is worth being clear about what would force it and what it would cost.

**What might force it.** Sandboxing gives the app a container, and containers are what App Groups and extension sharing are designed around. If the Phase 8 spike shows that an unsandboxed host cannot share a group container with its sandboxed widget extension, the cheapest fix is to sandbox the host rather than to abandon the widget. Any future decision to put the Mac app in the App Store would force it outright.

**What it costs.** Four things, in descending order of pain:

- **The screensaver becomes undeliverable from the app.** A sandboxed app cannot write to `~/Library/Screen Savers`. The saver would have to be distributed and installed separately, which means a second signing pipeline and a manual install step.
- **Every folder needs a security-scoped bookmark.** Folder sources stop being paths and become bookmarks that must be resolved inside `startAccessingSecurityScopedResource()` and released after, with a stale-bookmark path to handle. This is the change that reaches furthest into Phase 1 code.
- **Wallpaper setting gets constrained.** `NSWorkspace.setDesktopImageURL` from a sandboxed process needs the image inside the container or reachable via a bookmark, which pushes toward materializing even referenced folder photos.
- **The `legacyScreenSaver` container trick becomes impossible.** Writing into another app's container is exactly what the sandbox exists to prevent, so the screensaver would fall to the HTTP or journal rungs of the ladder.

**The insurance, which is cheap and belongs in Phase 1.** Never construct a `URL` from a stored path at a call site. Every file access goes through a small `FileAccess` abstraction in the kit that takes a source's locator and vends a URL for the duration of a closure. Unsandboxed, it resolves a path and does nothing else. Sandboxed, it resolves a bookmark, starts access, runs the closure, and stops access. The provider code is identical either way, and the decision to sandbox becomes one implementation swap rather than an archaeology expedition through every `URL(fileURLWithPath:)` in the project.

Storing bookmark data alongside the path from the very first commit — even while running unsandboxed and ignoring it — costs one nullable column and removes the need for a migration later. It also happens to be the same column the rename-and-move tracking wants.

## Known shortcomings and leftovers

Recorded rather than remembered. Everything here is a real gap in what is built, found either by running the thing or by auditing after a refactor. Ordered roughly by how much they would cost to leave.

**Wrong behaviour, worth fixing now**

1. **Selection and claim are not atomic.** Picking a candidate and marking it shown are separate statements with a fetch in between, so two producers can pick the same picture. Today that cannot happen — one agent, and a source refuses concurrent work beyond its limit — so this is a property of the deployment rather than of the code. The moment a second process produces, it costs a duplicated download. Cheap to fix by claiming at selection time; wrong to forget.
2. **A file edited in place is never noticed.** The refresh diff compares storage and byte size, so an edit that preserves the byte count — a crop re-encoded to the same length, a metadata rewrite — leaves the stale copy cached for ever. Wants a `modified_at` column compared on refresh, treated as re-fetch rather than as a new entry so it keeps its place in the rotation.

**Dead weight left by refactoring**

3. **`ScanChange` and `ScanResult` are named for a method called `refresh`.** Small, but the vocabulary should be one word.
4. **Seven inspect verbs still live in `photogoroundd`** — `serve`, `status`, `source`, `queue`, `get`/`set`, and the service ones. They are Phase 2's, and the plan already says the service does one thing. Until they move, that claim is true of the default behaviour and not of the binary.

**Cosmetic**

5. **The status line reports cached photos against a cap that some libraries can never approach.** A boot-volume library is referenced in place and never copied, so `0/1000 cached` is correct and reads like a stalled fetch. It should say what is true — that there is nothing to cache — rather than making the reader work it out.
6. **A folder that never existed is reported as "no longer at this path."** The check cannot tell "moved" from "never there", and says the more alarming of the two.

**Done since this list was written**

- `.sourcesChanged` was announced and nobody listened, so a source added from a terminal sat idle until the next scheduled refresh. The agent now observes it and refreshes within a tick — verified against a live agent with the scan interval set to an hour.
- `CacheSettings.chunkSize` and `burstSize` were vestigial after chunked ingestion went, along with their preferences. Removed.
- `Consumer.seenAt` was written and never read; it now backs a `consumerIdleTimeout` so a surface that has stopped asking can be seen. `DarwinNotification.deckAdvanced` was a topic nobody rang; serving now posts it.
- Sources can be named at launch with `PGR_FOLDERS`, so Phase 1 needs no CLI.
- The queue filled at one round of requests per tick rather than re-asking on each answer — four pictures every five seconds against a folder that fills a thousand-entry queue in three. Fixed, and written up under *Filling*.
- A pool smaller than the queue's target had no stopping condition, so a small library meant a producer spinning against a queue that already held everything. It is now paced by the maintenance tick.
- The agent printed a count of sources and nothing about them. It now names each one at startup with its photo count and whether it is recursive, disabled, unavailable, or not yet scanned — the whole class of "it is running but showing nothing" is visible in the first second rather than after a session of reading the log.
- The `run` verb is gone; a bare invocation runs the agent.
- An unavailable source printed its alert at every refresh and, worse, announced itself each time — and the agent observes its own announcements, so a missing folder drove a refresh loop. Both fixed; see *The doorbell rings back at you*.
- Recursion applied to a whole run rather than to each folder, so a flat directory and a nested tree could not be added in one command. Each source now carries its own, defaulting off.
- The tests leaked a preferences plist per run, five hundred of them. Bounded now, and the reason the obvious fix fails is written up under *Testing strategy*.
- `sources changed; refreshing now` was narrating routine work on every doorbell. Removed; what a refresh *finds* is still printed.

**Known and deliberately deferred**

7. **No Xcode project until Phase 3.** A shared scheme in `.swiftpm/xcode/xcshareddata/xcschemes/` gives the package a debugger today, which is enough for the agent. A real project arrives with the Mac app, where the App Group container has to be settled anyway — and doing both at once means the container question is answered by the thing that actually has the problem.
8. **The agent bundle and `SMAppService` are built but out of scope, and ahead of schedule.** `Scripts/make-agent-bundle.sh` assembles an `LSUIElement` app, and the server has `register` / `unregister` / `service-status` verbs. None of it is needed until there is a surface that wakes up on its own and expects the library to be there — the screensaver, the wallpaper, the widgets, and probably the Mac app that registers it on their behalf. Recorded because it exists and because the finding is worth keeping: `SMAppService.agent(plistName:)` reports `.notFound` from that bundle, having ruled out a missing plist, five plist shapes, ad-hoc versus Developer ID signing, and `Bundle.main` resolution. What is left is that the process probably has to be launched by LaunchServices as an app, which is how it will actually be used.
9. **Watching the filesystem is a 1.0 requirement, not built.** See *Watching, and why it comes back for 1.0*: the play-time existence check covers on-demand surfaces completely and pre-rendered ones not at all, so it is needed before the widget in Phase 5 and the Watch in Phase 9.
10. **The migrator refuses a database from a newer build.** Given the database is disposable, deleting and rebuilding would be a friendlier answer than an error — at the cost of one rescan. Worth revisiting when there is a second build to be older than.
11. **The staging run has been minutes, not a day.** A bare run, `source add/list`, `status`, `serve`, and the doorbell have all been driven against a live agent, and a photo deleted mid-run was never served across thirty-two draws. What has not been tested is duration: the gate asks for a detached `screen` left alone for a day, and nothing here has run longer than a few minutes.

## Expect the plan to change, and where it can absorb it

Every phase after the third adds a surface that lives under rules we do not control, and each one is the first genuine test of assumptions made before it. The widget may force sandboxing. The screensaver may force a journal instead of direct database access. tvOS may force a different cache policy entirely. This is not a risk to be eliminated by planning harder — it is the nature of building against five sandboxes — so the useful thing is to know in advance which decisions absorb change cheaply and which ones hurt.

**Seams built specifically to absorb it.** Each of these exists because something downstream is likely to change:

- `FileAccess` — path today, security-scoped bookmark if we sandbox. Isolates the single most likely architectural reversal.
- `HostEnvironment` — storage roots, App Group identifiers, cache caps, chunk sizes. Every platform difference and every container surprise lands here rather than in the kit.
- The source-provider protocol — enumerate and materialize, nothing else. New source kinds are additive.
- The pool API and the queue — a new surface is a new consumer row, and a new source kind is a new provider. Neither reaches into the other.
- The migrator — schema change is a routine operation with a test, not an event to be feared. This is what makes "add a nullable column later" a real answer rather than a hopeful one.
- The transport seam — a consumer reaches the deck through an interface, so one consumer falling back to a journal or an HTTP call does not disturb the others.

**Cheap to revisit later.** Cross-device sync is additive — a nullable identity column and a sync table. Deduplication is additive in the same way. Display modes are new cases in an existing enum. The cache cap and the repeat window are already configuration. Rename-and-move tracking is a column plus a resolver.

**Expensive to revisit, so worth being deliberate about now.** The shared queue versus per-surface queues is a semantic change that reaches the schema and every surface's expectations — it is the decision most worth being sure about. Sandboxing the Mac app is expensive not in code, thanks to `FileAccess`, but in consequence: it changes how the screensaver is delivered and may push wallpaper toward materializing everything. And SQLite itself is effectively permanent, which is fine, because nothing about it is likely to disappoint.

**What that means for this document.** It gets edited as the sequence proceeds rather than written once. A phase that forces a reversal should have the reversal recorded here — in Design Decisions if it changes a decision, in this section if it changes what we thought was safe to assume.

## What changed on the Mac since 2014

Orientation, limited to what actually touches this project. The last external Mac work here predates most of it.

**Distribution is no longer optional ceremony.**

- **Notarization (2019) is mandatory** for Developer ID distribution. Gatekeeper refuses an unnotarized app with a "damaged" error that tells the user nothing. The pipeline is `xcrun notarytool submit` — `altool` was retired in 2021 — followed by `xcrun stapler staple` on both the app and the DMG.
- **Hardened Runtime (2018) is a prerequisite** for notarization, and it means opting back in, via entitlement, to anything it blocks.
- **A paid Developer Program membership is effectively required** to distribute anything at all outside the App Store. In 2014 you could get away without one.
- **Universal binaries** again, arm64 plus x86_64, though for a machine-local project arm64-only is defensible.

**The privacy system did not exist in this form.** Covered separately below — it is the item most likely to bite.

**Things that got better and remove work:**

- `SMAppService` (macOS 13) replaced hand-installed launchd plists and the deprecated `SMLoginItemSetEnabled`. This is what removes the installer.
- Swift ABI stability (2019) means no Swift runtime is embedded in a `.saver` or anywhere else.
- SwiftUI exists, and on the Mac is now genuinely usable for something like this.
- Swift concurrency and, since Swift 6, strict concurrency checking — which is why the kit's API is designed around it rather than around `dispatch_queue_t`.
- Swift Package Manager is the normal way to structure shared code, replacing what would have been a framework target.

**Things that got worse, or at least stranger:**

- Screen savers no longer run in their own process. They are loaded into `legacyScreenSaver`, and inherit its sandbox. This is the single biggest change affecting the plan, and the reason Phase 6 opens with a spike.
- System Settings replaced System Preferences (Ventura), and the wallpaper and screensaver panes were merged and reworked (Sonoma). Anything remembered about how those panes behave is suspect.
- Widgets arrived on the Mac (Big Sur, then on the desktop in Sonoma) — an opportunity rather than a problem, but a whole surface that did not exist.

## Identifiers

`com.sydpolk.photogoround` is the root, and everything hangs off it.

| Thing | Identifier |
| --- | --- |
| Mac app | `com.sydpolk.photogoround` |
| Server (agent) | `com.sydpolk.photogoround.server` |
| Mac widget extension | `com.sydpolk.photogoround.widget` |
| Screensaver | `com.sydpolk.photogoround.saver` |
| iOS app / widget | `com.sydpolk.photogoround` / `.widget` |
| watchOS app | `com.sydpolk.photogoround.watchkitapp` |
| Swift module | `PhotoGoRoundKit` |
| Saver principal class | `@objc(PGRScreenSaverView)` |

Two identifiers are not free choices and are worth writing down before they cause an afternoon of confusion:

- **The App Group must be team-ID prefixed on macOS**: `<TeamID>.com.sydpolk.photogoround`, not `group.com.sydpolk.photogoround`. This differs from the iOS convention, and getting it wrong produces a `nil` container URL rather than an error. It also means the group identifier is not shared between the Mac and iOS builds, so it belongs in `HostEnvironment` rather than in a shared constant.
- **The preferences domain is the group, not the bundle.** Settings shared between the server, the app, and the widget live in the App Group's `UserDefaults` suite, whose backing store is inside `~/Library/Group Containers/`. That collides with the requirement that everything be settable from the command line, because `defaults write com.sydpolk.photogoround …` would write to the wrong place entirely and appear to do nothing.

  Hence a firm rule: **`pgr_ctl` owns preference writes.** It knows the correct domain for each consumer — the group suite for shared settings, and the `legacyScreenSaver` container's own domain for screensaver settings, which is a third location again. The command line requirement is satisfied by `pgr set <key> <value>`, not by raw `defaults`, and `pgr_ctl` posts the Darwin notification afterwards so the change takes effect immediately. Raw `defaults` remains usable by anyone who knows the right domain, but nothing depends on them knowing it.

## TCC: unsandboxed does not mean unrestricted

This corrects something stated too simply earlier in this plan. "Unsandboxed, so arbitrary folder access is straightforward" was true in 2014 and is not true now.

Since Catalina, **even an unsandboxed app needs user consent** to read `~/Desktop`, `~/Documents`, `~/Downloads`, iCloud Drive, removable volumes, and network volumes. The first access triggers a prompt attributed to the requesting application; denial is remembered, and the failure afterwards is a plain permission error rather than anything self-explanatory. Photos access is a separate consent again, with its own prompt and its own entry in Settings.

Three consequences for the design:

- **Consent is keyed to a code-signing identity, so two bundles mean two prompts.** The app and the agent are separate bundles with separate identities, and would each need their own Photos grant and their own Files-and-Folders grant — the user consenting twice to the same thing, with the second prompt arriving from a process they cannot see.

  The server architecture already solves this, and it is worth naming as a benefit rather than leaving as an accident: **only the server ever touches files or the Photos library.** The app is a window that reads the deck and displays cards; it opens no photo and enumerates no folder. One bundle holds every privacy grant, prompts once, and appears exactly once in each Settings list.
- **A headless agent prompting is bad ergonomics.** A TCC dialog attributed to a background process with no window, possibly minutes after the user did anything, is confusing. So `pgr_ctl` and the app should both be able to trigger the server's first access *on demand*, at a moment the user is looking at the screen and has just asked for the folder to be added — the prompt then arrives in context even though it names the server.
- **Full Disk Access is the escape hatch, not the design.** Granting it in Settings sidesteps every folder prompt at once, and is a perfectly reasonable thing to do on a personal machine. It should never be a requirement, and the software should work correctly without it, prompting per-folder as needed.

Adding this to the entitlements ledger: the server carries `NSPhotoLibraryUsageDescription` and needs Files-and-Folders consent; the app and `pgr_ctl` ideally carry neither, because they never touch either resource.

## Shipping it: 1.0 distribution and updates

A 1.0 concern only. 0.1 runs from Xcode.

### An installer is probably unnecessary

The instinct that a LaunchAgent needs an installer is a correct instinct about the old world. `SMAppService.agent(plistName:)` was introduced precisely to end it: the agent's plist lives inside the app bundle at `Contents/Library/LaunchAgents/`, the app registers it with one call, and the user sees and controls it in System Settings → General → Login Items. No `launchctl`, no writing to `~/Library/LaunchAgents`, no privileged install step, and — importantly — no uninstaller to write, since unregistering is also one call and deleting the app is most of the story.

So the pieces resolve like this:

- **The app** ships in a notarized, stapled DMG. Drag to `/Applications`.
- **The agent** registers itself on first launch via `SMAppService`. Nothing to install.
- **The screensaver** is the one piece that genuinely needs placing, into `~/Library/Screen Savers/`. Unsandboxed, the app can simply copy it there itself, which is better than making the user find and double-click a `.saver`. If we ever sandbox, this stops being possible and the saver ships as a separate download — which is already noted as one of the costs of sandboxing.

A `.pkg` installer buys only two things we do not need: installing for all users, and having the agent running before the app is ever launched. Against that it costs a second signing and notarization pipeline, a receipt to reason about, and an uninstall story. Worth revisiting only if the DMG route turns out to trip on something concrete.

### Updates, and the Sparkle problem

Not being in the App Store means no update mechanism comes for free, and Sparkle is the obvious answer — it is the de facto standard for Developer ID Mac apps, it is well built, and it handles EdDSA-signed appcasts, delta updates, and atomic replacement correctly.

It is also a third-party dependency, which collides directly with the rule that the only things outside our own code are Apple's frameworks and the photo libraries. That collision should be resolved deliberately rather than by reflex in either direction, because both reflexes are wrong here:

- **Reflex one: take Sparkle, it is standard.** Reasonable, but it is a large framework that runs privileged-ish code paths, and it is the single largest thing we would ever link.
- **Reflex two: hand-roll it, we hand-roll everything else.** This is the one place where the no-dependencies instinct is dangerous. An updater downloads and executes code. Getting signature verification, replacement atomicity, and quarantine handling right is security-critical work in a way that a SQLite wrapper is not — a bug in the migrator loses data, a bug in the updater runs someone else's binary.

**The third option is the recommended one: do not auto-update at all.** A "check for updates" that fetches a small JSON file from the GitHub releases API, compares versions, and — if newer — shows a notice and opens the release page in the browser. The user downloads the DMG and drags it over, exactly as they installed it. That is perhaps fifty lines, has no dependency, and has no security surface whatsoever, because we never download or execute anything: we open a URL.

For an application with a user base of one, that is not a compromise, it is the correct engineering. If it ever ships to strangers who will not tolerate manual updates, Sparkle becomes the deliberate exception, taken with eyes open and documented here as such.

## Beyond 0.1

Everything in the phase list is 0.1. The display richness below is held back deliberately, so that 0.1 ships one fit, one layout, one transition, and gets used.

### Can we reuse Apple's screensaver transitions?

No. `ScreenSaverView`'s public API contains no transition library at all — it gives you a view, a timer, and nothing else. The transitions people admire in Apple's photo screensavers (Ken Burns, Shifting Tiles, Sliding Panels, Vintage Prints) live in private frameworks of the `iLifeSlideshow` family. Linking against those is not shippable and would break without warning.

There was one supported way to get them anyway — maintain a folder of full-resolution photos and point Apple's built-in photo screensaver at it — and it is rejected on principle rather than on mechanics. See *Alternatives considered and rejected*: we control the content, entirely, or the project has given away the thing it exists to do.

So we write our own `.saver`, and its transitions are ours. That is why Phase 6 stays, sandbox spike and all.

The upside of owning it is that the transition list can start at one. A cross-fade is enough for 0.1 — the pan already supplies most of the motion, and every photo screensaver worth watching is mostly cross-fade anyway. Ken Burns, slides, and tiled collages come later, as items in an enum, tuned in the Mac app's full-screen window where a debugger works.

### Features versus architecture

The governing rule, and it is a rule rather than a hope: **nothing in this section may require a change below the display layer.** From that follows a test for whether a piece of work deserves a phase or is merely a feature.

**Architecture — the first instance of a new class of surface.** The first widget is real work: App Group container resolution across a sandbox boundary, timeline budgets, the memory ceiling, writing small files for an outstanding hand. The first `.saver` is real work: someone else's sandbox, and a transport that may not be the database. Those earn phases.

**Features — every instance after the first.** Once widgets work, more widgets are sizes and layouts. Small, medium, large, Lock Screen, Notification Center, desktop, Smart Stack — each is a new `WidgetFamily` case, a SwiftUI view, and a consumer row. No new mechanism, nothing below the display layer touched. The same is true of display styles: a new fit, a new transition, a tiled layout, a collage is an enum case plus a renderer that receives a decoded image and a rectangle. And of sources: once the provider protocol exists, a new source kind is a provider, which is why Google Photos is a late phase only because of its OAuth flow, not because of anything structural.

**The warning signal.** If something that looks like a feature seems to need something from the library layer, either it is smuggling in a new capability or the layering has drifted. Video is the known example — it presents as just another display style and is in fact a capability reaching down to per-consumer filtering in the deal query, which is exactly why it is a 2.0 item rather than an entry in a transitions list.

The practical consequence is that this whole section is safe to defer indefinitely and safe to pick from in any order, one item at a time, whenever one sounds fun.

### Display styles

Per-surface, and different for the screensaver and the wallpaper, since a photo you look at for two seconds and one you look at for an hour want different treatment:

- **Fits** beyond shrink-or-expand: fill and crop, center at native size, and an upscale cap that stops a small photo from being enlarged into mush.
- **Aspect-ratio handling** for the letterbox: pure black today; blurred-and-scaled fill of the photo itself, or a color sampled from the image, later.
- **Tiling**, for small images and for deliberately patterned wallpaper.
- **Multi-photo layouts** on the screensaver — the collage and grid arrangements that make Apple's versions pleasant.

### Timing and transitions

If we do write our own saver: dwell time, transition style, transition duration, pan speed and whether to pan at all, and cycle time — each per surface, since the wallpaper's half hour and the screensaver's ten seconds are unrelated numbers.

### Everything user-settable is a user default

All consumer-facing settings live in `UserDefaults` in a shared suite, not in the database, so that `defaults write` is a first-class interface on the Mac rather than an escape hatch. This is a refinement of the earlier "config in the database" decision, and the split is clean: **the database holds state — sources, deck, cache, hands; `UserDefaults` holds preferences — fits, timings, transitions, caps.** State is what the system knows; preferences are what you told it.

Two things to get right:

- **A Darwin notification still does the waking.** `UserDefaults` change observation is unreliable across process boundaries, so a writer posts a notification and readers re-read. `pgr_ctl` posts it after any write, so `defaults write` followed by `pgr notify prefs` takes effect immediately rather than at the next poll.
- **The screensaver's preference domain is not where you think it is.** A `.saver` running sandboxed inside `legacyScreenSaver` reads preferences from that host's container, not from `~/Library/Preferences/`. `ScreenSaverDefaults(forModuleWithName:)` exists to handle exactly this, and it means a plain `defaults write` from the terminal will appear to do nothing to screensaver settings until it is aimed at the right domain. Worth a `pgr_ctl` subcommand that writes to the correct place so the right path is discovered once rather than every time.

## Alternatives considered and rejected

- **Core Data with CloudKit sync.** Would give free cross-device sync, but the multi-process constraint kills it on the Mac and the deck logic fights the object graph.
- **Writing the core in C or C++.** You floated this. It would be portable beyond Apple platforms, but every consumer here is Swift, the Photos and WidgetKit APIs are Swift-or-Objective-C anyway, and Swift 6 concurrency is a better fit for the fetch pipeline than hand-rolled threading. Reconsider only if a Linux or Windows surface ever matters.
- **A single monolithic app with no agent.** Simpler, but nothing updates the deck when the app is not running, and the screensaver would have no data source. The agent is what makes the wallpaper schedule real.
- **A directory watcher on the preferences plist.** Replaced by a thirty-second poll. `defaults` writes through `cfprefsd`, which replaces the plist atomically via rename, so a vnode source has to be re-armed on every replace or it silently stops working after the first write — a whole class of bug, bought in exchange for latency nobody can perceive on a dwell time or a cache cap. `pgr_ctl set` rings the doorbell anyway, so the blessed path is still instant.
- **Watching folder sources — rejected for 0.1, then reinstated for 1.0.** Worth recording as a reversal rather than quietly amending, because the reasoning changed rather than the facts. Rescanning was measured and is genuinely free (2.4 seconds per twenty thousand photos, invisible to a concurrent consumer), so watching bought only latency and was cut. It came back when the never-show-a-deleted-photo requirement arrived from a different direction entirely: the play-time existence check protects on-demand surfaces completely, and pre-rendered ones not at all. See *Watching, and why it comes back for 1.0*.
- **Reusing Apple's screensaver by feeding it an album.** Considered and dismissed: you cannot control its download behavior, which is the actual bug being worked around.
- **Reusing Apple's screensaver by feeding it a *folder* we maintain.** A much stronger version of the above, and genuinely tempting. The server would keep a directory of full-resolution photos and point the built-in photo screensaver at it — Apple renders, we curate. It would have dissolved the hardest problem in the plan: no `.saver` bundle, so no `legacyScreenSaver` sandbox, no container-path archaeology, no consumption journal, no Phase 6 spike. It even fit the consumer model cleanly, since a folder is just a hand made of files. The user-picks-a-file problem it creates was solvable too, by rotating *contents* behind fixed slot filenames — `slot-001.heic` and friends, overwritten in place — so a reference never breaks and only the picture changes.

  Rejected anyway, and for the reason that outranks all of that: **we are the complete controllers of the content.** Handing the folder to Apple gives away ordering, timing, and which photos actually appear, and returns no feedback about what was shown — so the deck cannot honestly advance, and the shuffle we went to all this trouble to build stops being the thing on screen. Every mitigation above is a workaround for having ceded control that we should not have ceded. Owning the saver costs a sandbox spike and a cross-fade; it buys the entire point of the project.

  It also fails on its own mechanical terms, which is worth recording separately from the principle. Apple's screensaver selection GUI chokes on folders containing large numbers of pictures — one of the original motivations for this project — so the approach depends on the very component already known to be broken. The slot design happens to dodge it, since a few hundred fixed slots stay small no matter how large the library behind them grows, but relying on a workaround to stay inside the limits of a UI that already fails at this exact task is not a foundation.

  Kept here in full, mechanics and all, because it is the standing contingency: if the Phase 6 spike shows a saver cannot reach the deck by any of the four mechanisms and the consumption journal turns out unworkable, this is the fallback that still puts full-resolution shuffled photos on the screen. Worse, but not nothing, and already designed.
- **A real local cache on the Watch.** Technically possible — carve out space and keep a proper rolling library on-device. Declined, because it buys less than it appears to: the Watch still has no sources, so a bigger cache still has to be filled by the phone. All the extra storage purchases is more variety while out of range of the phone, in exchange for a second cache with its own eviction policy on the most storage-constrained device in the lineup. The small rolling set stays.

  One argument *against* it that does not hold, recorded so it does not get re-invented: that it would force us to down-convert images to the watch's resolution when we do not have to anywhere else. Down-conversion happens everywhere — it is what a subsampled decode to display size *is*, on every platform, for every photo. The watch's copies are produced on the *phone* in either design, so a local watch cache would add no new kind of work and move no resizing onto the watch. The reason above is the real one.

# References

- `PHAssetResourceManager` and `PHAssetResourceRequestOptions.isNetworkAccessAllowed` — the fix for low-resolution iCloud fetches.
- `SMAppService.agent(plistName:)` — modern LaunchAgent registration, macOS 13+.
- `NSWorkspace.setDesktopImageURL(_:for:options:)` — per-screen wallpaper.
- SQLite WAL mode and concurrency — <https://sqlite.org/wal.html>; `BEGIN IMMEDIATE` semantics — <https://sqlite.org/lang_transaction.html>
- `PRAGMA user_version`, the basis of the hand-written migrator — <https://sqlite.org/pragma.html#pragma_user_version>
- `CFNotificationCenterGetDarwinNotifyCenter` — cross-process, cross-sandbox change notification.
- WidgetKit timeline reload budgets — relevant to the iOS deck-advance design.
