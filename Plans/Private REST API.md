# Summary

The agent grows a support surface at `/private`: one HTML page of buttons, and a
GET URL behind each one that runs a `pgr_ctl` command and shows the answer. It
is undocumented, loopback-only, and reachable from any browser on the machine.

# Rationale

When something is wrong on somebody else's Mac there is nothing to tell them to
do. `pgr_ctl` is the rig and it is not shipped; the dashboard shows numbers but
changes nothing; and the four routes the agent serves exist for the app, not for
a person. Syd, 2026-09-19: this is "part of supporting existing users" — an
instruction that fits in one line, "open this URL", against an agent already
running on their machine. It is also the cheapest way to make the eleven
commands worth having reachable without shipping a binary that carries no
compatibility promise.

# Phases

Read-only first, then mutating, then mutating with arguments. Each phase leaves
a page you can open.

- **Phase 1 — `/private` exists, and `status` works.** The whole path end to
  end: the endpoint, the route claim, the HTML shell, the index of buttons, and
  one command answering.
- **Phase 2 — The rest of the read-only commands.** `sources list`, `pool
  stats`, `deck stats`, `queue peek`, `cache status`, `get`, `wallpaper get`.
  - Nothing here changes anything, so the whole set can land at once.
  - Source paths are user data rendered into HTML; escape them.
- **Phase 3 — Mutating commands with no free-form argument.** `refresh`, `cache
  evict`, `queue fill`, `notify <topic>`.
  - `notify` and `queue fill` take an argument from a fixed set, so they are
    buttons, not fields.
- **Phase 4 — Commands taking arguments.** `set`, `wallpaper set`, `sources
  add|remove|enable|disable`, `cache clear` with `--source` and `--unavailable`.
  - Inputs on the page build the URL and navigate; the URL is the command.
  - `cache clear`'s confirmation is **not decided** — see below.
- **Phase 5 — Where an undocumented surface is written down.** It is out of the
  man pages by design, so it needs somewhere else, and `README.md` needs to know
  it exists.

# Design Decisions

- **`pgr_ctl` is not reimplemented and stays standalone.** Syd, 2026-09-19: "I
  retract that then. pgr_ctl should work standalone and not be reimplemented
  with the api." It opens the database directly, so it works with the agent
  down, which is exactly when it is wanted.
- **Eleven command families, not fifteen.** Syd, 2026-09-19: "ditch
  shuffle-test, log, register. Keep the cache clear."
- **A typed URL runs the command, and `/private` is a page of buttons that
  navigate to those same URLs.** Syd, 2026-09-19: "the private page would just
  have a button to press which would navigate to the typedURL." One mechanism,
  not a page of forms plus a set of URLs.
- **A mutating GET does the thing; there is no confirmation page.** Syd,
  2026-09-19. The exposure that comes with it is recorded below and accepted.
- **Two namespaces.** `/v2/…` stays RESTful and is what the app calls;
  `/private/…` is the GET-invocable support surface. Syd, 2026-09-19: "two
  namespaces".
- **`/private` is a support page and need not be API-formal.** Syd, 2026-09-19.
  It answers HTML for a person, not JSON for a program.
- **`/v2` does not grow here.** It grows when a client needs it, which is
  `Installing by launching the app` and the menu-bar plan's business, not this
  one.
- **The handlers call `PhotoGoRoundKit`, which the agent already links.**
  *Claude's.* Not `pgr_ctl`, which is a binary; the Kit is where the operation
  lives and is what makes the CLI and the page the same behaviour.
- **The page, stylesheet and script are files in `Sources/photogoroundd/js/`.**
  *Claude's*, following the dashboard — Syd, 2026-09-16: "these files should go
  in the same directory the agent sources are in, with a subdirectory /js."
  Same two-place lookup: the app bundle's `Contents/Resources` first, the source
  folder second.
- **`/private` is present in Release.** *Claude's.* A support page that only
  exists on the developer's machine supports nobody.

# Background

- The agent serves four things today: `GET /v1/next` (pictures, and the fallback
  for anything unclaimed), `/v1/dashboard` with `/dashboard` and its thumbnail,
  `/v2/sources` (`GET`, `POST`, `DELETE`, and `POST …/<uuid>/reconnect`), and
  `/v2/photos/{albums,authorization}`.
- `Router` dispatches by prefix, dashboard first so its once-a-second poll never
  reaches the request log. Anything unclaimed goes to the pictures, which owns
  "no such endpoint" and "only GET is served".
