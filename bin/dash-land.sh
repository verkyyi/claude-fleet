#!/bin/bash
# dash-land.sh <window-target|issue> — land a green PR straight from the dash in
# ONE keystroke (issue #232). The dash's ⌃l bind runs this inside a display-popup:
# it resolves the highlighted row → its open PR, confirms the PR is landable-green
# (the SAME prmap `ready` verdict pr-refresh + the watcher gate on — issue #187,
# NOT the bare @prci glyph, which can't tell "ready" from "mergeability-not-yet-
# computed"), then hands the PR number to bin/fleet-land.sh — the seat-agnostic,
# no-LLM lander (issue #231) that owns the lease / merge / base-pull / teardown.
#
# The human pressing ⌃l on a green row IS the approval gate: there is no steward
# LLM turn and no daemon in this path. This script NEVER forces — it lands only
# what the local prmap already shows OPEN + CI-green + mergeable; anything else is
# refused in the popup WITH the reason. fleet-land.sh re-validates the PR live
# (and ejects if the state moved under us), so this local gate is a fast UX
# filter, not the safety boundary.
#
#   arg = the selected row's field 1 (`sess:idx`, a tmux window target) — the same
#         {1} the ⌃x / ⌃e dash binds take. A bare issue number is also accepted so
#         the lander is scriptable/testable without a live pane.
#
# Operates on THIS fleet only (the dash's resolved fleet) — never another fleet's
# repo/prmap. Reads only the caches the collector + pr-refresh already maintain;
# it makes NO gh call of its own before the hand-off to fleet-land.sh.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
[ -f "$BIN/../fleet.conf" ] && . "$BIN/../fleet.conf"
# shellcheck source=/dev/null
. "$BIN/fleet-lib.sh"

C="${TMPDIR:-/tmp}/.claude-dash"; G="$C/global"

# cache_key — byte-identical to tmux-dashboard-rows.sh / tmux-pr-refresh.sh /
# fleet-watch.sh (the shared reversible worktree-path key). Kept in lockstep so we
# read the SAME git_<key> branch cache the dash row itself was drawn from.
cache_key() { local k=${1//_/_u}; k=${k//\//_s}; k=${k// /_w}; printf '%s' "$k"; }

# Popup UX: everything prints to the popup. When run interactively (a tty) hold on
# a keypress at the end so the result token doesn't vanish the instant
# display-popup -E closes; in a pipe/test (no tty) return immediately.
hold() {
  [ -t 1 ] || return 0
  printf '\n  press any key to close… '
  IFS= read -rsn1 _ 2>/dev/null || true
  echo
}
say() { printf '%s\n' "$*"; }
refuse() { say "⌃l land: $*"; say "  (nothing merged.)"; hold; exit 0; }

# --- resolve fleet identity (this fleet only) ---------------------------------
FLEET_SESSION="${FLEET_SESSION:-$(fleet_current_session)}"; export FLEET_SESSION
fleet_load_conf "$FLEET_SESSION"
REPO="${FLEET_REPO:-}"
_r=$(fleet_repo_cached "$FLEET_SESSION"); [ -n "$_r" ] && REPO="$_r"
[ -z "$REPO" ] && refuse "no repo resolved — run this from a fleet dash."

# tmux socket helper (issue #159): a pane carries $TMUX → bare tmux; otherwise
# target the fleet's OWN socket by label. dash-land runs inside the dash popup so
# $TMUX is set, but keep parity with fleet-land.sh for out-of-pane callers/tests.
ftmux() {
  if [ -n "${TMUX:-}" ]; then tmux "$@"
  else tmux -L "$(fleet_socket "$FLEET_SESSION")" "$@"; fi
}

# --- resolve the row → its branch, issue, and dash PR glyph -------------------
target="${1:-}"
[ -z "$target" ] && refuse "no row selected."

iss=""; path=""; prci=""
case "$target" in
  *[!0-9]*)   # a tmux window target (sess:idx, @id, name) → ask tmux (one call)
    US=$'\x1f'
    info=$(ftmux display-message -p -t "$target" \
             "#{@issue}${US}#{pane_current_path}${US}#{@prci}" 2>/dev/null)
    IFS="$US" read -r iss path prci <<<"$info"
    ;;
  *)          # a bare issue number (scriptable / test path)
    iss="$target"
    ;;
esac
iss="${iss//[^0-9]/}"

# Candidate branches to match against prmap, most-authoritative first:
#   1. the git_<key> branch the dash row itself was drawn from (decoration-stripped,
#      same normalisation as tmux-pr-refresh/fleet-watch)
#   2. issue-<N> (the fleet's worktree/branch naming convention)
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
[ -z "$cands" ] && refuse "this row has no branch/issue — not a landable worker."

# --- prmap row: branch → #num  state  ci  ready --------------------------------
prmf=$(fleet_cache prmap "$FLEET_SESSION")
[ -s "$prmf" ] || refuse "no PR-status cache yet (pr-refresh hasn't run) — try again shortly."

row=""
for b in $cands; do
  row=$(awk -F'\t' -v x="$b" '$1==x{print $2"\t"$3"\t"$4"\t"$5; exit}' "$prmf" 2>/dev/null)
  [ -n "$row" ] && break
done
[ -z "$row" ] && refuse "no open PR for this row${iss:+ (issue #$iss)}."

IFS=$'\t' read -r pnum pstate pci pready <<<"$row"
pnum="${pnum#\#}"
[ -z "$pnum" ] && refuse "no PR number for this row."

# --- the landable-green gate (the issue #187 predicate; matches the watcher) ---
# state OPEN + CI green (✓) + mergeability ready|behind. `behind` IS landable —
# fleet-land.sh update-branches it while holding the lease. conflict / blocked /
# "" (mergeability-not-yet-computed) are NOT auto-landable and get refused here.
case "$pstate" in
  OPEN)   : ;;
  MERGED) refuse "PR #$pnum is already merged." ;;
  *)      refuse "PR #$pnum is $pstate — not open." ;;
esac
[ "$pci" = "✓" ] || refuse "PR #$pnum is not CI-green (ci='${pci:-·}')."
case "$pready" in
  ready|behind) : ;;
  conflict)     refuse "PR #$pnum conflicts with the base — needs a rebase." ;;
  blocked)      refuse "PR #$pnum is blocked (review required / branch protection)." ;;
  *)            refuse "PR #$pnum mergeability isn't computed yet — try again in a moment." ;;
esac

# --- hand off to the lander ----------------------------------------------------
say "▸ landing PR #$pnum${iss:+  (issue #$iss)}  [ready=$pready${prci:+ · dash=$prci}]"
say "  → bin/fleet-land.sh $pnum"
say ""
# fleet-land.sh streams progress on stderr (visible LIVE in the popup) and prints
# exactly ONE result token on stdout — capture that to headline the outcome.
tok=$(bash "$BIN/fleet-land.sh" "$pnum")
say ""
case "$tok" in
  landed:*) say "✓ $tok — merged, base fast-forwarded, worker reaped." ;;
  eject:*)  say "⚠ $tok — not landed (fleet-land.sh refused; nothing forced)." ;;
  error:*)  say "✗ $tok — a precondition failed." ;;
  '')       say "✗ fleet-land.sh returned no result token." ;;
  *)        say "· $tok" ;;
esac
hold
exit 0
