#!/bin/bash
# tmux-dashboard.sh — INTERACTIVE, footer-themed session dashboard (fzf).
# Rows come from tmux-dashboard-rows.sh (footer glyphs+palette; issue · model ·
# context% · one-line LLM summary). Reads like the tmux status bar with columns,
# but you can drive it:
#   ↑/↓ move · Enter jump to that window · type a name + Enter → an EMPTY scratch
#   session named after it, no prompt sent (#534; the prompt line at the bottom is
#   always visible; dash-enter.sh hands the text to dash-raw-session.sh --name-file) ·
#   ⌃n file an issue + spawn its worker ·
#   ⌃s raw scratch session (instant — no prompt) · ⌃e rename the highlighted
#   window (inline on the query line; ↵ commits, esc cancels) · ⌃x reap a
#   finished worker (confirms when the row isn't merged+clean) · ⌃t live⇄landed ·
#   ⌃o restore a landed session ·
#   ⌃v flip this fleet's default agent for NEW sessions (claude ⇄ codex, #554 —
#   written to the fleet's conf, so every spawn path follows; the prompt line
#   reads `claude ▸ ` / `codex ▸ ` from the same conf, dash-agent-prompt.sh) ·
#   Ctrl-R refresh now · Esc/q relaunch (it's always-on).
#   Every ⌃-key above is the DEFAULT: tmux never delivers its prefix to a pane,
#   so each launch resolves the bind table in bin/dash-keymap.sh against the
#   live prefix/prefix2 and remaps a colliding key to its ⌥ twin (issue #556 —
#   the flip was ⌃a, the operator's prefix, so tmux ate it); `?` shows the key
#   that is actually bound.
#   Pruned in #289: ⌃g (bind window↔issue — backlog Enter owns spawning) and ⌃l
#   (arm auto-merge — the worker lands its own PR now, #441; gh pr merge covers
#   strays), plus ⌥x (force-reap — folded into the one confirming ⌃x). ⌃e was
#   pruned there too but its handlers never were — #449 re-wires the key to the
#   rename mode dash-enter.sh/dash-esc.sh have carried all along.
# Auto-reloads every REFRESH sec (default 3). Runs as the embedded dash pane in
# the 'plan' hub (fleet-up/hub-session builds it; prefix+g focuses it). Env: REFRESH.
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

