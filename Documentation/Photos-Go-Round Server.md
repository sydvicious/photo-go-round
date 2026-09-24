# Photos-Go-Round Server(1)

## NAME

**Photos-Go-Round Server** — Photos-Go-Round library agent

## SYNOPSIS

**./Scripts/run-server.sh** \[`--release` | `--claude`] \[*options*]

The script builds the **Photos-Go-Round Server** target and runs the binary in
it, `Photos-Go-Round Server.app/Contents/MacOS/Photos-Go-Round Server`, passing
the options through.

## DESCRIPTION

**Photos-Go-Round Server** maintains a shuffled queue of photographs drawn from folders on
disk, keeps their bytes available, and serves them to whatever wants to display
one. It is an agent rather than a daemon — it runs in a user session and needs
one, because photo library access is per-user. Until 2026-09-22 it was named
the way a command-line service is named, `photogoroundd`.

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
  domain of the build you meant, refuses a key that does not exist,
  and makes the change take effect at once rather than at the next poll.

None of the four needs the agent running, which is the property worth having:
configuring the library and running it are separate acts.

A client changes one thing over HTTP rather than through any of the four: **the
source list**, which it can neither write safely nor read joined with what the
agent found. See **SERVICE**. The property above is untouched, because `pgr_ctl`
writes the same preferences with nothing running.

**Getting a picture does go through the agent.** It serves pictures over HTTP: a
client asks for one at the size it is about to draw at and is handed the bytes,
and never opens the database or the cache. That is what lets a screensaver inside
someone else's sandbox and an Apple TV across the network be the same kind of
client. See **SERVICE**.

**It is meant to run as a LaunchAgent**, so that launchd starts it at login and
restarts it if it stops. `Photos-Go-Round.app` installs and restarts it at every
launch, since 2026-09-21, from the copy inside its own bundle; the app's Help
menu installs or uninstalls it by hand, and ⌘R on the **Install Agent** scheme
is still the development route.
Nothing else has to be running for it to work, and it expects to be there before
any surface asks for a picture.

While developing, run it in a terminal instead:

    cd photos-go-round
    ./Scripts/run-server.sh

The wrapper script builds first, so a stale binary is never run. It builds Debug
unless told `--release` or `--claude`, and each build's agent opens that build's
own library and no other. A
detached `screen` or `tmux` session keeps it running after the terminal closes,
which is what a long unattended run wants.

## OPTIONS

**Each build has exactly one library, and nothing chooses another.** Syd,
2026-09-24: "They should be completely separate builds with completely separate
assets." Its container is `~/Library/Containers/<identifier>`, its cache
`~/Library/Caches/<identifier>`, and its preference domain `<identifier>` — all
three named alike, so a person reading any of them can find the other two. Until
that day each build also had a `.dev` library beside its real one, and a flag
chose between them; both are gone. `Scripts/scrub-dev.sh` deletes what the
retired libraries left behind.

**`<identifier>` carries the build configuration** — `com.sydpolk.photosgoround`, `….debug` or `….claude` by build configuration — so a
release, a Debug and an agent's build never share a database and can all run at
once. Everything is under the user's own home directory, so two people on one
Mac never share a library either.

`--port` *n*
Which port to serve pictures on, pinning it to a number you choose. Worth doing
when something has to reach the agent without asking where it is — a `curl` you
type by hand, a client with a hard-coded URL.

By default the agent binds a fixed port and publishes it to preferences under
`servicePort`, where every process on the machine can read it. **There is one
port per build configuration and per user**: a base of 20000 release, 23000
Debug, 26000 Claude, plus the FNV-1a hash of the user's short name modulo 3000.
So two agents can run side by side without either being told about the other,
two people on one Mac get different ports, and a client can compute the number
rather than chase one. Per user since 2026-09-21.

