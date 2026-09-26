# Summary

How Photos-Go-Round is distributed and sold. Syd, 2026-09-22: "Ok, I have clarity on how I want to distribute/sell this." There are four products, and three of them are for the Mac.

# Rationale

The App Store takes only what passes review, and the full Mac integration cannot pass: the wallpaper extension uses private frameworks and temporary exceptions. So the product that can pass goes in the Store, and the product that cannot is sold from Syd's own site.

# Phases

- *Photos-Go-Round Widgets, macOS* — a menubar app on the App Store that provides widgets for macOS. If the screensaver can pass review, it installs the screensaver too.
- *Photos-Go-Round Pro* — a menubar app with the wallpaper, the screensaver and the widgets, sold from an online store at `photosgoround.sydpolk.com`.
  - The online store, and the Widgets app's support and privacy pages at `pgrwidgets.sydpolk.com`, are planned in `../../sydpolk-com/sydpolk.com.md`.
- *Photos-Go-Round* — a desktop app with everything the menubar app has.
  - Undecided: whether it is offered for sale, and whether it is combined with the menubar app.
- *Photos-Go-Round Widgets, iOS, iPadOS, visionOS and watchOS.*

# Design Decisions

- **Every product is named "Photos-Go-Round".** Identifier strings say `photosgoround`. See `TODO.md`, *Rename the product to "Photos-Go-Round"*.
- **The Mac products are menubar apps; the desktop app is the exception.** The design of the menubar apps is still to come.

# Background

- `PLAN.md`, *Two Mac products, sandboxed and Pro* (2026-09-15), has a sandboxed App Store version and a Pro version sold from Syd's own site. This plan refines it: the App Store product is now the widgets app, and a desktop app is a third Mac product.
- `TODO.md`, *A menu-bar app for shipping*, and *Sandboxing, and whether the App Store is reachable*.

# Detailed discussions

None yet.

# References

- `PLAN.md`, *Two Mac products, sandboxed and Pro*; *The sandbox contingency*; *Shipping it: 1.0 distribution and updates*.
- `Plans/Photos-Go-Round Widgets.md`.
- `Plans/Wallpaper Plan.md`, *The real extension, inside the app*.
