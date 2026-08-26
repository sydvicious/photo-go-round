# Summary

The Mac app's own features — what the window gains beyond showing a photograph. Subordinate to `PLAN.md`, which plans the system.

# Rationale

`PLAN.md` plans a system: a library, a service, and a sequence of surfaces that consume it. The app accumulates features that live entirely inside its window and matter to nothing else, and threading each through the phase list would bury the shape of the project under interface detail. They also arrive on their own cadence — the app is the only place a person touches any of this, so it grows whenever using it makes an absence obvious rather than when a phase says so.

Building the first of them forced a decision that is **not** app-specific: the database became private to the service, and a client asks it over HTTP rather than reading the store. That lives in `PLAN.md` under *The database is private to the service*, because it governs the screensaver, the widgets, and iOS as much as this window. The first deliverable below is that work; the rest is the app.

# Phases

- *Web services for managing sources* — **done.** The agent answers, so a client never opens the store.
  - `GET /v1/sources` — the list, with photo count, availability, reason, and the source's `uuid`.
  - `POST /v1/sources` — add an array, all or none; returns what was created.
  - `GET /v1/sources/<uuid>` — one source, with the options it was added with.
  - `PATCH /v1/sources/<uuid>` — change one of those options; today that is `recursive`.
  - `DELETE /v1/sources/<uuid>` — remove one.
  - `pgr_ctl` is unchanged: it keeps preferences and the database, and never makes a web request. Command-line HTTP is `curl`.
- *Sources in Settings* — **done**, and superseded in shape by *Sources by kind, in sections* below. One panel that shows what is configured and changes it.
  - A list with icon, name, count, and state; path secondary.
  - `Add Picture Files…` — files only, multiple selection, one source per file.
  - `Add Picture Folder…` — one at a time, with an "Add contents of contained folders" checkbox.
  - **Two panels as of 2026-08-26**: *Apple Photos* on top, *Folders and Files* below enclosing everything above. See *Two panels, because there is one Photos library*.
  - `Select Collections…` in the upper panel — present and disabled, replacing the `Add from Photos Library…` menu item. The provider exists and `pgr_ctl sources add --album` works; what is missing is the picker, Phase 5 of `Apple Photos Plan.md`.
  - Remove a selected source.
  - Configure a selected folder — the button, the context menu, or a double-click — showing the full path and the one option it has.
  - The list is re-read at launch, when the panel appears, and every few seconds while it is open.
- *Choosing Photos collections* — **done 2026-08-26.** `Select Collections…` opens a picker over the agent's `/v2/photos/albums`.
  - Its own resizable `Window`, not a sheet: several hundred rows have to be resizable and a macOS sheet is not.
  - An outline of Photos' four sections, with folders nested inside them and albums under the folder that holds them.
  - A checkbox per album; three-state checkboxes on folders, which are never sources themselves.
  - Favorites pinned above the headings, in the heading's weight.
  - Counts arrive as the agent counts — absent is not zero, and the footer says `Counting 343 of 439…` so blanks are explained.
  - The unauthorized state lives here: an Allow button while undecided, a pointer to System Settings after.
  - Done applies it: one `POST` for what was ticked, a `DELETE` each for what was unticked, adds first.
- *Navigation in the picture window* — say "next" by hand.
  - Chevron on hover at the right edge; keys: space, →, ↓, page down.
  - One rule: no request sooner than `advanceIntervalSeconds` after the current picture was drawn.
- *Sources by kind, in sections* — replaces the single list, and settles what to do about a two-hundred-file selection.
  - A "Files" section and a "Folders" section, each with its own `+` and `−` beneath it, each showing five rows before it scrolls.
  - `+` is that kind's picker, so the menu that chooses a kind goes away with it.
  - Multiple selection inside a section, ⌘A included, so `−` removes everything selected in one act.
  - **Photos did not wait for this and did not take a section.** It is a panel, because there is one Photos library and never a list of them — see *Two panels, because there is one Photos library*. Google Photos is untouched by that argument and would still be a section here, or a panel of its own.
  - What remains for this phase is Files and Folders, which are genuinely a list of things you add to.
  - **Supersedes collapsing per-file sources into one row.** Sections do the same job — keeping two hundred pinned photographs from being two hundred undifferentiated rows — without inventing the batch identifier the data does not have.
  - Removing several at once wants a batch `DELETE`, or the panel makes a request, a preference write, and a doorbell *per row*. `POST` takes an array for exactly this reason and `DELETE` does not yet.
