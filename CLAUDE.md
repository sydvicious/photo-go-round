# Build hygiene

Rules for anyone — person or agent — building this project on a machine where Syd
also runs it. They exist because a build that installs itself takes over the
running system: the agent, the screensaver and the wallpaper extension are all
registered with macOS by name, and there is only one of each per user.

## Build where your output cannot be mistaken for the installed one

Agent builds go under `~/.claude/build/photo-go-round`, never into the default
DerivedData and never into the repository:

```bash
xcodebuild build -project app/Photo-Go-Round.xcodeproj -scheme "Photo-Go-Round Server" \
    -destination "platform=macOS" -configuration Debug \
    -derivedDataPath "$HOME/.claude/build/photo-go-round/DerivedData"
```

```bash
swift build --scratch-path "$HOME/.claude/build/photo-go-round/.build"
```

`swift test` takes the same `--scratch-path`. Syd's Xcode owns the default
DerivedData; two builders sharing it invalidate each other's intermediates, and
anything written inside the checkout is something he has to notice and exclude.

## Never build an `Install …` scheme, and never run `Scripts/install-*.sh`

`Install Agent`, `Install Screen Saver` and `Install Wallpaper Extension` are
aggregate targets whose scripts *install*: they boot out the running agent,
replace `~/Library/Screen Savers/Photo-Go-Round Screensaver.saver`, and register
the wallpaper extension with `pluginkit`. `-derivedDataPath` does not make them
safe — it only moves the build, and the script still installs from wherever that
is. Building `Install Screen Saver` into an agent's own directory replaced Syd's
installed saver on 2026-09-17.

To check something compiles, build the product scheme — `Photo-Go-Round`,
`Photo-Go-Round Server`, `Photo-Go-Round Wallpaper Host` — and hand Syd the
Install scheme to run from his own Xcode.

`Scripts/uninstall.sh` is his too: it unregisters and deletes.

## Wallpaper builds carry their own identity

Every build of the wallpaper extension registers itself with `pkd`, whoever
built it, so an agent's build must not share Syd's identifier:

```bash
xcodebuild build -project app/Photo-Go-Round.xcodeproj -scheme "Photo-Go-Round Wallpaper Host" \
    -destination "platform=macOS" -configuration Debug \
    -derivedDataPath "$HOME/.claude/build/photo-go-round/DerivedData" \
    -allowProvisioningUpdates WALLPAPER_ID_SUFFIX=.claude "WALLPAPER_NAME_SUFFIX= (Claude)"
```

Afterwards, unregister the copy and delete the host app, so nothing of yours is
left in the Wallpaper pane:

```bash
pluginkit -r "$HOME/.claude/build/photo-go-round/DerivedData/Build/Products/Debug/Photo-Go-Round Wallpaper Host.app/Contents/Extensions/Photo-Go-Round Wallpaper.appex"
```

Release is `com.sydpolk.photogoround.wallpaper.extension`, Syd's Debug builds are
`…wallpaper.debug.extension`, and an agent's are `…wallpaper.claude.extension`.
`Plans/Wallpaper Plan.md`, *Debug builds under their own identity*.

## Builds are warning-free, and checked on a clean build

Fix the cause rather than silencing it, and verify with a clean build:

```bash
xcodebuild clean build -project app/Photo-Go-Round.xcodeproj -scheme "Photo-Go-Round Server" \
    -destination "platform=macOS" -configuration Debug \
    -derivedDataPath "$HOME/.claude/build/photo-go-round/DerivedData" 2>&1 \
    | sed 's/\x1b\[[0-9;]*m//g' | grep -E "warning:|error:"
```

An incremental build can also lie after a change to a Swift concurrency setting:
the first one after `NonisolatedNonsendingByDefault` went on failed to link, and
a clean build succeeded. `Plans/Build Plan.md`.

## Where things are

- **Plans** are in `Plans/`; `TODO.md` and `README.md` stay at the top level.
- **Man pages and the install steps** are in `Documentation/`.
- **The agent's own logs**: `/tmp/com.sydpolk.photogoround.server.log`, and the
  unified log under subsystem `com.sydpolk.photogoround` — `/usr/bin/log show
  --info`, since `log` is a zsh builtin. Test runs log under
  `com.sydpolk.photogoround.tests` instead.
