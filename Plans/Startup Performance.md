# Summary

After a boot, the agent should show every photograph it can as soon as it can. The first piece of work: Photos albums that a cold library is slow to answer no longer drop out of the deal for five minutes.

# Rationale

Syd, 2026-09-23: "it seems like the most hostile environment on the Mac is while it is starting up." The same boot showed it: every step before the port opens took 100 to 300 times longer than it does warm, and `photolibraryd`, iCloud and the disk cache were all starting up alongside the agent. Yet a boot is when the screensaver and wallpaper are first on screen, often before anyone sits down. On 2026-09-23 both Photos albums were marked *Photos is not responding* forty seconds after a reboot. The pool fell from 9,184 photographs to 701 until the next scan, five minutes later. Photos was not stuck. It was just starting, and by the time anything asked again it answered in well under a second.

# Phases

- **Phase 1 — Photos albums that a cold library is slow to answer. Built, and verified on a reboot, 2026-09-23 on `startup-performance`.**
  - A walk may take 60 s to produce its first photograph; each gap after that is still 10 s.
  - An album Photos did not answer is walked again after 30 s, 60 s, 120 s and 240 s, then left to the normal scan.
  - Every album walk leaves a `WALK:` line: how long the first photograph took, how many arrived, and the total time.
  - *Verified* on the 19:52 reboot: neither album went unavailable, and the pool stayed at 9,184. The first photographs took 38.3 s and 47.2 s. The retries were not needed, so they are tested only by `RetriesTests`.

# Design Decisions

- **The first photograph gets its own bound, 60 s.** Before the first photograph arrives, the album has to be looked up and fetched, and a library that is just starting is slow at that, not stuck.
- **Silence is its own result, `SourceReachability.unanswered`.** It does to photographs exactly what `.unavailable` does. It exists so the retry has something to go on without matching the words of the reason.
- **Only silence is retried early.** An unplugged drive won't be back in thirty seconds, so asking it early is wasted work.
- **The wait doubles, then stops at the scan interval.** A library that stays silent costs four extra walks and then nothing.
- **Every walk reports to the retry list, scheduled scans included.** Whichever walk reaches an album first settles it.
- **Retries run in a task of their own.** A retry never holds up the scan, and the existing one-walk-per-source guard stops two walks of the same album overlapping.
- **`WALK:` is logged at `.notice`.** That is a few hundred lines a day, and it has to be kept, because the walk that matters is the one right after a boot, when nobody is watching.
- **Cached photographs from an unavailable source stay in the deal.** That was already the rule, in `Deck.swift`'s eligibility query. The boot at 19:28 kept about 149 of them. Unchanged.

# Background

- This plan picked up the `TODO.md` item *Photos albums stay "not responding" for up to five minutes after the agent starts*, first seen at the 2026-09-19 17:46 install. The item was removed once the 19:52 reboot verified the fix.
- `BoundedPhotoLibrary` has bounded every PhotoKit call since 2026-09-12. Its 10 s bound applies to the silence between photographs in a walk, and that includes the wait for the first one. `PLAN.md`, *TODO: a wedged Photos library freezes the agent*.
- **Related, and not part of this plan:** the screensaver got no picture in the first four minutes after the same boot. It asked four times, and each cached photograph took longer to serve than its 5 s limit, when one was served at all. See `TODO.md`, *The screensaver's first picture after a boot is late*.

# Detailed discussions

## What the boot at 19:28 on 2026-09-23 showed

The Release agent, pid 920, from the unified log:

- 19:28:34, first `STARTUP:` line. 19:28:48, listening, after a cold 12.8 s: `open` 3.7 s, `index` 6.3 s, `wiring` 2.6 s. Warm, the same steps total 43 ms.
- 19:29:07, the first refresh starts on all five sources, local folders first.
- 19:29:20 and 19:29:21: `library did not answer enumerateImages within 10 seconds`, once for each album. Both albums are marked unavailable, with the reason *Photos is not responding.*
- 19:29:46: `701 in pool`, down from 9,184. That is the 552 folder and file photographs plus about 149 cached Favorites, which the deal keeps.
- 19:34:25, the next scheduled refresh: both albums come back. The 80-photograph album took 2.4 s, the 8,552-photograph one 10.5 s.

Each walk stopped about 12.5–13.3 s after its `refreshing` line. The 10 s bound started only after the walk's authorization check, so both walks were silent for the whole bound before their first photograph. Nothing then asked again until the scan interval, 300 s.

## What the boot at 19:52 on 2026-09-23 showed

The first reboot with Phase 1 installed: a Release agent, pid 906, with `persist:info` set for the subsystem, so the `TIMING:` lines were kept.

- 19:52:43, listening after 3.3 s: `open` 551 ms, `index` 2.1 s, `wiring` 441 ms. The boot at 19:28 took 12.8 s, so cold starts vary a lot from one boot to the next.
- 19:53:00.7, both albums start their walks.
- 19:53:41, `WALK: A670E2FA… · first asset 38334ms · 80 assets · 39000ms`. The album was refreshed at 19:54:00, 59.8 s after it started, with the last 20 s spent on writes after the walk.
- 19:54:48, `WALK: EE63D18C… · first asset 47216ms · 8552 assets · 105433ms`, refreshed at 107.9 s. Warm, the same walk takes 10.5 s.
- **Neither album went unavailable, so nothing was retried.** Every status line reads `9184 in pool`.
- Other Photos calls also went unanswered while the library was cold: `title` at 19:53:10 and 19:53:35, and `resources` at 19:53:23. The `resources` stall made a cached copy of a Favorites photo fail. Those calls still have the 10 s `metadataLimit`.
- The first pictures served: the wallpaper's, at 19:53:02, took 6.2 s, with every step taking hundreds of milliseconds (`open 593 · queue 532 · check 801 · remove 886 · resize gave up 1869`). The screensaver's, at 19:54:37, took 2.3 s, most of it the resize giving up at 1.6 s. Both are recorded in `TODO.md`, *The screensaver's first picture after a boot is late*.