- *The sources panel resizes* — **done 2026-08-26.** A list that is always the same height is the wrong height twice: once for a single folder, and again for two hundred pinned files.
  - The window resizes in both directions. Vertically for the reason above; horizontally because a row shows its whole path and head-truncates when it will not fit, and because the Apple Photos panel names every collection in play in three lines at most, so width is what decides how many of them can be read.
  - It opens tall enough for what is actually configured, bounded by the screen, rather than opening at a fixed height and being dragged out again on every visit.
  - **This meets *Sources by kind, in sections***, which fixes each section at five rows before it scrolls. Whether the sections divide the available height between them or keep their own count is unsettled, and belongs to whichever of the two is built second.
- *Saying the agent is not there* — **done.** The window title becomes `Photo-Go-Round - No agent`, and the photograph dims behind a flat grey at three-tenths.
  - Nothing is written on the picture: a badge would have to stay legible against whatever is behind it, and `PLAN.md`'s *Showing unavailability* forbids annotating a photograph to report a problem elsewhere. A title has its own background.
  - The picture stays visible rather than being taken down, so what is on screen is still a photograph — veiled, and unmistakably not being replaced.
  - Only for an agent that cannot be reached. An empty queue resolves itself as the agent produces, and a dimmed window every time it ran briefly dry would be noise.
- *The empty state moves* — when there is nothing to show, say so without leaving a still frame on the glass.
  - The words drift around the window and bounce off the edges.
  - Slow. The motion is there to keep the pixels from sitting still, not to be looked at.
  - The motion is the same for every empty state; **the words are not.** "No photos" for an empty queue, and "No agent" when nothing is listening. The reason stays underneath as secondary text.
  - **One exception, and it is narrow**: when registering the agent was *refused*, the window says "Problem launching the agent. Contact support@sydpolk.com." — see *The app brings its own agent*. Anything else with no agent, including one that registered and later stopped, is "No agent".
  - Built here so Phase 6 inherits it: `PLAN.md`'s *The Mac app as instrument panel* parks the bouncing empty state in the app precisely so the screensaver does not invent a second one.
- *The app brings its own agent* — installing Photo-Go-Round should be the whole of installing Photo-Go-Round.
  - `photogoroundd` ships inside the app bundle, with its launchd plist in `Contents/Library/LaunchAgents/`.
  - The app registers and starts it at launch, and does nothing when it is already registered. Mechanism settled in `PLAN.md`, *An installer is probably unnecessary*.
  - Decide which deployment the embedded agent runs in — the app asks for `.development` today, and a shipped one must not.
  - Leave a development agent alone if one is already serving on the same preference domain; two agents on one library is the failure this must not cause.
  - Say what happened when registration is refused. It is the one failure that leaves the window with nothing to show and no way for the user to fix it, which is why it is the one that names somewhere to write to: "Problem launching the agent. Contact support@sydpolk.com."
  - `Scripts/make-agent-bundle.sh` and `pgr_ctl register` stay the rig's way in; decide whether the script is subsumed by a copy phase.
- *A menu bar app* — the picture window becomes something the app can show rather than the app itself.
  - A status item, and an item that brings the window up.
  - **Deliberately unfinished.** What else belongs in that menu, whether the Dock icon goes with it, and what closing the last window means are all open.
- *Later, in the same places* — the Display tab for timer duration and fit; going backwards through history.

# Design Decisions

