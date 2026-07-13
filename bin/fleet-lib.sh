#!/bin/bash
# fleet-lib.sh — shared helpers for the multi-fleet model (a fleet ≡ a tmux
# session ≡ one repo). Sourced by the collector (write side) and the read-side
# producers (dashboard/backlog). See docs/ARCHITECTURE.md.
#
# The collector does the EXPENSIVE session→repo resolution once per cycle and
# records it in $C/sessmap (session<TAB>slug<TAB>repo). Read-side producers use
# the CHEAP cached lookups below (no git/tmux forks), and fall back to the flat
# prmap/issues names when nothing resolves — so a single-fleet install behaves
# exactly as before.
#
# Shell-options policy (see CONTRIBUTING.md): this file is SOURCED, so it must
# NOT `set -u`/`set -o pipefail` — those would leak into every caller's shell and
# change behaviour far from here. Instead it is written to be safe under a `set -u`
# caller: every optional expansion is defaulted (`${VAR:-}`) and every helper
# returns cleanly.

FLEET_C="${TMPDIR:-/tmp}/.claude-dash"
# Per-fleet configs live here. Override FLEET_CONF_DIR to relocate (used by the
# test harness).
FLEET_CONF_DIR="${FLEET_CONF_DIR:-$HOME/.config/claude-fleet}"

# GLOBAL-ONLY FLEET_* keys (issue #237): read machine-wide — one daemon serving
# EVERY fleet (collector, pr-refresh, spinner, diskguard) or the SYSTEM-WIDE
# session cap — so a per-fleet value is a silent no-op at best, and for the caps
# actively wrong (one fleet raising the machine-wide ceiling for its own spawns).
# fleet_load_conf strips these from the per-fleet overlay so GLOBAL always wins,
# mirroring the prefix+c config modal, which already refuses to WRITE a
# global-scoped key into a per-fleet conf (bin/dash-config-edit.sh). Keep this list
# in step with the @scope=global tags in fleet.conf.example — tmux-config-selftest.sh
# cross-checks the two so they can't drift.
_FLEET_GLOBAL_ONLY="FLEET_GLOBAL_MAX_SESSIONS FLEET_ISSUE_BRIDGE_SECRET FLEET_ISSUE_TTL FLEET_GH_TTL FLEET_PR_REFRESH_INTERVAL FLEET_STUCK_WORKING_SECS FLEET_ACCOUNTS FLEET_ACCOUNT_LIMIT_TTL FLEET_NOTIFY_CMD FLEET_ESCALATE_AFTER FLEET_STATUS_CONTAINER FLEET_DISK_FLOOR_GB FLEET_DISK_WARN_GB FLEET_RUNAWAY_CPU_PCT FLEET_RUNAWAY_CPU_SECS FLEET_RUNAWAY_CPU_ACTION FLEET_USAGE_WARN_PCT FLEET_USAGE_CRIT_PCT FLEET_RATELIMIT_TTL FLEET_WEBHOOK_PORT FLEET_WEBHOOK_SECRET"

# ----------------------------------------------------------------- layout (#181)
# ONE DIRECTORY PER FLEET. A fleet's DURABLE state is keyed by its tmux SESSION
# name and lives under $FLEET_CONF_DIR/fleets/<sess>/ (conf, restore.map,
# bridge/{seen,since}, watch/{keys,needs}, sweep.due). Its RUNTIME cache is keyed
# by repo SLUG and lives under $FLEET_C/fleets/<slug>/ (issues, prmap, labels, …).
# Machine-wide state (sessmap, account.*, git_*/ctx_*/summary_* window caches,
# usage, collapsed) lives under $FLEET_C/global/. Truly global durable state
# (accounts/, diskguard/, restore/{autorestore.on,restore.log}) is unchanged.
#
# These helpers are the SINGLE source of the on-disk layout — no call site should
# hand-build a slug/session-suffixed path. For a transition window (land→migrate)
# the READ-side helpers accept BOTH the new layout and the legacy flat one, so a
# running fleet keeps working until bin/fleet-migrate-layout.sh moves its state.

# Durable per-fleet state dir for <sess> (created on demand). WRITERS use this.
fleet_state_dir() {
  local d="$FLEET_CONF_DIR/fleets/${1:-_}"
  mkdir -p "$d" 2>/dev/null
  printf '%s' "$d"
}

# A session's conf path for READING, dual-layout: the new fleets/<sess>/conf if it
# exists, else the legacy flat <sess>.conf, else the NEW path (so passing this to a
# create still lands in the new layout). Never creates directories.
fleet_conf_file() {
  local sess="${1:-}" new old
  new="$FLEET_CONF_DIR/fleets/$sess/conf"; old="$FLEET_CONF_DIR/$sess.conf"
  if   [ -f "$new" ]; then printf '%s' "$new"
  elif [ -f "$old" ]; then printf '%s' "$old"
  else                     printf '%s' "$new"; fi
}

