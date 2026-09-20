#!/bin/bash
#
# Makes sure the running agent has Photos access, asking for it if nobody has
# decided yet. `Build Plan.md`, *Photos, and why the agent goes half-blind
# without a prompt*.
#
# Called by every install that puts a surface on the Mac — the agent's, the
# saver's — because a surface is only as good as the library behind it, and the
# agent cannot raise the prompt on its own: each refresh *reads* the
# authorization status, and a status read is a TCC preflight that never prompts.
# Measured 2026-09-15, where the job ran happily with 867 of 9183 photographs and
# said so only in its log.
#
# `POST /v2/photos/authorization` is the one call in the project that can raise
# the prompt, and it is a no-op for anyone who has already decided.
#
# **It never fails an install.** A surface installs fine against an agent that is
# not running, or one whose owner said no; both are reported and neither is worth
# refusing to copy a bundle over.

set -euo pipefail

# **Every configuration's domain, since 2026-09-19.** Each build configuration
# has its own storage identifier — `com.sydpolk.photogoround`, `….debug`,
# `….claude` — and each of those has a development and a production domain, so
# there are six places an agent may have published its port. Probing only the
# release pair, as this did until the identities were introduced, reports "no
# agent is publishing a port" against a perfectly healthy Debug agent.
# `BuildVariant.swift`; `Plans/Xcode - Separate Build and Run.md`.
#
# Development first within each identity, because that is the agent's own
# default and what an install has just started.
port=""
domain=""
for candidate in \
    com.sydpolk.photogoround.debug.dev com.sydpolk.photogoround.debug \
    com.sydpolk.photogoround.claude.dev com.sydpolk.photogoround.claude \
    com.sydpolk.photogoround.dev com.sydpolk.photogoround; do
    found="$(defaults read "$candidate" servicePort 2>/dev/null || true)"
    if [[ -n "$found" ]]; then
        port="$found"
        domain="$candidate"
        break
    fi
done

if [[ -z "$port" ]]; then
    echo "photos: no agent is publishing a port in any configuration, so Photos access was not checked"
    echo "  start one, or build the Install Agent target"
    exit 0
fi

echo "photos: found an agent on $port ($domain)"

status="$(curl -s --max-time 5 "http://localhost:$port/v2/photos/authorization" 2>/dev/null || true)"
case "$status" in
    *'"authorized"'* | *'"limited"'*)
        echo "photos: the agent on $port has access"
        ;;
    *'"denied"'* | *'"restricted"'*)
        echo "photos: the agent on $port is refused — System Settings › Privacy & Security › Photos"
        echo "  every Photos source stays unavailable until that changes"
        ;;
    "")
        echo "photos: the agent on $port did not answer, so Photos access was not checked"
        ;;
    *)
        echo "photos: asking the agent on $port for access; answer the prompt"
        answer="$(curl -s --max-time 60 -X POST "http://localhost:$port/v2/photos/authorization" 2>/dev/null || true)"
        echo "photos: ${answer:-no answer}"
        ;;
esac
