# Summary

The Mac app's own features — what the window gains beyond showing a photograph. Subordinate to `PLAN.md`, which plans the system.

# Rationale

`PLAN.md` plans a system: a library, a service, and a sequence of surfaces that consume it. The app accumulates features that live entirely inside its window and matter to nothing else, and threading each through the phase list would bury the shape of the project under interface detail. They also arrive on their own cadence — the app is the only place a person touches any of this, so it grows whenever using it makes an absence obvious rather than when a phase says so.

Building the first of them forced a decision that is **not** app-specific: the database became private to the service and preferences became how every process asks and answers. That lives in `PLAN.md` under *The database is private to the service*, because it governs the screensaver, the widgets, and iOS as much as this window. The first two deliverables below are that work; the rest is the app.

# Phases

- *Source status published to preferences* — the agent writes what it found where anything can read it.
  - `sourceStatus`, keyed by locator and carrying the source's `uuid`: photo count, availability, reason, `scannedAt`.
  - Published after each reconcile and each refresh. **Rings no doorbell.**
- *`pgr_ctl`'s sources verbs stop opening the database* — they become a friendlier `defaults write`.
  - `add` writes preferences and rings once; it no longer reconciles or scans. **Done** — it resolves through the kit and writes the batch in one go.
  - `list` reads `sources`, merges `sourceStatus`, works with no agent running.
  - `remove`, `enable`, `disable` address a source by locator rather than a row id.
- *Sources in Settings* — one panel that shows what is configured and changes it.
  - A list with icon, name, count, and state; path secondary.
  - `Add Files…` — files only, multiple selection, one source per file.
  - `Add Folder…` — one at a time, with an "Also use nested folders" checkbox.
  - Remove a selected source.
- *Navigation in the picture window* — say "next" by hand.
  - Chevron on hover at the right edge; keys: space, →, ↓, page down.
  - One rule: no request sooner than `advanceIntervalSeconds` after the current picture was drawn.
- *Later, in the same places* — collapse per-file sources into one row; the Display tab for timer duration and fit; going backwards through history.

# Design Decisions

- **The architecture is `PLAN.md`'s, not this document's.** The database is private to the service, preferences are the RPC mechanism, bytes travel over HTTP and facts through preferences, `sources` and `sourceStatus` are separate keys, and a source's identity is the database's `Source.uuid`, which travels outward in published status while preferences address a source by locator. See *The database is private to the service*.
- **Settings, not the File menu.** Adding and removing act on one list, and only one of them has a picker shape.
- **One source per file, collapsed in the UI later.** The deck already treats a pinned photograph and a folder of ten thousand alike; changing that to tidy a list would be a schema change.
- **"Also use nested folders", not "Recursive."** Read by people who have never heard the word. Per folder, default off, not sticky.
- **One write, one doorbell.** A batch assembles the whole list and writes once, because the agent refreshes on every notification it hears.
- **Advancing is gated from the draw, not the request.** A slow fetch is then harmless, and coalescing needs no separate mechanism.
- **The photograph window acknowledges nothing.** New pictures simply appear; the panel is where a change is confirmed, because that is where it was made.

# Background

The app is a client: it reads `servicePort` from preferences, asks the service for a picture, and draws what it is handed. Sources are configured today only by `pgr_ctl`, or by `--add-folder` and `PGR_FOLDERS` at the agent's launch — and `pgr_ctl` is internal and never ships, so there is no user-facing way to add a photograph to the library at all.

One statement in `PLAN.md` says this should not exist, and it is the one argued with below: *The Mac app as instrument panel* has the Phase 3 app "manages no sources and exposes no settings, because `pgr_ctl` shipped one phase earlier and already does both." The other two it contradicts — *Identifiers*' rule that `pgr_ctl` owns preference writes, and *Preferences*' line that derived state lives in the database — are answered in `PLAN.md` itself, where the mechanism now lives.

# Detailed discussions

## The architecture this rests on lives in PLAN.md

