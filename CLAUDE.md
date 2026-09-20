# Build hygiene

Rules for anyone — person or agent — building this project on a machine where Syd
also runs it. They exist because a build that installs itself takes over the
running system: the agent, the screensaver and the wallpaper extension are all
registered with macOS by name, and there is only one of each per user.

## Build the `Claude` configuration, into your own directory

Two rules, and together they are the whole of build hygiene. Everything an
agent builds uses `-configuration Claude`, and lands under
`~/.claude/build/photo-go-round`:

```bash
xcodebuild build -project app/Photo-Go-Round.xcodeproj -scheme "Photo-Go-Round Server" \
    -destination "platform=macOS" -configuration Claude \
    -derivedDataPath "$HOME/.claude/build/photo-go-round/DerivedData"
```

```bash
swift build --scratch-path "$HOME/.claude/build/photo-go-round/DerivedData" -Xswiftc -DPGR_AGENT_CLAUDE
```

`swift test` takes the same two. SwiftPM has only `debug` and `release`, so it
keeps the flag; Xcode has the configuration and needs nothing else.

**Nothing generated goes in the repository.** Syd, 2026-09-19: "I really don't
want build artifacts in the repo directory", and "I would prefer ALL generated
artifacts to be in DerivedData and not .build directories". `Scripts/make-*.sh`
default their output to
`~/Library/Developer/Xcode/DerivedData/Photo-Go-Round-scripts`; set
`PGR_BUILD_ROOT` or pass `--output` to put yours under your own directory.

**`pgr_ctl` addresses one configuration's library at a time, and defaults to the
one it was built as.** A Claude-built `pgr_ctl` reads Claude storage; pass
`--release` or `--debug` only when you mean to look at Syd's.

Syd's Xcode owns the default DerivedData; two builders sharing it invalidate
each other's intermediates, and anything written inside the checkout is
something he has to notice and exclude.

## `Claude` is a build configuration, and it carries an identity

Since 2026-09-19 there are three configurations — `Debug`, `Release`, `Claude` —
and each names every installable product differently, so all three can be
installed on one Mac at once and none can be mistaken for another:

| | Release | Debug | Claude |
|---|---|---|---|
| Agent port | 9427 | 9428 | 9429 |
| LaunchAgent label | `…photogoround.server` | `….server.debug` | `….server.claude` |
| Screensaver bundle | `Photo-Go-Round Screensaver.saver` | `… (Debug).saver` | `… (Claude).saver` |
| Wallpaper extension | `…wallpaper.extension` | `…wallpaper.debug.extension` | `…wallpaper.claude.extension` |

`-configuration Claude` sets all of it. The three settings that used to be
passed by hand — `PGR_AGENT_CONDITION`, `WALLPAPER_ID_SUFFIX`,
`WALLPAPER_NAME_SUFFIX` — are in the configuration now; passing them yourself is
how you break this.

The suffixes live twice: as build settings at project level in
`project.pbxproj`, and in `BuildVariant.swift`, because Swift cannot read an
`.xcconfig` at runtime. `BuildVariantTests` reads the project file and fails
when the two disagree. `Plans/Xcode - Separate Build and Run.md`.

## `Install Wallpaper Extension` still installs on ⌘B; the other two do not

**`Install Screen Saver` and `Install Agent` are safe to build, since
2026-09-19.** Their aggregate targets are gone; each scheme builds its product
and `pgr_install` and installs nothing. ⌘R is what installs, by running
`pgr_install saver` or `pgr_install agent`, and pressing it is still Syd's.

**`Install Wallpaper Extension` still installs on ⌘B**: its aggregate target's
script phase runs on build. `-derivedDataPath` does not make it safe — it only
moves the build, and the script installs from wherever that is. It also restarts
`WallpaperAgent`, which is visible on Syd's desktop. Phase 4 of `Plans/Xcode -
Separate Build and Run.md` moves it to ⌘R as the other two have been; until
then this rule holds for it.

In the `Claude` configuration it can no longer replace anything of Syd's, which
is what it did on 2026-09-17. It still changes the running system: it
bootstraps a job under launchd, registers with `pkd`, restarts his
`WallpaperAgent`, and can raise a Photos prompt on his screen. So it is still
not yours to run.

To check something compiles, build the product scheme — `Photo-Go-Round`,
`Photo-Go-Round Server`, `Photo-Go-Round Saver`, `Photo-Go-Round Wallpaper
Host`. Hand Syd the Install scheme to run from his own Xcode.

`Scripts/install-*.sh` and `Scripts/uninstall.sh` are his for the same reason.

After building `Photo-Go-Round Wallpaper Host`, unregister the copy and delete
the host app, so nothing of yours is left in the Wallpaper pane:

```bash
pluginkit -r "$HOME/.claude/build/photo-go-round/DerivedData/Build/Products/Claude/Photo-Go-Round Wallpaper Host.app/Contents/Extensions/Photo-Go-Round Wallpaper.appex"
```

## Builds are warning-free, and checked on a clean build

Fix the cause rather than silencing it, and verify with a clean build:

```bash
xcodebuild clean build -project app/Photo-Go-Round.xcodeproj -scheme "Photo-Go-Round Server" \
    -destination "platform=macOS" -configuration Claude \
    -derivedDataPath "$HOME/.claude/build/photo-go-round/DerivedData" 2>&1 \
    | sed 's/\x1b\[[0-9;]*m//g' | grep -E "warning:|error:"
```

An incremental build can also lie after a change to a Swift concurrency setting:
the first one after `NonisolatedNonsendingByDefault` went on failed to link, and
a clean build succeeded. `Plans/Build Plan.md`.

## Where things are

- **Plans** are in `Plans/`; `TODO.md` and `README.md` stay at the top level.
- **Man pages and the install steps** are in `Documentation/`.
- **The agent's own logs**: the unified log under subsystem
  `com.sydpolk.photogoround` — `/usr/bin/log show --info`, since `log` is a zsh
  builtin. No binary writes a log file. Test runs log under
  `com.sydpolk.photogoround.tests` instead. Categories: `console` is everything
  the agent prints on standard output, `cache` the queue's own lines,
  `system-wallpaper` the extension, `saver` the screensaver.
