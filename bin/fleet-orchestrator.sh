#!/bin/bash
# fleet-orchestrator.sh — the fleet's ONE orchestrating session (issue #1957,
# EPIC #1949 C7).
#
#   fleet-orchestrator.sh ensure <sess>   the window, opened when it is missing:
#                                         prints its window id, rc 0; rc 3 = off
#                                         here (FLEET_ORCHESTRATOR, default on
#                                         where FLEET_HOST=1 — 承载), rc 1 = the
#                                         fleet is not up / the window would not open,
#                                         rc 5 = another machine holds it (the hub
#                                         says so): `held <machine>` and, when one
#                                         was open here, `retired <window id>`
#   fleet-orchestrator.sh find <sess>     its window id, rc 1 when there is none
#   fleet-orchestrator.sh where <sess>    the hub's answer: here | elsewhere <m> |
#                                         none; rc 1 = no answer (no hub, old hub,
#                                         unreachable — the last answer kept is printed)
#
# What it is: a session of no repo (`@norepo 1`, opened in $HOME), told by its
# `@fleet_role orchestrator` — never its name, the person may rename it — and
# addressed as `orchestrator`, never by a recycled scratch number: the inventory
# carries `role=orchestrator` beside its identity (fleet-control-read.sh column
# 20 → the worker's `role`), fleet_win_for_key answers `orchestrator`. It runs this login's default agent (FLEET_AGENT) as its
# definition says, agents/orchestrator.md (issue #2782; `fleet-role.py render
# orchestrator`): the strongest model at high effort — Claude `fable` (the fleet's
# FLEET_MODEL_FALLBACK while that model is capped on the active account,
# fleet-claude.sh's rule), Codex the login's own model, with model_reasoning_effort;
# FLEET_ORCH_MODEL / FLEET_ORCH_EFFORT / FLEET_ORCH_CODEX_MODEL still win for one
# version — and starts on `/fleet-orchestrate` (skills/fleet-orchestrate/). Its ROLE
# is not that seed (issue #2582, EPIC #2581 C1): a Claude orchestrator is launched
# with `--append-system-prompt-file` the definition's body, and the mod adds the
# same text to every request (`fleet:orchestrator-role`), so a compaction or a
# /clear leaves it the orchestrator; the seed is sent only to a new conversation,
# as its first turn's instructions. Codex keeps the seed alone.
#
# The client never lists it: the task list's 「新任务」 row wears its state, the
# writing area hands it a draft (⇧⇥) and says when it is busy
# (bin/fleet-hub-sessions.sh writes `orch_<sess>` beside the needs file;
# fleet-sidebar.py / fleet-compose.py read it).
#
# It comes back like `home` does: the diskguard tick's home_watch calls `ensure`
# for every live fleet, and fleet-up.sh calls it after home is built — so a window
# closed by hand (or by anything) is open again on the next tick, resuming the
# same Claude conversation when its transcript is still on disk (the id kept in
# $FLEET_CONF_DIR/fleets/<sess>/orchestrator.sid).
#
# And it comes back AS IT WAS (issue #2585, EPIC #2581 C4). A Claude orchestrator
# whose agent exited — /exit, a crash, a killed process — sits on the wrapper's
# recovery page with the window still open; once it has sat there
# FLEET_ORCH_REVIVE_SECS (default 30; `off` keeps the page) the next `ensure`
# respawns that pane in place (same window, same @fleet_id) on the same
# conversation (the window's @cc_session_id, else orchestrator.sid). A resumed
# conversation is handed a first turn, ORCH_RESUME_SEED: SessionStart (resume)
# has just injected the saved state (bin/fleet-orchestrator-state.py, C2) and the
# seed makes the session act on its next step — re-arm the Loop, say the batch —
# with nobody typing. Codex keeps its page and its seed (convention 5).
#
# And it follows the install (issue #2733). A live Claude orchestrator launched
# from an older ~/.claude/fleet than the one installed (fleet_cfg_state stale /
# renew — fleet-migrate.sh never reopens it) is renewed by `ensure` at its next
# QUIET moment (fleet_role_renew_why: done/looping for a minute, no keypress, its
# Loop's next round ≥ 2 min away, no tool call or job in flight): the state saved
# (fleet-orchestrator-state.py save, the Loop off its transcript), then the same
# in-place respawn on the same conversation with the resume seed. Not quiet ⇒ the
# next tick asks again; @renew_since marks it pending (the client's 「新任务」 says
# 待换新, the doctor WARNs past FLEET_ORCH_RESTART_WAIT) and it is never forced.
# FLEET_ORCH_RENEW=0 leaves it on its version; each renew is a line in renew.log. Restore, migrate and move treat
# it as a panel: never snapshotted, never moved off its machine — `ensure` is how
# it comes back.
#
# ONE per person, not one per machine (issue #2117). Several machines of one
# person each run their own fleet; with the hub on (CCQUOTA_FLEET=1 and a node
# token) `ensure` first asks it — POST /v1/node/orchestrator — which machine holds
# the person's orchestrator (tokenledger/internal/api/fleet_orchestrator.go: the
# holder sticks while it is online and not 维护中, else the machine with the most
# of their sessions). Named here ⇒ open it as above; another machine named ⇒ this
# machine's own is marked (fleet_win_retire, so restore never pulls it back) and
# closed — its conversation id stays in orchestrator.sid — and none is opened:
# rc 5. FLEET_ORCHESTRATOR=0 here tells the hub "not here" and closes ours the
# same way. The answer is kept in $DIR/orchestrator.host, so a hub that cannot be
# asked for a tick changes nothing; no hub, an old hub (404) or no answer ever
# kept ⇒ this machine decides alone, as before.
#
# And a handoff ends a conversation for good (issue #2937). /fleet-handoff in this
# window arms fleet-handoff-cycle.sh, which stamps @handoff_cycle while it waits
# to /clear: no renew and no revive meanwhile (fleet_handoff_cycle_live). The
# /clear's SessionStart writes the new conversation into orchestrator.sid
# (handoff-latch-reset-hook.sh); the cycle's record, orchestrator.handoff, names
# the one handed off — `ensure` never resumes that one: a new conversation whose
# first turn is the pickup.
#
# Seams: FLEET_WRAP_LAUNCH is handed to the window when set (the wrapper's own
# selftest seam — a fake agent); FLEET_HUB_CURL (default `curl`) is the transport
# to the hub, as in fleet-node-maintenance.sh.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
. "$BIN/fleet-lib.sh"

