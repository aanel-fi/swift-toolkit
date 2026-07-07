#!/bin/bash
# Stop hook: keeps the working tree consistent with what CI expects.
# - Formats Swift sources when any .swift file changed.
# - Regenerates the EPUB navigator script bundles when their sources changed.
set -u
cd "${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel)}" || exit 0

# Prevent an infinite loop when the hook itself blocked the previous stop.
input=$(cat)
if printf '%s' "$input" | grep -q '"stop_hook_active": *true'; then
    exit 0
fi

changed=$(git status --porcelain)

if printf '%s\n' "$changed" | grep -qE '\.swift$'; then
    make format >/dev/null 2>&1
fi

if printf '%s\n' "$changed" | grep -q 'Sources/Navigator/EPUB/Scripts/src/'; then
    if ! output=$(make scripts 2>&1); then
        echo "The EPUB navigator scripts changed but 'make scripts' failed. Fix the errors below, the bundled scripts must be regenerated before finishing:" >&2
        echo "$output" | tail -50 >&2
        exit 2
    fi
fi

exit 0
