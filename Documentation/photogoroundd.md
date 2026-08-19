# photogoroundd(1)

## NAME

**photogoroundd** — Photo-Go-Round library agent

## SYNOPSIS

**photogoroundd** \[*options*]

## DESCRIPTION

**photogoroundd** maintains a shuffled queue of photographs drawn from folders on
disk, keeps their bytes available, and serves them to whatever wants to display
one. It is an agent rather than a daemon — it runs in a user session and needs
one, because photo library access is per-user — but it is named the way a
command-line service is named.

The agent is **configured, not commanded**: what it should be doing is state it
reads, never an instruction it is asked to carry out.

There are four ways to say what that state is:

- **Command-line options**, listed below, which take effect for that run. The
  ones naming a source write through to preferences, so they need giving only
  once.
- **Environment variables**, saying the same things — because a launchd plist
  sets those far more naturally than it sets arguments.
- **User preferences**, which hold everything durable, the source list included.
  The agent re-reads them on a thirty-second poll, so a plain `defaults write`
  reconfigures a running agent with no cooperation from it.
- **`pgr_ctl`** (_recommended_). It writes those same preferences, but picks the
  domain matching the deployment you meant, refuses a key that does not exist,
  and makes the change take effect at once rather than at the next poll.

None of the four needs the agent running, which is the property worth having:
configuring the library and running it are separate acts.

**Getting a picture does go through the agent.** It serves pictures over HTTP: a
client asks for one at the size it is about to draw at and is handed the bytes,
and never opens the database or the cache. That is what lets a screensaver inside
someone else's sandbox and an Apple TV across the network be the same kind of
client. See **SERVICE**.

**It is meant to run as a LaunchAgent**, registered with `pgr_ctl register` from
a built bundle so that launchd starts it at login and restarts it if it stops.
Nothing else has to be running for it to work, and it expects to be there before
any surface asks for a picture.

While developing, run it in a terminal instead:

    cd photo-go-round
    ./Scripts/photogoroundd

The wrapper script builds first, so a stale binary is never run, and points the
agent's storage at `.build` so a development run cannot disturb a real library. A
detached `screen` or `tmux` session keeps it running after the terminal closes,
which is what a long unattended run wants.

## OPTIONS

`--prod`
Use the real library — `~/Library/Containers`, `~/Library/Caches`, and the real
preference domain. Without it everything lives under `.build`, so a plain run
cannot disturb anything. All three move together, deliberately: relocating the
storage root alone would leave the source list pointing at the real one.

`--port` *n*
Which port to serve pictures on, pinning it to a number you choose. A
development agent and a shipped one cannot both hold the same port, so each
names its own.

By default, the agent takes the port the kernel gives it at launch and publishes
it to preferences, where all Mac processes can read it. Other clients will use
Bonjour to discover the URL and port.

`--container` *dir*
Storage root, holding `photogoround.sqlite` and its WAL sidecars. Defaults to
`<repo>/.build/pgr-container`, or with `--prod` to
`~/Library/Containers/com.sydpolk.photogoround`.

`--database` *file*
The database file, overriding its default position inside the storage root.
Defaults to `<container>/photogoround.sqlite` in both deployments.

`--cache-root` *dir*
Where copied photo bytes live. Defaults to `<repo>/.build/pgr-cache`, or with
`--prod` to `~/Library/Caches/com.sydpolk.photogoround`. **Naming a container
takes the cache with it**: give `--container` or `PGR_CONTAINER` and the cache
defaults to `<container>/cache` instead, because somebody who named one
directory meant both.

The cache is deliberately not inside the container in either deployment.
`~/Library/Caches` is a place the system may purge whenever it likes, which is
exactly right for bytes that can be fetched again and exactly wrong for the
database.

`--add-folder` \[`--recursive`] *path*
Add *path* as a source if it is not already one, then run. Written through to
preferences, so it need only be given once. Repeatable.

`--recursive` — or `-r` — walks subdirectories of the folder it precedes, and of
no other. It belongs between `--add-folder` and its path, so a flat directory and
a nested tree can be named in one invocation and each keeps its own answer:

    photogoroundd --add-folder --recursive ~/Pictures/Albums \
                  --add-folder ~/Pictures/Wallpaper

Standing on its own, `--recursive` is an error rather than a setting for the run.
Recursion is off unless asked for, because the surprising direction is the
expensive one: walking a home directory by accident costs minutes and thousands
of photographs nobody meant to add.

`--once`
Do one pass — refresh, top up, maintain — and exit. For scripts and for
checking a configuration without leaving something running.

`-i`, `--interval` *seconds*
How often the main loop wakes. Default 2. This is not how often anything is
*done*; each activity has its own interval, below.

`--scan-interval` *seconds*
Override the `scanIntervalSeconds` preference for this run.

`-h`, `--help`
Print usage and exit.

## ENVIRONMENT

`PGR_CONTAINER`
Storage root. Same as `--container`; the flag wins.

`PGR_DATABASE`
Database file. Same as `--database`; the flag wins.

`PGR_CACHE`
Cache root. Same as `--cache-root`; the flag wins.

`PGR_FOLDERS`
Colon-separated folders to ensure exist as sources, written the way `PATH` is.
Adding one that is already a source is a no-op, so this describes what should
be true rather than what to do, and is safe to leave set across restarts.

