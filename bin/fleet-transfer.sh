#!/bin/bash
# fleet-transfer.sh — hand ONE Claude/Codex session to either agent in its existing pane.
#
# Usage: fleet-transfer.sh --session <fleet> --window <handle|name|@id> --to claude|codex
#                         [--handoff <notes.md>] [--loop <spec.json>] [--codex-home DIR]
#                         [--dry-run | --prepare-only | --after-turn]
#
# --dry-run       Resolve exact provenance and print the plan; write nothing.
# --prepare-only  Save the handoff package; leave Claude and tmux unchanged.
# --after-turn    Arm from /fleet-handoff; wait for this turn's Stop before switching.
#                 Requires --handoff. Returns after arming, without exiting Claude.
# --loop          Explicit recurring prompt + interval to continue on Codex.
# --handoff       Optional source-agent notes. Without notes, Codex reconstructs
#                 the task from the captured conversation and current git state.
#
# Supports Claude → Codex and Codex context cycling. No bulk mode, transcript guessing, git mutation,
# automatic source restart, or forced agent termination. A cutover requires @claude_state
# done, one pane, a registered source session, and its own linked git worktree.
# Run an immediate cutover from another pane/terminal. Inside the source agent,
# use --after-turn as the final tool call, then end the turn.
#
# Packages: $FLEET_CONF_DIR/handoffs/<fleet>-<source-session>-<unique>/ (0700).
# manifest.json + pickup.md always identify the source agent/session/transcript
# path. source.jsonl is a frozen snapshot; history.md is searchable visible text.
# resume-source.sh is a MANUAL recovery recipe, only after Codex is stopped.
#
# The TTL-bounded @agent_transfer_until + rotation lease suppress SessionEnd and
# reapers during /exit. Once the source has exited, respawn only a dead pane or
# its verified childless shell; preserve the window identity and all task bindings.
# Never run this against a live fleet to test it: fleet-transfer-selftest.sh uses
# an isolated socket and fake agents.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
. "$BIN/fleet-lib.sh"
HELPER="$BIN/.fleet-transfer.py"

die() { printf 'fleet-transfer: %s\n' "$*" >&2; exit 1; }
usage() { sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; }
SESS='' TARGET='' TO='' NOTES='' LOOP='' DRY=0 PREPARE=0 AFTER=0 EXPECT='' REQUEST='' CODEX_TARGET_HOME='' REQUIRE_IDLE=0
TARGET_FILE='' QUOTA_REQUEST='' DRAFT='' INSPECT=0 NATIVE=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --session|--window|--to|--handoff|--loop|--expected-source|--armed-request|--target-file|--quota-request|--draft-file|--codex-home)
      [ "$#" -ge 2 ] && [ -n "$2" ] || die "$1 needs a value"
      case "$1" in
        --session) SESS=$2 ;;
        --window) [ -z "$TARGET" ] || die 'only one --window is allowed'; TARGET=$2 ;;
        --to) TO=$2 ;; --handoff) NOTES=$2 ;;
        --loop) LOOP=$2 ;;
        --target-file) TARGET_FILE=$2 ;; --quota-request) QUOTA_REQUEST=$2 ;; --draft-file) DRAFT=$2 ;;
        --codex-home) CODEX_TARGET_HOME=$2 ;;
        --expected-source) EXPECT=$2 ;; --armed-request) REQUEST=$2 ;;
      esac
      shift 2 ;;
    --dry-run) DRY=1; shift ;;
    --prepare-only) PREPARE=1; shift ;;
    --after-turn) AFTER=1; shift ;;
    --inspect) INSPECT=1; DRY=1; shift ;;
    --native-resume) NATIVE=1; shift ;;
    --require-codex-idle) REQUIRE_IDLE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument $1 (exactly one --window is required)" ;;
  esac
done
[ -n "$TARGET" ] || { usage >&2; exit 2; }
case "$TO" in claude|codex) ;; *) usage >&2; exit 2;; esac
[ "$((DRY + PREPARE + AFTER))" -le 1 ] || die '--dry-run, --prepare-only and --after-turn are mutually exclusive'
[ "$AFTER" != 1 ] || [ -n "$NOTES" ] || die '--after-turn requires --handoff notes written by the source agent'
if [ -n "$CODEX_TARGET_HOME" ]; then
  CODEX_TARGET_HOME=$(cd "$CODEX_TARGET_HOME" && pwd -P) || die 'target CODEX_HOME is missing'
