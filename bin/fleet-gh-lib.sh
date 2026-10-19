# shellcheck shell=bash
# fleet-gh-lib.sh — GitHub rate-limit detection + the REST fallback (issue #1042,
# EPIC #1262 C1; folds #946 #954).
#
# The account's GraphQL budget (5,000/hr, shared by every session on every login
# that uses the one token) runs out while REST keeps answering. Every `gh pr …` /
# `gh issue …` subcommand is GraphQL, so when it does, a worker could not merge a
# green PR (it parked ~50 min until the reset), fleet-pr-verdict.sh said "cannot
# read PR", dash-reap read a MERGED PR as unmerged, and the epic tick log could not
# be written. This file is the ONE place that:
#   * recognizes a limit from a call's OWN result — stderr / JSON text
#     (`graphql_rate_limit`, `API rate limit`, `secondary rate limit`). Never
#     `gh api rate_limit`: #946 #989 #1211 caught it reporting headroom while calls
#     were refused (EPIC #1262 共同约定 2);
#   * remembers it in a shared marker so the next caller skips the doomed call;
#   * does the same job over REST (`gh api repos/…`).
#
# SOURCED, not executed — like fleet-lib.sh it must not `set -u` / `pipefail`; it
# is safe under a `set -u` caller (every optional expansion is defaulted). It needs
# nothing else sourced first. GitHub helpers added by later EPIC members go HERE
# (共同约定 1), each in its own section.
#
# Marker (共同约定 3): $FLEET_STATE_DIR/gh-limit.<bucket>, bucket ∈ graphql | core |
# secondary; FLEET_STATE_DIR defaults to $FLEET_CONF_DIR/global. Content, one
# key=value per line:
#   reset=<epoch the limit is believed to lift>
#   source=<which caller saw it>
#   at=<epoch it was seen>
# Written tmp+rename (atomic); a marker whose reset has passed is simply ignored.
#
# Fault injection (共同约定 4): FLEET_GH_FAKE_LIMIT=<bucket>[,<bucket>…] (or `all`)
# makes that bucket read as limited WITHOUT calling gh and without writing the
# shared marker — so a test never manufactures a limit on the real account.
#
# Log: every limit seen, call skipped and fallback completed appends one line to
# $FLEET_GH_LOG (default $FLEET_CONF_DIR/logs/gh-limit.log) — the limited→fallback-ok
# interval is the EPIC's «longest a worker waits under a limit» metric.
#
# API
#   fleet_gh_limit_bucket <text>         print graphql|core|secondary if <text> is a
#                                        rate-limit refusal; rc 1 if it is not
#   fleet_gh_limited <bucket>            rc 0 (+ print reset epoch or `fake`) while
#                                        <bucket> or `secondary` is limited
#   fleet_gh_mark_limited <bucket> [reset] [source]
#   fleet_gh <gh args…>                  THE road for a plain gh call (issue #3721):
#                                        gh itself, byte for byte — except that a
#                                        call aimed at a FLEET_FORGE=none repo is
#                                        refused (rc $FLEET_GH_NOFORGE_RC, one stderr
#                                        line) and gh never runs
#   fleet_gh_run <bucket> <source> <gh args…>
#                                        run gh unless <bucket> is known-limited;
#                                        rc $FLEET_GH_LIMITED_RC (75) = rate-limited
#                                        (marked, logged) → take the fallback; any
#                                        other non-zero rc replays gh's stderr
#   fleet_gh_rest_pr_view <repo> <pr>    the seven lines fleet-pr-verdict.sh reads
#   fleet_gh_rest_merge <repo> <pr> <method> [--delete-branch]
#   fleet_gh_rest_comment <repo> <issue> <body-file>   → prints the comment URL
#   fleet_gh_rest_issue_close <repo> <issue>
#   fleet_gh_merged_heads <repo> <branch>  merged-PR head refs (GraphQL → REST)
#   fleet_gh_write <gh args…>            run ONE write through the per-token queue
#                                        (issue #1264, below); gh's rc + output
#   fleet_gh_wrun <bucket> <source> <gh args…>
#                                        fleet_gh_run for a WRITE: same contract,
#                                        but the call goes through fleet_gh_write
#   fleet_gh_share_get / fleet_gh_share_put
#                                        background reads shared per repo across
#                                        logins (issue #3529, below)
#   fleet_wh_live / fleet_wh_mark / fleet_wh_sig
#                                        webhook event stamps (issue #1272, below)

FLEET_GH_LIMITED_RC=75

fleet_gh_state_dir() {
  local d="${FLEET_STATE_DIR:-${FLEET_CONF_DIR:-$HOME/.config/claude-fleet}/global}"
  [ -d "$d" ] || mkdir -p "$d" 2>/dev/null
  printf '%s' "$d"
}

fleet_gh_log() {  # fleet_gh_log <event> [k=v …] — best effort, never fails a caller
  local f="${FLEET_GH_LOG:-${FLEET_CONF_DIR:-$HOME/.config/claude-fleet}/logs/gh-limit.log}"
  # The login's conf dir, never the install (issue #4668); one that cannot take
  # it (read-only) is skipped silently. The 2>/dev/null must wrap the group —
  # a bare `>> "$f" 2>/dev/null` reports the failed open before stderr is moved.
  { mkdir -p "$(dirname "$f")" && [ -w "$(dirname "$f")" ] &&
    printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "$f"; } 2>/dev/null
  return 0
}

fleet_gh_fake_limited() {
  case ",${FLEET_GH_FAKE_LIMIT:-}," in
    ,,) return 1 ;;
    *",${1:-},"*|*,all,*) return 0 ;;
  esac
  return 1
}

# Classify a gh error text. Secondary first (its message also says "rate limit"),
# then GraphQL (gh prints `GraphQL: API rate limit …`; the raw JSON carries
# `graphql_rate_limit` / "type":"RATE_LIMIT"), else any other rate limit is core.
fleet_gh_limit_bucket() {
  local t="${1:-}"
  case "$t" in
    *[Ss]econdary\ rate\ limit*)                        echo secondary ;;
    *graphql_rate_limit*|*GraphQL:*[Rr]ate\ limit*|*'"RATE_LIMIT"'*) echo graphql ;;
    *[Rr]ate\ limit\ exceeded*|*[Rr]ate\ limit\ already\ exceeded*) echo core ;;
    *) return 1 ;;
  esac
}

fleet_gh_limited() {  # fleet_gh_limited <bucket>
  _fleet_gh_limited_any "${1:-graphql}" secondary
}

_fleet_gh_limited_any() {  # _fleet_gh_limited_any <bucket>… — first one limited wins
  local k f reset now
  now=$(date +%s)
  for k in "$@"; do
    if fleet_gh_fake_limited "$k"; then echo fake; return 0; fi
    f="$(fleet_gh_state_dir)/gh-limit.$k"
    [ -f "$f" ] || continue
    reset=$(sed -n 's/^reset=//p' "$f" 2>/dev/null | head -1)
    case "$reset" in ''|*[!0-9]*) continue ;; esac
    [ "$reset" -gt "$now" ] && { echo "$reset"; return 0; }
  done
  return 1
}

# Without a reset from the response, hold the marker FLEET_GH_LIMIT_HOLD_SECS
# (default 600s; 60s for secondary). Holding only skips the doomed GraphQL call —
# the REST fallback still runs — so a short hold costs one refused call per hold.
fleet_gh_mark_limited() {  # fleet_gh_mark_limited <bucket> [reset-epoch] [source]
  local b="${1:-graphql}" reset="${2:-}" src="${3:-${0##*/}}" now d tmp hold
  case "$b" in graphql|core|secondary) ;; *) return 1 ;; esac
  now=$(date +%s)
  hold="${FLEET_GH_LIMIT_HOLD_SECS:-600}"; [ "$b" = secondary ] && hold=60
  case "$hold" in ''|*[!0-9]*) hold=600 ;; esac
  case "$reset" in ''|*[!0-9]*) reset=$((now + hold)) ;; esac
  d=$(fleet_gh_state_dir)
  tmp="$d/.gh-limit.$b.$$"
  printf 'reset=%s\nsource=%s\nat=%s\n' "$reset" "${src//[$'\n']/ }" "$now" > "$tmp" 2>/dev/null \
    && mv -f "$tmp" "$d/gh-limit.$b" 2>/dev/null
  rm -f "$tmp" 2>/dev/null
  return 0
}

