#!/bin/bash
# spawn-origin-gate-selftest.sh — a spawn's parent must be a LIVE session (issue
# #1355, EPIC #1645 C2). On an isolated tmux server (`-L <label>`) and a sandbox
# conf dir, pins:
#   A  fleet_origin_gate (fleet-lib.sh): a live key → 0; a key no window answers
#      to → 4 + 「上级 <key> 不是活着的会话」; inside tmux with no $TMUX_PANE and no
#      --origin → 4; the same with an explicit `--origin hub` → 0; a pane, no
#      $TMUX at all (headless), `autofill`/`bridge`, a free label and an
#      --origin-wid (vetted by the placing machine) → 0.
#   B  fleet_epic_parent_key: a worker pane → its key; a hub pane / no pane →
#      rc 1, nothing printed, one stderr hint — never the EPIC's key.
#   C  dash-issue-session.sh end to end: no $TMUX_PANE → exit 4 and no window;
#      a closed parent (`--origin issue-99`) → exit 4 and no window; a live
#      parent and `--origin hub` get PAST the gate (to the FLEET_MAIN check,
#      exit 1 here — the sandbox has no checkout).
#   D  dash-raw-session.sh: no $TMUX_PANE → exit 4, no window; `--origin hub`
#      passes the gate.
#   F  who may spawn at all (issue #4591 lifted #2960): there is no seat check
#      left to ask (fleet_spawn_refused is gone, #4790). And the grant itself (which agent files
#      mount the dispatch group), off real files: bin/fleet-agent-def.py
#      spawn-tools — the shipped fleet-worker grants it now.
# tmux absent → SKIP. Exit 0 = pass.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
. "$BIN/selftest-lib.sh"
. "$BIN/selftest-repo-fixture.sh"
REAL_TMUX=$(command -v tmux) || { echo 'spawn-origin-gate selftest: tmux absent — SKIP'; exit 0; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/spawn-origin-gate.XXXXXX")" || exit 2
L="sog$$"
export FLEET_SKIP_GLOBAL_CONF=1
export FLEET_CONF_DIR="$WORK/conf"; mkdir -p "$FLEET_CONF_DIR/fleets/$L"
export FLEET_CC_SESSIONS_DIR="$WORK/sessions"; mkdir -p "$FLEET_CC_SESSIONS_DIR"
export FLEET_UI_QUIET=1 TMPDIR="$WORK"
: > "$FLEET_CONF_DIR/fleets/$L/conf"
fx_repo "$FLEET_CONF_DIR" "$L" acme/app FLEET_MAIN="$WORK/main"
unset TMUX TMUX_PANE CCQUOTA_FLEET FLEET_HUB_STATUS_CMD FLEET_HUB_CACHE_SECS

# gh shim: records every call; nothing in this test may reach GitHub.
mkdir -p "$WORK/shim"
cat > "$WORK/shim/gh" <<EOF
#!/bin/sh
echo "gh \$*" >> "$WORK/gh.log"; exit 1
EOF
chmod +x "$WORK/shim/gh"
export PATH="$WORK/shim:$PATH"

st_tally
tf() { "$REAL_TMUX" -L "$L" "$@"; }
cleanup() { "$REAL_TMUX" -L "$L" kill-server 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT INT TERM

tf -f /dev/null new-session -d -s "$L" -n home -c "$WORK" 'while :; do sleep 300; done' 2>/dev/null \
  || { echo 'spawn-origin-gate selftest: cannot start an isolated tmux server — SKIP' >&2; exit 0; }
SOCKPATH=$(tf display-message -p '#{socket_path}')
w7=$(tf new-window -d -P -F '#{window_id}' -n issue-7 -c "$WORK" 'while :; do sleep 300; done')
tf set-window-option -t "$w7" @issue 7
p7=$(tf display-message -p -t "$w7" '#{pane_id}')
phub=$(tf display-message -p -t "$L:home" '#{pane_id}')
INTMUX="$SOCKPATH,1,0"
nwin() { tf list-windows -t "$L" -F x | wc -l | tr -d ' '; }

# gate <TMUX> <TMUX_PANE> <args…> → "rc|stdout"
gate() {
  local t="$1" p="$2"; shift 2
  local out rc
  out=$(TMUX="$t" TMUX_PANE="$p" bash -c '. "$1/fleet-lib.sh"; shift; fleet_origin_gate "$@"' _ "$BIN" "$@"); rc=$?
  printf '%s|%s' "$rc" "$out"
}

# --- A: fleet_origin_gate ---------------------------------------------------------
r=$(gate '' '' "$L" '' issue-7);              st_count; [ "$r" = '0|' ] || st_miss "A: a live parent key passes" "$r"
r=$(gate '' '' "$L" issue-99 issue-99)
st_count; case "$r" in '4|上级 issue-99 不是活着的会话'*) ;; *) st_miss "A: a key no window answers to → 4 + reason" "$r" ;; esac
r=$(gate "$INTMUX" '' "$L" '' '')
st_count; case "$r" in '4|cannot tell who is spawning'*) ;; *) st_miss "A: lost pane, no --origin → 4" "$r" ;; esac
r=$(gate "$INTMUX" '' "$L" hub '');           st_count; [ "$r" = '0|' ] || st_miss "A: lost pane + --origin hub → 0" "$r"
r=$(gate "$INTMUX" '' "$L" issue-7 issue-7);  st_count; [ "$r" = '0|' ] || st_miss "A: lost pane + a live --origin key → 0" "$r"
r=$(gate "$INTMUX" '' "$L" issue-99 issue-99)
st_count; case "$r" in '4|上级 issue-99'*) ;; *) st_miss "A: lost pane + a dead --origin key → 4" "$r" ;; esac
r=$(gate "$INTMUX" "$phub" "$L" '' '');       st_count; [ "$r" = '0|' ] || st_miss "A: a hub pane (empty origin) → 0" "$r"
r=$(gate '' '' "$L" '' '');                   st_count; [ "$r" = '0|' ] || st_miss "A: headless (no \$TMUX) → 0" "$r"
r=$(gate '' '' "$L" autofill autofill);       st_count; [ "$r" = '0|' ] || st_miss "A: autofill → 0" "$r"
r=$(gate '' '' "$L" bridge bridge);           st_count; [ "$r" = '0|' ] || st_miss "A: bridge → 0" "$r"
r=$(gate '' '' "$L" otherfleet otherfleet);   st_count; [ "$r" = '0|' ] || st_miss "A: a free label (#516 source fleet) → 0" "$r"
r=$(gate "$INTMUX" '' "$L" '' issue-5 "abc/issue-5"); st_count; [ "$r" = '0|' ] || st_miss "A: --origin-wid (another machine vetted it) → 0" "$r"