Building this panel forced a system-wide decision, and it is recorded where every surface reads it rather than here: **`PLAN.md`, *The database is private to the service*.** In short — nothing but the agent opens the database, preferences are the RPC mechanism, HTTP carries bytes and preferences carry facts, `sources` and `sourceStatus` are separate keys, a source's identity is the database's `Source.uuid` while preferences address it by locator, and WAL stays for reasons that moved inside the agent.

That section also carries what it revised elsewhere in `PLAN.md`, and the debt it leaves in `pgr_ctl`'s remaining verbs. Everything below is what is specific to this app.

## Why this reverses "the app manages no sources"

The original argument was scope discipline and it was right at the time: `pgr_ctl` had shipped one phase earlier, it did sources properly, and a second implementation would have cost the phase its smallness. What it did not weigh is that `pgr_ctl` **never ships**. So "the app manages no sources because the tool does" quietly means "a user who is not Syd cannot add a photograph to their own library" — not a scope decision but a missing product.

The reversal stays narrow. The app gains sources and nothing else; enable, disable, refresh, cache clearing, and every tuning preference stay in `pgr_ctl` until something makes each a gap the same way.

## Why Settings rather than the File menu

The first sketch put `Add Files…` and `Add Folder…` in the File menu, and it was wrong for a reason worth keeping: **removing has no menu-item shape.** A picker shows the filesystem, not the library, so a File-menu remove would ask the user to navigate to a folder in order to say "not that one", and would silently do nothing if they chose one that was never a source. Add would live in one place and remove in a command-line tool the user does not have.

A panel dissolves that. The list is what you act on, removal is selecting a row, and adding is a button that happens to open a picker. It also produces the acknowledgement a menu item could not: **the new source appears in the list immediately**, because the app just wrote it and does not have to ask anyone.

macOS has a place for this: SwiftUI's `Settings` scene, which is the standard window and takes ⌘, for free.

## The beat between writing and knowing

The app writes, the agent scans, the count arrives when status is next published. A freshly added folder appears at once with its name and icon and no count, and the number fills in a moment later.

That is honest rather than a gap — the delay *is* the agent doing the work, and a count that appeared instantly would be a lie about a folder of eight thousand photographs. With no agent running, adding still works, the row still appears, and no count ever arrives; the panel says why, reusing the wording `Shuffle.Trouble.noAgent` already has.

What stays silent is narrower than it was but not nothing: an empty folder and a folder still being scanned look alike until the number lands, and a denied TCC prompt shows as unavailable only once the agent has tried.

## TCC, the pickers, and whose grant is whose

Two processes are involved and only one is looking at a window, which is what makes this confusing later.

The app is unsandboxed, so `NSOpenPanel` returns paths it could have read anyway, and what it does with them is write strings into preferences. **No access is transferred to the agent**, and none needs to be: the agent is unsandboxed too and reads the paths itself.

What the agent may still need is TCC consent — Files-and-Folders for `~/Desktop`, `~/Documents`, `~/Downloads`, iCloud Drive, removable and network volumes. Consent is keyed to a code-signing identity, and the agent is a separate bundle with its own, so the prompt names the agent rather than the app. The picker cannot avoid that and should not try: *TCC: unsandboxed does not mean unrestricted* decided that only the server touches files, which is what keeps every privacy grant on one bundle and one entry in each Settings list.

What the picker buys is timing. A background process with no window prompting for Documents access is baffling; the same prompt two seconds after the user chose a folder in a dialog is legible. The plan asked for exactly this and had nothing to hang it on until there was a window.

**This is also why the panel has no refresh button.** Adding a folder the user just chose is fine. Re-enumerating arbitrary existing sources from the app would make the app touch files in its own right, and that is the line that keeps the grant on one bundle.

## What the panel can show, and the correction that got us here

An earlier draft of this document claimed the panel had to show bare paths because that was all the app could see without the database. **That was wrong twice over.**

The app is unsandboxed and links the kit, so the filesystem is directly available: leaf names, `NSWorkspace.shared.icon(forFile:)`, and QuickLook thumbnails, none of which involve the database, the cache, or the service. And with `sourceStatus` published, real counts and availability arrive too.

