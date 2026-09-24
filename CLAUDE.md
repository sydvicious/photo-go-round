# Build hygiene

Rules for anyone — person or agent — building this project on a machine where Syd
also runs it. They exist because a build that installs itself takes over the
running system: the agent, the screensaver and the wallpaper extension are all
registered with macOS by name, and there is only one of each per user.

## Build the `Claude` configuration, into your own directory

Two rules, and together they are the whole of build hygiene. Everything an
agent builds uses `-configuration Claude`, and lands under
`~/.claude/build/photos-go-round`:

```bash
xcodebuild build -project Photos-Go-Round.xcodeproj -scheme "Photos-Go-Round Server" \
    -destination "platform=macOS" -configuration Claude \
    -derivedDataPath "$HOME/.claude/build/photos-go-round/DerivedData"
```

**`xcodebuild` is the only route**, since 2026-09-19. Syd: "what I really want
is each target runnable via xcodebuild. If there are shell scripts that get
called, ok." Not `swift build`: it has only `debug` and `release`, so it cannot
produce the `Claude` identity, and an agent built that way binds Syd's Debug
port and carries his label.

The tests run the same way, through the package's own scheme. It is a package
scheme, so it takes the package's workspace rather than `-project`; through the
project it finds no test bundles:

```bash
xcodebuild test -workspace .swiftpm/xcode/package.xcworkspace -scheme "Package Tests" -destination "platform=macOS,arch=arm64" -derivedDataPath "$HOME/.claude/build/photos-go-round/DerivedData"
```

That covers all five package test targets. `Package Tests.xctestplan` is
what lists them.

**Nothing generated goes in the repository.** Syd, 2026-09-19: "I really don't
want build artifacts in the repo directory", and "I would prefer ALL generated
artifacts to be in DerivedData and not .build directories". The scripts in
`Scripts/` default their output to
`~/Library/Developer/Xcode/DerivedData/Photos-Go-Round-scripts`; set
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
| Agent port | 20000 + hash of user name | 23000 + hash | 26000 + hash |
| LaunchAgent label | `…photosgoround.server` | `….server.debug` | `….server.claude` |
| Screensaver bundle | `Photos-Go-Round Screensaver.saver` | `… (Debug).saver` | `… (Claude).saver` |
| Wallpaper extension | `…wallpaper.extension` | `…wallpaper.debug.extension` | `…wallpaper.claude.extension` |
| Deployment | production (`--prod`) | development | development |

`-configuration Claude` sets all of it. The three settings that used to be
passed by hand — `PGR_AGENT_CONDITION`, `WALLPAPER_ID_SUFFIX`,
`WALLPAPER_NAME_SUFFIX` — are in the configuration now; passing them yourself is
how you break this.

The suffixes live twice: as build settings at project level in
`project.pbxproj`, and in `BuildVariant.swift`, because Swift cannot read an
`.xcconfig` at runtime. `BuildVariantTests` reads the project file and fails
when the two disagree. `Plans/Xcode - Separate Build and Run.md`.

## ⌘R installs; ⌘B does not. Pressing ⌘R is Syd's

**Since 2026-09-19 no install runs on ⌘B.** All three aggregate targets are
gone and the project has no shell script build phases at all. Each `Install …`
scheme builds its product and `pgr_install`, and its Run action does the
installing — `pgr_install saver`, `agent`, or `wallpaper`. Building one to check
that it compiles is now an ordinary thing to do.

**One exception, and it is Xcode's rather than ours: building `Install Wallpaper
Extension` or `Photos-Go-Round Wallpaper Host` registers the extension with
`pkd`**, because Xcode registers host-app builds by itself. Measured 2026-09-19:
a Claude build of that scheme took the registration count from one to two. It
cannot harm Syd — a `Claude` build registers `…wallpaper.claude.extension`
beside his `…wallpaper.debug.extension` and touches neither his nor Release —
but ⌘B there is not inert. Unregister afterwards:

```bash
pluginkit -r "$HOME/.claude/build/photos-go-round/DerivedData/Build/Products/Claude/Photos-Go-Round Wallpaper Host.app/Contents/Extensions/Photos-Go-Round Wallpaper.appex"
```

**⌘R on an `Install …` scheme is still Syd's to press**, because it changes the
running system: it bootstraps a job under launchd, restarts his
`WallpaperAgent`, and replaces an installed bundle. `Scripts/uninstall.sh` is
his for the same reason.

In the `Claude` configuration it can no longer replace anything of Syd's, which
is what it did on 2026-09-17. It still changes the running system: it
bootstraps a job under launchd, registers with `pkd`, restarts his
`WallpaperAgent`, and can raise a Photos prompt on his screen. So it is still
not yours to run.

To check something compiles, build the product scheme — `Photos-Go-Round`,
`Photos-Go-Round Server`, `Photos-Go-Round Saver`, `Photos-Go-Round Wallpaper
Host`. Hand Syd the Install scheme to run from his own Xcode.

`Scripts/install-*.sh` and `Scripts/uninstall.sh` are his for the same reason.

## Launching a built app installs. Never launch one

**Since 2026-09-21 every launch of `Photos-Go-Round.app`, in every
configuration, installs and restarts its own agent**, and may register the
wallpaper extension and restart `WallpaperAgent`. So launching an app you built
— `open`, a ⌘R of the `Photos-Go-Round` scheme, a test host — changes Syd's
running system. Build it; do not run it.

The `Claude` agent is Syd's to install, start, stop and remove, when you ask:

```bash
./Scripts/claude-agent.sh install
```

`Plans/Release App Installer.md`.

After building `Photos-Go-Round Wallpaper Host`, unregister the copy and delete
the host app, so nothing of yours is left in the Wallpaper pane:

```bash
pluginkit -r "$HOME/.claude/build/photos-go-round/DerivedData/Build/Products/Claude/Photos-Go-Round Wallpaper Host.app/Contents/Extensions/Photos-Go-Round Wallpaper.appex"
```

## Builds are warning-free, and checked on a clean build

Fix the cause rather than silencing it, and verify with a clean build:

```bash
xcodebuild clean build -project Photos-Go-Round.xcodeproj -scheme "Photos-Go-Round Server" \
    -destination "platform=macOS" -configuration Claude \
    -derivedDataPath "$HOME/.claude/build/photos-go-round/DerivedData" 2>&1 \
    | sed 's/\x1b\[[0-9;]*m//g' | grep -E "warning:|error:"
```

An incremental build can also lie after a change to a Swift concurrency setting:
the first one after `NonisolatedNonsendingByDefault` went on failed to link, and
a clean build succeeded. `Plans/Build Plan.md`.

## Where things are

- **Plans** are in `Plans/`; `TODO.md` and `README.md` stay at the top level.
- **Man pages and the install steps** are in `Documentation/`.
- **The agent's own logs**: the unified log under subsystem
  `com.sydpolk.photosgoround` — `/usr/bin/log show --info`, since `log` is a zsh
  builtin. No binary writes a log file. Test runs log under
  `com.sydpolk.photosgoround.tests` instead. Categories: `console` is everything
  the agent prints on standard output, `cache` the queue's own lines,
  `system-wallpaper` the extension, `saver` the screensaver, `install` what the
  app installs at launch and from its Help menu.