- **The architecture is `PLAN.md`'s, not this document's.** The database is private to the service; a client asks over HTTP and never opens the store; preferences stay the durable source list, the discovery channel, and `pgr_ctl`'s business; a source is named by its `Source.uuid`. See *The database is private to the service*.
- **Settings, not the File menu.** Adding and removing act on one list, and only one of them has a picker shape.
- **A `Window` scene of the app's own, not SwiftUI's `Settings` scene. Changed 2026-08-26.** `Settings` gives the menu item and ⌘, for free and will not yield a resizable window at any price — `.windowResizability(.contentMinSize)` declared on it is ignored. `CommandGroup(replacing: .appSettings)` buys both back in two lines.
- **Apple Photos is a panel, not a row and not a section.** There is one Photos library and there always will be, so what Settings holds is one standing statement of which collections are in play. It also gives authorization somewhere permanent to live, which a picker that exists only while it is open cannot.
- **The lower list is everything that is *not* a Photos collection**, rather than folders and files by name, so a kind the panel has not been taught about appears somewhere it can be seen and removed instead of being configured and invisible.
- **The picker is a chooser, not an adder.** What is ticked when you press Done *is* the set of Photos sources — so it opens showing what is already true, and unticking removes a source. There is one Photos library and it does not get added to twice.
- **Apple has no collection picker, and this is not a gap we filled reluctantly.** `PHPickerResult` carries an asset identifier and an item provider; `PHPickerCapabilitiesCollectionNavigation` lets somebody browse *into* an album and still returns photographs. Checked against the macOS 27.0 SDK.
- **One window telling another is not a doorbell.** The agent rings `.sourcesChanged` for every edit and this app does not listen. What the picker announces is narrower: a change *this app* just made, which another of its own windows is displaying. Waiting a minute to redraw something we did ourselves reads as a panel that has broken.
- **The word is "photo", not "photograph."** It matches the product's own name. Prose in these documents is not bound by it.
- **One source per file, collapsed in the UI later.** The deck already treats a pinned photograph and a folder of ten thousand alike; changing that to tidy a list would be a schema change.
- **"Add contents of contained folders", not "Recursive."** Read by people who have never heard the word. Per folder, default off, not sticky.
- **One request, one write, one doorbell.** `POST` takes an array rather than one source, because adding two hundred one at a time would ask the agent to refresh two hundred times.
- **Configure is a `PATCH`, not a remove-and-re-add.** A source keeps its `uuid`, its cache directory, and its deal history when a checkbox changes; recreating it would throw all three away for a tick box. It is a sheet rather than an inline control because a Photos album will have several options and this is the shape that grows.
- **The panel does not need the endpoint for file and folder sources at all.** It is unsandboxed, so preferences and the filesystem give it everything about one except the photo count. The endpoint stays because other kinds will need it: a Photos or Google album is not a path, and only the agent can answer for it. See *What the panel could get without the agent*.
- **Where a source stands, the app just looks.** `SourceAvailability.of(path:)` is the kit's own rule, run here on the path the app already has. **The endpoint deliberately does not check** — it reports what the last scan concluded — because an answer that came over HTTP is a round trip old before it is drawn, and making the agent `stat` every source on every read would buy a worse answer at a higher price.
- **The panel polls, because nothing rings a doorbell it can hear.** `pgr_ctl` removes a source, a drive is unplugged, a freshly added folder finishes scanning — none of those reach this process. Opening Settings re-reads, and after that it is **every few minutes**, not every few seconds; a failed read tries again in fifteen seconds, because noticing the agent is back should not take three of them.
- **A control sizes its label, never itself.** A borderless button hit-tests its *content*, so putting the frame on the button reserves space that looks clickable and is not — the glyph is a few points across and every click beside it lands nowhere. `−` was dead for exactly this reason, with the model in a perfectly good state.
- **The panel says what it is doing, and the logging stays in.** `panel:` on every line, so the Xcode console filters to it in one word: what was pressed, what the selection is, what the flags gating the buttons were, what a read returned. Info is cheap; the hit-testing fault was found in a single click by a log line saying the button was enabled and no press had arrived.
- **A spinner, and everything disabled until the change lands.** Any action that goes to the agent locks the `+`, `−`, and Configure controls *and* the list, so nothing can be pressed twice and the selection cannot move under the buttons. Without it a working panel and a broken one look identical — which is what "I hit `−` and nothing happened" turned out to be.
- **The selection follows its source by locator.** A source can keep its place in the list and change identity, because anything that takes it out of the durable list and puts it back mints a new `uuid`. Dropping the selection then leaves a row that still looks chosen while every control reads *nothing selected*.
- **Advancing is gated from the draw, not the request.** A slow fetch is then harmless, and coalescing needs no separate mechanism.
- **The photograph window acknowledges nothing.** New pictures simply appear; the panel is where a change is confirmed, because that is where it was made.

