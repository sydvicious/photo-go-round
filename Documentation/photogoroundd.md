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

It takes no command word, because there is only one thing it does. The agent is
**configured, not commanded**: everything
it needs to know arrives through preferences and the environment before it starts,
and anything that wants to inspect or change the library opens the same database
directly rather than asking the agent to do it. Neither process has to be running
for the other to work.

Running it looks like this:

    screen -h 10000
    cd photo-go-round
    ./Scripts/photogoroundd

The wrapper script builds first, so a stale binary is never run, and points the
agent's storage at `.build` so a development run cannot disturb a real library.

## OPTIONS

`--container` *dir*

: Storage root, holding `library.sqlite` and — by default — the cache.
  See **FILES**.

`--database` *file*

: The database file, overriding its default position inside the storage root.

`--cache` *dir*

: The cache root, overriding its default position inside the storage root.

`--add-folder` *path*

: Add *path* as a source if it is not already one, then run. Written through to
  preferences, so it need only be given once. Repeatable. **Not recursive**
  unless `-r` is also given.

`--add-folder-recursive` *path*

: The same, but this folder is walked whether or not `-r` was given. Recursion
  is a property of the folder rather than of the run, so a flat wallpaper
  directory and a nested album tree can be named in one command.

`-r`, `--recursive`

: Walk subdirectories of every folder named by a plain `--add-folder` or by
  `PGR_FOLDERS`.

`--once`

: Do one pass — refresh, top up, maintain — and exit. For scripts and for
  checking a configuration without leaving something running.

`-i`, `--interval` *seconds*

: How often the main loop wakes. Default 2. This is not how often anything is
  *done*; each activity has its own interval, below.

`--scan-interval` *seconds*

: Override the `scanIntervalSeconds` preference for this run.

`-h`, `--help`

: Print usage and exit.

## ENVIRONMENT

`PGR_CONTAINER`

: Storage root. Same as `--container`; the flag wins.

`PGR_DATABASE`

: Database file. Same as `--database`; the flag wins.

`PGR_CACHE`

: Cache root. Same as `--cache`; the flag wins.

`PGR_FOLDERS`

: Colon-separated folders to ensure exist as sources, written the way `PATH` is.
  Adding one that is already a source is a no-op, so this describes what should
  be true rather than what to do, and is safe to leave set across restarts.

`PGR_RECURSIVE`

: Set to `1` to walk subdirectories of every folder in `PGR_FOLDERS`.

`PGR_FOLDERS_RECURSIVE`

: Folders that are always walked, whatever `PGR_RECURSIVE` says. Independent of
  `PGR_FOLDERS`; both may be set, which is how a mixed set is expressed without
  ordering rules.

`PGR_PREFS_SUITE`

: Preference domain. Preferences are global to the executable rather than scoped
  to the storage root, so **relocating the container is not on its own enough to
  isolate a run** — the source list would still be the real one. Set this as well
  when pointing a run at scratch storage.

A launchd plist sets environment variables far more naturally than it sets
arguments, which is why every path has an environment form.

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

*storage-root*`/library.sqlite`

: Sources, the photo pool, the queue, and cache bookkeeping. Written in WAL
  mode, so `-wal` and `-shm` sidecars sit beside it and "delete the database"
  means deleting all three.

*cache-root*`/`*source-id*`/`*photo-id*`.`*ext*

: Copied photo bytes, one directory per source. Only photos on volumes that can
  disappear are copied; anything on the boot volume is read where it lies.

The defaults are the App Group container when the build is entitled, and
`~/Library/Application Support/Photo-Go-Round` otherwise. They will become
`~/Library/Containers` and `~/Library/Caches` when the agent is packaged. The
wrapper script puts both under `.build` while developing.

`status` prints which of those rungs supplied the roots, so it is never a guess.

## EXIT STATUS

0 on a clean exit, 1 on a configuration error — an unreadable option, a folder
that does not exist, a storage root that cannot be created.

Nothing about the library is a fatal error. A source that cannot be reached, a
provider that fails, a photo whose file has vanished: each reduces what can be
shown and none stops the agent. The worst outcome is that a client asking for a
picture is told there is not one.

## SEE ALSO

`pgr(1)` — the tool for inspecting and changing a library, arriving in Phase 2.

`PLAN.md` in the repository root, for why any of this is shaped the way it is.
