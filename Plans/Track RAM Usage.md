# Summary

A running record of how much memory the agent, the wallpaper extension and the screensaver hold, sampled every time one of them is about to be restarted, so a leak shows up as a trend rather than as a machine that has gone slow.

# Rationale

All three run for days without anybody looking at them — the agent under launchd, the wallpaper extension whenever `WallpaperAgent` wants a picture, the screensaver for as long as the Mac is idle — and all three hold image bytes. A leak in any of them is invisible until it is large, and the moments when Syd would notice are exactly the moments a developer restarts the process and destroys the evidence. Sampling before each restart costs nothing and turns "it feels heavy" into a number beside a date. Syd, 2026-09-17: "I want a running tally to make sure that there are no leaks from the agent, the screensaver agent, or the wallpaper extension."

# Phases

*Nothing here is decided; Syd: "We will brainstorm on how later."*

- **Phase 1 — Sample before every restart.** Whenever Claude asks Syd to reinstall or reboot, it first records each process's memory and how long it had been running, and appends it to the record.
- **Phase 2 — A record with a shape.** Decide where the samples live and in what form, so a trend can be read without re-reading a transcript.
- **Phase 3 — Sample without a restart.** A periodic sample, so a long uptime is more than two points.
- **Phase 4 — Say when it looks wrong.** Decide what counts as growth worth reporting, and where that is said.

# Design Decisions

*All proposals; none decided.*

- **Resident size is the number**, from `ps -o rss`, because it is what one command gives for any process without instrumenting it.
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

Taken before asking Syd to reinstall or reboot, until Phase 2 decides where they belong.

| When | Agent | Wallpaper extension | Screensaver | Note |
|---|---|---|---|---|
| 2026-09-17 16:18 | 113 MB, 9 min | 53 MB, 9 min | not running | first sample |
| 2026-09-17 16:41 | 157 MB, 23 min | 134 MB, 23 min | not running | before installing Phase 5's first slice |
| 2026-09-17 17:51 | 101 MB, 1 h 18 min | 57 MB, 1 h 43 min | not running | before installing Phase 5's second slice |
| 2026-09-17 19:20 | 150 MB, 1 h 28 min | 104 MB, 3 h 12 min | not running | before installing the evictor |

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
