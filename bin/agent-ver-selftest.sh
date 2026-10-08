#!/bin/bash
# shellcheck disable=SC1010  # `done` here is a state word handed to w(), not the keyword
# agent-ver-selftest.sh — every session can tell whether it runs the current fleet
# VERSION, apart from whether it runs the current configuration (issue #1895,
# EPIC #1906 C2).
#
# fleet-agent-team.py's fleet_ver(<root>) is the version a launch from <root> runs:
# the 12-hex sha of C1's version directory (~/.claude/fleet → fleet.versions/<sha>/),
# else the checkout's HEAD. The launcher stamps it as @agent_ver beside @agent_cfg
# (unchanged); `expected` adds a `ver <sha>` line. A session on the expected
# fingerprint but another version is `renew` = 待换新; another fingerprint stays
# `stale` = 配置旧.
#   A. fleet_ver — a version directory (bare / with a -<stamp> suffix) → its sha;
#                  a checkout → HEAD, and a commit that changes ONE bin/ script
#                  moves it; a dir inside a repo (not its top) / no git → ""
#   B. judge     — fleet_cfg_state: ok · renew (older ver, or none stamped) ·
#                  stale (another fingerprint, whatever the ver); no `ver` line
#                  expected ⇒ never renew (the degenerate: byte for byte #1783)
#   C. tick      — fleet-cfg-restart.sh --counts `<配置旧> <待换新> <会坏>` (#2076), --count both,
#                  fleet_cfg_restart_why reopens a renew one like a stale one
#   D. rows      — tmux-dashboard-rows.sh: field 13 `renew` and 待换新 on the hub
#                  list off `@agent_cfg/@agent_ver`; a remote row's `renew` verdict
#   E. sidebar   — fleet-sidebar.py draws 待换新 (narrow 换) where 配置旧 goes
#   F. inventory — fleet_hub_common.inventory_row keeps cfg=renew
# Drives fleet-agent-team.py, fleet-lib.sh, fleet-cfg-restart.sh,
# tmux-dashboard-rows.sh, fleet-sidebar.py, fleet_hub_common.py.
# Exit 0 = pass.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
ROWS="$BIN/tmux-dashboard-rows.sh"
command -v python3 >/dev/null 2>&1 || { echo 'agent-ver selftest: python3 absent — SKIP'; exit 0; }
command -v tmux >/dev/null 2>&1 || { echo 'agent-ver selftest: tmux absent — SKIP'; exit 0; }
command -v git >/dev/null 2>&1 || { echo 'agent-ver selftest: git absent — SKIP'; exit 0; }
REAL_TMUX=$(command -v tmux)
WORK="$(mktemp -d "${TMPDIR:-/tmp}/agentver-selftest.XXXXXX")" || exit 2
WORK=$(cd "$WORK" && pwd -P)
S="agver$$"
trap '"$REAL_TMUX" -L "$S" kill-server 2>/dev/null; rm -rf "$WORK"' EXIT INT TERM
unset CCQUOTA_FLEET FLEET_DASH_ORDER TMUX TMUX_PANE FLEET_SIDEBAR_SOURCE FLEET_CFG_RESTART FLEET_CFG_RESTART_IDLE FLEET_CFG_RESTART_MAX
export TMPDIR="$WORK" FLEET_SKIP_GLOBAL_CONF=1 FLEET_CONF_DIR="$WORK/conf" FLEET_UI_LANG=zh
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
G="$WORK/.claude-dash/global"
mkdir -p "$G" "$WORK/conf/fleets/$S" "$WORK/conf/global" "$WORK/bin"
printf 'FLEET_REPO=acme/app\n' > "$WORK/conf/fleets/$S/conf"
EXP="$WORK/conf/global/agent-cfg.expected"

CHECKS=0
fail() { printf 'selftest FAIL: %s\n' "$1" >&2; [ -n "${2:-}" ] && printf -- '--- detail ---\n%s\n' "$2" >&2; exit 1; }
eq()    { CHECKS=$((CHECKS+1)); [ "$2" = "$3" ] || fail "$1 (want '$2', got '$3')" "${4:-}"; }
has()   { CHECKS=$((CHECKS+1)); case "$2" in *"$3"*) : ;; *) fail "$1 — no [$3]" "$2";; esac; }
hasnt() { CHECKS=$((CHECKS+1)); case "$2" in *"$3"*) fail "$1 — unexpected [$3]" "$2";; *) : ;; esac; }
ver() { python3 - "$BIN/fleet-agent-team.py" "$1" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("t", sys.argv[1]); m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
print(m.fleet_ver(sys.argv[2]))
PY
}

# ============================================================================
# A. fleet_ver
# ============================================================================
H40=0123456789abcdef0123456789abcdef01234567
mkdir -p "$WORK/fleet.versions/$H40" "$WORK/fleet.versions/$H40-1759000000"
ln -s "$WORK/fleet.versions/$H40" "$WORK/fleet"
eq "A: a version directory (through the ~/.claude/fleet link) → its sha" "${H40:0:12}" "$(ver "$WORK/fleet")"
eq "A: …a re-installed one (<sha>-<stamp>) → the same sha" "${H40:0:12}" "$(ver "$WORK/fleet.versions/$H40-1759000000")"
R="$WORK/repo"; mkdir -p "$R/bin" "$R/conf"
printf 'echo one\n' > "$R/bin/x.sh"; printf 'k=v\n' > "$R/conf/c"
git -C "$R" init -q && git -C "$R" add -A \
  && git -C "$R" -c user.name=t -c user.email=t@t commit -qm one || fail "A: git init"