# --- B: fleet_epic_parent_key -----------------------------------------------------
pk() { TMUX="$1" TMUX_PANE="$2" bash -c '. "$1/fleet-lib.sh"; fleet_epic_parent_key "$2" acme/app 1645' _ "$BIN" "$L" 2>"$WORK/pk.err"; }
out=$(pk "$INTMUX" "$p7"); rc=$?;  st_count; [ "$rc:$out" = '0:acme-app:issue-7' ]   # keys carry the repo (#1939) || st_miss "B: a worker pane → its own key" "$rc:$out"
out=$(pk "$INTMUX" "$phub"); rc=$?; st_count; [ "$rc:$out" = '1:' ] || st_miss "B: a hub pane → rc 1, never the EPIC's key" "$rc:$out"
st_count; grep -q 'scratch or worker pane' "$WORK/pk.err" || st_miss "B: the refusal says where to run it" "$(cat "$WORK/pk.err")"
out=$(pk "$INTMUX" ''); rc=$?;     st_count; [ "$rc:$out" = '1:' ] || st_miss "B: no \$TMUX_PANE → rc 1" "$rc:$out"
out=$(pk '' ''); rc=$?;            st_count; [ "$rc:$out" = '1:' ] || st_miss "B: headless → rc 1" "$rc:$out"

# --- C: dash-issue-session.sh end to end ------------------------------------------
dis() { local t="$1" p="$2"; shift 2; TMUX="$t" TMUX_PANE="$p" bash "$BIN/dash-issue-session.sh" "$@" 2>"$WORK/dis.err" >/dev/null; }
n0=$(nwin)
dis "$INTMUX" '' 41 "$L" --title t; rc=$?
st_count; [ "$rc" = 4 ] || st_miss "C: no \$TMUX_PANE → exit 4" "rc=$rc $(cat "$WORK/dis.err")"
st_count; grep -q 'cannot tell who is spawning' "$WORK/dis.err" || st_miss "C: … and says why on stderr" "$(cat "$WORK/dis.err")"
st_count; [ "$(nwin)" = "$n0" ] || st_miss "C: … and opens no window" "$(nwin) vs $n0"
dis '' '' 41 "$L" --title t --origin issue-99; rc=$?
st_count; [ "$rc" = 4 ] || st_miss "C: a closed parent → exit 4" "rc=$rc $(cat "$WORK/dis.err")"
st_count; grep -q '上级 acme-app:issue-99 不是活着的会话' "$WORK/dis.err" || st_miss "C: … naming the parent" "$(cat "$WORK/dis.err")"
st_count; [ "$(nwin)" = "$n0" ] || st_miss "C: … and opens no window" "$(nwin) vs $n0"
dis "$INTMUX" '' 41 "$L" --title t --origin hub; rc=$?
st_count; [ "$rc" = 1 ] && grep -q 'FLEET_MAIN is not a git checkout' "$WORK/dis.err" \
  || st_miss "C: --origin hub passes the gate (stops at the sandbox's missing checkout)" "rc=$rc $(cat "$WORK/dis.err")"
