#!/bin/bash
# fleet-steward.sh — the fleet's STEWARD session (issue #2670, EPIC #2668 C2): the
# one that patrols every batch for you, so the orchestrator only talks with you.
#
#   fleet-steward.sh ensure <sess>   the window, opened when it is missing: prints
#                                    its window id, rc 0; rc 3 = no window here
#                                    (`off`, or `count` — only the attention count
#                                    runs), rc 1 = the fleet is not up / the window
#                                    would not open, rc 5 = the orchestrator is held
#                                    by another machine — the steward goes with it
#                                    (`held <machine>`, and `retired <id>` when one
#                                    was open here)
#   fleet-steward.sh find <sess>     its window id, rc 1 when there is none
#   fleet-steward.sh mode <sess>     off | count | on — the one reading of the switch
#
# The switch, FLEET_STEWARD (EPIC #2668 共同约定 9 · 批后):
#   0 / off      nothing: no window, no count, ask / sidebar as before — byte for byte
#   count        the attention count only (@attention_log on the fleet's server, the
#                node conf's [76] hooks → fleet-steward-stats.sh note); no window, no
#                model. The DEFAULT where this computer runs an orchestrator
#                (FLEET_ORCHESTRATOR, else FLEET_HOST): the batch-end rule is «three
#                days counting the baseline, then turn it on».
#   1 / on       the count AND the steward window
# bin/fleet_decision.py's steward_on() reads the same variable for the ask format.
#
# What it is: a session of no repo (`@norepo 1`, $HOME), told by `@fleet_role
# steward` — never its name — and addressed as `steward` (fleet_win_for_key,
# fleet-peer-send.sh). One tier cheaper than the orchestrator (发起人拍板 3), as its
# definition says, agents/steward.md (issue #2782): `opus` at `medium` effort
# (FLEET_STEWARD_MODEL / FLEET_STEWARD_EFFORT / FLEET_STEWARD_CODEX_MODEL still win
# for one version). Its role — the definition's body — rides the system prompt
# (`--append-system-prompt-file`), so a compaction or a
# /clear leaves it the steward; its STATE is never the conversation —
# fleet-steward-tick.sh rebuilds every beat from the ledgers, the issues and
# global/steward.state.json (共同约定 4).
#
# It never polls. The diskguard tick's home_watch calls `ensure` and then
# `fleet-steward-tick.sh beat`, which reads the fleet with no model; only a beat
# with something new hands the window one turn. A calm beat costs no API call.
#
# It comes back like the orchestrator: a window closed by anything is reopened on
# the next tick, on the same Claude conversation while its transcript is on disk
# ($FLEET_CONF_DIR/fleets/<sess>/steward.sid); one on the wrapper's recovery page
# past FLEET_STEWARD_REVIVE_SECS (30; `off` keeps the page) is respawned in place.
# A live one launched from an older ~/.claude/fleet than the one installed is
# renewed the orchestrator's way (issue #2733): at a quiet moment, in place, on
# the same conversation; pending meanwhile (@renew_since), never forced.
# Session caps never count it (only `worker` does); restore / migrate / move read
# it as `home` — never snapshotted, never moved.
#
# Seam: FLEET_WRAP_LAUNCH is handed to the window when set (a fake agent).
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
. "$BIN/fleet-lib.sh"

usage() { sed -n '5,17p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
MODE=${1:-}; SESS=${2:-}
[ -n "$SESS" ] || usage
SOCK=$(fleet_socket "$SESS")
T() { tmux -L "$SOCK" "$@"; }

stew_find() {
  T list-windows -t "=$SESS" -F '#{window_id} #{@fleet_role}' 2>/dev/null \
    | awk '$2 == "steward" { print $1; exit }'
}

# stew_retire — close ours: marked first (restore never pulls it back), quiet
# (no recovery page). The conversation id stays in steward.sid.
stew_retire() {
  local w; w=$(stew_find); [ -n "$w" ] || return 0
  fleet_win_retire "$w" "$SOCK"
  T set-window-option -t "$w" @wrap_quiet 1 2>/dev/null
  T kill-window -t "$w" 2>/dev/null
  printf 'retired %s\n' "$w"
}

case "$MODE" in
  find)
    w=$(stew_find); [ -n "$w" ] || exit 1
    printf '%s\n' "$w"; exit 0 ;;
  ensure|mode) ;;
  *) usage ;;
esac