It was whatever the kernel gave at launch until 2026-09-17. Syd, that day:
"Perhaps we had better actually pick a port and hardcode it. this dynamic port
stuff is causing problems." Measured across five reboots, each launch took a
different port and the app showed *waiting for the agent* until it re-read the
preference — from the person's side, indistinguishable from the agent being
down.

**A port already held is still fallen back from**, and the kernel's choice
published in its place, so a fixed port that somebody else has taken degrades
rather than failing. `pgr_ctl status` prints the published address either way.

`--no-publish` (_internal testing only_)
Serve normally, but do not write `servicePort`. Nothing announces this agent, so
nothing follows it: the Mac app and every other client keep talking to whichever
agent they were already using.

For standing up a scratch agent beside a working one. `--container` and
`--cache-root` isolate storage but **not** the preference domain, which is where
the port lives — so without this a scratch run publishes over the real agent and
silently captures the app's window, serving it from a different library. Pair it
with `--port` and reach the agent at the number you chose; the bound port is
printed at startup either way.

It still keeps its domain's `serviceSecret`, and makes one there if there is
none: a secret names the user, not the process, so sharing it confuses nothing.
Its startup line names the domain to read it from, never the value.

The value is withdrawn when the agent stops. A crash leaves it behind, and a
client that tries it finds nothing listening — the same answer it gets when no
agent is running.

`--container` *dir*
Storage root, holding `photosgoround.sqlite` and its WAL sidecars. Defaults to
the build's own, `~/Library/Containers/<identifier>`.

`-d`, `--database` *file*
The database file, overriding its default position inside the storage root.
Defaults to `<container>/photosgoround.sqlite`.

`--cache-root` *dir*
Where copied photo bytes live. Defaults to the build's own,
`~/Library/Caches/<identifier>`. **Naming a container
takes the cache with it**: give `--container` or `PGR_CONTAINER` and the cache
defaults to `<container>/cache` instead, because somebody who named one
directory meant both.

The cache is deliberately not inside the container.
`~/Library/Caches` is a place the system may purge whenever it likes, which is
exactly right for bytes that can be fetched again and exactly wrong for the
database.

`--add-folder` \[`--recursive`] *path*
Add *path* as a source if it is not already one, then run. Written through to
preferences, so it need only be given once. Repeatable.

`--recursive` — or `-r` — walks subdirectories of the folder it precedes, and of
no other. It belongs between `--add-folder` and its path, so a flat directory and
a nested tree can be named in one invocation and each keeps its own answer:

    ./Scripts/run-server.sh --add-folder --recursive ~/Pictures/Albums \
                            --add-folder ~/Pictures/Wallpaper

Standing on its own, `--recursive` is an error rather than a setting for the run.
Recursion is off unless asked for, because the surprising direction is the
expensive one: walking a home directory by accident costs minutes and thousands
of photographs nobody meant to add.

`--once`
Do one pass — refresh, top up, maintain — and exit. For scripts and for
checking a configuration without leaving something running. It does not serve:
the listener is never started, so the published `servicePort` — a running
agent's included — is left exactly as it was found.

`-i`, `--interval` *seconds*
How often the main loop wakes. Default 2. This is not how often anything is
*done*; each activity has its own interval, below.

`--scan-interval` *seconds*
Override the `scanIntervalSeconds` preference for this run.

An album Photos did not answer is not left for a whole interval: it is walked
again after 30 seconds, then 60, 120 and 240, and after that only at the
interval. An album that answered *no*, and any folder, waits for the interval as
before. Every walk of an album logs
`WALK: … · first asset …ms · … assets · …ms` in the `photos` category, with
`· stopped` when the walk failed. A walk has 60 seconds to produce its first
photograph and 10 seconds between photographs after that.

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

The agent listens on localhost, on the port `pgr_ctl status` prints — see
`--port` — and answers one request that matters:

    GET /v1/next?consumer=<name>&display=<id>&w=<pixels>&h=<pixels>

**Every request carries this user's secret**, as

    Authorization: Bearer <serviceSecret>

