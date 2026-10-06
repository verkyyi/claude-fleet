#!/bin/bash
# shellcheck disable=SC1010  # `done` here is a state word handed to w(), not the keyword
# cfg-stale-selftest.sh — a session on an old configuration is visible, and is
# reopened once idle (issue #1783, EPIC #1776 C7).
#
# @agent_cfg (stamped at launch, #1782) against $FLEET_CONF_DIR/global/agent-cfg.expected:
#   A. rows      — tmux-dashboard-rows.sh: a stale row carries field 13 `stale` and
#                  the hub list's 配置旧, a current one `ok` and no mark; no
#                  fingerprint / no expected file ⇒ no field 13 (byte for byte as
#                  before); a Codex row compares against the codex line; another
#                  machine's row takes its cache verdict (field 16)
#   B. sidebar   — fleet-sidebar.py: 配置旧 left of the @ mark, narrow 旧, cfg_part,
#                  row_need; ok / unknown ⇒ the row is exactly as before
#   C. judge     — fleet_cfg_restart_why on an isolated tmux socket: only a stale,
#                  `done`, idle ≥ FLEET_CFG_RESTART_IDLE session qualifies — a
#                  Codex one alike (issue #1896); working / needs / looping /
#                  recent / ok / unknown never
#   D. tick      — fleet-cfg-restart.sh (fleet-migrate.sh faked): auto hands the
#                  eligible window to `--cfg-stale`, never the working one, at most
#                  FLEET_CFG_RESTART_MAX, the Codex one on a later tick, not again
#                  within the idle span; off /
#                  ask reopen nothing (ask marks @cfg_asked); --count / --list
#   E. history   — fleet-history.sh resumed --reason cfg-stale: one `reason=cfg-stale`
#                  row after a closed-unlanded one, after the hook's own resumed one,
#                  or built from --key/--worktree/--title; hidden from every listing
#   F. inventory — fleet_hub_common.inventory_row parses `cfg=`; without it, none
#   G. degenerate— no expected file: --count 0, nothing reopened
# Exit 0 = pass.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
ROWS="$BIN/tmux-dashboard-rows.sh"
command -v python3 >/dev/null 2>&1 || { echo 'cfg-stale selftest: python3 absent — SKIP'; exit 0; }
command -v tmux >/dev/null 2>&1 || { echo 'cfg-stale selftest: tmux absent — SKIP'; exit 0; }
REAL_TMUX=$(command -v tmux)
WORK="$(mktemp -d "${TMPDIR:-/tmp}/cfgstale-selftest.XXXXXX")" || exit 2
S="cfgst$$"
trap '"$REAL_TMUX" -L "$S" kill-server 2>/dev/null; rm -rf "$WORK"' EXIT INT TERM
unset CCQUOTA_FLEET FLEET_DASH_ORDER TMUX TMUX_PANE FLEET_SIDEBAR_SOURCE FLEET_CFG_RESTART FLEET_CFG_RESTART_IDLE FLEET_CFG_RESTART_MAX
export TMPDIR="$WORK" FLEET_SKIP_GLOBAL_CONF=1 FLEET_CONF_DIR="$WORK/conf" FLEET_UI_LANG=zh
G="$WORK/.claude-dash/global"
mkdir -p "$G" "$WORK/conf/fleets/$S" "$WORK/conf/global" "$WORK/bin"
printf 'FLEET_REPO=acme/app\n' > "$WORK/conf/fleets/$S/conf"
EXP="$WORK/conf/global/agent-cfg.expected"
expected() { printf 'claude aaaaaaaaaaaa fleet=1\ncodex cccccccccccc fleet=1\n' > "$EXP"; }

CHECKS=0
fail() { printf 'selftest FAIL: %s\n' "$1" >&2; [ -n "${2:-}" ] && printf -- '--- detail ---\n%s\n' "$2" >&2; exit 1; }
eq()    { CHECKS=$((CHECKS+1)); [ "$2" = "$3" ] || fail "$1 (want '$2', got '$3')" "${4:-}"; }
has()   { CHECKS=$((CHECKS+1)); case "$2" in *"$3"*) : ;; *) fail "$1 — no [$3]" "$2";; esac; }
hasnt() { CHECKS=$((CHECKS+1)); case "$2" in *"$3"*) fail "$1 — unexpected [$3]" "$2";; *) : ;; esac; }

