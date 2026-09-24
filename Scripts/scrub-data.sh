#!/bin/bash
#
# Deletes a build's data: its library, its cache and its preferences, current
# and retired alike.
#
# **Renamed from `scrub-dev.sh` on 2026-09-24, and widened.** It deleted only
# what the retired development libraries left behind — each build's `.dev`
# library and the surfaces' `.dev` and `.prod` domains, gone since every build
# got one set of assets. Syd: "I want scrub-dev.sh to be renamed
# 'scrub-data.sh', and have it also take variants and --all", and "this includes
# older versions of data files and current ones." So a variant's data is now
# everything any version of that build has kept.
#
# **Names come from `--variant`, never from a path.** Every name below is
# spelled from `Scripts/variants.sh`; nothing is taken from an argument, from
# PGR_CONTAINER or from PGR_BUILD_ROOT — the one command whose whole job is
# deleting things is not one typo away from deleting something else.
#
# **The agent is stopped first** — unloaded, so `KeepAlive` does not bring it
# straight back — because a live agent holds the WAL open and republishes its
# port, and deleting underneath it leaves a half-deleted library and a running
# process disagreeing about what exists. It is left stopped: its plist stays
# installed, so it comes back at the next login, or with `pgr_install start`.

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/variants.sh"

usage() {
    cat <<'USAGE'
usage: scrub-data.sh (--variant <name> ... | --all) [--yes] [--dry-run]

Deletes a build's data: its library and cache, its preferences and the
screensaver's and wallpaper's, and the same from every retired name the build
has used (`.dev`, `.prod`). Stops that build's agent first. Installed bundles
and LaunchAgents are left alone; see uninstall.sh.

  --variant <name>  release, debug or claude. May be given more than once.
  --all             All three.
  --yes             Do not ask.
  --dry-run         Say what would go; delete nothing.
  -h, --help        This.

The screensaver's and the wallpaper's remembered pictures live in containers
macOS protects. They are tried, and reported if macOS refuses; a terminal with
Full Disk Access can delete them.
USAGE
}

ASSUME_YES=0
DRY_RUN=0
while [[ $# -gt 0 ]]; do
    take_variant_option "$@"
    if (( CONSUMED > 0 )); then shift "$CONSUMED"; continue; fi
    case "$1" in
        --yes|-y)      ASSUME_YES=1 ;;
        --dry-run|-n)  DRY_RUN=1 ;;
        -h|--help)     usage; exit 0 ;;
        *)             echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done
require_variants

container_of() { echo "$HOME/Library/Containers/$1"; }
cache_of()     { echo "$HOME/Library/Caches/$1"; }
plist_of()     { echo "$HOME/Library/Preferences/$1.plist"; }

# A library is a container, a cache and a preference domain of one name.
LIBRARIES=()
# Domains that were only ever preferences: the screensaver's and wallpaper's.
DOMAINS=()
# The remembered pictures, inside containers macOS protects.
PROTECTED=()
for variant in "${VARIANTS[@]}"; do
    suffix="$(identifier_suffix_of "$variant")"
    build="com.sydpolk.photosgoround$suffix"
    # Current, then the retired development library beside it.
    LIBRARIES+=("$build" "$build.dev")
    for surface in screensaver wallpaper; do
        DOMAINS+=("$build.$surface" "$build.$surface.dev" "$build.$surface.prod")
    done
    PROTECTED+=(
        "$HOME/Library/Containers/com.apple.ScreenSaver.Engine.legacyScreenSaver/Data/Library/Caches/com.sydpolk.photosgoround.saver$suffix"
        "$HOME/Library/Containers/com.sydpolk.photosgoround.wallpaper$suffix.extension/Data/Library/Application Support"
    )
done

# Everything of those names on disk, one path per entry.
FOUND=()
for domain in "${LIBRARIES[@]}"; do
    for path in "$(container_of "$domain")" "$(cache_of "$domain")" "$(plist_of "$domain")"; do
        [[ -e "$path" ]] && FOUND+=("$path")
    done
done
for domain in "${DOMAINS[@]}"; do
    path="$(plist_of "$domain")"
    [[ -e "$path" ]] && FOUND+=("$path")
done

# **An agent with one of these containers open that launchd does not own** — a
# `run-server.sh`, say. Matched on the container rather than the process name,
# so an agent serving another build's library is never a candidate.
hand_started_agents() {
    local pids="" domain
    for domain in "${LIBRARIES[@]}"; do
        pids="$pids$(pgrep -f '/Photos-Go-Round Server( |$)' 2>/dev/null | while IFS= read -r pid; do
            if lsof -p "$pid" 2>/dev/null | grep -qF "/Library/Containers/$domain/"; then echo "$pid"; fi
        done)
"
    done
    echo "$pids" | grep -v '^$' | sort -u || true
}

echo "data of the ${VARIANTS[*]} build(s) under $HOME/Library:"
if (( ${#FOUND[@]} == 0 )); then
    echo "    nothing in the library, cache or preferences"
fi
for path in "${FOUND[@]+"${FOUND[@]}"}"; do
    echo "    $path ($(du -sh "$path" 2>/dev/null | cut -f1))"
done
echo "  and the remembered pictures, if macOS allows:"
for path in "${PROTECTED[@]}"; do
    echo "    $path"
done

if (( DRY_RUN )); then
    echo "dry run — nothing stopped, nothing deleted"
    exit 0
fi

if (( ! ASSUME_YES )); then
    read -r -p "stop these builds' agents and delete their data? [y/N] " reply
    [[ "$reply" == [yY] ]] || { echo "left alone"; exit 1; }
fi

PGR_INSTALL="$(pgr_install_path)"
for variant in "${VARIANTS[@]}"; do
    "$PGR_INSTALL" stop --variant "$variant"
done

PIDS="$(hand_started_agents)"
if [[ -n "$PIDS" ]]; then
    # shellcheck disable=SC2086
    kill $PIDS
    for _ in $(seq 20); do
        [[ -z "$(hand_started_agents)" ]] && break
        sleep 0.25
    done
    if [[ -n "$(hand_started_agents)" ]]; then
        echo "an agent started by hand did not stop; not deleting anything under it" >&2
        exit 1
    fi
    echo "stopped the agent started by hand: ${PIDS//$'\n'/, }"
fi

for domain in "${LIBRARIES[@]}"; do
    rm -rf "$(container_of "$domain")" "$(cache_of "$domain")"
done
for domain in "${LIBRARIES[@]}" "${DOMAINS[@]}"; do
    defaults delete "$domain" 2>/dev/null || true
    rm -f "$(plist_of "$domain")"
done
# cfprefsd caches a domain it has read, and hands the stale copy back to the
# next process that asks. Deleting the file is not enough on its own.
killall cfprefsd 2>/dev/null || true

# **Tried, never forced.** Each of these is inside a sandbox container, and
# macOS refuses a terminal without Full Disk Access; that is reported, and the
# rest of the scrub stands.
for path in "${PROTECTED[@]}"; do
    if ! rm -rf "$path" 2>/dev/null; then
        echo "  macOS would not let this terminal delete $path"
    fi
done

echo "deleted the data; the agents are stopped until the next login or pgr_install start"
