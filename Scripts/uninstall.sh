#!/bin/bash
#
# Takes Photos-Go-Round off this Mac. `Build Plan.md`, *The install phases*.
#
# Syd, 2026-09-15: "we need an uninstall script for all of these agents". Three
# installs put things in three places — a LaunchAgent, a plug-in registration and
# a bundle in Screen Savers — and the one you forget is the one that keeps
# running. Three build configurations mean three of each.
#
# **It is a wrapper, not an implementation.** Syd, 2026-09-19: "there should not
# be multiple versions of the build scripts. the targets and the command line
# builds should share their guts, and behave the same, based on input
# parameters." Everything this does lives in `PhotosGoRoundInstall` and is driven
# by `pgr_install uninstall`, which is the same code `Install …` schemes run and
# the same code the app will link when it becomes the installer.
#
# **It removes what was installed, not what was built.** Build directories, the
# library, the cache and the preferences are left alone: uninstalling is not the
# same as throwing away the photographs you chose. `Scripts/scrub-data.sh` is the
# one that deletes a build's data.
#
# **Nothing here needs the checkout that installed it.** Everything is found by
# label, identifier and name — so it removes a Release install as readily as a
# Debug one, whoever built them.
#
# **Every uninstall says which build.** Syd, 2026-09-24: "I want all installers
# and uninstallers that I run to take a --variant argument, and accept --all for
# all three variants." Until then it removed every configuration's copy
# whatever was asked. `Scripts/variants.sh`.

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/variants.sh"

usage() {
    cat <<'HELPTEXT'
Removes what Photos-Go-Round's installs put on this Mac.

USAGE
  ./Scripts/uninstall.sh (--variant <name> ... | --all) [--agent] [--wallpaper] [--saver] [--dry-run]

  --variant <name>  release, debug or claude: whose copies to remove. May be
                    given more than once.
  --all             All three configurations' copies.

WHAT EACH ONE REMOVES
  --agent       Boots out the LaunchAgent and deletes its plist from
                ~/Library/LaunchAgents. An agent somebody started by hand is
                reported and left alone. The built bundles stay where they are.
  --wallpaper   Unregisters the wallpaper extension and stops its processes. If
                it is the chosen wallpaper, macOS falls back to a default
                picture.
  --saver       Deletes the Photos-Go-Round Screensaver bundle from
                ~/Library/Screen Savers and stops the hosts holding it.
                With none of the three, it removes all of them.
  --dry-run     Says what would go and removes nothing.

WHAT IT NEVER TOUCHES
  The library, the cache, preferences, and anything under a build directory. See
  Scripts/scrub-data.sh for those.
HELPTEXT
}

PASSED=()
while [[ $# -gt 0 ]]; do
    take_variant_option "$@"
    if (( CONSUMED > 0 )); then shift "$CONSUMED"; continue; fi
    case "$1" in
        --agent|--wallpaper|--saver|--dry-run) PASSED+=("$1") ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done
require_variants

PGR_INSTALL="$(pgr_install_path)"

# `pgr_install uninstall` with no `--variant` is every configuration's, which is
# what `--all` means.
if all_variants; then
    exec "$PGR_INSTALL" uninstall "${PASSED[@]+"${PASSED[@]}"}"
fi
for variant in "${VARIANTS[@]}"; do
    "$PGR_INSTALL" uninstall --variant "$variant" "${PASSED[@]+"${PASSED[@]}"}"
done
