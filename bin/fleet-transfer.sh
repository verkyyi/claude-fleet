#!/bin/bash
# fleet-transfer.sh — hand ONE Claude/Codex session to either agent in its existing pane.
#
# Usage: fleet-transfer.sh --session <fleet> --window <handle|name|@id> --to claude|codex
#                         [--handoff <notes.md>] [--loop <spec.json>] [--codex-home DIR]
#                         [--dry-run | --prepare-only | --after-turn]
#        fleet-transfer.sh --retry <retry-request-dir>
#
# --dry-run       Resolve exact provenance and print the plan; write nothing.
# --prepare-only  Save the handoff package; leave Claude and tmux unchanged.
# --after-turn    Arm from /fleet-handoff; wait for this turn's Stop before switching.
#                 Requires --handoff. Returns after arming, without exiting Claude.
# --loop          Explicit recurring prompt + interval to continue on Codex.
# --handoff       Optional source-agent notes. Without notes, Codex reconstructs
#                 the task from the captured conversation and current git state.
# --retry         Run a switch that a dead TARGET login stopped (issue #1669) once
#                 more, with its original arguments: exit 0 switched, 3 the target
#                 still cannot log in (left pending), 1 failed (never retried again).
#
# Supports Claude → Codex and Codex context cycling. No bulk mode, transcript guessing, git mutation,
# automatic source restart, or forced agent termination. A cutover requires @claude_state
# done (or a Codex `looping` between rounds), one worker pane, a registered source session, and its own linked git worktree.
# The TARGET account must be able to log in (issue #1667): --dry-run and the first
# step of a cutover ask `fleet-account.sh target-auth` (check-target for a pinned
# target), again right before /exit; a refusal — `target-auth: …`, exit 1 — leaves
# the source running, records `<quota-request>/refused.json` for the planner and a
# ▲ `transfer-refused` row in the alerts popup.
# A target that does not bind (issue #1668) is ROLLED BACK in the same pane: the
# source is relaunched from the package's `resume-source.sh --run-source` (Claude
# --resume <id> / codex resume <id>, cwd the worktree), the same session id is
# confirmed, state.json says `rolled_back`, @transfer_note carries
# 「切换失败，已退回：<why>」 and a ▲ `transfer-rolled-back` row is raised; exit 1.
# A source that does not come back either stays `failed` (▲ `transfer-failed`),
# pane retained — one rollback, never a loop. For FLEET_TRANSFER_ROLLBACK_HOLD
# (1800s) after a rollback an AUTOMATIC cutover (quota failover, after-turn) on
# that window refuses; a manual one, or `tmux set -wu @transfer_rolled_back`, goes.
# Either stop caused by the TARGET's login — a target-auth refusal of a switch the
# planner does not own, or a rollback after which the target's login is refused —
# leaves a retry record (issue #1669, EPIC #1665 C5): handoffs/retry/<fleet>-<id>/,
# one per window. Once that login is fixed, fleet-relogin.sh runs `--retry <dir>`:
# the same arguments, the same conversation (session id checked), ONCE — the retry
# writes no record of its own, so a retry that fails again ends `failed`.
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
# shellcheck source=/dev/null
. "$BIN/usage-lib.sh"          # fleet_limit_banner — the wall this cutover leaves behind (#870)
HELPER="$BIN/.fleet-transfer.py"