and anything without it — or with someone else's — is answered `401
Unauthorized`, `WWW-Authenticate: Bearer`, and one line of text that every agent
says alike: *Open the dashboard from Photos-Go-Round's About box.* Loopback keeps
other machines out, not other accounts on this Mac, and the port is worked out
from the user name; the secret is what keeps another account's requests out. The
agent makes it on first launch and keeps it in its preference domain beside
`servicePort`, where only this user can read it — see *PREFERENCES*. Each
refusal is a console line, `401 <method> <path> · absent` or `· wrong`, with no
query and never the value. From a terminal:

    DOMAIN=com.sydpolk.photosgoround.debug
    PORT=$(defaults read "$DOMAIN" servicePort)
    AUTH="Authorization: Bearer $(defaults read "$DOMAIN" serviceSecret)"
    curl -sS -H "$AUTH" -o /tmp/pgr.bin "http://localhost:$PORT/v1/next?consumer=cli"

`README.md`, *Testing the picture endpoint*, has each configuration's domain.

    GET /v1/alive

answers `204` and nothing else, touching no database, cache or library: whether
this user's agent is up. It is what the app's launch check asks before it
installs the wallpaper and the screensaver. It still needs the secret, so
another account's agent answers it `401`.

`200` returns the picture, with `Content-Type` describing the format,
`X-PGR-Pixels` the size produced when a box was asked for — original bytes
carry no such header, since nothing was decoded to measure — and `X-PGR-Card`,
`X-PGR-Deal`, `X-PGR-Source` and
`X-PGR-Storage` describing the photograph and its place in the shuffle.
`X-PGR-Name` and `X-PGR-Source-Name` say what a person calls them, percent-encoded
because a header is ASCII and a filename is not: the name is a Photos
photograph's original filename, or its identifier — a folder photograph's path
inside the folder — when none is recorded, **with its extension removed**, since
the format sent is the one `Accept` chose rather than the original's; the source
name is a folder's or a
file's path, or `Photos › Trips › Holiday` for an album. **A Photos photograph's
filename is recorded when its original is fetched**, so one fetched before
version 12 of the database is named by its identifier until it is fetched again. `204 No
Content` means nothing could be served: the queue is empty, or nothing on it has
its bytes yet and the request's one wait is spent. It is an ordinary answer
rather than an error — a fresh library replies this way until the first fetch
lands.

**Serving takes the head of the queue, and waits for its bytes if they are not
here yet.** A card is dealt whether or not its photograph has been copied, and
the queue fetches its own cards behind the screen, so by the time a card reaches
the head its bytes are usually here. When they are not, the request waits up to
`serveWaitSeconds` for them. If they land, that is the picture. If the wait runs
out, the card is dropped — it was dealt but no bytes were served, and next time
it is dealt maybe they will be — and the request takes the new head, dropping
that too if its bytes are not here, until it meets a card that can be served or
the queue is empty. A card whose source has stopped answering is dropped without
waiting.

The wait is spent once per request; every cold card after it is dropped on sight.
A dropped card keeps its photograph, which goes back into the deck's contention,
and does not cancel a fetch already running for it: those bytes are still kept
when they land, and the next deal of that photograph finds them here.

The card leaves the queue as it is handed over, and it leaves whether or not the
download to the client completes. There is no reservation and nothing to reclaim
from a client that disappears mid-transfer; a failed download is a lost picture
and the client asks again. Two clients asking at once never receive the same
picture: the removal runs under the database's write lock, so exactly one wins
and the other looks again.

**`w` and `h` are maximums.** A resized image never exceeds either bound. What
comes back is the largest that fits inside them with its aspect ratio intact and
upright. Nothing is ever enlarged, so asking for a box larger than the original
returns the original's pixels; `X-PGR-Pixels` reports what was actually produced.
Naming neither returns the original bytes, untouched.

**A resize that takes longer than 1.5 seconds returns the original instead**,
untouched and without `X-PGR-Pixels`, and the agent's console says
`RESIZE: gave up after 1500ms on …`. A client must be ready to scale and orient
an original. Resizes run one at a time. The bound is the 95th percentile of
measured renders, so about one picture in twenty is served this way.

Today that is the only fit: shrink or grow, aspect ratio preserved. More options
will be added to the endpoint later.

The format comes from `Accept`: HEIC unless the client will take only JPEG, since
everything here decodes HEIC and it is roughly half the bytes. Every sized
request is rendered fresh, so the format asked for is always the format
returned. An `Accept` admitting neither HEIC nor JPEG is refused with `406`,
before any card is spent on it.

**A photograph that will not render is skipped**, and the next entry is tried, so
a bad file costs a client the picture it would have had and nothing else. After
three failures it is retired and never offered again. The row stays — the file is
still on disk, and deleting the row would only mean the next rescan found it
again.

**Resized copies are kept.** Each resize is saved as a copy of that photograph
for that `w`, `h` and format, in `.resized/` under the cache root, with a row in
the database. A request that matches a copy is answered from it without resizing,
even while another resize is running, and even when the photograph's original has
been evicted; a photograph can have a copy for every size asked for. A resize that finishes after its request has sent the original is
still saved. Copies count against `cacheByteCeiling` with the originals, and are
deleted with their photograph when it is deleted, not when its source is offline.

Serving is also what notices the queue has run short, and what deals more. **Every
card dealt is fetched by the queue's own fetcher**, head first and
`downloadConcurrency` at a time. A new card is placed at random among the cards
already queued — anywhere from second to last, never at the head — so a source
added to a running agent appears within a picture or two rather than after a
whole traversal, and a card has on average half the queue's worth of pictures
for its bytes to arrive before its turn. A fetch that
fails or does not answer within a minute drops its card from the queue; a source
that keeps failing to answer is left alone for a while, doubling each time, so
one dead share cannot hold every fetch lane. Nothing is fetched beyond the
queue's cards.

Every request is logged to the console with the photograph's name, the consumer,
the display it named, the source's row id and name, the size asked for, the deal
ordinal, the bytes, and the latency. A photograph with a recorded filename is
named by it with its identifier beside it, `IMG_0042.HEIC (C3D4…/L0/001)`; the
queue's own lines name it the same way.

### Sources

The same listener manages the source list, because **the database is private to
the service**: a client asks for what it needs and never opens the store.

    GET    /v1/sources           the list, with counts and availability
    POST   /v1/sources           add an array, all or none
    GET    /v1/sources/<uuid>    one source, with the options it was added with
    PATCH  /v1/sources/<uuid>    change one of those options
    DELETE /v1/sources/<uuid>    remove one

**A source is named by its `uuid`**, which is minted when the row is inserted and
is what names its bytes in the cache. The row id `pgr_ctl` prints is not stable —
the database is disposable and a rebuilt one renumbers from 1.

Answers are JSON. One source reads:

    {"uuid": "…", "kind": "folder", "locator": "/Users/me/Pictures/Sunsets",
     "recursive": true, "enabled": true, "available": true, "photos": 1284,
     "addedAt": "2026-08-23T18:04:11Z", "scannedAt": "2026-08-23T18:04:12Z"}

`recursive` is absent for kinds that have no such option, `unavailableReason`
appears only when `available` is false, and `photos` is how many that source has
put in the pool.

`POST` takes an array of `{kind, path, recursive}`; `kind` defaults to `folder`,
and `folder` and `file` are the two that can be added. **All of them or none of
them** — one path that does not resolve refuses the whole batch with `400`, names
every path that was missing, and writes nothing. A path that exists but is not
the kind it was asked for as — a file named as a folder, or the reverse — refuses
the batch the same way, naming each under `mismatched`; and `recursive` on a
`file` source is refused exactly as `PATCH` refuses it. A path already listed is
not added twice, and a request that creates nothing answers `200` with an empty
array rather than `201`. A body over 1 MB is refused with `413`.

**Changes go through preferences, exactly as `pgr_ctl`'s do**: the service writes
the durable list on the client's behalf and reconciles the table from it before
answering, so one request is one write and one doorbell. **Adding does not wait
for the scan** — the answer carries the new source's `uuid` and a count of zero,
and the count arrives on a later `GET`.

`PATCH` takes `{recursive}` — the only option a folder has today — and answers
with the source as it now stands. A field left out is one that is not being
changed, which is why this is a `PATCH` and not a `PUT`; a body that asks for
nothing is refused, and so is recursion on a `file` source, which has no such
option. The source keeps its `uuid`, its cached bytes, and its place in the
shuffle: changing a checkbox is not remove-and-re-add.

**Switching recursion off removes the nested photographs**, which is the same
rule as any other departure — a photograph that is no longer in its source is
dropped whether it was deleted, or the folder stopped reaching that far. They go
at the next refresh, and any that is asked for before then is dropped at that
moment rather than served. Switching it back on finds them again at the next
refresh.

`DELETE` answers `204`, and takes the source's photographs and queue entries with
it. Removal is not deletion: nothing on the source is touched. **The cached bytes
go at once** — the originals we copied — rather than waiting for a restart to
notice nothing claims them.

Enabling, disabling, and refreshing are not here. They stay in `pgr_ctl`, which
keeps the database and preferences and never makes a web request.

### Dashboard

    GET /dashboard                             a page for a browser
    GET /dashboard/dashboard.css               its stylesheet
    GET /dashboard/dashboard.js                its script
    GET /v1/dashboard                          what the page shows, as JSON
    GET /v1/dashboard/thumbnail?photo=<id>     a small JPEG of one photograph
    POST /v1/dashboard/code                    a one-time code, for the secret

The agent prints the dashboard's address when its listener is ready. **The page
redraws itself every second**, and says `not answering` when the agent stops
replying.

**A browser cannot send the secret, so it is let in by a code.** The About box's
link asks `POST /v1/dashboard/code`, with the secret, and is answered
`{"code": "…"}` — good once, and for sixty seconds. It opens
`/dashboard?code=<code>` in the browser, and the agent answers `303 See Other` to
`/dashboard` with a cookie, so the code does not stay in the address bar. The
secret never reaches the browser: the cookie's name and value are both derived
from it, so it survives the agent's restarts, ends when the secret is rotated,
and two agents' cookies in one browser do not overwrite each other. It is kept
for 400 days, the most a browser allows, and **admits the `GET`s above and
nothing else** — every other request still needs the secret. A page that loses
it stops polling and says to open the dashboard again from the About box.

The page, stylesheet and script are `MacOS/Agent/Dashboard/Resources/dashboard.html`,
`dashboard.css` and `dashboard.js`, read from the agent's app bundle, or from that
folder when the agent has no bundle. A missing one is `500`, naming where it was looked for.

The thumbnail is `503` with `Retry-After: 1` when its resize takes longer than one
second; the page keeps the image it has and asks again.

It shows the last picture served, with a caption, and how many photographs the database holds, how many each source added and
removed since the agent launched, how many originals the cache
holds, how many cards are queued against `queueSize`, the bytes the cache
occupies against its ceiling, the free space on the cache's volume against the
floor below which fetching stops, how many pictures each consumer has been
handed since launch, what serving and dealing found in the cache and what
eviction took from it since then, and the errors standing now or reported in
the last minute.

    {"photos": 5093,
     "libraryChanges": [{"source": "/Volumes/Photos/2019", "sourceRemoved": false,
                         "added": 212, "removed": 3}],
     "cached": 212, "queued": 18, "queueSize": 20,
     "cacheBytes": 624000000, "cacheCeilingBytes": 1000000000,
     "freeBytes": 212000000000, "freeFloorBytes": 5000000000,
     "served": {"app": 14, "wallpaper": 2},
     "serveLookups": {"hits": 15, "landed": 1, "timedOut": 0, "leftDuringWait": 0,
                      "droppedWithoutWaiting": 3},
     "fetchLookups": {"hits": 4, "misses": 31, "fetched": 27, "failed": 1, "timedOut": 2},
     "last": {"photo": 4821, "consumer": "app", "at": "2026-09-12T17:14:31Z",
              "source": "/Volumes/Photos/2019", "name": "Rice Homecoming.jpeg",
              "externalID": "Rice Homecoming.jpeg"},
     "evictions": {"photos": 36, "bytesFreed": 106000000, "passes": 4,
                   "lastAt": "2026-09-12T17:10:02Z", "lastCeilingHalved": false},
     "errors": [{"kind": "cache.fetch-failed.source-6", "count": 4, "standing": false,
                 "message": "CACHE: IMG_0042.HEIC (C3D4…/L0/001) (source 6) failed — The network connection was lost.",
                 "firstSeen": "2026-09-12T17:14:02Z", "lastSeen": "2026-09-12T17:14:35Z"},
                {"kind": "source.paused.source-6", "count": 1, "standing": true,
                 "message": "CACHE: source 6 paused for 120.0 seconds — it has stopped answering",
                 "firstSeen": "2026-09-12T17:14:35Z", "lastSeen": "2026-09-12T17:14:35Z",
                 "until": "2026-09-12T17:16:35Z"}],
     "since": "2026-09-12T14:02:11Z", "at": "2026-09-12T17:14:40Z"}

**`last` is the picture most recently handed over** with a `200`, and is absent
until one has been. `source` is what `X-PGR-Source-Name` said, and `name` is
what `X-PGR-Name` said with the extension kept, since this names the original
file rather than the bytes sent; both are taken when it was served, so a source
removed since keeps the name it was served under. `externalID` is the
identifier, which for a folder photograph is the same as `name`.

**`errors` is one row per kind of trouble, most recently seen first.** Every red
line on the agent's console and every error it logs is recorded under a kind — a
short fixed name such as `cache.timed-out.source-6` or
`serve.library-unavailable` — so an error that keeps happening is one row with a
`count` rather than a new line each time. `message` is the most recent report's
words, since the photograph or the queue depth on a line changes while the
trouble does not. A kind about one source ends in that source's row id. A red
line with no kind is grouped by its exact words, and `kind` is then absent. An
event reported both on the console and in the log is recorded once. At most 100
kinds are kept; past that, the error seen longest ago gives way, and a standing
condition only when no other is left. The record starts empty at launch and is
not kept.

**An error leaves `errors` a minute after it last happened; a standing condition
stays until it clears.** `standing` marks one of these: a source unavailable,
recorded at every refresh that finds it so and gone at the first that does not;
a source empty, gone at the first scan that finds photographs or cannot reach
it; and a source paused after failed fetches, gone when the pause ends, which
is `until`. A source's standing conditions go when it is removed or disabled. On a standing
condition, `firstSeen` is when this run first found it rather than when it
began, and `count` is how many times it has been found. An error that happens
again after leaving is a new row, counted from one.

**A fetch that produces no bytes is `cache.fetch-failed`**, under its source,
with the reason the fetch gave: the source's own error, the source disabled or
gone, the cache's volume at `cacheMinimumFreeBytes`, the original fetched and
not kept. Each is one of the fetches counted in `fetchLookups.failed`. A fetch
given up on is `cache.timed-out` instead, and is not recorded again if it fails
afterwards.

**`libraryChanges` is one row per source that has added or removed a photograph
since launch**, ordered by name. `added` counts photographs a refresh put in the
database; one already there through another source is not added. `removed`
counts photographs that left it: a refresh that no longer found them, a fetch or
a serve whose source confirmed them gone, and the source itself being removed.
`source` is what the source is called now, or was called when it was removed,
and `sourceRemoved` says it was. Changes `pgr_ctl` makes from its own process
are not counted, and a source it removed is named `source` and its row id.

The thumbnail fits 480 pixels either way and is never enlarged. **Asking for one
takes no card and counts as nothing served.** It is drawn from the original, in
the cache or in place: a photograph that is not here — evicted since it was
served, or its file gone — is `404`, and so is an id the database does not
hold. `photo` missing or not a number is `400`; an original that will not
decode is `422`.

`freeBytes` is absent when the volume will not say. `served` counts only `200`s,
keyed by the `consumer` each request named, including `cli` and `anonymous`.
`libraryChanges`, `served`, `serveLookups`, `fetchLookups`, and `evictions`
start empty at launch and are not kept.

**The cache index at launch is what the database recorded**, not a walk of the
cache directory: the agent opens its port in milliseconds and checks the disk
afterwards. A photograph whose file has gone since is an ordinary miss, fetched
again. The walk runs once at launch and every `cacheWalkIntervalSeconds`, on a
thread of its own, and logs `CACHE WALK: … held · … · … discarded · …ms`.
Nothing is evicted until the first walk has finished, since a total nothing has
checked is not one to delete photographs over.

**Preferences are read on every request**, so a changed `cacheByteCeiling` or
`queueSize` is in the next reading once the agent has re-read its preferences —
at once after `pgr_ctl` or the app writes one, within thirty seconds after a
bare `defaults write`. The cache itself shrinks to a lowered ceiling when the
agent next writes a file to it, so the page can show it over its ceiling until
then.

**A serve lookup is a queued card reaching the head of the queue with its photograph
stored in the cache** — materialized, not referenced in place, which never
touches the cache. It is a hit when the original is there. Otherwise it is a
miss, and a miss ends one of four ways: `landed`, the request waited and the
bytes arrived; `timedOut`, it waited and they did not; `leftDuringWait`, the
card's fetch failed while it was waited for; or `droppedWithoutWaiting`, the
request's one wait was already spent or the card's source is benched. Misses are
the sum of those four. A request can meet several cold cards before it serves
one, and each is a miss, so hits and misses together can exceed pictures served.

**A fetch lookup is a materialized card being dealt.** It is a hit when the
original is already in the cache, and a miss when it is not and the card goes
to the queue's fetcher; on a large library most are misses. `fetched`, `failed`,
and `timedOut` count what became of each fetch since launch — including fetches
for cards dealt before it, so on a restart they can briefly exceed `misses` —
and a miss whose card was served or dropped before its fetch finished has no
outcome. It is counted at the deal because the fetcher only ever asks for cards
whose originals are not held. Referenced photographs are counted on neither
side.

**`evictions` counts what eviction took from the cache.** The agent evicts
after every file it writes there — an original a fetch brings in, and a resized
copy — and at no other time. `photos` and `bytesFreed` are totals across
`passes`, the eviction passes that evicted anything; `lastAt` is when the most recent of those ran, absent
until one has. `lastCeilingHalved` says that pass was aiming at half the byte
ceiling because free space was below `cacheCriticalFreeBytes`, so it was the disk
driving eviction rather than the cache's size. `pgr_ctl cache evict` and
`cache clear` run in another process and are not counted, and neither are bytes
that left because their photograph or source left the library.

Neither route writes to the request log, since an open page asks once a second.
Anything other than `GET` is refused with `405`.

## PREFERENCES

State the agent derives lives in the database and is disposable. Everything the
user *chose* lives in preferences, which is therefore the only durable thing —
including the source list. Delete the database and the sources come back; the
agent rescans and the only cost is time.

That also makes `defaults write` a control channel. The agent re-reads
preferences on a thirty-second poll, so a change takes effect on a running agent
without restarting it and without any cooperation:

    defaults write com.sydpolk.photosgoround sources -array-add \
        '{kind = folder; locator = "/Users/me/Pictures/Sunsets"; recursive = 1; enabled = 1;}'

| key | meaning | default |
| --- | --- | --- |
| `sources` | array of `{kind, locator, recursive, enabled}`; `recursive` is per source and defaults off | none |
| `repeatWindowFraction` | how much of the library must pass before a photo repeats | 0.5 |
| `queueSize` | cards to keep queued. A target, not a ceiling. Also how far ahead of the screen the cache fetches, since the queue fetches its own cards | 20 |
| `queueRefreshIntervalSeconds` | how often to top the queue up; serving tops it up too | 5 |
| `serveWaitSeconds` | how long a request waits for the head card's bytes before dropping that card; spent once, after which every cold card met is dropped without waiting. 0 never waits, and still drops | 2 |
| `scanIntervalSeconds` | how often to rescan sources for changes | 300 |
| `downloadConcurrency` | fetches running at once, across all sources | 4 |
| `cacheByteCeiling` | bytes of cached originals and resized copies to keep | 1 GB |
| `cacheMinimumFreeBytes` | stop fetching below this much free space | 5 GB |
| `cacheCriticalFreeBytes` | evict ahead of the ceiling below this much | 2 GB |
| `cacheWalkIntervalSeconds` | how often to check the cache index against the disk | 3600 |

Every read is a parse with a default and a clamp, because `defaults write` accepts
anything. An out-of-range value is logged and clamped rather than honoured.

**Two keys are the agent's to write, and not preferences at all.** `servicePort`
is where it is listening, published when its listener is ready and withdrawn when
it stops. `serviceSecret` is what every request must carry: 64 hex digits, made
on first launch and kept, and never withdrawn — it names the user, not the
process. A value the agent could not have made is replaced. Neither is listed by
`pgr_ctl get`. Only this user can read the domain, which is the whole of why the
secret works. **To rotate it**, delete it and restart the agent, which the next
launch of the app does anyway; every client reads it again on its next request:

    defaults delete com.sydpolk.photosgoround.debug serviceSecret

## FILES

*storage-root*`/photosgoround.sqlite`
Sources, the photo pool, the queue, and cache bookkeeping. Written in WAL
mode, so `-wal` and `-shm` sidecars sit beside it and "delete the database"
means deleting all three.

*cache-root*`/`
Copied photograph bytes. Only photographs on volumes that can disappear are
copied; anything on the boot volume is read where it lies and costs nothing
here.

The service walks this directory at startup and rebuilds its index from the
filenames, and a file the database does not claim is deleted rather than adopted.
**The filesystem is the truth**; the database records which photographs are held
so that the queue's fetcher can find the cards that still need bytes and eviction
can order what is held by when it was last seen, and that record is reconciled
against this walk at every launch. A disagreement is settled in the disk's
favour, always.

|                | storage root | cache root |
| --- | --- | --- |
| default, every build | `~/Library/Containers/<identifier>` | `~/Library/Caches/<identifier>` |
| container named | as given | `<container>/cache` |

**One library per build, and the build decides it.** Storage, cache and
preference domain share one name. Relocating the storage root does not move the
preferences — `PGR_PREFS_SUITE` does — so a scratch run that named only a
container would still read the build's real source list; which is why a
relocated run does not write folders through to it.

`pgr_ctl status` prints which of those rungs supplied the roots, so it is never
a guess, and the agent prints the same three lines at startup.

## EXIT STATUS

In normal operation this is an agent that never exits. It runs until something
stops it — a signal, launchd, or the terminal it was started from going away.

It exits with a non-zero return code for a fatal operational error: an unreadable
option, a storage root that cannot be created. A folder named at launch that does
not exist is not fatal — it is written through to preferences and marked
unavailable by the scan, exactly as a folder that disappears later would be.

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

`pgr_install(1)`, `Documentation/pgr_install.md` — what installs this agent as a
LaunchAgent, and what ⌘R on **Install Agent** runs.

`README.md`, *Testing the picture endpoint* — driving the service with `curl`.
