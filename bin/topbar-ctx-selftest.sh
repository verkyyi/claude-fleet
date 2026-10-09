#!/bin/bash
# topbar-ctx-selftest.sh — 剩余 % · model · effort on the client's top line
# (issue #2717): the node only produces the measurement bus (#2431), the client's
# top line is the one place that draws it, for this machine's rows and another's
# alike, off the same fields `fleet ls` reads.
#   A. local — a real isolated tmux socket: a window with #2431's stamps comes out
#              of tmux-dashboard-rows.sh --sidebar with field 19
#              `left|band|ts|model|effort` (fields 13-18 empty before it); a
#              window with no @ctx_pct has no field 19 (byte for byte as before)
#   B. remote — fleet-hub-sessions.sh --refresh writes the cache's fields 21-25;
#              the remote row's sidebar field 19 is those five, and `fleet ls`
#              (fleet-session-cli.py bus_cache) reads the same five
#   C. the line — fleet-sidebar.py bar_record carries them into the record and
#              fleet-topbar.py draws `剩余 62% · Opus 5.5 · high` for the local
#              row and the remote one alike; a row with none draws no segment
# No gh, no network. Exit 0 = pass.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
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
fail() { printf 'selftest FAIL: %s\n' "$1" >&2; [ -n "${2:-}" ] && printf -- '--- detail ---\n%s\n' "$2" >&2; exit 1; }
eq()    { CHECKS=$((CHECKS+1)); [ "$2" = "$3" ] || fail "$1 (want '$2', got '$3')" "${4:-}"; }
strip() { LC_ALL=C sed -e $'s/\x1b\\[[0-9;]*m//g'; }
# fld <rows> <label> <k>: field k of the row labelled <label>, `-` when it has fewer
fld() { printf '%s\n' "$1" | LC_ALL=C awk -F"$US" -v n="$2" -v k="$3" '$4 == n { print (NF >= k ? $k : "-") }'; }
# row <rows> <label>: the whole row, as the sidebar splits it
row() { printf '%s\n' "$1" | LC_ALL=C awk -F"$US" -v n="$2" '$4 == n'; }

# ============================================================================
# A. a local window's stamps → field 19
# ============================================================================
T() { "$REAL_TMUX" -L "$S" "$@"; }
T -f /dev/null new-session -d -s "$S" -n home 'sleep 600' || fail "A: could not start the isolated server"
T new-window -d -t "=$S:" -n measured 'sleep 600'
T new-window -d -t "=$S:" -n bare 'sleep 600'
SOCK=$(T display-message -p '#{socket_path}')
TS=$(date +%s)
T set-window-option -t "=$S:measured" @ctx_pct 38 \; set-window-option -t "=$S:measured" @ctx_left 62 \; \
  set-window-option -t "=$S:measured" @ctx_band ok \; set-window-option -t "=$S:measured" @ctx_ts "$TS" \; \
  set-window-option -t "=$S:measured" @model 'Opus 5.5' \; set-window-option -t "=$S:measured" @effort high
SIDE=$(TMUX="$SOCK,0,0" FLEET_SESSION=$S bash "$ROWS" --sidebar 2>"$WORK/err" | strip)
eq "A: a measured window's field 19" "62|ok|$TS|Opus 5.5|high" "$(fld "$SIDE" measured 19)" "$SIDE"
eq "A: …fields 13-18 empty before it" "|||||" "$(printf '%s\n' "$SIDE" | LC_ALL=C awk -F"$US" '$4 == "measured" { print $13 "|" $14 "|" $15 "|" $16 "|" $17 "|" $18 }')"
eq "A: no @ctx_pct ⇒ no field 19 (byte for byte as before)" "-" "$(fld "$SIDE" bare 19)"
LOCAL_ROW=$(row "$SIDE" measured); BARE_ROW=$(row "$SIDE" bare)

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
    return dict(worker_id=f + "/" + key, machine_name="mini2.local", os_user=me, fleet_id=f,
                fleet_name="x", availability="online", worker=w, observed_at="2026-10-09T10:00:00Z")
