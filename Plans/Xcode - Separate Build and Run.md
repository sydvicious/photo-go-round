# Summary

**All six phases built 2026-09-19.**

Building a product and installing it are separate acts: ⌘B builds, ⌘R installs.
`Claude` is a third build configuration beside Debug and Release so every build
carries its own identity — its own port, LaunchAgent label, screensaver name,
extension identifier and storage — the three aggregate targets whose script
phases installed are deleted, the install lives in a Swift module in the
package, and each installable product has a product scheme and an install
scheme.

The project has no `PBXShellScriptBuildPhase` left in it, and `Scripts/` went
from nine files to five.

# Rationale

Today the install *is* a build phase, so ⌘B on `Install Agent` boots out the
running agent, ⌘B on `Install Screen Saver` replaces the installed saver, and
⌘B on `Install Wallpaper Extension` re-registers the extension. There is no way
to ask "does this compile?" of an install target without changing the machine —
which is why `CLAUDE.md` has to forbid agents from building those schemes at
all, after one of them replaced Syd's installed saver on 2026-09-17. Separating
the two also moves the install logic somewhere the app can reach it, which is
the prerequisite `Installing by launching the app` and `A menu-bar app for
shipping` both need: a menu-bar app cannot shell out to `Scripts/install-*.sh`
from inside its bundle.

# Phases

Each phase leaves the tree working, and the products are taken smallest first.

- **Phase 1 — Three configurations, and storage to match. Built 2026-09-19.**
  `Claude` became a real Xcode build configuration beside Debug and Release, and
  every installable product and every datafile gained an identity per
  configuration. **It grew well past what this bullet first said**, because Syd
  added three requirements while it was being built: the three agents must run
  at once without clobbering each other, every datafile must live in the user's
  home directory so two people can share a Mac, and no generated artifact may
  sit in the repository.
  - `PGR_AGENT_CONDITION`, `WALLPAPER_ID_SUFFIX` and `WALLPAPER_NAME_SUFFIX`
    moved into the configuration, at project level, instead of being passed on
    the command line. Twelve configuration lists gained a `Claude` entry.
  - The saver gained a bundle name and identifier per configuration, and the
    agent a LaunchAgent label — carried in its own `Info.plist` as
    `PGRLaunchAgentLabel`, so an installer reads it from the bundle rather than
    from a constant. **The agent's bundle identifier deliberately did not
    change**: TCC grants hang off it, and Photos should be answered once.
  - `BuildVariant` in `PhotoGoRoundAgentAPI` — the project's one `#if` on build
    identity, which `ServiceAddress.port` now switches on.
  - **The container, cache and preference domain moved out of `<repo>/.build`
    and under `~/Library`**, named by deployment *and* variant:
    `com.sydpolk.photogoround[.debug|.claude][.dev]`. `buildDirectory()` and its
    `#filePath` fallback were deleted with it.
  - `pgr_ctl` gained two axes — `--production` (its new default) /
    `--development`, and `--release` / `--debug` / `--claude` — so it can
    address any configuration's library. The variant defaults to its own build's.
  - Four scripts followed: `install-saver.sh` and `install-agent.sh` derive the
    name and the label from the bundle they are handed; `uninstall.sh` and
    `scrub-dev.sh` know all three of everything; `make-agent-bundle.sh` lost
    `--install-to` (Syd: "Archive is the route") and the `make-*` scripts stopped
    defaulting their output into the repository.
  - `BuildVariantTests` reads `project.pbxproj` and fails when the build
    settings and `BuildVariant` disagree — the one thing that could drift
    silently.
  - `CLAUDE.md` rewritten: the per-product incantations collapsed to
    `-configuration Claude`, and *Never build an `Install …` scheme* now says it
    can no longer replace anything of Syd's but still changes his running system.
  - **Verified on Syd's Mac, 2026-09-19**, from a clean slate: agent on 9428
    under `…server.debug`, `Photo-Go-Round Screensaver (Debug).saver`,
    `…wallpaper.debug.extension`, storage in
    `~/Library/Containers/com.sydpolk.photogoround.debug.dev`, and an agent's
    Claude build registering beside Syd's Debug one without touching it.
- **Phase 2 — The saver, end to end. Built 2026-09-19.** The least dangerous
  install, and the one that has already gone wrong, proves the whole shape.
  Verified on Syd's Mac: ⌘B left `~/Library/Screen Savers` unchanged across a
  build, and ⌘R replaced the bundle.
  - `Sources/PhotoGoRoundInstall` with the saver's install in it, plan and apply
    separated.
  - `Scripts/ensure-photos-access.sh` is deleted, not translated.
  - `pgr_install` as a package executable target and an Xcode target, with
    `saver` and `--dry-run`.
  - A shared `Photo-Go-Round Saver` scheme; `Install Screen Saver` rewired to
    build the saver and run `pgr_install`.
  - `Scripts/install-saver.sh` deleted.
- **Phase 3 — The agent. Built 2026-09-19.** `launchctl bootout`, the
  ten-second wait, the plist, `bootstrap`, and the report on an agent the owner
  started. Verified: the plist was rewritten at 19:43:48, the job came back
  `state = running`, and the agent answered on 9428.
  - **The shared `Photo-Go-Round Server` scheme was done in Phase 1 instead,
    2026-09-19.** Xcode autocreated the scheme with `debugDocumentVersioning`
    on, so ⌘R launched the agent with `-NSDocumentRevisionsDebugMode YES` and
    its parser refused to start: "an unrecognised word is still an error rather
    than a silent start." There was no scheme file to correct — only
    `xcschememanagement.plist` — so the shared scheme was the only fix, and it
    keeps ⌘R for debugging the agent under LLDB as intended. The other six
    shared schemes still carry the same setting; harmless to the app and the
    extension, which eat the flag.
  - `Scripts/install-agent.sh` deleted.