v1=$(ver "$R")
eq "A: no versions layout — a checkout's HEAD (the degenerate)" "$(git -C "$R" rev-parse HEAD | cut -c1-12)" "$v1"
printf 'echo two\n' > "$R/bin/x.sh"
git -C "$R" -c user.name=t -c user.email=t@t commit -qam two
v2=$(ver "$R")
eq "A: one bin/ script changed → the new HEAD" "$(git -C "$R" rev-parse HEAD | cut -c1-12)" "$v2"
[ "$v1" != "$v2" ] || fail "A: the version did not move with the commit"
eq "A: a directory inside a repo (not its top) → nothing" "" "$(ver "$R/bin")"
mkdir -p "$WORK/plain"
eq "A: no git, no version directory → nothing" "" "$(ver "$WORK/plain")"

# ============================================================================
# B. judge — fleet_cfg_state
# ============================================================================
F=aaaaaaaaaaaa; FC=cccccccccccc
expected() { printf 'claude %s fleet=1\ncodex %s fleet=1\n' "$F" "$FC" > "$EXP"; [ -z "${1:-}" ] || printf 'ver %s\n' "$1" >> "$EXP"; }
st() { bash -c '. "$1/fleet-lib.sh"; fleet_cfg_expected_load; fleet_cfg_state "$2" "$3" "$4"; echo "$FCFG_STATE"' _ "$BIN" "$@"; }
expected "$v2"
eq "B: same fingerprint, same version → ok"           ok      "$(st '' "$F" "$v2")"
eq "B: same fingerprint, older version → renew"       renew   "$(st '' "$F" "$v1")"
eq "B: same fingerprint, no @agent_ver → renew"       renew   "$(st '' "$F" '')"
eq "B: another fingerprint, same version → stale"     stale   "$(st '' bbbbbbbbbbbb "$v2")"
eq "B: another fingerprint, older version → stale"    stale   "$(st '' bbbbbbbbbbbb "$v1")"
eq "B: a Codex session — its own line, the one ver"   renew   "$(st codex "$FC" "$v1")"
eq "B: no fingerprint → unknown"                      unknown "$(st '' '' "$v1")"
expected
eq "B: no ver line expected → never renew"            ok      "$(st '' "$F" "$v1")"
eq "B: …stale stays stale"                            stale   "$(st '' bbbbbbbbbbbb '')"

# ============================================================================
# C. tick — fleet-cfg-restart.sh on an isolated socket
# ============================================================================
T() { "$REAL_TMUX" -L "$S" "$@"; }
T new-session -d -s "$S" -n home -x 200 -y 50 2>/dev/null || fail "could not start an isolated tmux server"
OLDTS=$(( $(date +%s) - 3600 ))
mk() {   # <name> <fp> <ver> → window id (a Claude session, done an hour ago)
  local id; id=$(T new-window -d -t "$S:" -n "$1" -P -F '#{window_id}' 'sleep 600')
  T set-option -w -t "$id" @claude_state done; T set-option -w -t "$id" @claude_state_ts "$OLDTS"
  T set-option -w -t "$id" @agent_cfg "$2"
  [ -n "$3" ] && T set-option -w -t "$id" @agent_ver "$3"
  printf '%s' "$id"
}
WCUR=$(mk current "$F" "$v2")
WREN=$(mk oldver "$F" "$v1")
WNOV=$(mk nover "$F" '')
WSTA=$(mk oldcfg bbbbbbbbbbbb "$v2")
WBOTH=$(mk both bbbbbbbbbbbb "$v1")
FAKE="$WORK/fake-migrate.sh"; printf '#!/bin/sh\nexit 0\n' > "$FAKE"; chmod +x "$FAKE"
tick() { FLEET_CFG_RESTART_MIGRATE="$FAKE" bash "$BIN/fleet-cfg-restart.sh" "$@" -- "$S" 2>&1; }
why() { bash -c '. "$1/fleet-lib.sh"; fleet_cfg_restart_why "$2" "$3"; echo "rc=$?"' _ "$BIN" "$S" "$1" 2>/dev/null | tr '\n' ' ' | sed 's/ $//'; }
expected "$v2"
eq "C: --counts — 配置旧 2 · 待换新 2 · 会坏 0" "2 2 0" "$(tick --counts)"
eq "C: --count — both kinds" "4" "$(tick --count)"
eq "C: a renew session, done + idle → reopened like a stale one" "rc=0" "$(why "$WREN")"
eq "C: …one with no @agent_ver too" "rc=0" "$(why "$WNOV")"
eq "C: the current one → nothing" "ok rc=1" "$(why "$WCUR")"
l=$(tick --list)
has "C: --list names the renew one" "$l" "$WREN	oldver	reopen"
hasnt "C: …never the current one" "$l" "$WCUR"
expected
eq "C: no ver line — only 配置旧 counts (the degenerate)" "2 0 0" "$(tick --counts)"
eq "C: …the renew one is ok again" "ok rc=1" "$(why "$WREN")"
: "$WSTA$WBOTH"

