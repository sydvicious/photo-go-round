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
# **Production is unreachable from here on purpose.** Every path is spelled here
# and ends in ".dev", and nothing is taken from an argument or from
# PGR_CONTAINER — otherwise the one command whose whole job is deleting things
# would be one flag away from deleting the real library.
#
# **Three development libraries, one per build configuration.** Since 2026-09-19
# the storage lives under ~/Library rather than in the checkout — Syd: "all of
# the datafiles have to run in the users home directory so that this will work
# for two different users on the same machine" — and each configuration has its
# own, so all three agents can run at once. This clears all three.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Release, Syd's Debug and an agent's Claude build. `BuildVariant.swift`.
DOMAINS=(
    "com.sydpolk.photosgoround.dev"
    "com.sydpolk.photosgoround.debug.dev"
    "com.sydpolk.photosgoround.claude.dev"
)

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

container_of() { echo "$HOME/Library/Containers/$1"; }
cache_of()     { echo "$HOME/Library/Caches/$1"; }

sources_held() {
    defaults read "$1" sources 2>/dev/null | grep -c "kind = " || true
}

# **Every development agent, whichever configuration built it**, matched on the
# development container it has open rather than on the process name — so an
# agent serving the production library is never a candidate.
running_agent() {
    local pids=""
    for domain in "${DOMAINS[@]}"; do
        pids="$pids$(pgrep -f '/Photos-Go-Round Server( |$)' 2>/dev/null | while IFS= read -r pid; do
            if lsof -p "$pid" 2>/dev/null | grep -qF "/Library/Containers/$domain/"; then echo "$pid"; fi
        done)
"
    done
    echo "$pids" | grep -v '^$' | sort -u || true
}

echo "development libraries under $HOME/Library"
for domain in "${DOMAINS[@]}"; do
    echo "  $domain"
    echo "    database     $(size_of "$(container_of "$domain")")"
    echo "    cache        $(size_of "$(cache_of "$domain")")"
    if (( PREFERENCES )); then
        echo "    preferences  $(sources_held "$domain") sources, which will be lost"
    else
        echo "    preferences  kept ($(sources_held "$domain") sources); --preferences takes them too"
    fi
done

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

for domain in "${DOMAINS[@]}"; do
    rm -rf "$(container_of "$domain")" "$(cache_of "$domain")"
done
echo "deleted the databases and the caches"

if (( PREFERENCES )); then
    for domain in "${DOMAINS[@]}"; do
        defaults delete "$domain" 2>/dev/null || true
        echo "deleted $domain"
    done
    # cfprefsd caches a domain it has read, and hands the stale copy back to the
    # next process that asks. Deleting the file is not enough on its own.
    killall cfprefsd 2>/dev/null || true
fi

echo "next launch starts cold"
