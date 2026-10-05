#!/bin/bash
# fleet-relogin.sh — sign a dead account in again from the alert, then finish the
# switches it stopped (issue #1669, EPIC #1665 C5).
#
# Before this, recovering from a dead login took four things from the operator:
# notice the session did not come back, ask why, sign in, start the window again
# by hand. Now ↵ on `▲ accounts · reauth · <profile>` runs `login`; once the login
# is valid every switch that account's login stopped — refused up front (#1667) or
# rolled back (#1668), recorded under handoffs/retry/ by fleet-transfer.sh — is
# run again ONCE (`fleet-transfer.sh --retry <dir>`). The sign-in itself stays the
# operator's (the provider's own confirmation page); everything after is not.
#
# Usage:
#   fleet-relogin.sh login <agent>/<profile>   interactive (the alerts popup):
#       codex   `ccquota codex login <profile> --device-auth` — the link + code to
#               open on any device (phone / iPad included)
#       claude  `claude setup-token`, then the token pasted (hidden) into the pool
#               file, `fleet-account.sh clear-reauth <label>`
#     then the login is checked through the ONE judge (fleet-account.sh
#     target-auth), and `resume <agent>/<profile>` runs.
#   fleet-relogin.sh resume [<agent>/<profile>]
#       retry every pending switch (that login's, or all) whose target can log in
#       now; one line per record. A target still refused stays pending. The status
#       bar runs this detached when a pending record exists (fleet-alerts.sh), so a
#       login fixed anywhere else — another terminal, the hub — is picked up too.
#   fleet-relogin.sh pending   the pending records, one dir per line (exit 1: none)
#
# Seams: FLEET_QUOTA_BIN (ccquota), FLEET_RELOGIN_CLAUDE_BIN (claude),
# FLEET_ACCOUNTS_DIR. A credential is never printed, logged or passed on a
# command line: the pasted token goes from `read -s` to a 0600 file.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
: "${FLEET_CONF_DIR:=$HOME/.config/claude-fleet}"
export FLEET_CONF_DIR
HELPER="$BIN/.fleet-transfer.py"

say() { printf '%s\n' "$*"; }
die() { printf 'fleet-relogin: %s\n' "$*" >&2; exit 1; }

# _key <agent>/<profile> → AGENT PROF, or die.
_key() {
  AGENT=${1%%/*} PROF=${1#*/}
  case "$AGENT" in claude|codex) ;; *) die "expected <claude|codex>/<profile>, got '${1:-}'" ;; esac
  case "$PROF" in ''|*/*|.*|*[!A-Za-z0-9._@+-]*) die "not a profile name: '$PROF'" ;; esac
}

# _auth_ok — the ONE judge (EPIC #1665 convention 2) on AGENT/PROF; also restamps
# account.reauth through profiles(), so the ▲ row heals at the bar's next tick.
_auth_ok() {
  local out
  if [ "$AGENT" = codex ]; then out=$(bash "$BIN/fleet-account.sh" target-auth --agent codex --profile "$PROF" 2>/dev/null)
  else out=$(bash "$BIN/fleet-account.sh" target-auth --agent claude --label "$PROF" 2>/dev/null); fi
  case "$out" in *'"verdict": "ok"'*) return 0 ;; esac
  AUTH_WHY=$(printf '%s\n' "$out" | sed -n 's/.*"reason": *"\([^"]*\)".*/\1/p' | sed -n 1p)
  return 1
}

_pause() { [ -t 0 ] || return 0; printf '\n  press any key to close\n'; IFS= read -rsn1 _ 2>/dev/null || :; }

login_codex() {
  local q="${FLEET_QUOTA_BIN:-ccquota}"
  command -v "$q" >/dev/null 2>&1 || die "ccquota is not installed here; run on this machine: codex login --device-auth"
  say "Codex 账号 $PROF 重新登录 · open the link below on any device and enter the code"
  say ''
  "$q" codex login "$PROF" --device-auth || { say ''; say "登录没有完成 · the login did not complete"; return 1; }
}

