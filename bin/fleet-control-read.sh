#!/bin/bash
# Private, noninteractive adapter for fleet_control.py. All inputs are argv.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
. "$BIN/fleet-lib.sh"
mode="${1:-}"
sess="${2:-}"
# A fleet hosting 2+ repos (issue #790): which repo a key belongs to is the
# WINDOW's (or the ledger's) business, never the fleet conf's FLEET_REPO — two
# repos can both have an issue-12. A key may name its repo, `<repo>:issue-N`
# (the #789 spelling; <repo> = owner/name, slug or bare name); a bare one is
# resolved below and REFUSED when it matches more than one repo. A one-repo
# fleet never enters these paths.
key_repo_split() { # <key> → sets krepo (hosted owner/name, or empty) + kbare
  krepo=''; kbare=$1
  case "$1" in *:issue-*|*:scratch-*)
    krepo=$(fleet_repo_for_slug "$sess" "${1%%:*}") || exit 2
    kbare=${1#*:} ;;
  esac
}
case "$mode" in
  inventory)
    while IFS=$'\t' read -r sess _conf; do
      [ -n "$sess" ] || continue
      (
        fleet_load_conf "$sess"
        printf '%s\0' "$sess" "${FLEET_REPO:-}" "${FLEET_MAIN:-}" "${FLEET_AGENT:-claude}" "$(fleet_conf_file "$sess")"
      )
    done < <(fleet_each_conf)
    ;;
  workers)
    sock=$(fleet_socket "$sess")
    if ! failure=$(tmux -L "$sock" has-session -t "=$sess" 2>&1); then
      case "$failure" in
        *'no server running'*|*'No such file or directory'*|*"can't find session"*) exit 3 ;;
        *) printf '%s\n' "$failure" >&2; exit 1 ;;
      esac
    fi
    # SSH forced commands often have no UTF-8 locale. Without -u, tmux
    # replaces tabs/non-ASCII in format output with underscores.
    # @worker_lifecycle (issue #808): empty = awake; preparing|sleeping|waking|failed
    # while hibernation owns the pane — a stop must not type into a parked pane.
    tmux -u -L "$sock" list-windows -t "=$sess" -F $'#{window_id}\t#{@issue}\t#{@raw}\t#{@worktree}\t#{@claude_state}\t#{@cc_agent}\t#{@wid}\t#{@worker_lifecycle}'
    ;;
  config)
    fleet_load_conf "$sess"
    printf '%s\0' "${FLEET_MAX_SESSIONS:-0}" "${FLEET_AUTOFILL:-0}" "${FLEET_AUTOFILL_MAX_PER_TICK:-1}"
    ;;
  start)
    fleet_load_conf "$sess"
    agent="${4:-${FLEET_AGENT:-claude}}"
    [ -n "$agent" ] || agent="${FLEET_AGENT:-claude}"
    bash "$BIN/fleet-diskguard.sh" --gate >&2 || exit 4
    if [ "$agent" = codex ]; then
      if [ "${FLEET_CODEX_QUOTA_GATE:-0}" = 1 ]; then
        bash "$BIN/fleet-codex-account.sh" gate --session "$sess" >&2 || exit 4
      fi
    else
      bash "$BIN/fleet-quotaguard.sh" --gate >&2 || exit 4
    fi
    exec bash "$BIN/dash-issue-session.sh" "${3:-}" "$sess" --agent "$agent" --origin hub
    ;;
  # --- worker lifecycle by DURABLE key (issue #834) ---------------------------
  # $3 is issue-<N> / scratch-<N>; the window is re-resolved on the fleet at
  # action time (fleet-worker-stop.sh / dash-restore-session.sh), never taken
  # from the caller — a window number is an observation, not an address.
  message)
    # Body on stdin. Relayed by the issue bridge (fleet-issue-bridge.sh), never
    # send-keys: the comment is the durable record AND the delivery. Exit 5 when
    # the fleet has not opted into the bridge — a post would look delivered and
    # reach nobody (issue #489).
    fleet_load_conf "$sess"
    [ "${FLEET_ISSUE_BRIDGE:-0}" = 1 ] || exit 5
    repo=${FLEET_REPO:-}
    if fleet_multirepo "$sess"; then
      key_repo_split "${3:-}"; n=${kbare#issue-}
      case "$n" in ''|*[!0-9]*) exit 2 ;; esac
      if [ -n "$krepo" ]; then repo=$krepo
      else
        # a bare N: the repo of the live window(s) bound to it, when they agree;
        # none, two repos, or an unknown repo (`#N`) → refuse, never a guess.
        repo=$(fleet_bound_windows "$sess" | awk -F'\t' -v s="#$n" '
          { k = $1; if (substr(k, length(k) - length(s) + 1) != s) next
            r = substr(k, 1, length(k) - length(s)); if (!(r in seen)) { seen[r] = 1; c++; last = r } }
          END { if (c == 1 && last != "") print last }')
        [ -n "$repo" ] || { printf 'message: #%s is not live in exactly one repo; name it <repo>:issue-%s\n' "$n" "$n" >&2; exit 2; }
      fi
      set -- "$1" "$2" "$n"
    fi
    case "${3:-}" in ''|*[!0-9]*) exit 2 ;; esac
    exec bash "$BIN/fleet-comment.sh" "$3" --repo "$repo" --to-worker --from hub --body-file -
    ;;
  stop)
    fleet_load_conf "$sess"
    exec bash "$BIN/fleet-worker-stop.sh" "$sess" "${3:-}"
    ;;
  resume)
    # The /fleet-history resume path: verdict first (REVIEW-ONLY ⇒ 5, nothing
    # attempted), the same disk/quota gates a start pays (4), then the headless
    # dash-restore-session.sh (2 = at capacity). A resumed session is a real
    # session: it holds a slot and spends tokens like a start.
    fleet_load_conf "$sess"
    rrepo=''; multi=0
    if fleet_multirepo "$sess"; then
      multi=1; key_repo_split "${3:-}"; rrepo=$krepo
      set -- "$1" "$2" "$kbare"
    fi
    case "${3:-}" in
      issue-*)   rkey="${3#issue-}";  target="landed:issue:$rkey" ;;
      scratch-*) rkey="$3";           target="landed:scratch:$3" ;;
      *) exit 2 ;;
    esac
    case "${rkey#scratch-}" in ''|*[!0-9]*) exit 2 ;; esac
    bash "$BIN/fleet-diskguard.sh" --gate >&2 || exit 4
    if [ "${FLEET_AGENT:-claude}" = codex ]; then
      if [ "${FLEET_CODEX_QUOTA_GATE:-0}" = 1 ]; then
        bash "$BIN/fleet-codex-account.sh" gate --session "$sess" >&2 || exit 4
      fi
    else
      bash "$BIN/fleet-quotaguard.sh" --gate >&2 || exit 4
    fi
    if [ "$multi" = 0 ]; then
      verdict=$(bash "$BIN/fleet-history.sh" resume --repo "${FLEET_REPO:-}" --main "${FLEET_MAIN:-}" "$rkey" 2>/dev/null)
      case "${verdict%%$'\t'*}" in
        RESUME|CODEX-RESUME|FROM-PR) ;;
        *) printf '%s\n' "${verdict:-no verdict}" >&2; exit 5 ;;
      esac
      exec bash "$BIN/dash-restore-session.sh" "$target" "$sess"
    fi
    # multi-repo: the key's own repo when it names one, else the ONE hosted repo
    # whose ledger can resume it — two that can is ambiguous, and is refused.
    hit=''; nhit=0
    while IFS= read -r r; do
      [ -n "$r" ] || continue
      [ -z "$rrepo" ] || [ "$r" = "$rrepo" ] || continue
      verdict=$( fleet_load_repo_conf "$sess" "$r" >/dev/null 2>&1
        bash "$BIN/fleet-history.sh" resume --repo "$r" --main "${FLEET_MAIN:-}" "$rkey" 2>/dev/null )
      case "${verdict%%$'\t'*}" in RESUME|CODEX-RESUME|FROM-PR) hit=$r; nhit=$((nhit+1)) ;; esac
    done < <(fleet_repos "$sess")
    [ "$nhit" = 1 ] || { printf 'resume: %s is resumable in %s repos; name it <repo>:%s\n' "$3" "$nhit" "$3" >&2; exit 5; }
    exec bash "$BIN/dash-restore-session.sh" "$target" "$sess" --repo "$hit"
    ;;
  *) printf 'unsupported control adapter action\n' >&2; exit 2 ;;
esac
