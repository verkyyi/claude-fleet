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
    # The fleet's OWN identity — its conf's first repo and checkout — is what the
    # controller hashes into the fleet UUID the hub registers. fleet_identity_triplet
    # (bin/fleet-lib.sh) is the one reader, shared with fleet_uuid, so the two agree
    # byte for byte whoever runs them, from whichever pane (issues #1491, #1498).
    # Field 6 (issue #1512): every repo the fleet hosts, one per line —
    # fleet_repos, the conf's own first, then the repos/ overlays — so the hub
    # can place another repo's issue here. It is a list, never part of the UUID.
    while IFS=$'\t' read -r sess _conf; do
      [ -n "$sess" ] || continue
      fleet_identity_triplet "$sess"
      (
        unset TMUX TMUX_PANE
        fleet_load_conf "$sess"
        printf '%s\0' "${FLEET_AGENT:-claude}" "$(fleet_conf_file "$sess")" \
          "$(fleet_repos "$sess")"
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
    fmt=$'#{window_id}\t#{@issue}\t#{@raw}\t#{@worktree}\t#{@claude_state}\t#{@cc_agent}\t#{@wid}\t#{@worker_lifecycle}\t'
    # Column 9 = the window's repo (issue #1018), so a multi-repo fleet's keys
    # carry it: two hosted repos can both have an issue-12. EMPTY in a one-repo
    # fleet (its keys stay bare `issue-N`, as always); `?` = a multi-repo window
    # whose repo is unknown or @norepo — the controller never guesses one.
    # Columns 10-11 (issue #1423): the window name and @origin_wid, for the other
    # machines' sidebars (a remote row's label, and which parent it nests under).
    # Column 12 (issue #1475): what the window needs of its person (@claude_needs:
    # ask / perm / blocked / …), so a remote row draws the same red `?` / `⊘`.
    xfmt=$'\t#{window_name}\t#{@origin_wid}\t#{@claude_needs}'
    if ! fleet_multirepo "$sess"; then
      tmux -u -L "$sock" list-windows -t "=$sess" -F "$fmt$xfmt"
    else
      rows=$(tmux -u -L "$sock" list-windows -t "=$sess" -F "$fmt#{@repo}$xfmt") || exit 1
      while IFS= read -r row; do
        [ -n "$row" ] || continue
        nd=${row##*$'\t'}; row=${row%$'\t'*}
        ow=${row##*$'\t'}; row=${row%$'\t'*}
        nm=${row##*$'\t'}; row=${row%$'\t'*}
        r=${row##*$'\t'}; row=${row%$'\t'*}
        [ -n "$r" ] || r=$(fleet_window_repo "$sess" "${row%%$'\t'*}")
        printf '%s\t%s\t%s\t%s\t%s\n' "$row" "${r:-?}" "$nm" "$ow" "$nd"
      done <<<"$rows"
    fi
    ;;
  ready)
    # Can this login take a NEW session (issue #1475)? The node's heartbeat
    # carries the verdict and the hub's `auto` placement never picks a machine
    # that says no — only a `--node <name>` does. Three things, each named in
    # `missing` when absent: a gh login, a usable Claude or Codex credential (a
    # pool token file, a pool account's hub credential, Claude Code's own
    # credential file or keychain item, Codex's auth.json), and every hosted
    # repo's checkout. One JSON object on stdout; never an exit status.
    missing=''
    gh_ok=false
    if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then gh_ok=true; else missing="$missing gh"; fi
    creds=false
    adir="${FLEET_ACCOUNTS_DIR:-${FLEET_CONF_DIR:-$HOME/.config/claude-fleet}/accounts}"
    for f in "$adir"/*; do
      [ -f "$f" ] || continue
      case "${f##*/}" in .*|*~|*.conf) continue ;; esac
      creds=true; break
    done
    if [ "$creds" = false ]; then
      for d in "$adir"/*.hub; do [ -s "$d/.credentials.json" ] && { creds=true; break; }; done
    fi
    [ "$creds" = true ] || [ -s "$HOME/.claude/.credentials.json" ] && creds=true
    if [ "$creds" = false ] && [ "$(uname -s 2>/dev/null)" = Darwin ] && command -v security >/dev/null 2>&1 \
       && security find-generic-password -s 'Claude Code-credentials' >/dev/null 2>&1; then creds=true; fi
    [ "$creds" = true ] || [ -s "${CODEX_HOME:-$HOME/.codex}/auth.json" ] && creds=true
    [ "$creds" = true ] || missing="$missing creds"
    checkouts=true
    while IFS=$'\t' read -r s _c; do
      [ -n "$s" ] || continue
      while IFS= read -r r; do
        [ -n "$r" ] || continue
        m=$( fleet_load_conf "$s" >/dev/null 2>&1; fleet_load_repo_conf "$s" "$r" >/dev/null 2>&1; printf '%s' "${FLEET_MAIN:-}" )
        [ -n "$m" ] && [ -d "$m" ] || { checkouts=false; missing="$missing checkout:$s/${r##*/}"; }
      done < <(fleet_repos "$s" 2>/dev/null)
    done < <(fleet_each_conf)
    ready=false; [ "$gh_ok" = true ] && [ "$creds" = true ] && [ "$checkouts" = true ] && ready=true
    printf '{"ready":%s,"gh":%s,"creds":%s,"checkouts":%s,"missing":[' "$ready" "$gh_ok" "$creds" "$checkouts"
    sep=''; for w in $missing; do printf '%s"%s"' "$sep" "$w"; sep=','; done
    printf ']}\n'
    ;;
  capacity)
    # This login's own session cap and the count its spawn gate reads (issue
    # #1587): the node's heartbeat carries both, and the hub never places a
    # start on a login at its cap. The same numbers fleet_session_cap_ok
    # refuses on — FLEET_GLOBAL_MAX_SESSIONS (default 8, 0 = unlimited) against
    # the awake session windows of every fleet (a sleeper holds no slot). The
    # in-flight spawns are left out: the asker's own spawn is one of them.
    gmax="${FLEET_GLOBAL_MAX_SESSIONS:-8}"
    case "$gmax" in ''|*[!0-9]*) gmax=8 ;; esac
    printf '{"sessions":%d,"max_sessions":%d}\n' "$(fleet_session_count)" "$gmax"
    ;;
  config)
    fleet_load_conf "$sess"
    printf '%s\0' "${FLEET_MAX_SESSIONS:-0}" "${FLEET_AUTOFILL:-0}" "${FLEET_AUTOFILL_MAX_PER_TICK:-1}"
    ;;
  start)
    fleet_load_conf "$sess"
    agent="${4:-${FLEET_AGENT:-claude}}"
    [ -n "$agent" ] || agent="${FLEET_AGENT:-claude}"
    # $5 = which hosted repo issue $3 belongs to (issue #984): owner/name, slug
    # or bare name. A fleet hosting 2+ repos REQUIRES it — two repos can both
    # have an issue-12 — and an unknown/ambiguous one is refused (6) before any
    # gate runs. A one-repo fleet with no $5 execs exactly as it always has.
    srepo=''
    if [ -n "${5:-}" ]; then
      srepo=$(fleet_repo_for_slug "$sess" "$5") || { printf 'start: %s is not a repo this fleet hosts\n' "$5" >&2; exit 6; }
    elif fleet_multirepo "$sess"; then
      printf 'start: this fleet hosts several repos; name the repo of #%s\n' "${3:-}" >&2; exit 6
    fi
    bash "$BIN/fleet-diskguard.sh" --gate >&2 || exit 4
    if [ "$agent" = codex ]; then
      if [ "${FLEET_CODEX_QUOTA_GATE:-0}" = 1 ]; then
        bash "$BIN/fleet-codex-account.sh" gate --session "$sess" >&2 || exit 4
      fi
    else
      bash "$BIN/fleet-quotaguard.sh" --gate >&2 || exit 4
    fi
    # $6 = the parent's worker_id when another machine's node placed this start
    # here (issue #1425); the window records it as @origin_wid. A start the hub
    # sends is already placed — --node local keeps dash-issue-session from asking
    # the hub a second time (only said with the hub module on: off, the argv is
    # exactly as before).
    owid="${6:-}"
    case "$owid" in ''|*[!A-Za-z0-9/:._-]*) owid='' ;; esac
    here=''; [ "${CCQUOTA_FLEET:-0}" = 1 ] && here=local
    exec bash "$BIN/dash-issue-session.sh" "${3:-}" "$sess" --agent "$agent" --origin hub ${srepo:+--repo "$srepo"} ${owid:+--origin-wid "$owid"} ${here:+--node "$here"}
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
    repo=${FLEET_REPO:-}
    if ! fleet_multirepo "$sess"; then
      [ "${FLEET_ISSUE_BRIDGE:-0}" = 1 ] || exit 5
    else
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
      # The bridge is switched per repo (issue #978): the target repo's own value.
      [ "$(fleet_repo_conf_get "$sess" "$repo" FLEET_ISSUE_BRIDGE)" = 1 ] || exit 5
      set -- "$1" "$2" "$n"
    fi
    case "${3:-}" in ''|*[!0-9]*) exit 2 ;; esac
    exec bash "$BIN/fleet-comment.sh" "$3" --repo "$repo" --to-worker --from hub --body-file -
    ;;
  # --- GitHub through the fleet's own rails (issue #1274) ----------------------
  # gh <sess> issue|pr|checks <N> [<repo>] [<fields>] — fleet-gh.sh: the daemons'
  # local copy first, gh/REST only when it is too old. comment <sess> <N> [<repo>]
  # — body on stdin, record-only (--note), through the per-token write queue.
  # <repo> must be one this fleet hosts; a 2+ repo fleet must name it (6).
  gh|comment)
    fleet_load_conf "$sess"
    if [ "$mode" = gh ]; then n=${4:-}; want=${5:-}; fields=${6:-}; else n=${3:-}; want=${4:-}; fi
    case "$n" in ''|*[!0-9]*) exit 2 ;; esac
    if [ -n "$want" ]; then repo=$(fleet_repo_for_slug "$sess" "$want") || exit 6
    elif fleet_multirepo "$sess"; then exit 6
    else repo=$(fleet_target_repo "$sess") || exit 6
    fi
    if [ "$mode" = comment ]; then
      exec bash "$BIN/fleet-comment.sh" "$n" --repo "$repo" --note --from hub --body-file -
    fi
    # An SSH forced command has no TMPDIR; the daemons that write the cache run
    # with the per-user one (fleet-install-apply.sh), so read the same dir.
    if [ -z "${TMPDIR:-}" ] && t=$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null) && [ -d "$t" ]; then
      export TMPDIR="$t"
    fi
    case "${3:-}" in
      issue)  set -- issue view ;;
      pr)     set -- pr view ;;
      checks) set -- pr checks ;;
      *) exit 2 ;;
    esac
    exec bash "$BIN/fleet-gh.sh" "$1" "$2" "$n" --repo "$repo" ${fields:+--json "$fields"}
    ;;
  stop)
    fleet_load_conf "$sess"
    exec bash "$BIN/fleet-worker-stop.sh" "$sess" "${3:-}"
    ;;
  # --- answer <sess> <key> <answer> [<actor>] (issue #1487, EPIC #1479 C8) -----
  # The hub's worker_answer: what a sidebar on another machine does to a row
  # here that is asking. `yes` / `no` are a PERMISSION prompt's — fleet-permission.sh
  # --allow / --deny, which press exactly the plain Yes / No row the screen shows
  # and only in the name of a human (--by <actor>: the hub journal's actor);
  # anything else is the option number(s) of an AskUserQuestion, fleet-answer.sh
  # --answer's own grammar, one pick per question. Both scripts re-resolve the key
  # to its window here (wid:<key>, fleet_worker_locate) and gate on the transcript
  # + the screen; their exit codes pass through unchanged (fleet_control maps them:
  # 1/3 nothing pending or refused at a gate, 2 malformed, 4 sent but unconfirmed,
  # 5 no named human), and their last stderr line is the reason the hub shows.
  answer)
    fleet_load_conf "$sess"
    key="${3:-}"; ans="${4:-}"; by="${5:-hub}"
    case "$key" in issue-*|scratch-*|*:issue-*|*:scratch-*) ;; *) exit 2 ;; esac
    case "$ans" in
      yes) exec bash "$BIN/fleet-permission.sh" --allow "wid:$key" --session "$sess" --by "$by" ;;
      no)  exec bash "$BIN/fleet-permission.sh" --deny  "wid:$key" --session "$sess" --by "$by" ;;
      '') exit 2 ;;
    esac
    # picks: digits, commas and single spaces only — each becomes one argv word.
    case "$ans" in *[!0-9,\ ]*) exit 2 ;; esac
    # shellcheck disable=SC2086  # the split IS the grammar (one pick per question)
    exec bash "$BIN/fleet-answer.sh" --answer "wid:$key" --session "$sess" $ans
    ;;
  # --- reap <sess> <key> (issue #1487) -----------------------------------------
  # The hub's worker_reap: `dash-reap.sh <key> --yes` — the dash's confirmed ⌃x,
  # unasked (a dirty worktree is still KEPT; a live agent still refuses). dash-reap
  # addresses its fleet through bare `tmux`, as every pane script does, so point
  # bare tmux at THIS fleet's server the way fleet-remote-view.sh does when it has
  # no pane: TMUX=<socket_path>,0,0. The key goes in as itself — dash-reap.sh
  # (fleet-reap-target.py) resolves issue-N / scratch-N to the one window holding
  # it at that moment; a repo-qualified key (<slug>:issue-N, issue #1018) is
  # resolved here first, since the reaper's grammar has no repo prefix. The result
  # token on stdout is the verdict (issue #869); exit 5 = no window holds the key.
  reap)
    fleet_load_conf "$sess"
    key="${3:-}"
    case "$key" in issue-*|scratch-*|*:issue-*|*:scratch-*) ;; *) exit 2 ;; esac
    sock=$(fleet_socket "$sess")
    sp=$(tmux -L "$sock" display-message -p '#{socket_path}' 2>/dev/null)
    [ -n "$sp" ] || { printf 'reap: fleet %s has no running tmux server\n' "$sess" >&2; exit 5; }
    target="$key"
    case "$key" in *:*)
      target=$(fleet_win_for_key "$key" "$sock") && [ -n "$target" ] \
        || { printf 'reap: no live window holds %s on %s\n' "$key" "$sess" >&2; exit 5; } ;;
    esac
    export TMUX="$sp,0,0"
    unset TMUX_PANE
    exec bash "$BIN/dash-reap.sh" "$target" --yes
    ;;
  movein)
    # A session moved here through the hub (issue #1426): $3 is the move id, the
    # rest are fleet-move-remote.sh movein's own flags, each already checked by
    # fleet_hub_common.validate_write. The bundle is where this login's ccquota
    # agent downloaded it — $FLEET_CONF_DIR/control/move-in/<id>.tar — and is
    # removed whatever happens. Exit 6 = a repo this fleet does not host; 4 =
    # the disk gate; the rest are fleet-move-remote.sh movein's.
    fleet_load_conf "$sess"
    mid="${3:-}"; shift 3
    case "$mid" in ''|*[!0-9a-f]*) exit 1 ;; esac
    bundle="$FLEET_CONF_DIR/control/move-in/$mid.tar"
    trap 'rm -f "$bundle"' EXIT
    bash "$BIN/fleet-diskguard.sh" --gate >&2 || exit 4
    bash "$BIN/fleet-move-remote.sh" movein --fleet "$sess" --bundle "$bundle" "$@"
    exit $?
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