usage() { sed -n '5,17p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
MODE=${1:-}; SESS=${2:-}
[ -n "$SESS" ] || usage
SOCK=$(fleet_socket "$SESS")
T() { tmux -L "$SOCK" "$@"; }

orch_find() {
  T list-windows -t "=$SESS" -F '#{window_id} #{@fleet_role}' 2>/dev/null \
    | awk '$2 == "orchestrator" { print $1; exit }'
}

# orch_hub_ask <1|0> — ask the hub which machine holds the person's one
# orchestrator, saying whether THIS machine may (0 = FLEET_ORCHESTRATOR off here).
# stdout `here` | `elsewhere <machine>` | `none`, rc 0; rc 1 = no answer (hub off,
# no node token, unreachable, an error); rc 2 = the hub predates #2117 (404).
# The token lives only in the one subshell that calls (issue #1491).
orch_hub_ask() {
  [ "${CCQUOTA_FLEET:-0}" = 1 ] || return 1
  _fleet_hub_creds_missing >/dev/null && return 1
  local body='{"eligible":true}' resp code
  [ "${1:-1}" = 1 ] || body='{"eligible":false}'
  resp=$(_fleet_hub_env
    "${FLEET_HUB_CURL:-curl}" -sS --max-time "${FLEET_HUB_TIMEOUT:-10}" -o - -w '\n%{http_code}' \
      -H "Authorization: Bearer ${CCQUOTA_TOKEN:-}" -H 'Content-Type: application/json' \
      -X POST --data-binary "$body" "${CCQUOTA_HUB_URL%/}/v1/node/orchestrator" 2>/dev/null) || return 1
  code=$(printf '%s\n' "$resp" | tail -n 1)
  case "$code" in
    200) ;;
    404|405) return 2 ;;
    *) return 1 ;;
  esac
  printf '%s\n' "$resp" | sed '$d' | python3 -c '
