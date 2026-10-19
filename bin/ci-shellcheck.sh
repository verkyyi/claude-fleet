#!/bin/sh
# ci-shellcheck.sh [--changed <base>] [--jobs <n>] [--list]
#   — run the EXACT shellcheck invocation CI runs, locally, so a worker gets an
# identical verdict before pushing (the ship step == CI). Reproducibility is the
# whole point: CI pins the version from .shellcheck-version and gates at
# --severity=warning; this mirrors both. .github/workflows/shellcheck.yml RUNS this
# script, so the two cannot drift.
#
#   - The file set: every *.sh under bin hooks shell extras (a *.zsh is not
#     linted — shellcheck has no zsh), each checked with --severity=warning.
#   - -x: each file follows what it sources itself. The old single full call
#     followed a sourced file only because it happened to be one of the inputs
#     (shellcheck reads its own inputs), so one file's verdict depended on which
#     others shared its invocation — alone, shell/fleet-intro.sh was red. With -x
#     a file's verdict is its own, however the tree is split.
#   - --changed <base> (the PR gate — issue #4663): only the *.sh `git diff
#     <base> HEAD` adds or modifies — by -x the same verdict as the full run for
#     every file it checks. A change to what decides the verdict for EVERY file —
#     .shellcheckrc, .shellcheck-version, this script, the workflow — or a base
#     that does not resolve checks the whole tree. The full tree runs nightly too
#     (a sourced lib's change shows in its sourcers there).
#   - --jobs <n>: n shellcheck processes at once (xargs -P, 16 files each); the
#     findings are the same, only the wall clock drops (8.5 min single-threaded).
#   - --list: print the files it would check and stop (no shellcheck needed).
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

base='' jobs=1 list=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --changed) [ "$#" -ge 2 ] || { echo "ci-shellcheck: --changed needs a base revision" >&2; exit 2; }
               base=$2; shift 2 ;;
    --jobs)    case "${2:-}" in ''|*[!0-9]*|0) echo "ci-shellcheck: --jobs needs a positive number" >&2; exit 2 ;; esac
               jobs=$2; shift 2 ;;
    --list)    list=1; shift ;;
    *) echo "ci-shellcheck: unknown argument $1" >&2; exit 2 ;;
  esac
done

# --- the file set: the whole tree, or what <base>..HEAD added or modified ---
files=$(find bin hooks shell extras -name '*.sh' | sort)
scope=all
if [ -n "$base" ]; then
  if ! git rev-parse -q --verify "$base^{commit}" >/dev/null 2>&1; then
    echo "ci-shellcheck: base $base does not resolve — checking every script" >&2
  else
    changed=$(git diff --name-only --diff-filter=d "$base" HEAD --) || changed=''
    if printf '%s\n' "$changed" | grep -Eqx '\.shellcheckrc|\.shellcheck-version|bin/ci-shellcheck\.sh|\.github/workflows/shellcheck\.yml'; then
      echo "ci-shellcheck: the lint's own config changed — checking every script" >&2
    else
      scope=changed
      files=$(printf '%s\n' "$changed" | grep -E '^(bin|hooks|shell|extras)/.*\.sh$' | while IFS= read -r f; do
        [ -f "$f" ] && printf '%s\n' "$f"; done | sort)
    fi
  fi
fi
if [ "$list" = 1 ]; then
  [ -z "$files" ] || printf '%s\n' "$files"
  exit 0
fi

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
if [ -z "$files" ]; then
  if [ "$scope" = changed ]; then
    echo "ci-shellcheck: this change touches no shell script under bin hooks shell extras — nothing to lint"
    exit 0
  fi
  echo "no shell scripts found — nothing to lint" >&2
  exit 1
fi
count=$(printf '%s\n' "$files" | wc -l | tr -d ' ')
echo "Checking $count script(s) ($scope, $jobs at once) with shellcheck ${local_ver:-?} -x --severity=warning:"
printf '%s\n' "$files" | sed 's/^/  /'
printf '%s\n' "$files" | tr '\n' '\0' | xargs -0 -P "$jobs" -n 16 shellcheck -x --severity=warning