So the list shows an icon, a name, a count, and a state, with the path secondary — and an icon-grid modality is a later refinement rather than a different architecture. The one degradation to expect: a source added by `pgr_ctl` may sit somewhere the *app* has never been granted, and the graceful answer is a generic icon rather than a prompt.

The visual language stays plain regardless, and that is a decision about where effort goes. The screensaver is the surface where presentation **is** the product; whatever it settles — how a photograph is presented small, what a missing one looks like, how motion is used — is what this panel should borrow from rather than inventing a second answer now that would be the worse of the two.

## One source per file, and what it costs

`SourceKind.file` is first-class, and the plan is explicit that pinning one photograph and adding a folder of ten thousand are the same operation to the deck. A selection of two hundred photographs therefore produces two hundred specs, two hundred rows, and two hundred entries in the preferences array.

The cost is presentational: `pgr_ctl sources list` becomes a wall of one-photo sources and the panel's list does too. The alternative — a kind holding a set of files — was rejected because it is a schema change, a provider change, and a spelling `pgr_ctl --file` could not round-trip, all to fix how a list prints. So the model stays and the panel collapses them later: one row reading "12 photographs" that expands, and one act that removes the set.

One thing to remember when building that: these sources have **no group identity in the data.** They are individually chosen photographs that happen to have been picked in one dialog. Grouping by anything but kind would mean inventing a batch identifier — a schema change deferred rather than avoided.

## "Also use nested folders"

The preference is `recursive`, the flag is `--recursive`, and the checkbox says neither, because it is read by somebody who would not guess that means "and everything inside it."

- **Per folder, not per run.** The plan fixed this once already, after recursion applied to a whole command and a flat directory and a nested tree could not be added together. One folder per dialog keeps the checkbox honest.
- **Default off.** The surprising direction is the expensive one — walking a home directory by accident costs minutes and thousands of photographs nobody meant to add.
- **Not sticky.** Remembering the last answer applies a previous decision to a different folder unattended, and the expensive direction is the one that would be inherited.

## Removing, and what it does not touch

`remove` drops the source from preferences; its photographs and their queue entries go by cascade. **Cached bytes are not deleted at that moment** — the rows naming them are gone, so nothing points at the files, and a running agent reclaims them on its next maintenance pass. Freeing the space immediately is `pgr_ctl cache clear --source` *before* removing, which the panel does not offer and should not: it is a storage operation with a price worth stating, and stating prices is what `pgr_ctl` is for.

Removal is not deletion. Nothing on disk is touched — only the library's knowledge of it. Disabling, for "not right now", stays in `pgr_ctl`; the panel offers the destructive-sounding verb because it is the one with a user-facing need.

## Advancing costs a card

Serving pops the queue and the pop is irreversible — no reservation, nothing to reclaim. So there is one rule, and it lives in `Shuffle` where every trigger inherits it:

> **A request may be issued no sooner than `advanceIntervalSeconds` after the current picture was drawn.**

The clock starts at the **draw**, not at the previous request, and that is what makes a slow fetch harmless: however long the bytes take, the next request still waits half a second after the picture they produced went up. A held key changes the picture every half second plus whatever the fetch costs.

Coalescing needs no separate mechanism. The gate cannot open while a fetch is outstanding, because nothing has been drawn yet — so two requests can never be in flight and no popped photograph is ever discarded. A keypress arriving early is dropped rather than queued.

`advanceIntervalSeconds` defaults to 0.5 and is parsed with a default and a clamp like every other key, so `pgr_ctl set` tunes it whether or not the app ever exposes it. It is the first preference the agent itself does not read, which is a small oddity worth knowing when it appears in a `pgr_ctl get` listing.

## Building forwards so that backwards fits

Going backwards is a later feature, but it decides the shape of forwards: once there is history, advancing must walk it before asking the service for anything new. Retrofitting that means rewriting the advance path rather than adding to it.

