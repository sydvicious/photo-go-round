# Summary

Several people can use Photo-Go-Round on one Mac, each with their own agent and library. Each agent serves only its own user: it holds a secret of that user's, publishes it beside its port, and refuses any request that does not carry it.

# Rationale

The agent is per-user by design, installed in each user's `~/Library/LaunchAgents` with its own database. But it listens on loopback, and every account on the Mac shares loopback. Each user's agent now has its own port, but the port is worked out from the user name, so anyone logged in can compute another user's port and fetch their pictures from it. Where two names hash to the same port, the second user's app already mistakes the first user's agent for its own. Syd, 2026-09-21: "the danger is that the second user send a request to the first user's agent on the default port."

# Phases

- **Prerequisite — The app installs everything.** *Done 2026-09-22, in `Release App Installer.md`.* Syd, 2026-09-21: "We need to implement the app installing everything first, though." Then, 2026-09-22: "ok, the app should be ready for multiple users."
- **Phase 1 — Measure the boundary.** Nothing below is built until this holds.
  - Another account cannot read this user's preferences plist.
  - The sandboxed saver and wallpaper extension still can.
- **Phase 2 — The agent keeps a secret and checks it.**
  - Made on first launch, kept across launches, published as `serviceSecret` beside `servicePort`.
  - `401` to any request without it.
- **Phase 3 — Every client sends it.**
  - `PictureClient` (app, saver, wallpaper extension), the app's `SourceService`, `pgr_ctl`.
  - The app's launch check, `AgentProbe`, too: it asks the published port, and a `401` is not its agent.
- **Phase 4 — The dashboard.** A browser cannot add a header, so the app's link gets the browser a cookie.
- **Phase 5 — Documentation.** `Documentation/photogoroundd.md`'s `curl` examples gain the header, and each gets a test.
- **Phase 6 — Two users at once.** Syd logs in as a second user with the first still logged in; both agents serve, and each user sees only their own pictures.

# Design Decisions

*Claude's proposals except where marked.*

- **A per-user secret.** *Syd's, 2026-09-21: "yes, write it up as Phase 4 with the per-user secret".* It works over the TCP every client already speaks, and travels the way the port already does. A Unix socket and a peer-uid lookup were weighed; see *Why a secret*.
- **Kept, not remade each launch.** The app restarts the agent on every app launch; a new secret each time would send every running client back to re-read it.
- **Sent as `Authorization: Bearer`, published as `serviceSecret`.** *Claude's choices.* A header keeps it out of URLs.
- **A refusal is a bare `401`.** An agent that is not yours says nothing about whose it is.
- **Which port each agent binds stays as `Release App Installer.md` built it**: a base per build, plus a hash of the user name, with the kernel's port as the fallback. With the secret in place, a request that reaches the wrong agent is refused, not served.
- **The launch check asks the published port, not the hashed one.** The hashed port is predictable, so it is the one another account can hold; the secret must not be sent there.

# Background

- **Already per-user:** the agent's LaunchAgent plist, its database and container, and its preference domain. The binary stays in the one app bundle. Syd, 2026-09-10: "the agent MUST be installed in ~/Library/LaunchAgents; this needs to support multiple users on the same machine."
- **The agent checks nothing about who is asking.** Loopback keeps other machines out, not other accounts on this one.
- **Since 2026-09-21 the port is per user:** 20000, 23000 or 26000 by build, plus FNV-1a of the short name modulo 3000 (`BuildVariant.port`). Syd's Debug agent is on 23172.
- **The saver, the wallpaper extension and the app's windows read the published `servicePort`**, so they reach their own user's agent even after a collision.
- **The app's launch check does not.** `AgentProbe` polls the hashed port and counts any HTTP answer as its agent (`LaunchInstall.swift`).
- **The saver reads preferences as a file**, because its sandbox hands back an empty suite; see `ServicePort`.
- **The dashboard opens in the person's browser**; `AboutView` builds the link.

# Detailed discussions

## The danger

The agent binds loopback and serves anything that connects. Loopback is shared by every account on the Mac, so:

