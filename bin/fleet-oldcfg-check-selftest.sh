#!/bin/bash
# shellcheck disable=SC1010  # `done` here is a state word handed to a helper, not the keyword
# fleet-oldcfg-check-selftest.sh — an old session is either 会坏 or merely 旧, and
# the fleet can tell which (issue #2076, EPIC #2074 C3).
#
# bin/fleet-agent-team.py `session` writes the session's START down (the hook
# table it was handed, the mod tools it registered, its MCP servers —
# $FLEET_CONF_DIR/agentcfg/<sha>.json, the window's @agent_cfg_manifest);
# bin/fleet-oldcfg-check.sh judges it against the live install with the release
# gate's own rule (fleet-oldcfg-replay.py --manifest, static); the sweep writes
# global/agent-cfg.broken, which fleet_cfg_state reads for the rows producer, the
# doctor and the idle reopen. Pinned:
#
#   A  manifest   — a Claude launch prints `manifest <path>`; the file holds the
#                   fleet's hook table, the mod's three tools, the fleet server and
#                   the fp; two launches of one start share the file; checked
#                   against its own tree it is `ok`; a Codex launch records no
#                   tools (null), never «new tools» for it
#   B  check      — a manifest naming a dropped mod tool ⇒ broken (exit 2) naming
#                   the tool; a deleted hook script ⇒ broken naming the script; a
#                   gone MCP script ⇒ broken naming the server; one that only
#                   lacks a new hook ⇒ stale (exit 1) naming the hook; identical ⇒
#                   ok (exit 0); a missing / unreadable manifest ⇒ stale + note
#   C  sweep      — on an isolated tmux socket: the broken window alone lands in
#                   agent-cfg.broken; --list names broken · looping (stale AND
#                   looping) · stale rows with window · repo · issue · state; a
#                   window with no manifest is stale, never broken (degenerate); an
#                   `ok` window is never judged; a panel / remote row is skipped;
#                   nothing is closed; exit 2 ⇔ something broken
#   D  rows       — tmux-dashboard-rows.sh: field 13 `broken` on the listed window,
#                   `stale` on the others; the hub list draws 会坏·需重开 on it and
#                   配置旧 on the stale one; no broken file ⇒ byte for byte as before
#   E  sidebar    — fleet-sidebar.py: cfg_tag broken ⇒ 会坏·需重开 (narrow 坏), red
#                   pair; cfg_part / row_need; a remote row's cfg=broken is accepted
#   F  reopen     — fleet-cfg-restart.sh --counts `<stale> <renew> <broken>`; a
#                   broken, done, idle session is reopened like a stale one
#                   (fleet_cfg_restart_why rc 0); a looping one never
#
# Hermetic: temp HOME + FLEET_CONF_DIR, a rig «new install» tree, an isolated tmux
# server. Exit 0 = pass.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$BIN/.." && pwd)"
SUT="$BIN/fleet-oldcfg-check.sh"
for f in fleet-oldcfg-check.sh fleet-oldcfg-replay.py fleet-agent-team.py fleet-lib.sh tmux-dashboard-rows.sh fleet-sidebar.py fleet-cfg-restart.sh fleet-ui-lang.sh; do
  [ -f "$BIN/$f" ] || { printf 'selftest: %s missing\n' "$BIN/$f" >&2; exit 2; }
done
command -v python3 >/dev/null 2>&1 || { echo 'fleet-oldcfg-check selftest: python3 absent — SKIP'; exit 0; }
command -v tmux >/dev/null 2>&1 || { echo 'fleet-oldcfg-check selftest: tmux absent — SKIP'; exit 0; }
REAL_TMUX=$(command -v tmux)