fi
for dep in python3 git tmux; do command -v "$dep" >/dev/null 2>&1 || die "$dep is required"; done
[ -n "$SESS" ] || SESS=$(fleet_current_session)
case "$SESS" in ''|*[!A-Za-z0-9_-]*) die 'pass --session with a valid fleet name' ;; esac
# A default-socket/ad-hoc session is not a fleet. Its persisted conf is mandatory.
[ -f "$FLEET_CONF_DIR/fleets/$SESS/conf" ] || die "no fleet configuration for $SESS"
fleet_load_conf "$SESS" || die "cannot load fleet $SESS"
SOCK=$(fleet_socket "$SESS")
TM() { tmux -L "$SOCK" "$@"; }
opt() { TM display-message -p -t "$PANE" "$1" 2>/dev/null; }
SK() { FLEET_ALLOW_SENDKEYS=1 TM send-keys -t "$PANE" "$@"; }
TARGET=$(fleet_wid_target "$TARGET" "$SOCK")
WIN=$(TM display-message -p -t "$TARGET" '#{window_id}' 2>/dev/null) || die 'window not found'
PANE=$(TM display-message -p -t "$WIN" '#{pane_id}' 2>/dev/null) || die 'pane not found'
[ "$(opt '#{session_name}')" = "$SESS" ] || die 'window belongs to a different session'
[ "$(opt '#{window_panes}')" = 1 ] || die 'transfer requires a single-pane window'
case "$(opt '#{window_name}')" in dash|plan|backlog) die 'panel windows cannot be transferred' ;; esac
[ "$(opt '#{@hub}')" != 1 ] || die 'the hub cannot be transferred'
SOURCE_AGENT=$(opt '#{@cc_agent}'); SOURCE_AGENT=${SOURCE_AGENT:-claude}
case "$SOURCE_AGENT" in claude|codex) ;; *) die 'unsupported source agent' ;; esac
ISSUE=$(opt '#{@issue}'); RAW=$(opt '#{@raw}')
case "$ISSUE" in ''|*[!0-9]*) [ "$RAW" = 1 ] || die 'window is neither an issue worker nor a scratch session' ;; esac
WT=$(opt '#{@worktree}')
if [ -z "$WT" ]; then
  # Issue workers predate the scratch-only @worktree stamp. Resolve their real
  # pane cwd, then apply every linked-worktree and source-registry check below.
  CWD=$(opt '#{pane_current_path}')
  [ -n "$CWD" ] && [ -d "$CWD" ] || die 'window has no existing working directory'
  WT=$(git -C "$CWD" rev-parse --show-toplevel 2>/dev/null) || die 'pane is not in a worktree'
fi
[ -n "$WT" ] && [ -d "$WT" ] || die 'window has no existing @worktree'
WT=$(cd "$WT" && pwd -P) || die 'cannot resolve worktree'
MAIN=$(cd "${FLEET_MAIN:-/nonexistent}" && pwd -P) || die 'fleet base checkout not found'
[ "$WT" != "$MAIN" ] && [ -f "$WT/.git" ] || die 'source must own a linked worktree, never the base checkout'
[ "$(git -C "$WT" rev-parse --show-toplevel 2>/dev/null)" = "$WT" ] || die 'invalid worktree'
git -C "$MAIN" worktree list --porcelain | grep -Fx "worktree $WT" >/dev/null || die 'worktree is not registered to this fleet'
CODEX_SOURCE_HOME=''; REGISTRY=''
if [ "$SOURCE_AGENT" = codex ]; then
  RESOLVED=$(python3 "$HELPER" source-codex --pane "$PANE" --socket "$SOCK" --worktree "$WT") || exit 1
  IFS=$'\t' read -r PID SID CODEX_SOURCE_HOME TRANSCRIPT <<< "$RESOLVED"
