# Summary

**Phases 1, 2, 3 and 5 built and installed 2026-09-19. Phase 4 is measured over ten minutes and owes
a day in a release build; that is all that is left.**

No binary in this system captures its standard output to a file. Everything worth reading later goes
to the unified log, at a level chosen for how often the line happens — and a release build says less
than a Debug or a Claude build.

# Rationale

The agent's `/tmp/com.sydpolk.photogoround.server.log` was measured at 10.3 MB and 86,152 lines in
under eight hours on 2026-09-19 — about 31 MB a day, 11 GB a year — and nothing rotates it, because
launchd will not. Syd, 2026-09-19: *"I would rather let the system do log rotation for us and not
develop and maintain our own."* `logd` already does exactly that, under a fixed budget, for every
process including the two that run inside sandboxes where a file logger could not write at all. So
the fix is not to rotate our file: it is to stop having one, which means the unified log has to carry
everything the file was carrying — and today it does not. The other half is volume: a per-picture
line is worth having while a question is open and worth demoting when it closes, and the demotion is
the step that never happens unless the plan says so.

# Phases

- **Phase 1 — Nothing the agent says is lost when stdout goes away. Built 2026-09-19.** Audit every
  `Console` call reachable from the agent — 57 of them — and give each one a unified-log twin or a
  reason it is terminal-only. Do this *before* Phase 3; the order is the whole safety of this plan.
  - `Console` gains an installable mirror, the way it already has `recordAlerts`. The agent installs
    one; `pgr_ctl` does not.
  - Collapse the five sites that already call `Console` and `Log` by hand. **Six, as built** —
    `HTTPListener` was the sixth.
  - The served line `▸ …` in `PictureEndpoint` is the one `Documentation/Installing.md` tells a
    person to grep, and it exists only on stdout. It is the proof case for this phase.
  - **Mirrored lines go to a category of their own, `console`, not to `Log.deck`.** The mirror holds
    a `String`, so filing source refreshes and cache walks under `deck` would have been a lie.
    `MEMORY:` and `CACHE WALK:` moved to it from `deck` and `cache` as a result.
  - **It introduced two duplicates**, both found by Phase 4 and fixed in Phase 5: the served `▸` line
    against `served status=…`, and `RESIZE: gave up` against its own `Log.deck.notice`.
- **Phase 2 — A level policy, and a release build that says less. All three binaries. Built
  2026-09-19.** Syd,
  2026-09-19: *"this same logging discipline should apply to all three separately running
  binaries."* Per-request traffic drops a rung outside Debug and Claude builds; state changes,
  errors and startup stay at `.notice` everywhere.
  - **The agent.** `QueueEvent.report()` picks a level per case instead of logging all sixteen at
    `.notice`. ~~That one function is ~99% of the volume measured.~~ **Wrong, and Phase 4 said so**:
    it was 99% of the *file*, and about a third of the unified log. The rest was `deck`, which
    Phase 5 took.
  - **The screensaver.** Already at the floor — one line per picture — so the discipline is applied
    by confirming it, not by demoting anything. Its session start and teardown stay at `.notice`.
  - **The wallpaper extension.** One redundant line to remove: `port … from the … suite`, repeated
    on every wake. The rest of its six lines per change each say something different.
  - The rung is decided at compile time from the same `PGR_AGENT_CLAUDE` / `DEBUG` conditions that
    already pick the port, in `Log`, so no call site repeats the test.
  - A test pins the policy: the noisy cases are not `.notice` in a release build, and the state
    changes are `.notice` in every build. **Built as `QueueEventLevelTests`**, six tests.
    `level(chatter:)` takes the rung rather than reading `Log.chatter`, because a test run is a Debug
    build where the rung is `.default` and every case would otherwise look identical.
  - **No test pins the screensaver's floor.** `MacOS/Screensaver` is an Xcode target, not a package one, so
    the package suite cannot reach it. Open.
