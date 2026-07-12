#!/bin/bash
# dash-arm-merge.sh <window-target|issue> — ARM GitHub auto-merge on the row's
# open PR, straight from the dash in ONE keystroke (issue #277). The dash's ⌃l
# bind runs this inside a display-popup.
#
# THE FLEET NEVER MERGES — it arms auto-merge and cleans up afterward. /fleet-ship
# already arms auto-merge when it opens a PR; this key is the manual escape hatch
# for a PR that was shipped BEFORE arming existed, or whose auto-merge got
# disarmed. It does NOT merge and it does NOT force: it queues the PR with
# `gh pr merge --auto --squash`, and GitHub performs the merge only when the PR is
# green and branch protection is satisfied — that is the whole gate. The
# com.claude-fleet.cleanup daemon reaps the worktree/window/branch afterward.
#
#   arg = the selected row's field 1 (`sess:idx`, a tmux window target) — the same
#         {1} the ⌃x / ⌃e dash binds take. A bare issue number is also accepted so
#         it is scriptable/testable without a live pane.
#
# Operates on THIS fleet only (the dash's resolved fleet). Reads the caches the
# collector + pr-refresh already maintain to resolve the row → its open PR; the
# only gh call it makes is the one `gh pr merge --auto` that arms auto-merge.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
[ -f "$BIN/../fleet.conf" ] && . "$BIN/../fleet.conf"
# shellcheck source=/dev/null
. "$BIN/fleet-lib.sh"

C="${TMPDIR:-/tmp}/.claude-dash"; G="$C/global"

# cache_key — byte-identical to tmux-dashboard-rows.sh / tmux-pr-refresh.sh /
# fleet-watch.sh (the shared reversible worktree-path key).
cache_key() { local k=${1//_/_u}; k=${k//\//_s}; k=${k// /_w}; printf '%s' "$k"; }

# Popup UX: everything prints to the popup. When run interactively (a tty) hold on
# a keypress at the end so the result doesn't vanish the instant the popup closes.
hold() {
  [ -t 1 ] || return 0
  printf '\n  press any key to close… '
  IFS= read -rsn1 _ 2>/dev/null || true
  echo
}
say() { printf '%s\n' "$*"; }
refuse() { say "⌃l arm-merge: $*"; say "  (nothing armed.)"; hold; exit 0; }

# --- resolve fleet identity (this fleet only) ---------------------------------
FLEET_SESSION="${FLEET_SESSION:-$(fleet_current_session)}"; export FLEET_SESSION
fleet_load_conf "$FLEET_SESSION"
REPO="${FLEET_REPO:-}"
_r=$(fleet_repo_cached "$FLEET_SESSION"); [ -n "$_r" ] && REPO="$_r"
[ -z "$REPO" ] && refuse "no repo resolved — run this from a fleet dash."

ftmux() {
  if [ -n "${TMUX:-}" ]; then tmux "$@"
  else tmux -L "$(fleet_socket "$FLEET_SESSION")" "$@"; fi
}

# --- resolve the row → its branch + issue -------------------------------------
target="${1:-}"
[ -z "$target" ] && refuse "no row selected."

iss=""; path=""
case "$target" in
  *[!0-9]*)   # a tmux window target (sess:idx, @id, name) → ask tmux (one call)
    US=$'\x1f'
    info=$(ftmux display-message -p -t "$target" \
             "#{@issue}${US}#{pane_current_path}" 2>/dev/null)
    IFS="$US" read -r iss path <<<"$info"
    ;;
  *)          # a bare issue number (scriptable / test path)
    iss="$target"
    ;;
esac
iss="${iss//[^0-9]/}"

cands=""
if [ -n "$path" ]; then
  gitf="$G/git_$(cache_key "$path")"
  if [ -f "$gitf" ]; then
    b=$(cut -f1 "$gitf" 2>/dev/null)
    b=$(printf '%s' "$b" | sed -E 's/(\+[0-9]+)?(-[0-9]+)?$//')   # strip +ahead/-behind
    [ -n "$b" ] && [ "$b" != "-" ] && cands="$b"
  fi
fi
[ -n "$iss" ] && cands="$cands${cands:+ }issue-$iss"
[ -z "$cands" ] && refuse "this row has no branch/issue — not a shippable worker."

# --- prmap row: branch → #num  state  ci  ready --------------------------------
prmf=$(fleet_cache prmap "$FLEET_SESSION")
[ -s "$prmf" ] || refuse "no PR-status cache yet (pr-refresh hasn't run) — try again shortly."

row=""
for b in $cands; do
  row=$(awk -F'\t' -v x="$b" '$1==x{print $2"\t"$3; exit}' "$prmf" 2>/dev/null)
  [ -n "$row" ] && break
done
[ -z "$row" ] && refuse "no open PR for this row${iss:+ (issue #$iss)}."

IFS=$'\t' read -r pnum pstate <<<"$row"
pnum="${pnum#\#}"
[ -z "$pnum" ] && refuse "no PR number for this row."

# --- must be an OPEN PR to arm (a merged/closed PR has nothing to arm) ---------
case "$pstate" in
  OPEN)   : ;;
  MERGED) refuse "PR #$pnum is already merged — cleanup will reap it (or /fleet-cleanup $pnum)." ;;
  CLOSED) refuse "PR #$pnum is closed (not merged) — nothing to arm." ;;
  *)      refuse "PR #$pnum is ${pstate:-in an unknown state} — not open." ;;
esac

# --- arm auto-merge ------------------------------------------------------------
say "▸ arming auto-merge on PR #$pnum${iss:+  (issue #$iss)}"
say "  → gh pr merge --auto --squash $pnum"
say ""
if out=$(gh pr merge "$pnum" --repo "$REPO" --auto --squash 2>&1); then
  say "✓ auto-merge armed — GitHub squash-merges PR #$pnum when it goes green;"
  say "  com.claude-fleet.cleanup reaps the worktree/window afterward."
else
  say "⚠ could not arm auto-merge on PR #$pnum:"
  say "  ${out##*$'\n'}"
  say "  (the PR is untouched — enable auto-merge in the repo settings, or merge"
  say "   it on the web when green. Nothing was force-merged.)"
fi
hold
exit 0