die() { FAILURE=$*; printf 'fleet-transfer: %s\n' "$*" >&2; exit 1; }
usage() { sed -n '2,34p' "$0" | sed 's/^# \{0,1\}//'; }
SESS='' TARGET='' TO='' NOTES='' LOOP='' DRY=0 PREPARE=0 AFTER=0 EXPECT='' REQUEST='' CODEX_TARGET_HOME='' REQUIRE_IDLE=0
TARGET_FILE='' QUOTA_REQUEST='' DRAFT='' INSPECT=0 NATIVE=0 RETRY='' EXPECT_SID=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --session|--window|--to|--handoff|--loop|--expected-source|--armed-request|--target-file|--quota-request|--draft-file|--codex-home|--retry|--expected-session-id)
      [ "$#" -ge 2 ] && [ -n "$2" ] || die "$1 needs a value"
      case "$1" in
        --session) SESS=$2 ;;
        --window) [ -z "$TARGET" ] || die 'only one --window is allowed'; TARGET=$2 ;;
        --to) TO=$2 ;; --handoff) NOTES=$2 ;;
        --loop) LOOP=$2 ;;
        --target-file) TARGET_FILE=$2 ;; --quota-request) QUOTA_REQUEST=$2 ;; --draft-file) DRAFT=$2 ;;
        --codex-home) CODEX_TARGET_HOME=$2 ;;
        --expected-source) EXPECT=$2 ;; --armed-request) REQUEST=$2 ;;
        --retry) RETRY=$2 ;; --expected-session-id) EXPECT_SID=$2 ;;
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
# target_auth — may the TARGET account start an agent? (issue #1667, EPIC #1665 C3)
# Asked BEFORE anything is written and again right before /exit, so a target whose
# login ccquota has marked reauth_required — or a Claude label marked by
# mark-reauth, or whose hub token expired — is refused while the source still
# runs. 2026-10-05 was the opposite order: source /exit'ed, Codex at a login
# prompt, conversation gone. The ONE judge is fleet-account.sh target-auth
# (check-target for the planner's pinned target); `unknown` — no ccquota registry,
# multi-account off — is NOT a refusal, the launch then behaves as it always did,
# but a judge that cannot answer at all is (never guess a login). On 0 TARGET_AUTH
# carries the verdict line; on 1 TARGET_AUTH_WHY carries the reason, and
# TARGET_AUTH_WAIT the login a retry waits on (`<agent>/<profile>`, `<agent>/*`
# for a pool with none usable — issue #1669). Defined before anything else runs:
# `--retry` asks it before any window is resolved.
TARGET_AUTH='' TARGET_AUTH_WHY='' TARGET_AUTH_WAIT=''
_json_field() { printf '%s\n' "$1" | sed -n "s/.*\"$2\": *\"\([^\"]*\)\".*/\1/p" | sed -n '1p'; }
target_auth() {
  local out rc=0 verdict reason pin
  TARGET_AUTH='' TARGET_AUTH_WHY='' TARGET_AUTH_WAIT=''
  if [ -n "$TARGET_FILE" ]; then
    pin=$(cat "$TARGET_FILE" 2>/dev/null)
    TARGET_AUTH_WAIT="$TO/$(_json_field "$pin" profile)"; [ "$TARGET_AUTH_WAIT" != "$TO/" ] || TARGET_AUTH_WAIT="$TO/$(_json_field "$pin" label)"
    out=$(bash "$BIN/fleet-account.sh" check-target "$TARGET_FILE" 2>&1 >/dev/null) || rc=$?
    if [ "$rc" = 0 ]; then TARGET_AUTH="ok · pinned $(_json_field "$(cat "$TARGET_FILE" 2>/dev/null)" key)"; return 0; fi
    out=${out##*fleet-account: }; TARGET_AUTH_WHY="${out#target-auth: }"
    [ -n "$TARGET_AUTH_WHY" ] || TARGET_AUTH_WHY='pinned target is unavailable'
    return 1
  fi
  out=$(bash "$BIN/fleet-account.sh" target-auth --agent "$TO" ${CODEX_TARGET_HOME:+--home "$CODEX_TARGET_HOME"} 2>&1) || rc=$?
  verdict=$(_json_field "$out" verdict); reason=$(_json_field "$out" reason)
  TARGET_AUTH_WAIT="$TO/$(_json_field "$out" profile)"; [ "$TARGET_AUTH_WAIT" != "$TO/" ] || TARGET_AUTH_WAIT="$TO/$(_json_field "$out" label)"
  case "$verdict" in
    ok) TARGET_AUTH="ok · $(_json_field "$out" key)"; return 0 ;;
    unknown) TARGET_AUTH="unknown · $reason"; return 0 ;;
    refuse) TARGET_AUTH_WHY="$reason"; return 1 ;;
  esac
  [ "$TARGET_AUTH_WAIT" != "$TO/" ] || TARGET_AUTH_WAIT="$TO/*"
  TARGET_AUTH_WHY="the login check itself failed: $(printf '%s\n' "$out" | sed -n '/./{p;q;}')"
  return 1
}
# retry_main <dir> — `--retry` (issue #1669, EPIC #1665 C5): run a switch a dead
# TARGET login stopped once more, with the arguments its record kept. The target
# is asked first — still refused ⇒ exit 3 and the record stays pending (nothing
# consumed, the next login retries it). Then the record is CLAIMED (pending →
# retrying, atomic: of two resumes one runs it) and this script runs again as a
# child with FLEET_TRANSFER_RETRYING set, so the child writes no record of its
# own: a retry that is refused or rolls back again ends `failed` — once, never a
# loop. A source mid-turn is the one outcome that gives the claim back (pending).
# The window is found by its lifelong @fleet_id, and the child refuses unless it
# still runs the SAME conversation (--expected-session-id).
retry_main() {
  local dir=$1 line sess fid sid tf ch notes loop win rc out why
  dir=$(cd "$dir" 2>/dev/null && pwd -P) || die "--retry: no retry request at $1"
  line=$(python3 "$HELPER" retry-show "$dir") || exit 1
  IFS=$'\x1f' read -r sess fid TO sid tf ch notes loop <<< "$line"
  case "$sess" in ''|*[!A-Za-z0-9_-]*) die '--retry: the request names no valid fleet' ;; esac
  [ -f "$FLEET_CONF_DIR/fleets/$sess/conf" ] && fleet_load_conf "$sess" || die "--retry: cannot load fleet $sess"
  SOCK=$(fleet_socket "$sess")
  if ! win=$(fleet_win_for_fid "$fid" "$SOCK") || [ -z "$win" ]; then
    python3 "$HELPER" retry-finish "$dir" cancelled 'the window is gone' || :
    die '--retry: the window that was to switch is gone; cancelled'
  fi
  TARGET_FILE=$tf CODEX_TARGET_HOME=$ch
  # A positive `ok` only: the record exists because the judge once said refuse,
  # so a judge that cannot answer now (`unknown`) is no evidence of a fixed login.
  if ! target_auth || [ "${TARGET_AUTH%% *}" != ok ]; then
    printf 'fleet-transfer: retry waits: %s still cannot log in · %s\n' "$TARGET_AUTH_WAIT" "${TARGET_AUTH_WHY:-$TARGET_AUTH}" >&2
    exit 3
  fi
  python3 "$HELPER" retry-claim "$dir" || exit 1
  set -- --session "$sess" --window "$win" --to "$TO" --expected-session-id "$sid"
  [ -z "$tf" ] || set -- "$@" --target-file "$tf"
  [ -z "$ch" ] || set -- "$@" --codex-home "$ch"
  [ -z "$notes" ] || [ ! -s "$notes" ] || set -- "$@" --handoff "$notes"
  [ -z "$loop" ] || [ ! -s "$loop" ] || set -- "$@" --loop "$loop"
  out=$(FLEET_TRANSFER_RETRYING="$dir" bash "$0" "$@" 2>&1); rc=$?
  printf '%s\n' "$out" > "$dir/transfer.log"; chmod 600 "$dir/transfer.log" 2>/dev/null
  printf '%s\n' "$out"
  if [ "$rc" = 0 ]; then
    python3 "$HELPER" retry-finish "$dir" 'done' "switched to $TO after the login was fixed" || :
    [ -x "$BIN/fleet-alerts.sh" ] && bash "$BIN/fleet-alerts.sh" event -L "$SOCK" transfer-retried \
      "$(TM_RETRY "$win" '#{?@wid,#{@wid},#{window_name}}'): 重新登录后已自动切到 $TO · switched after the login was fixed" >/dev/null 2>&1 || :
    return 0
  fi
  case "$out" in
    *'source is not safely idle'*)
      python3 "$HELPER" retry-finish "$dir" pending 'the source was mid-turn; retried at the next login check' || :
      printf 'fleet-transfer: retry deferred: the source is mid-turn; still pending\n' >&2
      exit 3 ;;
  esac
  why=$(printf '%s\n' "$out" | grep '^fleet-transfer: ' | tail -n 1); why=${why#fleet-transfer: }
  python3 "$HELPER" retry-finish "$dir" failed "${why:-the retry did not switch (exit $rc)}" || :
  [ -x "$BIN/fleet-alerts.sh" ] && bash "$BIN/fleet-alerts.sh" event -L "$SOCK" transfer-retry-failed \
    "$(TM_RETRY "$win" '#{?@wid,#{@wid},#{window_name}}'): 登录后重试切换失败，不再重试 · retry failed: ${why:-exit $rc}" >/dev/null 2>&1 || :
  exit 1
}
TM_RETRY() { tmux -L "$SOCK" display-message -p -t "$1" "$2" 2>/dev/null; }
if [ -n "$RETRY" ]; then
  [ -z "$TARGET$TO$SESS" ] || die '--retry takes its arguments from the request; pass nothing else'
  retry_main "$RETRY"; exit $?