- **Phase 4 — The wallpaper extension. Built 2026-09-19.** The hardest: reading
  registrations, judging which are dead, killing only this bundle's process, and
  waiting on `pkd`. Verified: the registration came back under a new UUID and
  `WallpaperAgent` restarted in the same second.
  - The registration judgement is the unit test this whole plan buys, and it is
    written: ten tests over `pluginkit` output captured from Syd's Mac.
  - `Scripts/install-wallpaper-extension.sh` deleted. **With it went the last
    aggregate target and the last `PBXShellScriptBuildPhase` in the project**,
    which is the plan's central claim made true: no install runs on ⌘B.
- **Phase 5 — One implementation of every build and every install. Built
  2026-09-19.** Syd: "there should not be multiple versions of the build
  scripts. the targets and the command line builds should share their guts, and
  behave the same, based on input parameters." `Scripts/` went from nine files
  to five, and no script knows an install identity by hand any more.
  - `pgr_install uninstall`, with `--agent`, `--saver`, `--wallpaper`. Three
    configurations means three of everything to find.
  - `Scripts/uninstall.sh` becomes a thin call into it.
  - **The three duplications go**: `make-saver-bundle.sh --install` keeping its
    own copy of the saver install; `make-agent-bundle.sh` writing its own
    LaunchAgent plist; and each product having two build mechanisms that produce
    differently named output in different places.
  - What is left takes parameters — configuration, output, whether to install —
    and behaves identically whichever door it was entered by.
  - **`xcodebuild` is the single route.** Syd, 2026-09-19: "what I really want
    is each target runnable via xcodebuild. If there are shell scripts that get
    called, ok." Every product builds by scheme and configuration; scripts are
    what a target calls, not a second way in.
  - **A shared test scheme and plan**, so `xcodebuild test` reaches all five
    package test targets. Syd: "add the test schemes somewhere." `Package
    Tests.xctestplan` at the top of the repository, and the scheme in
    `.swiftpm/xcode/xcshareddata/xcschemes/` where Xcode writes a package
    scheme. 1,001 tests.
  - **The third duplication was smaller than this bullet claimed.** The agent's
    sources do compile twice — as the package target `photogorounddTests` links
    and as the Xcode target that wraps it in a bundle — and that cannot change
    while the tests are SwiftPM test targets. What actually hurt was that only
    the Xcode route carried the build configuration, so `make-agent-bundle.sh`
    needed an `if` on `$CONFIGURATION` to spell a label by hand; deleting that
    script removed the harm. `Scripts/photogoroundd` now builds the Xcode
    target too, so nothing derives an identity from the SwiftPM side.
  - **`SMAppService` went with it.** `make-agent-bundle.sh` was the only thing
    that wrote the plist inside the bundle that `SMAppService.agent(plistName:)`
    needs, so `pgr_ctl register`, `unregister` and `service-status` could no
    longer work. Syd: "they go too." `ServiceCommand.swift`, their man-page
    section and their synopsis line are deleted; the test that pinned them now
    pins that they are refused.
- **Phase 6 — The documents, and the rules that change. Built 2026-09-19.**
  - `Documentation/pgr_install.md` written, and `Documentation/Installing.md`
    rewritten around it: all three steps are ⌘R.
  - **`CLAUDE.md` states `xcodebuild` as the only route.** `swift build` now
    appears in it once, in the sentence saying not to use it — it has only
    `debug` and `release`, so it cannot produce the `Claude` identity.
  - **No stale build instruction survives anywhere.** `README.md` no longer
    opens with `swift build`, and `pgr_ctl` is documented as a built product on
    a `PATH` with the two flags that reach a development agent.
  - `CLAUDE.md`'s *Never build an `Install …` scheme* stops being true in Phase
    1 and is replaced there, not here.
  - `Build Plan.md`'s *Installing is a build phase, not a script's job* is
    reversed by this plan — **Syd's to revise, not Claude's.**

# Design Decisions

- **Six schemes for three products — a product scheme and an install scheme
  each.** Syd, 2026-09-19: "six schemes". The product schemes build without
  installing anything; the install schemes are where ⌘R installs. What ⌘R does
  on each product scheme differs by product — below.
- **A product scheme builds on ⌘B and runs on ⌘R when possible; an install
  scheme builds on ⌘B and installs on ⌘R.** Syd, 2026-09-19: "the build targets
  build on command B and run on command R when possible", and "all of the
  install targets install on command R". "When possible" is the saver, which is
  a bundle and cannot be run.
- **⌘R installs and stops there.** Syd, 2026-09-19: "install only". No pane is
  opened and nothing is started — except the agent, which the install boots back
  in by definition.
- **The install is a Swift module in the package, not shell.** Syd, 2026-09-19:
  "swift module". The menu-bar app links the same module rather than
  reimplementing it.
- **`pgr_install` is its own binary, not subcommands on `pgr_ctl`.** Syd,
  2026-09-19: "I want a separate binary." `pgr_ctl` has its own job, and
  installing is not it.
- **`pgr_install` ships in nothing and is expected to be replaced.** Syd,
  2026-09-19: "the application which installs on first launch will eventually
  replace pgr_install", and "I don't care about pgr_install" being on his PATH.
  So it is scaffolding with a known end: the module it drives is the lasting
  half, and the binary exists to give ⌘R something runnable until the app can do
  the job. `TODO.md`, *Installing by launching the app*.
- **The install schemes run `pgr_install`; the three aggregate targets are
  deleted.** An aggregate target has no runnable product, so it cannot be the
  thing ⌘R runs. Their only content is the script phase this plan replaces.
