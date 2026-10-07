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
# 20 → the worker's `role`), fleet_win_for_key answers `orchestrator`. It runs this login's default agent (FLEET_AGENT) on that agent's
# strongest model at high effort — Claude: FLEET_ORCH_MODEL (default `fable`, the
# fleet's FLEET_MODEL_FALLBACK while that model is capped on the active account,
# fleet-claude.sh's rule) with `--effort ${FLEET_ORCH_EFFORT:-high}`; Codex:
# FLEET_ORCH_CODEX_MODEL (else the login's own) with model_reasoning_effort — and
# starts on `/fleet-orchestrate` (skills/fleet-orchestrate/), its one instruction.
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
# $FLEET_CONF_DIR/fleets/<sess>/orchestrator.sid). Restore, migrate and move treat
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

w=$(orch_find)
[ -n "$w" ] && { printf '%s\n' "$w"; exit 0; }

# One opener at a time (the tick and fleet-up can meet): a lock dir, taken over
# when it is older than a minute (an opener that died holding it).
LOCK="$DIR/orchestrator.lock"
if ! mkdir "$LOCK" 2>/dev/null; then
  age=$(( $(date +%s) - $(stat -f %m "$LOCK" 2>/dev/null || stat -c %Y "$LOCK" 2>/dev/null || echo 0) ))
  [ "$age" -gt 60 ] || exit 1
  rm -rf "$LOCK"; mkdir "$LOCK" 2>/dev/null || exit 1
fi
trap 'rmdir "$LOCK" 2>/dev/null' EXIT
w=$(orch_find)
[ -n "$w" ] && { printf '%s\n' "$w"; exit 0; }

AGENT=${FLEET_AGENT:-claude}
case "$AGENT" in claude|codex) ;; *) AGENT=claude ;; esac
SIDF="$DIR/orchestrator.sid"
SEED='/fleet-orchestrate'
args="--agent $AGENT"; sid=''
if [ "$AGENT" = claude ]; then
  model=${FLEET_ORCH_MODEL-fable}
  if [ -n "$model" ] && [ -n "${FLEET_MODEL_FALLBACK-opus}" ]; then
    # the per-model cap (issue #524): the fallback while the strongest is walled
    label=$("$BIN/fleet-account.sh" active 2>/dev/null)
    if [ -n "$label" ]; then
      till=$("$BIN/fleet-account.sh" model-limited-until "$label" "$model" 2>/dev/null)
      case "$till" in ''|*[!0-9]*) till=0 ;; esac
      [ "$till" -gt "$(date +%s)" ] && model=${FLEET_MODEL_FALLBACK-opus}
    fi
  fi
  [ -n "$model" ] && args="$args --model $(printf '%q' "$model")"
  args="$args --effort $(printf '%q' "${FLEET_ORCH_EFFORT:-high}")"
  # the same conversation when it is still on disk, else a new one
  sid=''; [ -f "$SIDF" ] && sid=$(LC_ALL=C tr -cd '0-9a-f-' < "$SIDF")
  if [ -n "$sid" ] && [ -f "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects/$(fleet_mangle_path "$HOME")/$sid.jsonl" ]; then
    args="$args --resume $sid"; SEED=''
  else
    sid=$(fleet_fid_mint) || sid=''
    [ -n "$sid" ] && { printf '%s\n' "$sid" > "$SIDF"; args="$args --session-id $sid"; }
  fi
else
  [ -n "${FLEET_ORCH_CODEX_MODEL:-}" ] && args="$args -m $(printf '%q' "$FLEET_ORCH_CODEX_MODEL")"
  args="$args -c $(printf '%q' "model_reasoning_effort=\"${FLEET_ORCH_EFFORT:-high}\"")"
fi

seed=''
if [ -n "$SEED" ]; then
  seedf="$DIR/orchestrator.seed"
  printf '%s' "$SEED" > "$seedf" && seed=" \"\$(cat '$seedf')\""
fi
envs=''
[ -n "${FLEET_WRAP_LAUNCH:-}" ] && envs="env FLEET_WRAP_LAUNCH=$(printf '%q' "$FLEET_WRAP_LAUNCH") "
# the window says what it is BEFORE the launcher reads its conf (fleet_win_stamp_cmd)
stamp=$(fleet_win_stamp_cmd @fleet_role orchestrator @norepo 1 ${sid:+@norepo_sid "$sid"})
name=$(sh "$BIN/fleet-ui-lang.sh" t orch_window 2>/dev/null); [ -n "$name" ] || name=编排
w=$(T new-window -d -P -F '#{window_id}' -t "=$SESS:" -n "$name" -c "$HOME" \
      "$stamp$envs'$BIN/fleet-session-wrap.sh' $args$seed; exec \$SHELL" 2>/dev/null) || exit 1
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