# Enumerate configured fleets → one "<sess>\t<conf-path>" line each. The new layout
# (fleets/<sess>/conf) is preferred; a legacy flat <sess>.conf is emitted ONLY when
# that session has no new-layout dir yet — so a half-migrated estate lists each
# fleet exactly once. Replaces every `for cf in "$FLEET_CONF_DIR"/*.conf` loop.
fleet_each_conf() {
  local d conf sess
  # An empty conf estate must expand to NOTHING, not abort. zsh's NOMATCH (on by
  # default) errors `no matches found` on an unmatched glob — so when this lib is
  # sourced into a zsh shell and the `fleets/*/` or legacy `*.conf` glob matches
  # nothing, the whole function used to die noisily (issue #295). bash instead
  # passes the literal pattern through, which the per-entry `[ -d ]`/`[ -f ]`
  # guards below already skip. Enable null_glob function-locally under zsh (the
  # local_options save/restore is scoped to this function); bash needs no change.
  [ -n "${ZSH_VERSION:-}" ] && setopt local_options null_glob
  if [ -d "$FLEET_CONF_DIR/fleets" ]; then
    for d in "$FLEET_CONF_DIR"/fleets/*/; do
      [ -d "$d" ] || continue
      conf="${d}conf"; [ -f "$conf" ] || continue
      sess=${d%/}; sess=${sess##*/}
      printf '%s\t%s\n' "$sess" "$conf"
    done
  fi
  for conf in "$FLEET_CONF_DIR"/*.conf; do
    [ -f "$conf" ] || continue
    sess=$(basename "$conf" .conf)
    # dedup only when the NEW-layout conf FILE exists — a fleets/<sess>/ dir that
    # holds just restore.map/bridge/watch (no conf yet) must NOT hide the legacy conf.
    [ -f "$FLEET_CONF_DIR/fleets/$sess/conf" ] && continue
    printf '%s\t%s\n' "$sess" "$conf"
  done
}

# repo (owner/name or any remote URL) → the tmux SESSION name of the configured
# fleet whose FLEET_REPO matches, or empty if none. Lets the repo-native daemons
# (issue-bridge/watch) resolve which fleets/<sess>/ dir owns their state. Compares
# on normalized owner/name so URL vs slug forms match.
fleet_sess_for_repo() {
  local want sess conf rp
  want=$(fleet_norm_repo "${1:-}"); [ -n "$want" ] || return 0
  while IFS=$'\t' read -r sess conf; do
    [ -n "$sess" ] || continue
    rp=$( . "$conf" >/dev/null 2>&1; printf '%s' "${FLEET_REPO:-}" )
    [ "$(fleet_norm_repo "$rp")" = "$want" ] && { printf '%s' "$sess"; return 0; }
  done < <(fleet_each_conf)
  return 0
}

# Per-fleet RUNTIME cache dir for <slug> (created on demand). The single source of
# the runtime layout: callers do "$(fleet_cache_dir "$slug")/issues" instead of
# hand-building "$FLEET_C/issues_$slug".
fleet_cache_dir() {
  local d="$FLEET_C/fleets/${1:-_}"
  mkdir -p "$d" 2>/dev/null
  printf '%s' "$d"
}

# Machine-wide (non-fleet) runtime cache dir — sessmap, account.*, git_*/ctx_*/
# summary_* window caches, usage, ratelimit, collapsed, config scratch. Created on
# demand.
fleet_cache_global() {
  local d="$FLEET_C/global"
  mkdir -p "$d" 2>/dev/null
  printf '%s' "$d"
}

# Filename key for a window's dash-summary cache, machine-wide under global/
# (callers do "$(fleet_cache_global)/summary_$(fleet_summary_key "$sess" "$wid")").
# Post-#159 each fleet runs its OWN tmux server numbering windows from @1, so the
# bare numeric window id — globally unique under the old shared `default` socket —
# now COLLIDES across fleets: fleet A's @2 and fleet B's @2 both mapped to
# summary_2, so one fleet's row bled into another fleet's dash (issue #208).
# Prefixing the (globally-unique, fleet-up-sanitized) session name disambiguates.
# Both parts are sanitized to [A-Za-z0-9._-] so an unexpected char can't escape
# the cache dir; a real session name (fleet-up already strips '.'/':'/space) is
# unchanged, and the numeric id is digits-only, so the key stays stable across
# window reorders. The one hot-path reader (tmux-dashboard-rows.sh) inlines this
# same expansion to stay fork-free, so keep the two byte-identical.
fleet_summary_key() {
  local sess="${1:-}" wid="${2:-}"
  printf '%s_%s' "${sess//[^A-Za-z0-9._-]/_}" "${wid//[^0-9]/}"
}

# Path to the sessmap for READING, dual-layout: the new global/sessmap if present,
# else the legacy flat one (cold start / pre-#181). Writers always write the new
# global/ path via fleet_cache_global.
fleet_sessmap_file() {
  local new="$FLEET_C/global/sessmap"
  [ -f "$new" ] && { printf '%s' "$new"; return; }
  printf '%s' "$FLEET_C/sessmap"
}

# git remote URL (or owner/name) → owner/name. Empty if it isn't GitHub-ish.
fleet_norm_repo() {
  printf '%s' "$1" | sed -E 's#^git@[^:]*:##; s#^https?://[^/]*/##; s#\.git$##; s#/+$##'
}

# The tmux session the caller is running in (pane-targeted, client fallback).
fleet_current_session() {
  local s
  s=$(tmux display-message -p -t "${TMUX_PANE:-}" '#{session_name}' 2>/dev/null)
  [ -z "$s" ] && s=$(tmux display-message -p '#{session_name}' 2>/dev/null)
  printf '%s' "$s"
}

# Overlay a fleet's per-session conf ON TOP of the already-sourced global
# fleet.conf, so FLEET_REPO/FLEET_MAIN/FLEET_BASE_BRANCH/... target THIS fleet.
# Sources into the caller's shell (call it non-subshelled). No-op if absent.
#
# GLOBAL-ONLY keys ($_FLEET_GLOBAL_ONLY) are STRIPPED from the overlay before it is
# sourced (issue #237): they are read machine-wide, so a per-fleet value is a no-op
# at best and, for the SYSTEM-WIDE session cap, actively wrong — a per-fleet
# FLEET_GLOBAL_MAX_SESSIONS would otherwise raise the shared ceiling for THIS
# fleet's spawns (every spawn path + the dispatch/watch daemons load the overlay,
# then read that cap). Filtering here makes GLOBAL win, matching the modal's
# write-side, and everything else — comments, `source` includes, per-fleet keys —
# passes through verbatim.
fleet_load_conf() {
  local conf; conf=$(fleet_conf_file "$1")
  [ -f "$conf" ] || return 0
  # eval the conf with global-only lines filtered out (rather than `. <(grep …)`:
  # process substitution is unreliable when this function runs inside a command
  # substitution, as the dispatch/watch subshell-capture paths do). Confs are
  # trusted assignments-only content, so eval-ing the filtered text is exactly what
  # sourcing would do, minus the stripped keys.
  local _ore; _ore=$(printf '%s' "$_FLEET_GLOBAL_ONLY" | tr ' ' '|')
  eval "$(grep -Ev "^[[:space:]]*(export[[:space:]]+)?(${_ore})=" "$conf")"
  return 0
}

