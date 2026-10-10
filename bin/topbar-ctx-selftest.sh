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
#   D. no row, no record (issue #2739) — a session in view that is no list row
#              (the orchestrator) gets its record off the cache, bus included; a
#              missing switch-bar.json says 「顶行无记录」 (a `null` one — the
#              writing area — does not); an unwritable XDG state dir falls back to
#              the cache dir; a failed write lands in logs/topbar.log
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
    return dict(worker_id=f + "/" + key, machine_name="tbctx-peer.invalid", os_user=me, fleet_id=f,
                fleet_name="x", availability="online", worker=w, observed_at="2026-10-09T10:00:00Z")
sessions = [s("issue-41", issue=41, name="RM", ctx_left=23, ctx_band="watch", ctx_ts=ts,
              model="Fable 5.1", effort="high"),
            s("issue-42", issue=42, name="RN")]
nodes = [dict(machine_name="tbctx-peer.invalid", availability="online", sessions=2, observed_at="2026-10-09T10:00:00Z", age_sec=3)]
json.dump({"machines": [], "sessions": sessions, "nodes": nodes}, open(path, "w"), ensure_ascii=False)
PY
export CCQUOTA_FLEET=1 FLEET_HUB_SESSIONS_CMD="cat '$WORK/sessions.json'" FLEET_NODE_ALIASES="tbctx-peer=m4"
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
# the way the sidebar reads a producer line (issue #2963: a bare split hid
# that row_fields cut field 19 off into ask_text)
rows = [sb.row_fields(r) for r in sys.argv[3:7]]
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
for r in rows:
    chk("row_fields %s: field 18 is ask_text only" % r[3], r[17], "")
# a needs row asking AND measured: 19 fields, ask_text stays its words alone
asking = sb.row_fields("\x1f".join(["wid:f/w9", "needs", "?", "asking"] + [""] * 12
                                    + ["question", "Bash: git push", "70|ok|%d|opus|xhigh" % ts]))
chk("row_fields: 19 fields", len(asking), 19)
chk("row_fields: ask_text is the words", asking[17], "Bash: git push")
rec = sb.bar_record([asking], asking[0])
chk("record asking", tuple(rec.get(k) for k in five), (70, "ok", ts, "opus", "xhigh"))
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

# ============================================================================
# D. the orchestrator (no row), a missing record, an unwritable state dir
# ============================================================================
mkdir -p "$WORK/ro" "$WORK/notdir"; : > "$WORK/notdir/f"; chmod 555 "$WORK/ro"
# the orchestrator's line in its own cache (fleet-hub-sessions.sh's columns: 1 wid ·
# 2 node · 3 online · 4 issue · … 8 name · 17 title · 21-25 the bus)
OW="wid:$F/orchestrator"
printf '%s
' "$OW${US}m5${US}online${US}${US}${US}working${US}claude${US}orchestrator${US}${US}${US}0${US}${US}hub${US}${US}${US}${US}编排${US}${US}${US}${US}23${US}watch${US}$TS${US}Fable 5.1${US}high" > "$G/remote_$S-orch"
out=$(FLEET_SHELL=1 FLEET_SIDEBAR_STALL_LOG="$WORK/logs/sidebar-stall.log" python3 - "$BIN" "$S-orch" "$OW" "$TS" "$WORK" "$LOCAL_ROW" <<'PY'
import importlib.util, os, subprocess, sys
def load(name, path):
    spec = importlib.util.spec_from_file_location(name, sys.argv[1] + "/" + path)
    mod = importlib.util.module_from_spec(spec); spec.loader.exec_module(mod)
    return mod
binp, sess, wid, ts, work = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4]), sys.argv[5]
sb = load("sb", "fleet-sidebar.py")
rows = [sys.argv[6].split("\x1f")]   # the list without the session in view
bad = []
def chk(what, got, want):
    if got != want:
        bad.append("%s: %r, want %r" % (what, got, want))
rec = sb.bar_record(rows, wid, sess)
chk("orchestrator: a record off the cache", rec is not None, True)
if rec:
    chk("orchestrator: its bus", tuple(rec.get(k) for k in ("ctx_left", "ctx_band", "ctx_ts", "model", "effort")),
        (23, "watch", ts, "Fable 5.1", "high"))
    chk("orchestrator: its machine", rec.get("node"), "m5")
    chk("orchestrator: its title", rec.get("title"), "编排")
    chk("orchestrator: no key", rec.get("key"), "")
    chk("orchestrator: its wid", rec.get("wid"), wid[4:])
chk("not cached either: none", sb.bar_record(rows, "wid:nobody/x", sess), None)
# the top line: no file says so, a `null` one is the window's name only
env = dict(os.environ, FLEET_SWITCH_STATE=os.path.join(work, "sw"), FLEET_UI_LANG="zh")
def render():
    return subprocess.run(["python3", binp + "/fleet-topbar.py", "render", "cw=120", "wn=orchestrator"],
                          env=env, capture_output=True, text=True).stdout
chk("no record: 顶行无记录", "顶行无记录" in render(), True)
os.makedirs(env["FLEET_SWITCH_STATE"], exist_ok=True)
open(os.path.join(env["FLEET_SWITCH_STATE"], "switch-bar.json"), "w").write("null\n")
out = render()
chk("a null record: the window's name, no 顶行无记录", ("orchestrator" in out, "顶行无记录" in out), (True, False))
# an unwritable XDG state dir: the cache dir instead, for writer and reader alike
q = load("q", "fleet-quickopen.py")
os.environ.pop("FLEET_SWITCH_STATE", None)
os.environ["XDG_STATE_HOME"], os.environ["XDG_CACHE_HOME"] = os.path.join(work, "ro"), os.path.join(work, "cx")
if os.geteuid() != 0:
    chk("unwritable state dir: the fallback", str(q.state_dir()), os.path.normpath(os.path.join(work, "cx", "claude-fleet", "state")))
os.environ["XDG_STATE_HOME"] = os.path.join(work, "st")
chk("a writable one: itself", str(q.state_dir()), os.path.normpath(os.path.join(work, "st", "claude-fleet")))
# a failed write is logged, once
os.environ["FLEET_SWITCH_STATE"] = os.path.join(work, "notdir", "f", "x")
sb.STAGE = "nostage"
for _ in range(2):
    sb.publish_bar(rows, rows[0][0], None)
try:
    log = open(os.path.join(work, "logs", "topbar.log")).read()
except OSError:
    log = ""
chk("a failed write: one line in topbar.log", (log.count("\n"), "switch-bar.json" in log), (1, True))
print("\n".join(bad) or "ok")
PY
)
chmod 755 "$WORK/ro"
eq "D: no row, no record, no writable dir" "ok" "$out"
CHECKS=$((CHECKS + 10))

printf 'selftest PASS: topbar-ctx — 剩余 · 模型 · effort on the client top line (%s checks, #2717)\n' "$CHECKS"
exit 0
