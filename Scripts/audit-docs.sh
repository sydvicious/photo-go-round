#!/bin/bash
#
# Checks the documentation against the code, mechanically.
#
# `TODO.md`, *Audit all documentation against reality*: "A number repeated in
# prose drifts silently; the fix is not only to correct it but to leave
# something that fails when it drifts again." This is that something, for the
# half that can be checked without reading.
#
# **What it checks**, all of it a comparison between a document and a parser:
#
#   - every verb and flag `pgr_ctl` accepts is documented, and every flag its
#     man page documents is accepted;
#   - the same pair for the agent, `Photos-Go-Round Server`, and for `pgr_install`;
#   - every `Scripts/…` a document names exists, unless that line says it was
#     deleted or retired.
#
# **What it cannot check is the prose.** The worst finding of the 2026-09-19
# audit was a resize budget that still said one second after it became 1.5 —
# a number in a sentence, matching nothing a parser knows. Reading is still the
# job; this only stops the list-shaped drift.
#
# Exits 1 on any disagreement, naming each one.

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"
FAILURES=0

fail() {
    echo "  ✗ $1" >&2
    FAILURES=$((FAILURES + 1))
}

# Every string on a `case "…"` line — a parser may accept several spellings of
# one flag, as `case "--prod", "--production":` does.
accepted() {
    grep -oE '^[[:space:]]*case ("[^"]+"[, ]*)+' "$1" | grep -oE '"[^"]+"' | tr -d '"' | sort -u
}

# Every long flag a document presents in code voice. **Long only**: the single
# dash catches `photosgoround.sqlite-wal` and the like, and the short aliases
# have never been where drift hides.
documented_flags() {
    grep -oE '`--[a-z][a-z-]*' "$1" | tr -d '`' | sort -u
}

# A document writes a flag with its argument inside the same backticks —
# `--album <id>` — so the match is the flag followed by a boundary, not an
# exact string.
mentions_flag() {
    grep -qE -- "$2([\` <,.]|$)" "$1"
}

# --help is every tool's, and worth no ceremony in a man page.
UNIVERSAL="--help"

check_pair() {
    local name="$1" parser="$2" doc="$3"
    echo "$name"

    while read -r flag; do
        [[ "$flag" == --* ]] || continue
        [[ " $UNIVERSAL " == *" $flag "* ]] && continue
        mentions_flag "$doc" "$flag" \
            || fail "$name accepts $flag and $(basename "$doc") never mentions it"
    done < <(accepted "$parser")

    while read -r flag; do
        [[ -n "$flag" ]] || continue
        [[ " $UNIVERSAL " == *" $flag "* ]] && continue
        # A man page names the flags of the scripts it points at, too. It is
        # only drift if no tool of ours accepts it and no script does either.
        grep -qh "\"$flag\"" MacOS/Tools/pgr_ctl/Sources/PgrCtlOptions.swift \
            MacOS/Agent/Sources/Options.swift MacOS/Tools/pgr_install/Sources/main.swift 2>/dev/null && continue
        grep -qh -- "$flag" Scripts/*.sh 2>/dev/null && continue
        fail "$(basename "$doc") documents $flag and nothing accepts it"
    done < <(documented_flags "$doc")
}

check_pair "pgr_ctl" MacOS/Tools/pgr_ctl/Sources/PgrCtlOptions.swift Documentation/pgr_ctl.md
check_pair "Photos-Go-Round Server" MacOS/Agent/Sources/Options.swift "Documentation/Photos-Go-Round Server.md"
check_pair "pgr_install" MacOS/Tools/pgr_install/Sources/main.swift Documentation/pgr_install.md

echo "scripts named in documents"
while IFS=: read -r file line text; do
    for script in $(echo "$text" | grep -oE 'Scripts/[a-z-]+\.(sh|swift)' | sort -u); do
        [[ -e "$script" ]] && continue
        # A document may name a script precisely to say it is gone.
        echo "$text" | grep -qiE 'deleted|retired|went on|no longer' && continue
        fail "$file:$line names $script, which does not exist"
    done
done < <(grep -rn "Scripts/" README.md Documentation/*.md MacOS/Desktop/FEATURES.md 2>/dev/null)

echo
if (( FAILURES )); then
    echo "$FAILURES disagreement(s) between the documentation and the code" >&2
    exit 1
fi
echo "the documentation and the code agree, as far as this can tell"