WORK="$(mktemp -d "${TMPDIR:-/tmp}/oldcfgchk.XXXXXX")" || exit 2
WORK="$(cd "$WORK" && pwd -P)"
S="ocg$$"
trap '"$REAL_TMUX" -L "$S" kill-server 2>/dev/null; rm -rf "$WORK"' EXIT
trap 'exit 130' INT TERM HUP
unset CCQUOTA_FLEET FLEET_DASH_ORDER TMUX TMUX_PANE FLEET_SIDEBAR_SOURCE FLEET_CFG_RESTART FLEET_CFG_RESTART_IDLE FLEET_CFG_RESTART_MAX
export TMPDIR="$WORK" FLEET_SKIP_GLOBAL_CONF=1 FLEET_CONF_DIR="$WORK/conf" FLEET_UI_LANG=zh HOME="$WORK/home"
mkdir -p "$WORK/conf/global" "$WORK/conf/fleets/$S" "$WORK/home/.claude" "$WORK/bin"
printf 'FLEET_REPO=acme/app\n' > "$WORK/conf/fleets/$S/conf"
echo '{}' > "$WORK/home/.claude/settings.json"; echo '{}' > "$WORK/home/.claude.json"
EXP="$WORK/conf/global/agent-cfg.expected"
BROKEN="$WORK/conf/global/agent-cfg.broken"

CHECKS=0
fail()  { printf 'selftest FAIL: %s\n' "$1" >&2; [ -n "${2:-}" ] && printf -- '--- detail ---\n%s\n' "$2" >&2; exit 1; }
eq()    { CHECKS=$((CHECKS+1)); [ "$2" = "$3" ] || fail "$1 (want '$2', got '$3')" "${4:-}"; }
has()   { CHECKS=$((CHECKS+1)); case "$2" in *"$3"*) : ;; *) fail "$1 — no [$3]" "$2";; esac; }
hasnt() { CHECKS=$((CHECKS+1)); case "$2" in *"$3"*) fail "$1 — unexpected [$3]" "$2";; *) : ;; esac; }

# ============================================================================
# A. the manifest a launch writes (the composer, against this repo's own tree)
# ============================================================================
compose() {   # <agent> → the composer's TSV
  python3 "$BIN/fleet-agent-team.py" session "$1" --root "$ROOT" --claude-config "$WORK/home/.claude.json" \
    --claude-settings "$WORK/home/.claude/settings.json" --codex-home "$WORK/home/.codex" \
    --override "$WORK/conf/agent-overrides.json" 2>/dev/null
}
out=$(compose claude)
M1=$(printf '%s\n' "$out" | awk -F'\t' '$1 == "manifest" { print $2 }')
FP1=$(printf '%s\n' "$out" | awk -F'\t' '$1 == "fp" { print $2 }')
[ -n "$M1" ] && [ -f "$M1" ] || fail "A: a Claude launch prints no manifest line / file" "$out"
case "$M1" in "$WORK/conf/agentcfg/"*.json) ;; *) fail "A: the manifest is not under \$FLEET_CONF_DIR/agentcfg/" "$M1" ;; esac
eq "A: the manifest records the fingerprint it was launched with" "$FP1" \
   "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["fp"])' "$M1")"
eq "A: …the mod's three tools" "mcp__fleet__fleet_await mcp__fleet__fleet_spawn mcp__fleet__fleet_status" \
   "$(python3 -c 'import json,sys; print(" ".join(sorted(json.load(open(sys.argv[1]))["tools"])))' "$M1")"
has "A: …the fleet tool service among its MCP servers" \
    "$(python3 -c 'import json,sys; print(" ".join(sorted(json.load(open(sys.argv[1]))["mcp"])))' "$M1")" "fleet"
eq "A: …the fleet hook table (every event of hooks/settings-hooks.json)" \
   "$(python3 -c 'import json,sys; print(" ".join(sorted(json.load(open(sys.argv[1]))["hooks"])))' "$ROOT/hooks/settings-hooks.json")" \
   "$(python3 -c 'import json,sys; print(" ".join(sorted(json.load(open(sys.argv[1]))["hooks"])))' "$M1")"