# A WRITE (fleet_gh_wrun) does not skip on a secondary marker: the write queue
# WAITS it out instead (issue #1264) — a skipped comment is a lost comment.
fleet_gh_run() {  # fleet_gh_run <bucket> <source> <gh args…>
  local b="${1:-graphql}" src="${2:-gh}" err rc errtxt hit runner=_fleet_gh_call limited
  shift 2
  if [ "${_FLEET_GH_WRITE:-0}" = 1 ]; then
    runner=fleet_gh_write; _fleet_gh_limited_any "$b" >/dev/null && limited=1
  else
    fleet_gh_limited "$b" >/dev/null && limited=1
  fi
  if [ -n "${limited:-}" ]; then
    fleet_gh_log "skip bucket=$b source=$src"
    return "$FLEET_GH_LIMITED_RC"
  fi
  err=$(mktemp "${TMPDIR:-/tmp}/fleet-gh-err.XXXXXX") || { "$runner" "$@"; return $?; }
  "$runner" "$@" 2>"$err"; rc=$?
  if [ "$rc" -eq 0 ]; then rm -f "$err"; return 0; fi
  errtxt=$(cat "$err" 2>/dev/null)
  if hit=$(fleet_gh_limit_bucket "$errtxt"); then
    rm -f "$err"
    fleet_gh_mark_limited "$hit" '' "$src"
    fleet_gh_log "limited bucket=$hit source=$src"
    return "$FLEET_GH_LIMITED_RC"
  fi
  cat "$err" >&2; rm -f "$err"
  return "$rc"
}

# --- reachability: every GitHub call is timed; "GitHub 不通" is ONE shared state ---
# (issue #4841, EPIC #4839 C2, 共同约定 2/3). A gh call used to be bare `gh`: with
# GitHub connecting but never answering (a blackhole, a stalled proxy) every caller
# hung on its own, the daemons till their watchdog (~9 min), the tools for ever.
#   * _fleet_gh_call runs gh under _fleet_gh_timed — FLEET_GH_TIMEOUT seconds (15;
#     FLEET_GH_TIMEOUT_KEY=5 for a key's popup), the job its own PROCESS GROUP so the
#     kill takes gh's children too. A timeout, or gh's own connection error (DNS,
#     refused, i/o timeout, TLS handshake), is a CONNECTION failure; an HTTP answer
#     — 404, 422, a rate limit — is GitHub answering and resets the count.
#   * a TIMEOUT (FLEET_GH_TIMEOUT seconds of silence) opens the marker at once —
#     the next caller, a REST fallback right behind it, must not wait again; a FAST
#     connection error (DNS, refused) opens it on the FLEET_GH_DOWN_AFTER-th (2)
#     in a row (within FLEET_GH_DOWN_WINDOW, 300s), a blip being cheap. The marker
#     is $FLEET_STATE_DIR/gh-down — one
#     line `<epoch> <reason>`, beside gh-limit.<bucket>, shared by the login (and by
#     the machine where FLEET_STATE_DIR is shared). While it is open every call
#     returns $FLEET_GH_LIMITED_RC (75, "GitHub 暂时不可用" — the code callers
#     already treat as not-a-failure) at once, without running gh.
#   * at most once per FLEET_GH_DOWN_PROBE_SECS (60) one caller — whoever asks
#     first — probes (`gh api zen`, FLEET_GH_TIMEOUT_KEY seconds); success removes
#     the marker and the call goes ahead. A daemon asks fleet_gh_ready before its
#     tick, so the probe runs even when no session touches GitHub.
#   * one line in $FLEET_GH_LOG when it opens (`gh-down open`) and closes
#     (`gh-down close`) — never an alert, never a breakage.
# Not timed: a call whose stdin or stdout is a terminal (a person's prompt, a pager
# — a background process group would stop on SIGTTIN), and a shell that is not bash.
# Local subcommands (`auth token`, `config`, `--version` …) never see the marker.
# Constants of the layer, not settings: the env overrides exist for the selftests.
# FLEET_GH_BIN names the gh the layer runs (default `gh` off PATH) — a caller's own
# test seam (FLEET_CN_PROBE_GH, FLEET_IDLE_DAILY_GH …) hands its fake through it, so
# the fake still rides the layer (issue #4842).
fleet_gh_timeout() { case "${FLEET_GH_TIMEOUT:-}" in ''|*[!0-9]*) printf 15 ;; *) printf '%s' "$FLEET_GH_TIMEOUT" ;; esac; }
fleet_gh_timeout_key() { case "${FLEET_GH_TIMEOUT_KEY:-}" in ''|*[!0-9]*) printf 5 ;; *) printf '%s' "$FLEET_GH_TIMEOUT_KEY" ;; esac; }
_fleet_gh_num() { case "${1:-}" in ''|*[!0-9]*) printf '%s' "$2" ;; *) printf '%s' "$1" ;; esac; }

# _fleet_gh_timed <secs> <cmd…> — the command's own rc, or 124 when the clock ran
# out (the whole process group killed: TERM, then KILL). stdin/stdout/stderr are
# the caller's, untouched. A watcher subshell holds the clock, so the wait is a
# plain `wait` — no poll loop.
_fleet_gh_timed() {
  local secs="${1:-0}"; shift
  case "$secs" in ''|*[!0-9]*|0) "$@"; return $? ;; esac
  if [ -z "${BASH_VERSION:-}" ] || [ -t 0 ] || [ -t 1 ]; then "$@"; return $?; fi
  local mflag=0 job w rc flag
  flag="${TMPDIR:-/tmp}/fleet-gh-tmo.$$.$RANDOM$RANDOM"
  case "$-" in *m*) mflag=1 ;; esac
  set -m
  # An async command gets /dev/null for stdin even under `set -m` in a script:
  # hand it the caller's own (saved on fd 7) — `gh api --input -`, a body on stdin.
  { "$@" 0<&7 7<&- & job=$!; } 7<&0
  # The watcher writes the flag BEFORE the signal, so a job it killed is told
  # apart from one that failed by itself.
  # The system's sleep, never a PATH shim a test put first (`command -p` still
  # takes bash's hashed path).
  local sl=/bin/sleep; [ -x "$sl" ] || sl=/usr/bin/sleep
  ( trap - TERM; "$sl" "$secs"; : > "$flag"
    kill -TERM -- "-$job" 2>/dev/null; "$sl" 2; kill -KILL -- "-$job" 2>/dev/null ) >/dev/null 2>&1 </dev/null &
  w=$!
  [ "$mflag" = 1 ] || set +m
  wait "$job" 2>/dev/null; rc=$?
  kill -TERM -- "-$w" 2>/dev/null; kill -TERM "$w" 2>/dev/null
  wait "$w" 2>/dev/null
  if [ -e "$flag" ]; then
    rm -f "$flag"
    kill -KILL -- "-$job" 2>/dev/null   # whatever gh left behind in its group
    [ "$rc" -eq 0 ] || return 124
  fi
  return "$rc"
}

# fleet_gh_conn_fail <text> — rc 0 when <text> is a CONNECTION failure (gh / git /
# curl wording): GitHub never answered. An HTTP error is an answer, never this —
# but a PROXY's refusal of the tunnel is not GitHub's (Go's `Post "<url>": Bad
# Gateway`, curl's `CONNECT tunnel failed`): GitHub was never reached (issue #4844).
fleet_gh_conn_fail() {
  case "${1:-}" in
    *'error connecting to'*|*'no such host'*|*'connection refused'*|*'Connection refused'*|\
    *'i/o timeout'*|*'TLS handshake timeout'*|*'context deadline exceeded'*|*'proxyconnect tcp'*|\
    *'network is unreachable'*|*'Network is unreachable'*|*'connection reset by peer'*|\
    *'Could not resolve host'*|*'Failed to connect to'*|*"Couldn't connect to server"*|\
    *'Connection timed out'*|*'Operation timed out'*|*'Operation too slow'*|\
    *'SSL connection timeout'*|\
    *'": Bad Gateway'*|*'": Service Unavailable'*|*'": Gateway Timeout'*|\
    *'CONNECT tunnel failed'*|*'from proxy after CONNECT'*) return 0 ;;
  esac
  return 1
}

# fleet_gh_down [bucket] — rc 0 while GitHub is believed unreachable, printing the
# epoch it went down (`fake` under FLEET_GH_FAKE_DOWN=1). Forkless: the status bar
# and the dash may read it every tick. The bucket is accepted for symmetry with
# fleet_gh_limited; reachability is one state for all of them.
fleet_gh_down() {
  local f since _r
  [ "${FLEET_GH_FAKE_DOWN:-0}" = 1 ] && { echo fake; return 0; }
  f="${FLEET_STATE_DIR:-${FLEET_CONF_DIR:-$HOME/.config/claude-fleet}/global}/gh-down"
  [ -f "$f" ] || return 1
  read -r since _r < "$f" 2>/dev/null || return 1
  case "$since" in ''|*[!0-9]*) return 1 ;; esac
  echo "$since"
}