# ============================================================================
# A. rows — a PATH-shimmed tmux replays a fixture window list
# ============================================================================
US=$'\x1f'
cat > "$WORK/bin/tmux" <<'SHIM'
#!/bin/sh
US=$(printf '\037'); lw=0; fmt=0
for a in "$@"; do [ "$a" = list-windows ] && lw=1; case "$a" in *"$US"*) fmt=1 ;; esac; done
[ "$lw" = 1 ] && [ "$fmt" = 1 ] && cat "$WLIST_FILE"
exit 0
SHIM
chmod +x "$WORK/bin/tmux"
export WLIST_FILE="$WORK/wlist"
SHIMPATH="$WORK/bin:$PATH"
# The 27 WFMT fields — the 26 of dash-born-order-selftest, then @agent_cfg.
# w <idx> <name> <wid> <agent> <fp>
w() { printf '%s\n' "$S$US$1$US$2$US/w/app-$2${US}done$US$US$3$US$US$US$US$4$US$US$US$US$US$US$US$US$US$US$US$US$US$US$US${1}000$US$5" >> "$WLIST_FILE"; }
strip() { LC_ALL=C sed -e $'s/\x1b\\[[0-9;]*m//g'; }
side() { PATH="$SHIMPATH" FLEET_SESSION=$S bash "$ROWS" --sidebar 2>/dev/null | strip; }
hub()  { PATH="$SHIMPATH" FLEET_SESSION=$S FZF_COLUMNS=160 bash "$ROWS" 2>/dev/null | strip; }
f13()  { printf '%s\n' "$1" | LC_ALL=C awk -F"$US" -v n="$2" '$4 == n { print (NF >= 13 ? $13 : "-") }'; }

: > "$WLIST_FILE"
w 1 OLD @1 '' bbbbbbbbbbbb
w 2 NEW @2 '' aaaaaaaaaaaa
w 3 BARE @3 '' ''
w 4 CDX @4 'codex:9_x' bbbbbbbbbbbb
w 5 CDXOK @5 'codex:9_y' cccccccccccc
rm -f "$EXP"
s0=$(side); h0=$(hub)
eq "A: no expected file — no field 13 on a stale-looking row" "-" "$(f13 "$s0" OLD)"
hasnt "A: …and no 配置旧 on the hub list" "$h0" "配置旧"
expected
s=$(side); h=$(hub)
eq "A: a fingerprint ≠ expected → field 13 stale" "stale" "$(f13 "$s" OLD)"
eq "A: a fingerprint = expected → field 13 ok" "ok" "$(f13 "$s" NEW)"
eq "A: no fingerprint → no field 13 (unknown)" "-" "$(f13 "$s" BARE)"
eq "A: a Codex row compares against the codex line (stale)" "stale" "$(f13 "$s" CDX)"
eq "A: …and is current on it" "ok" "$(f13 "$s" CDXOK)"
eq "A: the unknown row is byte for byte the no-expected-file row" \
   "$(printf '%s\n' "$s0" | grep "${US}BARE$US")" "$(printf '%s\n' "$s" | grep "${US}BARE$US")"
