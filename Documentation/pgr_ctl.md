# pgr_ctl

## NAME

`pgr_ctl` — drive and inspect the Photo-Go-Round library from a terminal

## SYNOPSIS

```
pgr_ctl status
pgr_ctl source add --folder <path> [-r] | --file <path>
pgr_ctl source list | remove <id> | enable <id> | disable <id>
pgr_ctl refresh [--source <id>]
pgr_ctl pool stats
pgr_ctl queue peek [-n <count>] | fill [-n <rounds>]
pgr_ctl serve [-n <count>] [--consumer <name>] [-q] [-w <fraction>]
pgr_ctl deck stats
pgr_ctl cache status | evict | clear [--source <id>] [--unavailable] [--yes]
pgr_ctl shuffle-test [--deals <n>] [--photos <n>] [-w <fraction>]
pgr_ctl get [<key>] | set <key> <value>
pgr_ctl notify <topic>
pgr_ctl log [-f] [--last <time>]
pgr_ctl register | unregister | service-status
```

## DESCRIPTION

`pgr_ctl` is the rig. It is a separate binary from `photogoroundd` because the
service has exactly one job and answering questions is not it.

**It never talks to the agent.** Every command opens the same SQLite database,
changes what it came to change, and rings a Darwin notification — so the agent
does not have to be running for any of this to work, and when it is running it
notices within a tick. Neither process has to be running for the other to make
progress, which is the property that made the design worth having.

It is internal and never ships: it is not in any distributed bundle, has no
signing or notarization pipeline, and carries no compatibility promise —
subcommands may change shape whenever a phase makes that convenient. Being
unshipped does not make it a scratch script, though. `shuffle-test` holds the
project's real correctness checks for the deck, and they exit non-zero so CI can
run them exactly as a person does.

**Where a source lives is a preference, not a row.** `source add`, `remove`,
`enable`, and `disable` write to `UserDefaults` and then reconcile the database
in the same breath. The source table is a projection of the durable list, and the
agent reconciles the two on a thirty-second poll — so a row written straight into
the database is deleted again within half a minute.

## OPTIONS

### Where the library is

Every command has to agree with the running agent about the container, so these
are spelled exactly as the agent spells them.

`--prod`
: Use the real library: `~/Library/Containers`, `~/Library/Caches`, and the real
preference domain. Without it everything lives under `<repo>/.build`, so a plain
run cannot disturb anything. All three move together, deliberately.

`--container <dir>`
: Storage root. Default: `<repo>/.build/pgr-container`.

`-d`, `--database <path>`
: Database file. Default: `<container>/library.sqlite`.

`--cache <dir>`
: Cache root. Default: `<repo>/.build/pgr-cache`.

### Per command

`--folder <path>`, `--file <path>`
: What `source add` is adding. A folder source enumerates its contents; a file
source is one pinned photo.

`-r`, `--recursive`
: Walk subdirectories of an added folder. Off by default, because the surprising
direction is the expensive one. Recursion belongs to the folder rather than to
the command, so it is stored per source.

`--source <id>`
: Scope `refresh` or `cache clear` to one source.

`--unavailable`
: Scope `cache clear` to sources that are gone. These can never be re-fetched
anyway, which makes this the variant to reach for first: it frees space at zero
future cost.

`--yes`
: Do not ask before clearing. Required when stdin is not a terminal.

`-n`, `--count <n>`
: How many pictures to serve or peek at, or how many rounds to fill. Default: 10.

`--consumer <name>`
: Consumer identity for `serve`, recorded in the consumer registry. Default:
`cli`.

`-q`, `--quiet`
: Print only the summary.

`-w`, `--window <0-1>`
: Repeat window fraction for `serve` and `shuffle-test`. Default: 0.5.

`--deals <n>`, `--photos <n>`
: The size of the `shuffle-test` run. Defaults: 50000 deals across 4000 photos.

`-f`, `--follow`, `--last <time>`
: Stream the log rather than printing it, and how far back to read. Default: 1h.

`-h`, `--help`
: Usage.

Flags may appear anywhere, including before the command word. Positionals are
collected first and interpreted last, so `source add --folder /a -r` and
`-r --folder /a source add` mean the same thing.

## COMMANDS