# fleet_gh_down_reason — the marker's reason (one line), or nothing.
fleet_gh_down_reason() {
  local f _s r
  f="$(fleet_gh_state_dir)/gh-down"
  [ -f "$f" ] && read -r _s r < "$f" 2>/dev/null && printf '%s' "$r"
}

# fleet_gh_down_next — seconds until the next probe may run (0 = due now).
fleet_gh_down_next() {
  local d last now every
  d=$(fleet_gh_state_dir); now=$(date +%s)
  every=$(_fleet_gh_num "${FLEET_GH_DOWN_PROBE_SECS:-}" 60)
  last=$(cat "$d/gh-down.probe" 2>/dev/null); last=$(_fleet_gh_num "$last" 0)
  last=$(( last + every - now )); [ "$last" -lt 0 ] && last=0
  printf '%s' "$last"
}

# fleet_gh_down_line — the doctor's words: 「GitHub 不通 · 3 分钟 · 下次探测 40 秒后」.
fleet_gh_down_line() {
  local since now m nx
  since=$(fleet_gh_down) || return 1
  [ "$since" = fake ] && { printf 'GitHub 不通（注入：FLEET_GH_FAKE_DOWN）'; return 0; }
  now=$(date +%s); m=$(( (now - since) / 60 )); nx=$(fleet_gh_down_next)
  if [ "$m" -lt 1 ]; then m='不到 1 分钟'; else m="$m 分钟"; fi
  if [ "$nx" -gt 0 ]; then nx="下次探测 $nx 秒后"; else nx='下次调用即探测'; fi
  printf 'GitHub 不通 · %s · %s' "$m" "$nx"
}

_fleet_gh_down_open() {  # _fleet_gh_down_open <reason>
  local d tmp now
  d=$(fleet_gh_state_dir); now=$(date +%s); tmp="$d/.gh-down.$$"
  [ -f "$d/gh-down" ] && return 0
  printf '%s %s\n' "$now" "${1//[$'\n']/ }" > "$tmp" 2>/dev/null && mv -f "$tmp" "$d/gh-down" 2>/dev/null
  rm -f "$tmp" 2>/dev/null
  printf '%s\n' "$now" > "$d/gh-down.probe" 2>/dev/null
  fleet_gh_log "gh-down open reason=${1// /_} source=${0##*/}"
}

_fleet_gh_down_close() {  # _fleet_gh_down_close <how>
  local d since
  d=$(fleet_gh_state_dir)
  [ -f "$d/gh-fail" ] && rm -f "$d/gh-fail" 2>/dev/null
  [ -f "$d/gh-down" ] || return 0
  since=$(fleet_gh_down)
  rm -f "$d/gh-down" "$d/gh-down.probe" 2>/dev/null
  fleet_gh_log "gh-down close how=$1 secs=$(( $(date +%s) - $(_fleet_gh_num "$since" "$(date +%s)") )) source=${0##*/}"
}

# _fleet_gh_conn_failed <reason> [now] — count one connection failure; the
# FLEET_GH_DOWN_AFTER-th in a row (inside FLEET_GH_DOWN_WINDOW) opens the marker,
# `now` (a timeout) opens it at once.
_fleet_gh_conn_failed() {
  local d f n now win after
  d=$(fleet_gh_state_dir); f="$d/gh-fail"; now=$(date +%s)
  win=$(_fleet_gh_num "${FLEET_GH_DOWN_WINDOW:-}" 300)
  after=$(_fleet_gh_num "${FLEET_GH_DOWN_AFTER:-}" 2)
  # One appended line per failure — an O_APPEND write of a short line is atomic, so
  # callers failing at the same second (20 sessions behind one blackhole) are all
  # counted; a read-modify-write lost all but one of them.
  printf '%s\n' "$now" >> "$f" 2>/dev/null
  n=$(awk -v c=$(( now - win )) '$1 >= c { n++ } END { print n + 0 }' "$f" 2>/dev/null)
  n=$(_fleet_gh_num "$n" 1)
  fleet_gh_log "gh-conn-fail n=$n reason=${1// /_} source=${0##*/}"
  { [ "$n" -ge "$after" ] || [ "${2:-}" = now ]; } && _fleet_gh_down_open "$1"
  return 0
}

# fleet_gh_ready — rc 0: go ahead and call GitHub; rc 75: it is down, skip. While
# the marker is open and a probe is due, THIS caller probes (one at a time: a
# mkdir lock, stale after 30s) and a success closes the marker.
fleet_gh_ready() {
  local d now lk since rc
  since=$(fleet_gh_down) || return 0
  [ "$since" = fake ] && return "$FLEET_GH_LIMITED_RC"
  [ "$(fleet_gh_down_next)" -gt 0 ] && return "$FLEET_GH_LIMITED_RC"
  d=$(fleet_gh_state_dir); lk="$d/gh-down.probing"; now=$(date +%s)
  if ! mkdir "$lk" 2>/dev/null; then
    [ $(( now - $(_fleet_gh_mtime "$lk" 2>/dev/null || echo "$now") )) -gt 30 ] && rm -rf "$lk" 2>/dev/null
    return "$FLEET_GH_LIMITED_RC"
  fi
  printf '%s\n' "$now" > "$d/gh-down.probe" 2>/dev/null
  _fleet_gh_timed "$(fleet_gh_timeout_key)" "${FLEET_GH_BIN:-gh}" api zen >/dev/null 2>&1; rc=$?
  rmdir "$lk" 2>/dev/null
  if [ "$rc" -eq 0 ]; then _fleet_gh_down_close probe; return 0; fi
  fleet_gh_log "gh-down probe-fail rc=$rc source=${0##*/}"
  return "$FLEET_GH_LIMITED_RC"
}

_fleet_gh_local_cmd() {  # gh subcommands that never reach the network
  case "${1:-} ${2:-}" in
    'auth token'*|config\ *|alias\ *|completion\ *|help\ *|'--version '*|'version '*|'--help '*|'extension list'*) return 0 ;;
  esac
  return 1
}

# _fleet_gh_call <gh args…> — gh, timed and circuit-aware. Healthy: gh's stdout,
# stderr and exit code, byte for byte (stderr is held and replayed after the call,
# so it can be read). Down / timed out / no connection: rc 75 + one stderr line.
_fleet_gh_call() {
  local err rc txt
  _fleet_gh_local_cmd "$@" && { "${FLEET_GH_BIN:-gh}" "$@"; return $?; }
  if ! fleet_gh_ready; then
    printf 'fleet_gh: GitHub unreachable (since %s) — gh %s not run, rc %s\n' \
      "$(fleet_gh_hhmm "$(fleet_gh_down)")" "${1:-}" "$FLEET_GH_LIMITED_RC" >&2
    fleet_gh_log "down-skip cmd=${1:-}_${2:-} source=${0##*/}"
    return "$FLEET_GH_LIMITED_RC"
  fi
  err=$(mktemp "${TMPDIR:-/tmp}/fleet-gh-err.XXXXXX" 2>/dev/null) || { _fleet_gh_timed "$(fleet_gh_timeout)" "${FLEET_GH_BIN:-gh}" "$@"; return $?; }
  _fleet_gh_timed "$(fleet_gh_timeout)" "${FLEET_GH_BIN:-gh}" "$@" 2>"$err"; rc=$?
  if [ "$rc" -eq 0 ]; then
    [ -f "$(fleet_gh_state_dir)/gh-fail" ] && _fleet_gh_down_close call
    [ -s "$err" ] && cat "$err" >&2
    rm -f "$err"; return 0
  fi
  if [ "$rc" -eq 124 ]; then
    rm -f "$err"
    printf 'fleet_gh: GitHub did not answer in %ss — gh %s given up, rc %s\n' "$(fleet_gh_timeout)" "${1:-}" "$FLEET_GH_LIMITED_RC" >&2
    _fleet_gh_conn_failed "timeout ${1:-} ${2:-}" now
    return "$FLEET_GH_LIMITED_RC"
  fi
  txt=$(cat "$err" 2>/dev/null)
  cat "$err" >&2; rm -f "$err"
  if fleet_gh_conn_fail "$txt"; then
    _fleet_gh_conn_failed "connect ${1:-} ${2:-}"
    return "$FLEET_GH_LIMITED_RC"
  fi
  [ -f "$(fleet_gh_state_dir)/gh-fail" ] && _fleet_gh_down_close call   # GitHub answered
  return "$rc"
}