- **Deliberately, today:** the port is computed from the user name, which every account can see, so anyone logged in can work out another user's port, `curl http://localhost:<port>/…`, and get their pictures, their sources, and the dashboard. The per-user port made this a step harder than a fixed 9427, not impossible.
- **By accident, today, on a collision.** Two names with the same hash want the same port. The second user's agent falls back to a kernel port and publishes it, so their pictures are right — but their app's launch check polls the hashed port, finds the first user's agent, and reports its own agent as answering whether it started or not.
- **By accident, if `Service Port Plan.md`'s Phase 2 is ever built:** clients would try the hashed port first, and on a collision show the first user's pictures on the second user's desktop and screensaver. Nothing on either side would notice.
- **Not by accident otherwise:** the saver, the wallpaper extension and the app's windows read their own user's published port.

## Why the app installer came first

*Claude's reading of Syd's "We need to implement the app installing everything first."* Until 2026-09-21 the agent, the saver and the wallpaper extension were installed by ⌘R on an `Install …` scheme or by `Scripts/install-*.sh`, from a developer's Xcode, so a second user on the same Mac had no way to install their own copy. **Done 2026-09-22:** every launch of the app installs and restarts that user's agent, and a Release build also registers the wallpaper and links the screensaver. See `Release App Installer.md`. Phase 6 can now be run.

## Which port each agent binds

*Settled by `Release App Installer.md`, 2026-09-21.* Syd: "use three different base addresses based on build variants, and then add a hash of the user name to it to come up with the port. If there is a collision, let the agent pick one, and we fall back to the existing mechanim."

So two users no longer race for one number: each wants their own, from 20000, 23000 or 26000 by build plus FNV-1a of the short name modulo 3000. A collision is unlikely but possible, and the loser takes a kernel port and publishes it.

**This settles binding, not reading.** The port is predictable to anyone who knows the user name, and any request that reaches an agent is served. The options this section weighed before — first come first served, a small scan, the fixed port plus the published value — are all replaced by the hash, and none of them was ever the danger. The secret is what fixes that.

## How the secret works

1. **On first launch the agent makes a random secret** of 32 bytes from `SecRandomCopyBytes`, hex-encoded, and stores it in its own preferences. Later launches reuse it.
2. **It publishes it as `serviceSecret`**, in the same domain and the same way as `servicePort`, so every client that can find the port can already find the secret. It is not withdrawn on exit, unlike the port: it names the user, not the running process.
3. **Every request must carry `Authorization: Bearer <secret>`.** A missing or wrong one gets `401` and an empty body, and the agent logs one line naming the path and whether the secret was absent or wrong — never the value.
4. **The comparison is constant-time.** Cheap to do, and a local attacker timing responses on loopback is exactly the attacker this plan is about.

## Why a secret

- **A Unix domain socket in the user's own directory.** The kernel would enforce ownership outright, and `LOCAL_PEERCRED` gives the caller's uid. But every client moves off TCP, `curl` needs `--unix-socket`, the browser cannot reach the dashboard at all, and whether the sandboxed saver and wallpaper extension may connect to a socket at that path is unmeasured. Too much moves at once, for a guarantee the secret mostly gives.
- **Looking up the peer's uid over TCP.** Possible through `libproc` — walk processes to find the one holding the other end of the connection — but it costs a scan per connection, races against short-lived clients, and is also unmeasured.
- **The secret** changes nothing about transport, rides discovery that already works in all three sandboxes, and costs one header per request.

## Where it is readable, which has to be measured

The whole design rests on one fact that has not been checked: **another account cannot read this user's preferences plist.** `~/Library` is normally `drwx------`, and the plist itself `-rw-------`, but that is expectation, not measurement. The same measurement has to show the other half: the saver reads the plist as a *file* because its sandbox refuses the suite (`ServicePort`), so the saver must still be able to read the secret the same way, and so must the wallpaper extension. If either half fails, this plan changes before anything is built.

## The dashboard

A browser cannot be told to send a header. Two ways:

