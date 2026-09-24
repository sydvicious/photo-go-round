# Sourced, not run. What `install.sh`, `uninstall.sh` and `scrub-data.sh` share:
# which build configurations a run acts on, how each is named, and the one
# `pgr_install` they all drive.
#
# **Every script that installs, uninstalls or deletes takes `--variant` or
# `--all`, and nothing else chooses.** Syd, 2026-09-24: "I want all installers
# and uninstallers that I run to take a --variant argument, and accept --all for
# all three variants." There is no default: a script that changes the system
# says which build's copy it means.
#
# The names below are `BuildVariant.swift`'s, spelled again because a shell
# script cannot read Swift. Change one, change both.

VARIANT_NAMES=(release debug claude)

# The variants a run acts on, filled by `take_variant_option`.
VARIANTS=()

# Consumes `--variant <name>` or `--all` from the caller's argument loop, and
# sets CONSUMED to how many arguments it used — 0 when the argument is not one
# of its. `--variant` may be given more than once.
CONSUMED=0
take_variant_option() {
    CONSUMED=0
    case "$1" in
        --all)
            VARIANTS=("${VARIANT_NAMES[@]}")
            CONSUMED=1
            ;;
        --variant)
            local name="${2:-}"
            case "$name" in
                release|debug|claude) ;;
                *) echo "--variant needs release, debug or claude" >&2; exit 2 ;;
            esac
            CONSUMED=2
            local present
            for present in "${VARIANTS[@]+"${VARIANTS[@]}"}"; do
                [[ "$present" == "$name" ]] && return 0
            done
            VARIANTS+=("$name")
            ;;
    esac
}

# Stops the run unless `--variant` or `--all` was given.
require_variants() {
    if (( ${#VARIANTS[@]} == 0 )); then
        echo "say which build: --variant release|debug|claude, or --all" >&2
        exit 2
    fi
}

# Whether every variant was chosen, which `pgr_install uninstall` spells as no
# `--variant` at all.
all_variants() {
    (( ${#VARIANTS[@]} == ${#VARIANT_NAMES[@]} ))
}

# The Xcode configuration a variant is built as.
configuration_of() {
    case "$1" in
        release) echo Release ;;
        debug) echo Debug ;;
        claude) echo Claude ;;
    esac
}

# The suffix on every identifier a variant owns: its storage, its agent's
# label, its screensaver's and its wallpaper extension's bundle identifiers.
identifier_suffix_of() {
    case "$1" in
        release) echo "" ;;
        debug) echo ".debug" ;;
        claude) echo ".claude" ;;
    esac
}

# The suffix on the screensaver bundle's name.
name_suffix_of() {
    case "$1" in
        release) echo "" ;;
        debug) echo " (Debug)" ;;
        claude) echo " (Claude)" ;;
    esac
}

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$REPO/Photos-Go-Round.xcodeproj"

# **Nothing generated goes in the repository.** Syd's Xcode owns the default
# DerivedData; these scripts build beside it, or under `PGR_BUILD_ROOT`.
BUILD_ROOT="${PGR_BUILD_ROOT:-$HOME/Library/Developer/Xcode/DerivedData/Photos-Go-Round-scripts}"

# Builds a scheme, silent when it works and the whole log when it does not.
# xcodebuild warns about matching several macOS destinations whatever is asked
# for, and that warning is noise in front of an install.
build_scheme() {
    local scheme="$1" configuration="$2" derived="$3"
    local log
    if ! log="$(xcodebuild build \
        -project "$PROJECT" \
        -scheme "$scheme" \
        -destination "generic/platform=macOS" \
        -configuration "$configuration" \
        -derivedDataPath "$derived" 2>&1)"; then
        echo "$log" >&2
        echo "$(basename "$0"): could not build $scheme ($configuration); nothing was changed" >&2
        exit 1
    fi
}

# Builds `pgr_install` and prints its path. One build for every variant: which
# build a command acts on is its `--variant` or its `--from`, never the
# configuration `pgr_install` itself was built as.
PGR_INSTALL_DERIVED="$BUILD_ROOT/tools"
pgr_install_path() {
    build_scheme pgr_install Debug "$PGR_INSTALL_DERIVED"
    echo "$PGR_INSTALL_DERIVED/Build/Products/Debug/pgr_install"
}