fi
[ -n "$TARGET" ] || { usage >&2; exit 2; }
case "$TO" in claude|codex) ;; *) usage >&2; exit 2;; esac
[ "$((DRY + PREPARE + AFTER))" -le 1 ] || die '--dry-run, --prepare-only and --after-turn are mutually exclusive'
[ "$AFTER" != 1 ] || [ -n "$NOTES" ] || die '--after-turn requires --handoff notes written by the source agent'
[ "$NATIVE:$AFTER" != 1:1 ] || die '--native-resume is a controller-only immediate operation'
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
TARGET=$(fleet_wid_target "$TARGET" "$SOCK") && [ -n "$TARGET" ] || die 'no live window carries that handle'
WIN=$(TM display-message -p -t "$TARGET" '#{window_id}' 2>/dev/null) || die 'window not found'
# A TASKS sidebar is an auxiliary pane, never a second worker. Resolve the sole
# worker explicitly, including when a sidebar happens to be the active pane.
PANE=$(TM list-panes -t "$WIN" -F '#{pane_id}|#{@sidebar}' 2>/dev/null \
  | awk -F'|' '$2 != "1" { pane=$1; n++ } END { if (n == 1) print pane; else exit 1 }') \
  || die 'transfer requires exactly one worker pane (sidebars are allowed)'