M2=$(compose claude | awk -F'\t' '$1 == "manifest" { print $2 }')
eq "A: two launches of one start share one manifest (content-addressed)" "$M1" "$M2"
r=$(bash "$SUT" "$M1" --new-dir "$ROOT" 2>&1); rc=$?
eq "A: checked against its own tree the launch is ok" "ok" "$(printf '%s\n' "$r" | head -1)" "$r"
eq "A: …exit 0" 0 "$rc"
MC=$(compose codex | awk -F'\t' '$1 == "manifest" { print $2 }')
[ -n "$MC" ] && [ -f "$MC" ] || fail "A: a Codex launch prints no manifest"
eq "A: a Codex session has no mod — tools null, never «new tools» for it" "None" \
   "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["tools"])' "$MC")"
eq "A: …and it is ok against its own tree too" "ok" "$(bash "$SUT" "$MC" --new-dir "$ROOT" 2>&1 | head -1)"

# ============================================================================
# B. the check — a rig «new install» and hand-written starts
# ============================================================================
NEW="$WORK/new"
mkdir -p "$NEW/bin" "$NEW/hooks" "$NEW/mod/fleet/hooks" "$NEW/conf"
printf '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"sh ~/.claude/fleet/bin/h.sh"}]}],"UserPromptSubmit":[{"hooks":[{"type":"command","command":"sh ~/.claude/fleet/bin/new.sh"}]}]}}\n' > "$NEW/hooks/settings-hooks.json"
: > "$NEW/bin/h.sh"; : > "$NEW/bin/new.sh"; : > "$NEW/bin/fleet-mcp.py"
printf "export const FALLBACK = ['status', 'spawn'] as const\nexport const TOOL_RE = /^mcp__fleet__fleet_(status|spawn)\$/\n" > "$NEW/mod/fleet/hooks/tools.ts"
printf '{"mcpServers":{"fleet":{"command":"bash","args":["-c","exec python3 $HOME/.claude/fleet/bin/fleet-mcp.py"]}}}\n' > "$NEW/conf/mcp-worker.json"
FLEETSRV='"fleet":{"command":"bash","args":["-c","exec python3 $HOME/.claude/fleet/bin/fleet-mcp.py"]}'
STOP_H='"Stop":[{"hooks":[{"type":"command","command":"sh ~/.claude/fleet/bin/h.sh"}]}]'
NEW_H='"UserPromptSubmit":[{"hooks":[{"type":"command","command":"sh ~/.claude/fleet/bin/new.sh"}]}]'
man() {   # <file> <hooks json> <tools json> <mcp json>
  printf '{"agent":"claude","fp":"OLD","hooks":{%s},"tools":%s,"mcp":{%s}}\n' "$2" "$3" "$4" > "$WORK/$1.json"
}
man ok      "$STOP_H,$NEW_H" '["mcp__fleet__fleet_status","mcp__fleet__fleet_spawn"]' "$FLEETSRV"
man stale   "$STOP_H"        '["mcp__fleet__fleet_status","mcp__fleet__fleet_spawn"]' "$FLEETSRV"
man tool    "$STOP_H,$NEW_H" '["mcp__fleet__fleet_status","mcp__fleet__fleet_spawn","mcp__fleet__fleet_await"]' "$FLEETSRV"
man hook    '"Stop":[{"hooks":[{"type":"command","command":"sh ~/.claude/fleet/bin/gone.sh"}]}]'",$NEW_H" '["mcp__fleet__fleet_status","mcp__fleet__fleet_spawn"]' "$FLEETSRV"
man mcp     "$STOP_H,$NEW_H" '["mcp__fleet__fleet_status","mcp__fleet__fleet_spawn"]' '"fleet":{"command":"bash","args":["-c","exec python3 $HOME/.claude/fleet/bin/fleet-gone.py"]}'
man nomod   "$STOP_H,$NEW_H" 'null' "$FLEETSRV"
printf 'not json' > "$WORK/junk.json"
chk() { OUT=$(bash "$SUT" "$WORK/$1.json" --new-dir "$NEW" 2>&1); RC=$?; V=$(printf '%s\n' "$OUT" | head -1); }
chk ok;    eq "B: identical ⇒ ok" ok "$V" "$OUT"; eq "B: …exit 0" 0 "$RC"
chk nomod; eq "B: no mod in the session (tools null) + the install's mod ⇒ still ok" ok "$V" "$OUT"
chk stale; eq "B: only a new hook ⇒ stale" stale "$V" "$OUT"; eq "B: …exit 1" 1 "$RC"
has "B: …naming the hook it lacks" "$OUT" "hook  changed  UserPromptSubmit"
has "B: …and the command" "$OUT" "bin/new.sh"
chk tool;  eq "B: a dropped mod tool ⇒ broken" broken "$V" "$OUT"; eq "B: …exit 2" 2 "$RC"
has "B: …naming the tool" "$OUT" "tool  MISSING  mcp__fleet__fleet_await"
has "B: …and what happens" "$OUT" "no tool.call hook answered"
chk hook;  eq "B: a deleted hook script ⇒ broken" broken "$V" "$OUT"
has "B: …naming the script" "$OUT" "bin/gone.sh not in the new tree"
chk mcp;   eq "B: a gone MCP script ⇒ broken" broken "$V" "$OUT"
has "B: …naming the server and the script" "$OUT" "mcp   MISSING  fleet"
has "B: …" "$OUT" "fleet-gone.py not in the new tree"
chk nope;  eq "B: a missing manifest ⇒ stale, never broken" stale "$V" "$OUT"; eq "B: …exit 1" 1 "$RC"
has "B: …with a note" "$OUT" "no manifest at"
chk junk;  eq "B: an unreadable manifest ⇒ stale" stale "$V" "$OUT"
has "B: …with a note" "$OUT" "is not JSON"
j=$(bash "$SUT" "$WORK/tool.json" --new-dir "$NEW" --json 2>&1)
eq "B: --json: one object with the verdict" broken "$(printf '%s\n' "$j" | python3 -c 'import json,sys; print(json.loads(sys.stdin.readline())["verdict"])')"
r=$(bash "$SUT" 2>&1); eq "B: no manifest argument ⇒ usage, exit 3" 3 "$?"; has "B: …" "$r" "usage:"

