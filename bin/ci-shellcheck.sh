#!/bin/sh
# ci-shellcheck.sh — run the EXACT shellcheck invocation CI runs, locally, so a
# worker gets an identical verdict before pushing (the ship step == CI). Reproducibility
# is the whole point: CI pins the version from .shellcheck-version and gates at
# --severity=warning; this mirrors both.
#
#   - Same file set + same command as .github/workflows/shellcheck.yml:
#       find bin hooks shell extras -name '*.sh' -print0 | sort -z
#         | xargs -0 shellcheck --severity=warning
#   - Reads .shellcheck-version (single source of truth). If the local
#     `shellcheck` isn't that exact version, prints a one-line WARN (drift
#     notice) but still runs — a drifted binary can disagree with CI on the
#     SC2317/SC2329 heuristic, so the result is advisory, not authoritative.
#   - Exits non-zero on findings, exactly like CI.
#
# Runnable from anywhere: it resolves the repo root from its own location.
set -u

# --- locate repo root (script lives in <root>/bin) ---
unset CDPATH  # keep `cd` from echoing/jumping via a user's CDPATH
script_dir=$(cd -- "$(dirname -- "$0")" && pwd)
root=$(cd -- "$script_dir/.." && pwd)
cd "$root" || { echo "ci-shellcheck: cannot cd to repo root ($root)" >&2; exit 2; }

if ! command -v shellcheck >/dev/null 2>&1; then
  echo "ci-shellcheck: shellcheck not found on PATH — install it (brew install shellcheck)" >&2
  exit 2
fi

# --- version drift check (advisory) ---
pinned=$(tr -d '[:space:]' < .shellcheck-version 2>/dev/null || true)
local_ver=$(shellcheck --version 2>/dev/null | awk '/^version:/ {print $2}')
if [ -z "$pinned" ]; then
  echo "ci-shellcheck: WARN — .shellcheck-version missing/empty; can't check drift" >&2
elif [ "$local_ver" != "$pinned" ]; then
  echo "ci-shellcheck: WARN — local shellcheck $local_ver != pinned $pinned (CI uses $pinned); result may differ from CI" >&2
fi

# --- the exact CI invocation ---
count=$(find bin hooks shell extras -name '*.sh' | wc -l | tr -d ' ')
if [ "$count" -eq 0 ]; then
  echo "no shell scripts found — nothing to lint" >&2
  exit 1
fi
echo "Checking $count script(s) with shellcheck ${local_ver:-?} --severity=warning:"
find bin hooks shell extras -name '*.sh' | sort | sed 's/^/  /'
find bin hooks shell extras -name '*.sh' -print0 | sort -z | xargs -0 shellcheck --severity=warning
