# pgr_ctl

## NAME

`pgr_ctl` — drive and inspect the Photo-Go-Round library from a terminal

## SYNOPSIS

```
pgr_ctl status
pgr_ctl sources {add [--folder [--recursive] <path>] [--file <path>] [--album <id>] … | list | remove <id> | enable <id> | disable <id>}
pgr_ctl refresh
pgr_ctl pool stats
pgr_ctl queue {peek [-n <count>] | fill [-n <rounds>]}
pgr_ctl deck stats
pgr_ctl cache {status | evict | clear [--source <id>] [--unavailable] [--yes]}
pgr_ctl shuffle-test [--deals <n>] [--photos <n>] [-w <fraction>]
pgr_ctl photos-spike [-n <count>] [--probe <count>] [--album <id|title>] [--albums]
pgr_ctl get [<key>] | set <key> <value>
pgr_ctl notify <topic>
pgr_ctl log [-f] [--last <time>]
pgr_ctl register | unregister | service-status
```

## DESCRIPTION

`pgr_ctl` is the rig. It is a separate binary from `photogoroundd` because the
service has exactly one job and answering questions is not it.

**It configures and inspects; it does not hand out pictures.** Every command here
opens the same SQLite database or writes the same preference domain, then rings a
Darwin notification — so the agent does not have to be running for any of it to
work, and when it is running it notices within a tick.

Getting a picture is the agent's job and does not live here: a client asks it
over HTTP and is handed bytes. From a terminal that is `curl`; see *Testing the
picture endpoint* in `README.md`.

It is internal and never ships: it is not in any distributed bundle, has no
signing or notarization pipeline, and carries no compatibility promise —
subcommands may change shape whenever a phase makes that convenient. Being
unshipped does not make it a scratch script, though. `shuffle-test` holds the
project's real correctness checks for the deck, and they exit non-zero so CI can
run them exactly as a person does.

**Where a source lives is a preference, not a row.** `sources add`, `remove`,
`enable`, and `disable` write to `UserDefaults` and then reconcile the database
in the same breath. The source table is a projection of the durable list, and the
agent reconciles the two on a thirty-second poll — so a row written straight into
the database is deleted again within half a minute.

## OPTIONS

### Where the library is

Every command has to agree with the running agent about the container, so these
are spelled exactly as the agent spells them.

`--prod`
Use the real library: `~/Library/Containers`, `~/Library/Caches`, and the real
preference domain. Without it everything lives under `<repo>/.build`, so a plain
run cannot disturb anything. All three move together, deliberately.

`--container <dir>`
Storage root. Defaults to `<repo>/.build/pgr-container`, or with `--prod` to
`~/Library/Containers/com.sydpolk.photogoround`.

`-d`, `--database <path>`
Database file. Defaults to `<container>/photogoround.sqlite` in both deployments.

`--cache-root <dir>`
Cache root. Defaults to `<repo>/.build/pgr-cache`, or with `--prod` to
`~/Library/Caches/com.sydpolk.photogoround`. Naming a container takes the cache
with it: give `--container` or `PGR_CONTAINER` and this defaults to
`<container>/cache` instead.

### Per command

`--folder <path>`, `--file <path>`
What `sources add` is adding, and required by it — at least one. Both are
repeatable, so several sources can be named in one command. Used by no other
command.

`--recursive`, `-r`
Walks subdirectories of the folder it precedes, and of no other. It belongs
between `--folder` and its path; standing on its own it is an error rather than a
setting for the command. Off unless asked for, because the surprising direction
is the expensive one: walking a home directory by accident costs minutes and
thousands of photographs nobody meant to add.

`--source <id>`
Scope `cache clear` to the one source with that id, instead of acting on all of
them. The id is the number `sources list` prints; note that it
is a row id in a disposable database, so deleting the library renumbers sources
from 1 and `--source 3` means "whichever is third now" rather than a particular
folder.

`--unavailable`
Scope `cache clear` to sources that are gone. These can never be re-fetched
anyway, which makes this the variant to reach for first: it frees space at zero
future cost.

`--yes`
Do not ask before clearing. Required when stdin is not a terminal.

`-n`, `--count <n>`
How many entries to peek at, or how many rounds to fill. Default: 10.

`-w`, `--window <0-1>`
Repeat window fraction for `shuffle-test`. Default: 0.5.

`--deals <n>`, `--photos <n>`
The size of the `shuffle-test` run. Defaults: 50000 deals across 4000 photos.

