# Summary

The agent serves pictures on a fixed port that every client already knows, instead of taking whatever the kernel hands it at launch and publishing the number for clients to discover.

# Rationale

The dynamic port is the one piece of the system that changes on every launch, and everything that reaches the agent has to chase it. A client that was talking to the old port shows *waiting for the agent* until it re-reads the published value, which is exactly what the app did after each of today's five reboots. It also forced a workaround: the screensaver runs in a sandbox where reading the published value silently answers "no agent", so `ServicePort` opens the preferences plist as a file instead. A number everybody knows removes the discovery step, its failure modes and the workaround at once. Syd, 2026-09-17: "Perhaps we had better actually pick a port and hardcode it. this dynamic port stuff is causing problems."

# Phases

- **Phase 1 — The agent binds a fixed default.** `--port` still pins another number, and the bound port is still published. **Built and installed 2026-09-17**; see *Built: the agent takes its number*.
  - **Three numbers, one per build variant** — release 9427, Syd's Debug 9428, an agent's build 9429. Syd: "I think each of the three build variants need their own fixed ports."
  - **The variant is a compile-time condition**, not the deployment. Syd: "build-time identity."
  - **A refused port is fallen back from, not failed on**: the agent takes one from the kernel and publishes it, as it always did. Syd: "If the agent can't get the port it wants, it should fall back to what it does now."
**Status, 2026-09-19.** Phase 1 is built, installed, and did the job it was asked to do: the published value is now correct as soon as the agent starts, so the *waiting for the agent* window Syd complained about is gone without Phases 2 and 3. **This plan stayed open for Phase 4 alone** — Syd: "leave it open for the multi-user phase." *Phase 4 moved to `Multi-user Support.md` on 2026-09-21.* Phases 2 and 3 are not cancelled, only unscheduled: they remove a discovery mechanism that is no longer load-bearing, which is tidying rather than fixing. `TODO.md`'s pointer to this plan was removed the same day.

- **Phase 2 — Clients try the fixed port first.** *Unscheduled 2026-09-19; see the status note above.* The published value becomes the fallback. Syd: "The clients will try the hardcoded port first, and then fall back to what they do now."
  - The app, the screensaver, the wallpaper extension and `pgr_ctl`.
  - Each has its own handling of *no port published* against *unreadable*, so what a failed first attempt means to the surface is the part to get right.
  - **Never with the secret.** *Syd's, 2026-09-23, in `Multi-user Support.md`.* Since that plan every request carries the user's secret, and the hashed port is the one another account can hold on purpose. A first try there goes without it, and so can only learn that something answers — every agent says `401` to a request without the secret — never that it is this user's. The request that matters still goes to the published port.
- **Phase 3 — Retire what the discovery dance needed.** *Unscheduled 2026-09-19, and dependent on Phase 2.* Whatever is left unused after Phase 2 goes: the plist-file read in `ServicePort`, and possibly `servicePort` itself.
  - **Neither can go now.** *2026-09-23.* The secret from `Multi-user Support.md` is published beside `servicePort` and read the same two ways, the saver through the plist file; and the published port is the only one a client may send the secret to. This phase has nothing left to retire unless that plan changes.
- **Phase 4 — Several users on one Mac.** *Moved to `Multi-user Support.md`, 2026-09-21.* Syd: "I want multi-user support split out into it's own plan".

# Design Decisions

*All of these are Claude's proposals; none is decided.*

- **Numbers outside the ephemeral range**, which on this Mac is 49152–65535 (`net.inet.ip.portrange`). Inside it, a transient client socket can be holding our port when the agent starts. **9427, 9428 and 9429**, none listed in `/etc/services` and none in use on Syd's Mac. The numbers carry no other meaning.
- **One per build variant, decided at compile time.** `Deployment` answered *whose pictures* — production against `.build` — and that was a different question from *whose build*. *Since 2026-09-24 there is no second question:* each build has exactly one library (`Storage`), so the build decides both, and three port ranges remain the right number. Two agents built differently can be running at once on this Mac, which is the collision the three numbers exist to avoid, and it is the same three identities the wallpaper extension already has.
- **Loopback only, as now.** Nothing off the machine reaches it, so the number is a local convention rather than an allocation anyone else must respect.
- **`--port` stays**, for a scratch agent beside the real one, and for a second user.
- **Publishing stays**, so a pinned or scratch agent can still be found, and so `pgr_ctl status` keeps working unchanged.
- **A bind failure is not fatal.** *Proposed as fatal, and reversed by Syd on 2026-09-17: "If the agent can't get the port it wants, it should fall back to what it does now."* The agent names the port and prints what to run to find the holder, then takes one from the kernel and publishes it. The discovery path is still there; it has stopped being the ordinary one. A fixed port the agent could not have is a reason to be findable, not a reason not to start.
- **Clients try the fixed port first and the published value second**, so an agent told to use another port still answers. *Open again, 2026-09-21: see `Multi-user Support.md`,* What it does not stop.