- The listener is `NWListener` with `requiredInterfaceType = .loopback`. Ports
  are fixed per variant: 9427 release, 9428 Syd's Debug, 9429 an agent's build,
  with a kernel fallback when one is taken.
- `Documentation/pgr_ctl.md` is the command surface this mirrors. Fifteen
  families; eleven in scope.
- `DashboardPage` is the precedent for serving HTML from the agent, including
  reading the files on every request so an edit shows on the next reload.

# Detailed discussions

## What `/private` is, and what it is not

It is a page a person opens when something is wrong, with a button for every
command and the answer rendered underneath. It is not a REST API, not versioned,
carries no compatibility promise, and nothing programmatic should depend on it —
the same standing `pgr_ctl` has, moved to a surface that needs no install.

The practical test for every decision here: can the instruction be one line?
"Open `http://localhost:9427/private`" is one line. "Open `/private`, scroll to
Cache, press Clear" is still one screen. Anything that needs a paragraph has
gone wrong.

## The commands, and the URLs behind them

Read-only, Phases 1 and 2:

- `GET /private/status` — the one page to open first. Sources, pool, queue,
  cache, shuffle position, preferences in force, and which rung supplied the
  roots.
- `GET /private/sources` — id, kind, photo count and state per source: `ok`,
  `disabled`, or `UNAVAILABLE` with its reason. The ids the other commands take.
- `GET /private/pool` — rows per source: referenced against materialized, how
  much has bytes, how much a lane is fetching now.
- `GET /private/deck` — where the shuffle stands and the distribution of showing
  counts, with the remote half's share of the histogram beside it.
- `GET /private/queue` — the deck head first, `?n=` to narrow. Peeking consumes
  nothing.
- `GET /private/cache` — originals held, referenced in place, waiting for bytes,
  bytes against the ceiling, free on the volume, queued pictures.
- `GET /private/prefs` — every setting with its stored value, or `(default)`.
- `GET /private/wallpaper` — the wallpaper domain's own settings. One key,
  `interval`.

Mutating, Phase 3:

- `GET /private/refresh` — rings the doorbell and returns at once. Every enabled
  source, because a Darwin notification carries no payload. With no agent
  running there is no page to have opened, so the CLI's "nothing will act on
  it" case cannot arise here.
- `GET /private/cache/evict` — one eviction pass, reporting what went.
- `GET /private/queue/fill?n=` — deals synchronously, reporting each round.
- `GET /private/notify?topic=` — `prefs`, `sources`, `deck`, `cache`. Four
  buttons, not a field.

Mutating with arguments, Phase 4:

- `GET /private/prefs/set?key=&value=`
- `GET /private/wallpaper/set?key=interval&value=` — a *Shuffle All* tag such as
  `thirtyMinutes`; anything else is refused with the list of valid tags.
- `GET /private/sources/add?folder=&recursive=&file=&album=` — repeatable, mixed,
  and all-or-none: three folders with one misspelled adds none of them.
- `GET /private/sources/remove?id=`, `…/enable?id=`, `…/disable?id=`
- `GET /private/cache/clear?source=&unavailable=`

Path spellings are Claude's. They are deliberately shorter than the CLI's words
because a person types them.

## `cache clear`, and the confirmation that has nowhere to go

**Not decided.** `pgr_ctl cache clear` "prompts with data of how much would be
cleared and asks for confirmation to proceed", and `--yes` is what skips it. The
decision above is that a mutating GET does the thing — so the faithful
translation and the agreed mechanism disagree on exactly one command.

Three ways out:

- **Drop the confirmation.** `/private/cache/clear` clears. Consistent with
  every other button, and cached bytes are refetchable — nothing is lost but
  time and bandwidth. It is the only irreversible-feeling command in the set and
  it is not actually irreversible.
- **Two URLs.** `/private/cache` already reports what is held, so the button
  next to that number is the confirmation: you are looking at the figure when
  you press it. `/private/cache/clear` then clears with no further ceremony,
  and the one-line support instruction still works.
- **Mirror the CLI.** `/private/cache/clear` shows what would go and offers a
  button to `…/clear?yes=1`. Faithful, and the only place on the page where a
  button does not do what it says.

Claude's preference is the second: it is the first in behaviour, and it is
honest about where the confirmation actually lives.

## Why a mutating GET, and what it costs

Any page open in any browser on the Mac can fire one — `<img
src="http://localhost:9427/private/cache/clear">` on a page you visit runs it,
and no `Origin` check helps, because an image load sends none. A same-origin
check would work against `fetch`, which is what the earlier discussion proposed,
and does nothing against this.