`--albums`
Make `photos-spike` list every collection with its local identifier instead of
summarising them by subtype. Several hundred collections is a thousand lines, so
it is off by default; reach for it when you need a particular album's
identifier.

`--probe <n>`
How many assets `photos-spike` asks about local availability without fetching
them. Separate from `-n` because the two cost wildly different amounts: a probe
is milliseconds, a pull can be minutes. Default: 200.

`--album <id|title>`
For `sources add`, a Photos album to add, by local identifier; repeatable and
mixable with `--folder` and `--file`. For `photos-spike`, which album to
measure, by identifier or by title — default: the largest that is not
`smartAlbumAllHidden`.

`-f`, `--follow`, `--last <time>`
Stream the log rather than printing it, and how far back to read. Default: 1h.

`-h`, `--help`
Usage.

Flags may appear anywhere, including before the subcommand. Positionals are
collected first and interpreted last, so `sources add --folder /a -r` and
`-r --folder /a sources add` mean the same thing.

## COMMANDS

`status`
Sources, pool, queue, cache, shuffle position, and the preferences in force.
The one command to run when something is wrong and you do not yet know what. It
prints which rung supplied the roots, so that is never a guess.

`sources add`
Adds one or more sources. `--folder <path>` enumerates a folder's contents;
`--folder --recursive <path>` walks its subdirectories too. `--file <path>` pins
one photograph — a first-class kind rather than a folder special case, since
pinning one photo and adding a folder of ten thousand are the same operation to
the deck. `--album <id>` adds a Photos album or smart album by its
`PHAssetCollection` local identifier, which `photos-spike --albums` prints.

An album identifier is opaque: its slashes are not path separators, it is not
standardized, and it is stored exactly as given. **Nothing is added unless it
resolves in this Photos library**, under the same all-or-none rule as a
mistyped path — and a library that cannot be read refuses too, rather than
accepting an album nobody can see.

Both flags are repeatable and may be mixed, and each folder keeps its own answer
about recursion:

    pgr_ctl sources add --folder --recursive ~/Pictures/Albums \
                        --folder ~/Pictures/Wallpaper

Each is written to preferences and then scanned immediately, rather than making
you wait for the agent's next pass. A path that is already a source is a no-op.
**Nothing is added unless every path resolves**, so a command naming three
folders with one misspelled adds none of them.

`sources list`
Every source with its id, kind, photo count, and state — `ok`, `disabled`, or
`UNAVAILABLE` with the reason. The id it prints is what the other subcommands
take. This is also what a bare `pgr_ctl sources` does, that being the harmless
reading.

`sources remove <id>`
Drops it from preferences; its photos and their queue entries go with it by
cascade. Its cached bytes are *not* deleted at that moment — the rows that named
them are gone, so nothing is left pointing at the files. A running agent
reclaims them on its next maintenance pass, which sweeps cached files no pool
entry claims. To free the space immediately, or with no agent running, use
`cache clear --source <id>` **before** removing it.

`sources enable <id>`, `sources disable <id>`
Switch a source off without discarding it. **Disabling is not removing**: the
photos leave the deck and the queue immediately, but keep their deal history, so
re-enabling brings them straight back where they were (_primarily for internal testing_).

`refresh`
Ask the agent to re-enumerate its sources, and return at once. **It does no
scanning itself**: the walk belongs to the agent, which reports what it is
refreshing and what each source took on its own console. Rescanning a network
share with thousands of photographs is minutes of work, and doing it here meant
enumerating it twice and blocking a terminal for the privilege.

Every enabled source, because the doorbell is a Darwin notification and those
carry no payload — `--source` is refused rather than quietly ignored. With no
agent running it says so: nothing will act on it, which is not an error but is
worth knowing.

`pool stats`
Rows per source, split by what explains everything else — referenced against
materialized, how much has bytes, and how much is claimed by a producer that is
fetching it right now.

`queue peek`
What is ready to serve, in order, head first. Takes `-n` for how many to show,
and reports the total. Peeking consumes nothing.

`queue fill`
Does the agent's topping-up by hand: asks every enabled source for a picture,
synchronously, and reports what each round produced. Takes `-n` for how many
rounds, and stops early when a round produces nothing. This is the only way to
fill a queue with no agent running.

`deck stats`
Where the shuffle stands, plus the distribution of showing counts. `times_shown`
is a statistic and nothing orders by it, which is what makes it the honest
measure: a spread of one to three across a library is a healthy fraction below
1.0, and a spread of three to four hundred is starvation.

