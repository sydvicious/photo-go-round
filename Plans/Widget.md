# Summary

**An idea, not a commitment. Syd, 2026-09-19.** Nothing here is built, WidgetKit is imported nowhere
in the repository, and every phase, family and decision below is a proposal rather than something
agreed.

A WidgetKit extension that puts a photograph in Notification Center and on the desktop, asking the
agent for it over HTTP like every other surface. `PLAN.md` Phase 8.

# Rationale

The wallpaper and the screensaver both show photographs only when nobody is looking at the Mac — the
desktop is behind windows, the saver runs when the machine is idle. A widget is the first surface
that shows one while the person is actually working, which is the case none of the others covers.
Syd, 2026-09-15: *"I want to support image widgets on the Mac as well."* It is also the cheapest
surface left: `ConsumerKind.widget` and the `widget` log category already exist, the agent already
serves resized pictures over HTTP, and the sandbox problem that would have been expensive was solved
for the screensaver a phase ago.

# Phases

- **Phase 1 — A spike that proves the sandbox reaches the agent.** A widget that draws a solid
  colour, then one that draws a picture fetched from `localhost`. Nothing else.
  - An extension is sandboxed on macOS with no opt-out, so `com.apple.security.network.client` and a
    loopback request are the whole question.
  - It must find the port the way the saver does — reading the preferences plist as a file — because
    a sandboxed process asking `UserDefaults` for our domain gets nothing.
  - Build under a Claude identity from the start, the way the wallpaper extension does.
- **Phase 2 — One family, one photograph, honest refresh.** `systemMedium` only, a timeline that
  asks for a picture and says when to ask again.
  - The widget asks for its own point size; the agent resizes on the serving path already.
  - Registers as `widget.medium` — identity is `(kind, displayID)` and a widget has no display, so
    the family is what discriminates it.
- **Phase 3 — The families that matter, and the empty state.** `systemSmall` and `systemLarge`, each
  its own consumer, and a widget that never shows a blank tile.
- **Phase 4 — Logging discipline, the same as the other three binaries.** See *Logging*, below, and
  `Plans/Logging.md`.
- **Phase 5 — Install and measure.** Its own install script and `Documentation/` entry, then a day of
  its lines in the unified log and its refresh count against the budget WidgetKit actually gave it.

# Design Decisions

- **The widget is an HTTP client, like every surface.** Settled in `PLAN.md`, *The service is the
  interface*. No App Group, no shared container, no second copy of the deck — the App Group analysis
  in `PLAN.md` is superseded and kept only for the day something needs it.
- **It finds the port by reading the preferences plist as a file.** The same workaround the
  screensaver needs and for the same reason: a sandboxed process gets nothing back from
  `UserDefaults` for our domain. `ServicePort` already does this.
- **One consumer per family.** `widget.small`, `widget.medium`, `widget.large` — identity is
  `(kind, displayID)` and a widget has no display, so without this every family shares one hand.
- **It asks for its rendered size, never a full-resolution original.** WidgetKit kills an extension
  that hands back an oversized image, and the agent resizes on the serving path already.
- **Every build carries its own identity**, the way the wallpaper extension does: release, Syd's
  Debug, and an agent's `.claude` build, so a build of mine never replaces one of his in the widget
  gallery. `CLAUDE.md`, *Wallpaper builds carry their own identity*.
- **A widget never shows a blank tile.** *Always have something to show* applies here as everywhere;
  the last photograph it held outranks a correct-but-empty one.
- **Logging goes to the unified log and nowhere else**, under `Log.widget`, at a level chosen by how
  often the line happens. See *Logging*.

# Background

- **Nothing is built.** WidgetKit is imported nowhere in the repository. `ConsumerKind.widget` and
  `Log.widget` both exist and are both unused.
- **macOS 27 throughout**, so WidgetKit's current surfaces are simply present — no availability
  ladders. `PLAN.md`, *Targeting 27*.
- **The hard parts are already solved next door.** The screensaver proved the sandboxed-process-
  reaching-the-agent shape; the wallpaper extension proved per-build identity, `pluginkit`
  registration and the install script pattern. `Plans/Screensaver Plan.md` and
  `Plans/Wallpaper Plan.md`.
- **`PLAN.md` Phase 5 — the iOS widget — is deferred past 1.0** and is a different design: it shares
  an App Group with the app and reads the store directly, because iOS has no agent to ask.

# Detailed discussions

## Logging

**The same discipline as the other three binaries**, at Syd's direction on 2026-09-19: *"this same
logging discipline should apply to all three separately running binaries."* The widget is the fourth,
and it should arrive already holding the line rather than being cleaned up later.

**No standard output, anywhere, ever — and here it is not even a choice.** The widget runs inside a
host we do not launch, the way the screensaver runs inside `legacyScreenSaver` and the wallpaper
extension inside whatever `WallpaperAgent` starts. Its `print` goes wherever that host sends it,
which is nowhere useful, and its sandbox would refuse a hand-rolled file logger regardless. So it
calls `print` never and `Log.widget` always. `Plans/Logging.md`, *The unified log is the only log*.

**It spells `Log.subsystem`, never the literal string.** The subsystem switches to
`com.sydpolk.photogoround.tests` under a test host, so a target that spells the string out writes its
test runs into the real agent's log. The widget links the package, so it has no excuse — unlike the
saver spike and the wallpaper host, which deliberately link nothing and spell it out for that reason.

**Level by how often the line happens.** `.notice` persists to disk and is the budget; `.info` does
not unless asked. So:

- **Stays `.notice` in every build**: the extension starting, the port it found, a refresh it could
  not complete, a picture it could not fetch, an empty state it fell back to, and `MEMORY:` on
  whatever cadence a widget can manage.