else
PID=$(fleet_pane_claude_pid "$PANE" "$SOCK") || die 'no live Claude process in the source pane'
REGISTRY=$(fleet_cc_session_json "$PID")
[ -n "$REGISTRY" ] || die 'source process has no session registry; refusing to guess its transcript'
PROJECTS="${FLEET_CC_PROJECTS_DIR:-${CLAUDE_PROJECTS_DIR:-$HOME/.claude/projects}}"
RESOLVED=$(python3 "$HELPER" resolve --registry "$REGISTRY" --projects "$PROJECTS" --worktree "$WT") || exit 1
SID=${RESOLVED%%$'\n'*}; TRANSCRIPT=${RESOLVED#*$'\n'}
fi
[ -n "$CODEX_TARGET_HOME" ] || CODEX_TARGET_HOME="$CODEX_SOURCE_HOME"
[ -z "$EXPECT" ] || [ "$EXPECT" = "$PANE:$PID:$SID" ] || die 'the armed source pane/process/session changed; leaving it alone'
HANDLE=$(opt '#{@wid}'); ORIGIN=$(opt '#{@origin}'); PREVIOUS=$(opt '#{@handoff_manifest}')
STATE=$(opt '#{@claude_state}')
if [ "$INSPECT" = 1 ]; then
  python3 - "$SOURCE_AGENT" "$SID" "$PID" "$TRANSCRIPT" "$CODEX_SOURCE_HOME" "$REGISTRY" "$SESS" "$WIN" "$PANE" "$WT" "$STATE" "$PREVIOUS" "$(opt '#{@cc_account}')" "$(opt '#{@subscription_identity}')" "$(opt '#{@codex_identity}')" <<'PY'
import json, sys
keys = ('agent','session_id','pid','transcript','home','registry','session','window','pane','worktree','state','previous','label','subscription','codex_identity')
r = dict(zip(keys,sys.argv[1:])); r['pid'] = int(r['pid'])
for key in ('subscription','codex_identity'):
    r[key] = json.loads(r[key] or '{}')
print(json.dumps(r))
PY
  exit $?
fi
source_ready() {
  if [ -n "$QUOTA_REQUEST" ]; then
    python3 "$BIN/.fleet-failover.py" validate "$QUOTA_REQUEST" --session "$SESS" --pane "$PANE" --sid "$SID"
  else
    [ "$(opt '#{@claude_state}')" = done ]
  fi
}
[ -z "$NOTES" ] || [ -s "$NOTES" ] || die '--handoff file is missing or empty'
[ -z "$LOOP" ] || [ -s "$LOOP" ] || die '--loop file is missing or empty'
if [ -n "$LOOP" ]; then
  python3 - "$BIN/fleet-loop.py" "$LOOP" <<'PY' || die 'invalid loop spec'
import json, runpy, sys
runpy.run_path(sys.argv[1])['spec'](json.load(open(sys.argv[2])))
PY
fi
printf 'fleet-transfer: %s/%s · %s → %s\nsource session: %s\nsource transcript: %s\nworktree: %s\n' \
  "$SESS" "${HANDLE:-$WIN}" "$SOURCE_AGENT" "$TO" "$SID" "$TRANSCRIPT" "$WT"
if [ "$DRY" = 1 ]; then
  printf 'dry-run: save a provenance package, /exit the source, then launch Codex in %s (state=%s).\n' "$PANE" "${STATE:-unknown}"
  [ "$STATE" = "done" ] || printf 'cutover would refuse until the source reaches done.\n'
  exit 0
fi

umask 077
LAUNCH="$BIN/fleet-claude.sh"
if [ "$PREPARE" != 1 ]; then
  if [ "$AFTER" != 1 ]; then
    source_ready || die 'source is not safely idle; finish/pause its turn before transferring'
    CALLER_TMUX="${TMUX:-}"
    [ "${TMUX_PANE:-}" != "$PANE" ] || [ "${CALLER_TMUX%%,*}" != "$(opt '#{socket_path}')" ] \
      || die 'run cutover from another pane/terminal; use --after-turn inside the source'
  fi
  command -v "$TO" >/dev/null 2>&1 || die "$TO is not on PATH"
  [ -x "$LAUNCH" ] && [ -x "$BIN/fleet-codex.sh" ] || die 'fleet Codex launcher is missing'
  [ "$SOURCE_AGENT" = codex ] || [ "$(opt '#{@handoff_armed}')" != 1 ] || die 'a Claude auto-handoff is pending; finish it first'
  PENDING=$(opt '#{@agent_transfer_request}')
  if [ -n "$REQUEST" ]; then
    [ -n "$EXPECT" ] && [ "$PENDING" = "$REQUEST" ] \
      && [ "$(opt '#{@agent_transfer_ready}')" = "$REQUEST" ] || die 'the armed transfer no longer owns this pane'
  else
    [ -z "$PENDING" ] || die "an after-turn transfer is pending: $PENDING"
  fi
  # This install must include the exit-hook exemption before it can cut over.
  grep -q '@agent_transfer_until' "$BIN/session-end-hook.sh" || die 'SessionEnd transfer support is missing'
  HOOKS=$(bash "$BIN/fleet-hooks-emit.sh" --target "$TO" --root "$BIN/..") || die 'cannot materialize target guard hooks'
  case "$HOOKS" in *base-readonly-guard.py*bash-guard.py*|*bash-guard.py*base-readonly-guard.py*) : ;; *) die 'Codex guard hooks are incomplete' ;; esac
  TM set-option -w -t "$WIN" @worktree "$WT" || die 'cannot record verified worktree'
  [ -z "$TARGET_FILE" ] || bash "$BIN/fleet-account.sh" check-target "$TARGET_FILE" >/dev/null || die 'pinned target is unavailable'
