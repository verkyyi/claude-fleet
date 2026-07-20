#!/bin/bash
# tmux-dashboard.sh — INTERACTIVE, footer-themed session dashboard (fzf).
# Rows come from tmux-dashboard-rows.sh (footer glyphs+palette; issue · model ·
# context% · one-line LLM summary). Reads like the tmux status bar with columns,
# but you can drive it:
#   ↑/↓ move · Enter jump to that window · ⌃n file an issue + spawn its worker ·
#   ⌃s raw scratch session · ⌃x reap a finished worker (confirms when the row
#   isn't merged+clean) · ⌃t live⇄landed · ⌃o restore a landed session ·
#   Ctrl-R refresh now · Esc/q relaunch (it's always-on).
#   Pruned in #289: ⌃g (bind window↔issue — backlog Enter owns spawning), ⌃e
#   (rename — windows take their name from the issue title, #216), ⌃l (arm
#   auto-merge — /fleet-ship arms it now, gh pr merge --auto covers stragglers),
#   and ⌥x (force-reap — folded into the one confirming ⌃x).
# Auto-reloads every REFRESH sec (default 3). Runs as the embedded dash pane in
# the 'plan' hub (fleet-up/steward-session builds it; prefix+g focuses it). Env: REFRESH.
set -uo pipefail
REFRESH="${REFRESH:-1}"   # 1Hz repaint: 4Hz burned ~10% CPU per dash in steady state; the spinner steps a frame per repaint
# Pause the 1Hz repaint while a modal popup is open over the dash (issue #308).
# A tmux display-popup is a client-side overlay that does NOT freeze the panes
# under it — tmux keeps re-compositing them, so the dash's per-second re-render
# flashes THROUGH the popup (worst where the popup edge clips a double-width CJK
# cell — the underlying half-cell flickers before the popup redraws). The modal
# popup binds (conf/tmux-attention.conf) raise a server-global @popup_open flag
# for the lifetime of the popup; the reload loop below waits on it (bin/dash-popup-
# wait.sh) so it emits NO new frame — no under-popup churn — until the popup
# closes and clears the flag, at which point one repaint fires and the 1Hz loop
# resumes. Server scope (set -g) = per-fleet (one tmux server per fleet, issue
# #159) and can't under-detect a popup opened from a sibling window on the server.
#
# THE FLAG IS AN EPOCH, NOT A BOOLEAN (issue #431). Each popup OPEN stamps it with
# `date +%s`; the wait trusts the flag only while it is FRESH (now - flag < MAX_AGE).
# The one path that leaks the flag is the popup dying before its trailing `set 0`
# — the client detaches / switches fleets / disconnects mid-popup (a Termius drop,
# a `detach-client -E` fleet-switch) and the whole key-command chain is cut, so the
# flag STRANDS at a value that used to be a bare 1 and every subsequent reload
# stalled ~20s (the reported freeze, issue #323/#431). Now a `client-detached` hook
# (conf/tmux-attention.conf) clears the flag on that dominant path, and the epoch is
# the backstop: a stranded value simply ages out, so a leaked flag can NEVER stall
# the dash more than MAX_AGE — it self-heals, instead of freezing per reload forever.
FLEET_DASH_POPUP_MAX_AGE="${FLEET_DASH_POPUP_MAX_AGE:-30}"  # seconds a set flag is trusted (issue #431 example N)
FLEET_DASH_POPUP_POLL="${FLEET_DASH_POPUP_POLL:-0.2}"       # wait re-check interval ≈ resume latency
export FLEET_DASH_POPUP_MAX_AGE FLEET_DASH_POPUP_POLL       # inherited by the reload-sync wait
BIN="$(cd "$(dirname "$0")" && pwd)"
ROWS="$BIN/tmux-dashboard-rows.sh"
WAIT="$BIN/dash-popup-wait.sh"   # pauses the reload while @popup_open is fresh (issue #308/#431)
C="${TMPDIR:-/tmp}/.claude-dash"

# Scope rows to THIS fleet's tmux session (strict per-fleet). The rows producer and
# its reload-binds inherit FLEET_SESSION; unset ⇒ show-all (single-fleet back-compat).
# Same convention tmux-issues.sh uses for the backlog panel.
. "$BIN/fleet-lib.sh" 2>/dev/null || true
FLEET_SESSION=$(fleet_current_session 2>/dev/null); export FLEET_SESSION

# Mark this pane as a dash (mirrors how steward-session.sh marks @steward=1) so
# /fleet-sync-install can find EVERY dash pane to respawn on a launcher change —
# the standalone 'dash' window AND an embedded dash pane in the plan/steward
# split. Set early (before fzf) so even a freshly-launched dash is discoverable;
# the pane just runs `bash`, so a marker is far more robust than name/command
# heuristics. Mark THIS pane explicitly ($TMUX_PANE) — a bare `set-option -p`
# marks the *active* pane, so an embedded dash relaunching while the steward pane
# is focused would wrongly tag the steward (issue #135). fleet_mark_role also
# clears @steward here, keeping the two markers mutually exclusive.
fleet_mark_role dash "${TMUX_PANE:-}" 2>/dev/null || \
  tmux set-option -p -t "${TMUX_PANE:-}" @dash 1 2>/dev/null || true

if ! command -v fzf >/dev/null 2>&1; then
  echo "fzf not found — install it (brew install fzf) for the interactive dash."; sleep 5; exit 1
fi

# Summary is an inline column (one line per row) — no preview panel.
PREVIEW=( --preview-window=hidden )