- **Drops a rung outside Debug and Claude builds**: the per-entry lines — the timeline it produced,
  each entry's photograph and size, the next refresh date it asked for.

The rung comes from the same `PGR_AGENT_CLAUDE` / `DEBUG` compile-time conditions that already pick
the service port, read once in `Log` rather than tested at each call site. **It exists already**:
`Log.chatter`, built 2026-09-19 for `Plans/Logging.md` Phase 2, so the widget takes it rather than
inventing one.

**One line per rendered photograph is the target, and it is achievable.** Measured 2026-09-19: the
screensaver writes exactly one line per picture (`showing card N deal M at 0x0`) with everything else
once per session, and that is the shape to copy. The wallpaper extension writes about seven per
change, six of which each say something different and one — `port … from the … suite` — which
re-announced an unchanged fact on every wake. Say a fact when it changes, not when it is read.
**That one was fixed on 2026-09-19** with `wallpaperLogWhenChanged`, which the widget should copy
rather than reinvent.

**The wrinkle that is the widget's own, and it cuts the other way from everything above.** A widget
refreshes a few dozen times a day, not a few thousand, so its lines are *sparse* — and `logd`'s
window was measured at about nine hours on 2026-09-19. A widget that logged only at `.info` outside
Debug could leave nothing at all to read about yesterday, because there was never enough volume to
matter in the first place. **So the per-entry demotion is worth less here than it is in the agent,
and the startup and failure lines are worth more.** If the count comes in under a few hundred lines a
day when Phase 5 measures it, leave the whole thing at `.notice` and say so in this section.

**Nothing here writes a file, so nothing here rotates.** `logd` holds a fixed budget and ages the
oldest out. Syd, 2026-09-19: *"I would rather let the system do log rotation for us and not develop
and maintain our own."*

## Why the spike is a phase of its own

The one thing that could make this whole plan wrong is a sandboxed widget extension failing to reach
`localhost`. Everything else — families, timelines, sizes, the empty state — is ordinary WidgetKit
work that can be estimated. That one question cannot, and it gates the rest entirely.

It is very likely fine: `com.apple.security.network.client` is the ordinary entitlement for an
extension that talks to the network, loopback is not treated specially by the sandbox, and the
screensaver already reaches the agent from inside a sandbox it does not control. But *likely fine*
is what the App Group spelling was, and `PLAN.md` records that one as "a classic afternoon lost to a
`nil` container URL". Ten minutes of proving beats an afternoon of assuming.

The port is the second half of the same spike, and it is the part with a known trap rather than a
suspected one: the saver cannot read our preference domain through `UserDefaults` from inside its
sandbox and reads the plist as a file instead. A widget will hit that on its first run, and it will
look exactly like *the agent is not running*.

## The refresh budget, and what it means for a photo widget

WidgetKit gives an extension a few dozen timeline refreshes a day and decides for itself when to
honour them. That is the constraint that makes a widget different in kind from the other three
surfaces: the screensaver changes every thirty seconds and the wallpaper every hour because *we*
decide, and a widget changes when the system feels like it.

Two consequences worth settling before Phase 2 rather than discovering in Phase 5:

- **A timeline is several entries, not one.** Asking the agent once per displayed photograph would
  spend the budget in an hour. The widget should ask for a handful of pictures, produce entries with
  dates spread across the next few hours, and hand WidgetKit the lot — which is what `PLAN.md`'s
  iOS design already calls *reserving a hand covering the entries about to be generated*.
- **Those entries are dealt in advance, so the deleted-photo guarantee is relaxed.** `PLAN.md` notes
  this for the iOS widget and the Watch: a surface that renders ahead cannot retract. It applies to
  the Mac widget identically, and `PLAN.md` currently gates only Phases 5 and 9 on deletions
  *arriving* rather than being found by rescan. **Whether Phase 8 should be gated the same way is
  open, and is Syd's call** — the honest middle is that the widget's entries are short-dated and a
  photograph deleted in the last few hours may show once more.

## What is not decided

- **Which families to ship.** The plan says medium first, then small and large, on the assumption
  that a photograph wants width. Not argued.
- **Whether the widget is configurable.** Per-source or per-album selection through
  `AppIntentConfiguration` is possible and is not proposed here; the widget deals from the same deck
  as everything else, which is the design everywhere else in this system.
- **What the empty state actually says.** `PLAN.md` says "a static label". The screensaver bounces
  *No Photos Available*; the wallpaper leaves the desktop alone. A widget holding its last photograph
  may be better than either, and that is a decision, not a detail.
- **Where its install script lives and what it does.** The wallpaper extension's pattern applies, but
  a widget registers differently and this has not been looked at.

# References

- `Plans/PLAN.md`, Phase 8 — the one-line statement of the Mac widget.
- `Plans/PLAN.md`, *Widgets on macOS, and where the store actually lives* — the App Group analysis
  and the note that *The service is the interface* supersedes it.
- `Plans/PLAN.md`, *The iOS family* — the timeline-provider design this borrows from, and does not
  share a container with.
- `Plans/Logging.md` — the discipline the *Logging* section above applies.
- `Plans/Wallpaper Plan.md` — per-build identity, `pluginkit`, and the install-script pattern.
- `Plans/Screensaver Plan.md` — a sandboxed surface reaching the agent, and reading the port as a
  file.
- `Shared/Sources/PhotoGoRoundAgentAPI/Model/Consumer.swift` — `ConsumerKind.widget`, and why a family is a
  consumer.
- `Shared/Sources/PhotoGoRoundAgentAPI/Support/Log.swift` — `Log.widget`, defined and unused.
- `CLAUDE.md`, *Wallpaper builds carry their own identity* — what a Claude build of an extension must
  do differently.
