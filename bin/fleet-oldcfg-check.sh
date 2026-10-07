#!/bin/bash
# fleet-oldcfg-check.sh — which open sessions a release WOULD BREAK, and which only
# lack a new feature (issue #2076, EPIC #2074 C3).
#
# A session keeps what it read at its START — the hook table, the mod's tool list,
# the MCP servers (fleet-oldcfg-replay.py's three) — and runs everything they name
# from the live ~/.claude/fleet. After a stable move the sidebar showed ONE yellow
# 配置旧 for every old session, so the ones that WOULD FAIL — a hook script gone, a
# mod tool with no handler (2026-10-06: four sessions on m5 failing every spawn
# with «no tool.call hook answered») — looked exactly like the ones that merely
# lacked a new feature, and a looping scheduler (never reopened by the idle tick,
# on purpose) broke in silence until it reported an error.
#
# The launcher now writes the session's start down (fleet-agent-team.py `session`:
# $FLEET_CONF_DIR/agentcfg/<sha>.json, the window's @agent_cfg_manifest) and this
# script judges it against the live install with the release gate's OWN rule —
# fleet-oldcfg-replay.py --manifest, the same hook_paths_missing / tool_handler /
# mcp_scripts_missing the move gate asks (#2075); static, so a tick can afford it:
#
#   broken  something its start named is GONE from the install: a hook command's
#           ~/.claude/fleet path, a mod tool's tool.call handler, an MCP server's
#           script — it WILL fail (every turn / every spawn); reopen it
#   stale   nothing gone — it only lacks (or still runs) something the new table
#           / mod / MCP set changed; at worst a missing feature (#2068)
#   ok      its three are exactly the install's
#
#   fleet-oldcfg-check.sh <manifest.json> [--new-dir <tree>] [--json]
#       ONE session's start against the live install (default: this script's own
#       tree). Line 1 is the bare verdict, then one line per finding. Exit 0 ok ·
#       1 stale · 2 broken · 3 cannot run. A missing / unreadable manifest is
#       `stale` (exit 1), never broken: a window from before #2076 has none and
#       keeps the yellow it always had.
#
#   fleet-oldcfg-check.sh --sweep [--list] [--new-dir <tree>] [-- <session>…]
#       every open window of every live fleet (fleet_sockets; only the named ones
#       after --): the stale / renew ones (fleet_cfg_state off @agent_cfg /
#       @agent_ver — an `ok` window IS the install) have their manifests judged,
#       each distinct manifest ONCE, and the broken windows are written to
#       $FLEET_CONF_DIR/global/agent-cfg.broken — `<session>\t<window id>\t<sha>\t
#       <what>`, atomically, EMPTY when none — which fleet_cfg_broken_load reads
#       for the rows producer (red 会坏·需重开), the doctor's agentcfg row and the
#       idle reopen. Nothing is reopened here (#2068 B is the operator's).
#       --list also prints one row per window that is not current:
#         <kind>\t<session>\t<window>\t<repo>\t<#issue|->\t<state>\t<what>
#       kind = broken · looping (stale / renew AND in a /loop round or `looping`:
#       the idle tick never reopens it, so the operator must) · stale · renew.
#       Exit 0; 2 when something is broken (a caller sees it at a glance); 3 when
#       the sweep could not run (no python3, no replay script) — the broken file
#       is then emptied, so no red outlives the version that earned it.
#
# Who runs the sweep: tmux-dash-collect.sh's `agentcfg` phase every tick, and
# fleet-install-apply.sh's `oldcfg:` step right after a move (so the first frame
# after a release is already right, and the step names the broken + looping ones).
set -uo pipefail
BIN=$(cd "$(dirname "$0")" && pwd)
. "$BIN/fleet-lib.sh"
REPLAY="$BIN/fleet-oldcfg-replay.py"

MODE=one LIST='' JSON='' NEW='' MAN=''
while [ $# -gt 0 ]; do
  case "$1" in
    --sweep) MODE=sweep ;;
    --list) LIST=1 ;;
    --json) JSON=1 ;;
    --new-dir) NEW="${2:-}"; shift ;;
    --new-dir=*) NEW="${1#--new-dir=}" ;;
    --) shift; break ;;
    -h|--help) sed -n '2,60p' "$0"; exit 0 ;;
    -*) printf 'fleet-oldcfg-check: unknown option %s\n' "$1" >&2; exit 3 ;;
    *) if [ "$MODE" = one ] && [ -z "$MAN" ]; then MAN="$1"; else break; fi ;;
  esac
  shift
done
[ -n "$NEW" ] || NEW="$BIN/.."
NEW=$(cd "$NEW" 2>/dev/null && pwd -P) || { printf 'fleet-oldcfg-check: --new-dir is not a directory\n' >&2; exit 3; }
if ! command -v python3 >/dev/null 2>&1 || [ ! -f "$REPLAY" ]; then
  if [ "$MODE" = sweep ]; then      # cannot judge ⇒ nothing is red
    _bf="${FLEET_CONF_DIR:-$HOME/.config/claude-fleet}/global/agent-cfg.broken"
    [ -f "$_bf" ] && : > "$_bf"
  fi
  printf 'fleet-oldcfg-check: cannot run — %s\n' "$([ -f "$REPLAY" ] && printf 'no python3' || printf 'bin/fleet-oldcfg-replay.py missing')" >&2
  exit 3
