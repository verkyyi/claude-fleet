#!/bin/bash
# shellcheck disable=SC1010  # `done` here is a state word in a fixture, not the keyword
# ask-words-selftest.sh — 「在问你」带原话 (issue #2538, EPIC #2535 C3).
#
# A session that waits on you says WHAT it asks, on every surface, in its own
# words — not a bare red `!` you must open the window and scroll up to read:
#   A. 7501 → sidebar — a real isolated tmux socket: an OSC 7501
#                  `state=blocked:kind=question:msg=<b64>` record, decoded by
#                  fleet-status-7501.py and written by set-claude-state.sh
#                  --via 7501, comes out of tmux-dashboard-rows.sh --rows as
#                  fields 17-18 (question · its words); `kind=auth` stamps the
#                  `auth` subtype; a working row has no fields 17-18 (byte for
#                  byte as before)
#   C. the hub cache — fleet-hub-sessions.sh --refresh writes fields 27-28 of a
#                  needs row: the agent's own status_kind / status_msg first,
#                  else its needs subtype + detail; a row not in needs, none;
#                  the remote row's sidebar fields 17-18 follow
# No gh, no network. Exit 0 = pass.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
. "$BIN/selftest-lib.sh"
ROWS="$BIN/tmux-dashboard-rows.sh"
HUBS="$BIN/fleet-hub-sessions.sh"
command -v python3 >/dev/null 2>&1 || { echo 'ask-words selftest: python3 absent — SKIP'; exit 0; }
REAL_TMUX=$(command -v tmux || true)
WORK="$(mktemp -d "${TMPDIR:-/tmp}/askwords-selftest.XXXXXX")" || exit 2
S="askw$$"
cleanup() { [ -n "$REAL_TMUX" ] && "$REAL_TMUX" -L "$S" kill-server 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT INT TERM
unset CCQUOTA_FLEET CCQUOTA_HUB_URL CCQUOTA_VIEWER_TOKEN FLEET_HUB_SESSIONS_CMD FLEET_NODE_ALIASES \
      FLEET_HUB_SESSIONS_USER FLEET_HUB_SESSIONS_STALE FLEET_DASH_ORDER TMUX TMUX_PANE FLEET_HUB_URL \
      FLEET_SIDEBAR_SOURCE XDG_CONFIG_HOME
export TMPDIR="$WORK" FLEET_SKIP_GLOBAL_CONF=1 FLEET_CONF_DIR="$WORK/conf" FLEET_UI_LANG=zh
G="$WORK/.claude-dash/global"
mkdir -p "$G" "$WORK/conf/fleets/$S"
printf 'FLEET_REPO=acme/app\n' > "$WORK/conf/fleets/$S/conf"
printf '%s\tacme-app\tacme/app\n' "$S" > "$G/sessmap"
US=$'\x1f'

CHECKS=0
eq()    { CHECKS=$((CHECKS+1)); [ "$2" = "$3" ] || st_fail "$1 (want '$2', got '$3')" "${4:-}"; }
strip() { LC_ALL=C sed -e $'s/\x1b\\[[0-9;]*m//g'; }
# fld <rows> <label> <k>: field k of the row labelled <label>, `-` when it has fewer
fld() { printf '%s\n' "$1" | LC_ALL=C awk -F"$US" -v n="$2" -v k="$3" '$4 == n { print (NF >= k ? $k : "-") }'; }

Q='要把演练放在 mac-b 还是只在 mac-a？'
B64=$(printf '%s' "$Q" | base64 | tr -d '\n')

# ============================================================================
# A. 7501 → window → sidebar, on an isolated socket
# ============================================================================
SIDE=''
if [ -n "$REAL_TMUX" ]; then
  T() { "$REAL_TMUX" -L "$S" "$@"; }
  T -f /dev/null new-session -d -s "$S" -n home 'sleep 600' || st_fail "A: could not start the isolated server"
  T new-window -d -t "=$S:" -n asking 'sleep 600'
  T new-window -d -t "=$S:" -n login 'sleep 600'
  T new-window -d -t "=$S:" -n busy 'sleep 600'
  SOCK=$(T display-message -p '#{socket_path}')
  # the agent's own report → the argv the relay hands set-claude-state.sh
  verb() { python3 - "$BIN" "$1" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("s7501", sys.argv[1] + "/fleet-status-7501.py")
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
print("\0".join(m.claude_verb(m.decode(sys.argv[2]))), end="")
PY
  }
  stamp() {   # stamp <window> <7501 fields>
    local pane; pane=$(T display-message -p -t "=$S:$1" '#{pane_id}')
    verb "$2" | TMUX="$SOCK,0,0" TMUX_PANE="$pane" PATH="$(dirname "$REAL_TMUX"):/usr/bin:/bin" \
      xargs -0 sh "$BIN/set-claude-state.sh" --via 7501
  }
  stamp asking "state=blocked:app=claude-code:kind=question:msg=$B64"
  stamp login "state=blocked:app=claude-code:kind=auth:msg=$(printf '/login' | base64)"
  stamp busy "state=working:app=claude-code"
  eq "A: the window reads needs/ask with the question" "needs|ask|$Q" \
     "$(T display-message -p -t "=$S:asking" '#{@claude_state}|#{@claude_needs}|#{@claude_needs_detail}')"
  eq "A: kind=auth stamps its own subtype" "needs|auth" "$(T display-message -p -t "=$S:login" '#{@claude_state}|#{@claude_needs}')"
  SIDE=$(TMUX="$SOCK,0,0" FLEET_SESSION=$S bash "$ROWS" --rows 2>"$WORK/err" | strip)
  eq "A: the asking row's field 17 is its kind" "question" "$(fld "$SIDE" asking 17)"
  eq "A: …field 18 its words" "$Q" "$(fld "$SIDE" asking 18)"
  eq "A: a login request says auth" "auth|/login" "$(fld "$SIDE" login 17)|$(fld "$SIDE" login 18)"
  eq "A: …in words on field 8 (the kind's label)" "待登录" "$(fld "$SIDE" login 8)"
  eq "A: a working row has no field 17 (byte for byte as before)" "-" "$(fld "$SIDE" busy 17)"
else
  echo 'ask-words selftest: tmux absent — leg A skipped'
fi

# ============================================================================
# C. the hub cache — fields 27-28 (26 is #2505's test mark), then the remote row's 17-18
# ============================================================================
F=11111111-2222-3333-4444-555555555555
ME=$(id -un)
python3 - "$WORK/sessions.json" "$F" "$ME" <<'PY'
import json, sys
path, f, me = sys.argv[1:4]
def s(key, **w):
    w.setdefault("key", key); w.setdefault("state", "working"); w.setdefault("lifecycle", "awake")
    w.setdefault("agent", "claude"); w.setdefault("repo", "acme/app")
    return dict(worker_id=f + "/" + key, machine_name="mac-d.local", os_user=me, fleet_id=f,
                fleet_name="x", availability="online", worker=w, observed_at="2026-10-06T10:00:00Z")
sessions = [s("issue-31", issue=31, name="RQ", state="needs", needs="ask", detail="hook 的话",
              status_kind="question", status_msg="程序自报的话"),
            s("issue-32", issue=32, name="RP", state="needs", needs="perm", detail="Bash: git push"),
            s("issue-33", issue=33, name="RW", state="working", status_msg="Running tests"),
            s("issue-34", issue=34, name="RC", state="needs", needs="ask", detail="哪一个？",
              ctx_left=40, ctx_band="ok", ctx_ts=1800000000, model="Opus 5.5", effort="high")]
nodes = [dict(machine_name="mac-d.local", availability="online", sessions=4, observed_at="2026-10-06T10:00:00Z", age_sec=3)]
json.dump({"machines": [], "sessions": sessions, "nodes": nodes}, open(path, "w"), ensure_ascii=False)
PY
export CCQUOTA_FLEET=1 FLEET_HUB_SESSIONS_CMD="cat '$WORK/sessions.json'" FLEET_NODE_ALIASES="mac-d=mac-a"
bash "$HUBS" --refresh 2>"$WORK/err" || st_fail "C: --refresh failed" "$(cat "$WORK/err")"
R=$(cat "$G/remote_$S" 2>/dev/null)
crow() { printf '%s\n' "$R" | LC_ALL=C awk -F"$US" -v w="wid:$F/$1" '$1 == w { print NF "|" $21 "|" $27 "|" $28 }'; }
eq "C: the agent's own report wins over the hook's words" "28||question|程序自报的话" "$(crow issue-31)"
eq "C: no report — the needs subtype + detail" "28||permission|Bash: git push" "$(crow issue-32)"
eq "C: a row not in needs carries no words" "16|||" "$(crow issue-33)"
eq "C: beside a measured bus, the bus is kept" "28|40|question|哪一个？" "$(crow issue-34)"
if [ -n "$REAL_TMUX" ]; then
  NOW=$(date +%s); printf '%s\n' "$NOW" > "$G/hub_ok"
  S2=$(TMUX="$SOCK,0,0" FLEET_SESSION=$S bash "$ROWS" --rows 2>"$WORK/err" | strip)
  eq "C: a remote needs row's sidebar fields 17-18" "permission|Bash: git push" "$(fld "$S2" RP 17)|$(fld "$S2" RP 18)"
  eq "C: a remote working row has none" "-" "$(fld "$S2" RW 17)"
fi

printf 'selftest PASS: ask-words — 「在问你」带原话 on the sidebar and the hub cache (%s checks, #2538)\n' "$CHECKS"
exit 0