- **Nothing in this plan asks for access to anything.** Syd, 2026-09-19: "all
  access is controlled either by the toy app I have now, the app we are going to
  develop, any potential app-store friendly apps, or any potential menubar
  apps." A grant is asked for by something with a face; an installer has none,
  and neither does the agent. `Scripts/ensure-photos-access.sh` is deleted
  rather than translated.
- **`launchctl`, `pluginkit`, `killall` and `pkill` stay, as `Process` calls.**
  None has an API. This moves where the logic lives, not which tools do the
  work — the honest claim is "one implementation", not "no more shell".
- **Each install splits into a plan and an apply.** The plan is a pure value
  describing what would happen; the apply performs it. `--dry-run` prints the
  plan, and the tests exercise the judgement without touching the machine.
- **Installs log to the unified log, category `install`.** Today they echo into
  a build log that evaporates, so an install cannot be reconstructed afterwards.
- **Three build configurations, all fully supported: Debug, Release, Claude.**
  Syd, 2026-09-19: "There are three configurations, debug, release, claude. all
  fully supported." `Claude` stops being Debug plus three command-line settings
  and becomes a configuration, so an agent's build carries its own identity for
  every product and cannot collide with Syd's by construction.
- **The build variant is compiled in, and the shell's `CONFIGURATION` check
  goes with the shell.** Syd, 2026-09-19: "the configuration has be compiled
  into everything so the binary can fork behavior if needed. With that in place,
  you don't need that stuff in the script." `ServiceAddress` already does this
  for the port; `pgr_install` forks the same three ways.

# Background

- Three aggregate targets — `Install Wallpaper Extension` (`…0110`), `Install
  Agent` (`…0120`), `Install Screen Saver` (`…0130`) — each hold one
  `Install for development` Run Script phase that calls a script in `Scripts/`,
  each with `alwaysOutOfDate = 1` and `ENABLE_USER_SCRIPT_SANDBOXING = NO`.
- Six schemes are shared today, but not the six this plan wants: `Install
  Agent`, `Install Screen Saver`, `Install Wallpaper Extension`, `Photo-Go-Round`,
  `Photo-Go-Round Wallpaper` and `Photo-Go-Round Wallpaper Host`.
  `Photo-Go-Round Server` and `Photo-Go-Round Saver` have no shared scheme at
  all — Xcode autocreates them per user.
- The four scripts total 384 lines: `install-agent.sh` 138,
  `install-wallpaper-extension.sh` 131, `install-saver.sh` 58,
  `ensure-photos-access.sh` 57.
- The package already declares `.iOS("27.0")`, and `app/ios` is empty.
- `pgr_ctl` is the model for a binary that is both a package executable target
  and an Xcode target, including the `-sectcreate` trick for an `Info.plist`.
- Syd, 2026-09-16, which is what this plan answers: "we should think about
  separating build and install for everything, so command-b builds and command-r
  runs. but that can go in TODO.md; we don't need to do that now."

# Detailed discussions

## Why an aggregate target cannot simply be run

An `Install …` scheme's Run action has no `BuildableProductRunnable`, because an
aggregate target produces no product. Xcode will not run one; it offers to let
you pick an executable instead. So "move the script from ⌘B to ⌘R" cannot be
done by leaving the targets alone and changing when the phase fires. The
aggregate targets have exactly one thing in them, and once it moves there is
nothing left, so they go.

What replaces them in the scheme is:

- **Build action** — two entries: the product (`Photo-Go-Round Saver`,
  `Photo-Go-Round Server`, `Photo-Go-Round Wallpaper Host`) and `pgr_install`.
  ⌘B on the install scheme then compiles exactly what ⌘R will need, and installs
  nothing. That is the whole point of the change, and it is what makes building
  an `Install …` scheme safe for the first time.
- **Launch action** — `pgr_install` as the `BuildableProductRunnable`, with
  arguments naming the subcommand and the bundle it built.

## What ⌘R does on each product scheme

The three products are three different Xcode product types, so "the product
scheme stays free to run and debug" is true of one of them, arguable for the
second and false for the third.

- **`Photo-Go-Round Server`** is `com.apple.product-type.application`, so ⌘R
  runs the agent under LLDB — the reason six schemes beat three, and it does not
  fight the installed job. Syd, 2026-09-19: "debug and claude agents have their
  own port numbers, so lauching them should not conflict with the installed
  agent." The port is compiled in, not decided by how the process was started —
  9427 release, 9428 Debug, 9429 Claude — so a Debug run and a Release install
  are two agents on two ports, each publishing its own.
  `Sources/PhotoGoRoundAgentAPI/Host/ServiceAddress.swift`.
  - The one collision left is running the same configuration you have installed:
    two Debug agents both want 9428, the second falls back to a kernel port and
    publishes it. That is a deliberate act, not a trap, and it is the case the
    variants exist to make rare. `install-agent.sh` already reports an agent it
    did not start rather than killing it, and `pgr_install` keeps that.
- **`Photo-Go-Round Saver`** is `com.apple.product-type.bundle`, and ⌘R does
  nothing. Syd, 2026-09-19: "i still prefer that the screen saver build just
  builds, and the install target installs. the run command does nothing." No
  host executable is wired — naming `legacyScreenSaver` or `ScreenSaverEngine`
  as the scheme's executable would make ⌘R launch something that is not this
  product, and debugging a saver that way has its own problems. The scheme earns
  its keep as a ⌘B that installs nothing, which is the whole change.
- **`Photo-Go-Round Wallpaper Host`** is an application and already has a shared
  scheme, so nothing changes. ⌘R launches an `LSUIElement` shell with no
  interface, which is as useful as it sounds; the scheme is a ⌘B.

## The three ways ⌘R could have done this, and why the binary wins