login_claude() {
  local dir="${FLEET_ACCOUNTS_DIR:-$FLEET_CONF_DIR/accounts}" f tok first=''
  f="$dir/$PROF"
  [ -f "$f" ] || die "no Claude pool account '$PROF' in $dir"
  IFS= read -r first < "$f" 2>/dev/null || :
  case "$first" in hub:*)
    say "Claude 账号 $PROF 由入口托管 · hub-managed: sign it in again on the hub (fleet-creds-import.sh), not here"
    return 1 ;;
  esac
  say "Claude 账号 $PROF 重新登录 · sign in in the browser, then paste the token it prints"
  say ''
  "${FLEET_RELOGIN_CLAUDE_BIN:-claude}" setup-token || { say ''; say "登录没有完成 · the login did not complete"; return 1; }
  printf '\npaste the token (hidden): '
  IFS= read -rs tok || tok=''
  printf '\n'
  case "$tok" in sk-ant-oat01-*) ;; *) say "不是 setup-token · that is not a setup token; nothing changed"; return 1 ;; esac
  case "$tok" in *[!A-Za-z0-9_-]*) say "token 含非法字符 · the token has stray characters; nothing changed"; return 1 ;; esac
  ( umask 077; printf '%s\n' "$tok" > "$f.relogin.$$" ) && mv -f "$f.relogin.$$" "$f" || { rm -f "$f.relogin.$$"; die "could not write $f"; }
  tok=''
  bash "$BIN/fleet-account.sh" clear-reauth "$PROF" >/dev/null 2>&1 || :
}

cmd_login() {
  [ $# -ge 1 ] || die 'usage: fleet-relogin.sh login <agent>/<profile>'
  _key "$1"
  if [ "$AGENT" = codex ]; then login_codex; else login_claude; fi || { _pause; return 1; }
  say ''
  AUTH_WHY=''
  if ! _auth_ok; then
    say "登录后仍不可用 · still cannot log in: ${AUTH_WHY:-unknown}"
    _pause; return 1
  fi
  say "✓ $AGENT/$PROF 已登录 · signed in"
  cmd_resume "$AGENT/$PROF"
  _pause
  return 0
}

cmd_pending() {
  local out
  out=$(python3 "$HELPER" retry-list "$@" 2>/dev/null)
  [ -n "$out" ] || return 1
  printf '%s\n' "$out"
}

# cmd_resume [key] — one resume at a time per login (a mkdir lock, its owner's pid
# inside; a dead owner's lock is taken over), each record through --retry.
cmd_resume() {
  local lock dir rc n=0 owner
  [ $# -eq 0 ] || _key "$1"
  lock="$FLEET_CONF_DIR/handoffs/retry/.resume.lock"
  mkdir -p "${lock%/*}" 2>/dev/null; chmod 700 "${lock%/*}" 2>/dev/null
  if ! mkdir "$lock" 2>/dev/null; then
    owner=$(cat "$lock/pid" 2>/dev/null)
    if [ -n "$owner" ] && kill -0 "$owner" 2>/dev/null; then say "a resume is already running (pid $owner)"; return 0; fi
    rm -rf "$lock"; mkdir "$lock" 2>/dev/null || return 0
  fi
  printf '%s\n' "$$" > "$lock/pid"
  trap 'rm -rf "$lock"' EXIT
  while IFS= read -r dir; do
    [ -n "$dir" ] || continue
    n=$((n + 1))
    bash "$BIN/fleet-transfer.sh" --retry "$dir" >/dev/null 2>"$dir/retry.err"; rc=$?
    case "$rc" in
      0) say "↻ 已自动接着切换 · switched: $(_retry_label "$dir")" ;;
      3) say "… 仍在等待 · still waiting: $(_retry_label "$dir") · $(tail -n 1 "$dir/retry.err")" ;;
      *) say "✖ 重试失败，不再重试 · retry failed: $(_retry_label "$dir") · $(tail -n 1 "$dir/retry.err")" ;;
    esac
  done < <(python3 "$HELPER" retry-list ${1:+--wait "$1"} 2>/dev/null)
  [ "$n" -gt 0 ] || say "没有等待重试的切换 · no switch was waiting on ${1:-a login}"
  rm -rf "$lock"; trap - EXIT
  return 0
}

_retry_label() {
  python3 - "$1/request.json" <<'PY' 2>/dev/null
import json, sys
r = json.load(open(sys.argv[1]))
print('%s → %s (%s)' % (r.get('handle') or r.get('window') or '?', r.get('to') or '?', r.get('state') or '?'))
PY
}

cmd="${1:-}"; [ $# -gt 0 ] && shift
case "$cmd" in
  login) cmd_login "$@" ;;
  resume) cmd_resume "$@" ;;
  pending) cmd_pending "$@" ;;
  -h|--help|'') sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; [ -n "$cmd" ] ;;
  *) die "unknown command '$cmd' (login|resume|pending)" ;;
esac