# POPUP=1 → run as a one-shot FULL-SCREEN modal (prefix+g peek): esc/q closes it
# and drops you back where you were, and a jump (enter) closes it too. Otherwise
# it's the always-on 'dash' window that relaunches on esc. Same convention the
# backlog panel (tmux-issues.sh) uses.
POPUP="${POPUP:-}"
ENTER_TAIL=""; [ -n "$POPUP" ] && ENTER_TAIL="+abort"
# Minimal header (issue #249): core actions inline, the rest deferred to the `?`
# cheatsheet (fleet-keys.sh lists every demoted bind: ⌃s ⌃x ⌃t ⌃o). Terse
# `key verb` form, not `key=phrase`, so it fits one line at normal widths.
# `new` is a TAPPABLE button chip `[＋ new]` (issue #381): ⌃n is swallowed by
# Termius/iPad (its own new-tab shortcut) with no keyboard fallback, so the chip
# — wired in run_dash via click-header → the same file+spawn ⌃n runs — is the
# tap-first new-SESSION path there. ⌃n stays bound (additive), listed under `?`.
HDR='↵ jump · [＋ new] · ? keys'
# POPUP variant: same minimal set + a trailing `esc close` (closing a modal is
# less obvious than esc-back on the always-on dash) — that token is the only diff.
[ -n "$POPUP" ] && HDR='↵ jump · [＋ new] · ? keys · esc close'

run_dash() {
  # reset the live⇄landed view so the landed peek doesn't stick across
  # esc-relaunch (and never hides the live session list on reopen). Per-fleet
  # keyed, matching dash-view-toggle.sh (#130).
  rm -f "$C/global/dash_view_${FLEET_SESSION:-default}"
  # Interactive binds use execute-SILENT so fzf never suspends + clears the whole
  # display while the bind runs — a bare `execute` blanks the entire dash for the
  # bind's duration (⌃x reap, issue #313: its output goes to the tmux status line,
  # so an `execute` reap left the pane BLANK the whole time). The slow tail of each
  # action is backgrounded (dash-reap.sh → fleet_bg / `run-shell -b`, issue #304) so
  # the bind also returns instantly. Binds that hand the terminal to an interactive
  # popup (⌃n/⌃s/?) keep `execute` on purpose. The click-header bind mirrors ⌃n for
  # the tappable `[＋ new]` chip (issue #381): tapping ＋/new transforms into the very
  # file+spawn action string ⌃n runs — a single source of truth, additive to ⌃n.
  bash "$ROWS" | fzf --ansi --delimiter=$'\x1f' --with-nth=3 \
    --header-lines=1 \
    --disabled --no-input --no-sort \
    --layout=reverse-list --info=hidden --border=none \
    --prompt='▸ ' \
    --header="$HDR" \
    "${PREVIEW[@]}" \
    --bind "load:reload-sync(sleep $REFRESH; sh $WAIT; bash $ROWS)" \
    --bind "ctrl-r:reload(bash $ROWS)" \
    --bind "?:execute(tmux display-popup -E -w 72% -h 80% \"bash $BIN/fleet-keys.sh --context dash\")" \
    --bind "ctrl-n:execute(tmux display-popup -w 90% -h 12 -E \"bash $BIN/dash-issue-new.sh confirm --spawn\")+reload(bash $ROWS)" \
    --bind "click-header:transform:case \"\$FZF_CLICK_HEADER_WORD\" in *＋*|*new*) echo 'execute(tmux display-popup -w 90% -h 12 -E \"bash $BIN/dash-issue-new.sh confirm --spawn\")+reload(bash $ROWS)' ;; esac" \
    --bind "ctrl-s:execute(tmux display-popup -w 90% -h 10 -E \"bash $BIN/dash-raw-session.sh --prompt-read\")+reload(bash $ROWS)" \
    --bind "ctrl-t:execute-silent(sh $BIN/dash-view-toggle.sh)+reload(bash $ROWS)" \
    --bind "ctrl-o:execute-silent(bash $BIN/dash-restore-session.sh {1})+reload(bash $ROWS)" \
    --bind "ctrl-p:execute-silent(bash $BIN/dash-open-pr.sh {1})" \
    --bind "ctrl-x:execute-silent(bash $BIN/dash-reap.sh {1})+reload(bash $ROWS)" \
    --bind "enter:transform(bash $BIN/dash-enter.sh {1} {q})$ENTER_TAIL" \
    --bind "esc:transform(bash $BIN/dash-esc.sh)" \
    >/dev/null 2>&1
}

# Modal peek: run once, then exit so the popup closes and returns you.
if [ -n "$POPUP" ]; then run_dash; exit 0; fi

# Defensive clear of any STALE @popup_open before the always-on dash starts
# painting (issue #323). If a prior dash/popup died without running its trailing
# `set -g @popup_open 0` (crash, client detached mid-popup), the flag can stick at
# a stale value; a freshly (re)spawned dash must never inherit that or its very
# first reload would pause. The epoch self-expiry (dash-popup-wait.sh) bounds a
# leak that happens WHILE this dash loops; this clears one carried over from
# BEFORE it started. Looping dash only (the freeze-prone consumer) — the one-shot
# POPUP peek above never waits. Safe: a dash process only (re)starts on
# spawn/respawn, not while a sibling popup is genuinely open (and if one ever
# were, its own trailing `set 0` re-clears).
tmux set-option -g @popup_open 0 2>/dev/null || true

# Loop so Esc/q just relaunches — the window stays a live dashboard.
while :; do
  run_dash
  sleep 0.2
done
