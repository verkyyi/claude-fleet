#!/bin/bash
# session-tokens-selftest.sh — 每个会话今天用了多少 (issue #3377, EPIC #3225 C8).
#
# The hub puts each session's pool tokens since this UTC midnight on its
# fleet_sessions row (`tokens_today`); the client carries it the same road as
# the measurement bus and draws 「今天 N」 — never a 0 when none is recorded:
#   A. the hub cache — fleet-hub-sessions.sh --refresh writes it as field 29,
#                  the empty fields before it kept (a measured bus, an ask pair);
#                  a row with none (absent, 0, not a number) is byte for byte as
#                  before
#   B. the sidebar — tmux-dashboard-rows.sh --sidebar carries it as field 19's
#                  sixth part (`left|band|ts|model|effort|tokens`), only when any;
#                  fleet-sidebar.py's ctx_of reads it as tokens_today
#   C. the top line and ⌘P — fleet-topbar.py says 「今天 123 万」 / 「1.2M today」
#                  on every width, nothing without it; fleet_view.tokens_short is
#                  the hub page's fmtCompact
# No gh, no network. Exit 0 = pass.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
ROWS="$BIN/tmux-dashboard-rows.sh"
HUBS="$BIN/fleet-hub-sessions.sh"
command -v python3 >/dev/null 2>&1 || { echo 'session-tokens selftest: python3 absent — SKIP'; exit 0; }
REAL_TMUX=$(command -v tmux || true)
WORK="$(mktemp -d "${TMPDIR:-/tmp}/sesstok-selftest.XXXXXX")" || exit 2
S="sesstok$$"
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
fail() { printf 'selftest FAIL: %s\n' "$1" >&2; [ -n "${2:-}" ] && printf -- '--- detail ---\n%s\n' "$2" >&2; exit 1; }
eq()    { CHECKS=$((CHECKS+1)); [ "$2" = "$3" ] || fail "$1 (want '$2', got '$3')" "${4:-}"; }
strip() { LC_ALL=C sed -e $'s/\x1b\\[[0-9;]*m//g'; }
# fld <rows> <label> <k>: field k of the row labelled <label>, `-` when it has fewer
fld() { printf '%s\n' "$1" | LC_ALL=C awk -F"$US" -v n="$2" -v k="$3" '$4 == n { print (NF >= k ? $k : "-") }'; }

# ============================================================================
# A. the hub cache — field 29
# ============================================================================
F=11111111-2222-3333-4444-555555555555
ME=$(id -un)
python3 - "$WORK/sessions.json" "$F" "$ME" <<'PY'
import json, sys
path, f, me = sys.argv[1:4]
def s(key, tok=None, **w):
    w.setdefault("key", key); w.setdefault("state", "working"); w.setdefault("lifecycle", "awake")
    w.setdefault("agent", "claude"); w.setdefault("repo", "acme/app")
    row = dict(worker_id=f + "/" + key, machine_name="far3377.local", os_user=me, fleet_id=f,
               fleet_name="x", availability="online", worker=w, observed_at="2026-10-06T10:00:00Z")
    if tok is not None:
        row["tokens_today"] = tok
    return row
sessions = [s("issue-41", 1234567, issue=41, name="RT"),
            s("issue-42", 555, issue=42, name="RB",
              ctx_left=40, ctx_band="ok", ctx_ts=1800000000, model="Opus 5.5", effort="high"),
            s("issue-43", 98765, issue=43, name="RQ", state="needs", needs="ask", detail="哪一个？"),
            s("issue-44", None, issue=44, name="RN"),
            s("issue-45", 0, issue=45, name="RZ"),
            s("issue-46", True, issue=46, name="RX")]
nodes = [dict(machine_name="far3377.local", availability="online", sessions=6, observed_at="2026-10-06T10:00:00Z", age_sec=3)]
json.dump({"machines": [], "sessions": sessions, "nodes": nodes}, open(path, "w"), ensure_ascii=False)
PY
export CCQUOTA_FLEET=1 FLEET_HUB_SESSIONS_CMD="cat '$WORK/sessions.json'" FLEET_NODE_ALIASES="far3377=m4"
bash "$HUBS" --refresh 2>"$WORK/err" || fail "A: --refresh failed" "$(cat "$WORK/err")"
R=$(cat "$G/remote_$S" 2>/dev/null)
crow() { printf '%s\n' "$R" | LC_ALL=C awk -F"$US" -v w="wid:$F/$1" '$1 == w { print NF "|" $21 "|" $27 "|" $29 }'; }
eq "A: tokens alone — field 29, the empty ones before it kept" "29|||1234567" "$(crow issue-41)"
eq "A: beside a measured bus, the bus is kept" "29|40||555" "$(crow issue-42)"
eq "A: beside an ask pair, the pair is kept" "29||question|98765" "$(crow issue-43)"
eq "A: none recorded — no field (byte for byte as before)" "16|||" "$(crow issue-44)"
eq "A: a 0 is none" "16|||" "$(crow issue-45)"
eq "A: not a number is none" "16|||" "$(crow issue-46)"

