# Summary

Photos-Go-Round Widgets.app: a self-contained App Store app for macOS, iOS, iPadOS and visionOS, with
watchOS widgets served by the iPhone app. It shows your photographs in widgets of every size the
platform offers, and it must pass App Store review. Syd, 2026-09-26.

# Rationale

The App Store can take the widgets but not the screensaver or the wallpaper, so the widgets are the
Store product (`Plans/Product Strategy.md`). A Store app is sandboxed and can't count on our agent
running beside it, so it carries its own agent inside rather than asking one over HTTP. That makes one
design that works the same on the Mac and on devices that never had an agent.

# Phases

- *macOS* — Photos-Go-Round Widgets.app on the Mac App Store.
  - Spike: can a widget change its photograph every 10 seconds?
- *iOS and iPadOS* — the same app on the iOS App Store.
  - Investigate how widgets work on iPhone Duo.
  - Spike: can CarPlay show iPhone widgets, and in which sizes?
- *visionOS* — the same app on the visionOS App Store.
- *watchOS* — watch widgets, with the iPhone app as their agent.

# Design Decisions

- **Above everything else: it must be submittable to the App Stores.** Any decision below that would
  fail review gives way. No fights with App Review: if they object to a feature, we change it or drop
  it rather than argue.
- **Version 27.0 or later on every platform.** macOS, iOS, iPadOS, visionOS and watchOS 27, the
  same floor as the rest of the project.
- **Same source tree and Xcode project as the rest of Photos-Go-Round.** Not a separate repository
  or project.
- **`PLAN.md` only points here.** When this work changes code in the rest of the system, `PLAN.md` is
  updated then, not before.
- **The app contains the agent; there is no HTTP.** The widgets get their photographs from the app
  itself, not from a separate agent process.
- **On the Mac, it shares the photo sources with the rest of the system.** The albums and folders you
  pick are the same ones the rest of Photos-Go-Round on that Mac uses.
- **It has its own cache and queue.** It doesn't share them with the agent.
- **The cache is much smaller: about 128 MB.** Widgets show small pictures, so a large cache would
  be wasted.
- **Widgets in every size the platform offers.** No families left out.
- **Each widget has its own refresh preference.** One can change every 10 seconds, another every 30,
  and so on; it's set per widget, not app-wide. The watch may not offer the fastest intervals,
  for battery. Nor may CarPlay, because fast-changing pictures distract the driver.
- **The watch uses the iPhone app as its agent.** The watch has no agent of its own; it gets its
  photographs from the iPhone app.
- **The Pro app's widgets: to be decided.** Whether they share this design or ask Pro's agent is
  open.
- **CarPlay widgets on iPhone, if the platform has them.** If CarPlay can show iPhone widgets, ours
  are among them. If App Review objects, CarPlay is dropped rather than argued for.

# Background

- `Plans/Product Strategy.md` (2026-09-22) names this product: *Photos-Go-Round Widgets* on macOS, and
  on iOS, iPadOS, visionOS and watchOS.
- The 2026-09-19 version of this document had the widget ask the agent over HTTP. That design is
  replaced; git has it.
- Nothing is built. `ConsumerKind.widget` and `Log.widget` exist and are unused.

# Detailed discussions

Syd asked for top-level notes only on 2026-09-26. These two spikes are here because he asked for
them; nothing else is argued yet.

## Spike: a 10-second refresh

**The question.** Design Decisions says a widget can change its photograph every 10 seconds. Can
WidgetKit do that, and what does it cost?

**Why it's in doubt.** WidgetKit decides when a widget redraws. A widget asks for a *reload* — the
system waking the extension to build a new timeline — and those are rationed, by recollection to a
few dozen a day. A 10-second refresh can't be done with reloads. It could only be done with a single
timeline that holds many entries, each dated 10 seconds after the last, which the system shows in
turn without waking the extension.

**What could stop that, all unverified:**

- **Memory.** An extension runs under a small memory ceiling (about 30 MB, from `PLAN.md`'s
  recollection). An hour at 10 seconds is 360 entries. If each entry's picture has to be in memory
  when the timeline is handed over, that won't fit. If entries can refer to files on disk, it might.
- **The system may not honour the dates.** A timeline's dates are a request. Whether the system
  redraws every 10 seconds, or coalesces, is what the spike has to observe.
- **A covered widget.** On the Mac, a desktop widget behind windows may not be redrawn at all. That
  is fine. When it's uncovered it fetches one photograph and shows it; the entries it missed are
  skipped, not replayed.
- **Battery**, on iPhone, iPad and watch. A redraw every 10 seconds may be something the system
  throttles, or something App Review questions.

**What the spike does.** A widget on the Mac with a timeline of entries 10 seconds apart, each a
different solid colour, then each a different photograph from the app's cache. Watch it for an hour,
count redraws against entries, and read the extension's memory from the unified log. Then the same on
an iPhone.

**What the answer changes.** If 10 seconds works, Design Decisions stands. If it doesn't, the shortest
interval that does becomes the floor for the per-widget setting.

## Spike: CarPlay widgets

**The question.** Can CarPlay show iPhone widgets, and if so which sizes, and what does it do to a
photograph?

**What I think is true, unverified.** iOS 26 added widgets to CarPlay, showing the iPhone's own
widgets in the small size. That is from memory and needs checking against Apple's documentation for
27.

**What the spike does.** Read the WidgetKit documentation for CarPlay, then put the widget on a
CarPlay screen — the CarPlay simulator in Xcode, or a car. Check which sizes appear, whether the
picture is shown in colour, and whether the refresh setting is honoured while driving.

**What the answer changes.** If CarPlay shows widgets, our small widget is the CarPlay widget and
nothing extra is built. If it has rules of its own (for example, no changing pictures while the car
moves), those become design decisions here.

# References

- `Plans/Product Strategy.md` — the four products, and this one's place among them.
- `Plans/PLAN.md`, Phase 8 (Mac widget) and Phase 5 (iOS widget).
- `Plans/PLAN.md`, *Widgets on macOS, and where the store actually lives* — the App Group analysis.
- `Plans/Logging.md` — the logging rules every binary follows.