fleet_load_conf "$SESS" 2>/dev/null
DIR=$(fleet_state_dir "$SESS")
ON=off
case "${FLEET_STEWARD-}" in
  0|off|no|false) ON=off ;;
  count) ON=count ;;
  '') case "${FLEET_ORCHESTRATOR:-${FLEET_HOST:-0}}" in 1|on|yes|true) ON=count ;; esac ;;
  *) ON=on ;;
esac
if [ "$MODE" = mode ]; then printf '%s\n' "$ON"; exit 0; fi

if [ "$ON" = off ]; then
  if T has-session -t "=$SESS" 2>/dev/null; then
    [ -n "$(T show-option -gqv @attention_log 2>/dev/null)" ] && T set-option -gu @attention_log 2>/dev/null
    [ -n "$(stew_find)" ] && stew_retire >&2
  fi
  exit 3
fi
T has-session -t "=$SESS" 2>/dev/null || exit 1
# the attention count (EPIC #2668 指标 1): the node conf's [76] hooks log a
# client's window change only while this is set
[ "$(T show-option -gqv @attention_log 2>/dev/null)" = 1 ] || T set-option -g @attention_log 1 2>/dev/null
if [ "$ON" = count ]; then
  [ -n "$(stew_find)" ] && stew_retire >&2
  exit 3
fi

# The steward goes where the orchestrator is (issue #2117's answer, kept by
# fleet-orchestrator.sh): its [decision] goes to a session on this machine.
held=$(cat "$DIR/orchestrator.host" 2>/dev/null)
case "$held" in
  elsewhere\ ?*)
    printf 'held %s\n' "${held#elsewhere }"
    stew_retire
    exit 5 ;;
esac

stew_exited() {
  local grace=${FLEET_STEWARD_REVIVE_SECS:-30} st ts ag
  case "$grace" in off) return 1 ;; ''|*[!0-9]*) grace=30 ;; esac
  IFS='|' read -r st ts ag <<EOF2
$(T display-message -p -t "$1" '#{@claude_state}|#{@claude_state_ts}|#{@cc_agent}' 2>/dev/null)
EOF2
  [ "$st" = exited ] && [ "$ag" != codex ] || return 1
  case "$ts" in ''|*[!0-9]*) ts=0 ;; esac
  [ $(( $(date +%s) - ts )) -ge "$grace" ]
}

# stew_live — rc 0 = leave the open window as it is. On an older fleet version at
# a quiet moment (issue #2733, fleet_role_renew_why) it is renewed: RENEW=1.
RENEW=0
stew_live() {
  stew_exited "$1" && return 1
  if [ "${FLEET_ORCH_RENEW:-1}" != 0 ] && fleet_role_renew_due "$SESS" "$1" >/dev/null; then
    RENEW=1; return 1
  fi
  return 0
}

w=$(stew_find)
[ -n "$w" ] && stew_live "$w" && { printf '%s\n' "$w"; exit 0; }

LOCK="$DIR/steward.lock"
mkdir -p "$DIR" 2>/dev/null
if ! mkdir "$LOCK" 2>/dev/null; then
  age=$(( $(date +%s) - $(stat -f %m "$LOCK" 2>/dev/null || stat -c %Y "$LOCK" 2>/dev/null || echo 0) ))
  [ "$age" -gt 60 ] || exit 1
  rm -rf "$LOCK"; mkdir "$LOCK" 2>/dev/null || exit 1
fi
trap 'rmdir "$LOCK" 2>/dev/null' EXIT
w=$(stew_find); RENEW=0
[ -n "$w" ] && stew_live "$w" && { printf '%s\n' "$w"; exit 0; }

AGENT=${FLEET_AGENT:-claude}
case "$AGENT" in claude|codex) ;; *) AGENT=claude ;; esac
SIDF="$DIR/steward.sid"
SEED='/fleet-steward'
# The first turn of a RESUMED conversation: nothing to remember — the next beat
# rebuilds from the state file; say so and wait for it.
STEW_RESUME_SEED='[fleet steward] 会话刚被 fleet 接回。你的状态不在对话里：跑一次 `fleet-steward-tick.sh card` 看上一拍，然后等下一拍的 [steward] 消息；本轮不要做别的。'
args="--agent $AGENT"; sid=''
# What it runs with is its definition, agents/steward.md (issue #2782): model,
# effort and the role in the system prompt (`fleet-role.py render steward`).
ROLE_SHA=''; ROLE_BODY=''
while IFS=$'\t' read -r k v; do
  case "$k" in
    sha)  ROLE_SHA=$v ;;
    body) ROLE_BODY=$v ;;
    arg)  args="$args $(printf '%q' "$v")" ;;
  esac