[ "$(opt '#{session_name}')" = "$SESS" ] || die 'window belongs to a different session'
case "$(opt '#{window_name}')" in dash|plan|backlog|home) die 'panel windows cannot be transferred' ;; esac
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
if fleet_has_repo_overlays "$SESS"; then
  # "Registered to this fleet" = registered to ANY repo it hosts (issue #791); the
  # repo that registers it is the one the handoff records.
  IFS=$'\t' read -r _wrepo _wmain <<< "$(fleet_worktree_repo "$SESS" "$WT")"
  [ -n "${_wmain:-}" ] || die 'worktree is not registered to this fleet'
  FLEET_REPO=$_wrepo; FLEET_MAIN=$_wmain
fi
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
[ -z "$EXPECT_SID" ] || [ "$EXPECT_SID" = "$SID" ] || die "retry: the window now runs a different conversation ($SID, not $EXPECT_SID); not switching it"
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
    # A `looping` Codex source between rounds is as settled as `done`: its idle
    # native thread, no live item and a completed last turn are checked, never
    # assumed from the tmux flag (#786).
    # A `looping` CLAUDE source is settled only when the Stop hook wrote it off
    # this pane's own @loop mark (issue #1331: a /loop between rounds) — never off
    # a screen-classifier read.
    case "$(opt '#{@claude_state}')" in
      done) return 0 ;;
      looping) if [ "$SOURCE_AGENT" = codex ]; then
                 python3 "$BIN/.fleet-failover.py" settled --session "$SESS" --pane "$PANE"
               else
                 [ -n "$(opt '#{@loop}')" ] \
                   && python3 "$BIN/fleet_loop_mark.py" status --value "$(opt '#{@loop}')" >/dev/null 2>&1
               fi ;;
      *) return 1 ;;
    esac
  fi
}
# refuse_target — the one exit for a target-auth refusal on a real cutover: the
# planner's `refused.json` (its request dir, so failover-status can name the
# reason), a ▲ row in the alerts popup (a toast nobody was looking at is gone in
# 2s, #1617), then die. Nothing has been written to the pane or the worktree at
# either call site; after the lease is held the EXIT trap tidies as for any die.
# record_retry <origin> — leave the retry record for a switch the TARGET's login
# stopped (issue #1669), and say so in RETRY_NOTE. Never from a retry's own run
# (FLEET_TRANSFER_RETRYING: that is what keeps a retry from looping), never for a
# dry run or a prepare. A failure to record never changes the exit it rides on.
RETRY_NOTE=''
record_retry() {
  local fid dir
  [ -z "${FLEET_TRANSFER_RETRYING:-}" ] && [ "$DRY" != 1 ] && [ "$PREPARE" != 1 ] || return 0
  fid=$(fleet_window_fid "$SESS" "$WIN" "$SOCK") || return 0
  dir=$(python3 "$HELPER" retry-record --session "$SESS" --fid "$fid" --window "$WIN" --handle "${HANDLE:-$WIN}" \
    --to "$TO" --sid "$SID" --why "target-auth: $TARGET_AUTH_WHY" --wait "$TARGET_AUTH_WAIT" --origin "$1" \
    --bundle "${BUNDLE:-}" --target-file "$TARGET_FILE" --codex-home "$CODEX_TARGET_HOME" \
    --handoff "$NOTES" --loop "$LOOP" 2>/dev/null) || return 0
  RETRY_NOTE=" · 登录后自动重试 · retried after $TARGET_AUTH_WAIT logs in again"
  printf 'fleet-transfer: retry recorded: %s\n' "$dir" >&2
}
refuse_target() {
  # A refusal the failover planner owns is retried by the planner (it re-picks a
  # target every tick); any other is retried once the login is fixed.
  [ -n "$QUOTA_REQUEST" ] || record_retry refused
  if [ -n "$QUOTA_REQUEST" ] && [ -d "$QUOTA_REQUEST" ]; then
    python3 - "$QUOTA_REQUEST/refused.json" "$TARGET_AUTH_WHY" "$TO" <<'PY' 2>/dev/null || :
import json, os, sys, time
path, detail, to = sys.argv[1:]
fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, 'w') as stream:
    json.dump(dict(reason='target-auth', detail=detail, to=to, at=time.time()), stream)
