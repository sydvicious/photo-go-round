# pgr_install

## NAME

`pgr_install` — install a built Photos-Go-Round product on this Mac

## SYNOPSIS

```
pgr_install saver     [--from <path>] [--dry-run]
pgr_install agent     [--from <path>] [--dry-run]
pgr_install wallpaper [--from <path>] [--dry-run]
pgr_install start     [--variant <name>]
pgr_install stop      [--variant <name>]
pgr_install uninstall [--agent] [--saver] [--wallpaper] [--variant <name>] [--dry-run]
```

## DESCRIPTION

`pgr_install` is what an `Install …` scheme runs on ⌘R. Since 2026-09-19 those
schemes build their product and this binary and install nothing; ⌘R is what
installs.

**It exists because an aggregate target has no runnable product.** Xcode cannot
run one, so a scheme that installs on ⌘R needs something to launch. Each
`Install …` scheme builds its product alongside this and passes
`BUILT_PRODUCTS_DIR` through the environment.

**It is the development installer.** The work lives in `PhotosGoRoundInstall`,
which the app links too: an app installs the pieces it carries at launch and
from its Help menu, as symlinks and registrations pointing into itself.
`pgr_install` installs from a build directory, and copies the saver. It ships in
nothing and carries no compatibility promise.

**It asks for no access to anything.** A grant is asked for by something with a
window, and an installer has none. Photos is answered in the app.

**So an install alone leaves the agent half-blind**, and nothing here will tell
you: folder sources work, Photos sources stay unavailable, and the only sign is
a line in the log. Open the app once and it is fixed for good. This is known
and accepted — `Installing.md`, *The gap this leaves, which is accepted*.

**Every command takes the identity from what it is handed**, not from a
constant: the saver's name from the bundle, the agent's label from the bundle's
`PGRLaunchAgentLabel`, the extension's identifier from its `Info.plist`. So an
install replaces its own configuration's copy and no other, and all three can
sit on one Mac at once.

## OPTIONS

`--from` *path*
The built bundle. Defaults to the one in `$BUILT_PRODUCTS_DIR`: `Photos-Go-Round
Screensaver<suffix>.saver`, `Photos-Go-Round Server.app`, or `Photos-Go-Round
Wallpaper Host.app/Contents/Extensions/Photos-Go-Round Wallpaper.appex`.

`--dry-run`
Print what would happen and change nothing.

`--agent`, `--saver`, `--wallpaper`
For `uninstall`, which parts to remove. With none of them, all three.

`--variant` *name*
`release`, `debug` or `claude`. Whose agent `start` and `stop` act on — by
default the configuration this `pgr_install` was built as — and whose copies
`uninstall` removes, by default every configuration's.

## COMMANDS

`saver`
Copies the built `.saver` into `~/Library/Screen Savers`, replacing only the
bundle of its own name, then stops `legacyScreenSaver` and `ScreenSaverEngine`
— and only those of them that are running. **Both hosts cache a loaded bundle
for the life of the process**, so without the stop a rebuild runs the previous
build and looks exactly like a change that did nothing.

`agent`
Installs the agent as a per-user LaunchAgent and restarts it. It boots the job
out, **waits up to ten seconds for launchd to stop knowing the label**, writes
`~/Library/LaunchAgents/<label>.plist`, and bootstraps it. `bootout` returns
before the job is gone, and a bootstrap into that gap fails with "Operation
already in progress".

An agent somebody started by hand is reported with its pid and left alone.
Stopping something the owner started is the owner's call.

The plist points at the built bundle, which is right for development and wrong
for anything left running: a clean build directory takes the agent with it. It
says so when the path is one. Archive is the route for a release.

`wallpaper`
Registers the extension with `pluginkit`, from inside the host app that carries
it — **an appex registers only from inside a signed app bundle**. It first
removes registrations that are dead, stops only the extension process running
from this bundle, waits up to thirty seconds for `pkd` to record it, and
restarts `WallpaperAgent` so the desktop is re-acquired.

**A registration is dead when its bundle is gone, or when the bundle is there
and now holds a different identifier.** Anything else is another build's live
copy and is left alone, whichever configuration made it.

`start`
Starts an installed agent: loads its plist if launchd has not, then
`launchctl kickstart -k`, which restarts one already running. Fails when there
is no plist.

`stop`
Boots the agent out and leaves its plist, so `start` can bring it back. A kill
would not do: `KeepAlive` restarts a job whose process dies.

`uninstall`
Removes what the three installs put on this Mac, in every configuration unless
`--variant` names one: every
LaunchAgent and its plist, every registration of the extension, every installed
saver. It reports any agent still running outside launchd afterwards and leaves
it alone.

**It removes what was installed, not what was built.** Build directories, the
library, the cache and the preferences are untouched; `Scripts/scrub-dev.sh` is
what clears development storage.

## ENVIRONMENT

`BUILT_PRODUCTS_DIR`
Where to look for the product when `--from` is not given. An `Install …`
scheme passes it as an environment variable rather than in an argument, because
Xcode expands a launch argument and then re-splits it on whitespace — and every
product here has a space in its name.

`SAVER_NAME_SUFFIX`
The saver's per-configuration suffix, used with `BUILT_PRODUCTS_DIR` to find the
bundle. Empty for Release, `" (Debug)"`, `" (Claude)"`.

## FILES

`~/Library/Screen Savers/Photos-Go-Round Screensaver<suffix>.saver`
`~/Library/LaunchAgents/com.sydpolk.photosgoround.server<suffix>.plist`

Per user, both of them, so two people on one Mac never share an install.

## EXIT STATUS

`0` on success. `1` on a bundle that is not there, a bundle that is not the kind
asked for, an agent bundle carrying no `PGRLaunchAgentLabel`, a job still loaded
ten seconds after `bootout`, an extension that `pkd` did not record in
thirty, or a `start` with no plist installed.

## EXAMPLES

What ⌘R on **Install Screen Saver** does, by hand:

```bash
pgr_install saver --from "$HOME/Library/Developer/Xcode/DerivedData/…/Photos-Go-Round Screensaver (Debug).saver"
```

See what an uninstall would take, and take none of it:

```bash
./Scripts/uninstall.sh --dry-run
```

## SEE ALSO

`Photos-Go-Round Server.md`, `pgr_ctl.md`, `Installing.md`, `Plans/Xcode - Separate Build
and Run.md`.
