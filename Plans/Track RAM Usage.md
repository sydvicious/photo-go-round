# Summary

A running record of how much memory the agent, the wallpaper extension and the screensaver hold, written by each of them every five minutes, so a leak shows up as a trend rather than as a machine that has gone slow.

# Rationale

All three run for days without anybody looking at them — the agent under launchd, the wallpaper extension whenever `WallpaperAgent` wants a picture, the screensaver for as long as the Mac is idle — and all three hold image bytes. A leak in any of them is invisible until it is large, and the moments when Syd would notice are exactly the moments a developer restarts the process and destroys the evidence. Sampling before each restart costs nothing and turns "it feels heavy" into a number beside a date. Syd, 2026-09-17: "I want a running tally to make sure that there are no leaks from the agent, the screensaver agent, or the wallpaper extension."

# Phases

*Phases 1 to 3 are built; 4 and 5 are proposals, and nothing under them is decided.*

- **Phase 1 — Sample before every restart.** Whenever Claude asks Syd to reinstall or reboot, it first records each process's memory and how long it had been running, and appends it to the record. **In use since 2026-09-17**; the table below is it.
- **Phase 2 — A record with a shape.** Decide where the samples live and in what form, so a trend can be read without re-reading a transcript. **Answered by Phase 3**: the log is the record.
- **Phase 3 — Each service logs its own, every five minutes.** Syd, 2026-09-18: "what we should be doing is logging the RAM usage every five minutes", and "for all three of the permanent services". **Built 2026-09-18**; see *Built: the services say what they hold*.
  - The agent's dashboard has a panel for its own. Syd: "the agent dashboard should have a panel for RAM usage."
- **Phase 4 — The agent reads the other two out of the log.** Syd, 2026-09-18: the agent should read the logs for the wallpaper extension and the screensaver and report their RAM in the dashboard, so one page answers the question for all three. See *The agent reads the other two*.
- **Phase 5 — Say when it looks wrong.** Decide what counts as growth worth reporting, and where that is said. Still open, and better answerable now that there is a curve rather than two points.

# Design Decisions

*All proposals; none decided.*

- **Footprint is the number**, not resident size. *Proposed as `ps -o rss`, and reversed on 2026-09-18 by measuring both.* `phys_footprint` is what `footprint(1)` prints and what the kernel charges against a memory limit; `rss` counts pages the allocator has been given back and has not returned. See *What `rss` was hiding*.
- **Each service reads its own**, through one `task_info` call — no subprocess, nothing to install, and it works inside the screensaver's sandbox and the extension's.
- **The log is how the three meet.** Nothing can ask another process what it holds, but all three write the same `MEMORY:` line to the same subsystem, so a reader of the log has all of them. That makes the dashboard's panel a reading problem rather than a protocol one — no endpoint, no reporting-in, nothing for a stopped service to fail to do.
- **Uptime goes with it.** 110 MB after nine minutes and 110 MB after nine days are different facts.
- **Sampled before the restart**, never after: the restart is what destroys the evidence.
- **The three processes are the agent (`photogoroundd`), the wallpaper extension (`Photo-Go-Round Wallpaper`) and the screensaver's host.** The app is Syd's own window and he can watch it in Activity Monitor.
- **The record is in the repository**, so the trend survives the session that produced it.

# Background

- The agent holds the queue, the cache index — one entry per cached photograph — and whatever a request is streaming. The index at launch is now built from the database, so its size follows the number of cached photographs, currently about 300.
- The wallpaper extension keeps the last picture it showed for each surface, and a generated placeholder.
- The screensaver runs inside `legacyScreenSaver`, which hosts other savers too, so its number is not ours alone.
- Nothing measures any of this today. The first two samples, taken while writing this plan on 2026-09-17: the agent at **113 MB** after 9 minutes, and the wallpaper extension at **53 MB** after 9 minutes.

## Samples

Taken before asking Syd to reinstall or reboot. **Every figure here is `ps -o rss`**, which on
2026-09-18 turned out to overstate by roughly double — see *What `rss` was hiding*. Superseded
by the five-minute `MEMORY:` lines, and kept because it is the only record of the days before
them.