# Resolve the operator-facing BODY of an implementing worker's seed prompt
# (issue #234). A spawned worker is seeded (in dash-issue-session.sh) with:
#   Work GitHub issue #<n> in this repo. <run /fleet-claim …> <BODY><ship+stop tail>
# The head (issue binding), the /fleet-claim ritual (which since issue #283 carries
# the whole lifecycle), and the "open the PR + arm auto-merge, then STOP" tail are
# STRUCTURAL — the machinery depends on them, so they are always kept. Only <BODY>
# is operator-customizable per fleet, letting different fleets seed workers
# differently. Resolution (highest precedence
# first), from the ALREADY-SOURCED conf env (per-fleet ▸ global ▸ default — the
# caller runs fleet_load_conf first):
#   1. FLEET_WORKER_PROMPT_FILE — path to a file whose contents are the body (for a
#      long/multi-line template the single-line config modal can't hold); a leading
#      ~/ is expanded. Set-but-unreadable ⇒ warn on stderr and fall through.
#   2. FLEET_WORKER_PROMPT — an inline body string.
#   3. the built-in default.
# {issue}/{repo} placeholders are substituted (plain parameter expansion, no eval).
# The result is trimmed and a single trailing sentence-ender (. ! ?) removed, so
# the returned fragment flows into the tail (which supplies its own leading '. '/
# ', ' punctuation) — which keeps the DEFAULT body's seed byte-identical to the
# historic hardcoded string. Args: $1=issue number  $2=repo (owner/name).
fleet_worker_prompt_body() {
  local num="${1:-}" repo="${2:-}" body="" f
  local def='Implement and verify per the repo conventions'
  f="${FLEET_WORKER_PROMPT_FILE:-}"
  if [ -n "$f" ]; then
    # A leading ~/ from the conf/modal is a LITERAL tilde (the shell never
    # expanded it in a quoted assignment), so match it literally and expand by
    # hand — the "~/" here is a case PATTERN, not an attempted expansion.
    # shellcheck disable=SC2088
    case "$f" in "~/"*) f="$HOME/${f#\~/}" ;; esac
    if [ -r "$f" ]; then
      body=$(cat "$f")
    else
      printf 'fleet: FLEET_WORKER_PROMPT_FILE not readable (%s) — using inline/default\n' "$f" >&2
    fi
  fi
  [ -n "$body" ] || body="${FLEET_WORKER_PROMPT:-}"
  body="${body//\{issue\}/$num}"
  body="${body//\{repo\}/$repo}"
  # trim leading + trailing whitespace, then one trailing sentence-ender, then any
  # whitespace that ender was hiding — leaving a clean clause for the tail seam.
  body="${body#"${body%%[![:space:]]*}"}"
  body="${body%"${body##*[![:space:]]}"}"
  body="${body%[.!?]}"
  body="${body%"${body##*[![:space:]]}"}"
  [ -n "$body" ] || body="$def"
  printf '%s' "$body"
}

# The GitHub auto-merge strategy the fleet ARMS (issue #283). The fleet never
# merges — /fleet-ship (folded into /fleet-claim) and the dash ⌃l arm
# `gh pr merge --auto --<method>`; GitHub performs the merge when green. Reads
# FLEET_MERGE_METHOD from the already-sourced conf env (fleet_load_conf first).
# squash (default) | merge | rebase — an unset/typo'd value falls back to squash
# so arming never breaks on a bad key. Kept in lockstep with the enum validation
# in fleet-config-lib.sh (fcfg_validate) via tmux-config-selftest.sh.
fleet_merge_method() {
  case "${FLEET_MERGE_METHOD:-}" in
    squash|merge|rebase) printf '%s' "$FLEET_MERGE_METHOD" ;;
    *)                    printf 'squash' ;;
  esac
}

# Print the LAYERED worker charter for /fleet-claim to load into a worker's
# context (issue #283). The built-in contract lives in the skill TEXT (the base
# layer); this emits the two FILE layers that override it, LOW→HIGH precedence so
# "later wins on conflict" reads top-to-bottom for the worker:
#   1. repo charter  $FLEET_MAIN/.fleet/worker.md — an INJECTION SURFACE: PRs
#      auto-merge on green CI with no human review, so a PR could rewrite the
#      charter every future worker then obeys. GATED behind FLEET_REPO_CHARTER=1
#      (default OFF, fail-closed); skipped silently when the gate is off or the
#      file is absent/unreadable.
#   2. fleet overlay $FLEET_CONF_DIR/fleets/<session>/worker.md — operator-owned
#      and machine-local (~/.config, only the operator writes it), so it needs no
#      gate and is always trusted; skipped silently when absent.
# Emits NOTHING when no file layer applies (the worker then runs on the built-in
# defaults == today's behaviour). Needs the fleet conf already sourced
# (FLEET_MAIN / FLEET_CONF_DIR). Arg: $1 = session name (for the overlay path).
fleet_worker_charter() {
  local sess="${1:-}" repo_md overlay_md
  repo_md="${FLEET_MAIN:-}/.fleet/worker.md"
  overlay_md="$FLEET_CONF_DIR/fleets/$sess/worker.md"
  # Repo tier (gated, lower precedence) FIRST so the overlay printed after it wins.
  if [ "${FLEET_REPO_CHARTER:-0}" = 1 ] && [ -r "$repo_md" ]; then
    printf '===== repo charter · %s (lower precedence) =====\n' ".fleet/worker.md"
    cat "$repo_md"
    printf '\n'
  fi
  if [ -n "$sess" ] && [ -r "$overlay_md" ]; then
    printf '===== fleet overlay charter · operator (wins on conflict) =====\n'
    cat "$overlay_md"
    printf '\n'
  fi
}