# Background

The app is a client: it reads `servicePort` from preferences, asks the service for a picture, and draws what it is handed. Sources are configured today only by `pgr_ctl`, or by `--add-folder` and `PGR_FOLDERS` at the agent's launch — and `pgr_ctl` is internal and never ships, so there is no user-facing way to add a photograph to the library at all.

One statement in `PLAN.md` says this should not exist, and it is the one argued with below: *The Mac app as instrument panel* has the Phase 3 app "manages no sources and exposes no settings, because `pgr_ctl` shipped one phase earlier and already does both." The other two it contradicts — *Identifiers*' rule that `pgr_ctl` owns preference writes, and *Preferences*' line that derived state lives in the database — are answered in `PLAN.md` itself, where the mechanism now lives.

# Detailed discussions

## The architecture this rests on lives in PLAN.md

Building this panel forced a system-wide decision, and it is recorded where every surface reads it rather than here: **`PLAN.md`, *The database is private to the service*.** In short — no client opens the database, clients ask the agent over HTTP for pictures *and* for facts, preferences remain the durable source list and the way `servicePort` is found, `pgr_ctl` is the rig rather than a client and keeps its direct access, and WAL stays for reasons that moved inside the agent.

That section also carries what it revised elsewhere in `PLAN.md`, and the debt it leaves in `pgr_ctl`'s remaining verbs. Everything below is what is specific to this app.

## Why this reverses "the app manages no sources"

The original argument was scope discipline and it was right at the time: `pgr_ctl` had shipped one phase earlier, it did sources properly, and a second implementation would have cost the phase its smallness. What it did not weigh is that `pgr_ctl` **never ships**. So "the app manages no sources because the tool does" quietly means "a user who is not Syd cannot add a photograph to their own library" — not a scope decision but a missing product.

The reversal stays narrow. The app gains sources and nothing else; enable, disable, refresh, cache clearing, and every tuning preference stay in `pgr_ctl` until something makes each a gap the same way.

## Why Settings rather than the File menu

The first sketch put `Add Files…` and `Add Folder…` in the File menu, and it was wrong for a reason worth keeping: **removing has no menu-item shape.** A picker shows the filesystem, not the library, so a File-menu remove would ask the user to navigate to a folder in order to say "not that one", and would silently do nothing if they chose one that was never a source. Add would live in one place and remove in a command-line tool the user does not have.

A panel dissolves that. The list is what you act on, removal is selecting a row, and adding is a button that happens to open a picker. It also produces the acknowledgement a menu item could not: **the new source appears in the list immediately**, because the app just wrote it and does not have to ask anyone.

macOS has a place for this: the Settings window, under the application menu and on ⌘,.

**It is not SwiftUI's `Settings` scene, as of 2026-08-26.** That scene gives the menu item and the shortcut for free, and it would not give a window the user can resize — `.windowResizability(.contentMinSize)` declared on it is ignored, and reaching the `NSWindow` to insert `.resizable` in its style mask did not help either. It is a `Window` scene now, with `CommandGroup(replacing: .appSettings)` restating the menu item and ⌘,. Two lines, and the window resizes.

## Two panels, because there is one Photos library

The first sketch had Photos as another row in the list, and the one after it had a picker opened from the `+` menu. Both are wrong in the same way: they treat a Photos source as *a source*, one of a growing list you add to.

There is one Photos library on this machine and there always will be. What Settings holds is therefore not a list to append to but **one standing statement of which collections are in play** — so it is a panel, permanently present, above the list of things that genuinely are a growing collection.

It holds three things: the chosen collections comma-separated, capped at three lines so that checking forty of them cannot push the folder list off the bottom; the total number of photos across them, right-aligned above the button; and `Select Collections…`, which opens the picker.

**The count is a plain sum and that is now correct.** One asset in three collections is one row belonging to whichever collection reached it first, so adding the per-source counts cannot double-count — see `PLAN.md`, *One photograph, one row*. Before that landed it would have, and badly, since overlapping collections are the normal case rather than the exception. While any chosen collection is unscanned the line reads "so far", for the same reason a fresh row says "scanning…" instead of "0 photos": a number that silently omits a collection nobody has walked yet is a delay dressed as an answer.