- **Phase 3 — The file goes away. Built 2026-09-19.** Remove `StandardOutPath` and
  `StandardErrorPath` from
  `Scripts/install-agent.sh` and `Scripts/make-agent-bundle.sh`; launchd then discards stdout.
    *Both scripts were themselves deleted on 2026-09-19 — the plist is written by
    `JobDescription` in `PhotoGoRoundInstall` now, and it has never carried either key.*
  - Both scripts stop echoing `tail -f /tmp/…`.
  - `Documentation/Installing.md` (three places) and `CLAUDE.md` (*Where things are*) get
    `log show` / `log stream` instead. **`Documentation/photogoroundd.md` never mentioned the file**
    — there was nothing there to change. `Plans/Build Plan.md` still names it, in a historical
    account, and is left alone.
- **Phase 4 — Measure the result, the way the problem was measured. Run 2026-09-19, over ten
  minutes rather than a day; the day is still owed.** Count the agent's lines in the unified log, in
  a release build and in a Debug build, and record how far back `log show` can still answer.
  - The 2026-09-19 measurement said the window was about 9 hours at 51 chunks and 499 MB. The
    number to beat is that window, not a byte count.
  - **The budget is fixed, as predicted**: 51 chunks and 503 MB after, against 51 and 499 before.
  - **The window at the time of measuring was 7h45m**, not 9 — shorter, because a Debug build
    demotes nothing and the mirror added the console lines. See *What Phase 4 measured*.
  - **The demotion works.** An isolated release agent's queue lines came out `.info`, its console
    lines `.default`, and it still printed everything to a terminal.
  - **Still owed: a day, in a release build.** Everything above is ten minutes.
- **Phase 5 — Downgrade the closed investigation's instrumentation. Built 2026-09-19.** Syd,
  2026-09-19: *"putting in logs while we are investigating is great, but downgrading them later is
  essential."* The Agent Performance Overhaul closed on 2026-09-19 and its probes were still at
  `.notice` — measured at 188 lines in ten minutes, the largest persisted group left.
  - `TIMING:`, `RENDER:` and `POOL:` take `Log.chatter`. **`RESIZE: gave up` does not**: it is a
    budget overrun, not instrumentation, and it is rare.
  - **Two lines the console mirror duplicated in Phase 1**, both collapsed to one record: the served
    `▸` line against `served status=…`, and `RESIZE: gave up` against its own `Log.deck.notice`.
    `Console.change` gained the `mirrored:` opt-out `event` and `alert` already had, and `▸` is
    terminal-only now.
  - **`REFRESH:` was already `.info` and is left alone** — recorded here because Phase 4 first named
    it as the problem and was wrong, and the next person to look will make the same mistake.
  - `served status=…` stays at `.notice`: one line per picture is the floor, the same as the
    screensaver's.
  - `Documentation/Installing.md`'s served-lines recipe now greps `served status=` rather than `▸`.

# Design Decisions

- **The unified log is the only log.** It is already documented as such in `Log.swift`, and it is the
  only mechanism that works from inside the screensaver's and the wallpaper extension's sandboxes.
  Removing the file makes the documented rule true.
- **`logd` does the rotation.** Fixed budget, ages the oldest out, survives reboots, needs no code and
  no `newsyslog` entry. Lines we add shorten the window and never grow the disk.
- **Level is chosen by how often a line happens, not by how much we like it.** `.notice` persists to
  disk, `.info` does not unless asked — so `.notice` is the budget and per-request lines are what
  spends it.
- **The variant shifts the ladder; it does not silence anything.** A release build logs the same
  events, one rung lower for the noisy ones. `log stream --info` and `log config` bring them straight
  back without a rebuild or a flag.
- **`photogoroundd` run by hand still prints everything to stdout and stderr.** Syd, 2026-09-19:
  *"I should be able to run most of our binaries in a terminal or Xcode and see stdout/stderr."* The
  mirror is additive and nothing in this plan silences `Console`; what goes away is launchd pointing
  a *daemon's* stdout at a file. A terminal run and an Xcode run are unchanged.
- **`Console` gains a mirror rather than 57 paired calls.** Pairing by hand is how the five existing
  pairs got there and how the other 52 did not; a mirror cannot drift.
- **Queue lines keep `QueueEvent.report()` and do not go through the mirror.** They are the only lines
  whose level varies by case, and the case is the value — not the wording. `speak` tells the mirror
  to skip them.