# ============================================================================
# C. the sweep — an isolated tmux server, real windows
# ============================================================================
T() { "$REAL_TMUX" -L "$S" "$@"; }
T -f /dev/null new-session -d -s "$S" -n home -x 160 -y 40 'sleep 600' || fail "could not start an isolated tmux server"
OLDTS=$(( $(date +%s) - 3600 ))
mk() {   # <name> <state> <fp> <manifest|''> <issue> → window id
  local id; id=$(T new-window -d -t "$S:" -n "$1" -P -F '#{window_id}' 'sleep 600')
  T set-option -w -t "$id" @claude_state "$2"; T set-option -w -t "$id" @claude_state_ts "$OLDTS"
  T set-option -w -t "$id" @agent_cfg "$3"; T set-option -w -t "$id" @agent_ver v2
  [ -n "$4" ] && T set-option -w -t "$id" @agent_cfg_manifest "$4"
  T set-option -w -t "$id" @issue "$5"; T set-option -w -t "$id" @repo acme/app
  printf '%s' "$id"
}
printf 'claude NEW x\ncodex CDX x\nver v2\n' > "$EXP"
WB=$(mk w-broken done OLD "$WORK/tool.json" 11)
WL=$(mk w-loop looping OLD "$WORK/stale.json" 12)
WN=$(mk w-noman done OLD '' 13)
WO=$(mk w-ok done NEW "$WORK/tool.json" 14)       # current: its manifest is never judged
WP=$(mk w-panel done OLD "$WORK/tool.json" 15); T set-option -w -t "$WP" @fleet_role panel
WR=$(mk w-remote done OLD "$WORK/tool.json" 16); T set-option -w -t "$WR" @remote m4
WS=$(mk w-stale done OLD "$WORK/stale.json" 17)
sweep() { OUT=$(bash "$SUT" --sweep "$@" --new-dir "$NEW" -- "$S" 2>&1); RC=$?; }
sweep --list
eq "C: exit 2 — something is broken" 2 "$RC" "$OUT"
has "C: --list names the broken window with window · repo · issue · state · what" "$OUT" "broken	$S	w-broken	acme/app	#11	done	tool mcp__fleet__fleet_await"
has "C: …the looping stale one as looping" "$OUT" "looping	$S	w-loop	acme/app	#12	looping	stale, in a loop"
has "C: …the idle stale one as stale" "$OUT" "stale	$S	w-stale	acme/app	#17	done	"
has "C: …a window with no manifest as stale (the degenerate)" "$OUT" "stale	$S	w-noman	acme/app	#13	done	"
hasnt "C: …never the current one" "$OUT" "w-ok"
hasnt "C: …never a panel" "$OUT" "w-panel"
hasnt "C: …never another machine's row" "$OUT" "w-remote"
hasnt "C: …and nothing but w-broken is broken" "$(printf '%s\n' "$OUT" | grep '^broken' | grep -v 'w-broken')" "broken"
eq "C: agent-cfg.broken holds exactly the broken window" "$S	$WB	tool	tool mcp__fleet__fleet_await" "$(cat "$BROKEN")"
for w in $WB $WL $WN $WO $WP $WR $WS; do
  eq "C: the sweep closed nothing ($w)" "$w" "$(T display-message -p -t "$w" '#{window_id}' 2>/dev/null)"