import json, sys
d = json.load(sys.stdin)
m = (d.get("machine") or "").strip()
print("here" if d.get("here") else ("elsewhere " + m if m else "none"))' 2>/dev/null
}

# orch_retire — close this machine's orchestrator because another machine holds
# it (or it is off here): marked first, so fleet-restore --auto never pulls it
# back (#1840), quiet, so the wrapper keeps no recovery page. The conversation
# id stays in orchestrator.sid for the day the hub names this machine again.
orch_retire() {
  local w; w=$(orch_find); [ -n "$w" ] || return 0
  fleet_win_retire "$w" "$SOCK"
  T set-window-option -t "$w" @wrap_quiet 1 2>/dev/null
  T kill-window -t "$w" 2>/dev/null
  printf 'retired %s\n' "$w"
}

case "$MODE" in
  find)
    w=$(orch_find); [ -n "$w" ] || exit 1
    printf '%s\n' "$w"; exit 0 ;;
  ensure|where) ;;
  *) usage ;;
esac

fleet_load_conf "$SESS" 2>/dev/null
DIR=$(fleet_state_dir "$SESS")
HOSTF="$DIR/orchestrator.host"
# on by default where this computer hosts sessions (承载, FLEET_HOST=1)
ON=0
case "${FLEET_ORCHESTRATOR:-${FLEET_HOST:-0}}" in 1|on|yes|true) ON=1 ;; esac

if [ "$MODE" = where ]; then
  if ans=$(orch_hub_ask "$ON") && [ -n "$ans" ]; then printf '%s\n' "$ans"; exit 0; fi
  [ -s "$HOSTF" ] && cat "$HOSTF"
  exit 1
fi

if [ "$ON" = 0 ]; then
  # off here: tell the hub, so it names another machine, and close ours if any
  orch_hub_ask 0 >/dev/null 2>&1
  T has-session -t "=$SESS" 2>/dev/null && [ -n "$(orch_find)" ] && orch_retire >&2
  exit 3
fi
T has-session -t "=$SESS" 2>/dev/null || exit 1

# The hub's word on which machine holds it (issue #2117), kept for a tick it
# cannot be asked; an old hub forgets what was kept — this machine decides alone.
ans=$(orch_hub_ask 1); arc=$?
# `none` (the hub hears no machine of ours online — our own agent is silent) is
# no answer either: the last one kept stands.
if [ "$arc" = 0 ] && [ -n "$ans" ] && [ "$ans" != none ]; then
  [ "$(cat "$HOSTF" 2>/dev/null)" = "$ans" ] || printf '%s\n' "$ans" > "$HOSTF" 2>/dev/null
else
  [ "$arc" = 2 ] && rm -f "$HOSTF"
  ans=$(cat "$HOSTF" 2>/dev/null)
fi
case "$ans" in
  elsewhere\ ?*)
    printf 'held %s\n' "${ans#elsewhere }"
    orch_retire
    exit 5 ;;
esac

# orch_exited <window id> — a Claude orchestrator on the wrapper's recovery page
# for FLEET_ORCH_REVIVE_SECS or longer: rc 0 = revive it.
orch_exited() {
  local grace=${FLEET_ORCH_REVIVE_SECS:-30} st ts ag
  case "$grace" in off) return 1 ;; ''|*[!0-9]*) grace=30 ;; esac
  IFS='|' read -r st ts ag <<EOF2
$(T display-message -p -t "$1" '#{@claude_state}|#{@claude_state_ts}|#{@cc_agent}' 2>/dev/null)
EOF2
  [ "$st" = exited ] && [ "$ag" != codex ] || return 1
  case "$ts" in ''|*[!0-9]*) ts=0 ;; esac
  [ $(( $(date +%s) - ts )) -ge "$grace" ]
}

# orch_live <window id> — rc 0 = leave the open window as it is (print its id).
# A live one on an older fleet version at a quiet moment (issue #2733) is not
# left: RENEW=1 and the respawn below takes it onto the installed version.
RENEW=0
orch_live() {
  # a /fleet-handoff cycle owns the window until it has cleared it (issue #2937)
  fleet_handoff_cycle_live "$SESS" "$1" && return 0
  orch_exited "$1" && return 1
  if [ "${FLEET_ORCH_RENEW:-1}" != 0 ] && fleet_role_renew_due "$SESS" "$1" >/dev/null; then
    RENEW=1; return 1
  fi
  return 0
}