# fleet_gh_git <git args…> — git aimed at github.com, bounded: a transfer stalled
# below 1 B/s for FLEET_GH_TIMEOUT seconds is aborted (http.lowSpeed*; a long but
# moving push is never cut), ssh gets ConnectTimeout, FLEET_GH_GIT_TIMEOUT (600)
# bounds the whole. Down ⇒ rc 75 without running git; a connection failure counts.
fleet_gh_git() {
  local err rc txt t
  if ! fleet_gh_ready; then
    printf 'fleet_gh_git: GitHub unreachable — git %s not run, rc %s\n' "${1:-}" "$FLEET_GH_LIMITED_RC" >&2
    return "$FLEET_GH_LIMITED_RC"
  fi
  t=$(fleet_gh_timeout)
  err=$(mktemp "${TMPDIR:-/tmp}/fleet-gh-err.XXXXXX" 2>/dev/null) || err=/dev/null
  GIT_SSH_COMMAND="${GIT_SSH_COMMAND:-ssh} -o ConnectTimeout=$t" \
    _fleet_gh_timed "$(_fleet_gh_num "${FLEET_GH_GIT_TIMEOUT:-}" 600)" \
    git -c http.lowSpeedLimit=1 -c "http.lowSpeedTime=$t" "$@" 2>"$err"; rc=$?
  [ "$err" = /dev/null ] && return "$rc"
  txt=$(cat "$err" 2>/dev/null); cat "$err" >&2; rm -f "$err"
  if [ "$rc" -eq 124 ]; then
    _fleet_gh_conn_failed "git-timeout ${1:-}" now; return "$FLEET_GH_LIMITED_RC"
  fi
  if [ "$rc" -ne 0 ] && fleet_gh_conn_fail "$txt"; then
    _fleet_gh_conn_failed "git ${1:-}"
    return "$FLEET_GH_LIMITED_RC"
  fi
  [ "$rc" -eq 0 ] && [ -f "$(fleet_gh_state_dir)/gh-fail" ] && _fleet_gh_down_close git
  return "$rc"
}

# fleet_gh_curl <curl args…> — curl aimed at api / raw / codeload.github.com:
# connect within FLEET_GH_TIMEOUT_KEY, abort below 1 B/s for FLEET_GH_TIMEOUT.
# curl's own rc 6/7/28/35 (resolve · connect · timeout · TLS connect) is a
# connection failure ⇒ counted, rc 75. Down ⇒ rc 75 without running curl.
fleet_gh_curl() {
  local rc
  fleet_gh_ready || return "$FLEET_GH_LIMITED_RC"
  curl --connect-timeout "$(fleet_gh_timeout_key)" --speed-limit 1 --speed-time "$(fleet_gh_timeout)" "$@"; rc=$?
  case "$rc" in
    28) _fleet_gh_conn_failed "curl rc=28" now; return "$FLEET_GH_LIMITED_RC" ;;
    6|7|35) _fleet_gh_conn_failed "curl rc=$rc"; return "$FLEET_GH_LIMITED_RC" ;;
    0) [ -f "$(fleet_gh_state_dir)/gh-fail" ] && _fleet_gh_down_close curl ;;
  esac
  return "$rc"
}

# --- fleet_gh: every plain gh call (issue #3721, EPIC #3570 共同约定 2) -----------
# A program outside the door and this layer never spells `gh issue|pr|api|…`; it
# calls `fleet_gh …` (or, from POSIX sh / an exec, `fleet-gh.sh run …`). For a
# GitHub repo it is `gh "$@"` — same stdout, stderr and exit code. A call aimed at
# a repo whose conf says FLEET_FORGE=none (--repo / -R / --repo= / an api path
# `repos/<owner>/<name>/…`) stops here, so such a repo never reaches GitHub. The
# target's forge is fleet_repo_forge's (fleet-lib.sh) — not sourced ⇒ no check.
FLEET_GH_NOFORGE_RC=78
fleet_gh_target() {  # fleet_gh_target <gh args…> → owner/name the call is aimed at, or nothing
  local a prev='' api=0 n=0
  for a in "$@"; do
    n=$((n + 1))
    [ "$n" = 1 ] && [ "$a" = api ] && api=1
    case "$prev" in --repo|-R) printf '%s' "$a"; return 0 ;; esac
    case "$a" in
      --repo=*) printf '%s' "${a#--repo=}"; return 0 ;;
      repos/*/*) [ "$api" = 1 ] && { a=${a#repos/}; a=${a%%\?*}
                   printf '%s/%s' "${a%%/*}" "$(a=${a#*/}; printf '%s' "${a%%/*}")"; return 0; } ;;
    esac
    prev=$a
  done
  return 0
}
fleet_gh() {  # fleet_gh <gh args…>
  local t
  if type fleet_repo_forge >/dev/null 2>&1; then
    t=$(fleet_gh_target "$@")
    if [ -n "$t" ] && [ "$(fleet_repo_forge "$t")" = none ]; then
      printf 'fleet_gh: %s has no GitHub (FLEET_FORGE=none) — gh %s not run\n' "$t" "${1:-}" >&2
      return "$FLEET_GH_NOFORGE_RC"
    fi
  fi
  _fleet_gh_call "$@"
}

# --- REST equivalents ---------------------------------------------------------