fi

if [ "$AFTER" = 1 ]; then
  grep -q '@agent_transfer_ready' "$BIN/set-claude-state.sh" || die 'Stop-hook transfer support is missing'
  exec python3 "$BIN/.fleet-transfer-wait.py" arm --session "$SESS" --window "$WIN" \
    --pane "$PANE" --pid "$PID" --sid "$SID" --worktree "$WT" --main "$MAIN" \
    --registry "$REGISTRY" --transcript "$TRANSCRIPT" --notes "$NOTES" --source-agent "$SOURCE_AGENT" \
    --to "$TO" --target-file "$TARGET_FILE" --draft-file "$DRAFT" \
    --loop "$LOOP" --codex-home "$CODEX_TARGET_HOME" \
    --conf-dir "$FLEET_CONF_DIR" --lock "$(fleet_rotate_lease_file "$WT").transfer-lock" \
    --idle-wait "${FLEET_TRANSFER_IDLE_WAIT:-240}" --defer "${FLEET_HANDOFF_DEFER_SECS:-30}"
fi

[ -z "$QUOTA_REQUEST" ] || [ ! -s "$QUOTA_REQUEST/unsent-draft.txt" ] || DRAFT="$QUOTA_REQUEST/unsent-draft.txt"
package_flags=(); [ "$NATIVE" = 0 ] || package_flags+=(--native-resume)

BUNDLE=$(python3 "$HELPER" package --output "$FLEET_CONF_DIR/handoffs" --main "$MAIN" \
  --worktree "$WT" --sid "$SID" --transcript "$TRANSCRIPT" --registry "$REGISTRY" --pid "$PID" \
  --source-agent "$SOURCE_AGENT" --codex-home "$CODEX_SOURCE_HOME" --target-home "$CODEX_TARGET_HOME" \
  --session "$SESS" --window "$WIN" --pane "$PANE" --handle "$HANDLE" --issue "$ISSUE" \
  --origin "$ORIGIN" --repo "${FLEET_REPO:-}" --handoff "$NOTES" --previous "$PREVIOUS" --loop "$LOOP" --launcher "$LAUNCH" \
  --to "$TO" --target-file "$TARGET_FILE" --quota-request "$QUOTA_REQUEST" --draft-file "$DRAFT" ${package_flags[@]+"${package_flags[@]}"}) || exit 1
printf 'handoff package: %s\n' "$BUNDLE"
[ "$PREPARE" != 1 ] || exit 0

# One transfer per worktree. mkdir is atomic; a killed controller leaves a lock
# for explicit inspection, rather than allowing a second controller to guess.
LOCK="$(fleet_rotate_lease_file "$WT").transfer-lock"
if [ -n "$REQUEST" ]; then
  [ "$(cat "$LOCK/request" 2>/dev/null)" = "$REQUEST" ] || die 'the after-turn worker no longer owns the worktree lock'
else
  mkdir "$LOCK" 2>/dev/null || die "another transfer owns $LOCK; inspect it before retrying"
