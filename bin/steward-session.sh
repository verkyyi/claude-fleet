#!/bin/bash
# steward-session.sh — (re)create the HUB for a fleet: the plan window with the
# dash on top (40%) and the persistent steward Claude session below, in the
# fleet's base checkout. Idempotent PER SESSION: if a @steward-marked pane
# already exists IN THIS SESSION, just jump to it. This is prefix+g's fallback
# (steward-zoom.sh), so an accidentally closed hub window is one keypress from
# restored. The steward picks up its standing orders by running /fleet-steward
# (issue #286), which adopts the layered charter and the latest handoff if one exists.
#
# Multi-fleet (a fleet ≡ a tmux session ≡ one repo): SESS defaults to the CURRENT
# session so every fleet gets its OWN hub, and BASE defaults to that fleet's
# FLEET_MAIN (its per-session conf). Both overridable via STEWARD_SESSION /
# STEWARD_CWD — fleet-up.sh passes them explicitly when it builds a fresh fleet.
#
# IMPORTANT: window names are NOT unique in tmux, so we NEVER target "$SESS:plan"
# by name — a second 'plan' window makes that reference ambiguous, which is how
# earlier versions piled up orphan 'plan' windows and left you on the wrong one
# with no steward. Everything below targets by window_id / pane_id.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
[ -f "$BIN/../fleet.conf" ] && . "$BIN/../fleet.conf"
. "$BIN/fleet-lib.sh"

SESS="${STEWARD_SESSION:-$(fleet_current_session)}"
# Last resort (run outside tmux, no session given): the global primary fleet,
# named by the same 'fleet-<repo>' standard fleet-up.sh uses.
[ -z "$SESS" ] && SESS="fleet-$(basename "${FLEET_REPO:-primary}")"
# This fleet's own tmux server socket (== session name, issue #159). Named on
# EVERY tmux call so the hub is built on the right socket whether we're invoked
# from fleet-up (no $TMUX) or from a zoom bind inside the fleet ($TMUX set) — the
# explicit -L resolves to the same socket either way.
SOCK=$(fleet_socket "$SESS")
# BASE: explicit override → this fleet's FLEET_MAIN (per-session conf) →
# the session's first window cwd → HOME.
if [ -n "${STEWARD_CWD:-}" ]; then
  BASE="$STEWARD_CWD"
  fleet_load_conf "$SESS"   # pick up FLEET_STEWARD_CMD; BASE stays pinned above
else
  fleet_load_conf "$SESS"
  BASE="${FLEET_MAIN:-}"
  [ -z "$BASE" ] && BASE=$(tmux -L "$SOCK" list-windows -t "$SESS" -F '#{pane_current_path}' 2>/dev/null | awk 'NF{print; exit}')
  [ -z "$BASE" ] && BASE="$HOME"
