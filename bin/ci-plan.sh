#!/bin/bash
# ci-plan.sh <workflow> <base> — does this PR's change reach <workflow>'s checks?
#   (issue #4794)
#
# The PR checks that drive the stack end to end (task-acceptance, client-e2e,
# fleet-hub-mcp) used to run on any change under bin/ — their `paths:` could not
# say more, and nearly every PR touches bin/. The ONE selector says more:
# `run-selftests.sh --changed <base> --list-only --among <entry files>` — the
# rules the selftest gate itself trusts (a changed entry file, an entry file
# naming a changed file's basename, naming a touched bin/*lib.sh function; a
# change to the selector ⇒ everything). Plus each workflow's own globs: a path it
# builds or serves wholesale (tokenledger/**), its own workflow file.
# Prints `run=true|false` and one line of why (to $GITHUB_OUTPUT / the step
# summary when set). Anything it cannot answer — an unknown base, a selector
# error — is `run=true`: unsure ⇒ run. The skipped job reads green; the nightly
# (or a dispatch) runs each of these whole.
set -uo pipefail

wf=${1:-} base=${2:-}
[ -n "$wf" ] && [ -n "$base" ] || { echo "usage: ci-plan.sh <workflow> <base>" >&2; exit 2; }
bin=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$bin/.." && pwd)

# workflow → entry files (from bin/; ../x outside it) | globs that run it whole
case "$wf" in
  task-acceptance)
    among='nogh-task-acceptance.py nogh-live-selftest.sh nogh_live_kernel_test.py nogh_live_http_test.py fleet-client-pack.sh'
    globs='tokenledger/* extras/web-console/* .github/workflows/task-acceptance.yml' ;;
  client-e2e)
    # the installer fetches every file the client manifest lists
    among='client-e2e.sh newcomer-e2e.sh nogh-e2e-selftest.sh fleet-client-pack.sh ../tokenledger/internal/api/fleetclient/manifest'
    globs='tokenledger/* .github/workflows/client-e2e.yml' ;;
  fleet-hub-mcp)
    # run-selftests.sh fleet-hub 'fleet-hub-[0-9]*', with the MCP SDK installed
    among=$(cd "$bin" && printf '%s ' fleet-hub-selftest.sh fleet-hub-[0-9]*-selftest.sh)
    globs='requirements-mcp.txt .github/workflows/fleet-hub.yml' ;;
  *) echo "ci-plan: no entry for workflow '$wf'" >&2; exit 2 ;;
esac

decide() {
  printf 'run=%s\n' "$1"
  printf '%s: %s — %s\n' "$wf" "$([ "$1" = true ] && echo runs || echo skipped)" "$2"
  [ -z "${GITHUB_OUTPUT:-}" ] || printf 'run=%s\n' "$1" >> "$GITHUB_OUTPUT"
  [ -z "${GITHUB_STEP_SUMMARY:-}" ] || printf '### %s: %s\n%s\n' "$wf" "$([ "$1" = true ] && echo 跑 || echo 跳过（与本次改动无关）)" "$2" >> "$GITHUB_STEP_SUMMARY"
  exit 0
}

mb=$(git -C "$root" merge-base "$base" HEAD 2>/dev/null) || decide true "base '$base' does not resolve — unsure, so it runs"
files=$(git -C "$root" diff --no-renames --name-only "$mb" HEAD 2>/dev/null) || decide true "git diff failed — unsure, so it runs"
for f in $files; do
  for g in $globs; do
    # shellcheck disable=SC2254  # intentional: $g is a glob ( * crosses / in case )
    case "$f" in $g) decide true "$f changed (${g})" ;; esac
  done
done
picks=$(cd "$bin" && FLEET_HEAVY=0 bash run-selftests.sh --changed "$mb" --list-only --among "$among" 2>/dev/null) \
  || decide true "the selector failed — unsure, so it runs"
[ -z "$picks" ] || decide true "related: $(printf '%s' "$picks" | tr '\n' ' ')"
decide false "no changed file is named by its entry files ($among)"