done
st() { bash -c '. "$1/fleet-lib.sh"; fleet_cfg_expected_load; fleet_cfg_broken_load; fleet_cfg_state claude "$2" v2 "$3" "$4"; printf "%s" "$FCFG_STATE"' _ "$BIN" "$1" "$S" "$2"; }
eq "C: fleet_cfg_state reads broken for the listed window" broken "$(st OLD "$WB")"
eq "C: …stale for the looping one" stale "$(st OLD "$WL")"
eq "C: …stale for the one with no manifest" stale "$(st OLD "$WN")"
eq "C: …ok for the current one" ok "$(st NEW "$WO")"
eq "C: …never broken without the session + window id (the old 3-arg call)" stale \
   "$(bash -c '. "$1/fleet-lib.sh"; fleet_cfg_expected_load; fleet_cfg_broken_load; fleet_cfg_state claude OLD v2; printf "%s" "$FCFG_STATE"' _ "$BIN")"
# the broken window reopened onto the new tree: the next sweep clears it
T set-option -w -t "$WB" @agent_cfg NEW
sweep
eq "C: nothing broken ⇒ exit 0" 0 "$RC" "$OUT"
eq "C: …and the file is emptied, not left stale" "" "$(cat "$BROKEN")"
T set-option -w -t "$WB" @agent_cfg OLD
sweep; eq "C: …and back" 2 "$RC"