# Write a fleet's per-session conf, PRESERVING everything the operator added
# (issue #170). fleet-up.sh regenerates this conf on every restore; a naive
# truncating `cat >` silently drops FLEET_ISSUE_BRIDGE / FLEET_CLEANUP /
# FLEET_MAX_SESSIONS / FLEET_STEWARD_ISSUE / … — anything outside
# the derived three. Here we rewrite ONLY the three derived keys (repo/main/base)
# and re-emit every OTHER line from the existing conf verbatim — not just custom
# FLEET_* keys but comments, `source` includes, and plain vars too (dropping any
# of those is the same silent-content-loss class this fix exists to kill). The one
# thing we strip is OUR OWN regenerated header, so repeated rewrites don't stack
# stale headers. Atomic (temp + mv in the same dir) so an interrupted or failed
# write never leaves a truncated conf. Args:
#   $1=conf path  $2=session name  $3=repo  $4=main  $5=base  $6=timestamp string
fleet_write_conf() {
  local conf="$1" name="$2" repo="$3" main="$4" base="$5" stamp="$6"
  local tmp preserved=""
  # The three derived assignment lines we re-derive canonically (optional leading
  # whitespace / `export`), and our own 3-line auto-generated header (matched by
  # its fixed phrasing, timestamp-independent) — both are re-emitted below.
  local derived='^[[:space:]]*(export[[:space:]]+)?FLEET_(REPO|MAIN|BASE_BRANCH)='
  local ourhdr='^# (claude-fleet: fleet .* written by fleet-up\.sh|Overlays the global fleet\.conf|FLEET_\* keys \(see fleet\.conf\.example\))'
  if [ -f "$conf" ]; then
    preserved=$(grep -Ev "$derived" "$conf" 2>/dev/null | grep -Ev "$ourhdr")
  fi
  tmp="$conf.tmp.$$"
  {
    printf "# claude-fleet: fleet '%s' — written by fleet-up.sh %s\n" "$name" "$stamp"
    printf '# Overlays the global fleet.conf for this fleet'\''s tmux session. Add any other\n'
    printf '# FLEET_* keys (see fleet.conf.example) — e.g. FLEET_CTX_WINDOW, FLEET_PROTECTED_RE.\n'
    printf 'FLEET_REPO="%s"\n' "$repo"
    printf 'FLEET_MAIN="%s"\n' "$main"
    printf 'FLEET_BASE_BRANCH="%s"\n' "$base"
    # `if` (not `&&`) so an empty $preserved doesn't make the group exit non-zero.
    if [ -n "$preserved" ]; then printf '%s\n' "$preserved"; fi
  } > "$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$conf" || { rm -f "$tmp"; return 1; }
}

# ---- per-fleet tmux socket (issue #159) -------------------------------------
# A fleet ≡ a tmux SESSION ≡ its OWN tmux server on a NAMED socket, so one
# fleet's fatal crash — or a bypass-permissions worker's stray `tmux kill-server`
# — can only take down ITS OWN fleet, not every fleet sharing the machine (the
# old single `default` socket made the server a whole-machine single point of
# failure). The socket LABEL is the session name itself: fleet-up.sh already
# makes it unique per fleet and sanitizes it (no '.', ':' or space), so one
# string is BOTH the `-L` socket and the `-t` session target.
#
# The dividing line for callers:
#   • INSIDE a pane (Claude hooks, dash producers, zoom/F9 binds, spawn scripts,
#     commands/*.md): tmux inherits the right socket via $TMUX — call bare tmux,
#     no `-L` needed. New windows/sessions they open land on the same (correct)
#     socket automatically.
#   • OUTSIDE any session (launchd/systemd daemons; fleet-up/-down/-restore run
#     from a plain shell): there is no $TMUX, so every tmux call MUST pass
#     `-L "$(fleet_socket "$sess")"`. A daemon that used ONE server-wide
#     `tmux list-windows -a` must instead fan out over fleet_sockets and run its
#     per-fleet logic against each socket (writes stay on the same `-L` label).
fleet_socket() { printf '%s' "$1"; }

# fleet_bg <shell-command> — the shared "background this bind body" helper (issue
# #304). Dispatch <shell-command> as a DETACHED, server-side background job (via
# `tmux run-shell -b`) so the interactive fzf bind / popup that invoked it returns
# INSTANTLY instead of freezing the dash on a slow gh (network) or `git worktree`
# op. This is the ONE place the fleet's non-blocking-bind convention lives; the
# fix pattern is: keep the CHEAP/authoritative checks + optimistic UI synchronous
# on the bind, hand ONLY the slow tail to fleet_bg.
#
# Contract for <shell-command> (it runs LATER, decoupled from the now-gone caller):
#   • self-contained — it runs under `sh -c` with NO cwd/unexported-env guarantee,
#     so use absolute paths (a self re-exec `bash "$0" … --bg` is the usual shape);
#   • silent on stdout/stderr — `run-shell` surfaces any output as a view-mode
#     overlay on the attached client (issue #192), so redirect chatter to
#     /dev/null and report outcomes via `tmux display-message` instead;
#   • reports its OWN outcome — the caller has already returned, so a failure must
#     surface via `tmux display-message`, not an exit status nobody reads.
#
# Socket: run from INSIDE a fleet pane/popup, where $TMUX names THIS fleet's
# server, bare `tmux run-shell` is correct and the backgrounded job inherits the
# same $TMUX (its nested `tmux` calls stay on this fleet's socket). A HEADLESS
# caller with no $TMUX (a daemon/selftest) passes its socket via FLEET_BG_SOCK.
# Safe under a `set -u` caller.
fleet_bg() {
  if [ -n "${FLEET_BG_SOCK:-}" ]; then
    tmux -L "$FLEET_BG_SOCK" run-shell -b "$1" 2>/dev/null
  else
    tmux run-shell -b "$1" 2>/dev/null
  fi
}

# List the socket labels of all fleets with a CURRENTLY-LIVE tmux server, one per
# line. Source of truth: the configured fleets enumerated by fleet_each_conf —
# the new per-fleet layout (fleets/<sess>/conf, label = the DIRECTORY basename)
# with a dual-read of the legacy flat <sess>.conf (issue #203) — filtered to those
# whose server actually answers (`tmux -L <label> has-session`). Routing through
# fleet_each_conf is what makes the socket-aware daemons (bridge/watch/collector-
# fanout/dispatch) find fleets post-#181; a hand-rolled `for cf in …/*.conf` glob
# matched NOTHING after the confs moved under fleets/<sess>/. A downed-but-
# configured fleet (conf kept, server gone) is skipped, and the user's own
# default-socket tmux is never touched. Safe under a `set -u` caller.
fleet_sockets() {
  local sess conf
  [ -d "$FLEET_CONF_DIR" ] || return 0
  while IFS=$'\t' read -r sess conf; do
    [ -n "$sess" ] || continue
    tmux -L "$sess" has-session -t "$sess" 2>/dev/null && printf '%s\n' "$sess"
  done < <(fleet_each_conf)
}