**What the shape buys that a picker alone could not** is somewhere for authorization to live. A dialog that exists only while it is open has nowhere to say *this app has not been given access to your photo library*, and nowhere to put the button that asks. That state is not built yet and now has a home waiting for it.

**What it costs** is that the panel is present even for someone who never uses Photos, saying "No collections selected." That is the right trade: it is one line, and it is also the only place the feature announces that it exists.

## The picker, and the three shapes it went through

The first sketch was a popup menu of album names, one at a time. The second was a modal picker opened from `+`. The third is what shipped, and the two before it were wrong in the same way: they treated a Photos collection as *a source*, one of a growing list you add to.

It is not. There is one Photos library and there always will be, which is why the panel holds a standing statement of what is in play rather than a list you append to, and why the picker is a chooser rather than an adder.

**It is an outline because Photos has real folders.** Four flat sections lost them, and with them the only thing that tells two same-named albums apart: a measured library of 439 collections had 31 titles used more than once. Twenty-two of those spanned sections and were already distinguishable by their heading; the remaining nine were separated by their counts, which was luck — counts arrive late and two albums can be the same size. The tree removes the luck.

**Folders get three-state checkboxes and are never sources.** A folder holds albums, not photographs. Its checkbox summarises what is beneath it and is derived on every draw, so there is no folder state anywhere that could drift out of step with the albums. It is a real `NSButton` with `allowsMixedState` rather than an approximation drawn from SF Symbols, because a control that looks *nearly* like the system's is worse than the system's.

**A search field was built and removed.** Three hundred and fifty-three albums is not browsable as one list, and a search box is the obvious answer — but collapsing the three sections you are not looking in does the same job with a control that is already there for its own reasons.

**Favorites is pinned above the headings.** Technically an album; not one in any other sense. Library and Recents have the same argument and were deliberately left where they are, because ticking Library is 95,904 photographs in a single click.

## The beat between asking and knowing

`POST /v1/sources` does not wait for the scan. It resolves the paths, writes them, and answers — because a folder of eight thousand photographs takes seconds to walk, and a request that blocked on it would look like a hang for the one case that matters most.

So a freshly added folder appears at once with its name, its icon, and no count, and the number arrives on a later `GET`. That is honest rather than a gap: the delay *is* the agent doing the work, and a count that appeared instantly would be a lie.

What the status code does buy, which publication never could, is the immediate half of the answer. A path that stopped resolving between the dialog and the request comes back as a refusal naming it, rather than as a source that quietly never produces anything.

What stays silent is narrower but not nothing: an empty folder and a folder still being scanned look alike until the number lands, and a denied TCC grant shows as unavailable only once the agent has tried. With no agent, nothing can be added at all — and nothing could be shown either, so the panel says the same thing the window does.

## The longer beat: a source is added long before it is *seen*

Distinct from the one above, and worth separating because a user hits it as one experience. The count arriving late is seconds. **A photograph from that source actually appearing in the window can be many minutes**, and on 2026-08-24 it was measured at hours for a network folder — with nothing anywhere saying why.

Three delays compose, and only the first is the scan:

1. **The scan.** Seconds. The panel shows this honestly as no count yet.
2. **Having bytes.** For a source on a network volume or in Photos this now comes *before* reaching the queue, and it is the long step. The cache draws remote photographs at random and fetches them at its own pace — twice the deck's size at launch, then one per picture shown — so a new network source warms in proportion to how much of the library it is, and a fetch that does not answer within its bound (a minute for a file, fifteen for a photo library) is abandoned and its source is rested rather than holding a slot. A photograph on the boot volume skips this step entirely: it is read where it lies.
3. **Reaching the queue.** Once a photograph has bytes it joins the deck's pool, and cards are dealt from one shuffled order over that pool. A card is only dealt when there is room for one, and the agent fills the queue whether or not anybody is watching, so a source added to an idle library reaches the queue rather than waiting for somebody to open the window.

Step 2 is the one that surprises, because it is invisible: the source is present, available, correctly counted, and shows nothing. **A large network source warms over hours, not minutes.**

What it does *not* do, measured 2026-08-26, is settle at a permanently reduced share. The cache rotates, so a photograph enters the deck's pool as a card that has never been dealt — and a never-dealt card is eligible where the rest are waiting out the repeat window. Across two ratios the remote half's share of the screen matched its share of the library, from a resident set as small as three photographs in ninety-three. What bounds it is how fast the fetches land, not how much of the cache it occupies.