# The same six lines fleet-pr-verdict.sh's GraphQL read emits — state, mergeable,
# mergeStateStatus, draft, checks, auto-merge — so one fold (land_verdict) judges
# both paths. REST's lowercase enums map 1:1 onto the GraphQL ones. The check
# fold mirrors the GraphQL statusCheckRollup one: check-runs + the combined
# commit status; none / fail / pending / pass. A MERGED/CLOSED PR skips the check
# reads (the verdict ignores them) — two calls saved under a budget squeeze.
fleet_gh_rest_pr_view() {  # fleet_gh_rest_pr_view <repo> <pr>
  local repo="$1" pr="$2" row st mg ms dr sha am runs stats ck ci=''
  # shellcheck disable=SC2016
  row=$(fleet_gh_run core pr-view api "repos/$repo/pulls/$pr" --jq '
          (if .merged then "MERGED" elif .state=="closed" then "CLOSED" else "OPEN" end),
          (if .mergeable==true then "MERGEABLE" elif .mergeable==false then "CONFLICTING" else "UNKNOWN" end),
          ((.mergeable_state // "") | ascii_upcase),
          (if .draft then "DRAFT" else "" end),
          (.head.sha // ""),
          (if .auto_merge then "AUTO" else "" end)') || return $?
  [ -n "$row" ] || return 1
  { read -r st; read -r mg; read -r ms; read -r dr; read -r sha; read -r am; } <<< "$row"
  ck=none
  if [ "$st" = OPEN ] && [ -n "$sha" ]; then
    # `macOS shard *` is not part of the merge gate (issue #2286) — dropped here
    # exactly as fleet-pr-verdict.sh's GraphQL fold drops it.
    runs=$(fleet_gh_run core pr-view api "repos/$repo/commits/$sha/check-runs?per_page=100" --jq '
             .check_runs[] | select((.name // "") | startswith("macOS shard") | not) |
             (if .name == "CI 结论" then "ci-" else "" end) +
             (if (.conclusion=="failure" or .conclusion=="timed_out" or .conclusion=="cancelled"
                 or .conclusion=="action_required") then "fail"
              elif .status!="completed" then "pending" else "pass" end)') || return $?
    stats=$(fleet_gh_run core pr-view api "repos/$repo/commits/$sha/status" --jq '
             .statuses[] |
             if (.state=="failure" or .state=="error") then "fail"
             elif .state=="pending" then "pending" else "pass" end') || return $?
    runs="$runs
$stats"
    # `CI 结论` decides when present (issue #4815) — another red still fails
    # (# compat-1v: 下一批删); the same fold as fleet-pr-verdict.sh's GraphQL read
    if printf '%s\n' "$runs" | grep -q '^ci-'; then
      ci=CI
      if   printf '%s\n' "$runs" | grep -qE '^(ci-)?fail$'; then ck=fail
      elif printf '%s\n' "$runs" | grep -qx ci-pending;     then ck=pending
      else ck=pass
      fi
    elif printf '%s\n' "$runs" | grep -qx fail;    then ck=fail
    elif printf '%s\n' "$runs" | grep -qx pending; then ck=pending
    elif printf '%s\n' "$runs" | grep -qx pass;    then ck=pass
    fi
  fi
  printf '%s\n' "$st" "$mg" "$ms" "$dr" "$ck" "$am" "$ci"
}

# Merge over REST, pinned to the head sha it reads (a push that lands between the
# read and the PUT makes GitHub refuse rather than merge unverified code), and
# delete the head branch ONLY after GitHub says merged — never on a failed merge
# (issue #544). The caller owns the green gate: this function merges, it does not
# judge (bin/fleet-pr-merge.sh reads the verdict first).
fleet_gh_rest_merge() {  # fleet_gh_rest_merge <repo> <pr> <method> [--delete-branch]
  local repo="$1" pr="$2" method="${3:-squash}" del="${4:-}" head sha ref same merged
  # shellcheck disable=SC2016
  head=$(fleet_gh_run core merge api "repos/$repo/pulls/$pr" \
           --jq '(.head.sha // ""), (.head.ref // ""), (if .head.repo.full_name == .base.repo.full_name then "same" else "" end)') || return $?
  { read -r sha; read -r ref; read -r same; } <<< "$head"
  [ -n "$sha" ] || return 1
  merged=$(fleet_gh_wrun core merge api -X PUT "repos/$repo/pulls/$pr/merge" \
             -f "merge_method=$method" -f "sha=$sha" --jq '.merged') || return $?
  [ "$merged" = true ] || return 1
  if [ "$del" = --delete-branch ] && [ -n "$ref" ] && [ "$same" = same ]; then
    fleet_gh_wrun core merge api -X DELETE "repos/$repo/git/refs/heads/$ref" >/dev/null \
      || printf 'fleet-gh: merged #%s, but deleting branch %s failed (harmless)\n' "$pr" "$ref" >&2
  fi
  return 0
}

fleet_gh_rest_comment() {  # fleet_gh_rest_comment <repo> <issue> <body-file>
  fleet_gh_wrun core comment api "repos/$1/issues/$2/comments" -F "body=@$3" --jq '.html_url'
}

fleet_gh_rest_issue_close() {  # fleet_gh_rest_issue_close <repo> <issue>
  fleet_gh_wrun core comment api -X PATCH "repos/$1/issues/$2" -f state=closed --jq '.html_url'
}

# Head refs of MERGED PRs for <branch> — the `gh pr list --state merged --head`
# answer dash-reap's merged-check reads, with the REST fallback. Same argv as the
# pre-#1042 call on the healthy path. REST's `head=` filter wants owner:branch;
# a fleet branch is pushed to the repo itself, so the owner is the repo's.
# `--at` (issue #1542) appends a TAB + the PR's mergedAt (ISO-8601 UTC) to each
# line, so the reaper can hand the liveness probe the merge time (#1329) without a
# second round-trip; without it the argv is byte for byte the pre-#1542 one.
# `--sha` (issue #1842) appends a TAB + the PR's head sha (after the mergedAt with
# `--at`), which fleet_reap_ok reads to keep a commit made after the merge.
fleet_gh_merged_heads() {  # fleet_gh_merged_heads <repo> <branch> [--at] [--sha]
  local repo="$1" branch="$2" out rc at=0 sha=0 o
  for o in "${3:-}" "${4:-}"; do case "$o" in --at) at=1 ;; --sha) sha=1 ;; esac; done
  local gq='.[].headRefName' gj=headRefName rq='.[] | select(.merged_at != null) | .head.ref'
  if [ "$at" = 1 ] || [ "$sha" = 1 ]; then
    gq='.[] | "\(.headRefName)'; gj=headRefName
    rq='.[] | select(.merged_at != null) | "\(.head.ref)'
    [ "$at" = 1 ] && { gq="$gq"'\t\(.mergedAt)'; gj=$gj,mergedAt; rq="$rq"'\t\(.merged_at)'; }
    [ "$sha" = 1 ] && { gq="$gq"'\t\(.headRefOid)'; gj=$gj,headRefOid; rq="$rq"'\t\(.head.sha)'; }
    gq="$gq\""; rq="$rq\""
  fi
  out=$(fleet_gh_run graphql reap -R "$repo" pr list --state merged --head "$branch" \
          --json "$gj" -q "$gq"); rc=$?
  if [ "$rc" -eq 0 ]; then [ -n "$out" ] && printf '%s\n' "$out"; return 0; fi
  [ "$rc" -eq "$FLEET_GH_LIMITED_RC" ] || return "$rc"
  out=$(fleet_gh_run core reap api "repos/$repo/pulls?state=closed&head=${repo%%/*}:$branch&per_page=100" \
          --jq "$rq") || return $?
  fleet_gh_log "fallback-ok op=merged-heads repo=$repo branch=$branch"
  [ -n "$out" ] && printf '%s\n' "$out"
  return 0
}

# --- write queue (issue #1264, EPIC #1262 C4) ---------------------------------
# At the end of a big batch a dozen workers + the hub write GitHub at once
# (comments, filings, PRs). GitHub's SECONDARY limit is about write *rate*, and it
# punishes a retry storm by extending the block — so every writer that hit it and
# retried at once lost its progress log / delivery comment. fleet_gh_write makes
# the writes of one token a queue:
#   * a per-token lock (one writer at a time) + a minimum gap between the START
#     of two writes (FLEET_GH_WRITE_GAP seconds, default 1, decimals ok);
#   * a secondary refusal is waited out BY THE LOCK HOLDER, lock held: it writes
#     the shared gh-limit.secondary marker, sleeps Retry-After (from the call's
#     own output — `gh api -i` prints headers; else 60→120→240, capped 300,
#     base FLEET_GH_WRITE_BACKOFF), and retries, at most 3 times. Everyone else is
#     queued on the lock behind it, so the whole token waits ONCE, together,
#     instead of each one retrying into a longer block. A writer that acquires the
#     lock while a marker someone else wrote still holds sleeps it out first.
#   * gh's exit code, stdout and stderr pass through unchanged (replayed after
#     the call, so a retried attempt's refusal is never printed).
# Lock: $FLEET_STATE_DIR/gh-write.<token-fp>.lock — a file holding the holder's
# pid, created atomically by hard link. No flock on macOS, so staleness is a pid
# check: a holder that was SIGKILLed leaves a file whose pid is dead, and the
# next waiter removes it. Point FLEET_STATE_DIR at one shared dir and logins that
# share a token share the queue. A waiter gives up after FLEET_GH_WRITE_LOCK_WAIT
# seconds (default 1200) and writes unqueued (logged) rather than lose the write.

_fleet_gh_now_ms() {
  if [ -n "${EPOCHREALTIME:-}" ]; then
    local s="${EPOCHREALTIME%[.,]*}" u="${EPOCHREALTIME#*[.,]}"
    printf '%s' "$(( s * 1000 + 10#${u:0:3} ))"
  else
    perl -MTime::HiRes=time -e 'printf "%d", time()*1000' 2>/dev/null || printf '%s000' "$(date +%s)"
  fi
}

_fleet_gh_sleep_ms() { [ "${1:-0}" -gt 0 ] && sleep "$(awk -v m="$1" 'BEGIN{printf "%.3f", m/1000}')"; return 0; }

_fleet_gh_pid_alive() {  # another login's pid: kill -0 says EPERM, ps still sees it
  case "${1:-}" in ''|*[!0-9]*) return 1 ;; esac
  kill -0 "$1" 2>/dev/null || ps -p "$1" >/dev/null 2>&1
}

# Which token the write queue is for, without spending a gh call (a selftest's gh
# shim counts every argv): an env token is hashed; else gh's own config names the
# github.com user its stored token belongs to. One account ≡ one queue.
_fleet_gh_token_fp() {
  local t="${GH_TOKEN:-${GITHUB_TOKEN:-}}" fp
  if [ -z "$t" ]; then
    t=$(awk '/^[^ \t]/ { h = ($1 == "github.com:") } h && $1 == "user:" { print "user:" $2; exit }' \
          "${GH_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/gh}/hosts.yml" 2>/dev/null)
  fi
  [ -n "$t" ] || { printf default; return 0; }
  fp=$(printf '%s' "$t" | { shasum 2>/dev/null || sha1sum; } | cut -c1-12)
  printf '%s' "${fp:-default}"
}

_fleet_gh_write_lock() {  # _fleet_gh_write_lock <lockfile> <pid> — rc 1 = gave up
  local l="$1" me="$2" tmp held again waited=0 limit
  limit="${FLEET_GH_WRITE_LOCK_WAIT:-1200}"; case "$limit" in ''|*[!0-9]*) limit=1200 ;; esac
  tmp="$l.$me"
  printf '%s\n' "$me" > "$tmp" 2>/dev/null || return 1
  # Polled with builtins only (read / kill -0): a queue of 20 waiters must not
  # fork-storm the box it is trying to be polite on.
  while :; do
    if ln "$tmp" "$l" 2>/dev/null; then rm -f "$tmp"; return 0; fi
    held=; read -r held 2>/dev/null < "$l"
    if [ -n "$held" ] && ! _fleet_gh_pid_alive "$held"; then
      # Re-read right before removing: only the dead holder's file goes.
      again=; read -r again 2>/dev/null < "$l"
      [ "$again" = "$held" ] && rm -f "$l" && fleet_gh_log "write-lock-stale pid=$held"
      continue
    fi
    if [ "$waited" -ge $((limit * 10)) ]; then
      rm -f "$tmp"; fleet_gh_log "write-lock-timeout waited=${limit}s holder=${held:-?}"
      return 1
    fi
    sleep 0.1; waited=$((waited + 1))
  done
}

_fleet_gh_write_unlock() {  # only our own lock — never a successor's
  local h=; read -r h 2>/dev/null < "$1"
  [ "$h" = "$2" ] && rm -f "$1"
  return 0
}

fleet_gh_write() {  # fleet_gh_write <gh args…>
  local d fp lock me locked=0 gap_ms last now dly out err rc tries=0 ra secs base reset src
  d=$(fleet_gh_state_dir); fp=$(_fleet_gh_token_fp)
  lock="$d/gh-write.$fp.lock"
  # OUR pid even inside a $(…) subshell (bash 3.2 has no BASHPID): the command
  # substitution's child execs sh, whose parent is this shell.
  me="${BASHPID:-$(exec sh -c 'printf %s "$PPID"')}"
  _fleet_gh_write_lock "$lock" "$me" && locked=1
  gap_ms=$(awk -v g="${FLEET_GH_WRITE_GAP:-1}" 'BEGIN{ if (g !~ /^[0-9]*[.]?[0-9]+$/) g=1; printf "%d", g*1000 }')
  base="${FLEET_GH_WRITE_BACKOFF:-60}"; case "$base" in ''|*[!0-9]*) base=60 ;; esac
  src="${0##*/}"
  out=$(mktemp "${TMPDIR:-/tmp}/fleet-ghw-out.XXXXXX") || { [ "$locked" = 1 ] && _fleet_gh_write_unlock "$lock" "$me"; _fleet_gh_call "$@"; return $?; }
  err="$out.err"
  while :; do
    # Someone else's secondary refusal still holds → wait it out with them.
    if reset=$(_fleet_gh_limited_any secondary) && [ "$reset" != fake ]; then
      secs=$(( reset - $(date +%s) )); [ "$secs" -gt 900 ] && secs=900
      if [ "$secs" -gt 0 ]; then
        fleet_gh_log "secondary-wait secs=$secs source=$src cause=marker"
        sleep "$secs"
      fi
    fi
    last=$(cat "$d/gh-write.$fp.last" 2>/dev/null); case "$last" in ''|*[!0-9]*) last=0 ;; esac
    now=$(_fleet_gh_now_ms); dly=$(( last + gap_ms - now ))
    [ "$dly" -gt "$gap_ms" ] && dly=$gap_ms        # a clock step never stalls the queue
    _fleet_gh_sleep_ms "$dly"
    _fleet_gh_now_ms > "$d/gh-write.$fp.last.$me" 2>/dev/null \
      && mv -f "$d/gh-write.$fp.last.$me" "$d/gh-write.$fp.last" 2>/dev/null
    _fleet_gh_call "$@" >"$out" 2>"$err"; rc=$?
    [ "$rc" -eq 0 ] && break
    [ "$rc" -eq "$FLEET_GH_LIMITED_RC" ] && break   # down / no answer — never retried here
    # A journaled non-idempotent create owns its reconciliation. Keep this
    # queue/gap, but never infer safe resend from a wrapper's error text.
    [ "${_FLEET_GH_WRITE_ONCE:-0}" = 1 ] && break
    [ "$(fleet_gh_limit_bucket "$(cat "$err" "$out" 2>/dev/null)")" = secondary ] || break
    [ "$tries" -ge 3 ] && break
    ra=$(cat "$out" "$err" 2>/dev/null | tr -d '\r' | sed -n 's/^[Rr]etry-[Aa]fter: *\([0-9][0-9]*\).*/\1/p' | head -1)
    if [ -n "$ra" ]; then secs=$ra; else secs=$(( base << tries )); [ "$secs" -gt 300 ] && secs=300; fi
    tries=$((tries + 1))
    fleet_gh_mark_limited secondary "$(( $(date +%s) + secs ))" "$src"
    fleet_gh_log "secondary-wait secs=$secs source=$src try=$tries${ra:+ retry-after=$ra}"
    sleep "$secs"
  done
  [ "$locked" = 1 ] && _fleet_gh_write_unlock "$lock" "$me"
  [ "$tries" -gt 0 ] && [ "$rc" -eq 0 ] && fleet_gh_log "secondary-ok source=$src tries=$tries"
  cat "$out"; cat "$err" >&2; rm -f "$out" "$err"
  return "$rc"
}

fleet_gh_wrun() {  # fleet_gh_wrun <bucket> <source> <gh args…> — dynamic scope carries the flag
  local _FLEET_GH_WRITE=1
  fleet_gh_run "$@"
}

# --- C2 (#989): reading the limit back — the status bar, doctor and preflight ---
# These READ the marker (and FLEET_GH_FAKE_LIMIT); they never probe GitHub
# themselves (EPIC #1262 C2 接口约定). Forkless on the healthy path — the status
# bar renders through here every 5s per client (issue #888): the clock comes from
# fleet_now_pin's $_FLEET_NOW when the caller pinned one.

# fleet_gh_limit_rows — one `<bucket>\t<reset>\t<source>` line per bucket that is
# limited right now; <reset> is an epoch, or `fake` for an injected limit (which
# has no reset). No output, rc 1, when nothing is limited.
fleet_gh_limit_rows() {
  local now b f k v reset src out='' d
  d="${FLEET_STATE_DIR:-${FLEET_CONF_DIR:-$HOME/.config/claude-fleet}/global}"   # read-only: no mkdir
  now="${_FLEET_NOW:-}"; case "$now" in ''|*[!0-9]*) now=$(date +%s) ;; esac
  for b in graphql core secondary; do
    if fleet_gh_fake_limited "$b"; then
      out="$out$b	fake	FLEET_GH_FAKE_LIMIT
"
      continue
    fi
    f="$d/gh-limit.$b"
    [ -f "$f" ] || continue
    reset='' src=''
    while IFS='=' read -r k v; do
      case "$k" in reset) reset="$v" ;; source) src="$v" ;; esac
    done < "$f"
    case "$reset" in ''|*[!0-9]*) continue ;; esac
    [ "$reset" -gt "$now" ] || continue
    out="$out$b	$reset	${src:-?}