fi
printf '%s\n' "$$" > "$LOCK/pid"
EXIT_SENT=0 LEASE=0 SUCCESS=0
REMAIN=$(opt '#{remain-on-exit}')
cleanup() {
  local rc=$?
  if [ "$SUCCESS" != 1 ]; then
    python3 "$HELPER" state "$BUNDLE" failed 'Inspect the pane; resume-source.sh is for manual recovery only after Codex is stopped.' >/dev/null 2>&1 || :
    printf 'fleet-transfer: transfer incomplete; handoff preserved at %s\n' "$BUNDLE" >&2
    printf 'After confirming no Codex is writing, source recovery: bash %q\n' "$BUNDLE/resume-source.sh" >&2
  fi
  TM set-option -wu -t "$WIN" @agent_transfer_until 2>/dev/null || :
  # After /exit, keep the bounded lease on failure: a shell/dead pane and the
  # recovery packet remain available while the operator inspects the failure.
  if [ "$LEASE" = 1 ] && { [ "$SUCCESS" = 1 ] || [ "$EXIT_SENT" = 0 ] || kill -0 "$PID" 2>/dev/null; }; then fleet_rotate_lease_drop "$WT"; fi
  if [ "$EXIT_SENT" = 0 ] || [ "$SUCCESS" = 1 ] || kill -0 "$PID" 2>/dev/null; then
    TM set-option -p -t "$PANE" remain-on-exit "${REMAIN:-off}" 2>/dev/null || :
  fi
  # An after-turn worker owns the shared lock until it has recorded the outcome.
  if [ -z "$REQUEST" ]; then rm -f "$LOCK/pid"; rmdir "$LOCK" 2>/dev/null || :; fi
  return "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT TERM HUP
fleet_rotate_lease_held "$WT" >/dev/null && die 'worktree already has a migration lease'
fleet_rotate_lease_take "$WT" "transfer $SESS/$WIN $SOURCE_AGENT to $TO" 900 || die 'cannot protect worktree from cleanup'
LEASE=1
TM set-option -w -t "$WIN" @agent_transfer_until "$(( $(date +%s) + 120 ))" || die 'cannot mark transfer'
TM set-option -p -t "$PANE" remain-on-exit on || die 'cannot retain source pane on exit'
# Recheck identity and evidence AFTER exporting and acquiring the lease. A /clear,
# new turn, or another process must not inherit an earlier session's handoff.
if [ "$SOURCE_AGENT" = codex ]; then
  [ "$(python3 "$HELPER" source-codex --pane "$PANE" --socket "$SOCK" --worktree "$WT")" = "$RESOLVED" ] \
    || die 'Codex source changed while preparing the transfer'
else
  [ "$(fleet_pane_claude_pid "$PANE" "$SOCK")" = "$PID" ] && [ "$(fleet_cc_session_id "$PID")" = "$SID" ] \
    && [ "$(opt '#{@handoff_armed}')" != 1 ] || die 'source changed while preparing the transfer'
fi
source_ready || die 'source started another turn while preparing the transfer'
[ -z "$TARGET_FILE" ] || bash "$BIN/fleet-account.sh" check-target "$TARGET_FILE" >/dev/null || die 'pinned target changed before source exit'
if [ "$REQUIRE_IDLE" = 1 ]; then
  [ "$SOURCE_AGENT" = codex ] || die 'native idle check requires a Codex source'
  FLEET_CONF_DIR="$FLEET_CONF_DIR" "$BIN/fleet-codex-account.sh" idle --session "$SESS" --window "$PANE" \
    || die 'Codex source is not natively idle; leaving it alone'
fi
python3 "$HELPER" verify "$BUNDLE" || die 'source changed while preparing the transfer'
TM capture-pane -p -t "$PANE" > "$BUNDLE/pane-before-exit.txt" || die 'cannot preserve source screen before exiting'
chmod 600 "$BUNDLE/pane-before-exit.txt" || die 'cannot protect source screen snapshot'

EXIT_WAIT="${FLEET_TRANSFER_EXIT_WAIT:-30}"; BOOT_WAIT="${FLEET_TRANSFER_BOOT_WAIT:-15}"
case "$EXIT_WAIT:$BOOT_WAIT" in *[!0-9:]*|:*|*:) die 'transfer timeouts must be positive integer seconds' ;; esac
[ "$EXIT_WAIT" -gt 0 ] && [ "$BOOT_WAIT" -gt 0 ] && [ "$EXIT_WAIT" -le 60 ] && [ "$BOOT_WAIT" -le 30 ] \
  || die 'transfer timeout bounds: exit 1..60 seconds, boot 1..30 seconds'