- **The secret in the link, once.** `AboutView`'s link becomes `/dashboard?key=<secret>`. The agent, seeing a correct `key`, sets an `HttpOnly`, `SameSite=Strict` cookie and redirects to `/dashboard` without it, so the secret does not stay in the address bar. It does pass through one URL, and so into the browser's history as the redirect's source.
- **A one-time code.** The app asks the agent for a short-lived code and puts that in the link instead; the agent trades it for the cookie. The secret never reaches the browser, at the price of one more endpoint.

*Not decided; Claude leans to the one-time code.*

Cookies do not separate by port, so a cookie set by one user's agent is sent to the other user's agent in the same browser. That is harmless — the other agent rejects it — but it has to be a rejection and not a confusion.

## Clients

- **`PictureClient`**, used by the app's display, the saver and the wallpaper extension, reads the secret beside the port and adds the header. The `unreadable` case `ServicePort` already distinguishes applies to the secret too.
- **The app's `SourceService`**, the same.
- **`pgr_ctl`** reads its own configuration's secret, as it reads the port. `--release` and `--debug` still work, because they read Syd's own preferences as Syd.
- **The app's launch check, `AgentProbe`.** Today it polls the hashed port for thirty seconds and counts any HTTP status, a `404` included, as its agent. With the secret it reads the published port — waiting for the restarted agent to publish it — sends the secret, and counts only an answer that is not `401`. Asking the published port is what keeps the secret away from whoever may hold the hashed one.
- **A `401` is its own state**, separate from *agent not running*: it means *this is somebody else's agent*. From a client's own published port it means the secret changed underneath the client, and the client re-reads it once before reporting.

## What it does not stop

- **A hostile user who takes your port first.** The hashed port is predictable, so another account can start a listener on it before you log in. Your agent falls back to a kernel port and publishes it, and your clients follow the published value — but anything of yours that sends the secret to the hashed port hands it to that listener, which can then use it on your real agent. That is why the launch check moves to the published port, and why **`Service Port Plan.md`'s Phase 2 — clients try the fixed port first — should not be built**: it would send every client's secret to the predictable port. *For Syd to decide.*
- **Anything running as the same user.** It can read the secret. That is the same boundary the library itself has.
- **Root.** Likewise.

## Documentation

`Documentation/photogoroundd.md`'s `curl` examples gain `-H "Authorization: Bearer $(defaults read <domain> serviceSecret)"`, with the domain per configuration. Each of those examples then needs a test, because documented means tested.

## Testing

- The agent answers `401` to a request with no secret, with a wrong one, and with a right one of a different length; and serves one with the right secret.
- A secret survives a relaunch; one is made when none is stored.
- The launch check asks the published port, sends the secret, and does not count a `401` as its agent.
- The dashboard link sets the cookie and redirects without the secret; the cookie is then accepted, and another agent's cookie is refused.
- Each `curl` example in `Documentation/photogoroundd.md` works as written.
- Phase 6 is Syd's, by hand: two accounts logged in, each seeing only their own pictures.

# References

- `Plans/Service Port Plan.md` — the fixed port, and the Phase 2 this plan argues against.
- `Plans/Release App Installer.md` — the prerequisite, and the per-user port.
- `Plans/PLAN.md`, *An installer is probably unnecessary*, and its correction of 2026-09-10.
- `Plans/Wallpaper Plan.md` — the per-user install decisions, 2026-09-10 and 2026-09-14.
- `MacOS/Agent/Sources/HTTPListener.swift`, `Shared/Sources/PhotoGoRoundDisplay/PictureClient.swift`, `Shared/Sources/PhotoGoRoundDisplay/ServicePort.swift`, `Shared/Sources/PhotoGoRoundAgentAPI/Host/Preferences.swift`, `MacOS/Desktop/Sources/SourceService.swift`, `MacOS/Desktop/Sources/AboutView.swift`, `MacOS/Tools/pgr_ctl/Sources/InspectCommands.swift`, `MacOS/Shared/Sources/PhotoGoRoundInstall/AgentProbe.swift`, `MacOS/Shared/Sources/PhotoGoRoundInstall/LaunchInstall.swift`, `Shared/Sources/PhotoGoRoundAgentAPI/Host/BuildVariant.swift`.