"
  done
  [ -n "$out" ] || return 1
  printf '%s' "$out"
}

# fleet_gh_limit_until — the epoch the LAST live limit lifts (`fake` when only an
# injected one is live); rc 1 when nothing is limited.
fleet_gh_limit_until() {
  local rows b r max='' fake=''
  rows=$(fleet_gh_limit_rows) || return 1
  while IFS='	' read -r b r _; do
    case "$r" in
      fake) fake=1 ;;
      *[!0-9]*|'') ;;
      *) { [ -z "$max" ] || [ "$r" -gt "$max" ]; } && max="$r" ;;
    esac
  done <<< "$rows"
  if [ -n "$max" ]; then printf '%s\n' "$max"; elif [ -n "$fake" ]; then echo fake; else return 1; fi
}

# fleet_gh_hhmm <epoch> — local HH:MM (BSD `date -r`, GNU `date -d @`).
fleet_gh_hhmm() { date -r "$1" '+%H:%M' 2>/dev/null || date -d "@$1" '+%H:%M' 2>/dev/null || printf '?'; }

# fleet_gh_rest_repo_perm <repo> — the REST read of what the preflight's GraphQL
# `gh repo view` asks: `<PERM>\t<default branch>\t<has_issues>`, PERM spelled the
# GraphQL way (ADMIN|MAINTAIN|WRITE|TRIAGE|READ) so one case judges both paths.
# rc $FLEET_GH_LIMITED_RC when REST is limited too.
fleet_gh_rest_repo_perm() {
  # shellcheck disable=SC2016
  fleet_gh_run core preflight api "repos/$1" --jq '
    [ (.permissions // {} |
        if .admin then "ADMIN" elif .maintain then "MAINTAIN" elif .push then "WRITE"
        elif .triage then "TRIAGE" elif .pull then "READ" else "" end),
      (.default_branch // ""), ((.has_issues // true) | tostring) ] | @tsv'
}

# --- one machine, one fetch per repo (issue #3529; was #1271's one per token) ----
# Logins on one machine that host the same repo each ran the same collector /
# pr-refresh / issue-bridge reads — `gh pr list` ~17/min and `gh issue list` ~4/min
# on the mini with four people on two repos, growing with every login (#3522).
# #1271 shared them only between logins of ONE token, which different people never
# are. With FLEET_GH_SHARE=1 they are shared per REPO:
#
# Where: $FLEET_GH_SHARED_DIR (default /Users/Shared/claude-fleet/gh, or
# /var/tmp/claude-fleet/gh with no /Users/Shared), one subdir per repo
# (<owner>-<name>, lowercased). Both 1777, so a login only ever writes files it OWNS:
#   <repo>/pub.<login>/<kind>/<file>   what that login fetched (dirs 0755, files 0644)
#   <repo>/fetch.<kind>.<login>        `<pid> <ms>` while that login fetches <kind>
# <kind> is the cache a caller names: issues · prmap · comments.
#
# A caller asks fleet_gh_share_get before it fetches:
#   * a trusted login's copy no older than the caller's max age → taken, no gh;
#   * a trusted login is fetching it right now (its claim is live: pid alive, under
#     FLEET_GH_SHARE_LEASE 120s) → wait for its copy, ≤ FLEET_GH_SHARE_WAIT (15s);
#     of two claims the earlier wins (a tie: the smaller name), the later waits;
#   * else → the caller fetches, its claim held, and fleet_gh_share_put publishes
#     what it got and drops the claim.
# So a repo is fetched once per TTL however many logins host it.
#
# Trust: a copy is TAKEN only from a login this login names in
# FLEET_GH_SHARE_TRUST (login names, space-separated; `*` = every login here), and
# only from a pub dir that login really owns with no group / other write. The copy
# drives the reapers (a prmap MERGED row) and the dash, so another person's login
# is never trusted by default; empty = publish for others, take nothing.
# Access: a login neither publishes nor takes a repo until its OWN token reads it
# and the repo is public — one REST `GET repos/<r>` a day
# (FLEET_GH_SHARE_ACCESS_SECS), kept in <state>/gh-share/<key>.access. A private
# repo is never shared.
# Off (the default): no file, no fork — the historic behavior byte for byte.
#
# API
#   fleet_gh_share_on                       rc 0 when sharing is on
#   fleet_gh_share_me                       this login's name (FLEET_GH_SHARE_ID seam)
#   fleet_gh_share_root <repo>              print the repo's shared dir (created 1777)
#   fleet_gh_share_access <repo>            rc 0 = this login may share <repo>
#   fleet_gh_share_get <repo> <kind> <maxage> <dir> <stamp> <file>…
#                                           rc 0 = a fresh trusted copy is in <dir>;
#                                           rc 1 = fetch it yourself, then put
#   fleet_gh_share_put <repo> <kind> <ok> <dir> <stamp> <file>…
#                                           ok=1: publish (<stamp> last — it is the
#                                           copy's freshness); always drops the claim

fleet_gh_share_on() { [ "${FLEET_GH_SHARE:-0}" = 1 ]; }

fleet_gh_share_me() {
  local u="${FLEET_GH_SHARE_ID:-${USER:-}}"
  [ -n "$u" ] || u=$(id -un 2>/dev/null)
  printf '%s' "${u//[^A-Za-z0-9._-]/_}"
}

_fleet_gh_repo_key() {  # owner/name → owner-name, lowercased
  local k
  k=$(printf '%s' "$1" | tr 'A-Z/' 'a-z-')
  printf '%s' "${k//[^a-z0-9._-]/_}"
}

fleet_gh_share_root() {  # fleet_gh_share_root <repo>
  local base="${FLEET_GH_SHARED_DIR:-}" r
  if [ -z "$base" ]; then
    base=/var/tmp/claude-fleet/gh; [ -d /Users/Shared ] && base=/Users/Shared/claude-fleet/gh
  fi
  r="$base/$(_fleet_gh_repo_key "$1")"
  if [ ! -d "$r" ]; then
    [ -d "$base" ] || { mkdir -p "$base" 2>/dev/null && chmod 1777 "$base" 2>/dev/null; }
    mkdir "$r" 2>/dev/null && chmod 1777 "$r" 2>/dev/null
  fi
  [ -d "$r" ] && [ ! -L "$r" ] || return 1
  printf '%s' "$r"
}

fleet_gh_share_access() {  # fleet_gh_share_access <repo>
  local d f now at=0 v='' ttl out
  d="$(fleet_gh_state_dir)/gh-share"; f="$d/$(_fleet_gh_repo_key "$1").access"
  now=$(date +%s)
  [ -f "$f" ] && read -r at v < "$f" 2>/dev/null
  case "$at" in ''|*[!0-9]*) at=0 ;; esac
  ttl="${FLEET_GH_SHARE_ACCESS_SECS:-86400}"; case "$ttl" in ''|*[!0-9]*) ttl=86400 ;; esac
  [ "$v" = err ] && ttl=600                 # unanswered: ask again in 10 minutes
  if [ $((now - at)) -ge "$ttl" ]; then
    out=$(fleet_gh_run core share-access api "repos/$1" \
            --jq '"\(.private) \(.permissions.pull // false)"' 2>/dev/null)
    case "$out" in
      'false true') v=ok ;;
      true\ *|'false false') v=no; fleet_gh_log "share-off repo=$1 why=private-or-unreadable" ;;
      *) v=err ;;
    esac
    mkdir -p "$d" 2>/dev/null
    printf '%s %s\n' "$now" "$v" > "$f.$$" 2>/dev/null && mv -f "$f.$$" "$f" 2>/dev/null
    rm -f "$f.$$" 2>/dev/null
  fi
  [ "$v" = ok ]
}