- **No `pgr_ctl` command for turning chatter on.** `log config --subsystem com.sydpolk.photogoround`
  already does it, persistently. Wrapping the system tool is maintenance Syd asked not to take on.

# Background

- **`Log` and `Console` are already separate, and correctly so.** `Log` is unified logging for every
  process; `Console` is terminal output for a person watching a folder in a development run. The
  problem is not the split — it is that launchd points the agent's stdout at a file, which turns
  development output into a permanent record nobody prunes.
- **The file is the agent's alone.** `StandardOutPath` appears in two scripts and nowhere else. The
  screensaver and the wallpaper extension are loaded into hosts we do not launch, so their `print`
  output already goes nowhere — and neither of them calls `print`.
- **What the file actually held**, measured 2026-09-19: 24,528 `CACHE:`, 11,592 `DEAL:`, 11,547
  `SERVE:`, against 12 `STARTUP:`. Ordinary serving, not diagnostics.
- **Reboots have been hiding it.** macOS clears `/private/tmp` of files older than three days at
  boot. A Mac left up for months — the case Syd asked about — carries gigabytes.
- **`.notice` throughout this plan is `OSLogType.default`.** There are five levels — `.debug`,
  `.info`, `.default`, `.error`, `.fault` — and nine `Logger` methods over them: `notice` and `log`
  both write `.default`, `warning` and `error` both write `.error`, `critical` and `fault` both write
  `.fault`. The plan says `.notice` because that is the method every call site spells, but the alias
  pairs are indistinguishable once written, so a level policy cannot be expressed by choosing method
  names — which is why Phase 2 puts it in `QueueEvent`.
- **All three measured, 2026-09-19, after Phase 1 was installed and running.** The agent wrote 114
  console lines in ten minutes; the wallpaper extension 48 in thirty, on a `fiveMinutes` interval;
  the screensaver 12 for a whole session, ten of them start and teardown and two of them the
  pictures. The other two were already disciplined — the agent is where the volume is.
- **Level census today**: 73 `notice`, 11 `info`, 3 `debug`, 29 `error`. Nothing uses `warning`,
  `critical` or `fault`. `notice` has never been questioned at a call site — it is what the method
  gave, not what anybody chose.

# Detailed discussions

## What Phase 4 measured

All of it on 2026-09-19, over ten minutes rather than the day the phase asks for. The day is still
owed, and owed in a release build.

**The budget is fixed, exactly as this plan claimed.** 51 chunks and 503 MB in `/var/db/diagnostics/Persist`
afterwards, against 51 chunks and 499 MB in the baseline. Nothing we log grows the disk.

**The retention window had *shortened*, to 7h45m.** Two reasons, and both were expected once stated:
a Debug build — which is what was installed — demotes nothing, and Phase 1's mirror added the whole
`console` category on top of what was there before. The release build is where the demotion pays.

**Where the lines were**, installed Debug agent, ten minutes, by category and level:

| category | `.default` | `.info` |
|---|---|---|
| `cache` | 360 | 29 |
| `console` | 295 | 0 |
| `deck` | 276 | 1 |
| `sources` | 0 | 197 |

**That table is the finding.** This plan said `QueueEvent.report()` was ~99% of the volume; it was
99% of the *file*, which only ever carried what `Console` printed. In the unified log it is about a
third. `sources` — the `REFRESH:` page lines — was already `.info` and had never persisted. `deck`
was 88 `served`, 88 `TIMING:`, 87 `RENDER:`, 10 `POOL:` and 3 `RESIZE:`, three of which are the
closed overhaul's probes. Phase 5 came out of this table.

**`.info` persists, for less than half as long.** Measured the same afternoon: default-level lines
reached back to 04:22, info-level lines only to 08:36 — 7h45m against 3h31m. So a demotion buys
retention rather than making a line free, which is a more honest statement of the mechanism than
*`.info` does not persist*.