# ============================================================================
# D. rows — a PATH-shimmed tmux replays a fixture window list
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
# The 27 WFMT fields (cfg-stale-selftest's), the last `@agent_cfg[/@agent_ver]`.
w() { printf '%s\n' "$S$US$1$US$2$US/w/app-$2${US}done$US$US$3$US$US$US$US$4$US$US$US$US$US$US$US$US$US$US$US$US$US$US$US${1}000$US$5" >> "$WLIST_FILE"; }
strip() { LC_ALL=C sed -e $'s/\x1b\\[[0-9;]*m//g'; }
side() { PATH="$SHIMPATH" FLEET_SESSION=$S bash "$ROWS" --sidebar 2>/dev/null | strip; }
hub()  { PATH="$SHIMPATH" FLEET_SESSION=$S FZF_COLUMNS=160 bash "$ROWS" 2>/dev/null | strip; }
f13()  { printf '%s\n' "$1" | LC_ALL=C awk -F"$US" -v n="$2" '$4 == n { print (NF >= 13 ? $13 : "-") }'; }
: > "$WLIST_FILE"
w 1 CUR @1 '' "$F/$v2"
w 2 REN @2 '' "$F/$v1"
w 3 NOV @3 '' "$F"
w 4 STA @4 '' "bbbbbbbbbbbb/$v2"
expected
s0=$(side)
expected "$v2"
s=$(side); h=$(hub)
eq "D: current fingerprint + version → ok" ok "$(f13 "$s" CUR)"
eq "D: older version → renew" renew "$(f13 "$s" REN)"
eq "D: no @agent_ver → renew" renew "$(f13 "$s" NOV)"
eq "D: another fingerprint → stale" stale "$(f13 "$s" STA)"
has "D: the hub list marks the renew row 待换新" "$(printf '%s\n' "$h" | grep REN)" "待换新"
hasnt "D: …not 配置旧" "$(printf '%s\n' "$h" | grep REN)" "配置旧"
has "D: …and the stale row 配置旧" "$(printf '%s\n' "$h" | grep STA)" "配置旧"
hasnt "D: …the current one neither" "$(printf '%s\n' "$h" | grep CUR)" "待换新"
eq "D: no ver line — the renew row is ok (as before #1895)" ok "$(f13 "$s0" REN)"
export CCQUOTA_FLEET=1
NOW=$(date +%s); FID=11111111-2222-3333-4444-555555555555
printf '%s\n' "$NOW" > "$G/hub_ok"
{ printf '#ts\037%s\n#me\037m5\n#node\037m4\037online\0372\037%s\n' "$NOW" "$NOW"
  printf 'wid:%s/issue-7\037m4\037online\037\037acme/app\037done\037claude\037RR\037\037\0370\037\037hub\037\0371759000000\037renew\n' "$FID"
} > "$G/remote_$S"
eq "D: a remote row takes its machine's verdict — renew" renew "$(f13 "$(side)" RR)"
rm -f "$G/remote_$S" "$G/hub_ok"; unset CCQUOTA_FLEET

# ============================================================================
# E. sidebar — 待换新 where 配置旧 goes: the bar (issue #2305)
# ============================================================================
out=$(FLEET_SIDEBAR_HOST="MacBookPro.local" FLEET_NODE_ALIASES="macmini=m5 mini2=m4" \
  python3 - "$BIN/fleet-sidebar.py" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("sb", sys.argv[1]); m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
row = ["@1", "done", "✓", "worker-one", " ", "", "0", "", "m4", "", "", ""]
assert m.cfg_tag("renew") == "待换新", m.cfg_tag("renew")
assert m.detail_line(row + ["renew"]) == "worker-one · @m4 · 待换新", m.detail_line(row + ["renew"])
assert m.detail_line(row[:8] + [""] + row[9:] + ["renew"]) == "worker-one · 待换新"
assert m.detail_line(row + ["stale"]).endswith("· 配置旧")
assert m.row_glyph(row + ["renew"]) == ("✓", "") and m.row_need(row + ["renew"]) == m.row_need(row)
print("ok")
PY
)
eq "E: sidebar layout" "ok" "$out"

# ============================================================================
# F. inventory — cfg=renew survives the adapter
# ============================================================================
out=$(python3 - "$BIN" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
from fleet_hub_common import inventory_row
base = ["@1", "7", "", "/w", "done", "", "", "", "", "nm", "", "", "11111111-2222-3333-4444-555555555555"]
p, x = inventory_row(base + ["busy=", "born=1759000010", "cfg=renew"])
assert x["cfg"] == "renew", x
print("ok")
PY
)
eq "F: inventory_row keeps cfg=renew" "ok" "$out"

printf 'agent-ver selftest: PASS (%s checks)\n' "$CHECKS"