dis "$INTMUX" "$p7" 41 "$L" --title t; rc=$?
st_count; [ "$rc" = 1 ] && grep -q 'FLEET_MAIN is not a git checkout' "$WORK/dis.err" \
  || st_miss "C: a live worker pane passes the gate" "rc=$rc $(cat "$WORK/dis.err")"

# --- D: dash-raw-session.sh -------------------------------------------------------
TMUX="$INTMUX" TMUX_PANE='' bash "$BIN/dash-raw-session.sh" --name x "$L" >/dev/null 2>"$WORK/raw.err"; rc=$?
st_count; [ "$rc" = 4 ] && grep -q 'cannot tell who is spawning' "$WORK/raw.err" || st_miss "D: no \$TMUX_PANE → exit 4" "rc=$rc $(cat "$WORK/raw.err")"
st_count; [ "$(nwin)" = "$n0" ] || st_miss "D: … and opens no window" "$(nwin) vs $n0"
TMUX='' bash "$BIN/dash-raw-session.sh" --name x --origin scratch-88 "$L" >/dev/null 2>"$WORK/raw.err"; rc=$?
st_count; [ "$rc" = 4 ] && grep -q '上级 acme-app:scratch-88' "$WORK/raw.err" || st_miss "D: a closed parent → exit 4" "rc=$rc $(cat "$WORK/raw.err")"
TMUX="$INTMUX" TMUX_PANE='' bash "$BIN/dash-raw-session.sh" --name x --origin hub "$L" >/dev/null 2>"$WORK/raw.err"; rc=$?
st_count; [ "$rc" != 4 ] || st_miss "D: --origin hub passes the gate" "rc=$rc $(cat "$WORK/raw.err")"
st_count; grep -q -- "--origin='\${ORIGIN:-hub}'" "$BIN/dash-raw-session.sh" || st_miss "D: the --bg re-exec always states its origin (run-shell -b has no pane)"

# --- F: who may spawn ----------------------------------------------------------------
# (fleet_spawn_refused stays gone — every session may spawn, #4591 #4790: conf/gone.list)
mkdir -p "$WORK/cc/agents"
cp "$BIN/../conf/agent-defaults/claude/agents/"*.md "$WORK/cc/agents/"
printf -- '---\nname: doc-only\ndescription: d\ntools: Read, Edit\n---\n只改文档。\n' > "$WORK/cc/agents/doc-only.md"
printf -- '---\nname: dispatcher\ndescription: d\ntools:\n  - Read\n  - mcp__fleet-orch__spawn\n---\n' > "$WORK/cc/agents/dispatcher.md"
# epic-driver rides the fleet-epic plugin (issue #3116): listed as installed here
printf '[{"id":"fleet-epic@claude-fleet","enabled":true,"installPath":"%s"}]\n' "$BIN/../plugins/fleet-epic" > "$WORK/plugins.json"
grant() { CLAUDE_CONFIG_DIR="$WORK/cc" FLEET_AGENT_PLUGINS_CMD="cat '$WORK/plugins.json'" python3 "$BIN/fleet-agent-def.py" spawn-tools "$1" --dir "$WORK"; }
st_count; grant doc-only && st_miss "F: doc-only must not grant spawn"
for a in fleet-worker dispatcher; do st_count; grant "$a" || st_miss "F: $a grants spawn"; done

st_count; grant epic-driver > "$WORK/retired.out" 2> "$WORK/retired.err"; retired_rc=$?
[ "$retired_rc" = 3 ] && grep -q 'ROLE_RETIRED' "$WORK/retired.err" || st_miss "F: retired epic-driver must refuse"

st_done