**The release build behaves as designed.** An isolated release agent — its own port, container and
preference suite, four generated photographs — answered six requests and wrote every queue line at
`.info`, every console line at `.default`, `TIMING:` at `.info` after Phase 5, `served status=` at
`.default`, and no `▸` in the log at all. It printed everything to its terminal throughout, which is
the requirement Syd set on 2026-09-19.

**Estimated, not measured: about 51,000 persisted lines a day in a release build**, from ~137,000 in
the Debug build now installed and the old file's ~202,000. It is arithmetic over the table above
rather than an observation, and the owed day is what would replace it.

## Why the file cannot simply be moved or capped

Three things were on the table in `TODO.md` — rotate, cap, or move off `/tmp` — and all three are
worse than not having the file.

`newsyslog` is a system configuration file. An entry in `/etc/newsyslog.d` is root-owned, is not
installed by anything we ship, and would have to be documented as a manual step that a person
performs once and forgets; when it is missing, the symptom is the one we already have. A
self-imposed cap means writing a rotator: size check, rename, reopen, and a decision about what to do
when the process is killed mid-rotation. That is a small amount of code that has to be correct
forever, and it exists only to manage a file that duplicates a log the system already manages.

Moving to `~/Library/Logs` is the seductive one, because it is where a person looks and it is not
cleared at boot — which is exactly the problem. `/tmp` has been silently saving us: the file is
deleted every few days by a reboot. Under `~/Library/Logs` the same 31 MB a day accumulates with
nothing to stop it, so moving the file makes the disk problem strictly worse while making the file
easier to find. If the file has to exist at all, `/tmp` was the better of the two.

None of that applies once the file is gone. `logd` holds a fixed budget and ages the oldest chunks
out; adding lines to it shortens how far back you can ask, and never consumes another byte of disk.
That is the trade this plan makes: retention window in exchange for an unbounded file, with the
window itself managed by the level policy in Phase 2.

## The 9-hour window, and why Phase 2 exists for it

The unified log answered back about 9 hours on 2026-09-19, holding 51 chunks and 499 MB. That is not
a lot — the note in `TODO.md` records reading the 2026-09-18 render run at 08:34 "with roughly twenty
minutes to spare". Some of that budget is the rest of the system, but a meaningful share is ours: the
agent writes ~47,000 `.notice` lines a day through `QueueEvent.report()`.

So Phase 2 is not tidiness. It is what buys back the retention window that Phase 3 makes the agent
depend on. Dropping `DEAL:`, the ordinary `SERVE:` and the ordinary `CACHE:` cases below `.notice` in
a release build removes almost all of it, and what is left — startup, sources appearing and
disappearing, evictions, errors, `MEMORY:` every five minutes, configuration changes — is a few
hundred lines a day. An overnight question then has a log that can still answer it in the morning,
which is the thing that nearly failed on 2026-09-18.

A Debug or Claude build keeps everything at `.notice`, because that is the build somebody is actively
watching and a shorter window on a development machine costs nothing.

## Which cases drop, and which do not

The split is *did something change* against *did the machinery turn over*.

Stays `.notice` in every build:

- `dropped` — a photograph has left the library. This is the deleted-photo guarantee being enforced
  and it is rare.
- `cacheTimedOut` — "the failure that hides", already flagged as such in `speak`.
- `sourcePaused` — the reason nothing from a source is appearing.
- `cacheFailed` — rare in a healthy run, and the first thing looked at in an unhealthy one.
- `configurationChanged` — a setting moved under the agent.
- `nothingToShow` — the deck came up empty, which contradicts *always have something to show*.
- `waiting` — announced before the wait so a request that hangs is distinguishable from one that is
  silent. `logd` rotates, so the volume is not worth trading the hang for.

Drops a rung outside Debug and Claude builds:

- `dealt` — twenty at a time when the queue runs short, and says nothing on its own.
- `serving` when `unconfirmed` is nil — the ordinary success. **When `unconfirmed` is set it stays at
  `.notice`**, because that is the one moment the deleted-photo guarantee is knowingly relaxed and it
  is said out loud by design.
- `skipped` — ordinary queue movement.
- `caching`, `cacheUnnecessary`, `cached` — the fetch queue turning over.


## The other two binaries, and why there is so little to do in them