This is decided and is recorded here rather than argued: Syd, 2026-09-19, asked
for typed URLs and the page both, and then for the page to be buttons that
navigate to those URLs, which is the same thing. The exposure is bounded by what
the commands can do — refresh, evict, clear, deal, set a preference, ring a
bell, add or remove a source. Nothing reads the library out, nothing leaves the
machine, and `GET /v1/next` already hands any local process a photograph.

Worth knowing rather than acting on: the two existing write routes, `POST
/v2/sources` and `DELETE /v2/sources/<uuid>`, have the same exposure today and
always have.

## Where the implementation lives

`PhotoGoRoundKit` holds the operations, and both the agent and `pgr_ctl` already
link it — so the page and the CLI are the same behaviour by construction, not by
being kept in step. Anything a `/private` handler needs that is only in
`Sources/pgr_ctl/` moves down into the Kit as part of the phase that needs it,
which is the one real refactor in this plan.

`status` is the likely example: it is a composite of six things the Kit already
knows separately, assembled in `InspectCommands.swift`. That assembly moves; the
formatting stays where it is, because a terminal and an HTML page want different
shapes and neither should pretend otherwise.

## HTML, not JSON

`/private` answers `text/html`, because the reader is a person with a browser
and a support instruction cannot include "pipe it through `jq`". The dashboard
already establishes the pattern — page, stylesheet and script as files in
`Sources/photogoroundd/js/`, read on every request so an edit shows on reload,
found in the app bundle's `Contents/Resources` first and the source folder
second.

The one place this bites is that a command's answer is a table, and eleven
commands means eleven table shapes. The cheapest honest thing is one renderer
over rows of label-and-value plus a monospace block for anything that is really
terminal output, rather than eleven bespoke layouts.

## What testing this needs

`/private` is deliberately undocumented, so *documented means tested* does not
reach it through the man pages. It still needs coverage, and the three things
worth testing are the three that can be wrong without anyone noticing:

- **The route table.** That `/private/cache/clear` reaches the clear and not the
  cache report, and that an unknown path under `/private` is answered there
  rather than falling through to the pictures' 404 — `Router` sends anything
  unclaimed to the pictures, so a missed claim is a silent misroute.
- **Argument parsing.** A missing `id`, an unknown `topic`, a `value` that is
  not a valid *Shuffle All* tag, `n` that is not a number. Each should say what
  was wrong, on the page, rather than 500.
- **HTML escaping.** Source paths, preference values and album identifiers are
  all user data rendered into the page. A folder named with an `&` or a `<`
  should appear, not break the page. An album identifier is opaque and stored
  exactly as given, which makes it the likeliest carrier.

Tests log under `com.sydpolk.photogoround.tests`, as everything else does.

## What this does not build

- **No authentication, and no token.** Loopback and obscurity are the whole
  defence, which is the decision above.
- **No `/v2` growth.** Nothing here adds a REST route. When the menu-bar app
  needs `cache status` over HTTP it adds `/v2/cache`, and `/private` is
  unaffected.
- **No change to `pgr_ctl`** beyond operations moving down into the Kit, which
  it links already.
- **Nothing about `log`, `shuffle-test`, `register`, `unregister` or
  `service-status`.** Dropped by decision. `log` in particular stays
  `/usr/bin/log`'s job; the support instruction for it is a command line, not a
  URL.
- **No decision about shipping the agent at all.** `/private` being present in
  Release assumes there is a Release, which `Build Plan.md` still owes.

# References

- `Documentation/pgr_ctl.md` — the command surface this mirrors, and the source
  of every behaviour described above.
- `Sources/photogoroundd/Service/Router.swift` — prefix dispatch, and the
  fallback to the pictures that makes a missed claim silent.
- `Sources/photogoroundd/Service/DashboardEndpoint.swift`,
  `DashboardPage.swift`, `Sources/photogoroundd/js/` — the precedent for
  serving a page from the agent.
- `Sources/photogoroundd/Service/SourceEndpoint.swift` — the existing write
  routes, and the versioned-path handling.
- `Sources/PhotoGoRoundAgentAPI/Host/ServiceAddress.swift`, `Plans/Service Port
  Plan.md` — which port a variant binds.
- `Plans/Build Plan.md` — *What "install" means, per product*, and the Release
  story this assumes.
- `TODO.md` — *Installing by launching the app*, *A menu-bar app for shipping*,
  which are what will pull `/v2` forward.
- Indeed's "Poodlepants", which is what Syd is describing. Not looked up; the
  description in this document is his.