**A Run pre-action.** A `<PreActions>` block on the `LaunchAction` runs after the
build and before the launch, which is the right moment. It was rejected on
visibility: a pre-action's output does not go to the build log or to the console
pane, and there is nowhere to read what an install said. For a project where the
diagnosis is always the lines — and where `install-wallpaper-extension.sh` alone
prints eleven distinct explanations of what it decided and why — that is the
wrong trade. Whether a failing pre-action even stops the launch is version-
dependent and was never worth establishing.

**A `PathRunnable` pointing straight at a shell script.** The Run action can
launch an arbitrary path, so the existing scripts could have been the runnable
with no Swift at all. This is the cheapest thing that works, and it was rejected
because it does nothing for `Installing by launching the app`: a menu-bar app
still cannot use a shell script from inside its bundle, so the install would be
written twice.

**A `BuildableProductRunnable` on `pgr_install`.** Chosen. It gets four things
the build phase cannot have, all of which want measuring rather than assuming:

- **No user script sandbox.** `ENABLE_USER_SCRIPT_SANDBOXING = NO` exists on
  those targets because, under the sandbox, `pluginkit -a` registers but
  `pluginkit -m` returns nothing at all, so the script could not see its own
  work — measured 2026-09-15, thirty seconds of polling finding nothing while
  the record was plainly there from a terminal. A Run action launches an
  ordinary user process, so the sandbox should not apply. **Phase 4 measures
  this.** If it holds, the `pluginkit -m` wait stops being a workaround for the
  build environment and becomes an honest wait on `pkd`.
- **stdout in the console pane**, where it is read, scrollable and copyable,
  rather than folded into a build log entry.
- **LLDB.** An install that misbehaves can be stepped through. No shell script
  in this project has ever been debuggable.
- **A nonzero exit shown as a process that failed**, with its status, rather
  than as a build failure whose message is the script's last line.

## What each script becomes

### `install-saver.sh` — Phase 2

Four steps and no judgement: check the bundle exists, `rm -rf` the installed
copy by name, `cp -R` the new one, verify it arrived, `killall legacyScreenSaver`
and `killall ScreenSaverEngine`. In Swift this is `FileManager` for the first
four and `Process` for the two kills. Almost nothing
is lost in translation, which is exactly why it goes first: Phase 2 is really
about the module's shape, the `pgr_install` target, the scheme wiring and the
`--dry-run` convention, and the saver is the product that lets all four be
proved without much else going on.

The plan value here is small and obvious — the source path, the destination
path, whether a copy is being replaced or created, and which hosts are running
and would be stopped. That it is small is useful: it fixes what a plan value
looks like before Phase 4 needs a hard one.

### `ensure-photos-access.sh` — Phase 2

Reads `servicePort` from `com.sydpolk.photogoround.dev`, falling back to
`com.sydpolk.photogoround`; `GET`s `/v2/photos/authorization`; `POST`s the same
path only when the answer is neither a grant nor a refusal. It never fails an
install.

**It is deleted, not translated.** Syd, 2026-09-19: "the app is going to be the
installer; it will go there. Until that is true, put the access checks in the
install module" — then, on being shown that the app already does it: "change
that. For now, leave it in the app."

The rule behind it is general, and outlives this plan — Syd, 2026-09-19: "all
access is controlled either by the toy app I have now, the app we are going to
develop, any potential app-store friendly apps, or any potential menubar apps."
Every one of those has a window and a person looking at it. An installer, a
script and the agent do not, which is why the agent's own status read is a TCC
preflight that shows nothing and comes back `.notDetermined`.

The app has owned this since before the install targets existed:
`SourceService.postPhotosAuthorization` POSTs `/v2/photos/authorization`, and
`CollectionPickerView.unauthorized` is the permanent home for the refused state
that `app/mac/FEATURES.md` describes — "somewhere for authorization to live",
which a dialog that exists only while it is open cannot have. An install that
asks as well is a second implementation of the same prompt, and this plan's
whole argument is against those.

**The gap this leaves, stated rather than solved.** Syd, 2026-09-15, of the
saver's install: "it also needs to make sure the agent has photos access." That
was true when nothing else asked. It is now covered only for someone who opens
the app — so installing the saver with `pgr_install`, never opening the window,
and wondering why half the library is missing is reachable again. It is the
exact 2026-09-15 failure: the job ran, folder sources worked, the pool sat at
867 of 9183 with both Photos sources dark, and the only sign was a line in a
log. The mitigation is a line in the install's output saying the app is where
Photos is granted, which costs nothing and is in Phase 2.

Claude had proposed moving the call into `PhotoGoRoundAgentAPI` so a future iOS
client could link it. That was solving for a client that does not exist against
a prompt it would not use.

### What Phase 2 measured

Two things this plan had written down as assumptions. Both turned out to be
wrong in the direction that is easy to miss: not "it doesn't work", but "it
works badly enough to look like something else".

#### Xcode expands a launch argument, then re-splits it on whitespace

The `Install Screen Saver` scheme first passed
`$(BUILT_PRODUCTS_DIR)/Photo-Go-Round Screensaver$(SAVER_NAME_SUFFIX).saver` as
one `<CommandLineArgument>`. Xcode expanded both macros correctly — and then
tokenised the result, so `pgr_install` received three arguments where one was
meant, and reported `unknown option Screensaver` and exited 1.

**Environment variables are expanded and not re-split**, so the scheme now
passes only `saver` as an argument and hands `BUILT_PRODUCTS_DIR` and
`SAVER_NAME_SUFFIX` through `<EnvironmentVariables>`. `pgr_install` already read
those as its fallback, so nothing in the tool changed. Every later phase's
install scheme follows this shape; a product name with a space in it is the
normal case here, not an edge one.

**This is also the argument for a runnable binary over a Run pre-action, paid
back on the first try.** The failure announced itself in the console, named the
offending token, and exited non-zero. A pre-action would have printed the same
words somewhere nobody reads.

#### `isatty` is not enough to decide whether to colour