Measured on 2026-09-19 with Phase 1 installed.

**The screensaver writes one line per picture**, and that is the floor rather than something to
demote — it is the only record of what was on the screen. A session that showed two pictures wrote
twelve lines, of which ten were `created` / `window` / `startAnimation` / the port it found / the
loop it joined / the interval it read / `last view … went`. All of that is once per session, and a
session is once per idle period. At a `thirtySeconds` interval an all-night idle Mac writes about
2,900 lines, which is the same order as the pictures it actually showed.

So the discipline is applied there by confirming it holds, and the test that pins the policy should
include the saver's per-picture line staying at `.notice` — a future hand adding a second or third
line per picture is exactly what would break this quietly.

**The wallpaper extension writes about seven lines per change**, and six of them each say something
different: the picture's size, the surface it went to, the remote context that now holds it, the
size that context is at, the thumbnail path, the interval it will ask on. The seventh is
`system-wallpaper: port 9428 from the com.sydpolk.photogoround.dev suite`, which re-announces an
unchanged fact on every wake — six times in thirty minutes during the measurement. That one line is
the whole of the work here: say it when it changes, not when it is read.

At the shipped hourly interval the extension writes about 170 lines a day. At the `fiveMinutes`
interval it was measured on, about 2,300. Neither is a problem; the repeated line is worth removing
because it is noise in a log somebody is reading, not because of its volume.

**Neither writes to a file**, so Phase 3 does not touch them. Both are loaded into hosts we do not
launch — `legacyScreenSaver` and whatever `WallpaperAgent` starts — and neither calls `print`. The
unified log is not a preference for those two, it is the only channel that exists.

## How the mirror works, and the one awkward edge

`Console` already has this shape. `recordAlerts(to:)` installs a `@Sendable` closure that receives
every `alert`, and the agent installs one that files into `AgentErrors` while `pgr_ctl` leaves it
nil. The mirror is the same mechanism with a wider mouth:

```swift
public static func mirror(to sink: (@Sendable (_ text: String, _ level: Level) -> Void)?)
```

with `Level` a small enum Console owns — `notice`, `error` — mapped from the call kind: `note`,
`event`, `summary`, `recovered` and `change` are `notice`; `alert` and `failure` are `error`. The
agent installs a sink that writes to `Log.deck`; `pgr_ctl` installs nothing and behaves exactly as it
does today.

That mapping is coarse on purpose. Every Console call the agent makes outside the queue is low
frequency — startup, the source list, a refresh, a source appearing or disappearing, an eviction, the
served `▸` line — so a single category and two levels is enough, and a finer taxonomy would mean
touching all 57 call sites, which is the cost this design exists to avoid.

**The edge**: `speak` prints every queue line through `Console` *and* calls `event.report()`. With a
mirror installed, each queue line would be logged twice — once by the mirror at the flat level, once
by `report()` at the chosen one. Three ways out, in order of preference:

1. **`speak` asks the mirror to skip.** A `mirrored: Bool = true` parameter on the Console calls
   `speak` makes, passed `false`. One parameter, honest about why, and `report()` keeps sole
   ownership of the level policy. Recommended.
2. **`speak` drops `report()` and the mirror carries the level.** Cleaner at the call site, but it
   moves a per-case policy into a sink that only sees a `String`, so the mirror would have to
   re-derive the case from the text. Rejected: a level policy that pattern-matches on wording is
   exactly the kind of thing that breaks silently when somebody rewords a line.
3. **The mirror is installed only for the non-queue path.** Not expressible — `Console` is a single
   enum with static state, and splitting it into two instances to express this is a larger change
   than the problem.

## Running it by hand keeps working, and that is not an accident of this design

Nothing here removes a `print`. `Console` writes to stdout unconditionally and always will; the
mirror is a second destination, not a replacement. So:

- **`./Scripts/photogoroundd` in a terminal** prints exactly what it prints today, in colour, because
  `Console.isTTY` is true.
