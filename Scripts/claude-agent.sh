#!/bin/bash
#
# Installs, uninstalls, starts and stops the agent Claude builds — the `Claude`
# configuration's, label `com.sydpolk.photogoround.server.claude`.
#
# **Syd runs this, when Claude asks.** Syd, 2026-09-21: "it's ok to leave a
# script that sets up the launchdaemon for the claude agent and ask me to
# install/uninstall/start/stop it." Launching an app now installs and restarts
# its own agent, and bootstrapping a launchd job on Syd's Mac is not Claude's
# to do — `CLAUDE.md`, *⌘R installs; ⌘B does not*. It is a per-user LaunchAgent
# like every other configuration's, in ~/Library/LaunchAgents.
#
# **It touches only the Claude agent.** Syd's Debug agent and any Release one
# have their own labels and ports and are never named here.
#
# **A wrapper, not an implementation**, like `uninstall.sh`: `pgr_install` does
# the work, and the plist it writes points into the Claude-built app, so the
# binary never leaves the app bundle.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$REPO/Photo-Go-Round.xcodeproj"
DERIVED_DATA="$HOME/.claude/build/photo-go-round/DerivedData"
PRODUCTS="$DERIVED_DATA/Build/Products/Claude"
SERVER="$PRODUCTS/Photo-Go-Round.app/Contents/Helpers/Photo-Go-Round Server.app"

usage() {
    cat <<'HELPTEXT'
Manages the Claude build's agent on this Mac.

USAGE
  ./Scripts/claude-agent.sh install     Build the Claude app, then install its
                                        agent as a LaunchAgent and start it.
  ./Scripts/claude-agent.sh uninstall   Stop it and remove its plist.
  ./Scripts/claude-agent.sh start       Start it, installed but stopped.
  ./Scripts/claude-agent.sh stop        Stop it and leave the plist installed.

Only com.sydpolk.photogoround.server.claude is touched.
HELPTEXT
}

# Silent when it works, and the whole log when it does not.
build() {
    local scheme="$1"
    if ! build_log="$(xcodebuild build \
        -project "$PROJECT" \
        -scheme "$scheme" \
        -destination "generic/platform=macOS" \
        -configuration Claude \
        -derivedDataPath "$DERIVED_DATA" 2>&1)"; then
        echo "$build_log" >&2
        echo "claude-agent: could not build $scheme; nothing was changed" >&2
        exit 1
    fi
}

case "${1:-}" in
    install)
        build "Photo-Go-Round"
        build pgr_install
        exec "$PRODUCTS/pgr_install" agent --from "$SERVER"
        ;;
    uninstall)
        build pgr_install
        exec "$PRODUCTS/pgr_install" uninstall --agent --variant claude
        ;;
    start|stop)
        build pgr_install
        exec "$PRODUCTS/pgr_install" "$1" --variant claude
        ;;
    -h|--help)
        usage
        ;;
    *)
        usage >&2
        exit 2
        ;;
esac