done <<EOF2
$(fleet_role_render steward "$AGENT" 2>/dev/null)
EOF2
if [ "$AGENT" = claude ]; then
  proj="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects/$(fleet_mangle_path "$HOME")"
  sid=''; [ -f "$SIDF" ] && sid=$(LC_ALL=C tr -cd '0-9a-f-' < "$SIDF")
  if [ -n "$w" ]; then
    wsid=$(T display-message -p -t "$w" '#{@cc_session_id}' 2>/dev/null | LC_ALL=C tr -cd '0-9a-f-')
    if [ -n "$wsid" ] && [ "$wsid" != "$sid" ] && [ -f "$proj/$wsid.jsonl" ]; then
      sid=$wsid; printf '%s\n' "$sid" > "$SIDF"
    fi
  fi
  if [ -n "$sid" ] && [ -f "$proj/$sid.jsonl" ]; then
    args="$args --resume $sid"; SEED=$STEW_RESUME_SEED
  else
    sid=$(fleet_fid_mint) || sid=''
    [ -n "$sid" ] && { printf '%s\n' "$sid" > "$SIDF"; args="$args --session-id $sid"; }
  fi
fi

seedf="$DIR/steward.seed"
printf '%s' "$SEED" > "$seedf" && seed=" \"\$(cat '$seedf')\""
envs=''
[ -n "${FLEET_WRAP_LAUNCH:-}" ] && envs="env FLEET_WRAP_LAUNCH=$(printf '%q' "$FLEET_WRAP_LAUNCH") "
stamp=$(fleet_win_stamp_cmd @fleet_role steward @norepo 1 ${sid:+@norepo_sid "$sid"} \
  ${ROLE_SHA:+@fleet_role_file "$ROLE_SHA"} ${ROLE_BODY:+@fleet_role_body "$ROLE_BODY"})
launch="$stamp$envs'$BIN/fleet-session-wrap.sh' $args$seed; exec \$SHELL"
if [ -n "$w" ]; then
  if [ "$RENEW" = 1 ]; then
    # nothing to save: its state is never the conversation (the beat rebuilds it)
    printf '%s %s steward %s renewed %s → %s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "$SESS" "$w" \
      "$(T display-message -p -t "$w" '#{@agent_ver}' 2>/dev/null)" "$(fleet_cfg_expected_load; printf '%s' "$FCFG_EXP_VER")" \
      >> "$DIR/renew.log" 2>/dev/null
    T set-window-option -u -t "$w" @renew_since 2>/dev/null
  fi
  T respawn-pane -k -t "$w" -c "$HOME" "$launch" 2>/dev/null || exit 1
  T set-window-option -t "$w" @claude_state '' \; set-window-option -t "$w" @claude_state_ts "$(date +%s)" 2>/dev/null
  [ -n "$sid" ] && T set-window-option -t "$w" @norepo_sid "$sid" 2>/dev/null
  if [ "$RENEW" = 1 ]; then printf 'renewed %s\n' "$w" >&2; else printf 'revived %s\n' "$w" >&2; fi
  printf '%s\n' "$w"
  exit 0
fi
name=$(sh "$BIN/fleet-ui-lang.sh" t steward_window 2>/dev/null); [ -n "$name" ] || name=管家
w=$(T new-window -d -P -F '#{window_id}' -t "=$SESS:" -n "$name" -c "$HOME" \
      "$launch" 2>/dev/null) || exit 1
[ -n "$w" ] || exit 1
fleet_win_role_stamp "$w" steward "$SOCK"
T set-window-option -t "$w" @norepo 1 \; set-window-option -t "$w" automatic-rename off \; \
  set-window-option -t "$w" @reap_policy keep 2>/dev/null
[ -n "$sid" ] && T set-window-option -t "$w" @norepo_sid "$sid" 2>/dev/null
fleet_window_fid "$SESS" "$w" "$SOCK" >/dev/null 2>&1 || :
fleet_window_born "$SESS" "$w" "$SOCK" >/dev/null 2>&1 || :
fleet_wid_stamp "$w" "$SOCK" >/dev/null 2>&1 || :
printf '%s\n' "$w"
exit 0