`cache status`
Originals held, renderings held, how many photographs are referenced in place
rather than copied, how many are waiting for bytes, what is on disk against the
byte ceiling, and what is free on the volume. Also the number of queued pictures,
which are the ones eviction will not touch whatever their age.

`cache evict`
Runs an eviction pass now rather than waiting for the agent's maintenance
interval. Reports what went and what it freed, and says how many were left alone
because they are queued.

`cache clear`
Discards cached bytes, optionally scoped by `--source` or to
`--unavailable` sources. Prompts with data of how much would be cleared and asks
for confirmation to proceed. It does not touch anything else in the system, including
shuffle order (_internal testing only_).

`shuffle-test`
Test the shuffle algorithms against a dummy library of empty files and an in-memory
database (_internal testing only_).

`photos-spike`
Measure PhotoKit against the system Photos library: every album and smart album
summarised by subtype, how lazy `PHFetchResult` is, the resource
lists of an edited photograph and a Live Photo, whether `--probe` assets are
already on this machine and what asking costs, and `-n` originals pulled,
classified local or iCloud-optimized, and checked against the dimensions their
asset claims. It reads the library and never writes to it; the originals it
copies out go to a temporary directory and are deleted once measured.

It asks for `.readWrite` authorization, because `PHAccessLevel` has no read-only
level — `.addOnly` grants writing and nothing else. Run from a terminal the
grant lands on Terminal rather than on the agent's bundle, which is fine for
measuring and is why the same request has to be made again from the installed
agent before any of this is believed about the product (_internal testing
only_).

`get [<key>]`
Reads preferences. With no key it lists every setting with its stored value, or
`(default)` where nothing is stored. With a key it prints that value alone, for
scripts — an empty line if nothing is stored, rather than the default the agent
would use. An unknown key is an error.

`set <key> <value>`
Writes one preference, to the current domain. A running agent picks the change
up immediately. For a list of valid keys, see `get`.

`notify <topic>`
Announces that something changed, without changing it, so that every process
listening goes and looks. Valid topics are `prefs`, `sources`, `deck`, and
`cache` — the preferences, the source list, the shuffle's position, and the
cached bytes respectively.

The bell is scoped to the library, so it reaches only processes that have the
same database open. `--prod`, `--container`, and `--database` therefore decide
whose bell rings, and the posted name is printed so it can be checked against
the agent being watched.

`log`
What this project's processes have recorded. They all write to the system log
under one subsystem, and this reads back that subsystem and nothing else. `-f`
follows it as it happens; `--last` bounds how far back to read.

`register`, `unregister`
Add or remove the agent as a login item, via `SMAppService`. Only works from a
built bundle — see `./Scripts/make-agent-bundle.sh`.

`service-status`
What launchd makes of that registration: not registered, enabled, waiting for
approval in System Settings, or not found.

## ENVIRONMENT

`PGR_CONTAINER`
Storage root. Same as `--container`; the flag wins.

`PGR_DATABASE`
Database file. Same as `--database`; the flag wins.

`PGR_CACHE`
Cache root. Same as `--cache-root`; the flag wins.

Setting `PGR_CONTAINER` once per shell is the usual way to work.

## FILES

`<container>/photogoround.sqlite`
The database, and its WAL sidecars.

`<cache>/`
Materialized photo bytes. Only photos on volumes that can disappear are copied;
anything on the boot volume is read where it lies.

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
pgr_ctl sources add --folder --recursive ~/Pictures/Wallpaper
pgr_ctl status
```

Prove the queue pop serialises across clients. The port floats, so ask `status`
where the agent is rather than assuming a number:

```
PORT=$(pgr_ctl status | grep -o "localhost:[0-9]*" | cut -d: -f2)
for c in a b c d; do
  curl -sS -D - -o /dev/null "http://localhost:$PORT/v1/next?consumer=display-$c&w=1920&h=1080" &
done; wait
```

Run the deck's correctness checks:

```
pgr_ctl shuffle-test --deals 50000 --photos 4000
pgr_ctl shuffle-test --deals 50000 --photos 4000 -w 1.0
pgr_ctl photos-spike -n 20 --album Favorites
```

## SEE ALSO

`photogoroundd(1)`, `Documentation/photogoroundd.md`

`README.md`, *Testing the picture endpoint* — taking a picture, which is `curl`
against the agent rather than anything in this tool.