`Console` coloured whenever `isatty(STDOUT_FILENO)` was true. Xcode runs a
command-line tool on a pseudo-terminal, so that is true under Xcode — and
Xcode's console does not interpret the escapes, so the first error arrived as
`[31merror: [0munknown option Screensaver`.

`TERM` is the discriminator: Xcode sets none, a launchd job sets none, and a
terminal sets one. `Console.isTTY` now requires both, and both directions were
checked — `TERM` unset gives clean text, `TERM=xterm-256color` under a real pty
still colours. This was never specific to `pgr_install`; `pgr_ctl` and the agent
have been emitting the same noise into Xcode's console all along.

### `install-agent.sh` — Phase 3

The most procedural of the three, and the one with the hardest-won details:

- **The other-agent report.** `pgrep -f photogoroundd`, then `ps -o comm=` per
  pid, skipping the job's own binary. It reports and does not kill, because
  stopping something the owner started is the owner's call — Syd, 2026-09-15.
  In Swift this stays a `Process` call to `pgrep` in the first cut.
  `proc_listpids` plus `proc_pidpath` would remove the subprocess entirely and
  is worth doing, but not in the phase that is also moving everything else.
- **`bootout` returns before the job is gone.** Measured 2026-09-16: the
  bootstrap at 13:29:11.409 failed with "37: Operation already in progress"
  while launchd removed the old service at .417, and Xcode showed "Bootstrap
  failed: 5: Input/output error" with no agent running. The script polls
  `launchctl print` at 100 ms for ten seconds and fails loudly if the label is
  still loaded. This is the single most important behaviour in the file and the
  translation must not lose the bound or the loud failure.
- **The plist becomes a `Codable` value.** `PropertyListEncoder` writes it, and
  `plutil -lint` disappears with the heredoc that made it necessary. Every field
  stays: `RunAtLoad`, `KeepAlive`/`SuccessfulExit` false, and `ProcessType`
  `Adaptive` — which is *not* `Background`, for reasons measured 2026-09-17 and
  recorded in the script's comment: a Background job's disk I/O is throttled,
  and four restarts showed two minutes from process start to first line of code.
  That comment is the kind of thing that must survive the move; it is the reason
  the field is not the obvious value.
- **The port wait goes with the Photos check.** Twenty one-second polls of
  `defaults read … servicePort` existed only so the authorization call had
  something to talk to. Nothing else in the install needs the agent to have
  published yet, so both go.
- **The closing note that the plist points into the build directory.** Keep it.
  A clean build directory takes the agent with it, and that is worth a line
  every single time.

Phase 3 is also where `Photo-Go-Round Server` gets a shared scheme, which is
what preserves the ability to run the agent under the debugger — the reason Syd
chose six schemes over three.

### `install-wallpaper-extension.sh` — Phase 4

The only script with real judgement in it, and therefore the only one where
moving to Swift buys correctness rather than reach.

- **Parsing `pluginkit -m -D -v`.** One record per line: `identifier(version)`,
  a UUID, a date whose own fields vary, then the path. The script takes the path
  as everything from the first slash on, because counting fields got the date
  wrong and left `+0000 ` glued to the front of the path. That `sed` expression
  is untested, unreadable, and the single most likely thing in the project to
  break silently against a future `pluginkit`. In Swift it becomes a parser with
  a test holding real captured output — including the malformed case that
  produced the rule.
- **Judging a registration dead.** A registration is dead when its bundle is
  gone, *or* when the bundle still exists but now holds a different identifier —
  the second being what a rebuild at the same path under a new identity leaves
  behind, as Syd's Debug build did moving from `…wallpaper.extension` to
  `…wallpaper.debug.extension`. Anything else is somebody else's live build and
  is left alone, whichever identity. This rule exists because the earlier
  version hijacked: a build from one directory silently unregistered the copy
  another directory had installed, and the last build won. **This is the test
  this plan is worth writing.** Given a list of registrations and a filesystem
  answer per path, which does it remove? Today the answer can only be obtained
  by running an install on a real Mac and looking.
- **Killing only this bundle's process.** `pkill -f "$APPEX/Contents/MacOS/"`,
  not `killall` by name — every identity's process has the same name, so a name
  kill stops another build's wallpaper too.
- **Waiting on `pkd`.** Thirty one-second polls, printing progress every five,
  because `pluginkit -a` returns before the record exists. Under a build it took
  longer than ten seconds where a terminal verified first time — which may have
  been the sandbox rather than `pkd`, and is the measurement above.
- **Restarting `WallpaperAgent`.** Measured 2026-09-16: killing the extension
  leaves the desktop dark grey until a wallpaper is chosen again, because
  `WallpaperAgent` does not re-acquire from the new process by itself. It comes
  straight back under launchd and re-acquires every surface from the store.

### What Phases 3 and 4 measured

#### Xcode registers a host app's extension by itself, so ⌘B is not inert

Deleting the `Install Wallpaper Extension` aggregate target removed the only
thing *this project* did on build — and building the scheme still registers the
extension, because Xcode registers host-app builds on its own. **Measured
2026-09-19:** a `Claude` build of that scheme took the Mac's Photo-Go-Round
wallpaper registrations from one to two.

It cannot displace anybody: a build registers only its own configuration's
identifier, so a `Claude` build lands beside Syd's `…wallpaper.debug.extension`
and touches neither it nor Release. But "⌘B changes nothing" is true of the
saver and the agent and **not** of the wallpaper, and `CLAUDE.md` says so rather
than claiming a safety the machine does not provide. An agent that builds it
unregisters afterwards.

#### Per-variant ports made an old message a guess

`install-agent.sh` reported an agent it had not started with "It holds the port
this job wants." That was true when there was one fixed port. Since Phase 1 each
variant binds its own — 9427, 9428, 9429 — so another agent contends only if it
was built in the same configuration, **and its path does not say which**. Caught
by reading the first real dry run, which called Syd's running Debug agent a
conflict for a Claude install that would have bound a different port.