fi
# --- Steward Lite profile (issue #284) --------------------------------------
# Minimum fixed context + hard no-code rails for the hub, rendered per-fleet and
# applied at this one choke point every hub shares. ON by default
# (FLEET_STEWARD_LITE=1); set =0 to revert to today's bare spawn. Applies ONLY to
# the built-in launch (fresh + resume) — a FLEET_STEWARD_CMD override owns its
# whole command line, so we never inject flags into it. STEWARD_FLAGS collects the
# `--settings/--strict-mcp-config/--mcp-config/--model` flags spliced into `claude`.
STEWARD_FLAGS=""
if [ "${FLEET_STEWARD_LITE:-1}" != 0 ] && [ -z "${FLEET_STEWARD_CMD:-}" ]; then
  # The base checkout this steward must never edit — plus its issue-<N> worktree
  # siblings (created next to it as <repo>-issue-*). Prefer FLEET_MAIN (the canonical
  # code root); fall back to the resolved BASE. Claude's absolute-path anchor is a
  # DOUBLE slash (//abs), so strip the single leading slash before prefixing `//`.
  lite_base="${FLEET_MAIN:-$BASE}"
  tpl="$(cat "$BIN/../conf/steward-settings.template.json" 2>/dev/null)"
  if [ -n "$lite_base" ] && [ -n "$tpl" ]; then
    fdir="$(fleet_state_dir "$SESS")"
    settings="$fdir/steward-settings.json"
    mcpcfg="$fdir/steward-mcp.json"
    deny_base="//${lite_base#/}"
    lite_parent="$(dirname "$lite_base")"; lite_repo="$(basename "$lite_base")"
    deny_wt="//${lite_parent#/}/${lite_repo}-issue-*"
    # Render the template via bash substitution (no sed delimiter clash on the /'s).
    tpl="${tpl//__DENY_BASE__/$deny_base}"
    tpl="${tpl//__DENY_WORKTREES__/$deny_wt}"
    tpl="${tpl//__BIN__/$BIN}"
    printf '%s\n' "$tpl" > "$settings"
    STEWARD_FLAGS="--settings '$settings'"
    # MCP diet (the responsiveness win): mount NO personal MCP servers into the hub
    # — their tool lists + instruction blocks are pure per-turn overhead for a
    # dispatcher. --strict-mcp-config + an empty --mcp-config ⇒ zero servers. Escape
    # hatch: FLEET_STEWARD_MCP=1 skips it so an operator keeps their connectors.
    if [ "${FLEET_STEWARD_MCP:-0}" != 1 ]; then
      printf '{"mcpServers":{}}\n' > "$mcpcfg"
      STEWARD_FLAGS="$STEWARD_FLAGS --strict-mcp-config --mcp-config '$mcpcfg'"
    fi
    # Model: a dispatcher needn't run the biggest model. FLEET_STEWARD_MODEL ▸
    # FLEET_MODEL ▸ (unset → claude's own default).
    lite_model="${FLEET_STEWARD_MODEL:-${FLEET_MODEL:-}}"
    [ -n "$lite_model" ] && STEWARD_FLAGS="$STEWARD_FLAGS --model '$lite_model'"
  fi
fi

# The command the steward pane runs. The FRESH launch is the steward's normal
# startup: a documented per-fleet FLEET_STEWARD_CMD override if set, else the
# built-in seed — a ONE-LINE /fleet-steward invocation (issue #286). That skill
# carries the whole steward bootstrap: resolve the fleet, adopt the layered charter
# (bin/steward-charter.sh), pick up the newest handoff if one exists, report
# readiness, then go idle (no /sweep, no /loop). FRESH_INNER is that launch WITHOUT
# the pane-keep-alive `exec $SHELL` tail (appended once below) so it can double as
# the resume fallback. STEWARD_FLAGS (empty unless Steward Lite is on) is spliced
# right after `claude`.
FRESH_INNER="${FLEET_STEWARD_CMD:-claude ${STEWARD_FLAGS} \"/fleet-steward\"}"
# Crash-resume (issue #143): if fleet-restore.sh captured this steward's live
# transcript and passes its id via STEWARD_RESUME_ID, RESUME it (`claude --resume
# <id>`) so the steward's full history survives a tmux-server crash — same as a
# worker. Resume is PRIMARY (it beats FLEET_STEWARD_CMD, matching what restore
# announces), but if the resume FAILS (stale/pruned id) fall back to the fresh
# launch with `||` — never leave a bare shell with no steward (which would be
# strictly worse than the pre-#143 always-fresh behaviour). No id → just fresh.
# NB: a successful resume already carries the /fleet-steward charter adoption in its
# restored history, so it stays correctly scoped without re-running the skill.
if [ -n "${STEWARD_RESUME_ID:-}" ] && [ "${STEWARD_RESUME_ID}" != "-" ]; then
  LAUNCH="claude ${STEWARD_FLAGS} --resume '${STEWARD_RESUME_ID}' || { ${FRESH_INNER}; }"
else
  LAUNCH="$FRESH_INNER"
fi
# An explicit STEWARD_CMD in the environment (fleet-up.sh's internal contract)
# still overrides everything; otherwise run LAUNCH and keep the pane as a shell.
STEWARD_CMD="${STEWARD_CMD:-$LAUNCH; exec \$SHELL}"
# Durable steward seat marker (issue #202): export FLEET_SEAT=steward into the
# pane's command so the steward's claude AND every Bash-tool shell it spawns
# inherit it — independent of whether tmux re-exports $TMUX_PANE per shell (that
# per-shell export proved unreliable, intermittently refusing the steward's own
# /fleet-cleanup kill-window under the #185 strict-$TMUX_PANE guard). The tmux()
# destroy-guard in shell/cw.zsh treats this env as the PRIMARY steward signal.
# A worker spawn (dash-issue-session.sh) never sets it, so #158 is untouched.
# Prepended to the FINAL command so it applies to fresh, resume, and override.
STEWARD_CMD="export FLEET_SEAT=steward; $STEWARD_CMD"

