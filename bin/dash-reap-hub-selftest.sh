#!/bin/bash
# dash-reap-hub-selftest.sh — reaping a worker that lives on ANOTHER machine
# (issue #1589, EPIC #1585 R3). On an isolated tmux server, a sandbox conf dir and
# the hub write client stubbed (FLEET_HUB_WRITE_CMD), pins:
#   A  the degenerate case: hub off (no CCQUOTA_FLEET, a worker map on disk all
#      the same) → dash-reap.sh on a key no window here holds answers exactly as
#      before (refused:target, exit 4) and the hub is never written to.
#   B  hub on, the key on mac-a (the worker map), --yes → ONE worker_reap write
#      naming the map's full worker_id; the node's terminal fields come back as a
#      local reap's answer: reaped:full → 0 · reaped:keep → 0 · skip:live → 3 with
#      the node's reason (stderr1) on stderr · refused:* → 4 · an older node that
#      writes no fields back is read off its error message · NOT_FOUND →
#      refused:no-target 4 · unknown / still running → failed:* 5 ("not counted as
#      reaped") · the hub refusing, or nothing sent → refused:hub 4.
#   C  without --yes → skip:needs-confirm (exit 3), nothing written.
#   D  a key live HERE never goes to the hub, hub on or not; FLEET_REAP_LOCAL=1
#      (the node's own adapter) never bounces a reap back to the hub; a fleet conf
#      line CCQUOTA_FLEET=1 turns the branch on with the login env silent (#1539).
#   E  the sidebar's remote 回收 (fleet-row-remote.sh reap) goes through
#      fleet_hub_reap: one worker_reap write, no error.
# tmux / python3 absent → SKIP. Exit 0 = pass.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
. "$BIN/selftest-lib.sh"
REAL_TMUX=$(command -v tmux) || { echo 'dash-reap-hub selftest: tmux absent — SKIP'; exit 0; }
st_need python3

WORK="$(mktemp -d "${TMPDIR:-/tmp}/dash-reap-hub.XXXXXX")" || exit 2
L="drh$$"
export FLEET_SKIP_GLOBAL_CONF=1
export FLEET_CONF_DIR="$WORK/conf"; mkdir -p "$FLEET_CONF_DIR/fleets/$L" "$FLEET_CONF_DIR/control"
export FLEET_CC_SESSIONS_DIR="$WORK/sessions"; mkdir -p "$FLEET_CC_SESSIONS_DIR"
CONF="$FLEET_CONF_DIR/fleets/$L/conf"
printf 'FLEET_REPO=acme/app\nFLEET_MAIN=%s/main\n' "$WORK" > "$CONF"
unset TMUX TMUX_PANE CCQUOTA_FLEET FLEET_HUB_STATUS_CMD FLEET_HUB_CACHE_SECS FLEET_REAP_LOCAL FLEET_HUB_WRITE_CMD

st_tally
tf() { "$REAL_TMUX" -L "$L" "$@"; }
cleanup() { "$REAL_TMUX" -L "$L" kill-server 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT INT TERM

tf -f /dev/null new-session -d -s "$L" -n home 'while :; do sleep 300; done' 2>/dev/null \
  || { echo 'dash-reap-hub selftest: cannot start an isolated tmux server — SKIP' >&2; exit 0; }
w7=$(tf new-window -d -P -F '#{window_id}' -n issue-7 'while :; do sleep 300; done')
tf set-window-option -t "$w7" @issue 7
SP=$(tf display-message -p '#{socket_path}')

# The worker map: issue-9 lives on mac-a (another machine's fleet UUID).
MAC_A=11111111-2222-4333-8444-555555555555
printf '%s/issue-9\tmac-a\t\n%s/issue-7\tmac-a\t\n' "$MAC_A" "$MAC_A" > "$FLEET_CONF_DIR/control/hub-workers.tsv"

# The write client's seam: log the call, answer with $FLEET_CONF_DIR/answer.
WRITES="$WORK/writes"
STUB='printf "%s\t%s\n" "$1" "$2" >> '"$WRITES"'; cat "$FLEET_CONF_DIR/answer" 2>/dev/null'
answer() { printf '%s\n' "$1" > "$FLEET_CONF_DIR/answer"; }
OP='"operation_id":"00000000-0000-4000-8000-000000000009"'
nwrites() { [ -f "$WRITES" ] && grep -c . "$WRITES" || echo 0; }

# reap <args…> → OUT / ERR / RC — dash-reap.sh pointed at the isolated server
reap() {
  OUT=$(TMUX="$SP,0,0" FLEET_HUB_WRITE_CMD="$STUB" bash "$BIN/dash-reap.sh" "$@" 2>"$WORK/err"); RC=$?
  ERR=$(cat "$WORK/err")
}

# --- A: hub off — byte for byte as before ------------------------------------------
reap issue-9 --yes
st_count; [ "$OUT" = refused:target ] && [ "$RC" = 4 ] || st_miss "A: hub off, remote key → refused:target 4" "$OUT rc=$RC"
st_count; [ "$(nwrites)" = 0 ] || st_miss "A: hub off must never write to the hub"

export CCQUOTA_FLEET=1
# --- C: no --yes → skip:needs-confirm, nothing sent --------------------------------
reap issue-9
st_count; [ "$OUT" = skip:needs-confirm ] && [ "$RC" = 3 ] || st_miss "C: no --yes → skip:needs-confirm 3" "$OUT rc=$RC"
st_count; case "$ERR" in *mac-a*--yes*) ;; *) st_miss "C: the reason names the machine and --yes" "$ERR" ;; esac
st_count; [ "$(nwrites)" = 0 ] || st_miss "C: no --yes must send nothing"