# Mark this pane as a dash (mirrors how hub-session.sh marks @hub=1) so
# /fleet-sync-install can find EVERY dash pane to respawn on a launcher change —
# the standalone 'dash' window AND an embedded dash pane in the plan/hub
# split. Set early (before fzf) so even a freshly-launched dash is discoverable;
# the pane just runs `bash`, so a marker is far more robust than name/command
# heuristics. Mark THIS pane explicitly ($TMUX_PANE) — a bare `set-option -p`
# marks the *active* pane, so an embedded dash relaunching while the hub pane
# is focused would wrongly tag the hub (issue #135). fleet_mark_role also
# clears @hub here, keeping the two markers mutually exclusive.
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
# No hint line above the prompt (issue #536). The dash used to carry a one-row
# fzf header — `↵ jump · ＋new · ? keys` (#249 minimal set, #381 tap chip) — but
# once the prompt line became always-visible (#493) it went stale against it:
# `↵ jump` contradicted the ghost text's `↵ → scratch` one row below, `? keys`
# only fires on an EMPTY line (with text typed `?` is a character — see the `?`
# bind), and the `? keys` token was never tappable. The operator chose to drop the
# row outright rather than relocate its content, so:
#   • the ghost text carried BOTH ↵ meanings (typed → named scratch, empty → jump)
#     until #554 gave its second half to the agent hint — since #559 `↵ 新开空
#     scratch · 切换 agent: ⌃v` (the resolved toggle key, never a literal);
#     empty-↵ = jump is the cheatsheet's;
#   • the ＋new chip is gone with the row — ⌃n is the dash's only new-issue+worker
#     path (the backlog popup, prefix b, keeps its own chip);
#   • `?` stays bound (empty line → the cheatsheet, fleet-keys.sh --context dash).
# The prompt line at the bottom is ALWAYS visible (no --no-input): it is the
# quick-scratch box — type a name, ↵ → an EMPTY scratch session named after it
# (dash-enter.sh → dash-raw-session.sh --name-file; it seeded a prompt until #534 —
# an operator typing here wants a session to drive, not one already working). The
# hint lives in the input's ghost text, so it vanishes the moment you start typing.
# Typing never filters (--disabled); ↵ on an EMPTY line is still plain jump.
# --no-separator + --info=hidden: the input costs ONE row, not two (iPad-height
# panes), and the list runs straight into it.
# The prompt label + ghost are NOT literals here (issue #554): the prompt carries
# the fleet's default agent for a NEW session — `claude ▸ ` / `codex ▸ ` (codex in
# the #547 row-tag colour) — and the ghost says what ↵ does + names the toggle
# key the dash actually bound (issue #559; the `<agent>:` one-off prefix is gone).
# Both come from ONE helper, bin/dash-agent-prompt.sh (effective FLEET_AGENT via
# fleet_load_conf; the key via the exported DASH_GLYPH_AGENT below), read at
# every launch here AND re-derived on every reload tick (`load` / ⌃r →
# transform(… actions)), so a change from ANY writer — ⌃v (dash-agent-toggle.sh),
# the prefix+c modal, a hand edit — shows on the next tick without a relaunch.
# Same helper restores the label after a rename.
AGENT_PROMPT="$BIN/dash-agent-prompt.sh"
KEYMAP="$BIN/dash-keymap.sh"   # the dash's ⌃-keys, resolved against the tmux prefix (issue #556)

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
  # popup (⌃n/?) keep `execute` on purpose. ⌃s is no longer one of them (issue #444):
  # a scratch now spawns ON THE KEYSTROKE — no name popup, no confirm (that prompt was
  # an empty line to dismiss; `--name` still exists off the dash) — so it takes the same
  # silent + backgrounded (`--bg`) form as the other instant actions.
  # The two popup binds (⌃n/?) do NOT call `tmux display-popup` directly — they go
  # through bin/dash-popup.sh (issue #448). A popup needs a CLIENT to draw on, and a
  # command run from a pane process (which is what an fzf `execute()` bind is) reaches
  # tmux with no client of its own, so tmux has to guess one; when it can't it exits 1
  # with "no current client" and draws NOTHING. Inside `execute()` that error is
  # invisible — our stdout/stderr are /dev/null — so the keystroke just looked dead,
  # intermittently, exactly across a Termius drop / reconnect / detached hub. The helper
  # resolves the live client itself, raises @popup_open for the popup's lifetime (the
  # #308/#431 rail the prefix binds always had and these two skipped), and falls back to
  # running the command INLINE in the pane when there is no client — so a dash popup
  # bind can never silently do nothing again.
  # `?` is the dash's one PRINTABLE bind, and a bound printable key fires its action
  # instead of typing (fzf 0.74.3) — so with the input always visible it is a
  # transform: an EMPTY query → the cheatsheet popup (the key as documented); a
  # non-empty one → `put(?)`, i.e. the character goes into the task you're typing.
  # (dash-rename.sh still unbinds it outright for the length of a rename, where the
  # query is pre-filled and may be emptied mid-edit.)
  # ⌃v is a transform (issue #554): dash-agent-toggle.sh flips FLEET_AGENT in the
  # fleet's conf via the config-modal write path, toasts, and emits the
  # change-prompt/change-ghost that relabels the line at once. `load`/⌃r re-derive
  # the label from the conf each tick (a no-op emit when nothing changed; nothing at
  # all while a rename owns the prompt line).
  # The ⌃-keys are NOT literals (issue #556): tmux swallows its prefix (and
  # prefix2) before any pane sees it, so each launch resolves the bind table
  # through bin/dash-keymap.sh — the default key unless it IS the live prefix,
  # else the ⌥ fallback — and the `?` sheet (fleet-keys.sh) + the toggle toast
  # read the same resolution. The literals below are only the never-launch-
  # unbound floor for an install missing the helper.
  DASH_KEY_AGENT=ctrl-v DASH_KEY_RELOAD=ctrl-r DASH_KEY_NEW=ctrl-n DASH_KEY_SCRATCH=ctrl-s DASH_KEY_VIEW=ctrl-t
  DASH_KEY_RESTORE=ctrl-o DASH_KEY_PR=ctrl-p DASH_KEY_REAP=ctrl-x DASH_KEY_RENAME=ctrl-e DASH_KEY_ANSWER=ctrl-k
  DASH_GLYPH_AGENT='⌃v'
  eval "$(bash "$KEYMAP" env 2>/dev/null)"
  # The ghost names the agent-flip key (issue #559): export the LAUNCH-TIME glyph
  # so the helper — at launch here, on every tick, and inside the toggle's
  # change-ghost, all children of this fzf — says the key the bind above holds.
  export DASH_GLYPH_AGENT
  PROMPT_NOW=$(bash "$AGENT_PROMPT" prompt 2>/dev/null); [ -n "$PROMPT_NOW" ] || PROMPT_NOW='▸ '
  GHOST_NOW=$(bash "$AGENT_PROMPT" ghost 2>/dev/null);   [ -n "$GHOST_NOW" ]  || GHOST_NOW='↵ 新开空 scratch'
  bash "$ROWS" | fzf --ansi --delimiter=$'\x1f' --with-nth=3 \
    --header-lines=1 \
    --disabled --no-sort \
    --layout=reverse-list --info=hidden --no-separator --border=none \
    --prompt="$PROMPT_NOW" --ghost="$GHOST_NOW" \
    "${PREVIEW[@]}" \
    --bind "load:reload-sync(sleep $REFRESH; sh $WAIT; bash $ROWS)+transform(bash $AGENT_PROMPT actions)" \
    --bind "$DASH_KEY_RELOAD:reload(bash $ROWS)+transform(bash $AGENT_PROMPT actions)" \
    --bind "$DASH_KEY_AGENT:transform(bash $BIN/dash-agent-toggle.sh)" \
    --bind "?:transform:[ -n \"\$FZF_QUERY\" ] && echo 'put(?)' || echo 'execute(bash $BIN/dash-popup.sh -w 72% -h 80% -- bash $BIN/fleet-keys.sh --context dash)'" \
    --bind "$DASH_KEY_NEW:execute(bash $BIN/dash-popup.sh -w 90% -h 12 -- bash $BIN/dash-issue-new.sh confirm --spawn)+reload(bash $ROWS)" \
    --bind "$DASH_KEY_SCRATCH:execute-silent(bash $BIN/dash-raw-session.sh --bg)+reload(bash $ROWS)" \
    --bind "$DASH_KEY_VIEW:execute-silent(sh $BIN/dash-view-toggle.sh)+reload(bash $ROWS)" \
    --bind "$DASH_KEY_RESTORE:execute-silent(bash $BIN/dash-restore-session.sh {1})+reload(bash $ROWS)" \
    --bind "$DASH_KEY_PR:execute-silent(bash $BIN/dash-open-pr.sh {1})" \
    --bind "$DASH_KEY_REAP:execute-silent(bash $BIN/dash-reap.sh {1})+reload(bash $ROWS)" \
    --bind "$DASH_KEY_RENAME:transform(bash $BIN/dash-rename.sh {1})" \
    --bind "$DASH_KEY_ANSWER:execute(bash $BIN/dash-popup.sh -w 84% -h 70% -- bash $BIN/dash-answer.sh {1})+reload(bash $ROWS)" \
    --bind "enter:transform(bash $BIN/dash-enter.sh {1} {q})$ENTER_TAIL" \
    --bind "esc:transform(bash $BIN/dash-esc.sh {q})" \
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