It now reports the process, says it is not this install's to stop, and qualifies
the contention. A diagnostic that overclaims is worse than one that says less:
`TODO.md`'s flaky-test lesson in another form.

#### A test that waits out a real timeout is a test nobody wants to run

`AgentInstall.waitForLaunchdToForget` used the ten-second bound that the 2026-09-16
measurement earned, and the test proving it gives up rather than hangs therefore
took 10.046 seconds — one test costing more than the other four targets
together. The bound is a parameter now, defaulted to `bootoutTimeout`, and the
test passes 120 ms: 0.125 seconds, with a separate assertion pinning that the
real default is still ten seconds. The measurement is preserved and the suite
does not pay for it.

### One implementation of every build and every install — Phase 5

**Syd, 2026-09-19:** "there should not be multiple versions of the build
scripts. the targets and the command line builds should share their guts, and
behave the same, based on input parameters." This is the phase that makes that
true, and it is wider than the install half the plan first described.

#### The three duplications, named — all three closed 2026-09-19

Written in the present tense, as they stood when the phase opened.

- **The saver's install exists twice.** `Scripts/install-saver.sh` copies the
  bundle, replaces the previous one and kills `legacyScreenSaver` and
  `ScreenSaverEngine`; `make-saver-bundle.sh --install` does the same again in
  its own words. The second one's header says why — "that script keeps its own
  copy of these steps because it is also the route for a machine with no Xcode
  project open" — and that justification dissolves once the install is a binary
  rather than a build phase, because a binary runs anywhere.
- **The agent's LaunchAgent plist exists twice.** `install-agent.sh` writes one
  into `~/Library/LaunchAgents`; `make-agent-bundle.sh` writes another into the
  bundle's `Contents/Library/LaunchAgents` for `SMAppService`. Both carry the
  label, `RunAtLoad`, `KeepAlive`/`SuccessfulExit` and `ProcessType` —
  **`Adaptive`, not `Background`**, for reasons measured 2026-09-17 that only
  one of the two copies explains. On 2026-09-19 the label had to be corrected in
  both, separately; that is the drift arriving, not a hypothetical.
- **Each product builds two ways.** The saver by `xcodebuild -scheme` from
  `make-saver-bundle.sh` and by its Xcode target; the agent by `swift build`
  from `make-agent-bundle.sh` and `Scripts/photogoroundd`, and by the
  `Photo-Go-Round Server` target. The two routes put differently named products
  in different directories, and only one of them gets the build configuration's
  identity — which is why `make-agent-bundle.sh` needs an `if` on
  `$CONFIGURATION` to spell a label the Xcode route gets from a build setting.

#### What replaces them

`PhotoGoRoundInstall` already holds one implementation of each install by the
end of Phase 4; Phase 5 finishes the job by leaving exactly one caller shape.
Every entry point — an Xcode scheme's ⌘R, a script, CI — resolves to the same
code with different arguments:

- **the configuration**, which decides every identity;
- **where the product is**, rather than each caller deriving it;
- **whether to install**, which is a parameter and not a different program.

`uninstall.sh` stays runnable from a terminal — Syd, 2026-09-15: "I am willing
to run that on the command line" — as a thin call into `pgr_install uninstall`.
It must keep the property that nothing in it needs the checkout that installed
it: everything is found by label, identifier and name.

#### `xcodebuild` is the single route

**Decided 2026-09-19.** Syd: "what I really want is each target runnable via
xcodebuild. If there are shell scripts that get called, ok." So a scheme and a
configuration are the whole interface to building anything, and a script is
something a target invokes rather than a parallel way in. Three things follow:

- **`make-saver-bundle.sh` and `make-agent-bundle.sh` stop being build entry
  points.** Either they become thin wrappers over `xcodebuild -scheme …
  -configuration …`, or they go and the scheme is the command. The assembly work
  they do — the bundle layout, the `Info.plist`, the `SMAppService` plist — moves
  into the targets, which is also what makes it stop being a second
  implementation.
- **`CLAUDE.md` loses its SwiftPM asymmetry.** It tells an agent to build with
  both `xcodebuild … -configuration Claude` and `swift build --scratch-path …
  -Xswiftc -DPGR_AGENT_CLAUDE`, because SwiftPM has no third configuration.
  Under one route the second line goes, and with it the note that the two halves
  are spelled differently.
- **Test schemes have to exist.** The package's four test targets —
  `PhotoGoRoundKitTests`, `PhotoGoRoundDisplayTests`, `photogorounddTests`,
  `pgr_ctlTests` — run through `swift test` today and are invisible to
  `xcodebuild test`, which reaches only `Photo-Go-RoundTests` through the app's
  scheme. Shared schemes carrying them as `Testables` are what make "each target
  runnable via xcodebuild" true of the tests as well. They could come forward
  from this phase if an earlier one wants them.

#### The package `photogoroundd` target is load-bearing, and gates the rest