# ============================================================================
# B. the sidebar — field 19's sixth part
# ============================================================================
if [ -n "$REAL_TMUX" ]; then
  T() { "$REAL_TMUX" -L "$S" "$@"; }
  T -f /dev/null new-session -d -s "$S" -n home 'sleep 600' || fail "B: could not start the isolated server"
  SOCK=$(T display-message -p '#{socket_path}')
  date +%s > "$G/hub_ok"
  SIDE=$(TMUX="$SOCK,0,0" FLEET_SESSION=$S bash "$ROWS" --sidebar 2>"$WORK/err" | strip)
  eq "B: tokens alone ride field 19 as its sixth part" "|||||1234567" "$(fld "$SIDE" RT 19)" "$SIDE"
  eq "B: …after a measured bus" "40|ok|1800000000|Opus 5.5|high|555" "$(fld "$SIDE" RB 19)"
  eq "B: none recorded — no field 19" "-" "$(fld "$SIDE" RN 19)"
else
  echo 'session-tokens selftest: tmux absent — leg B skipped'
fi
out=$(python3 - "$BIN" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("sb", sys.argv[1] + "/fleet-sidebar.py")
sb = importlib.util.module_from_spec(spec); spec.loader.exec_module(sb)
assert sb.ctx_of("|||||1234567") == {"tokens_today": 1234567}, sb.ctx_of("|||||1234567")
assert sb.ctx_of("40|ok|1800000000|Opus 5.5|high|555")["tokens_today"] == 555
assert "tokens_today" not in sb.ctx_of("40|ok|1800000000|Opus 5.5|high")
assert "tokens_today" not in sb.ctx_of("40|ok|1800000000|Opus 5.5|high|0")
assert sb.ctx_of("") == {}
print("ok")
PY
)
eq "B: ctx_of reads tokens_today, none from a five-part or 0 field" "ok" "$out"

# ============================================================================
# C. the top line and ⌘P
# ============================================================================
REC="$WORK/rec.json"
printf '%s' '{"i":1,"n":2,"state":"working","key":"#41","title":"会话用量","pr":"","node":"m4","ctx_left":62,"ctx_band":"ok","ctx_ts":9999999999,"model":"Opus 5.5","effort":"high","tokens_today":1234567}' > "$REC"
for c in 45 100 160; do
  line=$(FLEET_UI_LANG=zh python3 "$BIN/fleet-topbar.py" fit "$c" "$REC")
  case "$line" in *"今天 123 万"*) CHECKS=$((CHECKS+1)) ;; *) fail "C: the top line at $c columns says 今天 123 万" "$line" ;; esac
done
line=$(FLEET_UI_LANG=en python3 "$BIN/fleet-topbar.py" fit 100 "$REC")
case "$line" in *"1.2M today"*) CHECKS=$((CHECKS+1)) ;; *) fail "C: en says 1.2M today" "$line" ;; esac
printf '%s' '{"i":1,"n":2,"state":"working","key":"#41","title":"会话用量","pr":"","node":"m4","ctx_left":62}' > "$REC"
line=$(python3 "$BIN/fleet-topbar.py" fit 160 "$REC")
case "$line" in *今天*) fail "C: no tokens_today, but the line says 今天" "$line" ;; *) CHECKS=$((CHECKS+1)) ;; esac
out=$(python3 - "$BIN" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
import fleet_view as FV
want = {"zh": {999: "999", 12345: "1.23 万", 100000: "10 万", 1234567: "123 万", 123456789: "1.23 亿"},
        "en": {999: "999", 12345: "12.3k", 1234567: "1.2M", 2345678901: "2.35B"}}
for lang, cases in want.items():
    FV._WORDS.clear(); FV._WORDS.update({"view_tok_style": lang, "_": ""})
    for n, w in cases.items():
        assert FV.tokens_short(n) == w, (lang, n, FV.tokens_short(n), w)
print("ok")
PY
)
eq "C: tokens_short prints as the hub page's fmtCompact" "ok" "$out"
eq "C: the ⌘P row's phrase (zh)" "今天 1.23 万 token" "$(FLEET_UI_LANG=zh sh "$BIN/fleet-ui-lang.sh" t view_today_fmt '1.23 万')"
eq "C: the ⌘P row's phrase (en)" "1.2M tokens today" "$(FLEET_UI_LANG=en sh "$BIN/fleet-ui-lang.sh" t view_today_fmt 1.2M)"

printf 'selftest PASS: session-tokens — 每个会话今天用了多少 on the hub cache, the sidebar, the top line and ⌘P (%s checks, #3377)\n' "$CHECKS"
exit 0
