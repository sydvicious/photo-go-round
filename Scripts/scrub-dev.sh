#!/bin/bash
#
# Deletes the development library and starts over.
#
# The database and the cache are disposable by design — rebuilding them costs
# one rescan — so this is the first thing to reach for when the dev setup is in
# a state nobody wants to reason about.
#
# **Preferences are the exception and are kept unless asked for.** The source
# list lives in UserDefaults and is the one thing here that cannot be
# reconstructed by rescanning; everything else is derivable. So --preferences is
# a separate flag rather than part of "scrub", and it says how many sources it
# is about to lose before it does it.
#
# **Production is unreachable from here on purpose.** Every path is derived from
# the repository directory, and nothing is taken from an argument or from
# PGR_CONTAINER — otherwise the one command whose whole job is deleting things
# would be one flag away from deleting the real library.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONTAINER="$REPO/.build/pgr-container"
CACHE="$REPO/.build/pgr-cache"
DOMAIN="com.sydpolk.photogoround.dev"

PREFERENCES=0
ASSUME_YES=0
DRY_RUN=0

usage() {
    cat <<'USAGE'
usage: scrub-dev.sh [--preferences] [--yes] [--dry-run]

Deletes the development database and cache, so the next launch starts cold.
The production library is never touched.

  --preferences  Also delete the dev preference domain. This loses the source
                 list, which is the one thing a rescan cannot rebuild.
  --yes          Do not ask.
  --dry-run      Say what would go; delete nothing.
  -h, --help     This.
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --preferences) PREFERENCES=1 ;;
        --yes|-y)      ASSUME_YES=1 ;;
        --dry-run|-n)  DRY_RUN=1 ;;
        -h|--help)     usage; exit 0 ;;
        *)             echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done

size_of() {
    [[ -e "$1" ]] && du -sh "$1" 2>/dev/null | cut -f1 || echo "absent"
}

# Matched on the repository's own build directory rather than on the process
# name, so an agent running from another checkout — or from the installed
# production bundle — is never a candidate.
running_agent() {
    pgrep -f "$REPO/.build/.*photogoroundd" || true
}

sources_held() {
    defaults read "$DOMAIN" sources 2>/dev/null | grep -c "kind = " || true
}

echo "development library under $REPO/.build"
echo "  database     $(size_of "$CONTAINER")"
echo "  cache        $(size_of "$CACHE")"
if (( PREFERENCES )); then
    echo "  preferences  $DOMAIN — $(sources_held) sources, which will be lost"
else
    echo "  preferences  kept ($(sources_held) sources); pass --preferences to take them too"
fi

PIDS="$(running_agent)"
if [[ -n "$PIDS" ]]; then
    echo "  agent        running as ${PIDS//$'\n'/, }, and will be stopped"
fi

if (( DRY_RUN )); then
    echo "dry run — nothing deleted"
    exit 0
fi

if (( ! ASSUME_YES )); then
    read -r -p "scrub it? [y/N] " reply
    [[ "$reply" == [yY] ]] || { echo "left alone"; exit 1; }
fi

# Stopped before anything is unlinked: a live agent holds the WAL open and
# republishes servicePort, so deleting underneath it leaves a half-scrubbed
# library and a running process disagreeing about what exists.
if [[ -n "$PIDS" ]]; then
    # shellcheck disable=SC2086
    kill $PIDS
    for _ in $(seq 20); do
        [[ -z "$(running_agent)" ]] && break
        sleep 0.25
    done
    if [[ -n "$(running_agent)" ]]; then
        echo "agent did not stop; not deleting anything under it" >&2
        exit 1
    fi
    echo "stopped the agent"
fi

rm -rf "$CONTAINER" "$CACHE"
echo "deleted the database and the cache"

if (( PREFERENCES )); then
    defaults delete "$DOMAIN" 2>/dev/null || true
    # cfprefsd caches a domain it has read, and hands the stale copy back to the
    # next process that asks. Deleting the file is not enough on its own.
    killall cfprefsd 2>/dev/null || true
    echo "deleted $DOMAIN"
fi

echo "next launch starts cold"