`status`
: Sources, pool, queue, cache, shuffle position, and the preferences in force.
The one command to run when something is wrong and you do not yet know what. It
prints which rung supplied the roots, so that is never a guess.

`source`
: Manage sources. `add` scans the new source immediately rather than making you
wait for the agent's next pass. `disable` is not `remove`: the photos leave the
deck and the queue but keep their deal history, so re-enabling brings them
straight back.

`refresh`
: Re-enumerate sources into the pool. Reports `+added -removed =unchanged` per
source, or the reason a source is unavailable.

`pool stats`
: Rows per source, split by what explains everything else — referenced against
materialized, how much has bytes, and how much is claimed by a producer that is
fetching it right now.

`queue peek`
: What is ready to serve, in order. `queue fill` does the agent's topping-up by
hand, synchronously, one round at a time — which is the only way to fill a queue
with no agent running.

`serve`
: Take pictures off the head of the queue as a named consumer, reporting each one
and the latency. This is what a display does, reduced to a terminal, and it
answers questions no unit test can: does the queue stay responsive while a
refresh runs in another process, does a deleted photo really never appear, does
an unplugged drive really keep serving from cache. Run several at once to show
the queue pop serialises — the union of what they got has no duplicates.

`deck stats`
: Where the shuffle stands, plus the distribution of showing counts. `times_shown`
is a statistic and nothing orders by it, which is what makes it the honest
measure: a spread of one to three across a library is a healthy fraction below
1.0, and a spread of three to four hundred is starvation.

`cache`
: `status` reports resident against the cap, bytes on disk, and free space.
`evict` runs a pass now. `clear` discards bytes and never shuffle state — deal
ordinals, shuffle keys, and last-shown times are untouched, so a cleared cache
refills into the same rotation. It states its price before charging it.

`shuffle-test`
: The statistical assertions, run against a throwaway library of empty files and
an in-memory database. It never touches yours. At fraction 1.0 it asserts every
pass contains every photo exactly once and that showings have zero variance;
below 1.0 it asserts no repeat inside the window. It always reports the gap
distribution. Exits non-zero on any failure.

`get` / `set`
: Preferences, written to the domain the agent actually reads — which `--prod`
and the development default disagree about, and getting it wrong writes a setting
nothing consults. `get <key>` prints the bare value, for scripts.

`notify`
: Ring a doorbell by hand: `prefs`, `deck`, `sources`, `cache`. Diagnostic — when
something does not update, this separates "the notification never fired" from
"the listener ignored it".

`log`
: Wraps `log show --predicate 'subsystem == "com.sydpolk.photogoround"'` with
sensible defaults, because nobody should have to remember predicate syntax.

`register` / `unregister` / `service-status`
: The login item, via `SMAppService`. Only works from a built bundle — see
`./Scripts/make-agent-bundle.sh`.

## ENVIRONMENT

`PGR_CONTAINER`
: Storage root. Same as `--container`; the flag wins.

`PGR_DATABASE`
: Database file. Same as `--database`; the flag wins.

`PGR_CACHE`
: Cache root. Same as `--cache`; the flag wins.

Setting `PGR_CONTAINER` once per shell is the usual way to work.

## FILES

`<container>/library.sqlite`
: The database, and its WAL sidecars.

`<cache>/<source-id>/<photo-id>.<ext>`
: Materialized photo bytes. One level of structure, so clearing one source is a
directory removal rather than a thousand unlinks.

## EXIT STATUS

`0` on success. `1` on a command that could not do what it was asked — no library
at the container, no such source, an unknown preference, a refused clear, or a
failed `shuffle-test` assertion.

## EXAMPLES

Point every command at the same library as the agent, once per shell:

```
export PGR_CONTAINER="$HOME/Library/Application Support/Photo-Go-Round"
```

Add a folder and watch the queue fill behind it:

```
pgr_ctl source add --folder ~/Pictures/Wallpaper -r
pgr_ctl status
```

Prove the queue pop serialises across processes:

```
for c in a b c d; do pgr_ctl serve -n 40 --consumer "display-$c" & done; wait
```

Run the deck's correctness checks:

```
pgr_ctl shuffle-test --deals 50000 --photos 4000
pgr_ctl shuffle-test --deals 50000 --photos 4000 -w 1.0
```

## SEE ALSO

`photogoroundd(1)`, `Documentation/photogoroundd.md`, `PLAN.md`