The agent's sources are compiled twice, by two build systems: `Photo-Go-Round
Server` synchronizes `../Sources/photogoroundd` into an app bundle, and the
package's `photogoroundd` target builds the same directory as a bare executable.
The obvious cleanup — delete the package target, keep the Xcode one — **cannot
be done first**, for a reason that is easy to miss:

- **`photogorounddTests` depends on it.** `Package.swift` declares
  `dependencies: ["PhotoGoRoundAgentAPI", "photogoroundd"]`, and a SwiftPM test
  target can link a package target but not an Xcode target's sources. Removing
  the package target leaves the agent's 246 tests with nothing to link.
- So **the order is forced**: shared test schemes first, so `xcodebuild test`
  reaches what `swift test` reaches today; only then can the package target go.
  The test schemes are not a tidy-up at the end of this phase, they are its
  precondition.
- The same is true, less sharply, of `pgr_ctl` and `pgr_install`: each is a
  package target with a package test target, and each is also an Xcode target.

**`Scripts/photogoroundd`: answered 2026-09-19.** Syd, asked whether it stays as
the one deliberate exception to `xcodebuild`-only or builds the Xcode target's
binary instead: "build target's binary." So it does, and it keeps everything
else about itself — the `screen` framing, the `exec` so `^C` reaches the agent,
and exporting nothing so the `--prod` safety stays in the program rather than in
a wrapper.

**It gained something in the move.** Built by `swift build`, that agent got
`DEBUG` and nothing else — the same port and label as an installed Debug one,
indistinguishable from it. It now carries its configuration's identity like
everything else, and takes `--claude` alongside `--release`.

**What it still is, and is not:** the way to run the agent in front of you, in a
terminal you are watching. ⌘R on **Install Agent** is the other thing — a
launchd job whose output goes to the unified log.

#### `xcodebuild test` can run the package's test targets — measured 2026-09-19

The precondition holds. All five run under `xcodebuild`, 994 tests, `TEST
SUCCEEDED`, with no change to the package and no test target rewritten as an
Xcode one. **Four things have to be true together**, and each was got wrong on
the way:

- **The scheme is a *package* scheme**, written by Xcode to
  `.swiftpm/xcode/xcshareddata/xcschemes/`, not to the project's
  `xcshareddata`. Searching the `.xcodeproj` for it finds nothing, and
  `xcodebuild -list -project` reports it all the same, which is a confusing
  pair of facts to meet in that order.
- **A package target is referenced with `ReferencedContainer = "container:"`** —
  empty — and the target's *name* as `BlueprintIdentifier`. Eleven spellings
  were tried by hand first, all of them assuming the container was a path
  (`container:..`, `container:../Package.swift`, and so on). None resolved, and
  the scheme reported no buildables at all.
- **The scheme has to *build* the test targets**, not only list them in the
  plan. Listing alone fails with "There are no test bundles available to test",
  which is what defeated the one hand-written guess that had the container
  right.
- **It must be invoked without `-project`.** Through
  `-project app/Photo-Go-Round.xcodeproj` it still fails with the same message;
  addressed as a package, `xcodebuild test -scheme "Package Tests"` runs
  everything.

The test plan's own paths are package-root-relative to match:
`"containerPath" : "container:"` for a package target, and
`container:app/Photo-Go-Round.xcodeproj` for the Xcode one.

**How it was found, which is the part worth remembering.** Guessing the syntax
failed eleven times; the answer came from asking Syd to create one scheme
through Xcode's UI and then reading the file Xcode wrote. When a format is
undocumented and a tool will produce it, produce one and read it rather than
enumerating spellings.

**Two things left as they are.** The plan lives at `app/Package Tests.xctestplan`
while its paths are package-root-relative, so Xcode's navigator marks its
entries "(missing)" though `xcodebuild` resolves them; moving it to the
repository root would settle both. *It moved to the repository root later on
2026-09-19, and to `Tests/Package Tests.xctestplan` on 2026-09-21 — Syd: "I
think it should actually live in Tests/ for now." Xcode's saved window state
still named `app/`, which is what "Failed to open “Package Tests.xctestplan”"
was on 2026-09-21's first open.* And it no longer lists `Photo-Go-RoundTests`,
which is the app's bundle and wants a running agent — `TODO.md`, *No GUI
testing*.

## The build variant, compiled in

Each script phase begins by checking `CONFIGURATION` and exiting 0 for anything
but Debug, on the rule that release installs from the app wrapper. Claude read
that as a guard with nowhere to live once the install is a binary. Syd,
2026-09-19: "the configuration has be compiled into everything so the binary can
fork behavior if needed. With that in place, you don't need that stuff in the
script."

Which is right, and the mechanism is already in the tree. `ServiceAddress` picks
the agent's fixed port from `#if PGR_AGENT_CLAUDE / #elseif DEBUG / #else`, and
says exactly why: "the variant comes from the compiler, not from which library a
run opens: `Deployment` answers *whose pictures*, and that is a different
question from *whose build*." Three identities — a release, Syd's Debug, and a
build made by an agent — the same three the wallpaper extension has.

So the guard does not disappear; it moves from a shell environment variable that
only existed inside a build phase into a fact the binary carries wherever it is
run. That is strictly better: `pgr_install` invoked by hand from a terminal is
governed by it too, which `CONFIGURATION` never was.

**Built as `BuildVariant`, in `PhotoGoRoundAgentAPI/Host/BuildVariant.swift`:**
`ServiceAddress.variant` was a `String` used for one startup line; it is an enum
with cases `release`, `debug` and `claude`, and `ServiceAddress.port` and
`pgr_install` both switch on it. One `#if` in the project rather than a second
written alongside the first. It owns the port, the LaunchAgent label, the
screensaver bundle name and the wallpaper extension identifier, and
`BuildVariantTests` reads `project.pbxproj` to prove its suffixes still agree
with the build settings.

What each variant installs is the Phase 1 question. Debug installs where a
developer wants it. Release has nothing to install into yet, since the app
wrapper is later work that `Build Plan.md` still owes — until it exists, Release
refusing with a clear line is the honest behaviour, and a line beats a silent
`exit 0`.

### The Claude configuration, and a rule that stops being a rule

**Decided 2026-09-19.** Syd: "There are three configurations, debug, release,
claude. all fully supported." So `Claude` is not a lesser thing that gets
refused; it installs, fully, under an identity of its own, and an agent can
verify its own work end to end — which Phase 2 onward depends on.