`PGR_RECURSIVE`
Set to `1` to walk subdirectories of every folder in `PGR_FOLDERS`.

`PGR_FOLDERS_RECURSIVE`
Folders that are always walked, whatever `PGR_RECURSIVE` says. Independent of
`PGR_FOLDERS`; both may be set, which is how a mixed set is expressed without
ordering rules.

`PGR_PREFS_SUITE`
Preference domain. Preferences are global to the executable rather than scoped
to the storage root, so **relocating the container is not on its own enough to
isolate a run** — the source list would still be the real one. Set this as well
when pointing a run at scratch storage.

A launchd plist sets environment variables far more naturally than it sets
arguments, which is why every path has an environment form.

## SERVICE

The agent listens on localhost — see `--port` — and answers one request that
matters:

    GET /v1/next?consumer=<name>&display=<id>&w=<pixels>&h=<pixels>

`200` returns the picture, with `Content-Type` describing the format and
`X-PGR-Card`, `X-PGR-Deal`, `X-PGR-Source` and `X-PGR-Storage` describing the
photo and its place in the shuffle. `204 No Content` means the queue is empty,
which is an ordinary answer rather than an error — a fresh library replies this
way until the agent has produced something.

**Serving pops the queue**, and it pops whether or not the download completes.
There is no reservation and nothing to reclaim from a client that disappears
mid-transfer; a failed download is a lost picture and the client asks again. Two
clients asking at once therefore never receive the same picture.

For now, `w` and `h` are accepted and ignored: the bytes returned are the
original, unmodified.

Serving is also what notices the queue has run short, and what asks the sources
for more.

Every request is logged to the console with the consumer, the size asked for, the
deal ordinal, the bytes, and the latency.

## PREFERENCES

State the agent derives lives in the database and is disposable. Everything the
user *chose* lives in preferences, which is therefore the only durable thing —
including the source list. Delete the database and the sources come back; the
agent rescans and the only cost is time.

That also makes `defaults write` a control channel. The agent re-reads
preferences on a thirty-second poll, so a change takes effect on a running agent
without restarting it and without any cooperation:

    defaults write com.sydpolk.photogoround sources -array-add \
        '{kind = folder; locator = "/Users/me/Pictures/Sunsets"; recursive = 1; enabled = 1;}'

| key | meaning | default |
| --- | --- | --- |
| `sources` | array of `{kind, locator, recursive, enabled}`; `recursive` is per source and defaults off | none |
| `repeatWindowFraction` | how much of the library must pass before a photo repeats | 0.5 |
| `queueSize` | pictures to keep ready. A target, not a ceiling | 1000 |
| `queueRefreshIntervalSeconds` | how often to top the queue up | 5 |
| `scanIntervalSeconds` | how often to rescan sources for changes | 300 |
| `maintenanceIntervalSeconds` | how often to verify, sweep, and evict | 30 |
| `downloadConcurrency` | fetches in flight per source | 4 |
| `cachePhotoCap` | copied photos to keep | 1000 |
| `cacheByteCeiling` | bytes to keep, as a safety valve | 50 GB |
| `cacheMinimumFreeBytes` | stop fetching below this much free space | 5 GB |
| `cacheCriticalFreeBytes` | evict ahead of the cap below this much | 2 GB |

Every read is a parse with a default and a clamp, because `defaults write` accepts
anything. An out-of-range value is logged and clamped rather than honoured.

## FILES

*storage-root*`/photogoround.sqlite`
Sources, the photo pool, the queue, and cache bookkeeping. Written in WAL
mode, so `-wal` and `-shm` sidecars sit beside it and "delete the database"
means deleting all three.

*cache-root*`/`
Copied photo bytes. Only photos on volumes that can disappear are copied;
anything on the boot volume is read where it lies.

|                | storage root | cache root |
| --- | --- | --- |
| default | `<repo>/.build/pgr-container` | `<repo>/.build/pgr-cache` |
| `--prod` | `~/Library/Containers/com.sydpolk.photogoround` | `~/Library/Caches/com.sydpolk.photogoround` |
| container named | as given | `<container>/cache` |

**Development is the default, and reaching a real library takes `--prod`, typed
on purpose.** All three of storage, cache, and the preference domain move
together under that flag. Two of the three are obviously per-deployment and the
third silently is not, so relocating the storage root alone would leave the
source list — and therefore what the agent scans — pointing at the real one.

`pgr_ctl status` prints which of those rungs supplied the roots, so it is never
a guess, and the agent prints the same three lines at startup.

## EXIT STATUS

In normal operation this is an agent that never exits. It runs until something
stops it — a signal, launchd, or the terminal it was started from going away.

It exits with a non-zero return code for a fatal operational error: an unreadable
option, a folder that does not exist, a storage root that cannot be created.

When run with `--help` or `--once`, it exits with a return code of 0, assuming no
fatal operational error.

The agent is designed to handle various normal operational issues without ending
with fatal errors. This includes, but is not limited to: a source that cannot be
reached, a provider that fails, or a photo whose file has vanished. In the worst
case, when a client requests the next photo, the service will report that there
are no photos available.

## SEE ALSO

`pgr_ctl(1)`, `Documentation/pgr_ctl.md` — the tool for inspecting and
configuring a library.

`README.md`, *Testing the picture endpoint* — driving the service with `curl`.