# Debug seam (issue #284): print the fully-resolved launch command and exit
# BEFORE any tmux spawn, so the Steward-Lite flag logic (steward-session-selftest.sh)
# can be asserted hermetically without a live claude/hub. Never set in normal use.
if [ -n "${STEWARD_PRINT_CMD:-}" ]; then
  printf '%s\n' "$STEWARD_CMD"
  exit 0
fi

# already have a live steward pane IN THIS SESSION → just focus it, done. Scoped
# with -s (not -a) so a fresh fleet builds its own hub instead of jumping to
# another fleet's steward.
existing=$(fleet_steward_pane "$SESS")   # socket-aware (issue #159)
if [ -n "$existing" ]; then
  tmux -L "$SOCK" select-window -t "$existing"; tmux -L "$SOCK" select-pane -t "$existing"; exit 0
fi

# No steward pane in this session → no 'plan' window here holds anything precious
# (their dash pane is just a respawnable `bash tmux-dashboard.sh`). Nuke ALL
# 'plan' windows IN THIS SESSION so we rebuild exactly one hub — this also
# self-heals any accumulated orphans.
for wid in $(tmux -L "$SOCK" list-windows -t "$SESS" -F '#{window_id} #{window_name}' | awk '$2=="plan"{print $1}'); do
  tmux -L "$SOCK" kill-window -t "$wid" 2>/dev/null
done

# build the hub fresh, capturing IDs so every op hits THIS window/pane. The dash
# pane's `tmux-dashboard.sh` runs ON this socket (tmux new-window inherits it via
# $TMUX), so it self-marks @dash correctly with bare tmux.
win=$(tmux -L "$SOCK" new-window -P -F '#{window_id}' -t "$SESS:" -n plan -c "$BASE" "bash '$BIN/tmux-dashboard.sh'")
sp=$(tmux -L "$SOCK" split-window -P -F '#{pane_id}' -v -l 60% -t "$win" -c "$BASE" "$STEWARD_CMD")
# Mark the steward pane by its explicit id (never the active pane) and clear any
# @dash on it — @dash/@steward must stay mutually exclusive (issue #135). Done
# inline (not via fleet_mark_role) because that helper uses bare tmux, which would
# hit the WRONG (default) socket when we're invoked from fleet-up outside $TMUX.
tmux -L "$SOCK" set-option -p -t "$sp" @steward 1  2>/dev/null || true
tmux -L "$SOCK" set-option -u -p -t "$sp" @dash    2>/dev/null || true
# Hub cue: re-affirm the top pane-border on this window. Since issue #267 the conf
# sets pane-border-status top GLOBALLY (every window shows a top-of-window header),
# so this is now a redundant safety net for a hub built before that conf is live.
# pane-border-format (in the conf) labels the @steward pane "▸ STEWARD HUB · <fleet>"
# — visible even when the pane is zoomed fullscreen (prefix+g), where the window
# list is the only other cue — while worker/scratch windows get an index:name+#issue
# header and the hub's dash pane stays empty.
tmux -L "$SOCK" set-window-option -t "$win" pane-border-status top 2>/dev/null

# hub belongs at the lowest index (slot 1). Nothing re-sorts windows anymore,
# so this one-time placement is what keeps the hub at slot 1.
if tmux -L "$SOCK" list-windows -t "$SESS" -F '#{window_index}' | grep -qx 1; then
  tmux -L "$SOCK" swap-window -d -s "$win" -t "$SESS:1" 2>/dev/null
else
  tmux -L "$SOCK" move-window -d -s "$win" -t "$SESS:1" 2>/dev/null
fi
tmux -L "$SOCK" select-window -t "$win"
tmux -L "$SOCK" select-pane -t "$sp"
exit 0
