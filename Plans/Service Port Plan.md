# Summary

The agent serves pictures on a fixed port that every client already knows, instead of taking whatever the kernel hands it at launch and publishing the number for clients to discover.

# Rationale

The dynamic port is the one piece of the system that changes on every launch, and everything that reaches the agent has to chase it. A client that was talking to the old port shows *waiting for the agent* until it re-reads the published value, which is exactly what the app did after each of today's five reboots. It also forced a workaround: the screensaver runs in a sandbox where reading the published value silently answers "no agent", so `ServicePort` opens the preferences plist as a file instead. A number everybody knows removes the discovery step, its failure modes and the workaround at once. Syd, 2026-09-17: "Perhaps we had better actually pick a port and hardcode it. this dynamic port stuff is causing problems."

# Phases

- **Phase 1 — The agent binds a fixed default.** `--port` still pins another number, and the bound port is still published.
  - Choose the number; check it against `/etc/services` and what the machine actually listens on.
  - Bind failure is fatal and says what holds the port.
- **Phase 2 — Clients try the fixed port first.** The published value becomes the fallback, for an agent that was told to use a different one.
  - The app, the screensaver, the wallpaper extension and `pgr_ctl`.
- **Phase 3 — Retire what the discovery dance needed.** Whatever is left unused after Phase 2 goes: the plist-file read in `ServicePort`, and possibly `servicePort` itself.
- **Phase 4 — Several users on one Mac.** Decide what a second user's agent binds, since two agents cannot hold the same port.

# Design Decisions

*All of these are Claude's proposals; none is decided.*

- **A number outside the ephemeral range**, which on this Mac is 49152–65535 (`net.inet.ip.portrange`). Inside it, a transient client socket can be holding our port when the agent starts. **Proposed: 9427**, unlisted in `/etc/services` and not in use on Syd's Mac.
- **Loopback only, as now.** Nothing off the machine reaches it, so the number is a local convention rather than an allocation anyone else must respect.
- **`--port` stays**, for a scratch agent beside the real one, and for a second user.
- **Publishing stays**, so a pinned or scratch agent can still be found, and so `pgr_ctl status` keeps working unchanged.
- **A bind failure is fatal**, loudly: the agent names the port and what holds it rather than quietly taking another, since the whole value of a fixed port is that it is the one clients try.
- **Clients try the fixed port first and the published value second**, so an agent told to use another port still answers.

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

## Choosing the number

The constraint that matters is macOS's ephemeral range, 49152–65535 on this Mac: anything inside it can be taken by an outgoing connection before the agent starts, and a fixed port that is sometimes stolen is worse than a dynamic one. Below 1024 needs privilege. That leaves 1024–49151, where the risk is colliding with software Syd runs rather than with the kernel.

**9427 is the proposal**: not in `/etc/services`, not listening on his Mac today. Anything in that range with the same two properties would do — the number itself carries no meaning, and the plan should not pretend otherwise.

## Several users on one Mac

This is the one place the fixed port is genuinely worse, and it is worth deciding rather than discovering. The agent is per-user by design — Syd, 2026-09-10: "the agent MUST be installed in ~/Library/LaunchAgents; this needs to support multiple users on the same machine" — and two logged-in users each run their own. They cannot both bind 9427 on loopback.

Options, none decided:

- **First come, first served, and the second agent fails loudly.** Simplest, and wrong for a Mac where two people are logged in at once.
- **A small scan: try the fixed port, then the next few.** Keeps the common case fixed and makes the second user's agent work, at the cost of clients having to try more than one number — which is most of the discovery dance coming back, but bounded and with no preference involved.
- **The fixed port plus the published value**, which is the Phase 2 shape: the second user's agent binds something else and publishes it, and that user's clients find it the way they do now. The first user never pays the cost.

The third is what the phases above assume, since it keeps discovery as the exception rather than the rule.

## What can be deleted afterwards

Only after clients default to the fixed port:

- `ServicePort`'s plist-file fallback, if the saver no longer needs a published value.
- `servicePort` itself, if nothing reads it — but not before Phase 4 is settled, since the multi-user answer above depends on it.
- The `--no-publish` option keeps its meaning either way: a scratch agent still must not overwrite what clients read.

## Testing

- The agent binds the fixed port with nothing else holding it, and fails with a legible message when something does.
- A client with no published value reaches the agent anyway.
- A client reaches an agent started with `--port` at another number, through the published value.
- `pgr_ctl status` prints the right port in both cases.

# References

- `Plans/PLAN.md`, *Preferences as a client transport, tried and reversed*, and the preference table in `Documentation/photogoroundd.md`.
- `Plans/Screensaver Plan.md`, *The question the entitlements do not answer: finding the port* — why the plist read exists.
- `Sources/PhotoGoRoundDisplay/ServicePort.swift`, `Sources/PhotoGoRoundAgentAPI/Host/Preferences.swift`.
- `TODO.md`, *A fixed service port*.