- **Running the `Photo-Go-Round Server` scheme in Xcode** prints the same lines, uncoloured, in the
  console pane — `Console` drops the escape sequences rather than the text.

  **This paragraph was wrong until 2026-09-19, and the error was visible all along.** It said
  `isatty` is false in Xcode's console. It is not: Xcode runs a command-line tool on a
  pseudo-terminal, so `isatty` answers yes and `Console` coloured — and Xcode's console does not
  interpret the escapes, so they arrived as literal text. Measured that day, when `pgr_install`'s
  first error in the Xcode console read `[31merror: [0munknown option Screensaver`. `Console.isTTY`
  now also requires a usable `TERM`, which Xcode sets and a launchd job sets to nothing; both
  directions were checked. `pgr_ctl` and the agent had been emitting the same noise into that pane
  for as long as either had run there.
- **Piping to a file yourself** — `./Scripts/photogoroundd > /tmp/mine.log` — still works and is now
  the only way that file comes into existence: a person asked for it, for one run, and can delete it.

The thing being removed is narrower than "stdout to a file". It is *launchd* writing a daemon's
stdout to a file forever, on every install, whether or not anybody ever reads it. A person watching
their own run is the case `Console` was built for and is untouched.

This also means the mirror is redundant during a foreground run — the same line appears on the
terminal and in `log stream`. That is correct and not worth suppressing: the agent should not behave
differently depending on how it was started, and a duplicate during a session somebody is watching
costs nothing.

**The two that cannot do this**, and it is worth being explicit about why rather than leaving it as a
maybe. The screensaver is loaded into `legacyScreenSaver`, and the wallpaper extension into a process
`WallpaperAgent` launches; neither host is ours, neither is started from a terminal, and their stdout
goes wherever the host sends it — which is nowhere useful. Both already log through `Log` and nothing
else, and both already call no `print`. For those two the unified log is not a preference, it is the
only channel that exists, which is why `Log.swift` says so. `pgr_ctl` and the app are in the same
position as the agent: a person runs them, and they print.

## The served `▸` line is the case that proves the phase ordering

`Documentation/Installing.md` currently tells a person to run:

```bash
grep "▸" /tmp/com.sydpolk.photogoround.server.log | tail -10
```

to see which consumer got which picture — `system-wallpaper` for the extension, `screensaver` for the
saver. That line is emitted at `MacOS/Agent/Endpoints/Sources/PictureEndpoint.swift:245` by
`Console.change` and by nothing else. It has no unified-log twin.

So if Phase 3 were done first, the single most useful diagnostic in the system would disappear, and
the documentation that names it would still be sitting there telling people to look for it. It is one
line of the 57, and it is the reason the audit is a phase of its own rather than a step inside the
one that removes the file.

Its replacement is the same fact through `log show`:

```bash
/usr/bin/log show --last 1h --info --predicate 'subsystem == "com.sydpolk.photogoround"' | grep "▸"
```

which is longer, and is what `Installing.md` should say. `/usr/bin/log`, spelled out, because `log`
is a zsh builtin.

## What a person types after this change

Worth writing down in `Installing.md` as a small set, because "read the log" stops being `tail`:

- **Watch it live**, the closest thing to the old `tail -f`:
  `/usr/bin/log stream --info --predicate 'subsystem == "com.sydpolk.photogoround"'`
- **Read back**, including the demoted lines a release build wrote:
  `/usr/bin/log show --last 30m --info --predicate 'subsystem == "com.sydpolk.photogoround"'`
- **Startup only**: add `--predicate '… AND eventMessage CONTAINS "STARTUP:"'`.
- **Turn the demoted lines into persisted ones on a release build**, until told otherwise:
  `/usr/bin/log config --subsystem com.sydpolk.photogoround --mode "persist:info"` — and
  `--mode "persist:default"` to put it back.

`--info` is the one that catches people out: without it, `log show` omits everything Phase 2 demotes,
and a release agent will look like it is saying nothing.

## Testing this, given that it is logging

*Documented means tested* applies to the `Installing.md` commands above, and they are testable in the
weakest sense only — a test can assert that the predicate string in the documentation matches
`Log.subsystem`, which catches the subsystem being renamed. It cannot assert that `log show` returns
anything.

What is worth pinning:

