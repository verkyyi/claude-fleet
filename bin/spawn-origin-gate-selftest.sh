#!/bin/bash
# Parent gate compatibility is inert, while repo/session authority stays intact.
# Uses an isolated tmux server and a sandbox conf directory.
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
st_count; [ "$r" = '0|' ] || st_miss "A: dead Parent cannot gate a start" "$r"
r=$(gate "$INTMUX" '' "$L" '' '')
st_count; [ "$r" = '0|' ] || st_miss "A: missing pane cannot gate through Parent" "$r"
r=$(gate "$INTMUX" '' "$L" hub '');           st_count; [ "$r" = '0|' ] || st_miss "A: lost pane + --origin hub → 0" "$r"
r=$(gate "$INTMUX" '' "$L" issue-7 issue-7);  st_count; [ "$r" = '0|' ] || st_miss "A: lost pane + a live --origin key → 0" "$r"
r=$(gate "$INTMUX" '' "$L" issue-99 issue-99)
st_count; [ "$r" = '0|' ] || st_miss "A: old dead --origin remains inert" "$r"
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

# --- C/D: production spawners no longer consult the old Parent gate ---------------
# Repo authority still refuses this deliberately missing checkout. Neither a
# missing caller pane nor a dead --origin is a reason to deny a start.
n0=$(nwin)
for spawn in dash-issue-session.sh dash-raw-session.sh; do
  if [ "$spawn" = dash-issue-session.sh ]; then args=(41 "$L" --title t)
  else args=(--name x "$L"); fi
  for origin in '' issue-99 hub; do
    extra=(); [ -z "$origin" ] || extra=(--origin "$origin")
    TMUX="$INTMUX" TMUX_PANE='' bash "$BIN/$spawn" "${args[@]}" ${extra[@]+"${extra[@]}"} >"$WORK/spawn.out" 2>"$WORK/spawn.err"; rc=$?
    st_count; [ "$rc" != 4 ] && ! grep -qE 'cannot tell who is spawning|上级 .*不是活着的会话' "$WORK/spawn.err" \
      || st_miss "C/D: $spawn legacy origin=$origin cannot gate a start" "rc=$rc $(cat "$WORK/spawn.err")"
    st_count; [ "$(nwin)" = "$n0" ] || st_miss "C/D: checkout/authority guard remains" "$(nwin) vs $n0"
  done
done

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