## Why a first-photograph bound, and not a longer gap

`SystemPhotoLibrary.enumerateImages` resolves the collection, calls `PHAsset.fetchAssets`, reads the count, and faults in the first batch from `photolibraryd`, all before it hands over a single photograph. So the first wait covers a different amount of work from every later one. A later gap is one batch being read. The first is the whole setup, done against a daemon that may have been started a moment ago.

Raising the gap bound for the whole walk would have fixed the boot too, but it would weaken the check on a library that stalls part way through a large album. The 2026-09-07 migration case, which `SilentLibraryTests` pins, needs that check. Keeping the gap at 10 s and giving only the first wait 60 s leaves that case unchanged.

60 s started as a guess. The 19:52 boot measured it: first photographs arrived at 38.3 s and 47.2 s, four to five times the old bound, with 13 s to spare under the new one.

## The `WALK:` line

`WALK: <collection id> · first asset <ms|none> · <n> assets · <ms>`, with `· stopped` added when the walk threw. It is logged by `BoundedPhotoLibrary.enumerateImages` in the `photos` category, whether or not the walk finished. `first asset none` means nothing answered at all. For an empty album, `first asset` is the time until the walk ended.

## The retry, in detail

`Retries`, in `MacOS/Agent/Sources/Retries.swift`, is an actor. The caller supplies the time, as with `Heartbeat`.

- `heard(result, at:)` is called after every walk, from both the scheduled pass and a retry. If the result is `unanswered`, the failure count goes up and the time is recorded. Any other result forgets the album.
- `take(at:ceiling:)` runs once per tick, from the loop's `.refresh` case, before the scheduled pass's own check. It returns the albums that have waited long enough and marks them *in flight*, so the next tick doesn't hand them out again while their walk runs. An album whose next wait would reach the ceiling is forgotten instead. The ceiling is the scan interval, read on each tick because a preference can change it.
- The loop runs the returned albums through `runRefresh(only:retries:)` in a detached task, and prints `retrying #1 #2, which did not answer`.
- **If a scheduled pass is already walking the album**, the per-source `refreshing` guard drops the retry's walk. The album stays in flight until the pass's own walk reports, and that report settles it.
- **An album removed or disabled since it failed** is not in the enabled list, so `runRefresh` calls `forget` for it. Nothing else would ever report on it.
- **`--once` doesn't retry.** A single pass has no next tick.

The waits run 30, 60, 120 and 240 s. A fifth wait would be 480 s, which is past the 300 s default scan interval, so after four failed retries the album goes back to the normal scan. Every retry walks only the silent album. The folder sources are not walked again.

## Tests

- `FirstAssetBoundTests`: a walk slower to start than the gap bound still finishes. A walk that never starts is ended by the first-photograph bound, not the gap bound. The `WALK:` line's format. Neither test can fail on a loaded machine: the slow case sits a minute under its bound, and the silent case never answers.
- `RetriesTests`: the backoff, due at 30 s rather than at the next scan, in-flight albums not handed out twice, the doubled wait after a second silence, an answer forgetting the album, an unplugged drive not being retried early, and the ceiling.
- `SilentLibraryTests`: its four library helpers pass `firstAsset:` explicitly, so a hanging walk still fails in 100 ms and not 60 s. Its two tests of a silent walk now expect `.unanswered`.

## Still open

- **The margin is 13 s.** A boot slower than the one at 19:52 could still take the large album past 60 s. If it does, the retries catch it after 30 s, but no reboot has exercised them yet. Raising the bound further is the alternative; one boot's measurement is not much to decide on.
- **Other Photos calls on a cold library.** `title` and `resources` went unanswered in the first minute of the 19:52 boot, under the 10 s `metadataLimit`. That cost one cached copy. Whether those calls need boot-time patience too is not decided.
- **Whether the slow add of 26 albums on 2026-09-21 has the same cause.** On a Release agent a minute old, adding them took more than 15 s. It looks like the same cold daemon, but that log hasn't been read.
- **The 8,552-photograph album walks in 10.5 s even warm.** That isn't a fault, since no gap came near 10 s, but it is more than the "handful of milliseconds" the metadata bound was sized against.

# References

- `TODO.md`, *The screensaver's first picture after a boot is late*. The *not responding* item this plan picked up has been removed; git has it.
- `PLAN.md`, *TODO: a wedged Photos library freezes the agent*.
- `Agent Performance Overhaul.md`, which has the `STARTUP:` line and the boot-to-serving measurements.
- `Release App Installer.md`, the 2026-09-21 album add that took more than 15 s.
- The unified log for pid 920, 2026-09-23 19:28–19:35, and for pid 906 from 19:52, subsystem `com.sydpolk.photosgoround`.