- **The level policy**, as a pure function. Give `QueueEvent` a `level` property and test it: the
  noisy cases are not `.notice` under a release build's conditions, the state changes are `.notice`
  under all of them, and `serving` with `unconfirmed` set is `.notice`. This is the test that makes
  the demotion survive somebody adding a case.
- **The mirror fires for every Console kind.** Install a sink in a test, call each of the seven
  entry points, assert seven lines with the expected levels. Cheap, and it is what catches a new
  Console call kind added without mirroring.
- **The plists carry no `StandardOutPath`.** A shell-level check in whatever already lints the
  scripts. **Answered better on 2026-09-19:** the plist is a `Codable` value, `JobDescription`, and
  a test asserts its fields directly — `Label`, `ProgramArguments`, `RunAtLoad`, `KeepAlive` and
  `ProcessType` — so a `StandardOutPath` could not appear without someone adding the property. No
  grep, and no script to run.

`MacOS/Shared/Tests/PhotoGoRoundKitTests/TestLoggingTests.swift` already exists and pins the test-subsystem split,
so there is a home for the first two.

## What this does not touch

- **`AgentErrors`.** The error ledger is a separate record with its own bound (100 entries) and the
  dashboard reads it. Nothing here changes what is recorded or how.
- **Signposts.** `Log.signposter` is read by Instruments, not by `log show`, and has no disk cost.
- **`pgr_ctl`.** It prints to a terminal a person is standing at and should keep doing exactly that,
  with no mirror and no unified-log lines.
- **The `MEMORY:` lines.** Every five minutes from three processes, at `.notice`, and they stay
  there: `Plans/Track RAM Usage.md` closed on the strength of them, and they are ~860 lines a day.

# References

- `TODO.md`, *Next: the agent's own log file grows without bound* — the 2026-09-19 measurement this
  plan is answering.
- `Shared/Sources/PhotoGoRoundAgentAPI/Support/Log.swift` — the subsystem, the categories, and the existing
  statement that unified logging is the only mechanism.
- `MacOS/Shared/Sources/Console/Console.swift` — `recordAlerts(to:)` and `redirectFailures(to:)`, the pattern the
  mirror follows.
- `MacOS/Shared/Sources/PhotoGoRoundKit/Cache/QueueEvent.swift` — the sixteen cases and `report()`.
- `MacOS/Agent/Sources/RunCommand.swift`, `speak` — the console routing the mirror has to avoid
  double-logging.
- `MacOS/Agent/Endpoints/Sources/PictureEndpoint.swift:245` — the `▸` line.
- `Scripts/install-agent.sh`, `Scripts/make-agent-bundle.sh` — the two `StandardOutPath` writers.
  Both deleted 2026-09-19; `MacOS/Shared/Sources/PhotoGoRoundInstall/JobDescription.swift` is the one writer now.
- `Documentation/Installing.md` — three references to the file.
- `Shared/Sources/PhotoGoRoundAgentAPI/Host/ServiceAddress.swift` — the `PGR_AGENT_CLAUDE` / `DEBUG` /
  release conditions Phase 2 reuses.
- `Plans/Service Port Plan.md`, *Three numbers, one per build variant* — where build-time identity
  was decided.
- `log(1)`, `os_log(3)`, `logd(8)` — all three man pages are present on this Mac.
- **The five levels**, in the SDK: `usr/include/os/log.h`, lines 84–109 — `OS_LOG_TYPE_DEFAULT`,
  `INFO`, `DEBUG`, `ERROR`, `FAULT`, with the persistence behaviour in the doc comment above each.
- **The nine `Logger` methods and how they map onto those five**:
  `usr/lib/swift/os.swiftmodule/arm64e-apple-macos.swiftinterface`, lines 1634–1665, with the
  `OSLogType` statics at 19–29. This mapping is not stated in Apple's documentation pages; the
  `.swiftinterface` is where it is visible.
- `developer.apple.com/documentation/os/oslogtype`, `developer.apple.com/documentation/os/logger`.
- RFC 5424 §6.2.1 — the syslog severities, where the name `notice` comes from. It has no log4j
  counterpart, which is why the level `notice` emits is the unfamiliar one.