_fleet_gh_share_trusts() {  # <login>
  case " ${FLEET_GH_SHARE_TRUST:-} " in *' * '*|*" $1 "*) return 0 ;; esac
  return 1
}

# <path> is <login>'s and nobody else may write it (a squatter's pub.<you> is not yours)
_fleet_gh_owned_by() {  # <path> <login>
  local o='' m='' g x
  read -r o m <<EOF2
$(stat -c '%U %a' "$1" 2>/dev/null || stat -f '%Su %Lp' "$1" 2>/dev/null)
EOF2
  # FLEET_GH_SHARE_OWNER_AS: the one OS user a selftest's logins all are (seam)
  [ -n "$o" ] && [ "$o" = "${FLEET_GH_SHARE_OWNER_AS:-$2}" ] || return 1
  g="${m%?}"; g="${g: -1}"; x="${m: -1}"
  case "$g$x" in *[2367]*) return 1 ;; esac
  return 0
}

_fleet_gh_mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null; }

_fleet_gh_share_mark() {  # <root> <kind> <ms> — write our claim
  local f
  f="$1/fetch.$2.$(fleet_gh_share_me)"
  printf '%s %s\n' "$$" "$3" > "$f.$$" 2>/dev/null && chmod 644 "$f.$$" 2>/dev/null \
    && mv -f "$f.$$" "$f" 2>/dev/null
  rm -f "$f.$$" 2>/dev/null
  return 0
}

# rc 0 = ours to fetch (claim written); rc 1 = a trusted login claimed it first
_fleet_gh_share_claim() {  # <root> <kind>
  local r="$1" kind="$2" me mine f who pid ms lease
  me=$(fleet_gh_share_me); mine=$(_fleet_gh_now_ms)
  lease="${FLEET_GH_SHARE_LEASE:-120}"; case "$lease" in ''|*[!0-9]*) lease=120 ;; esac
  _fleet_gh_share_mark "$r" "$kind" "$mine"
  for f in "$r/fetch.$kind".*; do
    [ -f "$f" ] || continue
    who="${f##*/fetch."$kind".}"
    [ "$who" = "$me" ] && continue
    _fleet_gh_share_trusts "$who" || continue
    pid='' ms=''; read -r pid ms < "$f" 2>/dev/null
    case "$pid$ms" in ''|*[!0-9]*) continue ;; esac
    [ $(( (mine - ms) / 1000 )) -le "$lease" ] || continue
    _fleet_gh_pid_alive "$pid" && _fleet_gh_owned_by "$f" "$who" || continue
    if [ "$ms" -lt "$mine" ] || { [ "$ms" -eq "$mine" ] && [[ "$who" < "$me" ]]; }; then
      rm -f "$r/fetch.$kind.$me"; return 1
    fi
  done
  return 0
}