| When | Agent | Wallpaper extension | Screensaver | Note |
|---|---|---|---|---|
| 2026-09-17 16:18 | 113 MB, 9 min | 53 MB, 9 min | not running | first sample |
| 2026-09-17 16:41 | 157 MB, 23 min | 134 MB, 23 min | not running | before installing Phase 5's first slice |
| 2026-09-17 17:51 | 101 MB, 1 h 18 min | 57 MB, 1 h 43 min | not running | before installing Phase 5's second slice |
| 2026-09-17 19:20 | 150 MB, 1 h 28 min | 104 MB, 3 h 12 min | not running | before installing the evictor |
| 2026-09-17 22:35 | 213 MB, 3 h 14 min | 140 MB, 6 h 27 min | not running | before installing Phase 5's last slice |
| 2026-09-17 23:20 | 268 MB, 27 min | 234 MB, 7 h 12 min | not running | before installing the finished Phase 5; the agent's steepest climb yet |
| 2026-09-18 00:12 | 192 MB, 18 min | 197 MB, 8 h 04 min | not running | before a reboot and a full reinstall |
| 2026-09-18 00:33 | 82 MB, 29 s | 45 MB, 16 min | not running | after the first reboot, before the second |
| 2026-09-18 07:43 | 531 MB, 6 h 59 min | 163 MB, 6 h 59 min | not running | overnight, and the last `rss` sample: `footprint` said 299 MB and 163 MB, with 181 MB of the agent's reclaimable |

*The second pair is the same two processes half an hour older: the agent up 44 MB, the extension up 81 MB. Both had been serving pictures throughout — the extension changes its picture every ten minutes — so this says nothing yet. It is the shape of the next few days that will.*

# Detailed discussions

## What a sample is

`ps -o pid,rss,etime` for each process gives resident kilobytes and elapsed time in one line and needs nothing installed, nothing entitled, and no cooperation from the process. Resident size is not the whole story — it excludes what has been paged out and includes what is shared — but it is the number that goes up when something is leaking, and comparing it against itself over days is what this is for.

`footprint` and `vmmap -summary` give a truer figure (dirty, compressed, swapped) and cost a second per call. Worth using when a sample looks wrong, rather than on every restart.

## Where the record goes

Options, unpicked:

- **A section in this plan**, appended to. Simple, and the plan becomes a log — which `PLAN.md` already is for decisions.
- **A file of its own**, `Documentation/ram.md` or a CSV in the repository. Easier to read as a trend; one more thing to keep tidy.
- **Nowhere durable**: the unified log. The agent could log its own resident size on a timer, which makes the sample a property of the agent rather than of the developer's habit — and the log is already where Syd reads everything else. It also survives a restart, which the other two do not: `log show --last 7d` would draw the curve.

The third is the most useful and the most work, and it makes the process measure itself, which is the only version that keeps working when nobody is watching.

## Built: the services say what they hold

*2026-09-18, at Syd's "what we should be doing is logging the RAM usage every five minutes", "for all three of the permanent services", and "the agent dashboard should have a panel for RAM usage".*

- **`Footprint`** in `PhotoGoRoundAgentAPI` reads `phys_footprint` and `resident_size` from `task_info(TASK_VM_INFO)` — one call, no subprocess — and keeps the largest footprint seen since launch. Every reading raises that mark, whoever took it.
- **`Footprint.startLogging` is once per process**, guarded by an `Atomic`, so a service with several entry points can call it from all of them: the wallpaper extension does from `PaneHandler.init`, the screensaver from `startAnimation`, the agent from `RunCommand` once it is listening.
- **One line, three voices.** `MEMORY: footprint 299 MB · resident 531 MB · up 6h 59m`, written to each service's own log. `log show --predicate 'subsystem == "com.sydpolk.photogoround"' | grep MEMORY:` reads all three at once, and survives a restart, which the table below does not.
- **The dashboard panel is the agent's own.** It shows footprint, the peak since launch, and resident size underneath, and says so: nothing reports another process's memory, because nothing has any way to ask.
- **Tests:** the reading is plausible and footprint never exceeds resident, the peak only rises, the line names both numbers and the uptime, and the interval is five minutes.