**Nothing in the panel says any of this**, and something probably should. The honest number is not a percentage of the library cached — that would read as a progress bar for something that never completes, since the cache is a bounded window and not a copy. Whatever it becomes, the fact to convey is "reachable and warming" as a state distinct from "reachable", so a folder added an hour ago that has shown nothing does not look broken. Unresolved; recorded so the next person to notice it does not have to re-derive it from a log.

**Step 3 shrank a great deal on 2026-08-24, and the reason is worth knowing here rather than only in `PLAN.md`.** Three agent-side changes — a fetched photograph returns to the queue instead of waiting to be dealt again, the deck advances at the rate pictures are shown rather than at the rate cards are consumed, and cards are placed at random positions instead of at the back. Measured end to end on a real network folder, from a card being dealt to its photograph being displayed: **8m 38s** before, **4m 46s** after. Of that original figure, one second was the network and the rest was queue traversal.

So the delay a user experiences is set almost entirely by `queueSize`, which is a preference and not a property of their storage. That matters for what the panel could eventually say: "warming" is a state with a knowable duration, not an indefinite one.

## TCC, the pickers, and whose grant is whose

Two processes are involved and only one is looking at a window, which is what makes this confusing later.

The app is unsandboxed, so `NSOpenPanel` returns paths it could have read anyway, and what it does with them is write strings into preferences. **No access is transferred to the agent**, and none needs to be: the agent is unsandboxed too and reads the paths itself.

What the agent may still need is TCC consent — Files-and-Folders for `~/Desktop`, `~/Documents`, `~/Downloads`, iCloud Drive, removable and network volumes. Consent is keyed to a code-signing identity, and the agent is a separate bundle with its own, so the prompt names the agent rather than the app. The picker cannot avoid that and should not try: *TCC: unsandboxed does not mean unrestricted* decided that only the server touches files, which is what keeps every privacy grant on one bundle and one entry in each Settings list.

What the picker buys is timing. A background process with no window prompting for Documents access is baffling; the same prompt two seconds after the user chose a folder in a dialog is legible. The plan asked for exactly this and had nothing to hang it on until there was a window.

**This is also why the panel has no refresh button.** Adding a folder the user just chose is fine. Re-enumerating arbitrary existing sources from the app would make the app touch files in its own right, and that is the line that keeps the grant on one bundle.

## What the panel can show, and the correction that got us here

An earlier draft of this document claimed the panel had to show bare paths because that was all the app could see without the database. **That was wrong twice over.**

The app is unsandboxed and links the kit, so the filesystem is directly available: leaf names, `NSWorkspace.shared.icon(forFile:)`, and QuickLook thumbnails, none of which involve the database, the cache, or the service. And `GET /v1/sources` supplies the rest — real counts and availability, from the one process that knows them.

So the list shows an icon, a name, a count, and a state, with the path secondary — and an icon-grid modality is a later refinement rather than a different architecture. The one degradation to expect: a source added by `pgr_ctl` may sit somewhere the *app* has never been granted, and the graceful answer is a generic icon rather than a prompt.

The visual language stays plain regardless, and that is a decision about where effort goes. The screensaver is the surface where presentation **is** the product; whatever it settles — how a photograph is presented small, what a missing one looks like, how motion is used — is what this panel should borrow from rather than inventing a second answer now that would be the worse of the two.

## One source per file, and what it costs

`SourceKind.file` is first-class, and the plan is explicit that pinning one photograph and adding a folder of ten thousand are the same operation to the deck. A selection of two hundred photographs therefore produces two hundred specs, two hundred rows, and two hundred entries in the preferences array.

The cost is presentational: `pgr_ctl sources list` becomes a wall of one-photo sources and the panel's list does too. The alternative — a kind holding a set of files — was rejected because it is a schema change, a provider change, and a spelling `pgr_ctl --file` could not round-trip, all to fix how a list prints. So the model stays and the panel collapses them later: one row reading "12 photographs" that expands, and one act that removes the set.

One thing to remember when building that: these sources have **no group identity in the data.** They are individually chosen photographs that happen to have been picked in one dialog. Grouping by anything but kind would mean inventing a batch identifier — a schema change deferred rather than avoided.

