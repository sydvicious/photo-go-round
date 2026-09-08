# TODO

Things to look into, deferred out of the phase list. Each one earns its own plan document if and when it is picked up; nothing here is designed yet.

## An Options button for the screensaver

Some savers show one in System Settings. `ScreenSaverView` provides it through `hasConfigureSheet` and `configureSheet`, both of which `PGRScreenSaverView` currently answers `false` and `nil`.

- **The blocker to establish first is where a setting would be written.** The Phase 1 spike found the saver cannot even *read* the agent's preference domain from inside `legacyScreenSaver`'s sandbox — `UserDefaults(suiteName:)` returns a suite that opens cleanly and is empty. It certainly cannot write one.
- **The available route is the agent.** Every other client changes things over HTTP; a settings endpoint does not exist yet. See `PLAN.md`, *The database is private to the service*.
- **Whether the sheet is presented at all is untested.** `hasConfigureSheet` is queried — it appears in the call sequence on `FB9835060` — so the button probably shows. Whether the sheet displays is unknown, and the preview instance being 0x0 is a reason to check rather than assume.
- **What would go in it** is also open: dwell, fit, an upscale cap. All are `PLAN.md`'s *Beyond 0.1* today, and *Everything user-settable is a user default* is held back with them.

## The icon in System Settings

The saver shows a generic icon in the list.

- The convention is `thumbnail.png` and `thumbnail@2x.png` in `Contents/Resources`, with `COMBINE_HIDPI_IMAGES` disabled so the two are not merged. No `Info.plist` key is involved.
- **Unverified on macOS 27** — the reference is older than Sonoma's System Settings rewrite.
- Blocked on there being an app icon at all, which does not exist yet.
- Distinct from the large preview in the pane, which is a snapshot the system captures from a real run — measured 2026-09-08, and not something we supply.

## Sandboxing, and whether the App Store is reachable

`PLAN.md`'s *Platform and distribution* says Developer ID direct, on the grounds that "a sandboxed app cannot install a `.saver` bundle, so App Store distribution and a screensaver are mutually exclusive." That is the decision to re-examine rather than the answer.

- **Answer this first, because it ends the item if it is no:** is there any App Store-legal mechanism in 2026 for an app to deliver a screensaver? If not, the rest is moot and the note stands.
- **The agent is the harder half, not the saver.** It is unsandboxed by design: it opens SQLite and the cache directly, binds a localhost listener, holds the Photos TCC grant, and registers as a LaunchAgent through `SMAppService`. Sandboxing it means an App Group container for the database and cache, `com.apple.security.network.server` for the listener, `network.client` for everything that asks, and re-testing every path that touches a file.
- **`pgr_ctl` is not a constraint here.** It is a debugging tool and need not ship at all, so a sandboxed build simply leaves it out and it keeps the direct database access that is the rig's whole premise. The consequence worth knowing is that the shipped configuration would then be one nothing exercises from a terminal — a fact to hold, not a problem to solve.
- Worth noting the widget already forces part of this: an app extension is sandboxed on macOS whether we like it or not, which is why the agent serves over HTTP rather than sharing a store.

## Installing by launching the app

Installing Photo-Go-Round should be the whole of installing Photo-Go-Round. **Needs its own plan document.**

- **The agent half is already designed** and not built: `app/mac/FEATURES.md`, *The app brings its own agent* — `photogoroundd` inside the app bundle at `Contents/Library/LoginItems/`, registered with `SMAppService.agent(plistName:)`. See also `PLAN.md`, *An installer is probably unnecessary*.
- **The saver half is not designed at all.** An unsandboxed Developer ID app can copy `Photo-Go-Round.saver` into `~/Library/Screen Savers` itself, which is what `Scripts/make-saver-bundle.sh --install` does today by hand.
- **Selecting it is probably not ours to do.** Installing a screensaver and making it the user's screensaver are different acts, and the second one is theirs.
- **Updating is the part that bites.** `legacyScreenSaver` caches the loaded bundle for the life of its process and System Settings caches its list, so replacing an installed saver means killing both — the script already does this, and an app doing it silently to a running screensaver needs thought.
- **Decide which deployment a shipped app runs in.** The app and the saver both ask for `.development` today; a shipped one must not.