w=$(orch_find)
[ -n "$w" ] && orch_live "$w" && { printf '%s\n' "$w"; exit 0; }

# One opener at a time (the tick and fleet-up can meet): a lock dir, taken over
# when it is older than a minute (an opener that died holding it).
LOCK="$DIR/orchestrator.lock"
if ! mkdir "$LOCK" 2>/dev/null; then
  age=$(( $(date +%s) - $(stat -f %m "$LOCK" 2>/dev/null || stat -c %Y "$LOCK" 2>/dev/null || echo 0) ))
  [ "$age" -gt 60 ] || exit 1
  rm -rf "$LOCK"; mkdir "$LOCK" 2>/dev/null || exit 1
fi
trap 'rmdir "$LOCK" 2>/dev/null' EXIT
w=$(orch_find); RENEW=0
[ -n "$w" ] && orch_live "$w" && { printf '%s\n' "$w"; exit 0; }

AGENT=${FLEET_AGENT:-claude}
case "$AGENT" in claude|codex) ;; *) AGENT=claude ;; esac
SIDF="$DIR/orchestrator.sid"
SEED='/fleet-orchestrate'
# The first turn of a RESUMED conversation (issue #2585): SessionStart (resume)
# injects the saved state; this makes the session act on it.
ORCH_RESUME_SEED='[fleet orchestrator] 会话刚被 fleet 接回（退出、崩溃或重启之后）。照上面「fleet orchestrator state」摘要的下一步做：先重新 arm 循环，再一句话报出当前批次和未读回报；没有摘要就先用 mcp__fleet__children 看一眼子会话。'
args="--agent $AGENT"; sid=''
# What it runs with is its definition, agents/orchestrator.md (issue #2782):
# model, effort and the role in the system prompt — the role rides it, not the
# conversation (issue #2582), so a compaction, a /clear or a resume keeps it; the
# mod adds the same text as its `fleet:orchestrator-role` section
# (mod/fleet/hooks/orchestrator.ts, off @fleet_role_body). --cap: the per-model
# cap's fallback (issue #524) while the strongest is walled.
ROLE_SHA=''; ROLE_BODY=''; cap=''; [ "$AGENT" = claude ] && cap=--cap
while IFS=$'\t' read -r k v; do
  case "$k" in
    sha)  ROLE_SHA=$v ;;
    body) ROLE_BODY=$v ;;
    arg)  args="$args $(printf '%q' "$v")" ;;
  esac
done <<EOF2
$(fleet_role_render orchestrator "$AGENT" $cap 2>/dev/null)
EOF2
if [ "$AGENT" = claude ]; then
  # the same conversation when it is still on disk, else a new one
  proj="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects/$(fleet_mangle_path "$HOME")"
  sid=''; [ -f "$SIDF" ] && sid=$(LC_ALL=C tr -cd '0-9a-f-' < "$SIDF")
  # a window being revived: the conversation it last ran (↵ r may have started a new one)
  if [ -n "$w" ]; then
    wsid=$(T display-message -p -t "$w" '#{@cc_session_id}' 2>/dev/null | LC_ALL=C tr -cd '0-9a-f-')
    if [ -n "$wsid" ] && [ "$wsid" != "$sid" ] && [ -f "$proj/$wsid.jsonl" ]; then
      sid=$wsid; printf '%s\n' "$sid" > "$SIDF"
    fi
  fi
  # A conversation a /fleet-handoff handed off is never resumed (issue #2937): its
  # cycle lost a race (a renew, an exit) or never cleared — a new one starts, its
  # first turn the pickup. SessionStart (clear) moved $SIDF on when the cycle won.
  hsid=$(fleet_role_handoff_sid "$DIR" orchestrator) || hsid=''
  if [ -n "$sid" ] && [ "$sid" = "$hsid" ]; then
    SEED=$(fleet_role_handoff_pickup "$DIR" orchestrator) || SEED='/fleet-orchestrate'
    printf '%s %s orchestrator %s handed-off %s → new conversation (%s)\n' "$(date '+%Y-%m-%dT%H:%M:%S')" \
      "$SESS" "${w:-new}" "$sid" "$SEED" >> "$DIR/renew.log" 2>/dev/null
    sid=''
  fi
  if [ -n "$sid" ] && [ -f "$proj/$sid.jsonl" ]; then
    args="$args --resume $sid"; SEED=$ORCH_RESUME_SEED
  else
    sid=$(fleet_fid_mint) || sid=''
    [ -n "$sid" ] && { printf '%s\n' "$sid" > "$SIDF"; args="$args --session-id $sid"; }
  fi