## "Add contents of contained folders"

The preference is `recursive`, the flag is `--recursive`, and the checkbox says neither, because it is read by somebody who would not guess that means "and everything inside it."

- **Per folder, not per run.** The plan fixed this once already, after recursion applied to a whole command and a flat directory and a nested tree could not be added together. One folder per dialog keeps the checkbox honest.
- **Default off.** The surprising direction is the expensive one — walking a home directory by accident costs minutes and thousands of photographs nobody meant to add.
- **Not sticky.** Remembering the last answer applies a previous decision to a different folder unattended, and the expensive direction is the one that would be inherited.

**Unticking it later is a removal**, and the sheet says so before you do it. The photographs inside contained folders leave the pool and take their cached copies and their deal history with them — the same rule as any other departure, since a photograph nested inside a source that no longer reaches that far is not in that source, however healthily it sits on disk. Ticking it again finds them at the next scan, as new photographs with no history.

## Finding a dead button

Worth writing down because every plausible explanation was wrong, and the way through was not reasoning.

`−` did nothing. The candidates were all about state — the selection binding not updating, the row's identity changing underneath it, a change still in flight blocking the next one — and each had been a real bug at some point that evening, which made all of them credible. Two were fixed on the strength of it. Neither was this.

One line logging the press, and one logging the selection with the flags that gate the button, settled it in a single click: `can remove true, working false`, and no press. The button was enabled and the click never reached it. That leaves hit-testing, and nothing else.

**The general lesson is the cheap one.** A control that does nothing looks identical whether it is disabled, unbound, or unhittable, and no amount of reading the model tells them apart. A line that says *the press happened* separates the third from the first two before any theory is needed.

## The app has tests of its own

Added with the Settings panel, because the model is where the panel's behaviour actually lives: what a refusal leaves on screen, whether Configure is offered for what is selected, what happens to the selection when the row under it changes identity, and what the panel does while a change is in flight.

**What it cannot cover is the window.** The first bug this panel shipped with — a double-click gesture on a row swallowing the click that sets the selection, so every control acted on nothing — lived entirely in the view, and thirty passing tests said nothing about it. The target earns its keep on the model and the client; the window still needs somebody looking at it.

**Poll intervals are injected** for the same reason a socket test has a deadline: a test that waits three real minutes to prove a timer stopped is a test nobody runs. That one is not hypothetical — it was written with the production interval and took three minutes.

## What the panel could get without the agent

**Captured, not acted on. The app does not write preferences, and is not to start yet.** Everything it changes still goes over HTTP; the one preference it reads is `servicePort`, which is how it finds the agent at all.

**That one preference is a single point of confusion, and it bit on 2026-08-24.** The port is published by whichever agent started most recently, and the app follows it without asking whose it is. A second agent — started for a scratch run with `--container` and `--cache-root`, which isolate storage but *not* the preference domain — published over the running one, and the app began serving from an empty scratch library: real photographs, but a deck starting at ordinal 1 and every request a cold miss. When that scratch agent exited, the published port pointed at nothing and the window said "No agent" while a perfectly healthy agent was listening on the port it used to own. Neither state is distinguishable from a real fault by looking at the app. This is written down because it matters when the next source kind arrives, and because it is the sort of thing that gets rediscovered expensively.

**Settled: a test agent does not publish `servicePort` at all.** It serves normally and is reached by a port handed to `curl` and `pgr_ctl` by hand; nothing announces it, so nothing follows it. Starting a second agent to poke at becomes a safe thing to do rather than something that quietly redirects the window mid-session.

**The decision is the agent's to keep, and that is why this shape won.** The alternative considered was a reserved port — or range — that this app refuses on sight, and it is the worse answer twice over: it puts a blocklist in the client, which is a rule that can be got wrong by the side with the least information, and it still leaves a scratch agent publishing over the real one for every port outside the range. Not publishing removes the confusion at its source instead of teaching one reader to ignore it. **No app change at all**, which is the tell — the app already does the right thing with a port nobody overwrote.

What it costs is discovery: an unpublished agent cannot be found by anything that does not already know its port, so the flag should say what it bound plainly enough to copy out of a terminal. That is the whole of the trade, and it is the right way round — a test agent is started by someone who is watching.