has "A: the hub list marks the stale row 配置旧" "$(printf '%s\n' "$h" | grep OLD)" "配置旧"
hasnt "A: …never the current one" "$(printf '%s\n' "$h" | grep 'NEW')" "配置旧"
# another machine's row: the cache's 16th field is that machine's verdict
export CCQUOTA_FLEET=1
NOW=$(date +%s); F=11111111-2222-3333-4444-555555555555
printf '%s\n' "$NOW" > "$G/hub_ok"
{ printf '#ts\037%s\n#me\037m5\n#node\037m4\037online\0372\037%s\n' "$NOW" "$NOW"
  printf 'wid:%s/issue-7\037m4\037online\037\037acme/app\037done\037claude\037RS\037\037\0370\037\037hub\037\037%s\037stale\n' "$F" "$((B=1759000000))"
  printf 'wid:%s/issue-8\037m4\037online\037\037acme/app\037done\037claude\037RO\037\037\0370\037\037hub\037\037%s\037ok\n' "$F" "$B"
  printf 'wid:%s/issue-9\037m4\037online\037\037acme/app\037done\037claude\037RN\037\037\0370\037\037hub\037\037%s\n' "$F" "$B"
} > "$G/remote_$S"
s=$(side)
eq "A: a remote row takes its machine's verdict — stale" "stale" "$(f13 "$s" RS)"
eq "A: …ok" "ok" "$(f13 "$s" RO)"
eq "A: …an older cache (no field 16): unknown" "-" "$(f13 "$s" RN)"
rm -f "$G/remote_$S" "$G/hub_ok"; unset CCQUOTA_FLEET

# ============================================================================
# B. sidebar — 配置旧 left of the @ mark
# ============================================================================
out=$(FLEET_SIDEBAR_HOST="MacBookPro.local" FLEET_NODE_ALIASES="macmini=m5 mini2=m4" \
  python3 - "$BIN/fleet-sidebar.py" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("sb", sys.argv[1]); m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
w = m.width_of
assert m.ROW_FIELDS == 14   # 14: the reap policy (#1902)
t0, g0 = m.row_layout(" ", "✓", " ", "worker-one", "", 44, "", "m4")
t1, g1 = m.row_layout(" ", "✓", " ", "worker-one", "", 44, "", "m4", "ok")
assert (t0, g0) == (t1, g1), "ok draws nothing"
t2, g2 = m.row_layout(" ", "✓", " ", "worker-one", "", 44, "", "m4", "stale")
assert g2 == "配置旧 @m4", g2
assert m.cfg_part(g2, "stale") == "配置旧"
assert w(t2) + w(g2) + 1 <= 44, (t2, g2)
t3, g3 = m.row_layout(" ", "✓", " ", "worker-one", "", 44, "", "", "stale")
assert g3 == "配置旧", g3                       # a local row: no @ mark, still 配置旧
t4, g4 = m.row_layout(" ", "✓", " ", "worker-one", "", 28, "", "m4", "stale")
assert m.cfg_part(g4, "stale") in ("旧", ""), g4  # narrow: the short word (or none)
assert m.cfg_part("@m4", "stale") == "" and m.cfg_part(g2, "ok") == ""
row = ["@1", "done", "✓", "worker-one", " ", "", "0", "", "m4", "", "", ""]
assert m.row_need(row + ["stale"]) == m.row_need(row) + w("配置旧") + 1
assert m.row_need(row + ["ok"]) == m.row_need(row)
assert m.row_fields("a\x1fb")[12] == ""
print("ok")
PY
)
eq "B: sidebar layout" "ok" "$out"