PY
  fi
  [ -x "$BIN/fleet-alerts.sh" ] && bash "$BIN/fleet-alerts.sh" event -L "$SOCK" transfer-refused \
    "${HANDLE:-$WIN}: 未切换：$TO 需要重新登录 · not switched: $TARGET_AUTH_WHY$RETRY_NOTE" >/dev/null 2>&1 || :
  die "target-auth: $TARGET_AUTH_WHY — not switched; the source keeps running (log in to the target, then retry)"
}
# rollback_hold — a window rolled back by issue #1668 within FLEET_TRANSFER_ROLLBACK_HOLD
# seconds is not cut over AUTOMATICALLY again: the rolled-back source has a new pid,
# so the failover planner sees a fresh request and would relaunch the same broken
# target, kill the source, roll back — every tick. The refusal is as cheap as
# target-auth's (nothing written yet) and lands in refused.json the same way.
rollback_hold() {
  local at hold="${FLEET_TRANSFER_ROLLBACK_HOLD:-1800}" now
  case "$hold" in ''|*[!0-9]*) hold=1800 ;; esac
  at=$(opt '#{@transfer_rolled_back}'); case "$at" in ''|*[!0-9]*) return 0 ;; esac
  now=$(date +%s)
  [ $(( now - at )) -lt "$hold" ] || return 0
  TARGET_AUTH_WHY="rolled back $(( now - at ))s ago: $(opt '#{@transfer_note}')"
  if [ -n "$QUOTA_REQUEST" ] && [ -d "$QUOTA_REQUEST" ]; then
    python3 - "$QUOTA_REQUEST/refused.json" "$TARGET_AUTH_WHY" "$TO" <<'PY' 2>/dev/null || :
import json, os, sys, time
path, detail, to = sys.argv[1:]
fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, 'w') as stream:
    json.dump(dict(reason='rolled-back', detail=detail, to=to, at=time.time()), stream)
PY
  fi
  die "rolled-back: $TARGET_AUTH_WHY — no automatic retry for ${hold}s; switch by hand, or clear @transfer_rolled_back"
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
  # The target's login, first (issue #1667): a dry-run that says «would switch»
  # onto an account that cannot log in is the plan that lost the 10-05 session.
  if target_auth; then printf 'target auth: %s\n' "$TARGET_AUTH"
  else
    printf 'target auth: REFUSED · %s\n' "$TARGET_AUTH_WHY"
    die "target-auth: $TARGET_AUTH_WHY — a cutover would not switch; log in to the target first"
  fi
  printf 'dry-run: save a provenance package, /exit the source, then launch %s in %s (state=%s).\n' "$TO" "$PANE" "${STATE:-unknown}"
  [ "$STATE" = "done" ] || [ "$STATE" = looping ] || printf 'cutover would refuse until the source reaches done.\n'
  exit 0
fi