**For a file or folder source, the panel needs the agent for one fact.** This app is unsandboxed and links the kit, so it can read the durable list itself and look at the filesystem:

| | preferences and the filesystem | only the agent |
| --- | --- | --- |
| kind, locator, recursive, enabled | yes | |
| name, icon, whether it can be reached | yes | |
| **photo count** | | yes |
| `uuid` | | yes |

The `uuid` costs nothing — preferences key on the locator, and so would the panel. **The photo count is the only real loss**, and it is the one number in that row that cannot be computed from a path: it lives in the pool, which is the database, which is the service's.

**The endpoint is not going away**, because the argument only holds for kinds that are paths. A Photos album is a `PHAssetCollection` identifier and a Google album is an id on somebody's server; neither can be looked at from here, and the agent is the only process that can say whether they are reachable or how many photographs they hold.

**What would still be true if the panel wrote preferences directly.** `PLAN.md`'s *The database is private to the service* rejected preferences-as-transport for five reasons, and three of them weaken for this app specifically: it resolves paths itself, so it knows immediately whether one is real; and it reads back its own writes, so it never watches its own change arrive late. **Two writers on one array does not weaken at all** — `pgr_ctl` writes the same key, `UserDefaults` has no compare-and-swap, and a lost update is a source that silently did not get added.

## Removing, and what it does not touch

`remove` drops the source from preferences; its photographs and their queue entries go by cascade. **Its cached bytes go with them, at that moment** — the originals we copied and every rendering made from them. That is a correction: this document used to say they were left for a running agent to reclaim on its next maintenance pass, and no such pass existed. The only reclaim was the byte index being rebuilt at the *next launch*, so removing a large source freed nothing until the agent was restarted. See `PLAN.md`, *Rows and bytes leave together*.

`pgr_ctl cache clear --source` remains the way to free one source's space *without* removing it, which the panel does not offer and should not: it is a storage operation with a price worth stating, and stating prices is what `pgr_ctl` is for.

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
- A thumbnail for each file-backed source in the settings list, in place of the generic file icon.
- The grow / shrink / stretch / aspect-ratio family, which needs the service's `fit` parameter — already parked in `PLAN.md`'s Phase 3.
- **Deleting the file itself gets its own plan.** Not an app feature: it crosses the app, the service, the pool, the deck's history, the cache, and the source, and it is the only irreversible thing the product would do. Everything `PLAN.md` says about deletion today is *reactive* — noticing a photograph somebody else removed and ceasing to show it. Removing one on purpose runs the other way and nothing covers it.

Two facts that already exist and would otherwise be rediscovered. **Saving** wants a filename and the response carries none — that is `X-PGR-Name`, item 8 on the known-shortcomings list, unbuilt; printing and the clipboard need only the bytes. And *Never showing a photo the user deleted* is where the delete-from-source design would have to start.

## Documents this contradicts

Not edited here; recorded so the contradictions are deliberate.

- **`Documentation/photogoroundd.md`** — updated. SERVICE still opens on the one request that matters and now carries a *Sources* subsection for the five that manage the library, and DESCRIPTION acknowledges that a client commands the source list over HTTP while configuring never requires the agent. The PREFERENCES table will gain `advanceIntervalSeconds` when that key exists; a man page describing something unbuilt is worse than one that is behind.
- **`Documentation/pgr_ctl.md`** — unaffected. `pgr_ctl` keeps preferences and the database and gains no web verbs, so every word of it stays true.
- **`PLAN.md`** — already reconciled: *The Mac app as instrument panel* now records the reversal, and *The database is private to the service* carries the rest.

# References

- `PLAN.md` — the system's plan. *The service is the interface*, *Sources live in preferences, not in the database*, *The doorbell rings back at you*, *TCC: unsandboxed does not mean unrestricted*, *Preferences*, *Clearing the cache on purpose*, *Showing unavailability*, and *The sandbox contingency*.
- `Documentation/pgr_ctl.md` — `sources add`, `remove`, `enable`, `disable`, whose behaviour the panel matches.
- `Documentation/photogoroundd.md` — the four configuration channels, *configured, not commanded*, and `--port`'s account of publishing a value that outlives its writer.
