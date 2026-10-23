#!/bin/bash
# fleet-report-parent.sh — compat-1v: 下一批删 — Parent delivery is retired.
# Existing own-session calls save only that session's result and PR evidence.
# --state merged|blocked|failed|stopped|waiting [--outcome succeeded|failed]
# [--summary text] [--pr N] [-L socket] [--dry-run]
# Old --win hook/reaper calls do nothing. No parent, ancestor, queue or reminder.
# A saved result is history, not proof that the native process has exited.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
[ -f "$BIN/../fleet.conf" ] && . "$BIN/../fleet.conf"
# shellcheck source=/dev/null
. "$BIN/fleet-lib.sh"

OUTCOME='' STATE='' PR='' SUMMARY='' WIN='' BRANCH='' KEY='' SOCK='' DRY=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --outcome)  shift; OUTCOME="${1:-}" ;;
    --state)    shift; STATE="${1:-}" ;;
    --pr)       shift; PR="${1:-}" ;;
    --verdict) shift ;; # retired delivery metadata
    --summary)  shift; SUMMARY="${1:-}" ;;
    --rows) shift ;; # retired delivery metadata
    --sample) shift ;; # retired delivery metadata
    --win)      shift; WIN="${1:-}" ;;
    --origin) shift ;; # retired delivery metadata
    --issue) shift ;; # retired delivery metadata
    --title) shift ;; # retired delivery metadata
    --branch)   shift; BRANCH="${1:-}" ;;
    --key)      shift; KEY="${1:-}" ;;
    -L)         shift; SOCK="${1:-}" ;;
    -L*)        SOCK="${1#-L}" ;;
    --only-once) : ;; # old hook dedup option; hooks are inert
    --dry-run)  DRY=1 ;;
    -h|--help)  sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)          printf 'fleet-report-parent: unknown argument %s\n' "$1" >&2; exit 2 ;;
  esac
  shift
done

STATES='merged|blocked|failed|reaped|stopped|waiting|idle|degenerate'
case "$STATE" in
  merged|blocked|failed|reaped|stopped|waiting|idle|degenerate) ;;
  '') printf 'fleet-report-parent: --state is required (%s)\n' "$STATES" >&2; exit 2 ;;
  *)  printf 'fleet-report-parent: unknown --state %s (%s)\n' "$STATE" "$STATES" >&2; exit 2 ;;
esac


# Old installed hooks still name this path for one version.
if [ -n "$WIN" ]; then
  printf 'RETIRED: Parent reports are disabled; this hook saved no result and delivered nothing.\n'
  exit 0
fi
TM() { if [ -n "$SOCK" ]; then tmux -L "$SOCK" "$@"; else tmux "$@"; fi; }
target="${TMUX_PANE:-}"
[ -n "$target" ] || { printf 'RETIRED: Parent reports are disabled; no own session to save.\n'; exit 2; }
row=$(TM display-message -p -t "$target" '#{window_id}|#{@fleet_id}|#{@task}|#{@cc_agent}|#{@issue}|#{@worktree}' 2>/dev/null)
[ -n "$row" ] || { printf 'result: own session unavailable\n' >&2; exit 1; }
selfwin=${row%%|*}; row=${row#*|}
selffid=${row%%|*}; row=${row#*|}
wtask=${row%%|*}; row=${row#*|}
wagent=${row%%|*}; row=${row#*|}
wissue=${row%%|*}; wworktree=${row#*|}
fleet_is_fid "$selffid" || { printf 'result: own session has no stable ID\n' >&2; exit 1; }
case "$wagent" in codex|codex:*) wagent=codex ;; *) wagent=claude ;; esac
case "$wtask" in T[1-9]*) case "${wtask#T}" in *[!0-9]*) wtask='' ;; esac ;; *) wtask='' ;; esac
if [ -n "$OUTCOME" ]; then
  case "$OUTCOME" in succeeded|failed) ;; *) printf 'result: invalid outcome\n' >&2; exit 2 ;; esac
  [ -n "$wtask" ] && [ -n "$SUMMARY" ] || { printf 'result: outcome requires task and summary\n' >&2; exit 2; }
  [ "$STATE" = merged ] || STATE=$OUTCOME
fi
sess="$SOCK"; [ -n "$sess" ] || sess=$(fleet_current_session)
[ -n "$sess" ] && fleet_load_conf "$sess"
selfkey="$KEY"
if [ -z "$selfkey" ]; then
  case "$wissue" in ''|*[!0-9]*) selfkey=$(fleet_scratch_key "$wworktree") ;; *) selfkey="issue-$wissue" ;; esac
fi
[ -n "$BRANCH" ] || BRANCH="${selfkey##*:}"

# Keep persistence protection independent of any retired delivery destination.
report_token=''
if [ "$DRY" != 1 ]; then
  TM set-window-option -t "$selfwin" @reap_report_pending 1 2>/dev/null || exit 1
  report_token=$(python3 "$BIN/fleet_reap_policy.py" report-begin "$selffid" "$wtask") || {
    printf 'result: cannot preserve evidence; session retained\n' >&2; exit 1;
  }