So the path is built around a cursor now that only ever moves forward, and "back" later becomes a ring capacity, a key binding, and a second chevron. The storage question that comes with it is worth recording early: a ring of decoded 4K `CGImage`s is tens of megabytes apiece, while the served bytes are a few hundred kilobytes — so history should hold `ServedPicture` and decode on demand.

Mechanically, the dwell becomes interruptible by holding the sleep in its own task that the loop awaits; cancelling *that* ends the wait while the loop survives. Any advance restarts the full dwell, so a deliberate "next" gives a whole interval before the automatic one.

## Chevrons on the photograph

Hovering the right edge reveals a chevron that fades on exit. The left one is **not drawn at all** until history exists — a control that can never become enabled is worse than no control.

They sit over the photograph, which is a deliberate exception to *Showing unavailability*'s "the photo is never annotated." That rule forbids badges and warnings defacing an image to report a problem elsewhere; it does not forbid a transient control that appears under the pointer and vanishes.

Keys are space, →, ↓, and page down, on the focused window. Each window owns its own `Shuffle`, so only the key window advances — the multi-window behaviour falls out of the existing design rather than needing arbitration.

## What happens if the app is ever sandboxed

*The sandbox contingency* names what would force it and what it would cost, and this adds one item.

Sandboxed, `NSOpenPanel` becomes a powerbox transaction: access arrives as a security-scoped bookmark rather than a path. Writing the path into preferences would hand the agent a string it has no right to use — except the agent is a separate, unsandboxed process, so it would work anyway. The fragility is that the app's ability to add a source would stop being a property of the app and become a property of the agent staying unsandboxed.

If both were sandboxed, the source list would carry bookmark data rather than paths — the change `SourceSpec` and `FileAccess` were built to absorb, one nullable column with the provider code identical either way. Worth knowing this feature is the first thing that would break, and that the insurance already exists.

## Captured, not designed

Raised and deliberately not worked out.

- Copy the current image to the clipboard.
- Print the current image.
- Save the current image to a file.
- Drop an image from the queue from the app.
- The grow / shrink / stretch / aspect-ratio family, which needs the service's `fit` parameter — already parked in `PLAN.md`'s Phase 3.
- **Deleting the file itself gets its own plan.** Not an app feature: it crosses the app, the service, the pool, the deck's history, the cache, and the source, and it is the only irreversible thing the product would do. Everything `PLAN.md` says about deletion today is *reactive* — noticing a photograph somebody else removed and ceasing to show it. Removing one on purpose runs the other way and nothing covers it.

Two facts that already exist and would otherwise be rediscovered. **Saving** wants a filename and the response carries none — that is `X-PGR-Name`, item 8 on the known-shortcomings list, unbuilt; printing and the clipboard need only the bytes. And *Never showing a photo the user deleted* is where the delete-from-source design would have to start.

## Documents this contradicts

Not edited here; recorded so the contradictions are deliberate.

- **`Documentation/photogoroundd.md`** — the PREFERENCES table gains `sourceStatus` and `advanceIntervalSeconds`, and the sentence that derived state lives in the database needs its exception naming.
- **`Documentation/pgr_ctl.md`** — `sources add` no longer scans immediately; `remove`, `enable`, and `disable` take a UUID; "every command here opens the same SQLite database or writes the same preference domain" narrows.
- **`PLAN.md`** — *The Mac app as instrument panel*, *Identifiers*' rule that `pgr_ctl` owns preference writes, and *Preferences*' derived-state sentence.

# References

- `PLAN.md` — the system's plan. *The service is the interface*, *Sources live in preferences, not in the database*, *The doorbell rings back at you*, *TCC: unsandboxed does not mean unrestricted*, *Preferences*, *Clearing the cache on purpose*, *Showing unavailability*, and *The sandbox contingency*.
- `Documentation/pgr_ctl.md` — `sources add`, `remove`, `enable`, `disable`, whose behaviour the panel matches.
- `Documentation/photogoroundd.md` — the four configuration channels, *configured, not commanded*, and `--port`'s account of publishing a value that outlives its writer.