# ============================================================================
# C. judge — fleet_cfg_restart_why on an isolated socket
# ============================================================================
T() { "$REAL_TMUX" -L "$S" "$@"; }
T new-session -d -s "$S" -n home -x 200 -y 50 2>/dev/null || fail "could not start an isolated tmux server"
OLDTS=$(( $(date +%s) - 3600 ))
mk() {   # <name> <state> <fp> [agent] [ts] → window id
  local id; id=$(T new-window -d -t "$S:" -n "$1" -P -F '#{window_id}' 'sleep 600')
  T set-option -w -t "$id" @claude_state "$2"; T set-option -w -t "$id" @claude_state_ts "${5:-$OLDTS}"
  [ -n "$3" ] && T set-option -w -t "$id" @agent_cfg "$3"
  [ -n "${4:-}" ] && T set-option -w -t "$id" @cc_agent "$4"
  printf '%s' "$id"
}
WIDLE=$(mk idle done bbbbbbbbbbbb)
WWORK=$(mk busy working bbbbbbbbbbbb)
WNEED=$(mk asking needs bbbbbbbbbbbb)
WLOOP=$(mk looper looping bbbbbbbbbbbb)
WRECENT=$(mk fresh done bbbbbbbbbbbb '' "$(date +%s)")
WCDX=$(mk cdx done bbbbbbbbbbbb codex)
WOK=$(mk current done aaaaaaaaaaaa)
WNONE=$(mk nofp done '')
why() { bash -c '. "$1/fleet-lib.sh"; fleet_cfg_restart_why "$2" "$3"; echo "rc=$?"' _ "$BIN" "$S" "$1" 2>/dev/null | tr '\n' ' ' | sed 's/ $//'; }
eq "C: stale + done + idle → reopen"          "rc=0"                 "$(why "$WIDLE")"
eq "C: working → never"                        "state:working rc=1"   "$(why "$WWORK")"
eq "C: needs (a pending question) → never"     "state:needs rc=1"     "$(why "$WNEED")"
eq "C: looping → never"                        "state:looping rc=1"   "$(why "$WLOOP")"
eq "C: idle < FLEET_CFG_RESTART_IDLE → not yet" "recent rc=1"         "$(why "$WRECENT")"
eq "C: a Codex session → reopened alike (#1896)" "rc=0"                "$(why "$WCDX")"
eq "C: current configuration → nothing"        "ok rc=1"              "$(why "$WOK")"
eq "C: no fingerprint → nothing"               "unknown rc=1"         "$(why "$WNONE")"
eq "C: a panel → nothing"                      "panel rc=1"           "$(why "$(T display-message -p -t "$S:home" '#{window_id}')")"

# ============================================================================
# D. tick — fleet-cfg-restart.sh with fleet-migrate.sh faked
# ============================================================================
FAKE="$WORK/fake-migrate.sh"; MLOG="$WORK/migrate.log"
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s"\n' "$MLOG" > "$FAKE"; chmod +x "$FAKE"
tick() { FLEET_CFG_RESTART_MIGRATE="$FAKE" bash "$BIN/fleet-cfg-restart.sh" "$@" -- "$S" 2>&1; }
waitlog() { local _n; for _n in 1 2 3 4 5 6 7 8 9 10; do [ -s "$MLOG" ] && return 0; sleep 0.3; done; return 1; }
eq "D: --count — every stale session (not the current, not the bare, not a panel)" "6" "$(tick --count)"
l=$(tick --list)
has "D: --list names the reopenable one" "$l" "$WIDLE	idle	reopen"
has "D: …and why the working one is not" "$l" "$WWORK	busy	state:working"
o=$(FLEET_CFG_RESTART=off tick)
sleep 0.5
eq "D: off — nothing reopened" "" "$(cat "$MLOG" 2>/dev/null)"
o=$(FLEET_CFG_RESTART=ask tick)
has "D: ask — says so" "$o" "ask: $S:idle"
sleep 0.5
eq "D: ask — nothing reopened" "" "$(cat "$MLOG" 2>/dev/null)"
eq "D: ask — the window is marked for this fingerprint" "bbbbbbbbbbbb" "$(T display-message -p -t "$WIDLE" '#{@cfg_asked}')"
o=$(FLEET_CFG_RESTART=ask tick)
hasnt "D: ask — once per fingerprint" "$o" "ask:"
o=$(tick)
has "D: auto — reopens the idle one" "$o" "reopen: $S:idle ($WIDLE)"
waitlog || fail "D: the fake migrate never ran" "$o"
eq "D: …through fleet-migrate.sh --cfg-stale, that window only" "--cfg-stale --session $S --alert $WIDLE" "$(cat "$MLOG")"
has "D: …stamped @cfg_restart_ts" "$(T display-message -p -t "$WIDLE" '#{@cfg_restart_ts}')" "1"
: > "$MLOG"
o=$(tick)
has "D: the next tick takes the idle Codex session (#1896)" "$o" "reopen: $S:cdx ($WCDX)"
waitlog || fail "D: the fake migrate never ran for the Codex window" "$o"
eq "D: …the same --cfg-stale road" "--cfg-stale --session $S --alert $WCDX" "$(cat "$MLOG")"
: > "$MLOG"
o=$(tick)
hasnt "D: not again within the idle span" "$o" "reopen:"
WIDLE2=$(mk idle2 done bbbbbbbbbbbb); WIDLE3=$(mk idle3 done bbbbbbbbbbbb)
o=$(tick)
eq "D: FLEET_CFG_RESTART_MAX=1 — one reopen per fleet per tick" "1" "$(printf '%s\n' "$o" | grep -c '^reopen:')"
has "D: …the other waits" "$o" "later: $S:"
o=$(FLEET_CFG_RESTART_MAX=2 tick)
eq "D: …the next tick takes the rest" "1" "$(printf '%s\n' "$o" | grep -c '^reopen:')"
: "$WIDLE2$WIDLE3"