fi

# --- one manifest -----------------------------------------------------------------
if [ "$MODE" = one ]; then
  [ -n "$MAN" ] || { printf 'usage: fleet-oldcfg-check.sh <manifest.json> [--new-dir <tree>] [--json] | --sweep [--list] [-- <session>…]\n' >&2; exit 3; }
  exec python3 "$REPLAY" --manifest "$MAN" --new-dir "$NEW" ${JSON:+--json}
fi

# --- the sweep ----------------------------------------------------------------------
if [ $# -gt 0 ]; then sessions=$*; else sessions=$(fleet_sockets); fi
fleet_cfg_expected_load
ROWS=''      # <sess>|<wid>|<name>|<repo>|<issue>|<state>|<cfgst>|<loop>|<manifest>
MANS=''      # the distinct manifest paths
for sess in $sessions; do
  while IFS='|' read -r wid role name rem ag fp av man st lp iss repo; do
    [ -n "$wid" ] || continue
    case "$(printf '%s\n' "$role" | awk "$FLEET_ROLE_AWK"' { print frole($0) }')" in home|panel) continue ;; esac
    [ -z "$rem" ] || continue                       # another machine's row, judged there
    fleet_cfg_state "$ag" "$fp" "$av"
    case "$FCFG_STATE" in stale|renew) ;; *) continue ;; esac
    loop=''
    if [ "$st" = looping ]; then loop=1
    elif [ -n "$lp" ] && [ -f "$BIN/fleet_loop_mark.py" ] \
         && python3 "$BIN/fleet_loop_mark.py" status --value "$lp" >/dev/null 2>&1; then loop=1; fi
    ROWS="$ROWS$sess|$wid|$name|${repo:--}|${iss:--}|${st:-none}|$FCFG_STATE|$loop|$man"$'\n'
    [ -n "$man" ] && case "$MANS" in *"$man"$'\n'*) ;; *) MANS="$MANS$man"$'\n' ;; esac
  done < <(tmux -L "$sess" list-windows -t "=$sess" \
             -F "#{window_id}|$FLEET_ROLE_FMT|#{window_name}|#{@remote}|#{@cc_agent}|#{@agent_cfg}|#{@agent_ver}|#{@agent_cfg_manifest}|#{@claude_state}|#{@loop}|#{@issue}|#{@repo}" 2>/dev/null)
done

# Each distinct manifest judged once: `<path>\t<sha>\t<verdict>\t<what>` lines.
VERDICTS=''
if [ -n "$MANS" ]; then
  _args=()
  while IFS= read -r m; do [ -n "$m" ] && _args+=(--manifest "$m"); done <<EOF
$MANS
EOF
  VERDICTS=$(python3 "$REPLAY" ${_args[@]+"${_args[@]}"} --new-dir "$NEW" --json 2>/dev/null \
    | python3 -c '
import json, sys
for line in sys.stdin:
    line = line.strip()
    if not line.startswith("{"):
        continue
    d = json.loads(line)
    f = [i for i in d.get("items", []) if i.get("verdict") in ("MISSING", "ERROR")]
    what = ""
    if f:
        what = "%s %s" % (f[0]["kind"], f[0]["name"])
        if len(f) > 1:
            what += " (+%d)" % (len(f) - 1)
    elif d.get("note"):
        what = d["note"]
    print("%s\t%s\t%s\t%s" % (d["manifest"], d["sha"], d["verdict"], what.replace("\t", " ")))
')
fi
verdict_of() {   # verdict_of <manifest path> → V_VERDICT V_SHA V_WHAT
  V_VERDICT='' V_SHA='' V_WHAT=''
  local p sha v what
  while IFS=$'\t' read -r p sha v what; do
    [ "$p" = "$1" ] && { V_VERDICT=$v; V_SHA=$sha; V_WHAT=$what; return 0; }
  done <<EOF
$VERDICTS
EOF
  return 1
}

BF="${FLEET_CONF_DIR:-$HOME/.config/claude-fleet}/global/agent-cfg.broken"
mkdir -p "${BF%/*}" 2>/dev/null
OUT='' NB=0
while IFS='|' read -r sess wid name repo iss st cfgst loop man; do
  [ -n "$wid" ] || continue
  kind=$cfgst what=''
  if [ -n "$man" ] && verdict_of "$man" && [ "$V_VERDICT" = broken ]; then
    kind=broken; what=$V_WHAT; NB=$((NB + 1))
    OUT="$OUT$sess	$wid	$V_SHA	$what"$'\n'
  elif [ -n "$loop" ]; then
    kind=looping; what="$cfgst, in a loop — the idle tick never reopens it"
  fi
  [ -n "$LIST" ] && printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$kind" "$sess" "$name" "$repo" "$([ "$iss" = - ] && printf -- '-' || printf '#%s' "$iss")" "$st" "$what"
done <<EOF
$ROWS
EOF
_tmp="$BF.tmp.$$"
if printf '%s' "$OUT" > "$_tmp" 2>/dev/null && mv -f "$_tmp" "$BF" 2>/dev/null; then :
else rm -f "$_tmp" 2>/dev/null; printf 'fleet-oldcfg-check: could not write %s\n' "$BF" >&2; fi
[ "$NB" -gt 0 ] && exit 2
exit 0
