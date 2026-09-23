# Summary

Several people can use Photos-Go-Round on one Mac, each with their own agent and library. Each agent serves only its own user: it holds a secret of that user's, publishes it beside its port, and refuses any request that does not carry it.

**Complete, 2026-09-23.** All six phases are done, on branch `multi-user-support`. One problem it found is left as later work in `TODO.md`: *The wallpaper goes grey after switching users*.

# Rationale

The agent is per-user by design, installed in each user's `~/Library/LaunchAgents` with its own database. But it listens on loopback, and every account on the Mac shares loopback. Each user's agent now has its own port, but the port is worked out from the user name, so anyone logged in can compute another user's port and fetch their pictures from it. Where two names hash to the same port, the second user's app already mistakes the first user's agent for its own. Syd, 2026-09-21: "the danger is that the second user send a request to the first user's agent on the default port."

# Phases

- **Prerequisite — The app installs everything.** *Done 2026-09-22, in `Release App Installer.md`.* Syd, 2026-09-21: "We need to implement the app installing everything first, though." Then, 2026-09-22: "ok, the app should be ready for multiple users."
- **Phase 1 — Measure the boundary.** *Done 2026-09-22; both halves hold.* See *Where it is readable*.
  - Another account cannot read this user's preferences plist: `~/Library` and `~/Library/Preferences` are `drwx------`, the plists `-rw-------`.
  - The saver still reads it as a file and the wallpaper extension through the suite; the secret sits in the same file.
- **Phase 2 — The agent keeps a secret and checks it.** *Done 2026-09-23*: `ServiceSecret`, `Preferences.establishServiceSecret()`, `ServiceGate`.
  - Made on first launch, kept across launches, published as `serviceSecret` beside `servicePort`. No secret, no agent.
  - A `ServiceGate` in front of the `Router` answers `401` to any request without it.