umask 077
LAUNCH="$BIN/fleet-session-wrap.sh"
if [ "$PREPARE" != 1 ]; then
  # Step one of any cutover or arming (issue #1667): the target must be able to
  # log in, or nothing below runs — the source is not even asked whether it is idle.
  target_auth || refuse_target
  { [ -z "$QUOTA_REQUEST" ] && [ -z "$REQUEST" ] && [ "$AFTER" != 1 ]; } || rollback_hold
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
EXIT_SENT=0 LEASE=0 SUCCESS=0 ROLLED=0
REMAIN=$(opt '#{remain-on-exit}')
cleanup() {
  local rc=$?
  if [ "$ROLLED" = 1 ]; then
    printf 'fleet-transfer: %s did not start; the source %s session %s was resumed in place. Handoff kept for a retry: %s\n' \
      "$TO" "$SOURCE_AGENT" "$SID" "$BUNDLE" >&2
  elif [ "$SUCCESS" != 1 ]; then
    python3 "$HELPER" state "$BUNDLE" failed "${FAILURE:-Transfer interrupted; inspect the retained pane before recovery.}" >/dev/null 2>&1 || :
    printf 'fleet-transfer: transfer incomplete; handoff preserved at %s\n' "$BUNDLE" >&2
    printf 'After confirming no Codex is writing, source recovery: bash %q\n' "$BUNDLE/resume-source.sh" >&2
  fi
  TM set-option -wu -t "$WIN" @agent_transfer_until 2>/dev/null || :
  # After /exit, keep the bounded lease on failure: a shell/dead pane and the
  # recovery packet remain available while the operator inspects the failure.
  if [ "$LEASE" = 1 ] && { [ "$SUCCESS" = 1 ] || [ "$ROLLED" = 1 ] || [ "$EXIT_SENT" = 0 ] || fleet_pid_alive "$PID"; }; then fleet_rotate_lease_drop "$WT"; fi
  if [ "$EXIT_SENT" = 0 ] || [ "$SUCCESS" = 1 ] || [ "$ROLLED" = 1 ] || fleet_pid_alive "$PID"; then
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
# The last read before /exit (issue #1667): a login that went bad while the
# package was written still finds the source running.
target_auth || refuse_target
if [ "$REQUIRE_IDLE" = 1 ]; then
  [ "$SOURCE_AGENT" = codex ] || die 'native idle check requires a Codex source'
  FLEET_CONF_DIR="$FLEET_CONF_DIR" "$BIN/fleet-codex-account.sh" idle --session "$SESS" --window "$PANE" \
    || die 'Codex source is not natively idle; leaving it alone'
fi
python3 "$HELPER" verify "$BUNDLE" || die 'source changed while preparing the transfer'
TM capture-pane -p -t "$PANE" > "$BUNDLE/pane-before-exit.txt" || die 'cannot preserve source screen before exiting'
chmod 600 "$BUNDLE/pane-before-exit.txt" || die 'cannot protect source screen snapshot'
# The wall the source is leaving (issue #870): a Claude target re-renders the
# transcript tail on this same pane, and the collector must not credit it to the
# target's account. Stamped with @migrated_at just before the respawn.
WALL=$(TM capture-pane -p -S - -t "$PANE" 2>/dev/null | fleet_limit_banner)

EXIT_WAIT="${FLEET_TRANSFER_EXIT_WAIT:-30}"; BOOT_WAIT="${FLEET_TRANSFER_BOOT_WAIT:-15}"
case "$EXIT_WAIT:$BOOT_WAIT" in *[!0-9:]*|:*|*:) die 'transfer timeouts must be positive integer seconds' ;; esac
[ "$EXIT_WAIT" -gt 0 ] && [ "$BOOT_WAIT" -gt 0 ] && [ "$EXIT_WAIT" -le 60 ] && [ "$BOOT_WAIT" -le 30 ] \
  || die 'transfer timeout bounds: exit 1..60 seconds, boot 1..30 seconds'
EXIT_SENT=1
TM set-option -w -t "$PANE" @wrap_quiet 1 2>/dev/null   # the fleet's own exit: no recovery page (#1784)
SK Escape || die 'cannot address source prompt'
SK C-u || die 'cannot clear source prompt'
if [ "$SOURCE_AGENT" = codex ]; then
  # Codex's unbracketed paste detector can absorb a fast following Enter as a
  # newline, leaving /exit UNSUBMITTED in the composer. Explicit paste framing
  # ends that burst before Enter; no timing guess or second submission needed.
  SK -l $'\033[200~/exit\033[201~' || die 'cannot paste Codex source exit'
else
  SK -l '/exit' || die 'cannot type source exit'
fi
SK Enter || die 'cannot submit source exit'
EXIT_CONFIRMED=0
for ((i=0; i<EXIT_WAIT; i++)); do
  fleet_pid_alive "$PID" || break
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
if fleet_pid_alive "$PID"; then
  TM capture-pane -p -t "$PANE" > "$BUNDLE/pane-exit-timeout.txt" 2>/dev/null || :
  die "source did not exit; no replacement $TO was launched"