# the newest trusted copy no older than <maxage> → <dir>; rc 1 = none
_fleet_gh_share_adopt() {  # <root> <kind> <maxage> <dir> <stamp> <file>…
  local r="$1" kind="$2" maxage="$3" dst="$4" me now d who mt best='' bmt=0 f
  shift 4
  [ -n "${FLEET_GH_SHARE_TRUST:-}" ] || return 1
  me=$(fleet_gh_share_me); now=$(date +%s)
  for d in "$r"/pub.*; do
    who="${d##*/pub.}"
    [ "$who" = "$me" ] && continue
    [ -f "$d/$kind/$1" ] && _fleet_gh_share_trusts "$who" || continue
    mt=$(_fleet_gh_mtime "$d/$kind/$1"); case "$mt" in ''|*[!0-9]*) continue ;; esac
    [ $((now - mt)) -le "$maxage" ] && [ "$mt" -gt "$bmt" ] || continue
    _fleet_gh_owned_by "$d" "$who" || continue
    best="$d/$kind"; bmt="$mt"
  done
  [ -n "$best" ] || return 1
  mkdir -p "$dst" 2>/dev/null
  for f in "$@"; do
    [ -f "$best/$f" ] || continue
    cp "$best/$f" "$dst/.$f.adopt.$$" 2>/dev/null && mv -f "$dst/.$f.adopt.$$" "$dst/$f" 2>/dev/null
    rm -f "$dst/.$f.adopt.$$" 2>/dev/null
  done
  return 0
}

fleet_gh_share_get() {  # fleet_gh_share_get <repo> <kind> <maxage> <dir> <stamp> <file>…
  fleet_gh_share_on || return 1
  local repo="$1" kind="$2" maxage="$3" dst="$4" r waited=0 limit
  shift 4
  case "$maxage" in ''|*[!0-9]*) maxage=0 ;; esac
  fleet_gh_share_access "$repo" || return 1
  r=$(fleet_gh_share_root "$repo") || return 1
  _fleet_gh_share_adopt "$r" "$kind" "$maxage" "$dst" "$@" && return 0
  limit="${FLEET_GH_SHARE_WAIT:-15}"; case "$limit" in ''|*[!0-9]*) limit=15 ;; esac
  while ! _fleet_gh_share_claim "$r" "$kind"; do
    sleep 0.5; waited=$((waited + 1))
    _fleet_gh_share_adopt "$r" "$kind" "$maxage" "$dst" "$@" && return 0
    if [ "$waited" -ge $((limit * 2)) ]; then
      fleet_gh_log "share-wait-timeout repo=$repo kind=$kind waited=${limit}s"
      _fleet_gh_share_mark "$r" "$kind" "$(_fleet_gh_now_ms)"
      return 1
    fi
  done
  return 1
}

fleet_gh_share_put() {  # fleet_gh_share_put <repo> <kind> <ok> <dir> <stamp> <file>…
  fleet_gh_share_on || return 0
  local repo="$1" kind="$2" ok="$3" src="$4" r me d stamp f
  shift 4
  fleet_gh_share_access "$repo" || return 0
  r=$(fleet_gh_share_root "$repo") || return 0
  me=$(fleet_gh_share_me)
  if [ "$ok" = 1 ] && [ -f "$src/$1" ]; then
    d="$r/pub.$me/$kind"
    [ -d "$d" ] || { mkdir -p "$d" 2>/dev/null && chmod 755 "$r/pub.$me" "$d" 2>/dev/null; }
    stamp="$1"; shift
    for f in "$@" "$stamp"; do
      [ -f "$src/$f" ] || continue
      cp "$src/$f" "$d/.$f.$$" 2>/dev/null && chmod 644 "$d/.$f.$$" 2>/dev/null \
        && mv -f "$d/.$f.$$" "$d/$f" 2>/dev/null
      rm -f "$d/.$f.$$" 2>/dev/null
    done
  fi
  rm -f "$r/fetch.$kind.$me" 2>/dev/null
  return 0
}

# --- webhook event stamps: wait on a change, not a clock (issue #1272, R4) -------
# fleet-webhook.sh --route already hears every pull_request / check_run /
# check_suite / status delivery for a forwarded repo. Besides kicking pr-refresh it
# now leaves a STAMP per PR it names — so a waiter (fleet-pr-verdict.sh --wait,
# fleet-gh.sh pr checks) reads GitHub only when something changed, plus one
# confirming read at the end, instead of one read every 15-20s.
#   <state>/events/<slug>/pr-<N>   a delivery naming PR #N (pull_request, or a
#                                  check_run/check_suite's pull_requests[])
#   <state>/events/<slug>/repo     a PR-class delivery naming NO PR (a `status`
#                                  event, a fork PR's check_suite) — and every
#                                  forward (re)connect, since `gh webhook forward`
#                                  never replays what it missed while down
# Content: `<epoch> <event> <id>` — the id makes every write a new value, so a
# waiter compares contents, never mtimes. Written tmp+rename.
# <state> is the webhook daemon's own dir (FLEET_WEBHOOK_STATE_DIR, default
# ~/.config/claude-fleet/webhook — per login, like the daemon).
#
# AVAILABLE (fleet_wh_live) = the handler AND this repo's forward are running.
# Anything else — no daemon, a repo not opted in, a forward mid-restart — and the
# waiter polls exactly as before. A live forward that misses a delivery costs
# freshness only: every waiter still re-reads on a long backstop.
#
#   fleet_wh_state_dir                   the webhook state dir
#   fleet_wh_live <repo>                 rc 0 while deliveries for <repo> arrive
#   fleet_wh_mark <repo> <key> <event>   write one stamp (key: pr-<N> | repo)
#   fleet_wh_sig <repo> <pr>             one line that changes whenever a delivery
#                                        for <pr> (or for the repo) lands
fleet_wh_state_dir() { printf '%s' "${FLEET_WEBHOOK_STATE_DIR:-$HOME/.config/claude-fleet/webhook}"; }

_fleet_wh_slug() {
  if command -v fleet_slug >/dev/null 2>&1; then fleet_slug "$1"
  else printf '%s' "$1" | tr '/' '-' | tr -cd '[:alnum:]._-'; fi
}

_fleet_wh_pid_live() {  # _fleet_wh_pid_live <pidfile>
  local p
  p=$(cat "$1" 2>/dev/null) || return 1
  case "$p" in ''|*[!0-9]*) return 1 ;; esac
  # the machine's one forwarder (issue #4358) is root's: kill -0 on another
  # user's pid says EPERM, which is alive — ps tells
  kill -0 "$p" 2>/dev/null || ps -p "$p" >/dev/null 2>&1
}

fleet_wh_live() {  # fleet_wh_live <repo>
  local d; d=$(fleet_wh_state_dir)
  [ -n "${1:-}" ] || return 1
  _fleet_wh_pid_live "$d/handler.pid" && _fleet_wh_pid_live "$d/forwards/$(_fleet_wh_slug "$1").pid"
}

fleet_wh_mark() {  # fleet_wh_mark <repo> <key> <event>
  local d tmp
  case "${2:-}" in repo|pr-[0-9]*) ;; *) return 1 ;; esac
  d="$(fleet_wh_state_dir)/events/$(_fleet_wh_slug "${1:-}")"
  mkdir -p "$d" 2>/dev/null || return 1
  tmp="$d/.$2.$$"
  printf '%s %s %s.%s\n' "$(date +%s)" "${3:-event}" "$$" "${RANDOM:-0}" > "$tmp" 2>/dev/null \
    && mv -f "$tmp" "$d/$2" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }
}

fleet_wh_sig() {  # fleet_wh_sig <repo> <pr>
  local d; d="$(fleet_wh_state_dir)/events/$(_fleet_wh_slug "${1:-}")"
  printf '%s|%s\n' "$(cat "$d/pr-${2:-}" 2>/dev/null)" "$(cat "$d/repo" 2>/dev/null)"
}