# ============================================================================
# E. history — the reopen's own row
# ============================================================================
L="$WORK/landed.tsv"
row() { printf '%s\t%s\tT\t-\t-\t/w/x\t/t\t%s\tsum\t%s\t-\n' "$1" "$2" "$3" "$4"; }
hist() { FLEET_HISTORY_LEDGER="$L" bash "$BIN/fleet-history.sh" "$@" 2>/dev/null; }
row 2026-10-06T00:00:00Z 41 sid-a closed-unlanded > "$L"
hist resumed --session-id sid-a --reason cfg-stale >/dev/null
eq "E: after a closed-unlanded row — one reason row" "resumed reason=cfg-stale" "$(tail -1 "$L" | awk -F'\t' '{print $10, $9}')"
row 2026-10-06T00:00:00Z 42 sid-b closed-unlanded > "$L"; row 2026-10-06T00:00:01Z 42 sid-b resumed >> "$L"
hist resumed --session-id sid-b >/dev/null
eq "E: without --reason, a resumed row stays the last word" "2" "$(wc -l < "$L" | tr -d ' ')"
hist resumed --session-id sid-b --reason cfg-stale >/dev/null
eq "E: with --reason, the reopen gets its row after the hook's" "3 reason=cfg-stale" "$(wc -l < "$L" | tr -d ' ') $(tail -1 "$L" | cut -f9)"
: > "$L"
hist resumed --session-id sid-c --reason cfg-stale --key x:issue-43 --worktree /w/y --title 'W 43' >/dev/null
eq "E: no row yet — built from --key/--worktree/--title" "43 W 43 /w/y sid-c reason=cfg-stale resumed" \
   "$(awk -F'\t' '{print $2, $3, $6, $8, $9, $10}' "$L")"
row 2026-10-06T00:00:00Z 44 sid-d closed-unlanded >> "$L"
hasnt "E: the reopen row is hidden from the list" "$(hist list)" "W 43"

# ============================================================================
# F. inventory — the adapter's cfg= column
# ============================================================================
out=$(python3 - "$BIN" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
from fleet_hub_common import inventory_row
base = ["@1", "7", "", "/w", "done", "", "", "", "", "nm", "", "", "11111111-2222-3333-4444-555555555555"]
p, x = inventory_row(base + ["busy=", "born=1759000010", "cfg=stale"])
assert x["cfg"] == "stale" and x["born"] == 1759000010 and x["name"] == "nm", x
p, x = inventory_row(base + ["busy=", "born=1759000010", "cfg=unknown"])
assert x["cfg"] is None, x
p, x = inventory_row(base + ["busy=", "born=1759000010"])
assert "cfg" not in x and x["born"] == 1759000010, x
print("ok")
PY
)
eq "F: inventory_row parses cfg=" "ok" "$out"

# ============================================================================
# G. degenerate — no expected file
# ============================================================================
rm -f "$EXP"; : > "$MLOG"
eq "G: no expected file — nothing stale" "0" "$(tick --count)"
o=$(tick); sleep 0.5
eq "G: …nothing reopened" "" "$(cat "$MLOG")"

printf 'cfg-stale selftest: PASS (%s checks)\n' "$CHECKS"
