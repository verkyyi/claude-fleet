#!/bin/bash
# pane-header-selftest.sh — the top-of-window header contract (issue #267).
#
# Every window shows a top-of-pane header naming its session — "index:name" plus
# the bound ##{@issue} when issue-bound — EXCEPT the hub, whose steward pane keeps
# its "▸ STEWARD HUB" cue and whose dash pane stays empty. That behaviour lives in
# ONE line of conf/tmux-attention.conf: `set -g pane-border-format "…"`. This test
# takes that REAL line, applies it on a private tmux server, and asserts the
# three-way role routing so a future edit can't silently drop the hub exemption
# (dash pane leaking "1:plan") or the worker header (issue/name vanishing).
#
# Also guards `pane-border-status top` is set globally in the conf — without it the
# format renders nowhere.
#
# tmux absent → SKIP cleanly (exit 0), per the run-selftests convention.
# Exit 0 = pass. Non-zero = fail (prints which assertion diverged).
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
CONF="$BIN/../conf/tmux-attention.conf"
[ -f "$CONF" ] || { printf 'selftest: %s not found\n' "$CONF" >&2; exit 2; }
REAL_TMUX="$(command -v tmux 2>/dev/null)"
[ -n "$REAL_TMUX" ] || { printf 'selftest: tmux not installed — SKIP\n' >&2; exit 0; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/ph-selftest.XXXXXX")" || exit 2
SOCK="$WORK/tmux.sock"
tmux() { "$REAL_TMUX" -S "$SOCK" "$@"; }  # every tmux call → private socket

cleanup() { tmux kill-server 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT
trap 'exit 130' INT TERM HUP

fail() { printf 'selftest FAIL: %s\n' "$1" >&2; exit 1; }
# render the border format for a pane, then strip #[...] style tokens → visible text
render() { tmux display-message -p -t "$1" "$FMT" | sed -E 's/#\[[^]]*\]//g'; }

# --- pull the REAL conf lines (the thing we actually ship) --------------------
grep -qE '^[[:space:]]*set(-option)?[[:space:]]+-g[[:space:]]+pane-border-status[[:space:]]+top' "$CONF" \
  || fail "conf does not enable 'pane-border-status top' globally"

# extract the pane-border-format value (the string between the outer quotes)
FMT="$(sed -n 's/^[[:space:]]*set\(-option\)\{0,1\}[[:space:]]\{1,\}-g[[:space:]]\{1,\}pane-border-format[[:space:]]\{1,\}"\(.*\)"[[:space:]]*$/\2/p' "$CONF")"
[ -n "$FMT" ] || fail "could not extract pane-border-format from conf"

# --- build a fleet-shaped session on the private socket ----------------------
# -f /dev/null: a clean server (no ~/.tmux.conf bleed → base-index etc. stay
# default). We target windows/panes by captured id, never a numeric index, so the
# test is base-index-agnostic.
tmux -f /dev/null new-session -d -s s -x 120 -y 40 || fail "could not start isolated tmux server"

# an issue-bound worker window
ww="$(tmux display-message -p '#{window_id}')"
tmux rename-window -t "$ww" issue-267
tmux set-window-option -t "$ww" @issue 267

# the hub window: dash pane (top) + steward pane (bottom)
hw="$(tmux new-window -P -F '#{window_id}' -t s: -n plan)"
dp="$(tmux display-message -p -t "$hw" '#{pane_id}')"
tmux set-option -p -t "$dp" @dash 1
sp="$(tmux split-window -P -F '#{pane_id}' -v -t "$hw")"
tmux set-option -p -t "$sp" @steward 1

# a raw/scratch window (no @issue)
rw="$(tmux new-window -P -F '#{window_id}' -t s: -n scratch)"
tmux set-window-option -t "$rw" @raw 1

# --- assert the three-way routing --------------------------------------------
worker="$(render "$ww")"
case "$worker" in
  *"issue-267"*"#267"*) : ;;                       # index:name + bound issue
  *) fail "worker header missing name/issue — got [$worker]" ;;
esac

steward="$(render "$sp")"
case "$steward" in
  *"STEWARD HUB"*) : ;;                            # hub keeps its own cue
  *) fail "steward pane lost its hub cue — got [$steward]" ;;
esac
case "$steward" in
  *"plan"*) fail "steward pane leaked the window name — got [$steward]" ;;
esac

dash="$(render "$dp")"
[ -z "$(printf '%s' "$dash" | tr -d '[:space:]')" ] \
  || fail "hub dash pane should be empty (the 'except the hub' rule) — got [$dash]"

raw="$(render "$rw")"
case "$raw" in
  *"scratch"*) : ;;                                # names the scratch window
  *) fail "raw header missing window name — got [$raw]" ;;
esac
case "$raw" in
  *"#"*[0-9]*) fail "raw (no @issue) should show no issue number — got [$raw]" ;;
esac

printf 'selftest OK: top-of-window header routes worker/steward/dash/raw correctly (issue #267)\n'