# Emulate the old server-wide `tmux list-windows -a -F <fmt>` across EVERY live
# fleet socket, so a read-side daemon that relied on one estate-wide scan keeps
# its whole-fleet view. Each emitted line is the tmux -F expansion (no socket
# prefix — session_name is globally unique across fleets, so read-side keys don't
# collide). A daemon that must WRITE per window should loop fleet_sockets ITSELF
# so it holds the `-L` label to target the write. Safe under `set -u`.
fleet_list_windows_all() {
  local fmt="$1" label
  while IFS= read -r label; do
    tmux -L "$label" list-windows -a -F "$fmt" 2>/dev/null
  done < <(fleet_sockets)
}

# CHEAP: which SEAT is the caller running in? (see commands/README.md — the
# fleet-skill role-guard.) Prints:
#   worker  — the current tmux window has @issue set AND cwd is inside an
#             issue-<N> git worktree (a session bound to one issue)
#   steward — no @issue on the window AND cwd is the fleet base checkout
#             ($FLEET_MAIN — the hub session that triages, doesn't implement)
#   ""      — neither (ambiguous: a stray shell, or cwd elsewhere)
# Needs FLEET_MAIN in the environment to recognise the steward seat, so call
# fleet_load_conf first. Pure tmux + shell builtins, no git/gh forks.
fleet_seat() {
  local issue cwd main
  issue=$(tmux display-message -p -t "${TMUX_PANE:-}" '#{@issue}' 2>/dev/null)
  cwd=$(pwd -P 2>/dev/null)
  # Match both the bare `issue-<N>` worktree name and the `<repo>-issue-<N>`
  # form that cw.zsh actually creates (dir="$root/../${repo}-${branch}"), where
  # `issue-<N>` is preceded by `-`, not `/`. `*/*issue-[0-9]*` still requires a
  # path separator (a real nested path) but tolerates the `<repo>-` prefix.
  case "$cwd" in
    */*issue-[0-9]*)
      [ -n "$issue" ] && { printf 'worker'; return; } ;;
  esac
  if [ -z "$issue" ] && [ -n "${FLEET_MAIN:-}" ]; then
    main=$(cd "$FLEET_MAIN" 2>/dev/null && pwd -P)
    [ -n "$main" ] && [ "$cwd" = "$main" ] && { printf 'steward'; return; }
  fi
  return 0
}

# Mark a pane with exactly ONE of the mutually-exclusive fleet role markers —
# @dash (the mission-control dashboard) or @steward (the steward hub). Both
# dash-/steward-zoom AND /fleet-sync-install key off these, so a pane must never
# carry both at once (it would read as both a dash to respawn and a steward hub).
# This sets the chosen role to 1 and UNSETS the other, on the pane the caller
# names — defaulting to the caller's OWN pane ($TMUX_PANE), NEVER the active
# pane. tmux's `set-option -p` alone targets the *active* pane, which is wrong
# when the dash relaunches while another pane is focused (issue #135): the marker
# would land on whatever pane happens to be active. Passing `-t <pane>` pins it.
# Args: <dash|steward> [pane-id]   (pane-id defaults to $TMUX_PANE)
fleet_mark_role() {
  local role="${1:-}" pane="${2:-${TMUX_PANE:-}}" on off
  [ -n "$pane" ] || return 0
  case "$role" in
    dash)    on='@dash';    off='@steward' ;;
    steward) on='@steward'; off='@dash' ;;
    *) return 1 ;;
  esac
  tmux set-option -p -t "$pane" "$on" 1  2>/dev/null || true
  tmux set-option -u -p -t "$pane" "$off" 2>/dev/null || true
}

# CHEAP: the @steward=1 pane_id in <session> (that fleet's steward hub pane), or
# empty if the session has none. The shared marker lookup for the SESSION-scoped
# callers steward-zoom.sh and steward-session.sh (issue #146). The issue-bridge
# does NOT use this — it scans @steward panes across ALL sessions in one pass and
# needs @claude_state(_ts) + repo-match in the same row, so it has its own
# machine-wide scan (bridge_find_steward); keep the @steward=1 marker semantics in
# step between the two. Scoped with -s so it never leaks a pane from another fleet.
# Pure tmux + awk, no git/gh forks.
fleet_steward_pane() {
  [ -n "${1:-}" ] || return 0
  # -L "$(fleet_socket "$1")": each fleet is its own tmux server (issue #159); the
  # session arg IS the socket label, so this resolves correctly whether the caller
  # is in-session (steward-zoom via $TMUX → same socket) or out-of-session
  # (steward-session from fleet-up, which has no $TMUX for this fleet's server).
  tmux -L "$(fleet_socket "$1")" list-panes -s -t "$1" -F '#{pane_id} #{@steward}' 2>/dev/null \
    | awk '$2=="1"{print $1; exit}'
}

# The "clean + merged?" gate shared by the worktree janitor (worktree-autoclean.sh)
# and the dash reaper (dash-reap.sh) — ONE source for identical guarantees. Given a
# worktree, decides whether it is safe to auto-remove. Prints a reason token on
# stdout and sets the return code:
#   merged-pr   (rc 0) — clean AND a MERGED PR exists for the branch
#   ancestor    (rc 0) — clean AND the tip is an ancestor of the base ref
#   dirty       (rc 1) — has uncommitted/untracked changes (untracked counts)
#   unmerged    (rc 1) — clean but neither a merged PR nor an ancestor of base
# Args: <worktree-dir> <repo-root> <branch> <head-sha> <base-ref> <merged-branches>
# <merged-branches> is a newline-separated list of merged PR head-ref names (the
# caller's `gh pr list --state merged` output). A caller that only wants the two
# safe outcomes can just test the return code. Safe under a `set -u` caller.
fleet_reap_ok() {
  local wtdir="${1:-}" root="${2:-}" branch="${3:-}" head="${4:-}" base="${5:-}" merged="${6:-}"
  if [ -n "$wtdir" ] && [ -e "$wtdir" ] \
     && [ -n "$(git -C "$wtdir" status --porcelain 2>/dev/null)" ]; then
    printf 'dirty'; return 1
  fi
  if [ -n "$branch" ] && printf '%s\n' "$merged" | grep -qxF "$branch"; then
    printf 'merged-pr'; return 0
  fi
  if [ -n "$head" ] && [ -n "$base" ] \
     && git -C "$root" merge-base --is-ancestor "$head" "$base" 2>/dev/null; then
    printf 'ancestor'; return 0
  fi
  printf 'unmerged'; return 1
}

# Locate the worktree checked out on <branch> in <repo-root>. Prints
# "<worktree-dir>\t<HEAD-sha>" (tab-separated) or nothing if the branch has no
# worktree. Used by dash-reap.sh; the janitor keeps its own full-scan loop since
# it iterates EVERY worktree per cycle, not one branch. Safe under `set -u`.
fleet_worktree_head() {
  local root="${1:-}" branch="${2:-}" line d="" h=""
  [ -n "$root" ] && [ -n "$branch" ] || return 0
  while IFS= read -r line; do
    case "$line" in
      "worktree "*) d="${line#worktree }" ;;
      "HEAD "*)     h="${line#HEAD }" ;;
      "branch refs/heads/$branch") printf '%s\t%s' "$d" "$h"; return 0 ;;
    esac
  done < <(git -C "$root" worktree list --porcelain 2>/dev/null)
  return 0
}

# Reap any processes still anchored to a worktree BEFORE it is removed (issue
# #151). A worker can detach processes — selftest tmux servers, backgrounded
# scripts, hung pipes — that outlive `git worktree remove`: reparented to init,
# invisible to the janitor, they keep burning CPU/fds against the SHARED tmux
# server (a since-fixed hang became a permanent 100%-core drain in crash #3).
# Nothing should outlive its worktree.
#
#   $1  worktree dir (required; a broad root like / or $HOME is refused)
#   $2  mode: "kill" (default) SIGTERM→grace→SIGKILL, or "dry" (report only)
#   $3  grace seconds before SIGKILL (default 2; ignored in dry mode)
#
# Finds them two ways because the crash-#3 orphan had a RELATIVE argv but its cwd
# was inside the worktree: (1) argv references the path (pgrep -f — catches e.g. a
# selftest `tmux -S <dir>/sock`), and (2) cwd is inside the path (lsof, or /proc
# on Linux). Never touches this process, its parent, pid≤1, or the shared tmux
# server. Prints a one-line summary to stdout (the caller logs it). Best-effort:
# absent pgrep/lsof simply narrow the search; it never fails the caller.
fleet_reap_worktree_procs() {
  local dir="${1:-}" mode="${2:-kill}" grace="${3:-2}"
  [ -n "$dir" ] || { printf 'no worktree dir\n'; return 0; }
  dir="${dir%/}"
  # Never sweep a broad root — a bad caller must not turn this into a mass kill.
  case "$dir" in ""|/|/Users|/home|/tmp|/var|"$HOME") printf 'refused (broad root: %s)\n' "$dir"; return 0 ;; esac

  # Canonical (symlink-resolved) form for the cwd match: lsof/readlink report the
  # PHYSICAL path (macOS /var → /private/var), so compare against that. argv match
  # keeps the path as passed (that's how the process references it on its cmdline).
  local cdir; cdir="$(cd "$dir" 2>/dev/null && pwd -P)"; [ -n "$cdir" ] || cdir="$dir"

  local pids="" p re
  # 1) argv references the worktree path. Escape ERE metacharacters so a `.` in
  #    the path can't over-match an unrelated process (pgrep -f is a regex).
  if command -v pgrep >/dev/null 2>&1; then
    re="$(printf '%s' "$dir" | sed 's/[][\\.^$*+?(){}|]/\\&/g')"
    pids="$(pgrep -f "$re" 2>/dev/null)"
  fi
  # 2) cwd is inside the worktree. One lsof lists every process's cwd (macOS +
  #    Linux); fall back to /proc where lsof is absent. Exact prefix match on $cdir.
  if command -v lsof >/dev/null 2>&1; then
    pids="$pids
$(lsof -w -d cwd -Fpn 2>/dev/null | awk -v d="$cdir" '
        /^p/ { pid=substr($0,2) }
        /^n/ { path=substr($0,2)
               if (path==d || substr(path,1,length(d)+1)==d"/") print pid }')"
  elif [ -d /proc ]; then
    for p in /proc/[0-9]*/cwd; do
      case "$(readlink "$p" 2>/dev/null)" in
        "$cdir"|"$cdir"/*) p="${p#/proc/}"; pids="$pids ${p%/cwd}" ;;
      esac
    done
  fi

  # Dedupe → drop self, parent, pid≤1, and the shared tmux server → keep runnable.
  local self=$$ parent="${PPID:-0}" list="" tmuxpid=""
  command -v pgrep >/dev/null 2>&1 && tmuxpid="$(pgrep -x tmux 2>/dev/null; pgrep -f 'tmux: server' 2>/dev/null)"
  for p in $(printf '%s\n' $pids | grep -E '^[0-9]+$' | sort -un); do
    [ "$p" -gt 1 ] 2>/dev/null || continue
    [ "$p" = "$self" ] && continue
    [ "$p" = "$parent" ] && continue
    printf '%s\n' $tmuxpid | grep -qx "$p" && continue
    list="$list $p"
  done
  list="${list# }"
  [ -n "$list" ] || { printf 'no orphan procs\n'; return 0; }

  if [ "$mode" = dry ]; then printf 'would reap:%s\n' " $list"; return 0; fi

  kill -TERM $list 2>/dev/null
  # brief grace, then SIGKILL survivors (a spinning orphan may ignore SIGTERM).
  local i=0; while [ "$i" -lt "$grace" ]; do sleep 1; i=$((i+1)); done
  local survivors=""
  for p in $list; do kill -0 "$p" 2>/dev/null && survivors="$survivors $p"; done
  [ -n "$survivors" ] && kill -KILL $survivors 2>/dev/null
  printf 'reaped:%s%s\n' " $list" "${survivors:+ (SIGKILL$survivors)}"
}

# owner/name → filesystem-safe slug (owner-name).
fleet_slug() {
  printf '%s' "$1" | tr '/' '-' | tr -cd '[:alnum:]._-'
}

# issue title → short kebab window name (lowercase, ascii-alnum + single
# hyphens, ≤32 chars, no leading/trailing hyphen). Used to name a session's
# tmux window after the issue CONTENT instead of a bare "issue-<N>". Prints
# empty when the title has no usable ascii-alnum content (non-latin titles,
# symbols-only) — callers fall back to "issue-<N>". LC_ALL=C so tr classes
# operate byte-wise (multibyte chars collapse to hyphens, not errors).
fleet_win_name() {
  printf '%s' "$1" \
    | LC_ALL=C tr '[:upper:]' '[:lower:]' \
    | LC_ALL=C tr -c 'a-z0-9\n' '-' \
    | LC_ALL=C tr -s '-' \
    | sed -e 's/^-//' -e 's/-$//' \
    | cut -c1-32 \
    | sed -e 's/-$//'
}

# timestamp → friendly relative span (issue #228). Sets $reltime_out to a short,
# human-readable "time since": "now", "5 mins", "2 hours", "3 days", "2 wks",
# "5 mos", "1 yr". Both the dash live-list activity column and the landed history
# rows/list render last-activity through this, so the two lists read alike.
#
# PURE bash (no forks) so it is safe in the dash rows HOT LOOP (one call per
# window per repaint). Args:
#   $1 = epoch SECONDS (all-digits). Non-numeric / empty → reltime_out='' so the
#        caller can render its own "unknown" marker. (ISO timestamps must be
#        pre-converted with fleet_epoch_from_iso — that path forks `date`, which
#        is fine for the ledger but never for the hot loop.)
#   $2 = now epoch SECONDS. Empty/non-numeric → reltime_out='' (caller supplies a
#        NOW it already computed once, keeping this fork-free).
# Widths stay ≤8 ("23 hours") so callers can budget a fixed column.
# shellcheck disable=SC2034  # reltime_out is a caller-facing OUTPUT global (read
# cross-file by the dash/history producers), so it reads as "unused" in this file.
fleet_reltime() {
  reltime_out=''
  local ts="${1:-}" now="${2:-}"
  case "$ts"  in ''|*[!0-9]*) return 0;; esac
  case "$now" in ''|*[!0-9]*) return 0;; esac
  local d=$(( now - ts )); [ "$d" -lt 0 ] && d=0        # clock-skew guard
  local n
  if   [ "$d" -lt 60 ]; then reltime_out='now'
  elif [ "$d" -lt 3600 ];     then n=$(( d / 60 ));       reltime_out="$n min";  [ "$n" -ne 1 ] && reltime_out="$n mins"
  elif [ "$d" -lt 86400 ];    then n=$(( d / 3600 ));     reltime_out="$n hour"; [ "$n" -ne 1 ] && reltime_out="$n hours"
  elif [ "$d" -lt 604800 ];   then n=$(( d / 86400 ));    reltime_out="$n day";  [ "$n" -ne 1 ] && reltime_out="$n days"
  elif [ "$d" -lt 2592000 ];  then n=$(( d / 604800 ));   reltime_out="$n wk";   [ "$n" -ne 1 ] && reltime_out="$n wks"
  elif [ "$d" -lt 31536000 ]; then n=$(( d / 2592000 ));  reltime_out="$n mo";   [ "$n" -ne 1 ] && reltime_out="$n mos"
  else                             n=$(( d / 31536000 )); reltime_out="$n yr";   [ "$n" -ne 1 ] && reltime_out="$n yrs"
  fi
}

# ISO-8601 UTC (e.g. 2026-01-01T00:00:00Z, as the history ledger stores mergedAt
# and gh returns it) → epoch seconds on stdout, empty on failure. Handles GNU
# date (-d) and BSD/macOS date (-j -f). FORKS `date`, so it is for the ledger
# path (once per landed row), NOT the dash hot loop — feed its output into
# fleet_reltime (issue #228).
fleet_epoch_from_iso() {
  local iso="${1:-}"
  case "$iso" in ''|-) return 0;; esac
  date -u -d "$iso" +%s 2>/dev/null && return 0                    # GNU date
  TZ=UTC date -j -f '%Y-%m-%dT%H:%M:%SZ' "$iso" +%s 2>/dev/null    # BSD/macOS date
}

# EXPENSIVE: resolve a tmux session's repo. Order: per-session conf override
# (fleets/<sess>/conf, or the legacy flat <sess>.conf), else the origin remote of
# the first git checkout among its windows, else the global FLEET_REPO. Prints
# owner/name or empty. Collector-only (runs once per cycle).
fleet_resolve_repo_for_session() {
  local sess="$1" conf repo path
  conf=$(fleet_conf_file "$sess")
  if [ -f "$conf" ]; then
    repo=$( . "$conf" >/dev/null 2>&1; printf '%s' "${FLEET_REPO:-}" )
    [ -n "$repo" ] && { fleet_norm_repo "$repo"; return; }
  fi
  while IFS= read -r path; do
    [ -z "$path" ] && continue
    git -C "$path" rev-parse --git-dir >/dev/null 2>&1 || continue
    repo=$(git -C "$path" remote get-url origin 2>/dev/null) || continue
    repo=$(fleet_norm_repo "$repo")
    [ -n "$repo" ] && { printf '%s' "$repo"; return; }
    # -L "$sess": each fleet runs on its own named socket (== session name), so a
    # daemon/collector querying from OUTSIDE tmux must name the socket explicitly.
  done < <(tmux -L "$(fleet_socket "$sess")" list-windows -t "$sess" -F '#{pane_current_path}' 2>/dev/null | awk '!seen[$0]++')
  fleet_norm_repo "${FLEET_REPO:-}"
}

# CHEAP: session → slug from the collector's sessmap (single awk, no forks into
# git/tmux). Prints slug or empty.
fleet_slug_cached() {
  local sm; sm=$(fleet_sessmap_file)
  [ -f "$sm" ] || return 0
  awk -F'\t' -v s="$1" '$1==s{print $2; exit}' "$sm"
}

# CHEAP: session → repo (owner/name) from the sessmap. Prints repo or empty.
fleet_repo_cached() {
  local sm; sm=$(fleet_sessmap_file)
  [ -f "$sm" ] || return 0
  awk -F'\t' -v s="$1" '$1==s{print $3; exit}' "$sm"
}

# CHEAP: list the tmux sessions that are FLEETS — i.e. own a 'plan' or 'dash' hub
# window — one per line. The single source for "which sessions are fleets"; the
# plan/dash hub rule is otherwise copy-pasted across callers. Fans out across
# every live fleet socket (issue #159), since no single server sees them all now.
fleet_hub_sessions() {
  fleet_list_windows_all '#{session_name} #{window_name}' | awk '
    { if ($2=="plan" || $2=="dash") f[$1]=1 } END { for (s in f) print s }'
}

# CHEAP: count the live Claude WORKING-session windows across every fleet (the
# system-wide count issue #28's cap measures). Since each fleet now runs on its
# own socket (issue #159), this fans out over fleet_sockets rather than scanning
# one shared server. A fleet session is one that owns a hub window ('plan' or
# 'dash'); inside it, windows named
# dash/plan/backlog are panels — everything else is a Claude working session
# (the same rule the dashboard uses). Pure tmux + awk, no git/tmux-per-window
# forks. Prints an integer (0 if tmux isn't running or no fleets are up).
fleet_session_count() {
  fleet_list_windows_all '#{session_name} #{window_name}' | awk '
    { rows[NR]=$0; if ($2=="plan" || $2=="dash") fleet[$1]=1 }
    END {
      for (i=1; i<=NR; i++) {
        split(rows[i], a, " "); s=a[1]; w=a[2]
        if (fleet[s] && w!="dash" && w!="plan" && w!="backlog") c++
      }
      print c+0
    }'
}

# CHEAP: count the live Claude WORKING-session windows in ONE fleet session (the
# per-fleet analogue of fleet_session_count, for issue #70's FLEET_MAX_SESSIONS).
# Only counts if the session is a real fleet (owns a 'plan'/'dash' hub window);
# inside it, dash/plan/backlog are panels, everything else is a working session —
# the same rule the dashboard and the global count use. Prints an integer (0 if
# the session isn't a fleet, doesn't exist, or tmux isn't running).
# NB: the hub/panel names (plan/dash/backlog) are duplicated in fleet_session_count
# above — keep BOTH in sync, or the global and per-fleet caps count different sets.
fleet_session_count_for() {
  tmux -L "$(fleet_socket "$1")" list-windows -t "$1" -F '#{window_name}' 2>/dev/null | awk '
    { name=$0; if (name=="plan" || name=="dash") hub=1; rows[NR]=name }
    END {
      if (!hub) { print 0; exit }
      for (i=1; i<=NR; i++) {
        n=rows[i]
        if (n!="dash" && n!="plan" && n!="backlog") c++
      }
      print c+0
    }'
}

# Cap on concurrent Claude working sessions (issues #28, #70). Returns 0 if a new
# session may be spawned, non-zero if a cap is already reached. Two ceilings:
#   • GLOBAL   FLEET_GLOBAL_MAX_SESSIONS (default 8) — SYSTEM-WIDE across all
#              fleets; 0 ⇒ unlimited. Always checked.
#   • PER-FLEET FLEET_MAX_SESSIONS (default 0 = unlimited) — checked ONLY when a
#              session name is passed as $1 (so existing no-arg callers keep the
#              global-only behaviour unchanged) AND the cap is a positive number.
# On refusal, prints a human-readable reason on stdout for the caller to surface
# (tmux display-message); prints nothing when allowed.
fleet_session_cap_ok() {
  local sess="${1:-}"
  local gmax="${FLEET_GLOBAL_MAX_SESSIONS:-8}" fmax="${FLEET_MAX_SESSIONS:-0}" n
  case "$gmax" in ''|*[!0-9]*) gmax=8;; esac   # tolerate a garbled conf value
  case "$fmax" in ''|*[!0-9]*) fmax=0;; esac
  if [ "$gmax" -ne 0 ]; then                   # 0 ⇒ unlimited
    n=$(fleet_session_count)
    if [ "$n" -ge "$gmax" ]; then
      printf 'fleet at capacity: %s/%s Claude sessions running (global) — raise FLEET_GLOBAL_MAX_SESSIONS or close one first' "$n" "$gmax"
      return 1
    fi
  fi
  if [ -n "$sess" ] && [ "$fmax" -ne 0 ]; then
    n=$(fleet_session_count_for "$sess")
    if [ "$n" -ge "$fmax" ]; then
      printf 'fleet at capacity: %s/%s Claude sessions in this fleet — raise FLEET_MAX_SESSIONS or close one first' "$n" "$fmax"
      return 1
    fi
  fi
  return 0
}

# Pick the cache file for <base> (prmap|issues) for a session: the slug'd file if
# the session resolved AND its fetch has COMPLETED (the .ts marker exists, even if
# the repo has 0 rows). Keying off .ts — not file size — so a fleet whose repo
# genuinely has 0 issues/PRs shows empty rather than reading a stale file. This is
# the SINGLE slug-resolution truth every reader uses. Layout (#181): the fetch
# lives at fleets/<slug>/<base>; for the land→migrate transition we also accept the
# legacy flat <base>_<slug> file (the collector regenerates into the new dir within
# a tick). A cold start / unresolved session returns a NON-EXISTENT path so the
# reader treats absent as "loading".
fleet_cache() {
  local base="$1" slug new old
  slug=$(fleet_slug_cached "$2")
  if [ -n "$slug" ]; then
    new="$FLEET_C/fleets/$slug/$base"
    [ -f "$new.ts" ] && { printf '%s' "$new"; return; }
    old="$FLEET_C/${base}_${slug}"          # legacy flat slug-suffixed (pre-#181)
    [ -f "$old.ts" ] && { printf '%s' "$old"; return; }
    printf '%s' "$new"; return              # cold start → new path (won't exist yet)
  fi
  printf '%s' "$FLEET_C/$base"              # unresolved session: degenerate fallback
}