sessions = [s("issue-41", issue=41, name="RM", ctx_left=23, ctx_band="watch", ctx_ts=ts,
              model="Fable 5.1", effort="high"),
            s("issue-42", issue=42, name="RN")]
nodes = [dict(machine_name="mini2.local", availability="online", sessions=2, observed_at="2026-10-09T10:00:00Z", age_sec=3)]
json.dump({"machines": [], "sessions": sessions, "nodes": nodes}, open(path, "w"), ensure_ascii=False)
PY
export CCQUOTA_FLEET=1 FLEET_HUB_SESSIONS_CMD="cat '$WORK/sessions.json'" FLEET_NODE_ALIASES="mini2=m4"
bash "$HUBS" --refresh 2>"$WORK/err" || fail "B: --refresh failed" "$(cat "$WORK/err")"
R=$(cat "$G/remote_$S" 2>/dev/null)
eq "B: the cache's fields 21-25" "23|watch|$TS|Fable 5.1|high" \
   "$(printf '%s\n' "$R" | LC_ALL=C awk -F"$US" -v w="wid:$F/issue-41" '$1 == w { print $21 "|" $22 "|" $23 "|" $24 "|" $25 }')"
printf '%s\n' "$(date +%s)" > "$G/hub_ok"
SIDE2=$(TMUX="$SOCK,0,0" FLEET_SESSION=$S bash "$ROWS" --sidebar 2>"$WORK/err" | strip)
eq "B: the remote row's field 19 is the cache's five" "23|watch|$TS|Fable 5.1|high" "$(fld "$SIDE2" RM 19)" "$SIDE2"
eq "B: a remote row the node measured nothing for has none" "-" "$(fld "$SIDE2" RN 19)"
REMOTE_ROW=$(row "$SIDE2" RM); REMOTE_BARE=$(row "$SIDE2" RN)
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
# C. the record and the line: local and remote drawn the same way
# ============================================================================
out=$(FLEET_SHELL=1 python3 - "$BIN" "$TS" "$LOCAL_ROW" "$BARE_ROW" "$REMOTE_ROW" "$REMOTE_BARE" <<'PY'
import importlib.util, sys
def load(name, path):
    spec = importlib.util.spec_from_file_location(name, sys.argv[1] + "/" + path)
    mod = importlib.util.module_from_spec(spec); spec.loader.exec_module(mod)
    return mod
sb, tb = load("sb", "fleet-sidebar.py"), load("tb", "fleet-topbar.py")
ts = int(sys.argv[2])
rows = [r.split("\x1f") for r in sys.argv[3:7]]
bad = []
def chk(what, got, want):
    if got != want:
        bad.append("%s: %r, want %r" % (what, got, want))
five = ("ctx_left", "ctx_band", "ctx_ts", "model", "effort")
for r, want, line in ((rows[0], (62, "ok", ts, "Opus 5.5", "high"), "剩余 62% · Opus 5.5 · high"),
                      (rows[2], (23, "watch", ts, "Fable 5.1", "high"), "剩余 23% · Fable 5.1 · high")):
    rec = sb.bar_record(rows, r[0])
    chk("record " + r[3], tuple(rec.get(k) for k in five), want)
    text, _ = tb.fit(rec, 150, now=ts + 30)
    if line not in text:
        bad.append("line %s: %r lacks %r" % (r[3], text, line))
for r in (rows[1], rows[3]):
    rec = sb.bar_record(rows, r[0])
    chk("record %s: no bus" % r[3], [k for k in five if k in rec], [])
    text, _ = tb.fit(rec, 150, now=ts)
    if "剩余" in text or "%" in text:
        bad.append("line %s: a segment with no bus: %r" % (r[3], text))
print("\n".join(bad) or "ok")
PY
)
eq "C: the record + the top line, local and remote alike" "ok" "$out"
CHECKS=$((CHECKS + 7))

printf 'selftest PASS: topbar-ctx — 剩余 · 模型 · effort on the client top line (%s checks, #2717)\n' "$CHECKS"
exit 0
