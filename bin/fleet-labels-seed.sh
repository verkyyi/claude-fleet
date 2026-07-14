#!/bin/bash
# fleet-labels-seed.sh — seed a repo with the fleet's canonical label taxonomy
# (issue #333). Nothing else seeds labels at install: `gh label` starts empty on
# a fresh repo, and the issue-filer channel (bin/fleet-issue-file.sh) rejects any
# label not in the fixed set — so without this step a fresh-repo fleet could file
# no labelled issue at all. Run once at install (docs/INSTALL.md calls it) and
# re-run any time to reconcile.
#
# IDEMPOTENT: each label is `gh label create --force`d, which CREATES the label
# if missing and UPDATES its color/description if it already exists — so a
# re-run converges the repo onto the canonical set with no duplicates and no
# error on labels that already exist. Extra labels the repo already carries
# (GitHub's defaults, one-offs) are left untouched; this only asserts the
# canonical set is present and correct, it does not prune.
#
# The taxonomy itself lives in ONE place, fleet_labels_canonical in fleet-lib.sh,
# shared with the filer's validator (fleet_labels_allowed) so the seeded set and
# the accepted set can never drift.
#
# Usage: fleet-labels-seed.sh [--repo OWNER/NAME]
#   --repo wins; else $FLEET_REPO; else this fleet's cached repo. gh must be
#   authed for the target repo (needs `issues:write`/label admin).
# Exit codes: 0 all labels seeded · 2 usage · 1 no-repo / gh missing / a create
# failed (so an install step records an honest FAIL rather than a false success).
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
[ -f "$BIN/../fleet.conf" ] && . "$BIN/../fleet.conf"
. "$BIN/fleet-lib.sh"

repo=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo)    shift; repo="${1:-}" ;;
    -h|--help) sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    --*)       printf 'fleet-labels-seed: unknown flag %s\n' "$1" >&2; exit 2 ;;
    *)         printf 'fleet-labels-seed: unexpected argument %s\n' "$1" >&2; exit 2 ;;
  esac
  shift
done

# Repo resolution mirrors bin/fleet-issue-file.sh: explicit --repo wins, else the
# global FLEET_REPO, else this fleet's cached repo.
repo="${repo:-${FLEET_REPO:-}}"
if [ -z "$repo" ]; then
  _r=$(fleet_repo_cached "$(fleet_current_session)" 2>/dev/null); [ -n "$_r" ] && repo="$_r"
fi
[ -z "$repo" ] && { printf 'fleet-labels-seed: no repo resolved (set --repo or FLEET_REPO)\n' >&2; exit 1; }
command -v gh >/dev/null 2>&1 || { printf 'fleet-labels-seed: gh not on PATH\n' >&2; exit 1; }

# Create-or-update each canonical label. `--force` is the idempotency rail. A
# single failure is recorded and reported, but we keep going so one bad label
# (e.g. a transient API error) doesn't skip the rest.
rc=0 made=0
while IFS='|' read -r name color desc; do
  [ -n "$name" ] || continue
  if gh label create "$name" --color "$color" --description "$desc" --force --repo "$repo" >/dev/null 2>&1; then
    made=$((made+1))
    printf 'fleet-labels-seed: %s\n' "$name" >&2
  else
    rc=1
    printf 'fleet-labels-seed: FAILED to seed %s\n' "$name" >&2
  fi
done <<EOF
$(fleet_labels_canonical)
EOF

if [ "$rc" -eq 0 ]; then
  printf 'fleet-labels-seed: %s canonical labels seeded in %s\n' "$made" "$repo" >&2
else
  printf 'fleet-labels-seed: seeded %s labels in %s with FAILURES (see above)\n' "$made" "$repo" >&2
fi
exit "$rc"