# ============================================================================
# D. the rows producer — field 13 broken, the hub list's red word
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
# The 27 WFMT fields (cfg-stale-selftest's fixture): w <idx> <name> <wid> <agent> <fp/ver>
w() { printf '%s\n' "$S$US$1$US$2$US/w/app-$2${US}done$US$US$3$US$US$US$US$4$US$US$US$US$US$US$US$US$US$US$US$US$US$US$US${1}000$US$5" >> "$WLIST_FILE"; }
strip() { LC_ALL=C sed -e $'s/\x1b\\[[0-9;]*m//g'; }
side() { PATH="$WORK/bin:$PATH" FLEET_SESSION=$S bash "$BIN/tmux-dashboard-rows.sh" --sidebar 2>/dev/null | strip; }
hub()  { PATH="$WORK/bin:$PATH" FLEET_SESSION=$S FZF_COLUMNS=160 bash "$BIN/tmux-dashboard-rows.sh" 2>/dev/null | strip; }
f13()  { printf '%s\n' "$1" | LC_ALL=C awk -F"$US" -v n="$2" '$4 == n { print (NF >= 13 ? $13 : "-") }'; }
: > "$WLIST_FILE"
w 1 BRK "$WB" '' OLD/v2
w 2 OLD @8 '' OLD/v2
w 3 NEW @9 '' NEW/v2
s=$(side); h=$(hub)
eq "D: the listed window's field 13 is broken" broken "$(f13 "$s" BRK)"
eq "D: a stale one not on the list stays stale" stale "$(f13 "$s" OLD)"
eq "D: a current one is ok" ok "$(f13 "$s" NEW)"
has "D: the hub list draws 会坏·需重开 on the broken row" "$(printf '%s\n' "$h" | grep BRK)" "会坏·需重开"
has "D: …配置旧 on the stale one" "$(printf '%s\n' "$h" | grep OLD)" "配置旧"
hasnt "D: …never 会坏 on the stale one" "$(printf '%s\n' "$h" | grep OLD)" "会坏"
# the red: the broken row's word carries PAL_RED's escape, the stale one's PAL_YELLOW's
rawh=$(PATH="$WORK/bin:$PATH" FLEET_SESSION=$S FZF_COLUMNS=160 bash "$BIN/tmux-dashboard-rows.sh" 2>/dev/null)
red=$(bash -c '. "$1/fleet-palette.sh"; fleet_palette_load; fleet_palette_rgb "${PAL_RED:-}"; printf "%s" "$_fpr"' _ "$BIN")
yel=$(bash -c '. "$1/fleet-palette.sh"; fleet_palette_load; fleet_palette_rgb "${PAL_YELLOW:-}"; printf "%s" "$_fpr"' _ "$BIN")
if [ -n "$red" ] && [ -n "$yel" ]; then
  has "D: the broken word is painted red" "$(printf '%s\n' "$rawh" | grep BRK)" "38;2;${red}m会坏·需重开"
  has "D: the stale word is painted yellow" "$(printf '%s\n' "$rawh" | grep OLD)" "38;2;${yel}m配置旧"
fi
rm -f "$BROKEN"
s2=$(side)
eq "D: no broken file ⇒ the row is stale, byte for byte as before" stale "$(f13 "$s2" BRK)"
eq "D: …the whole sidebar frame equal to the one with an empty list" "$(: > "$BROKEN"; side)" "$s2"
rm -f "$BROKEN"