## What `rss` was hiding

The first samples in the table above are `ps -o rss`, and they overstate by roughly double.

Measured 2026-09-18 on the agent after **6 h 59 min**, 1,777 fetches, 1,640 pictures served and 1,334 eviction passes:

| | |
|---|---|
| `ps -o rss` | **531 MB** |
| `footprint` | **299 MB** |
| of which `Malloc Large`, dirty | 221 MB |
| of that, **reclaimable** | **181 MB** |

So the live figure was nearer **120 MB**, and the rest was the allocator holding large freed blocks — which is what an allocator does with the multi-megabyte buffers an image pipeline churns through. The overnight run had no errors and the cache sat exactly on its 1 GB ceiling.

That does not close the question. What it does is move the baseline: a climb is now something above roughly 120 MB of footprint, not something above 100 MB of `rss`, and the five-minute line is what will show whether there is one.

## The agent reads the other two

*Syd, 2026-09-18: the agent should read the logs for the wallpaper extension and the screensaver and report their RAM in the dashboard. Nothing below is decided.*

The panel the agent has today shows the agent, and says so, because a process cannot ask another one what it is holding. What changed on 2026-09-18 is that all three now write the same line to the same subsystem — so the agent does not need to ask anybody. It needs to read.

### How it would read them

- **`OSLogStore`**, in process. The clean version, and the one to try first. `OSLogStore(scope: .currentProcessIdentifier)` sees only our own entries; reading everything the system has takes the wider scope, which on macOS has historically wanted privilege the agent does not have. **Measure it before designing around it** — the agent is unsandboxed and runs as Syd, which may be enough.
- **`/usr/bin/log show --predicate … --last 10m`**, as a subprocess. Certain to work, since it is what Claude has used all week, but it is a process spawn and a parse, so it belongs on a timer rather than on a dashboard request.
- **Neither, and have them write a file.** Each service already knows its own number; a small file per service in the container would need no log reading at all. It trades one problem for another — a stale file looks exactly like a stopped service — and it puts state where the log already is.

### What a reading means when nobody is running

This is the part that decides how the panel reads, and it is a design question rather than a technical one.

- **The wallpaper extension** is alive only while a surface exists, which is most of the time but not all of it.
- **The screensaver** runs only while the Mac is idle, inside `legacyScreenSaver`, which hosts other savers too — so its number is not ours alone, and for long stretches there is no number at all.
- So each row wants a *when*, not just a figure: `screensaver 61 MB, 3 hours ago` says something true, and `screensaver 61 MB` does not. A service that has never run in the window the agent looked at should say that rather than show a zero, which is the same mistake the `wallpaper 0` row made.

### How often

A reading every five minutes matches what the services write, and costs one read of the log. Doing it on each dashboard request would be wasteful — the page refreshes far faster than the lines arrive — and would make a `log show` subprocess part of serving, which is exactly the kind of thing the agent has spent the week getting off its request path.

## What growth would look like

The agent's resident size should track what it is holding: the cache index (a few hundred entries), the queue (twenty cards), and one request's bytes at a time. None of that grows with uptime, so a figure that climbs across days with a steady library is the signal. The known suspects, in order:

- **A request's bytes not released** — the one path that touches megabytes per request, and the one with a streaming file body.
- **The resize cache's rendered bytes**, held between the resizer finishing and the copy being written.
- **PhotoKit's own caches** inside the agent, which are not ours but are ours to notice.

The wallpaper extension holds one picture per surface by design, so its floor rises with the number of displays and should be flat otherwise.

## When to sample

Every time Claude asks for a restart is the rule Syd gave, and it has a useful property: those are the moments with the longest uptimes, since they follow a stretch of work. It is also biased — a day of heavy development produces many short-lived samples and no long ones. Phase 3's periodic sample is what fixes that, and the agent logging its own figure is the cheapest version.

# References

- `TODO.md`, *Track RAM usage*.
- `Plans/Agent Performance Overhaul.md` — the cache index at launch, and what the agent holds.