EXIT_SENT=1
SK Escape || die 'cannot address source prompt'
SK C-u || die 'cannot clear source prompt'
SK -l '/exit' || die 'cannot type source exit'
SK Enter || die 'cannot submit source exit'
EXIT_CONFIRMED=0
for ((i=0; i<EXIT_WAIT; i++)); do
  kill -0 "$PID" 2>/dev/null || break
  # A live ScheduleWakeup adds a native exit dialog. --loop authorizes moving
  # that one timer, so stop it at the source before starting the replacement.
  # Only the exact selected one-timer dialog may get ONE additional Enter.
  if [ -n "$LOOP" ] && [ "$EXIT_CONFIRMED" = 0 ] \
    && TM capture-pane -p -t "$PANE" | python3 "$HELPER" loop-exit-confirmation; then
    [ "$(fleet_pane_claude_pid "$PANE" "$SOCK")" = "$PID" ] \
      && [ "$(fleet_cc_session_id "$PID")" = "$SID" ] \
      || die 'source changed at the loop exit confirmation'
    python3 "$HELPER" verify "$BUNDLE" || die 'source transcript changed at the loop exit confirmation'
    TM capture-pane -p -t "$PANE" > "$BUNDLE/loop-exit-confirmation.txt" || die 'cannot preserve loop exit confirmation'
    SK Enter || die 'cannot confirm stopping the source loop'
    EXIT_CONFIRMED=1
  fi
  sleep 1
done
kill -0 "$PID" 2>/dev/null && die 'source did not exit; no replacement Codex was launched'
python3 "$HELPER" state "$BUNDLE" source_exited || die 'cannot record source exit'
[ "$(opt '#{window_id}')" = "$WIN" ] || die 'source window was closed by an older hook; use the saved handoff to recover'
fleet_pane_claude_pid "$PANE" "$SOCK" >/dev/null 2>&1 && die 'another Claude appeared; leaving the pane alone'
if [ "$(opt '#{pane_dead}')" != 1 ]; then
  # The fleet runner execs the shell after the agent. Allow that brief transition.
  SHELL_OK=0
  for ((i=0; i<30; i++)); do
    if python3 "$HELPER" process shell "$(opt '#{pane_pid}')"; then SHELL_OK=1; break; fi
    sleep 1
  done
  [ "$SHELL_OK" = 1 ] || die 'source pane is not a childless shell; refusing to replace it'
fi

# The helper quotes metadata as argv; conversation text is only ever data.
python3 "$HELPER" launcher "$BUNDLE" "$LAUNCH" || die 'cannot write target launcher'
for key in @cc_account @subscription_identity @codex_identity @cc_model @ctx_pct @ctx_limit @handoff_armed @handoff_cleared_at; do
  TM set-option -wu -t "$WIN" "$key" 2>/dev/null || :
done
TM set-option -w -t "$WIN" @cc_agent "$TO" || die 'cannot stamp target agent'
TM set-option -w -t "$WIN" @handoff_manifest "$BUNDLE/manifest.json" || die 'cannot stamp provenance'
TM set-option -w -t "$WIN" @source_agent "$SOURCE_AGENT" || die 'cannot stamp source agent'
TM set-option -w -t "$WIN" @source_session_id "$SID" || die 'cannot stamp source session'
TM set-option -w -t "$WIN" @source_transcript "$TRANSCRIPT" || die 'cannot stamp source transcript'
TM set-option -w -t "$WIN" @claude_state working || die 'cannot stamp target state'
printf -v CMD 'exec bash %q' "$BUNDLE/launch.sh"
python3 "$HELPER" state "$BUNDLE" starting || die 'cannot record target launch'
# -k only replaces the verified leftover shell; Claude is already confirmed gone.
TM respawn-pane -k -t "$PANE" -c "$WT" "$CMD" || die 'could not launch Codex in the retained pane'
CPID=''
for ((i=0; i<BOOT_WAIT; i++)); do
  if [ -n "$TARGET_FILE" ] || [ "$TO" = claude ]; then
    CPID=$(python3 "$HELPER" target-ready "$BUNDLE" "$SOCK" "$PANE" 2>/dev/null) && [ -n "$CPID" ] && break
  else
    CPID=$(python3 "$HELPER" process codex "$(opt '#{pane_pid}')" 2>/dev/null) && [ -n "$CPID" ] && break
  fi
  [ "$(opt '#{pane_dead}')" != 1 ] || break
  sleep 1
done
[ -n "$CPID" ] || die 'target session did not bind; inspect the retained pane and handoff package'
python3 "$HELPER" state "$BUNDLE" started "$TO identity $CPID; task completion is not implied." || die 'cannot record target startup'
SUCCESS=1
printf '%s started in %s/%s (identity %s). Source provenance: %s\n' "$TO" "$SESS" "${HANDLE:-$WIN}" "$CPID" "$BUNDLE/manifest.json"