# ============================================================================
# E. the sidebar view (fleet-sidebar.py)
# ============================================================================
out=$(FLEET_SIDEBAR_HOST="MacBookPro.local" FLEET_NODE_ALIASES="macmini=m5 mini2=m4" \
  python3 - "$BIN/fleet-sidebar.py" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("sb", sys.argv[1]); m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
w = m.width_of
assert m.cfg_tag("broken") == "会坏·需重开", m.cfg_tag("broken")
assert m.cfg_tag("broken", narrow=True) == "坏"
assert m.cfg_tag("stale") == "配置旧" and m.cfg_tag("ok") == "" and m.cfg_tag("") == ""
assert "broken" in m.CFG_WORDS and "stale" in m.CFG_WORDS and "renew" in m.CFG_WORDS
assert m.cfg_pair("broken") == m.PAIR_BROKEN and m.cfg_pair("stale") == m.PAIR_STALE and m.cfg_pair("renew") == m.PAIR_STALE
assert m.PAIRS[m.PAIR_BROKEN] == ("PAL_RED", None), m.PAIRS[m.PAIR_BROKEN]
assert m.PAIRS[m.PAIR_BROKEN + m.SEL_GLYPH] == ("PAL_RED", "PAL_SEL")
assert m.PAIRS[m.PAIR_STALE] == ("PAL_YELLOW", None)
used = [p for p, v in m.PAIRS.items() if p != m.PAIR_BROKEN and p != m.PAIR_BROKEN + m.SEL_GLYPH]
assert m.PAIR_BROKEN not in used and m.PAIR_BROKEN + m.SEL_GLYPH not in used, "a pair number collides"
t2, g2 = m.row_layout(" ", "✓", " ", "worker-one", "", 44, "", "m4", "broken")
assert g2 == "会坏·需重开 @m4", g2
assert m.cfg_part(g2, "broken") == "会坏·需重开"
assert w(t2) + w(g2) + 1 <= 44, (t2, g2)
t3, g3 = m.row_layout(" ", "✓", " ", "worker-one", "", 44, "", "", "broken")
assert g3 == "会坏·需重开", g3                   # a local row: no @ mark, still the word
t4, g4 = m.row_layout(" ", "✓", " ", "worker-one", "", 26, "", "m4", "broken")
assert m.cfg_part(g4, "broken") in ("坏", ""), g4     # narrow: the short word (or none)
assert m.cfg_part("@m4", "broken") == "" and m.cfg_part(g2, "ok") == ""
row = ["@1", "done", "✓", "worker-one", " ", "", "0", "", "m4", "", "", ""]
assert m.row_need(row + ["broken"]) == m.row_need(row) + w("会坏·需重开") + 1
assert m.row_need(row + ["ok"]) == m.row_need(row)
print("E-ok")
PY
) || fail "E: sidebar assertions" "$out"
eq "E: fleet-sidebar.py draws 会坏·需重开 red for a broken row" "E-ok" "$out"
eq "E: the English word" "breaks·reopen" "$(FLEET_UI_LANG=en bash -c '. "$1/fleet-ui-lang.sh"; fleet_ui_t sidebar_cfg_broken' _ "$BIN")"
out=$(python3 - "$BIN" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
from fleet_hub_common import inventory_row
base = ["@1", "7", "", "/w", "done", "", "", "", "", "nm", "", "", "11111111-2222-3333-4444-555555555555"]
p, x = inventory_row(base + ["busy=", "born=1759000010", "cfg=broken"])
assert x["cfg"] == "broken", x
p, x = inventory_row(base + ["busy=", "born=1759000010", "cfg=stale"])
assert x["cfg"] == "stale", x
print("ok")
PY
)
eq "E: another machine's cfg=broken is kept by the inventory reader" "ok" "$out"

# ============================================================================
# F. the idle reopen (fleet-cfg-restart.sh) counts and honours broken
# ============================================================================
sweep   # the broken file back (WB on OLD again)
FAKE="$WORK/fake-migrate.sh"; printf '#!/bin/sh\nexit 0\n' > "$FAKE"; chmod +x "$FAKE"
tick() { FLEET_CFG_RESTART_MIGRATE="$FAKE" bash "$BIN/fleet-cfg-restart.sh" "$@" -- "$S" 2>&1; }
why() { bash -c '. "$1/fleet-lib.sh"; fleet_cfg_restart_why "$2" "$3"; echo "rc=$?"' _ "$BIN" "$S" "$1" 2>/dev/null | tr '\n' ' ' | sed 's/ $//'; }
# stale by fingerprint: w-loop, w-noman, w-stale, w-remote, w-panel (cfg-restart skips
# panels by NAME, and judges remote rows itself) = 5; broken: w-broken, counted apart
eq "F: --counts <stale> <renew> <broken> — the broken one counted once, apart" "5 0 1" "$(tick --counts)"
eq "F: a broken, done, idle session is reopened like a stale one" "rc=0" "$(why "$WB")"
eq "F: the looping stale one never" "state:looping rc=1" "$(why "$WL")"
l=$(tick --list)
has "F: --list names the broken one to reopen" "$l" "$WB	w-broken	reopen"
rm -f "$BROKEN"
eq "F: no broken file ⇒ the two-kind counts as before, nothing broken" "6 0 0" "$(tick --counts)"

printf 'selftest PASS: fleet-oldcfg-check (%d checks) — 会坏·需重开 told from 配置旧 (#2076)\n' "$CHECKS"