fi
id_result() {
  local rc=$?
  if [ -n "$report_token" ] && [ "$rc" = 0 ]; then
    if python3 "$BIN/fleet_reap_policy.py" report-finish "$selffid" "$report_token" \
        "$STATE" "$SUMMARY" "$wagent" "${PR//[^0-9]/}" >/dev/null 2>&1; then
      TM set-window-option -t "$selfwin" -u @reap_report_pending 2>/dev/null
      fleet_reap_soon "$selffid" "$STATE"
      printf 'RECORDED: own session result saved. RETIRED: Parent reports are disabled; nothing was delivered.\n'
    else
      printf 'result: not safely recorded; session retained\n' >&2; rc=1
    fi
  fi
  trap - EXIT
  exit "$rc"
}
trap id_result EXIT

_mforge=github
if [ "$STATE" = merged ] && [ -z "${PR//[^0-9]/}" ] && [ -n "$sess" ] && [ -n "${selfwin:-}" ]; then
  _mr=$(fleet_window_repo "$sess" "$selfwin")
  [ -n "$_mr" ] && _mforge=$(fleet_repo_forge "$_mr" "$sess")
  # A repo the fleet lands itself (FLEET_LAND=fleet, issue #3602) has no PR either.
  [ -n "$_mr" ] && [ "$(fleet_repo_land "$_mr" "$sess")" = fleet ] && _mforge=none
fi
if [ "$STATE" = merged ] && [ -z "${PR//[^0-9]/}" ] && [ "$_mforge" != none ]; then
  STATE=idle
  printf 'result: merged requires verifiable PR evidence; saved as idle.\n' >&2
fi
if [ "$STATE" = merged ] && { [ -n "${PR//[^0-9]/}" ] || [ "$_mforge" = none ]; }; then
  _prepo=''
  [ -n "$sess" ] && [ -n "${selfwin:-}" ] && _prepo=$(fleet_window_repo "$sess" "$selfwin")
  [ -n "$_prepo" ] || _prepo="${FLEET_REPO:-}"
  case "$_prepo" in
    ?*/?*)
      _pms=$(FLEET_SESSION="${sess:-${FLEET_SESSION:-}}" fleet_pr_merge_state "$_prepo" "$PR" "$BRANCH")
      case "$_pms" in
        merged) ;;
        armed|open)
          STATE=waiting
          ;;
        closed)
          STATE=failed
          SUMMARY="PR #${PR//[^0-9]/} was closed WITHOUT merging${SUMMARY:+ — $SUMMARY}" ;;
        *)
          STATE=idle ;;
      esac
      if [ "$_pms" != merged ] && [ "$_mforge" = none ]; then
        printf 'fleet-report-parent: NOT reporting MERGED — %s branch %s is %s (its work is not on the base, per git); filed as %s. Re-run once it has really landed.\n' \
          "$_prepo" "$BRANCH" "$_pms" "$(printf '%s' "$STATE" | tr '[:lower:]' '[:upper:]')" >&2
      elif [ "$_pms" != merged ]; then printf 'fleet-report-parent: NOT reporting MERGED — %s PR #%s is %s on GitHub (.merged != true); filed as %s. Re-run once it has really merged.\n' \
        "$_prepo" "${PR//[^0-9]/}" "$_pms" "$(printf '%s' "$STATE" | tr '[:lower:]' '[:upper:]')" >&2; fi ;;
    *) STATE=idle; printf 'result: cannot resolve PR repo; saved as idle.\n' >&2 ;;
  esac
fi


if [ "$DRY" = 1 ]; then
  printf 'RETIRED: Parent reports are disabled; would save own result %s.\n' "$STATE"
  exit 0
fi
# Preserve the old caller's own human-step hold until it reports again.
if [ "$STATE" = waiting ] && printf '%s' "$SUMMARY" | grep -qiE 'https?://|\.(png|jpe?g|gif|svg|pdf|html?)([^a-z]|$)|扫|二维码|确认码|验证码|点击|点一下|\bqr\b|scan|click'; then
  TM set-window-option -t "$selfwin" @human_wait "$(date +%s)" 2>/dev/null
else
  TM set-window-option -t "$selfwin" @human_wait off 2>/dev/null
fi
# PR annotation belongs to this task; it conveys no report or control authority.
if [ -n "$wtask" ] && [ -n "${PR//[^0-9]/}" ]; then
  _prrepo=$(fleet_window_repo "$sess" "$selfwin" 2>/dev/null)
  [ -z "$_prrepo" ] || bash "$BIN/fleet-task-record.sh" set "$wtask" --pr "$_prrepo#${PR//[^0-9]/}" >/dev/null 2>&1 || :
fi
exit 0