fi

seed=''
if [ -n "$SEED" ]; then
  seedf="$DIR/orchestrator.seed"
  printf '%s' "$SEED" > "$seedf" && seed=" \"\$(cat '$seedf')\""
fi
envs=''
[ -n "${FLEET_WRAP_LAUNCH:-}" ] && envs="env FLEET_WRAP_LAUNCH=$(printf '%q' "$FLEET_WRAP_LAUNCH") "
# the window says what it is BEFORE the launcher reads its conf (fleet_win_stamp_cmd)
stamp=$(fleet_win_stamp_cmd @fleet_role orchestrator @norepo 1 ${sid:+@norepo_sid "$sid"} \
  ${ROLE_SHA:+@fleet_role_file "$ROLE_SHA"} ${ROLE_BODY:+@fleet_role_body "$ROLE_BODY"})
launch="$stamp$envs'$BIN/fleet-session-wrap.sh' $args$seed; exec \$SHELL"
if [ -n "$w" ]; then
  if [ "$RENEW" = 1 ]; then
    # renew (issue #2733): the state is saved FIRST — the kill below runs no
    # SessionEnd — so the resumed conversation's SessionStart hands back the
    # batches and the Loop it had (the ScheduleWakeup read off its transcript)
    tr=""; [ -n "$sid" ] && [ -n "${proj:-}" ] && [ -f "$proj/$sid.jsonl" ] && tr="$proj/$sid.jsonl"
    python3 "$BIN/fleet-orchestrator-state.py" save ${tr:+--transcript "$tr"} --reason renew >/dev/null 2>&1 || :
    printf '%s %s orchestrator %s renewed %s → %s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "$SESS" "$w" \
      "$(T display-message -p -t "$w" '#{@agent_ver}' 2>/dev/null)" "$(fleet_cfg_expected_load; printf '%s' "$FCFG_EXP_VER")" \
      >> "$DIR/renew.log" 2>/dev/null
    T set-window-option -u -t "$w" @renew_since 2>/dev/null
  fi
  # revive in place (issue #2585): the page's wrapper goes, the window and its
  # identity stay; a reader that sees the state cleared sees the new launch
  T respawn-pane -k -t "$w" -c "$HOME" "$launch" 2>/dev/null || exit 1
  T set-window-option -t "$w" @claude_state '' \; set-window-option -t "$w" @claude_state_ts "$(date +%s)" 2>/dev/null
  [ -n "$sid" ] && T set-window-option -t "$w" @norepo_sid "$sid" 2>/dev/null
  if [ "$RENEW" = 1 ]; then printf 'renewed %s\n' "$w" >&2; else printf 'revived %s\n' "$w" >&2; fi
  printf '%s\n' "$w"
  exit 0
fi
name=$(sh "$BIN/fleet-ui-lang.sh" t orch_window 2>/dev/null); [ -n "$name" ] || name=编排
w=$(T new-window -d -P -F '#{window_id}' -t "=$SESS:" -n "$name" -c "$HOME" \
      "$launch" 2>/dev/null) || exit 1
[ -n "$w" ] || exit 1
fleet_win_role_stamp "$w" orchestrator "$SOCK"
T set-window-option -t "$w" @norepo 1 \; set-window-option -t "$w" automatic-rename off \; \
  set-window-option -t "$w" @reap_policy keep 2>/dev/null
[ -n "$sid" ] && T set-window-option -t "$w" @norepo_sid "$sid" 2>/dev/null
fleet_window_fid "$SESS" "$w" "$SOCK" >/dev/null 2>&1 || :
fleet_window_born "$SESS" "$w" "$SOCK" >/dev/null 2>&1 || :
fleet_wid_stamp "$w" "$SOCK" >/dev/null 2>&1 || :
printf '%s\n' "$w"
exit 0