Today that identity is partial. The wallpaper extension has all three —
`…wallpaper.extension`, `…wallpaper.debug.extension`,
`…wallpaper.claude.extension` — and the port has all three, 9427, 9428, 9429.
The saver bundle has one name in every configuration, and the agent has one
LaunchAgent label, `com.sydpolk.photogoround.server`. Those are the two that
Phase 1 adds, and they are exactly the two an agent's install has previously
trodden on: `Install Screen Saver` replaced Syd's saver on 2026-09-17, and
`install-agent.sh` boots out a job by label whoever built it.

The consequence is the good one. `CLAUDE.md`'s *Never build an `Install …`
scheme, and never run `Scripts/install-*.sh`* exists because that rule is all
that stood between an agent and Syd's running system, and it is obeyed or not
obeyed by whoever is reading it. Once every product carries its configuration's
identity, an agent's build cannot reach Syd's saver, his label or a registration
it did not create — whatever the agent intended, and whatever it was told. The
section in `CLAUDE.md` becomes a description of what the configuration
enforces, and its three-settings-per-product build commands become
`-configuration Claude`.

**The asymmetry to hold:** SwiftPM has only `debug` and `release`, so
`swift build --scratch-path … -Xswiftc -DPGR_AGENT_CLAUDE` stays as it is. An
Xcode configuration cannot reach a `swift build`, and inventing a parallel
mechanism for one flag would cost more than the inconsistency does.

## What testing this buys, and what it does not

The project does not GUI-test, and an install is by nature a change to the
machine — so most of what these scripts do cannot be tested and should not be
pretended otherwise. Splitting plan from apply draws the line in the one place
it can be drawn:

- **Testable.** The `pluginkit -m -D -v` parser. The dead-registration
  judgement, over a table of identifiers, paths and what each path's `Info.plist`
  says. The plist encoder's output, field by field. Which processes the agent
  install would report and which it would leave. The saver install's
  replace-versus-create decision.
- **Not testable, and stays a hand check on Syd's Mac.** That `launchctl
  bootstrap` actually starts the job; that `pkd` actually writes the record;
  that `WallpaperAgent` re-acquires the desktop; that the TCC prompt appears.
  Each phase ends with a command Syd runs and a log to read.
- Test runs log under `com.sydpolk.photogoround.tests`, as everything else does.

## What this does not build

- **The menu-bar app links nothing yet.** This plan makes the module exist and
  gives it one caller. `Installing by launching the app` and `A menu-bar app for
  shipping` are separate plans and stay so.
- **The dev and shipping installs are not the same job**, and this plan does not
  pretend they will be. Bootstrapping a LaunchAgent plist that points into a
  build directory has no shipping counterpart, and `SMAppService.agent(plistName:)`
  from inside a bundle has no dev counterpart. What genuinely transfers is the
  saver copy with its `legacyScreenSaver` kill, the `pluginkit` registration with
  its `WallpaperAgent` restart, and the dead-registration judgement.
- **The app and `pgr_ctl` still have no install**, which `Build Plan.md` lists
  as the remaining two of five. Neither needs one: the app runs from Xcode, and
  `pgr_ctl` is a copy or a symlink into `~/bin` — Syd, 2026-09-19.
- **`build-all.sh` does not exist yet** and is `Build Plan.md`'s to deliver.
  `pgr_install` becomes one more thing it builds when it does.

## Risks

- **A half-migrated machine.** Between phases, one product installs from a
  binary and two from scripts. Each phase deletes its script in the same commit
  that wires its scheme, so there is never a moment where both exist and
  disagree — but there *is* a moment where `uninstall.sh` knows about all three
  and only some of them came from the new code. Since it finds everything by
  label, identifier and name, that is survivable.
- **Scheme files are hand-edited XML.** The six `.xcscheme` files and
  `project.pbxproj` are edited as text with deterministic identifiers
  (`AA0000000000000000000110` and friends). Deleting three aggregate targets
  means removing their target entries, their build-configuration lists, their
  script phases, their dependencies and their `Products` group references —
  five places each, and a miss leaves a project Xcode will not open.
- **Argument macro expansion — measured 2026-09-19, and the answer was the
  awkward middle one.** See *What Phase 2 measured* above. A path passed as a
  launch argument is expanded and then re-split on whitespace, so it half-works;
  every install scheme passes paths through environment variables instead.
- **`CLAUDE.md` is rewritten in Phase 1, not left to rot.** Its *Never build an
  `Install …` scheme* and its per-product build incantations both stop being
  true there — the first because ⌘B no longer installs, the second because
  `-configuration Claude` replaces three settings passed by hand. It is the file
  that protects Syd's installed saver from agents, so it is revised in the same
  step that makes it false, and the revision describes what the configuration
  enforces rather than what an agent must remember.

# References

- `Plans/Build Plan.md` — *The install phases*, *Design Decisions*, and *What
  "install" means, per product*. Its decision *Installing is a build phase, not
  a script's job* is what this plan reverses.
- `Plans/Wallpaper Plan.md` — *Debug builds under their own identity*, which is
  why the extension install reads the identifier from the bundle it is given.
- `TODO.md` — *Build and install as separate steps, so ⌘B builds and ⌘R runs*
  (the item this plan closes), *Installing by launching the app*, and *A
  menu-bar app for shipping*.
- `CLAUDE.md` — *Never build an `Install …` scheme, and never run
  `Scripts/install-*.sh`*, and the 2026-09-17 incident that produced it.
- `Documentation/Installing.md`, `Documentation/pgr_ctl.md`.
- `Scripts/install-agent.sh`, `install-saver.sh`,
  `install-wallpaper-extension.sh`, `ensure-photos-access.sh`, `uninstall.sh`.
- `app/Photo-Go-Round.xcodeproj/project.pbxproj`, aggregate targets
  `AA0000000000000000000110`, `…0120`, `…0130`.
