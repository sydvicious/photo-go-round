#!/bin/bash
#
# Builds a configuration and installs what it makes: the agent, the screensaver,
# the wallpaper extension. The counterpart of `uninstall.sh`.
#
# **Every install says which build.** Syd, 2026-09-24: "I want all installers
# and uninstallers that I run to take a --variant argument, and accept --all for
# all three variants." `Scripts/variants.sh`.
#
# **It does what an Install scheme's ⌘R does**, from a terminal: build the
# product, then hand its path to `pgr_install`. Syd, 2026-09-19: "the targets
# and the command line builds should share their guts, and behave the same,
# based on input parameters." It replaces `claude-agent.sh install`, which knew
# one configuration and one product.
#
# **It changes the running system** — a job bootstrapped under launchd, a
# bundle in Screen Savers, a registration with `pkd` — so, like the Install
# schemes, it is Syd's to run.

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/variants.sh"

usage() {
    cat <<'HELPTEXT'
Builds a Photos-Go-Round configuration and installs what it makes.

USAGE
  ./Scripts/install.sh (--variant <name> ... | --all) [--agent] [--saver] [--wallpaper] [--dry-run]

  --variant <name>  release, debug or claude. May be given more than once.
  --all             All three.
  --agent           The agent, as a LaunchAgent, started.
  --saver           The screensaver, into ~/Library/Screen Savers.
  --wallpaper       The wallpaper extension, registered with macOS.
                    With none of the three, it installs all of them.
  --dry-run         Builds, and says what would be installed; installs nothing.
                    Building the wallpaper still registers its host with pkd,
                    because Xcode does that for every host-app build.

  Each configuration is built under $PGR_BUILD_ROOT, by default
  ~/Library/Developer/Xcode/DerivedData/Photos-Go-Round-scripts, and installed
  from there — so a release installed here runs from that build, not from
  /Applications.

  To start or stop an installed agent without reinstalling it:
    pgr_install start|stop --variant <name>
HELPTEXT
}

PARTS=()
DRY_RUN=()
while [[ $# -gt 0 ]]; do
    take_variant_option "$@"
    if (( CONSUMED > 0 )); then shift "$CONSUMED"; continue; fi
    case "$1" in
        --agent) PARTS+=(agent) ;;
        --saver) PARTS+=(saver) ;;
        --wallpaper) PARTS+=(wallpaper) ;;
        --dry-run) DRY_RUN=(--dry-run) ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done
require_variants
(( ${#PARTS[@]} == 0 )) && PARTS=(agent saver wallpaper)

PGR_INSTALL="$(pgr_install_path)"

for variant in "${VARIANTS[@]}"; do
    configuration="$(configuration_of "$variant")"
    derived="$BUILD_ROOT/$variant"
    products="$derived/Build/Products/$configuration"
    for part in "${PARTS[@]}"; do
        case "$part" in
            agent)
                build_scheme "Photos-Go-Round Server" "$configuration" "$derived"
                bundle="$products/Photos-Go-Round Server.app"
                ;;
            saver)
                build_scheme "Photos-Go-Round Saver" "$configuration" "$derived"
                bundle="$products/Photos-Go-Round Screensaver$(name_suffix_of "$variant").saver"
                ;;
            wallpaper)
                build_scheme "Photos-Go-Round Wallpaper Host" "$configuration" "$derived"
                bundle="$products/Photos-Go-Round Wallpaper Host.app/Contents/Extensions/Photos-Go-Round Wallpaper.appex"
                ;;
        esac
        "$PGR_INSTALL" "$part" --from "$bundle" "${DRY_RUN[@]+"${DRY_RUN[@]}"}"
    done
done