- **Phase 3 — Every client sends it.** *Done 2026-09-23.* The app's own test bundle compiles and has not been run: its host app installs when launched.
  - `PictureClient` (the app's window, the saver), the wallpaper extension's own request in `AgentPicture`, the app's `SourceService`.
  - The launch check, `AgentProbe`: the published port, the secret, and a `401` is not its agent.
  - `pgr_ctl status` says whether a secret is published, never what it is. It makes no requests, so it sends nothing.
- **Phase 4 — The dashboard, by one-time code.** *Syd's choice, 2026-09-22. Done 2026-09-23*, and checked by hand on Syd's Debug install; see *Checked by hand*.
  - `POST /v1/dashboard/code`, sent with the secret, returns a code good once for sixty seconds.
  - `GET /dashboard?code=…` sets a cookie and redirects to `/dashboard`; the cookie admits the dashboard's `GET`s and nothing else.
  - The About box's link fetches a code, then opens the browser.
- **Phase 5 — Documentation.** *Done 2026-09-23.*
  - `README.md`'s and `Documentation/pgr_ctl.md`'s `curl` examples read the port and the secret from preferences, and each is run by a test.
  - `Documentation/Photos-Go-Round Server.md` lists `serviceSecret` and says what a `401` means.
- **Phase 6 — Two users at once.** Syd logs in as a second user with the first still logged in; both agents serve, and each user sees only their own pictures.
  - Syd's way, 2026-09-23: uninstall everything in his own account, archive the app, put it in `/Applications`, run it there; then switch to `randyarbuckle` and run it again. See *Phase 6, by hand*.
  - ***Done 2026-09-23.*** Every step in *Phase 6, by hand* passed — Syd: "everything looks good". The ports differ (20172 and 21458). The runs found three faults that are not the secret's, all fixed; see *What Phase 6 found*:
    - A first launch in a fresh account missed the launch check, so the wallpaper and the screensaver were not installed. The check now waits 90 s, allows 5 s per attempt, and logs why it is waiting.
    - The agent stopped answering altogether while CacheDelete was slow: its free-space query held a process-wide lock. Free space now comes from `statfs(2)`.
    - With both fixes installed, the check still missed on Randy's next launch: it asked `/v1/dashboard`, the heaviest read there is. It now asks `GET /v1/alive`, which answers `204` and touches nothing.
  - **Left as later work:** switching users leaves the other account's wallpaper grey when it comes back. In `TODO.md`, *The wallpaper goes grey after switching users*.

# Design Decisions

*Claude's proposals except where marked.*

- **A per-user secret.** *Syd's, 2026-09-21: "yes, write it up as Phase 4 with the per-user secret".* It works over the TCP every client already speaks, and travels the way the port already does. See *Why a secret*.
- **Kept, not remade each launch.** The app restarts the agent on every app launch; a new secret each time would send every running client back to re-read it.
- **Sent as `Authorization: Bearer`, published as `serviceSecret`.** A header keeps it out of URLs.
- **No secret, no agent.** If one cannot be made, the agent exits rather than serving unguarded.
- **A refusal is a `401` with one line, the same from every agent:** *Open the dashboard from Photos-Go-Round's About box.* *Syd's, 2026-09-23.* It helps whoever hits it and says nothing about whose agent it is.
- **The check is a gate in front of the router, not inside it.** Endpoints and their tests stay as they are; one type owns every credential.
- **The comparison is constant-time.** A local attacker timing answers on loopback is exactly who this plan is about.
- **Which port each agent binds stays as `Release App Installer.md` built it.** With the secret in place, a request that reaches the wrong agent is refused, not served.
- **The launch check asks the published port, not the hashed one.** The hashed port is predictable, so it is the one another account can hold; the secret must not be sent there.
- **Nothing ever sends the secret to the hashed port.** *Syd's, 2026-09-23.* `Service Port Plan.md`'s Phase 2 may still try that port first, but without the secret.
- **A `401` is its own failure, not *agent not running*.** A client re-reads the secret once and tries again before reporting it.
- **The window still says *Waiting for Photos*.** *Syd's, 2026-09-23.* A refused secret is told apart in the log, not on the screen.
- **The dashboard trades a one-time code for a cookie.** *Syd's, 2026-09-22.* The secret never reaches the browser or its history.
- **The cookie is derived from the secret, and so is its name.** It survives the agent's restarts, and two agents' cookies in one browser cannot overwrite each other, since cookies ignore ports.
- **The cookie lasts until the secret is rotated**, capped at the 400 days browsers allow. *Syd's, 2026-09-23.* A bookmarked dashboard survives browser restarts.
- **The cookie admits only the dashboard's `GET`s.** A hostile page on another localhost port can make your browser send it, but cannot use it to change anything.
- **A `--no-publish` agent uses its domain's secret too.** It prints where the secret is, never the value.
- **Documented examples share one setup block**, `DOMAIN`, `PORT` and `AUTH`, and each example uses `$PORT` and `-H "$AUTH"`. One place to get right, and one shape for the test to check.
- **The documented examples are read and run.** *Syd's, 2026-09-23.* Every `curl` in the docs must carry the header, and the README's and `pgr_ctl.md`'s examples are run through `zsh` against a gated listener.
- **The launch check waits 90 s, allows 5 s per attempt, and says why it is waiting.** *Syd's, 2026-09-23: "do 1 and 2".* A first launch in a fresh account took 21.6 s to publish its port and was slow to answer after it.
- **The launch check asks `GET /v1/alive`, which the agent answers `204` without touching anything.** *Syd's, 2026-09-23: "add /v1/alive and point the probe at it".* The question is whether the agent is up; `/v1/dashboard` answered a much bigger one. It stays behind the gate, so a `401` still means someone else's agent.
- **Free space comes from `statfs(2)`, not `volumeAvailableCapacityForImportantUsageKey`.** *Syd's, 2026-09-23: "make the statfs change".* The old key waits on CacheDelete inside a lock every URL lookup in the process needs; `statfs` waits on nobody. It counts no purgeable space, so fetching stops a little sooner on a nearly full disk.

# Background

- **Already per-user:** the agent's LaunchAgent plist, its database and container, and its preference domain. The binary stays in the one app bundle. Syd, 2026-09-10: "the agent MUST be installed in ~/Library/LaunchAgents; this needs to support multiple users on the same machine."
- **The agent checks nothing about who is asking.** Loopback keeps other machines out, not other accounts on this one.
- **Since 2026-09-21 the port is per user:** 20000, 23000 or 26000 by build, plus FNV-1a of the short name modulo 3000 (`BuildVariant.port`). Syd's Debug agent is on 23172.
- **The saver, the wallpaper extension and the app's windows read the published `servicePort`**, so they reach their own user's agent even after a collision.
- **The app's launch check did not, until Phase 3.** `AgentProbe.answers(on: BuildVariant.current.port)` polled the hashed port and counted any HTTP answer, a `404` included, as its agent (`LaunchInstall.swift`).
- **The saver reads preferences as a file**, because its sandbox hands back an empty suite; see `ServicePort`. **The wallpaper extension reads the suite**, and makes its own request rather than using `PictureClient`.
- **The dashboard opens in the person's browser**; `AboutView` builds the link.
- **The agent was renamed on 2026-09-22**: `photogoroundd` is now `Photos-Go-Round Server`, and its man page `Documentation/Photos-Go-Round Server.md`.

# Detailed discussions

## The danger

The agent binds loopback and serves anything that connects. Loopback is shared by every account on the Mac, so:

- **Deliberately, today:** the port is computed from the user name, which every account can see, so anyone logged in can work out another user's port, `curl http://localhost:<port>/…`, and get their pictures, their sources, and the dashboard. The per-user port made this a step harder than a fixed 9427, not impossible.
- **By accident, today, on a collision.** Two names with the same hash want the same port. The second user's agent falls back to a kernel port and publishes it, so their pictures are right — but their app's launch check polls the hashed port, finds the first user's agent, and reports its own agent as answering whether it started or not.
- **By accident, if `Service Port Plan.md`'s Phase 2 is ever built:** clients would try the hashed port first, and on a collision show the first user's pictures on the second user's desktop and screensaver. Nothing on either side would notice.
- **Not by accident otherwise:** the saver, the wallpaper extension and the app's windows read their own user's published port.
**How likely.** Syd, 2026-09-23: "the agent's http is in the user space, so nobody can connect to it from another machine. So the only exposure is two hostile users on the same machine. Highly unlikely, although could happen via phishing, I suppose." Loopback does keep other machines out. The item below is the phishing-shaped route, and the likelier of the two.

- **From a web page, today.** Not a second account at all: a page that rebinds its own host name to `127.0.0.1` can read anything the agent serves, because the agent answers every request. The secret closes this too — a rebound page has neither the header nor the cookie, which belongs to `localhost`.

## Why the app installer came first

*Claude's reading of Syd's "We need to implement the app installing everything first."* Until 2026-09-21 the agent, the saver and the wallpaper extension were installed by ⌘R on an `Install …` scheme or by `Scripts/install-*.sh`, from a developer's Xcode, so a second user on the same Mac had no way to install their own copy. **Done 2026-09-22:** every launch of the app installs and restarts that user's agent, and a Release build also registers the wallpaper and links the screensaver. See `Release App Installer.md`. Phase 6 can now be run.

## Which port each agent binds

*Settled by `Release App Installer.md`, 2026-09-21.* Syd: "use three different base addresses based on build variants, and then add a hash of the user name to it to come up with the port. If there is a collision, let the agent pick one, and we fall back to the existing mechanim."

So two users no longer race for one number: each wants their own, from 20000, 23000 or 26000 by build plus FNV-1a of the short name modulo 3000. A collision is unlikely but possible, and the loser takes a kernel port and publishes it.

**This settles binding, not reading.** The port is predictable to anyone who knows the user name, and any request that reaches an agent is served. The options this section weighed before — first come first served, a small scan, the fixed port plus the published value — are all replaced by the hash, and none of them was ever the danger. The secret is what fixes that.

## Where it is readable

*Measured 2026-09-22, as Syd, on his Mac.* The design rests on one fact: **another account cannot read this user's preferences plist**, while the sandboxed saver and wallpaper extension still can.

**Other accounts.**

```
drwxr-x---@  jazzman  staff  /Users/jazzman                 0: group:everyone deny delete
drwx------+  jazzman  staff  /Users/jazzman/Library         0: group:everyone deny delete
drwx------+  jazzman  staff  /Users/jazzman/Library/Preferences
-rw-------@  jazzman  staff  com.sydpolk.photosgoround.debug.dev.plist
-rw-------@  jazzman  staff  com.sydpolk.photosgoround.plist
```

The Mac has two other accounts, `jadeocho` and `randyarbuckle`. Both are in `staff`, so they can list the home directory, but `~/Library` admits only its owner, and the plists are the owner's alone. No ACL grants anything back. Measured from the permission bits, not by logging in as another account and trying — that is Phase 6, which does it for real. Asking `cfprefsd` for another user's domain is refused to anyone but root; expected, not measured.

**The sandboxed readers.** From the unified log:

```
21:04:08  Photos-Go-Round Wallpaper  system-wallpaper: port 23172 from the com.sydpolk.photosgoround.debug.dev suite
21:04:20  legacyScreenSaver          saver: agent on port 23172 via file
```

The saver's sandbox refuses the suite and it reads the `.plist` as a file; the wallpaper extension reads the suite. Either way it is the same domain, and the secret is a second key in it, so whatever reads the port reads the secret. The one thing not covered is timing: a secret written seconds ago may not be on disk yet for the saver's file read. That only matters on an agent's very first launch, since the secret is kept, and a client that finds a port but no secret yet waits, as it would for no port.

**What else could expose it**, checked in the code:

- `Preferences.all()`, which `pgr_ctl get` prints and the agent logs at launch, lists `allKeys` only; `servicePort` is not in it, and `serviceSecret` will not be.
- Nothing passes it on a command line, so it is not in `ps`.
- The agent's console output goes to the unified log under `console`, which admin accounts can read; the secret is never printed or logged. Only whether it was absent or wrong.

## How the secret works

1. **On first launch the agent makes a random secret** of 32 bytes from `SecRandomCopyBytes`, as 64 lowercase hex digits, and stores it in its own preferences. Later launches reuse it. A stored value that is not 64 hex digits — a `defaults write` gone wrong — is replaced and the replacement logged.
2. **It publishes it as `serviceSecret`**, in the same domain and the same way as `servicePort`, so every client that can find the port can already find the secret. It is not withdrawn on exit, unlike the port: it names the user, not the running process.
3. **If no secret can be made, the agent does not start.** `SecRandomCopyBytes` failing is next to impossible, and an agent that served unguarded because of it would be the one failure this plan exists to prevent.
4. **Every request must carry `Authorization: Bearer <secret>`.** A missing or wrong one gets `401 Unauthorized`, `WWW-Authenticate: Bearer` — which HTTP asks of every `401` — and a plain-text body of one line, identical from every agent: *Open the dashboard from Photos-Go-Round's About box.* *Syd's, 2026-09-23*, over an empty body that a browser shows as a blank page. The plan's first draft had it empty so that an agent not yours would say nothing about whose it is; a line every agent says alike keeps that, and the product's name is no secret on a Mac where it is installed. The agent logs one line naming the method, the path, and whether the secret was absent or wrong. Never the value.
5. **The comparison is constant-time**: every byte of the longer of the two is looked at, and a difference in length counts as a difference, so an answer's timing says nothing about how much of a guess was right.

**Rotating it** needs nothing new: `defaults delete <domain> serviceSecret` and restart the agent, which the next app launch does anyway. Every client re-reads it on its next request. Worth a line in the man page; not worth a command.

## The gate

`ServiceGate`, in the agent, sits between the listener and the `Router`:

```
listener → ServiceGate.handle(request) → Router.route(request)
```

It decides, in this order:

1. **A `Bearer` header.** Right: the request goes on, and `POST /v1/dashboard/code` is answered by the gate itself. Wrong: `401`, logged as *wrong*.
2. **`GET /dashboard?code=…`.** A live code is spent, and the answer is `303 See Other` to `/dashboard` with the cookie set. A dead one falls through to the cookie, so a stale link in a tab that already has a cookie still opens.
3. **The cookie**, on a `GET` of a path `DashboardEndpoint.claims`. Right: on it goes. Wrong: `401`.
4. **Nothing.** `401`, logged as *absent*.

**Why a gate and not a change to `Router`.** `Router` is built by `DashboardEndpointTests` and exists so a test can hold the dispatch; a secret it had to be given would either be a parameter every such test invents, or a default that turns checking off — and a default that disables security is one edit from shipping. The gate is its own type with its own tests, and the endpoints never learn that credentials exist.

**Why not inside `HTTPListener`.** The listener is transport. `ListenerPortTests` and `RequestBodyTests` speak raw HTTP to it and would all need the header for reasons that have nothing to do with them.

**A `--no-publish` agent** still reads the secret from its domain, and makes one there if there is none. A secret is not per process, so writing it into a shared domain is harmless — the real agent reuses it. Its line becomes *not published — reach this agent at http://localhost:<port>, with the serviceSecret in <domain>*.

## The dashboard

*Decided 2026-09-22.* Syd, choosing between putting the secret in the link once and a one-time code: the one-time code.

**The exchange.**

1. The About box's link still reads `http://localhost:<port>/dashboard` — it is still where to find the port — but it is a button now, not a `Link`.
2. Clicked, the app sends `POST /v1/dashboard/code` with the secret. The agent answers `{"code": "<32 hex digits>"}`, good once and for sixty seconds.
3. The app opens `http://localhost:<port>/dashboard?code=<code>` in the default browser.
4. The gate spends the code and answers `303 See Other`, `Location: /dashboard`, `Set-Cookie: <name>=<value>; Path=/; Max-Age=34560000; HttpOnly; SameSite=Strict`.
5. The browser loads `/dashboard` with the cookie. Its stylesheet, its script, the once-a-second `fetch("/v1/dashboard")` and the thumbnails all carry it: same origin.

The code is in one URL, and so in the browser's history. That is the point of it: by the time anyone reads the history, it is spent and expired.

**The codes** live in memory, in an actor, dropped when they expire or are spent. An agent restart forgets them, which costs nothing: the next click asks for another.

**The cookie's value** is `HMAC-SHA256(secret, "dashboard cookie")`, in hex. Not a value made per launch: the app restarts the agent on every launch, and a per-launch value would turn every open dashboard into a blank page each time. Not the secret itself either, since the browser keeps what it is given in its own files. Derived, it lasts as long as the secret does and changes when it is rotated.

**The cookie's name** is `pgr-` followed by the first twelve hex digits of `HMAC-SHA256(secret, "dashboard cookie name")`. Cookies are kept by host and path and ignore the port, so Syd's Debug, Release and Claude agents — and another user's, in a shared browser — would each overwrite the others' cookie if they shared a name, and every switch between two dashboards would log the other one out. A name per secret keeps them apart and gives nothing away. The plan's first draft said *"a cookie set by one user's agent is sent to the other user's agent … it has to be a rejection and not a confusion"*: with distinct names it is neither; the other agent never looks at it.

**It admits the dashboard's `GET`s and nothing more.** `SameSite=Strict` keeps other *sites* from sending it, but every port on `localhost` is the same site. So a page served from another user's port on this Mac, opened in your browser, can make your browser send your cookie to your agent. It cannot read the answers — that is the same-origin rule — but it could `POST` to `/v2/sources`, if the cookie were accepted there. Restricted to the dashboard's `GET`s, which change nothing that matters, it buys that page nothing.

**It lasts until the secret is rotated, as near as a browser allows.** *Syd's, 2026-09-23*, choosing it over a cookie that dies when the browser quits and over thirty days: a bookmarked dashboard keeps working across browser restarts. `Max-Age` is 400 days, the most Chrome will keep any cookie; a longer one is cut to that silently, so asking for more would only make the header lie. Every agent restart leaves it valid, since its value is derived from the secret, and rotating the secret ends it.

**When the cookie is gone** — cleared by hand, past 400 days, or the secret rotated — the page's script sees `401` from its poll, stops polling, and says to open the dashboard again from Photos-Go-Round's About box. Reloading such a page gets the `401`'s one line, which says the same.

## Clients

- **`PictureClient`**, used by the app's picture window and the saver, reads the secret beside the port through `ServicePort`, by the same two routes, and adds the header. Its failures gain two:
  - **`.noSecret`** — a port is published and no secret beside it: an agent from before this plan, or a first launch not yet on disk. Treated like no port: wait and ask again.
  - **`.notOurs(port:)`** — the agent answered `401`. Before throwing, it reloads the preferences once and, if the secret changed, asks again.
  - Both reach the window as `Waiting for Photos`, the words it uses for every agent trouble, with the difference in the log line. *Syd's, 2026-09-23*, asked whether a refused secret earns words of its own: no — the person at the glass can do nothing about either.
- **The wallpaper extension**, `AgentPicture`, makes its own `URLSession` request for each deployment's domain in turn. It reads the secret from the same domain, adds the header, and treats a `401` like no answer: log it and ask the next domain.
- **The app's `SourceService`** reads `serviceSecret` beside `servicePort` and adds the header. A `401` is `Failure.notOurs`, after the same one retry, and the panel says *The agent on this port refused this account's secret.* It also asks for the dashboard's code, being the app's one client of the agent's JSON.
- **`pgr_ctl`** makes no requests at all — command-line HTTP is `curl`, by design. `status` gains whether a secret is published. It never prints one: `defaults read` is there for anyone who needs it, and a tool that printed it would put it in terminal scrollback and shell history.
- **The launch check, `AgentProbe`.** Today it polls the hashed port for thirty seconds and counts any HTTP status as its agent. With the secret it re-reads the published port and the secret on every attempt — the agent it just restarted withdraws one port and publishes the next — sends the secret, and counts only an answer that is not `401`. `LaunchInstall.Steps.live` hands it the app's own preferences, `MacHostEnvironment(deployment: .development)`, the deployment the installed agent runs.

## What it does not stop

- **A hostile user who takes your port first.** The hashed port is predictable, so another account can start a listener on it before you log in. Your agent falls back to a kernel port and publishes it, and your clients follow the published value — but anything of yours that sends the secret to the hashed port hands it to that listener, which can then use it on your real agent. That is why the launch check moves to the published port. **`Service Port Plan.md`'s Phase 2 — clients try the fixed port first — may be built, but never sends the secret there.** *Syd's, 2026-09-23*, choosing it over dropping that phase. The secret goes to the published port only. One consequence to carry into that phase: without the secret, every agent answers `401`, so the hashed port can say *something is answering* but never *it is yours*. It can be a hint, never the answer.
- **Anything running as the same user.** It can read the secret. That is the same boundary the library itself has.
- **Root.** Likewise.
- **The browser's own files.** The dashboard cookie is in the user's browser profile, under their home directory — the same boundary again.

## Documentation

**Where the examples actually are.** This plan used to say `Documentation/photogoroundd.md`'s `curl` examples; that man page had none. They are in `README.md`, *Testing the picture endpoint* and *Managing sources over HTTP*, and one in `Documentation/pgr_ctl.md`. The README's all used port 9000, which had been wrong since the port became per user. *Done 2026-09-23:* every example now reads `$PORT` from the setup block, and the man page's *SERVICE* gained one of its own.

**One setup block, then the examples:**

```
DOMAIN=com.sydpolk.photosgoround.debug.dev
PORT=$(defaults read "$DOMAIN" servicePort)
AUTH="Authorization: Bearer $(defaults read "$DOMAIN" serviceSecret)"
```

```
curl -sS -H "$AUTH" -D - -o /tmp/pgr.bin "http://localhost:$PORT/v1/next?consumer=cli&w=3840&h=2160"
```

with a line on which domain each configuration uses. That fixes the stale port as well, and gives the test one thing to look for.

**`Documentation/Photos-Go-Round Server.md`** gains `serviceSecret` in its preferences, a paragraph on the `401` and the dashboard's code, and how to rotate. *Done 2026-09-23*: *SERVICE* for the secret and the refusal, *Dashboard* for the code and the cookie, *PREFERENCES* for the two keys the agent writes and rotating, and `--no-publish` for the secret such an agent keeps. `Documentation/pgr_ctl.md`'s `status` says its service line shows whether a secret is published, never the value.

**The test does both halves.** *Syd's, 2026-09-23*, over only running them or only reading them. It starts `/bin/zsh` and `/usr/bin/curl` as child processes, as `AgentLifecycleTests` already starts the built agent.

It finds every fenced block in `README.md` and `Documentation/*.md` that calls `curl` and requires `-H "$AUTH"` on each call. Then it runs the README's and `pgr_ctl.md`'s examples through `zsh` against a gated listener on a kernel port, with `DOMAIN` pointed at a scratch preference file holding that listener's port and a secret, `/tmp/` pointed at a scratch directory, and anything after `&& open` dropped, so nothing opens Preview. The route behind the gate answers every request, so what is tested is that each example gets through the gate as written. Each has to be admitted; the same example without the header has to be refused.

## Checked by hand

*2026-09-23, Syd's Debug build, installed after uninstalling the old one; domain `com.sydpolk.photosgoround.debug.dev`, port 23172.*

- **The secret was made and published:** `defaults read … serviceSecret` has one line.
- **Without it, refused:** `curl` of `/v1/dashboard` answered `401 Unauthorized`, `WWW-Authenticate: Bearer`, and *Open the dashboard from Photos-Go-Round's About box.*
- **With it, served:** the same request with `-H "Authorization: Bearer …"` answered `200`.
- **The saver found both through the file:** `saver: agent on port 23172 via file`, then `saver: secret via file`.
- **The wallpaper was served:** after the new agent started at 08:26:14, both of its requests came back `200` with a picture.
- **The dashboard link works**, from the About box. Syd.
- **Not reported:** the picture window and Settings › Sources, which send the secret through the same code the tests cover.

**One thing seen on the way, and it is the upgrade, not a fault.** A dashboard tab left open from before the install went on asking `/v1/dashboard` once a second, and the agent logged `401 GET /v1/dashboard · absent` for each, across the agent's restart. That tab was still running the old script, which has no cookie and never stops asking. The new script stops at its first `401` and says to reopen from the About box. Closing the tab ended it. Anyone upgrading with a dashboard open will see the same, once.

## Phase 6, by hand

*Planned 2026-09-23.* Syd, on `randyarbuckle`: "That account has a lot of sensitive pictures, so I won't be taking screenshots or movies, and I won't be giving you log snippets." So every check below prints a status code, a count or a permission error, and nothing about the pictures leaves that account. What comes back to Claude is a yes or no, or a number, per step.

An archived app is a Release build, so both agents use the domain `com.sydpolk.photosgoround.dev`. Nothing here is secret: `serviceSecret` is only ever read inside the account it belongs to, and never printed.

**In `jazzman`:**

1. Uninstall everything from earlier builds.
2. Archive the app, and put it in `/Applications`.
3. Run it from `/Applications`. It installs its agent, wallpaper and screensaver at launch.
4. Note this agent's port, for step 11:

   ```
   defaults read com.sydpolk.photosgoround.dev servicePort
   ```

**Switch to `randyarbuckle`, leaving `jazzman` logged in:**

5. Run the app from `/Applications`.
6. **`jazzman`'s preferences cannot be read from here.** This is Phase 1 measured for real, from another account. Expect *Permission denied*:

   ```
   cat /Users/jazzman/Library/Preferences/com.sydpolk.photosgoround.dev.plist
   ```

7. **This account's agent made a secret.** Expect `1`:

   ```
   defaults read com.sydpolk.photosgoround.dev serviceSecret | wc -l
   ```

8. **This account's port**, for step 12. Compare it with step 4's: they should differ, since each is a hash of the user name. A match is a collision, and worth knowing.

   ```
   defaults read com.sydpolk.photosgoround.dev servicePort
   ```

9. **This account's agent serves this account.** Expect `200`; `-o /dev/null` keeps the answer off the screen, and `--max-time 20` turns a hang into `000`:

   ```
   curl -s --max-time 20 -o /dev/null -w "%{http_code} %{time_total}s\n" -H "Authorization: Bearer $(defaults read com.sydpolk.photosgoround.dev serviceSecret)" "http://localhost:$(defaults read com.sydpolk.photosgoround.dev servicePort)/v1/dashboard"
   ```

10. **By eye:** the window, the wallpaper and the screensaver show this account's pictures and none of `jazzman`'s.
11. **This account's secret, sent to `jazzman`'s agent, is refused.** Expect `401`. The first line is `jazzman`'s port — 20172 on 2026-09-23; change it if step 4 said otherwise. (Pasted with the word `PORT` in the URL, as the first version of this step had it, `curl` never connects and prints `000`.)

    ```
    OTHER_PORT=20172
    curl -s --max-time 20 -o /dev/null -w "%{http_code}\n" -H "Authorization: Bearer $(defaults read com.sydpolk.photosgoround.dev serviceSecret)" "http://localhost:$OTHER_PORT/v1/next?consumer=test"
    ```

**Back in `jazzman`:**

12. **And the other way.** Expect `401`. The first line is `randyarbuckle`'s port — 21458 on 2026-09-23; change it if step 8 said otherwise.

    ```
    OTHER_PORT=21458
    curl -s --max-time 20 -o /dev/null -w "%{http_code}\n" -H "Authorization: Bearer $(defaults read com.sydpolk.photosgoround.dev serviceSecret)" "http://localhost:$OTHER_PORT/v1/next?consumer=test"
    ```

13. **By eye:** this account still shows its own pictures, and none of `randyarbuckle`'s.

## What Phase 6 found

*The first run, 2026-09-23.* Everything here came back as timestamps, status codes, process states and a stack sample — nothing about `randyarbuckle`'s pictures. **All thirteen steps passed**, with the build carrying `/v1/alive`: another account cannot read this one's preferences; each agent made its own secret and serves its own account; each account's secret is refused by the other's agent, both ways; the ports differ (`jazzman` 20172, `randyarbuckle` 21458); and each account sees only its own pictures. Syd, 2026-09-23: "everything looks good." Reported as a verdict, not as output — nothing came back from `randyarbuckle`'s account but yes, no, and numbers.

**The unified log is shared by every account on the Mac.** `log show` in one account prints the other's lines too — and the agent's served lines name photographs — so every log command in this plan filters to lines that cannot. Claude reads no agent lines from `randyarbuckle`'s account.

### 1. A first launch in a fresh account missed the launch check

In `randyarbuckle`'s account the app bootstrapped the agent, waited, logged `agent: not answering`, and skipped the wallpaper and the screensaver — so neither appeared in System Settings. In `jazzman`'s, three minutes earlier, the same archive installed all three with the agent answering in 1.2 s.

| `randyarbuckle`, first launch | time | since bootstrap |
|---|---|---|
| agent bootstrapped | 08:57:49.97 | 0 |
| `serving on port 21458`, before the listener | 08:58:08.04 | 18 s |
| listener ready, port published (`dashboard at …`) | 08:58:11.58 | 21.6 s |
| the app's check gives up | 08:58:24.21 | 34 s |

`jazzman`'s agent took 0.2 s from bootstrap to `serving on port`. Randy's built its container, cache and database from nothing, on a Mac at load 85–160 (see 3). Once it was listening, the check still failed for nine seconds: each attempt had 2 s, the agent was too busy to answer `/v1/dashboard` in that, and the last attempt ended in a timeout three seconds past the deadline.

Installing both from the Help menu afterwards worked, and both then appeared.

**Fixed** (`AgentProbe`): patience 30 s → 90 s, each attempt 2 s → 5 s, and the install log says why it is still waiting whenever the reason changes — no port published yet, no secret yet, a refused secret, a timeout, a refused connection — and why it gave up. A reason, never the secret and never anything served. *Not changed:* the wallpaper and the screensaver still wait for the agent, Syd's rule of 2026-09-21 ("the agent has to be up and running first"); installing them regardless was offered and not chosen.

### 2. The agent stopped answering while CacheDelete was slow

Minutes later `randyarbuckle`'s agent answered nothing at all — step 9's `curl` hung — while `ps` showed it runnable at 0% CPU. Syd took a stack sample in that account into `/Users/Shared` (function names and library paths only). Every one of the agent's threads that mattered was waiting on one thing:

- **The main thread**, for the whole sample: `URL.resourceValues(forKeys:)` for `volumeAvailableCapacityForImportantUsageKey` → CoreServices → `CacheDeleteCopyAvailableSpaceForVolume` → a synchronous XPC call to CacheDelete that never answered.
- **Four request lanes and the evictor**, for the whole sample: `-[NSURL resourceValuesForKeys:error:]` → `_FileCacheLock` → waiting on an `os_unfair_lock`.

CacheDelete is the system service that counts purgeable space. The free-space query waits on it while holding CoreServices' process-wide file cache lock, so one slow answer stops every URL property lookup in the agent — requests, eviction, the refresh walk. The agent asks for free space in four places (`PhotoCache.freeBytesOnVolume()`): the dashboard's status, dealing, fetching and eviction.

**Not the secret's, and older than this plan.** It needs CacheDelete to be slow, which a fresh login on a loaded Mac made it; it could happen in any account.

**Fixed:** `PhotoCache.freeBytes(onVolumeOf:)` reads `statfs(2)` — one system call, no other process — at the nearest existing ancestor of the cache root. It counts no purgeable space, so on a nearly full disk with much purgeable data fetching stops a little sooner. `FreeSpaceTests`.

### 3. The Mac was saturated by Shortcuts indexing both accounts

Load average reached 162 on ten cores, with 67 processes runnable. The biggest users were `BackgroundShortcutRunner` (up to 78%, relaunching every minute or so in both accounts), `coreaudiod`, `SecurityAgent`, `WindowServer`, `storagekitd` and `opendirectoryd`. `BackgroundShortcutRunner` wrote about 48,000 log lines in three minutes across uid 501 and 502, almost all under `com.apple.shortcuts` `ToolKitDatabase`, `ToolKitExecution` and `AppIntentsMetadata` — Shortcuts rebuilding its catalogue of every app's actions, apparently for the app newly in `/Applications`. Counted by category; no message was read. Syd: `randyarbuckle` has no shortcuts and no dialog was showing, and Photos-Go-Round declares no App Intents. It is macOS's, and it settled by itself (load 62 by 09:24).

It is the likely reason both 1 and 2 surfaced: the first launch was slow because everything was, and CacheDelete was slow for the same reason. The same load failed 18 kit tests in one run — `PhotosSourceEditingTests` and `SilentLibraryTests`, the load-sensitive suites `TODO.md` already holds — which passed once it fell.

### 4. With both fixes installed, the check still asked too big a question

*11:07, the same day.* The first attempt at a retest ran this morning's 08:52 build: a 09:27 archive existed but had not replaced the copy in `/Applications`, so neither fix was in it. Checking the build's date first — and a string only the new build carries — is now part of retesting. With an 11:01 build installed, `jazzman`'s launch answered in 0.7 s. `randyarbuckle`'s did not, and the new log said why:

```
11:07:29  agent restarted — waiting — no port published yet
11:07:56  waiting — nothing from 21458 within 5 s      (port published after ~27 s)
11:09:08  gave up after 98 s — nothing from 21458 within 5 s
11:10:47  (next launch) waiting — no port published yet
11:10:48  answering                                     (1.5 s)
```

The agent was up and listening, and `/v1/dashboard` missed its five seconds on every attempt for 72 seconds. That route was chosen because it asks nothing of the photo library, but it is the heaviest read the agent serves — counts over the whole photo table, the cache's totals, changes by source — and just after a restart the agent was walking its cache and refreshing a large library on the same database, on a Mac still at load 60–150. The Help menu installed both without waiting, and the next launch answered in 1.5 s.

**Fixed:** `Router.alive` answers `GET /v1/alive` with `204` before any endpoint is consulted — no database, cache or library, no request line — and `AgentProbe` asks it. It is behind the gate like everything else. An agent from before it answers `404` from its picture endpoint, which has still passed the gate and so still counts. `AliveTests`; `Documentation/Photos-Go-Round Server.md`, *SERVICE*.

### 5. A step that could be pasted unchanged

Step 11's first version had `PORT` in the URL for the reader to replace; pasted as written it printed `000`, `curl` never connecting. Steps 11 and 12 now set `OTHER_PORT` on a line of its own, holding the port seen that day, and the `curl` commands carry `--max-time 20` so a hang comes back as `000` rather than never.

### 6. Switching users leaves the other account's wallpaper grey

*11:22, with the 11:19 build in both accounts.* `jazzman`'s wallpaper was showing a picture at 11:19. At 11:22:41 Syd switched to the login window from Control Center; at 11:22:51 `randyarbuckle`'s session started; at 11:22:52 `jazzman`'s wallpaper extension exited on SIGTERM. Back in `jazzman`, WallpaperAgent — the same process as at 11:19, never restarted — tried six times between 11:24:47 and 11:25:38 to reach the extension, failed every time with `NSCocoaErrorDomain` 4099, and never relaunched it: a grey desktop, the Golden Gate as the preview. Help › Install Wallpaper registers it again and restarts WallpaperAgent, which brings it back.

**Not the installer's.** Randy's app did not launch until 11:23:22, and what it installs acts on its own session. **Not a leak either:** for a moment the log looked like `jazzman`'s extension reading Randy's port 21458; by user ID it was Randy's extension reading his own. Every agent and extension in the day's logs used its own account's port.

**Open, and it matters here:** switching accounts is how several users share a Mac, so every switch can leave the account switched away from grey. Syd, 2026-09-23: "I really want the wallpapers and screensavers to survive user switching without the app running if possible." Two ways were weighed and neither chosen: the app watching for its session becoming active again (only while it runs), or the agent doing it (it runs whenever the user is logged in, but restarting WallpaperAgent is installing, which the agent does not do). The screensaver after a switch is not checked yet. `TODO.md`, *The wallpaper goes grey after switching users*.

## Testing

- The gate answers `401` to a request with no secret, with a wrong one, and with a right one of a different length; and passes one with the right secret.
- A secret survives a relaunch; one is made when none is stored; a malformed one is replaced.
- The agent does not start when no secret can be made.
- A code is good once, and not after sixty seconds; it sets the cookie and redirects without itself; the cookie is accepted on the dashboard's `GET`s and refused on anything else; another secret's cookie is refused.
- `PictureClient` and `SourceService` send the header, retry once after a `401` when the secret changed, and report `notOurs` when it did not.
- The launch check asks the published port, sends the secret, and does not count a `401` as its agent.
- Each documented `curl` example gets through the gate as written.
- Phase 6 is Syd's, by hand: two accounts logged in, each seeing only their own pictures.

**Found on the way, 2026-09-23: a test that could hang the whole run.** `AgentLifecycleTests`, *SIGTERM withdraws the published port on the way out*, launches the built agent, signals it, and called `waitUntilExit()`. That spins the *current* thread's run loop, while `Process` delivers the exit to the run loop of the thread that launched it — and after the test's `await`, it is usually on a different pool thread. The first full run with `DocumentedExamplesTests` beside it sat at 0% CPU for seven minutes, the agent long gone and reaped. It passed every run before that, so it was a latent race, not a new fault; more work in parallel made the thread switch likelier. The test now awaits the exit from the process's `terminationHandler`; three full runs passed, about 40 seconds each. `DocumentationTests` also calls `waitUntilExit`, but synchronously, on one thread, and is safe.

# References

- `Plans/Service Port Plan.md` — the fixed port, and the Phase 2 this plan argues against.
- `Plans/Release App Installer.md` — the prerequisite, and the per-user port.
- `Plans/PLAN.md`, *An installer is probably unnecessary*, and its correction of 2026-09-10.
- `Plans/Wallpaper Plan.md` — the per-user install decisions, 2026-09-10 and 2026-09-14.
- The agent: `MacOS/Agent/Sources/HTTPListener.swift`, `Router.swift`, `RunCommand.swift`, `Options.swift`; `MacOS/Agent/Dashboard/Sources/DashboardEndpoint.swift`, `MacOS/Agent/Dashboard/Resources/dashboard.js`.
- Shared: `Shared/Sources/PhotosGoRoundAgentAPI/Host/Preferences.swift`, `BuildVariant.swift`, `HostEnvironment.swift`; `Shared/Sources/PhotosGoRoundDisplay/ServicePort.swift`, `PictureClient.swift`, `Shuffle.swift`.
- Clients: `MacOS/Wallpaper/Sources/AgentPicture.swift`, `MacOS/Screensaver/Sources/DisplayShuffles.swift`, `MacOS/Desktop/Sources/SourceService.swift`, `AboutView.swift`, `MacOS/Tools/pgr_ctl/Sources/InspectCommands.swift`, `MacOS/Shared/Sources/PhotosGoRoundInstall/AgentProbe.swift`, `LaunchInstall.swift`.
- Documentation: `README.md`, `Documentation/pgr_ctl.md`, `Documentation/Photos-Go-Round Server.md`.