# --- B: the node's terminal fields → a local reap's answer --------------------------
answer '{'"$OP"',"status":"succeeded","result":{"how":"reaped:full","token":"reaped:full","exit":0,"window":"@44","kept":"worktree, branch and issue disposed; the window is closed"}}'
reap issue-9 --yes
st_count; [ "$OUT" = reaped:full ] && [ "$RC" = 0 ] || st_miss "B: succeeded → reaped:full 0" "$OUT rc=$RC $ERR"
st_count; [ "$(nwrites)" = 1 ] || st_miss "B: exactly one hub write" "$(cat "$WRITES" 2>/dev/null)"
st_count; [ "$(cut -f1 "$WRITES")" = worker_reap ] || st_miss "B: the write is worker_reap" "$(cat "$WRITES")"
st_count; python3 -c 'import json,sys; d=json.loads(sys.argv[1]); sys.exit(0 if d["worker_id"]==sys.argv[2] and d.get("idempotency_key") else 1)' \
      "$(cut -f2 "$WRITES")" "$MAC_A/issue-9" || st_miss "B: names the map's full worker_id + an idempotency key" "$(cut -f2 "$WRITES")"
st_count; case "$ERR" in *"lives on mac-a"*) ;; *) st_miss "B: stderr says where it was reaped" "$ERR" ;; esac
# the repo-qualified spelling (a 2+ repo fleet) resolves through wid: the same way
printf '%s/acme-app:issue-11\tmac-a\t\n' "$MAC_A" >> "$FLEET_CONF_DIR/control/hub-workers.tsv"
reap acme-app:issue-11 --yes
st_count; [ "$OUT" = reaped:full ] && tail -1 "$WRITES" | grep -q "$MAC_A/acme-app:issue-11" \
  || st_miss "B: <slug>:issue-N goes to the hub as its worker_id" "$OUT $(tail -1 "$WRITES")"

answer '{'"$OP"',"status":"succeeded","result":{"how":"reaped:keep","token":"reaped:keep","exit":0}}'
reap issue-9 --yes
st_count; [ "$OUT" = reaped:keep ] && [ "$RC" = 0 ] || st_miss "B: reaped:keep 0" "$OUT rc=$RC"

answer '{'"$OP"',"status":"failed","result":{"error":{"code":"INVALID_STATE","message":"Reap refused on the fleet: skip:live — reap: @44 is live","exit":3,"stderr1":"reap: @44 is live or could not be checked (young: 120s < 1800s) — leaving window and worktree alone","token":"skip:live"}}}'
reap issue-9 --yes
st_count; [ "$OUT" = skip:live ] && [ "$RC" = 3 ] || st_miss "B: skip:live 3" "$OUT rc=$RC"
st_count; case "$ERR" in *"young: 120s < 1800s"*) ;; *) st_miss "B: the node's stderr1 is the reason here" "$ERR" ;; esac

answer '{'"$OP"',"status":"failed","result":{"error":{"code":"INVALID_STATE","message":"Reap refused on the fleet: refused:no-issue — reap: not an issue row","exit":4,"stderr1":"reap: not an issue row","token":"refused:no-issue"}}}'
reap issue-9 --yes
st_count; [ "$OUT" = refused:no-issue ] && [ "$RC" = 4 ] || st_miss "B: refused:* 4" "$OUT rc=$RC"