# Background

- Today the agent asks the kernel for a port, publishes it to `servicePort` in the shared preference domain, and withdraws it on exit. `pgr_ctl status` prints it; the app, saver and wallpaper read it.
- `ServicePort` in `PhotoGoRoundDisplay` exists because of a measurement on 2026-09-07: inside `legacyScreenSaver`'s sandbox, `UserDefaults(suiteName:)` returns an empty suite rather than failing, so a missing value is indistinguishable from *no agent running*. It falls back to reading the plist as a file.
- Measured 2026-09-17, across five reboots: each agent launch took a different port (56333, 58192, …), and the app reported waiting until it re-read the published value.
- `--no-publish` already exists for scratch agents, which serve without announcing themselves.

# Detailed discussions

## What the fixed port removes

Three things, in order of how much trouble they have caused:

1. **The window after a relaunch.** Every client holds the port it last read. The agent restarts — an install, a crash, a reboot — and takes a new number, so the next request goes to a port nothing is listening on. The client reports the agent missing until its next read of the preference. Today's reboots each showed this, and it is indistinguishable, from the person's side, from the agent being down.
2. **The sandbox workaround.** `ServicePort`'s plist read exists only because the published value cannot be read the ordinary way from the screensaver. A fixed default means the saver needs no value at all in the common case.
3. **Typing a URL.** `curl` against the agent needs a lookup first, which is why `Documentation/photogoroundd.md`'s examples pin `--port`.

## Built: the agent takes its number

*2026-09-17, installed the same night. `http listener ready on port 9428`, `lsof` agreeing, and the app finding the dashboard by itself.*

- **`ServiceAddress`** holds the three numbers behind `#if PGR_AGENT_CLAUDE` / `#elseif DEBUG`, and a `variant` string so the startup line says which build took which port rather than leaving a number nobody can account for.
- **The Xcode project takes `PGR_AGENT_CONDITION`**, appended to `SWIFT_ACTIVE_COMPILATION_CONDITIONS`, which is the same shape `WALLPAPER_ID_SUFFIX` already had. **Since 2026-09-19 it is set by the `Claude` build configuration rather than passed on the command line**, and `-configuration Claude` is the whole of it; `swift build` is no longer a build route, because it has only `debug` and `release` and so cannot produce this identity. Both are recorded in `CLAUDE.md`, because a build that forgets takes 9428, which is Syd's.
- **The listener binds once and falls back once.** On `.failed` with a fixed port it alerts with the number and `lsof -nP -iTCP:<port>`, then rebinds with no port. A second failure is reported and nothing is served, which is the only case left where the agent has no socket.
- **`--port` is unchanged**, and is what a scratch agent still uses.
- **Tests:** a pinned port is still honoured, and a port another listener holds is fallen back from rather than failed on. The first of those had to change: it treated "bound something other than the candidate" as a failure, which is now the ordinary fallback.
- **What Phase 1 does not do**: clients still read the published value, so the window after a restart is still there. That is Phase 2, and it is the half that removes it.

## Choosing the number

The constraint that matters is macOS's ephemeral range, 49152–65535 on this Mac: anything inside it can be taken by an outgoing connection before the agent starts, and a fixed port that is sometimes stolen is worse than a dynamic one. Below 1024 needs privilege. That leaves 1024–49151, where the risk is colliding with software Syd runs rather than with the kernel.

**9427, 9428 and 9429**: none in `/etc/services`, none listening on his Mac. Anything in that range with the same two properties would do — the numbers carry no meaning, and the plan should not pretend otherwise. Three of them because three builds of the agent exist and two can run at once; see *Design Decisions*.

## Several users on one Mac

*Moved to `Multi-user Support.md`, 2026-09-21, with the per-user secret.*

## What can be deleted afterwards

Only after clients default to the fixed port:

- `ServicePort`'s plist-file fallback, if the saver no longer needs a published value.
- `servicePort` itself, if nothing reads it — but not before `Multi-user Support.md` is settled, since clients read the secret the same way.
- The `--no-publish` option keeps its meaning either way: a scratch agent still must not overwrite what clients read.

## Testing

- The agent binds the fixed port with nothing else holding it, and fails with a legible message when something does.
- A client with no published value reaches the agent anyway.
- A client reaches an agent started with `--port` at another number, through the published value.
- `pgr_ctl status` prints the right port in both cases.

# References

- `Plans/PLAN.md`, *Preferences as a client transport, tried and reversed*, and the preference table in `Documentation/photogoroundd.md`.
- `Plans/Screensaver Plan.md`, *The question the entitlements do not answer: finding the port* — why the plist read exists.
- `Shared/Sources/PhotoGoRoundDisplay/ServicePort.swift`, `Shared/Sources/PhotoGoRoundAgentAPI/Host/Preferences.swift`.
- `Plans/Multi-user Support.md` — what was Phase 4.
- `TODO.md`, *A fixed service port*.
