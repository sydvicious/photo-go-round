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

port=""
domain=""
for candidate in com.sydpolk.photogoround.dev com.sydpolk.photogoround; do
    found="$(defaults read "$candidate" servicePort 2>/dev/null || true)"
    if [[ -n "$found" ]]; then
        port="$found"
        domain="$candidate"
        break
    fi
done

if [[ -z "$port" ]]; then
    echo "photos: no agent is publishing a port, so Photos access was not checked"
    echo "  start one, or build the Install Agent target"
    exit 0
fi

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
