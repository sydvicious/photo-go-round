#!/bin/bash
#
# Installs the agent as a per-user LaunchAgent and restarts it. `Build Plan.md`,
# *The install phases*.
#
# Called by the `Install Agent` target, and usable by hand with one argument: the
# path to the built `Photo-Go-Round Server.app`.
#
# **Full install.** Syd, 2026-09-15, choosing between building the bundle alone,
# writing the plist without starting it, and this: "full install". So every Debug
# build of the install target boots the job out, rewrites the plist, and boots it
# back in. That is what ends the "three ways to run the agent" confusion — after
# this, the job is the agent.
#
# **`~/Library/LaunchAgents`, per user.** Syd, 2026-09-10: "whatever launchctl
# needs should be put into ~/Library/LaunchAgents so multiple users don't clobber
# each other."
#
# **It does not kill an agent you started yourself.** A terminal agent holding the
# port is reported, loudly, and left alone: stopping something the owner started
# is the owner's call. The job will fail to bind until it goes.

set -euo pipefail

EXECUTABLE="photogoroundd"

APP="${1:-${BUILT_PRODUCTS_DIR:-}/Photo-Go-Round Server.app}"

if [[ ! -d "$APP" ]]; then
    echo "install-agent: no bundle at $APP" >&2
    exit 1
fi

BINARY="$APP/Contents/MacOS/$EXECUTABLE"
if [[ ! -x "$BINARY" ]]; then
    echo "install-agent: no executable at $BINARY" >&2
    exit 1
fi

# **The label is the bundle's own, never a constant.** launchd allows one job
# per label per user, so a single label means a Debug install boots out a
# Release one and neither can tell it happened. Each configuration writes
# `PGRLaunchAgentLabel` into its own Info.plist — `…server`, `…server.debug`,
# `…server.claude` — and this installs, restarts and reports only that one.
# The bundle identifier stays the same across all three on purpose: TCC grants
# hang off it, and Photos should be answered once rather than once per
# configuration.
LABEL="$(/usr/libexec/PlistBuddy -c "Print :PGRLaunchAgentLabel" "$APP/Contents/Info.plist" 2>/dev/null || true)"
if [[ -z "$LABEL" ]]; then
    echo "install-agent: $APP carries no PGRLaunchAgentLabel" >&2
    echo "  it was built before the label moved into the bundle; rebuild it" >&2
    exit 1
fi
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

# An agent nobody's launchd started — the `Scripts/photogoroundd` route, or an
# Xcode run of the package's executable. It holds the port, and the job cannot
# bind while it does.
others="$(pgrep -f "$EXECUTABLE" 2>/dev/null | grep -v "^$$\$" || true)"
while IFS= read -r pid; do
    [[ -n "$pid" ]] || continue
    path="$(ps -o comm= -p "$pid" 2>/dev/null || true)"
    case "$path" in
        "$BINARY") continue ;;  # the job's own process, restarted below
        "") continue ;;
    esac
    echo "install-agent: another agent is running, pid $pid"
    echo "  $path"
    echo "  It holds the port this job wants. Stop it with: kill $pid"
done <<< "$others"

# Out first, so the plist is never rewritten under a running job. Failure is
# ordinary: there may be no job yet.
launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true

# **`bootout` returns before the job is gone.** Measured 2026-09-16: bootstrap
# ran at 13:29:11.409 and failed with "37: Operation already in progress", and
# launchd logged "removing service" for the old job at 13:29:11.417. Xcode shows
# that as "Bootstrap failed: 5: Input/output error", and the agent is left not
# running at all. So wait for launchd to stop knowing the label — bounded past
# the job's five-second exit timeout, so a job that will not leave is reported
# rather than waited on for ever.
for _ in $(seq 1 100); do
    launchctl print "gui/$UID/$LABEL" >/dev/null 2>&1 || break
    sleep 0.1
done
if launchctl print "gui/$UID/$LABEL" >/dev/null 2>&1; then
    echo "install-agent: $LABEL is still loaded ten seconds after bootout" >&2
    exit 1
fi

# **`ProcessType` is `Adaptive`, not `Background`, since 2026-09-17.** macOS
# throttles a Background job's disk I/O, and this agent reads the disk to answer
# a person waiting on a picture. Measured over four restarts with `Background`:
# about two minutes between the process starting and its first line of code,
# then a cache walk of 16 to 39 seconds that takes 137 ms on a quiet machine,
# and one-row writes holding the database's write lock for hundreds of
# milliseconds — all of it disk, none of it the agent's own work. Adaptive lets
# the system lift the throttle when the process is doing user-visible work.
# `TODO.md`, *The agent takes about two minutes from launch to listening after a
# restart*.
cat > "$PLIST" <<PLIST_END
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$BINARY</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key>
        <false/>
    </dict>
    <key>ProcessType</key>
    <string>Adaptive</string>
</dict>
</plist>
PLIST_END

plutil -lint "$PLIST" >/dev/null

launchctl bootstrap "gui/$UID" "$PLIST"

if launchctl print "gui/$UID/$LABEL" >/dev/null 2>&1; then
    echo "install-agent: $LABEL bootstrapped"
    echo "  $BINARY"
    echo "  log: /usr/bin/log stream --info --predicate 'subsystem == \"com.sydpolk.photogoround\"'"
else
    echo "install-agent: $LABEL did not bootstrap" >&2
    exit 1
fi

# **Photos access is not asked for here.** A grant is asked for by something with
# a window — the app — and an installer has none; the agent cannot ask at all,
# because a status read is a TCC preflight that shows nothing. Syd, 2026-09-19:
# "all access is controlled either by the toy app I have now, the app we are
# going to develop, any potential app-store friendly apps, or any potential
# menubar apps." `Plans/Xcode - Separate Build and Run.md`.
echo "install-agent: Photos access is granted in the app, not here"

# **The plist points into DerivedData**, which is right for development and wrong
# for anything left running: a clean build directory takes the agent with it.
# Syd, 2026-09-19: "We use Archive to generate the app bundle, and that can be
# copied or moved to /Applications." Every scheme archives Release, so an
# archived agent carries the release identity — port 9427, label
# `com.sydpolk.photogoround.server` — and nothing else has to arrange that.
echo "install-agent: note — this job points into the build directory"
