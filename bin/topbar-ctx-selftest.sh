#!/bin/bash
# topbar-ctx-selftest.sh — 剩余 % · model · effort on the client's top line
# (issue #2717): the node only produces the measurement bus (#2431), the client's
# top line is the one place that draws it, for this machine's rows and another's
# alike, off the same fields `fleet ls` reads.
#   A. local — a real isolated tmux socket: a window with #2431's stamps comes out
#              of tmux-dashboard-rows.sh --rows with field 19
#              `left|band|ts|model|effort` (fields 13-18 empty before it); a
#              window with no @ctx_pct has no field 19 (byte for byte as before)
#   B. remote — fleet-hub-sessions.sh --refresh writes the cache's fields 21-25;
#              the remote row's sidebar field 19 is those five, and `fleet ls`
#              (fleet-session-cli.py bus_cache) reads the same five
#   (C/D — the old client's record off its sidebar and its switch-bar.json —
#   went with that client, issue #3008.)
# No gh, no network. Exit 0 = pass.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
. "$BIN/selftest-lib.sh"
ROWS="$BIN/tmux-dashboard-rows.sh"
HUBS="$BIN/fleet-hub-sessions.sh"
command -v python3 >/dev/null 2>&1 || { echo 'topbar-ctx selftest: python3 absent — SKIP'; exit 0; }
REAL_TMUX=$(command -v tmux || true)
[ -n "$REAL_TMUX" ] || { echo 'topbar-ctx selftest: tmux absent — SKIP'; exit 0; }
WORK="$(mktemp -d "${TMPDIR:-/tmp}/topbarctx-selftest.XXXXXX")" || exit 2
S="tbctx$$"
cleanup() { "$REAL_TMUX" -L "$S" kill-server 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT INT TERM
unset CCQUOTA_FLEET CCQUOTA_HUB_URL CCQUOTA_VIEWER_TOKEN FLEET_HUB_SESSIONS_CMD FLEET_NODE_ALIASES \
      FLEET_HUB_SESSIONS_USER FLEET_HUB_SESSIONS_STALE FLEET_DASH_ORDER TMUX TMUX_PANE FLEET_HUB_URL \
      FLEET_SIDEBAR_SOURCE XDG_CONFIG_HOME FLEET_SESSION_CLI_CACHE
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

# ============================================================================
# A. a local window's stamps → field 19
# ============================================================================
T() { "$REAL_TMUX" -L "$S" "$@"; }
T -f /dev/null new-session -d -s "$S" -n home 'sleep 600' || st_fail "A: could not start the isolated server"
T new-window -d -t "=$S:" -n measured 'sleep 600'
T new-window -d -t "=$S:" -n bare 'sleep 600'
SOCK=$(T display-message -p '#{socket_path}')
TS=$(date +%s)
T set-window-option -t "=$S:measured" @ctx_pct 38 \; set-window-option -t "=$S:measured" @ctx_left 62 \; \
  set-window-option -t "=$S:measured" @ctx_band ok \; set-window-option -t "=$S:measured" @ctx_ts "$TS" \; \
  set-window-option -t "=$S:measured" @model 'Opus 5.5' \; set-window-option -t "=$S:measured" @effort high
SIDE=$(TMUX="$SOCK,0,0" FLEET_SESSION=$S bash "$ROWS" --rows 2>"$WORK/err" | strip)
eq "A: a measured window's field 19" "62|ok|$TS|Opus 5.5|high" "$(fld "$SIDE" measured 19)" "$SIDE"
eq "A: …fields 13-18 empty before it" "|||||" "$(printf '%s\n' "$SIDE" | LC_ALL=C awk -F"$US" '$4 == "measured" { print $13 "|" $14 "|" $15 "|" $16 "|" $17 "|" $18 }')"
eq "A: no @ctx_pct ⇒ no field 19 (byte for byte as before)" "-" "$(fld "$SIDE" bare 19)"

# ============================================================================
# B. a remote row: the hub cache's 21-25 → field 19, the same five `fleet ls` reads
# ============================================================================
F=11111111-2222-3333-4444-555555555555
ME=$(id -un)
python3 - "$WORK/sessions.json" "$F" "$ME" "$TS" <<'PY'
import json, sys
path, f, me, ts = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
def s(key, **w):
    w.setdefault("key", key); w.setdefault("state", "working"); w.setdefault("lifecycle", "awake")
    w.setdefault("agent", "claude"); w.setdefault("repo", "acme/app")
    return dict(worker_id=f + "/" + key, machine_name="tbctx-peer.invalid", os_user=me, fleet_id=f,
                fleet_name="x", availability="online", worker=w, observed_at="2026-10-09T10:00:00Z")
sessions = [s("issue-41", issue=41, name="RM", ctx_left=23, ctx_band="watch", ctx_ts=ts,
              model="Fable 5.1", effort="high"),
            s("issue-42", issue=42, name="RN")]
nodes = [dict(machine_name="tbctx-peer.invalid", availability="online", sessions=2, observed_at="2026-10-09T10:00:00Z", age_sec=3)]
json.dump({"machines": [], "sessions": sessions, "nodes": nodes}, open(path, "w"), ensure_ascii=False)
PY
export CCQUOTA_FLEET=1 FLEET_HUB_SESSIONS_CMD="cat '$WORK/sessions.json'" FLEET_NODE_ALIASES="tbctx-peer=mac-a"
bash "$HUBS" --refresh 2>"$WORK/err" || st_fail "B: --refresh failed" "$(cat "$WORK/err")"
R=$(cat "$G/remote_$S" 2>/dev/null)
eq "B: the cache's fields 21-25" "23|watch|$TS|Fable 5.1|high" \
   "$(printf '%s\n' "$R" | LC_ALL=C awk -F"$US" -v w="wid:$F/issue-41" '$1 == w { print $21 "|" $22 "|" $23 "|" $24 "|" $25 }')"
printf '%s\n' "$(date +%s)" > "$G/hub_ok"
SIDE2=$(TMUX="$SOCK,0,0" FLEET_SESSION=$S bash "$ROWS" --rows 2>"$WORK/err" | strip)
eq "B: the remote row's field 19 is the cache's five" "23|watch|$TS|Fable 5.1|high" "$(fld "$SIDE2" RM 19)" "$SIDE2"
eq "B: a remote row the node measured nothing for has none" "-" "$(fld "$SIDE2" RN 19)"
LS=$(FLEET_SESSION=$S python3 - "$BIN" "wid:$F/issue-41" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("cli", sys.argv[1] + "/fleet-session-cli.py")
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
b = m.bus_cache().get(sys.argv[2], {})
print("|".join(b.get(k, "") for k in ("left", "band", "ts", "model", "effort")))
PY
)
eq "B: fleet ls reads the same five" "23|watch|$TS|Fable 5.1|high" "$LS"

# ============================================================================
# E. the 看台's line says THIS session only (issue #3194, overriding #3184's
#    additions): no 「! N 个在等你」 for other sessions, no 会坏·需重开 — both
#    are the panel's
# ============================================================================
mkdir -p "$WORK/cfgc/remote-views" "$WORK/cfgc/global"
# fleet-hub-sessions.sh's columns: 1 wid · 2 node · 3 online|lost · 4 issue · 5 repo · 6 state
row() { printf 'wid:%s/%s\037mac-b\037%s\037\037\037%s\037claude\n' "$F" "$1" "$2" "$3"; }
{ row issue-1 online needs; row issue-2 online needs; row issue-3 lost needs; row issue-4 online working; } > "$G/remote_$S-wait"
printf '%s\t@7\tabc\thook gone\n' "$S-wait" > "$WORK/cfgc/global/agent-cfg.broken"
out=$(FLEET_UI_LANG=zh python3 - "$BIN" "$G" "$S" "$WORK/cfgc/remote-views" <<'PY2'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("tb", sys.argv[1] + "/fleet-topbar.py")
tb = importlib.util.module_from_spec(spec); spec.loader.exec_module(tb)
g, s, reg = sys.argv[2:5]
bad = []
def chk(what, got, want):
    if got != want:
        bad.append("%s: %r, want %r" % (what, got, want))
for w in ("@9", "@7"):
    rec, down, rr, via = tb.node_record({"g": g, "s": s + "-wait", "w": w, "reg": reg})
    text = tb.fit(rec, 150, down, rr)[0]
    chk("%s: no count of other sessions" % w, ("在等你" in text, "waiting" in rec), (False, False))
    chk("%s: no 会坏·需重开 (the panel's)" % w, "会坏" in text, False)
    chk("%s: no ‹ i/n ›" % w, "‹" in text, False)
print("\n".join(bad) or "ok")
PY2
)
eq "E: the 看台's line says this session only" "ok" "$out"
CHECKS=$((CHECKS + 6))

printf 'selftest PASS: topbar-ctx — 剩余 · 模型 · effort on the client top line (%s checks, #2717)\n' "$CHECKS"
exit 0