fi
python3 "$HELPER" state "$BUNDLE" source_exited || die 'cannot record source exit'
# A hard wall past its grace migrates despite background commands (#871): stop
# the ones validate() recorded and name them in the resume prompt. Past /exit a
# failure here must not strand the pane, so it only warns.
if [ -n "$QUOTA_REQUEST" ]; then
  python3 "$BIN/.fleet-failover.py" terminate-background "$QUOTA_REQUEST" --bundle "$BUNDLE" \
    || printf 'fleet-transfer: warning: could not stop the recorded background commands\n' >&2
fi
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

# rollback <why> — the target did not bind (issue #1668, EPIC #1665 C4). Before
# this the pane was left dead and the conversation waited for someone to notice
# and run resume-source.sh by hand. The source is verified gone and its pane
# was a childless shell, so the same pane takes it back: the window's own stamps
# as the source left them, then `resume-source.sh --run-source` (the recipe the
# package already carries — Claude --resume <id>, codex resume <id>, cwd the
# worktree), then the SAME session id must answer. One attempt: a source that
# does not come back either stays `failed` with the pane retained, never a loop.
# The handoff package is kept, so a retry after the login is fixed starts there.
ROLLBACK_KEYS=(@cc_agent @handoff_manifest @source_agent @source_session_id @source_transcript @migrated_at @migrated_banner)
ROLLBACK_VALS=()
for key in "${ROLLBACK_KEYS[@]}"; do ROLLBACK_VALS+=("$(opt "#{$key}")"); done
rollback() {
  local why=$1 st note cmd back='' got rest i
  # The target's last screen + exit status, before the respawn wipes them; it is
  # private to the package (0600) and never copied into a note or an alert.
  TM capture-pane -p -S - -t "$PANE" > "$BUNDLE/pane-target-failed.txt" 2>/dev/null && chmod 600 "$BUNDLE/pane-target-failed.txt"
  if [ "$(opt '#{pane_dead}')" = 1 ]; then
    # tmux ≤3.4 can mark the pane dead (EOF) before it reaps the child, so the
    # status reads empty for a moment (#1801's missed SIGCHLD): ask again briefly.
    st=$(opt '#{pane_dead_status}')
    for i in 1 2 3 4 5 6 7 8 9 10; do [ -z "$st" ] || break; sleep 0.1; st=$(opt '#{pane_dead_status}'); done
    [ -n "$st" ] || st=$(opt '#{@wrap_last_rc}')
    why="$TO exited at startup (status ${st:-?})"
  fi
  python3 "$HELPER" state "$BUNDLE" target_failed "$why" >/dev/null 2>&1 || :
  for i in "${!ROLLBACK_KEYS[@]}"; do
    if [ -n "${ROLLBACK_VALS[$i]}" ]; then TM set-option -w -t "$WIN" "${ROLLBACK_KEYS[$i]}" "${ROLLBACK_VALS[$i]}" 2>/dev/null || :
    else TM set-option -wu -t "$WIN" "${ROLLBACK_KEYS[$i]}" 2>/dev/null || :; fi
  done
  note="切换失败，已退回：$why"
  # The note is printed into the pane above the resumed source, so the pane
  # itself says what happened even with no bar in view.
  printf -v cmd 'printf "%%s\\n" %q; exec bash %q --run-source' "▲ $note" "$BUNDLE/resume-source.sh"
  if TM respawn-pane -k -t "$PANE" -c "$WT" "$cmd"; then
    for ((i=0; i<BOOT_WAIT; i++)); do
      if [ "$SOURCE_AGENT" = codex ]; then
        got=$(python3 "$HELPER" source-codex --pane "$PANE" --socket "$SOCK" --worktree "$WT" 2>/dev/null) \
          && IFS=$'\t' read -r back rest <<< "$got" && [ "$(printf '%s' "$rest" | cut -f1)" = "$SID" ] && break
      else
        back=$(fleet_pane_claude_pid "$PANE" "$SOCK" 2>/dev/null) && [ "$(fleet_cc_session_id "$back")" = "$SID" ] && break
      fi
      back=''
      [ "$(opt '#{pane_dead}')" != 1 ] || break
      sleep 1
    done
  fi
  if [ -z "$back" ]; then
    TM capture-pane -p -S - -t "$PANE" > "$BUNDLE/pane-rollback-failed.txt" 2>/dev/null && chmod 600 "$BUNDLE/pane-rollback-failed.txt"
    TM set-option -w -t "$WIN" @transfer_note "切换失败，原会话也未能恢复：$why" 2>/dev/null || :
    [ -x "$BIN/fleet-alerts.sh" ] && bash "$BIN/fleet-alerts.sh" event -L "$SOCK" transfer-failed \
      "${HANDLE:-$WIN}: 切换失败，原会话也未能恢复 · $why; source $SOURCE_AGENT $SID did not resume" >/dev/null 2>&1 || :
    die "$why; rollback: the source $SOURCE_AGENT session $SID did not resume either — pane retained, not retrying"
  fi
  python3 "$HELPER" state "$BUNDLE" rolled_back "$why; source $SOURCE_AGENT $SID resumed as pid $back" >/dev/null 2>&1 || :
  ROLLED=1
  # Was it the target's LOGIN (issue #1669)? Ask the one judge again now: a target
  # that died on a login prompt, or whose credential lapsed after the first ask,
  # is refused here — and is switched again once someone signs in.
  target_auth || record_retry rolled_back
  TM set-option -w -t "$WIN" @claude_state "done" 2>/dev/null || :
  TM set-option -w -t "$WIN" @transfer_note "$note" 2>/dev/null || :
  TM set-option -w -t "$WIN" @transfer_rolled_back "$(date +%s)" 2>/dev/null || :
  fleet_hub_nudge
  [ -x "$BIN/fleet-alerts.sh" ] && bash "$BIN/fleet-alerts.sh" event -L "$SOCK" transfer-rolled-back \
    "${HANDLE:-$WIN}: $note$RETRY_NOTE" >/dev/null 2>&1 || :
  printf 'fleet-transfer: rolled-back: %s\n' "$note" >&2
  exit 1
}

# The helper quotes metadata as argv; conversation text is only ever data.
python3 "$HELPER" launcher "$BUNDLE" "$LAUNCH" || rollback 'cannot write the target launcher'
for key in @cc_account @subscription_identity @codex_identity @cc_model @ctx_pct @ctx_limit @ctx_band @model @effort @handoff_armed @handoff_cleared_at; do
  TM set-option -wu -t "$WIN" "$key" 2>/dev/null || :
done
TM set-option -w -t "$WIN" @cc_agent "$TO" || die 'cannot stamp target agent'
TM set-option -w -t "$WIN" @handoff_manifest "$BUNDLE/manifest.json" || die 'cannot stamp provenance'
TM set-option -w -t "$WIN" @source_agent "$SOURCE_AGENT" || die 'cannot stamp source agent'
TM set-option -w -t "$WIN" @source_session_id "$SID" || die 'cannot stamp source session'
TM set-option -w -t "$WIN" @source_transcript "$TRANSCRIPT" || die 'cannot stamp source transcript'
TM set-option -w -t "$WIN" @claude_state working || die 'cannot stamp target state'
fleet_hub_nudge   # issue #1481
TM set-option -w -t "$WIN" @migrated_at "$(date +%s)" 2>/dev/null || :
if [ -n "$WALL" ]; then TM set-option -w -t "$WIN" @migrated_banner "$WALL" 2>/dev/null || :
else TM set-option -wu -t "$WIN" @migrated_banner 2>/dev/null || :; fi
# respawn-pane keeps the pane's history: drop the source's scrollback (and the
# old wall in it) so the target starts on a clean pane.
TM clear-history -t "$PANE" 2>/dev/null || :
printf -v CMD 'exec bash %q' "$BUNDLE/launch.sh"
python3 "$HELPER" state "$BUNDLE" starting || die 'cannot record target launch'
# -k only replaces the verified leftover shell; Claude is already confirmed gone.
TM respawn-pane -k -t "$PANE" -c "$WT" "$CMD" || rollback "could not launch $TO in the retained pane"
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
[ -n "$CPID" ] || rollback "$TO did not bind within ${BOOT_WAIT}s"
TM clear-history -t "$PANE" 2>/dev/null || :   # a resume's replay, out of history (#870)
python3 "$HELPER" state "$BUNDLE" started "$TO identity $CPID; task completion is not implied." || die 'cannot record target startup'
SUCCESS=1
# A switch that landed some other way ends a retry still waiting on this window.
_fid=$(TM show-options -wqv -t "$WIN" @fleet_id 2>/dev/null)
[ -z "$_fid" ] || python3 "$HELPER" retry-supersede "$SESS" "$_fid" 2>/dev/null || :
TM set-option -wu -t "$WIN" @transfer_note 2>/dev/null || :
TM set-option -wu -t "$WIN" @transfer_rolled_back 2>/dev/null || :
printf '%s started in %s/%s (identity %s). Source provenance: %s\n' "$TO" "$SESS" "${HANDLE:-$WIN}" "$CPID" "$BUNDLE/manifest.json"
