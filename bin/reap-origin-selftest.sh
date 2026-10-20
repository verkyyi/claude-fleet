#!/bin/bash
# reap-origin-selftest.sh — where a session came from decides when it may be
# closed (T694, 回收 B): bin/fleet_reap_policy.py's ORIGINS table, read by the
# spawners through fleet_reap_origin (bin/fleet-lib.sh) and stamped @reap_origin
# beside @reap_policy; a `keep` a session sets for itself is marked (lapses once
# its work is over — fleet-cleanup-idle-selftest.py DispatchedSession closes it).
#
#   A  fleet_reap_origin: person · dispatched · member (its parent window runs the
#      EPIC driver) · driver · orchestrator · probe; a reopened / continued ID
#      with a parent in its ledger (代起 / 恢复) keeps «dispatched»
#   B  each origin's default (origin-default) — the table the spawners stamp
#   C  fleet-reap-policy.sh set keep --by session stamps @reap_keep_by session;
#      a person's keep (the default) or any other policy clears it
#   D  both spawners derive the origin and stamp @reap_origin + the table's
#      default; an orchestrator is pinned; a session's keep is marked
#
# Real tmux on an isolated socket under a private TMUX_TMPDIR.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
command -v tmux >/dev/null || { printf 'selftest: tmux not installed — SKIP\n' >&2; exit 0; }
WORK=$(mktemp -d "${TMPDIR:-/tmp}/reap-origin.XXXXXX")
export TMUX_TMPDIR="$WORK/tmux" FLEET_CONF_DIR="$WORK/conf" HOME="$WORK/home"
mkdir -p "$TMUX_TMPDIR" "$FLEET_CONF_DIR" "$HOME"
SOCK="reaporig$$"
unset TMUX TMUX_PANE
T() { tmux -L "$SOCK" -f /dev/null "$@"; }
trap 'T kill-server 2>/dev/null; rm -rf "$WORK"' EXIT
fails=0
eq() { if [ "$2" = "$3" ]; then printf 'PASS %s\n' "$1"; else printf 'FAIL %s: got [%s] want [%s]\n' "$1" "$2" "$3"; fails=$((fails + 1)); fi; }
# shellcheck source=/dev/null
. "$BIN/fleet-lib.sh"
O() { fleet_reap_origin "$SOCK" "$@"; }

# ---- A ------------------------------------------------------------------------
T new-session -d -s "$SOCK" -n home "sleep 600"
DRV=aaaaaaaa-1111-4111-8111-111111111111
ORC=bbbbbbbb-2222-4222-8222-222222222222
w=$(T new-window -d -P -F '#{window_id}' -t "$SOCK" "sleep 600")
T set-option -w -t "$w" @fleet_id "$DRV"; T set-option -w -t "$w" @agent_def epic-driver
w=$(T new-window -d -P -F '#{window_id}' -t "$SOCK" "sleep 600")
T set-option -w -t "$w" @fleet_id "$ORC"; T set-option -w -t "$w" @agent_def orchestrator
eq "A: no parent, no agent file → person"     "$(O '' '' '' 0 '')" person
eq "A: the hub as origin → person"             "$(O '' hub '' 0 '')" person
eq "A: a session's key → dispatched"           "$(O '' scratch-3 '' 0 '')" dispatched
eq "A: another machine's parent → dispatched"  "$(O '' '' u/$ORC 0 '')" dispatched
eq "A: the orchestrator's child → dispatched"  "$(O '' "$ORC" '' 0 "$ORC")" dispatched
eq "A: the EPIC driver's child → member"       "$(O '' "$DRV" '' 0 "$DRV")" member
eq "A: the driver itself → driver"             "$(O fleet-epic:epic-driver "$ORC" '' 0 "$ORC")" driver
eq "A: an orchestrator → orchestrator"         "$(O orchestrator '' '' 0 '')" orchestrator
eq "A: the TEST identity's → probe"            "$(O '' '' '' 1 '')" probe
OLD=cccccccc-3333-4333-8333-333333333333
python3 "$BIN/fleet_id.py" open "$OLD" --parent "$ORC" --title t >/dev/null 2>&1
eq "A: 代起 — a reopened ID whose ledger has a parent → dispatched" "$(O '' '' '' 0 '' "$OLD")" dispatched
eq "A: …a parent-less ID stays a person's"     "$(O '' '' '' 0 '' dddddddd-4444-4444-8444-444444444444)" person

# ---- B ------------------------------------------------------------------------
D() { python3 "$BIN/fleet_reap_policy.py" origin-default "$@"; }
eq "B: person idle 2h · dispatched/member/driver merged · orchestrator keep · decide idle 15m · probe done 1m" \
  "$(for o in person dispatched member driver orchestrator decide probe; do D "$o"; done | tr '\n' ' ')" \
  "idle:2h merged merged merged keep idle:15m done:1m "
eq "B: an issue session a person opened keeps merged" "$(D person --kind issue)" merged
eq "B: a /loop seed keeps loop-end, a driver's goes when the batch does" "$(D dispatched --kind loop)|$(D driver --kind loop)" "loop-end|merged"

# ---- C ------------------------------------------------------------------------
w=$(T new-window -d -P -F '#{window_id}' -t "$SOCK" "sleep 600")
# the session's socket label is its name (fleet_socket): our server is "$SOCK"
P() { bash "$BIN/fleet-reap-policy.sh" set "$@" --win "$w" --session "$SOCK" >/dev/null 2>&1; }
R() { T show-options -wqv -t "$w" "$1"; }
P keep --by session
eq "C: a session's own keep is marked" "$(R @reap_policy)|$(R @reap_keep_by)" "keep|session"
P keep
eq "C: a person's keep clears the mark" "$(R @reap_policy)|$(R @reap_keep_by)" "keep|"
P keep --by session; P idle:15m --by session
eq "C: any other policy clears it" "$(R @reap_policy)|$(R @reap_keep_by)" "idle:15m|"
P keep --by robot; eq "C: --by takes person|session" "$?" 2
eq "C: …and refuses anything else (nothing stamped)" "$(R @reap_policy)" "idle:15m"

# ---- D ------------------------------------------------------------------------
for f in dash-raw-session.sh dash-issue-session.sh; do
  grep -q 'fleet_reap_origin "\$SOCK"' "$BIN/$f" && grep -q 'fleet_reap_policy.py" origin-default' "$BIN/$f" \
    && grep -q '@reap_origin' "$BIN/$f" && grep -q '@reap_keep_by session' "$BIN/$f"
  eq "D: $f derives the origin, stamps it and the table's default, marks a session's keep" "$?" 0
done
grep -q '\[ "\$REAP_ORIGIN" = orchestrator \] && \[ "\$PIN" != 1 \] && stamp_option @pin 1' "$BIN/dash-raw-session.sh"
eq "D: dash-raw-session.sh pins an orchestrator" "$?" 0
grep -q '"--by", "session"' "$BIN/fleet-mcp.py"
eq "D: the set_reap tool sets as the session" "$?" 0
grep -q '@reap_origin @reap_keep_by @reap_unreported' "$BIN/fleet-migrate.sh"
eq "D: a reopen carries where it came from" "$?" 0

[ "$fails" = 0 ] && { printf 'reap-origin-selftest: all green\n'; exit 0; }
printf 'reap-origin-selftest: %d failed\n' "$fails"; exit 1