# an older node: no exit/stderr1/token, only the message
answer '{'"$OP"',"status":"failed","result":{"error":{"code":"INVALID_STATE","message":"Reap refused on the fleet: skip:live — reap: @44 is live or could not be checked (working)"}}}'
reap issue-9 --yes
st_count; [ "$OUT" = skip:live ] && [ "$RC" = 3 ] || st_miss "B: an older node's message is read for its token" "$OUT rc=$RC"
answer '{'"$OP"',"status":"failed","result":{"error":{"code":"NOT_FOUND","message":"No live worker holds this identity on the fleet"}}}'
reap issue-9 --yes
st_count; [ "$OUT" = refused:no-target ] && [ "$RC" = 4 ] || st_miss "B: NOT_FOUND → refused:no-target 4" "$OUT rc=$RC"

answer '{'"$OP"',"status":"unknown","result":{"error":{"code":"UNKNOWN_OUTCOME","message":"Reap did not confirm: failed:kill-window","exit":5,"stderr1":"no detail","token":"failed:kill-window"}}}'
reap issue-9 --yes
st_count; [ "$OUT" = failed:kill-window ] && [ "$RC" = 5 ] || st_miss "B: unknown → failed:* 5" "$OUT rc=$RC"
st_count; case "$ERR" in *"not counted as reaped"*) ;; *) st_miss "B: unknown is said to be not a reap" "$ERR" ;; esac
answer '{'"$OP"',"status":"running"}'
FLEET_REAP_HUB_WAIT=2 reap issue-9 --yes
st_count; [ "$OUT" = failed:unconfirmed ] && [ "$RC" = 5 ] || st_miss "B: still running after the wait → failed:unconfirmed 5" "$OUT rc=$RC"

answer '{"error":{"code":"FORBIDDEN","message":"worker:reap is outside this caller"}}'
reap issue-9 --yes
st_count; [ "$OUT" = refused:hub ] && [ "$RC" = 4 ] || st_miss "B: the hub refusing → refused:hub 4" "$OUT rc=$RC"
st_count; case "$ERR" in *FORBIDDEN*) ;; *) st_miss "B: the hub's refusal is on stderr" "$ERR" ;; esac
rm -f "$FLEET_CONF_DIR/answer"
reap issue-9 --yes
st_count; [ "$OUT" = refused:hub ] && [ "$RC" = 4 ] || st_miss "B: no answer → refused:hub 4" "$OUT rc=$RC"

# --- D: local keys and the node's own adapter stay local ----------------------------
n=$(nwrites)
FLEET_REAP_MIN_AGE=999999 reap issue-7 --yes
st_count; [ "$(nwrites)" = "$n" ] || st_miss "D: a key live here (even if the map also names it) never goes to the hub"
st_count; case "$OUT" in reaped:*|skip:*|refused:*|failed:*) ;; *) st_miss "D: the local reap answered with a token" "$OUT" ;; esac
FLEET_REAP_LOCAL=1 reap issue-9 --yes
st_count; [ "$OUT" = refused:target ] && [ "$(nwrites)" = "$n" ] || st_miss "D: FLEET_REAP_LOCAL=1 refuses here, never the hub" "$OUT"
unset CCQUOTA_FLEET
printf 'CCQUOTA_FLEET=1\n' >> "$CONF"
answer '{'"$OP"',"status":"succeeded","result":{"how":"reaped:full","token":"reaped:full","exit":0}}'
reap issue-9 --yes
st_count; [ "$OUT" = reaped:full ] && [ "$(nwrites)" = $((n + 1)) ] || st_miss "D: the fleet conf's CCQUOTA_FLEET=1 turns the branch on" "$OUT rc=$RC $ERR"

# --- E: the sidebar's remote 回收 --------------------------------------------------
# the sidebar's own cache lives under $TMPDIR (FLEET_C): a sandbox one
SBT="$WORK/tmp"; G="$SBT/.claude-dash/global"; mkdir -p "$G"
printf '#ts\037%s\nwid:%s/issue-9\037mac-a\037\037\037\037\037\037issue-9\037\037\n' "$(date +%s)" "$MAC_A" > "$G/remote_$L"
date +%s > "$G/hub_ok"
n=$(nwrites)
TMPDIR="$SBT" TMUX="$SP,0,0" FLEET_HUB_WRITE_CMD="$STUB" CCQUOTA_FLEET=1 \
  bash "$BIN/fleet-row-remote.sh" reap "$L" "wid:$MAC_A/issue-9" >/dev/null 2>"$WORK/err"; RC=$?
st_count; [ "$RC" = 0 ] && [ "$(nwrites)" = $((n + 1)) ] && [ "$(tail -1 "$WRITES" | cut -f1)" = worker_reap ] \
  || st_miss "E: the sidebar's 回收 is one worker_reap write" "rc=$RC $(cat "$WORK/err")"

st_done
