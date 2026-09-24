#!/bin/bash
#
# Deletes what the retired development libraries left behind.
#
# **Every build has one set of assets since 2026-09-24.** Syd: "They should be
# completely separate builds with completely separate assets." Until then each
# build had two libraries — a real one and a `.dev` one beside it — and the
# screensaver and the wallpaper each had a `.dev` and a `.prod` domain. None of
# those names is used any more, and Syd chose to start fresh rather than move
# them: "right now, I don't care about existing data, especially dev/debug."
# This removes them — containers, caches and preferences alike.
#
# **Nothing in use is reachable from here.** Every name is spelled below and
# ends in `.dev` or `.prod`, and nothing is taken from an argument or from
# PGR_CONTAINER — otherwise the one command whose whole job is deleting things
# would be one flag away from deleting a library somebody is using. The current
# names — `com.sydpolk.photosgoround`, `….debug`, `….claude`, and their
# `.screensaver` and `.wallpaper` domains — are never touched.

set -euo pipefail

# Release, Syd's Debug and an agent's Claude build. `BuildVariant.swift`.
BUILDS=(
    "com.sydpolk.photosgoround"
    "com.sydpolk.photosgoround.debug"
    "com.sydpolk.photosgoround.claude"
)

# Each build's old development library: container, cache and preferences.
LIBRARIES=()
# Preference domains that were only ever preferences: the surfaces' old pair.
SURFACE_DOMAINS=()
for build in "${BUILDS[@]}"; do
    LIBRARIES+=("$build.dev")
    for surface in screensaver wallpaper; do
        SURFACE_DOMAINS+=("$build.$surface.dev" "$build.$surface.prod")
    done
done

ASSUME_YES=0
DRY_RUN=0

usage() {
    cat <<'USAGE'
usage: scrub-dev.sh [--yes] [--dry-run]

Deletes the leftovers of the retired development libraries: each build's
`.dev` container, cache and preferences, and the screensaver's and wallpaper's
old `.dev` and `.prod` domains. Nothing a current build uses is touched.

  --yes          Do not ask.
  --dry-run      Say what would go; delete nothing.
  -h, --help     This.
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --yes|-y)      ASSUME_YES=1 ;;
        --dry-run|-n)  DRY_RUN=1 ;;
        -h|--help)     usage; exit 0 ;;
        *)             echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done

container_of() { echo "$HOME/Library/Containers/$1"; }
cache_of()     { echo "$HOME/Library/Caches/$1"; }
plist_of()     { echo "$HOME/Library/Preferences/$1.plist"; }

# Everything of the retired names still on disk, one path per entry.
FOUND=()
for domain in "${LIBRARIES[@]}" "${SURFACE_DOMAINS[@]}"; do
    for path in "$(container_of "$domain")" "$(cache_of "$domain")" "$(plist_of "$domain")"; do
        [[ -e "$path" ]] && FOUND+=("$path")
    done
done

# **Any agent with a leftover container open**, matched on the container rather
# than on the process name — so an agent serving a current library is never a
# candidate.
running_agent() {
    local pids=""
    for domain in "${LIBRARIES[@]}"; do
        pids="$pids$(pgrep -f '/Photos-Go-Round Server( |$)' 2>/dev/null | while IFS= read -r pid; do
            if lsof -p "$pid" 2>/dev/null | grep -qF "/Library/Containers/$domain/"; then echo "$pid"; fi
        done)
"
    done
    echo "$pids" | grep -v '^$' | sort -u || true
}

if (( ${#FOUND[@]} == 0 )); then
    echo "no leftovers of the retired development libraries under $HOME/Library"
    exit 0
fi

echo "leftovers of the retired development libraries under $HOME/Library:"
for path in "${FOUND[@]}"; do
    echo "    $path ($(du -sh "$path" 2>/dev/null | cut -f1))"
done

PIDS="$(running_agent)"
if [[ -n "$PIDS" ]]; then
    echo "  agent running on one of them as ${PIDS//$'\n'/, }, and will be stopped"
fi

if (( DRY_RUN )); then
    echo "dry run — nothing deleted"
    exit 0
fi

if (( ! ASSUME_YES )); then
    read -r -p "delete them? [y/N] " reply
    [[ "$reply" == [yY] ]] || { echo "left alone"; exit 1; }
fi

# Stopped before anything is unlinked: a live agent holds the WAL open and
# republishes servicePort, so deleting underneath it leaves a half-deleted
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

for domain in "${LIBRARIES[@]}"; do
    rm -rf "$(container_of "$domain")" "$(cache_of "$domain")"
done
for domain in "${LIBRARIES[@]}" "${SURFACE_DOMAINS[@]}"; do
    defaults delete "$domain" 2>/dev/null || true
    rm -f "$(plist_of "$domain")"
done
# cfprefsd caches a domain it has read, and hands the stale copy back to the
# next process that asks. Deleting the file is not enough on its own.
killall cfprefsd 2>/dev/null || true

echo "deleted the leftovers"
