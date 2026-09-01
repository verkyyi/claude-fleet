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
_FLEET_GLOBAL_ONLY="FLEET_GLOBAL_MAX_SESSIONS FLEET_ISSUE_BRIDGE_SECRET FLEET_ISSUE_TTL FLEET_GH_TTL FLEET_PR_REFRESH_INTERVAL FLEET_STUCK_WORKING_SECS FLEET_ACCOUNTS FLEET_ACCOUNT_LIMIT_TTL FLEET_CLOSE_ON_EXIT FLEET_NOTIFY_CMD FLEET_ESCALATE_AFTER FLEET_STATUS_CONTAINER FLEET_DISK_FLOOR_GB FLEET_DISK_WARN_GB FLEET_QUOTA_GATE FLEET_QUOTA_CEILING FLEET_QUOTA_ACCOUNT FLEET_QUOTA_BIN FLEET_RUNAWAY_CPU_PCT FLEET_RUNAWAY_CPU_SECS FLEET_RUNAWAY_CPU_ACTION FLEET_USAGE_WARN_PCT FLEET_USAGE_CRIT_PCT FLEET_RATELIMIT_TTL FLEET_WEBHOOK_PORT FLEET_WEBHOOK_SECRET FLEET_REAP_KEPT_PROCS FLEET_REAP_KEPT_MINAGE FLEET_HELPER_NO_MCP"

# Source the GLOBAL fleet.conf on load + EXPORT the global-only keys (issue #399).
# ---------------------------------------------------------------------------------
# The $_FLEET_GLOBAL_ONLY keys — headline: the SYSTEM-WIDE cap FLEET_GLOBAL_MAX_SESSIONS
# — live in the install's global fleet.conf, a SIBLING of this bin/ dir. Historically
# a reader saw them only where a script explicitly `. "$BIN/../fleet.conf"`, and even
# then the assignments were NOT exported, so any value re-evaluated in a child the
# parent spawned via tmux (run-shell) fell back to the `:-8` default. Net (issue #399):
# an operator's FLEET_GLOBAL_MAX_SESSIONS=20 rendered as `/8` in the slots chip and
# gated at 8 in some spawn paths. fleet-lib.sh is the ONE choke point ~every reader
# sources (slots chip, spawn gate, daemons), so sourcing the global conf HERE — and
# EXPORTING the global-only keys so children/subshells inherit them — fixes every
# consumer at once. The per-fleet overlay (fleet_load_conf) still STRIPS these keys,
# so GLOBAL still wins over any per-fleet value (issue #237). Guarded against
# double-source; the conf is resolved relative to THIS file (via BASH_SOURCE, $0 under
# zsh), so a dev checkout / test bin with NO sibling fleet.conf is a clean no-op.
# FLEET_SKIP_GLOBAL_CONF=1 opts a hermetic caller out of both the source and the export
# (run-selftests.sh sets it so the gate stays install-independent).
if [ -z "${_FLEET_GLOBAL_CONF_SOURCED:-}" ] && [ -z "${FLEET_SKIP_GLOBAL_CONF:-}" ]; then
  _FLEET_GLOBAL_CONF_SOURCED=1
  _flib_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)"
  if [ -n "$_flib_dir" ] && [ -f "$_flib_dir/../fleet.conf" ]; then
    . "$_flib_dir/../fleet.conf"
  fi
  # eval so the space-separated NAME list re-tokenizes under zsh too (an unquoted
  # $var is NOT word-split there); export of a name the conf left unset is harmless.
  eval "export $_FLEET_GLOBAL_ONLY"
  unset _flib_dir
fi

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
  local want sess conf rp tab
  tab=$(printf '\t')                                 # POSIX tab (ANSI-C quoting is a bashism dash ignores)
  want=$(fleet_norm_repo "${1:-}"); [ -n "$want" ] || return 0
  while IFS="$tab" read -r sess conf; do
    [ -n "$sess" ] || continue
    rp=$( . "$conf" >/dev/null 2>&1; printf '%s' "${FLEET_REPO:-}" )
    [ "$(fleet_norm_repo "$rp")" = "$want" ] && { printf '%s' "$sess"; return 0; }
  done <<EOF
$(fleet_each_conf)
EOF
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

# fleet_summary_sanitize <text> — make a session one-liner safe to hand tmux as the
# @summary WINDOW OPTION the pane border renders (issue #455). The dash column keeps
# reading the raw summary FILE; only this option-bound copy is scrubbed, because the
# border takes a second parsing pass the file never does:
#   • ONE LINE      pane-border-format draws a single row, so CR/LF/TAB → space (a
#                   raw newline would truncate or smear the border).
#   • NO '#'        tmux re-parses the EXPANDED border string in format_draw, so a
#                   '#[' or '#{' arriving from an LLM one-liner would leak a style
#                   or a format token into the header. Substituted values are not
#                   re-expanded, so ',', '{', '%' are inert and stay readable —
#                   '#' is the one byte that must go.
#   • CLIPPED       ~60 chars, an upper bound on what any window option can carry;
#                   the format clips again to the width it can actually draw.
# Squeeze/trim keeps the double spaces a collapsed newline leaves behind out of the
# header. Pure builtins — no forks, and safe under a `set -u` caller.
fleet_summary_sanitize() {
  local s="${1:-}"
  s="${s//$'\n'/ }"; s="${s//$'\r'/ }"; s="${s//$'\t'/ }"
  s="${s//'#'/}"
  while [ "$s" != "${s//  / }" ]; do s="${s//  / }"; done
  s="${s# }"; s="${s% }"
  printf '%s' "${s:0:60}"
}

# --- helper `claude -p` auth: ride the account POOL, not the ambient login (#497)
# The two screen-classifier helpers (bin/tmux-summarize.sh, bin/classify-sessions.sh)
# shell out to `claude -p`. Left bare, that call authenticates from the machine's
# AMBIENT login — the macOS Keychain entry / ~/.claude credentials — which is a
# DIFFERENT credential from the one every worker runs on: bin/fleet-claude.sh exports
# CLAUDE_CODE_OAUTH_TOKEN for the active pool account before exec'ing claude, exactly
# as fleet-account.sh's header describes. So when the ambient login lapsed on
# 2026-08-25, all eleven workers kept running and only the dash's summary column and
# the looping-detector died — the one credential nothing else in the fleet depends on
# was the one credential these two helpers depended on.
#
# This is that missing wire, and only that: the pool token when there IS one, silence
# when multi-account is off (then a bare `claude -p` and its ambient login is still
# exactly right, and this is a no-op). An INHERITED token always wins — the Stop-hook
# path runs as a child of a worker's claude, which already carries the right account's
# token, and re-resolving 'active' there could hand a hook the OTHER account mid-turn.
# Sourced-library rules apply: no `set`, every expansion defaulted, always returns 0.
fleet_helper_claude_auth() {
  [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] && return 0    # inherited (hook path) — keep it
  local _bin label tok
  _bin="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)"
  [ -n "$_bin" ] && [ -x "$_bin/fleet-account.sh" ] || return 0
  label="$(bash "$_bin/fleet-account.sh" active 2>/dev/null)"
  [ -n "$label" ] || return 0                          # multi-account off → ambient login
  tok="$(bash "$_bin/fleet-account.sh" token "$label" 2>/dev/null)"
  [ -n "$tok" ] || return 0
  export CLAUDE_CODE_OAUTH_TOKEN="$tok"
  return 0
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
# the whole lifecycle), and the "open the PR, land it on green, then STOP" tail are
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

# The merge strategy this fleet lands with (issues #283, #441). A worker's
# /fleet-claim ship+land step runs `gh pr merge --<method> --delete-branch` once
# bin/fleet-pr-verdict.sh reads READY. Reads FLEET_MERGE_METHOD from the
# already-sourced conf env (fleet_load_conf first).
# squash (default) | merge | rebase — an unset/typo'd value falls back to squash
# so landing never breaks on a bad key. Kept in lockstep with the enum validation
# in fleet-config-lib.sh (fcfg_validate) via tmux-config-selftest.sh.
fleet_merge_method() {
  case "${FLEET_MERGE_METHOD:-}" in
    squash|merge|rebase) printf '%s' "$FLEET_MERGE_METHOD" ;;
    *)                    printf 'squash' ;;
  esac
}

# The shared "tap-first" charter block (issue #328) — the ONE canonical source,
# appended to the worker charter (fleet_worker_charter below) so a second consumer
# is a one-line call. Emits the block ONLY when FLEET_TAP_FIRST=1 (default OFF); with the
# flag unset/0 it is a silent no-op, so the default charter stays byte-identical.
# It steers HOW a needed decision is asked (a tappable AskUserQuestion menu, cheap
# on a soft keyboard) — guidance, never a mandate, and never about asking MORE.
# Needs the fleet conf already sourced (FLEET_TAP_FIRST); costs no extra tokens
# beyond the charter text itself.
fleet_tap_first_block() {
  [ "${FLEET_TAP_FIRST:-0}" = 1 ] || return 0
  cat <<'EOF'
===== tap-first input · machine-global (FLEET_TAP_FIRST=1) =====
The operator often drives this fleet from an iPad / Termius soft keyboard, where
composing prose is the real friction. When you genuinely need a decision from them
and it is BOUNDED / enumerable, PREFER an `AskUserQuestion` menu of 2–4 concrete
options — recommended option FIRST and clearly labelled — over an open-ended prose
question: picking is ~one keystroke and the auto "Other" gives a free-text escape,
so it collapses most operator input.
Judgment, not a mandate: keep free text for genuinely open input, do NOT manufacture
trivial questions, and when you would normally just proceed, still just proceed. This
steers HOW you ask, not how OFTEN — it must not increase how often you interrupt the
operator. It is about input latency, nothing else.
EOF
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
# Then appends the shared machine-global tap-first block (fleet_tap_first_block,
# issue #328) — emitted only when FLEET_TAP_FIRST=1. Emits NOTHING when no file
# layer applies AND the flag is off (the worker then runs on the built-in defaults
# == today's behaviour). Needs the fleet conf already sourced (FLEET_MAIN /
# FLEET_CONF_DIR / FLEET_TAP_FIRST). Arg: $1 = session name (for the overlay path).
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
  # Machine-global tap-first steer, from the one shared source; a silent no-op
  # unless FLEET_TAP_FIRST=1.
  fleet_tap_first_block
}

# Write a fleet's per-session conf, PRESERVING everything the operator added
# (issue #170). fleet-up.sh regenerates this conf on every restore; a naive
# truncating `cat >` silently drops FLEET_ISSUE_BRIDGE / FLEET_CLEANUP /
# FLEET_MAX_SESSIONS / FLEET_AUTOFILL / … — anything outside
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
  local sess conf tab
  [ -d "$FLEET_CONF_DIR" ] || return 0
  tab=$(printf '\t')                                 # POSIX tab (ANSI-C quoting is a bashism dash ignores)
  while IFS="$tab" read -r sess conf; do
    [ -n "$sess" ] || continue
    tmux -L "$sess" has-session -t "$sess" 2>/dev/null && printf '%s\n' "$sess"
  done <<EOF
$(fleet_each_conf)
EOF
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
    [ -n "$label" ] || continue
    tmux -L "$label" list-windows -a -F "$fmt" 2>/dev/null
  done <<EOF
$(fleet_sockets)
EOF
}

# A Claude session's transcript lives at
# `~/.claude/projects/<encoded-cwd>/<session-id>.jsonl`. Claude Code encodes a
# cwd into that project-dir name by replacing EVERY non-alphanumeric byte with
# '-' (verified on-disk: '/', '.', '_' and spaces all collapse to '-'), not just
# '/'. LC_ALL=C so tr's class is byte-wise ASCII — matches the CLI's per-char rule
# for the (near-universal) ASCII path case. Honours CLAUDE_PROJECTS_DIR so a test
# can point the whole lookup at a temp tree.
# Shared by bin/fleet-history.sh (resolve a REAPED worker's surviving transcript)
# and bin/fleet-context.sh (resolve the CALLER's own live one, issue #464) — one
# copy of the encoding rule, so the two can't drift.
fleet_transcript_dir() {
  local wt="${1:-}"; [ -z "$wt" ] && return 0
  local enc; enc=$(printf '%s' "$wt" | LC_ALL=C tr -c 'A-Za-z0-9' '-')
  printf '%s/%s' "${CLAUDE_PROJECTS_DIR:-$HOME/.claude/projects}" "$enc"
}

# Is this transcript one of the FLEET'S OWN helper `claude -p` calls, not a session
# a human ran? The status classifier and the dashboard summarizer run from INSIDE a
# window's worktree, so their transcripts land in the SAME project dir as the
# session they describe — and they run every ~60s, so they are usually the NEWEST
# file there. Recognise them by their own rubric text (RUBRIC= in
# bin/classify-sessions.sh / bin/tmux-summarize.sh; fleet-history-selftest.sh pins
# both strings against those files so they cannot drift apart silently).
# Canonical copy — bin/fleet-history.sh (indexing) and bin/worktree-autoclean.sh
# (the conversation-scratch keep gate) both key off it.
#
# Read into a variable, then match — `head -c … | grep -q` would exit 141 under
# pipefail when grep closes the pipe early.
fleet_internal_transcript() {   # $1=jsonl path → 0 = fleet-internal, 1 = a real session
  local head_bytes; head_bytes=$(head -c 16384 "${1:-}" 2>/dev/null)
  case "$head_bytes" in
    *"You are a status classifier for a Claude Code"*)          return 0 ;;
    *"You are labeling a Claude Code session for a dashboard"*) return 0 ;;
  esac
  return 1
}

# newest HUMAN *.jsonl session id in a transcript dir (basename sans .jsonl), or
# empty when the dir holds nothing but the fleet's own helper transcripts (a warm
# scratch-pool worktree is exactly that — all 21 transcripts in one such dir were
# classifier/summarizer runs).
#
# NO `| head` here, deliberately. With `set -o pipefail` an early-closing consumer
# makes `ls` die of SIGPIPE and the substitution reports 141 — which silently
# dropped exactly the BUSIEST transcript dirs (331 sessions → skipped, 3 → fine).
fleet_newest_human_session() {
  local dir="${1:-}" list f n=0
  [ -d "$dir" ] || return 0
  list=$(ls -t "$dir"/*.jsonl 2>/dev/null)
  [ -n "$list" ] || return 0
  # Newest first, skipping the fleet's own helper transcripts. Bounded: a dir where
  # the classifier has been busy for days should not cost an unbounded scan.
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    n=$((n + 1)); [ "$n" -gt 200 ] && break
    fleet_internal_transcript "$f" && continue
    basename "$f" .jsonl
    return 0
  done <<EOF
$list
EOF
  return 0
}

# CHEAP: which SEAT is the caller running in? (see commands/README.md — the
# fleet-skill role-guard.) Prints:
#   worker  — the current tmux window has @issue set AND cwd is inside an
#             issue-<N> git worktree (a session bound to one issue)
#   ""      — not a worker (the operator's hub pane, a panel, or a stray shell)
# Since issue #439 the fleet has ONE seat: `worker`. The hub pane is the
# operator's own Claude session, not a fleet role — it is identified by the @hub
# pane marker / FLEET_HUB env (see fleet_hub_pane), never by a seat.
# Pure tmux + shell builtins, no git/gh forks.
fleet_seat() {
  local issue cwd
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
  return 0
}

# Mark a pane with exactly ONE of the mutually-exclusive fleet pane markers —
# @dash (the mission-control dashboard) or @hub (the operator's Claude pane).
# Both dash-/hub-zoom key off these, so a pane must never carry both at once (it
# would read as both a dash to respawn and a hub pane).
# This sets the chosen role to 1 and UNSETS the other, on the pane the caller
# names — defaulting to the caller's OWN pane ($TMUX_PANE), NEVER the active
# pane. tmux's `set-option -p` alone targets the *active* pane, which is wrong
# when the dash relaunches while another pane is focused (issue #135): the marker
# would land on whatever pane happens to be active. Passing `-t <pane>` pins it.
# Args: <dash|hub> [pane-id]   (pane-id defaults to $TMUX_PANE)
fleet_mark_role() {
  local role="${1:-}" pane="${2:-${TMUX_PANE:-}}" on off
  [ -n "$pane" ] || return 0
  case "$role" in
    dash) on='@dash'; off='@hub'  ;;
    hub)  on='@hub';  off='@dash' ;;
    *) return 1 ;;
  esac
  tmux set-option -p -t "$pane" "$on" 1  2>/dev/null || true
  tmux set-option -u -p -t "$pane" "$off" 2>/dev/null || true
}

# CHEAP: the @hub=1 pane_id in <session> (a pane the OPERATOR marked by hand), or
# empty if the session has none. Since the hub went dash-only nothing SETS @hub
# automatically — hub-session.sh no longer splits a Claude pane in — so this
# normally returns empty. It is kept because the marker still confers the cw.zsh
# kill-window exemption (#177/#202) and the session-end-hook bail on any pane an
# operator marks deliberately (`tmux set-option -p @hub 1`). Scoped with -s so it
# never leaks a pane from another fleet. Pure tmux + awk, no git/gh forks.
fleet_hub_pane() {
  [ -n "${1:-}" ] || return 0
  # -L "$(fleet_socket "$1")": each fleet is its own tmux server (issue #159); the
  # session arg IS the socket label, so this resolves correctly whether the caller
  # is in-session (via $TMUX → same socket) or out-of-session (from fleet-up,
  # which has no $TMUX for this fleet's server).
  tmux -L "$(fleet_socket "$1")" list-panes -s -t "$1" -F '#{pane_id} #{@hub}' 2>/dev/null \
    | awk '$2=="1"{print $1; exit}'
}

# CHEAP: the @dash=1 pane_id in <session> (that fleet's dashboard pane), or empty
# if the session has none. The dash IS the hub now, so this is the shared lookup
# for every SESSION-scoped focus caller — hub-zoom.sh (⌂ / F9), dash-zoom.sh
# (prefix+g) and hub-session.sh's idempotency check. Same socket reasoning and
# same -s scoping as fleet_hub_pane above; replaces the hand-rolled list-panes
# that dash-zoom.sh used to inline.
fleet_dash_pane() {
  [ -n "${1:-}" ] || return 0
  tmux -L "$(fleet_socket "$1")" list-panes -s -t "$1" -F '#{pane_id} #{@dash}' 2>/dev/null \
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
  done <<EOF
$(git -C "$root" worktree list --porcelain 2>/dev/null)
EOF
  return 0
}

# Age of a process in SECONDS, portably (issue #469). macOS `ps` has no `etimes`
# (Linux does), so parse the POSIX `etime` field — [[dd-]hh:]mm:ss. Prints 0 for a
# pid that is gone or unparseable, which makes an age gate fail CLOSED (the process
# is treated as brand new and therefore skipped).
fleet_proc_age() {
  local et
  et="$(ps -o etime= -p "${1:-0}" 2>/dev/null | tr -d ' ')"
  [ -n "$et" ] || { printf '0\n'; return 0; }
  printf '%s' "$et" | awk -F'[-:]' '
    { if (NF==4)      s=$1*86400 + $2*3600 + $3*60 + $4
      else if (NF==3) s=$1*3600 + $2*60 + $3
      else if (NF==2) s=$1*60 + $2
      else            s=0
      printf "%d\n", s }'
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
#   $4  minimum process age in seconds (default 0 = no age gate) — see below
#
# Finds them THREE ways, because each earlier pair missed a real orphan:
#   (1) argv references the worktree path (pgrep -f — catches e.g. a selftest
#       `tmux -S <dir>/sock`);
#   (2) cwd is inside the worktree (lsof, or /proc on Linux) — the crash-#3 orphan
#       had a RELATIVE argv but its cwd was in the worktree;
#   (3) cwd/argv is inside the Claude Code SESSION SCRATCHPAD anchored to this
#       worktree (issue #469). That dir lives OUTSIDE the worktree, at
#       …/claude-<uid>/<worktree-path-with-/-turned-to->/<session-uuid>/scratchpad,
#       so a mock server started there (`node mock-yaya-server.js`) matches neither
#       (1) nor (2). Eleven such orphans were found alive 2 days after their window
#       closed. Matched on the mangled component with BOTH delimiters, so
#       `…-scratch-1/` cannot swallow `…-scratch-11/`.
#
# The AGE GATE ($4) exists because (1) greps argv: a live session's transient
# command that merely MENTIONS the path (a `grep`, an `ls`) must never be caught.
# Prune-time callers pass nothing (the dir is going away anyway); the recurring
# kept-worktree sweep in worktree-autoclean.sh passes ~600 so only something that
# has genuinely settled in is eligible.
#
# Never touches this process, its parent, pid≤1, or the shared tmux server. Prints
# a one-line summary to stdout (the caller logs it). Best-effort: absent pgrep/lsof
# simply narrow the search; it never fails the caller.
fleet_reap_worktree_procs() {
  local dir="${1:-}" mode="${2:-kill}" grace="${3:-2}" minage="${4:-0}"
  [ -n "$dir" ] || { printf 'no worktree dir\n'; return 0; }
  dir="${dir%/}"
  # Never sweep a broad root — a bad caller must not turn this into a mass kill.
  case "$dir" in ""|/|/Users|/home|/tmp|/var|"$HOME") printf 'refused (broad root: %s)\n' "$dir"; return 0 ;; esac

  # Canonical (symlink-resolved) form for the cwd match: lsof/readlink report the
  # PHYSICAL path (macOS /var → /private/var), so compare against that. argv match
  # keeps the path as passed (that's how the process references it on its cmdline).
  local cdir; cdir="$(cd "$dir" 2>/dev/null && pwd -P)"; [ -n "$cdir" ] || cdir="$dir"

  # Scratchpad patterns (issue #469): the mangled worktree path, delimited on both
  # sides. Both the canonical and the as-passed form are tried — Claude Code mangles
  # the path it was LAUNCHED with, which may or may not be symlink-resolved; on macOS
  # a $TMPDIR worktree differs between the two (/var → /private/var). They stay TWO
  # scalars rather than one joined list because macOS awk rejects a literal newline
  # inside a -v assignment ("awk: newline in string"), which silently killed the whole
  # cwd matcher when the two forms diverged.
  local mp1 mp2
  mp1="/$(printf '%s' "$cdir" | tr '/' '-')/"
  mp2="/$(printf '%s' "$dir" | tr '/' '-')/"
  [ "$mp2" = "$mp1" ] && mp2=""

  local pids="" p re pat
  # 1) argv references the worktree path. Escape ERE metacharacters so a `.` in
  #    the path can't over-match an unrelated process (pgrep -f is a regex).
  if command -v pgrep >/dev/null 2>&1; then
    for pat in "$dir" "$mp1" "$mp2"; do
      [ -n "$pat" ] || continue
      re="$(printf '%s' "$pat" | sed 's/[][\\.^$*+?(){}|]/\\&/g')"
      pids="$pids
$(pgrep -f "$re" 2>/dev/null)"
    done
  fi
  # 2) cwd is inside the worktree. One lsof lists every process's cwd (macOS +
  #    Linux); fall back to /proc where lsof is absent. Exact prefix match on $cdir.
  if command -v lsof >/dev/null 2>&1; then
    pids="$pids
$(lsof -w -d cwd -Fpn 2>/dev/null | awk -v d="$cdir" -v m1="$mp1" -v m2="$mp2" '
        /^p/ { pid=substr($0,2) }
        /^n/ { path=substr($0,2)
               if (path==d || substr(path,1,length(d)+1)==d"/") { print pid; next }
               if (m1 != "" && index(path, m1)) { print pid; next }
               if (m2 != "" && index(path, m2)) { print pid } }')"
  elif [ -d /proc ]; then
    local cw hit
    for p in /proc/[0-9]*/cwd; do
      cw="$(readlink "$p" 2>/dev/null)"; hit=0
      case "$cw" in "$cdir"|"$cdir"/*) hit=1 ;; esac
      if [ "$hit" = 0 ]; then
        for pat in "$mp1" "$mp2"; do
          [ -n "$pat" ] || continue
          case "$cw" in *"$pat"*) hit=1; break ;; esac
        done
      fi
      [ "$hit" = 1 ] && { p="${p#/proc/}"; pids="$pids ${p%/cwd}"; }
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
    # Age gate (issue #469): skip anything younger than $minage seconds — matcher
    # (1) greps argv, so a live session's transient command that merely names the
    # path would otherwise be caught by a recurring sweep. 0 = gate off.
    if [ "$minage" -gt 0 ] 2>/dev/null; then
      [ "$(fleet_proc_age "$p")" -ge "$minage" ] 2>/dev/null || continue
    fi
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

# path-or-branch → the /fleet-history ledger KEY for a SCRATCH (@raw) session, or
# empty when the argument is not a scratch identity (issue #466).
#
# A scratch has no GitHub issue, so the ledger keys it by the `scratch-<N>` slug
# dash-raw-session.sh allocates — the one identity stable across the session's whole
# life: the branch IS `scratch-<N>`, the worktree IS `<repo-dir>-scratch-<N>`, and
# both outlive a /clear (which cycles the session id) and a window rename. Accepts
# either shape:
#   scratch-4                      (branch)         → scratch-4
#   /repos/claude-fleet-scratch-4  (worktree path)  → scratch-4
#   /repos/claude-fleet-scratch-4/docs (wandered cwd) → ""   (strict — see below)
#   /repos/claude-fleet-issue-9, /main, ""           → ""
# STRICT by design: only a basename ending in `scratch-<digits>` matches, so a pane
# whose cwd wandered into a SUBDIR of a scratch worktree yields NO key rather than a
# bogus one (`scratch-4-docs`) that would never resolve back to a worktree. Callers
# pass @worktree — which dash-raw-session.sh always binds — so the strict rule costs
# nothing real and keeps every scratch key in the ledger reconstructable.
fleet_scratch_key() {
  local s="${1:-}"
  [ -n "$s" ] || return 0
  s="${s%/}"; s="${s##*/}"                     # basename (a branch has no slash)
  case "$s" in
    scratch-*)   s="${s#scratch-}" ;;
    *-scratch-*) s="${s##*-scratch-}" ;;
    *)           return 0 ;;
  esac
  case "$s" in ''|*[!0-9]*) return 0 ;; esac    # digits only → a real scratch-<N>
  printf 'scratch-%s' "$s"
}

# fleet_origin_key — spawn provenance (issue #503): which fleet session is running
# THIS script? Prints the CALLER's own ledger key — `issue-<N>` when the calling
# pane's window carries @issue, `scratch-<N>` when it is an @raw scratch (key
# derived from @worktree, else the pane cwd, via the STRICT fleet_scratch_key) —
# and prints NOTHING for everything else: the dash/backlog/plan panels, the hub,
# a headless caller (no $TMUX). Empty ≡ "hub" everywhere downstream (@origin
# unset, blank ledger column), so the operator's own spawns stay untagged.
# Spawn scripts call this in their FOREGROUND pass — a run-shell -b / fleet_bg
# tail has no caller pane, so the detected value must ride a --origin flag into
# any backgrounded re-invocation. Bare tmux on purpose: inside a pane $TMUX
# already names the right per-fleet socket (the CLAUDE.md socket rail).
fleet_origin_key() {
  [ -n "${TMUX:-}" ] && [ -n "${TMUX_PANE:-}" ] || return 0
  local o iss raw owt path
  o=$(tmux display-message -p -t "$TMUX_PANE" \
        '#{@issue}|#{@raw}|#{@worktree}|#{pane_current_path}' 2>/dev/null)
  [ -n "$o" ] || return 0
  iss=${o%%|*}; o=${o#*|}; raw=${o%%|*}; o=${o#*|}; owt=${o%%|*}; path=${o#*|}
  case "$iss" in
    ''|*[!0-9]*) : ;;
    *) printf 'issue-%s' "$iss"; return 0 ;;
  esac
  if [ "$raw" = 1 ]; then
    local k; k=$(fleet_scratch_key "$owt")
    [ -z "$k" ] && k=$(fleet_scratch_key "$path")
    [ -n "$k" ] && printf '%s' "$k"
  fi
  return 0
}

# The RECORD half of "record before remove" (issue #384): given a worktree a reaper
# is ABOUT to prune, write the matching /fleet-history ledger row so the finished
# session stays listed + resumable no matter WHICH janitor reaps it. History rows
# used to be written ONLY by fleet-cleanup.sh (landed) and fleet-ledger-watch.sh
# (closed-unlanded), so with the cleanup daemon off, worktree-autoclean.sh reaped
# merged workers that then vanished from /fleet-history. Factoring the record step
# HERE and having BOTH reapers call it means it can never again be wired to only one.
# Idempotent: it drives fleet-history.sh record / record-closed, which BOTH dedup on
# the session/transcript key, so two reapers recording the same reap yield ONE row.
#
#   $1 outcome   reap verdict — merged-pr|merged-PR|merged → a LANDED row;
#                ancestor|ancestor-of-*|unmerged|dirty → a CLOSED-UNLANDED row;
#                anything else no-ops. The unmerged|dirty verdicts index a KEPT (not
#                removed) worktree so a hand-closed worker is browsable + resumable
#                the instant it ends (issue #403's SessionEnd hook — the only reaper
#                that records the resumable worktree it deliberately KEEPS; the other
#                reapers only ever pass a reaped merged-pr/ancestor). record-closed
#                needs the worktree present to resolve its transcript, so a keep-case
#                caller records BEFORE nothing / while the worktree still stands.
#   $2 repo      owner/name (for gh PR resolution + the per-repo ledger)
#   $3 main      base checkout (passed through as --main; record itself ignores it)
#   $4 issue     N — the ledger KEY for a worker row. May be empty for a SCRATCH
#                reap (@raw has no issue): the key is then derived from $9/$5 via
#                fleet_scratch_key, so a scratch session is indexed + resumable
#                like any worker (issue #466). No key at all → a clean no-op.
#   $5 worktree  the issue-<N>/scratch-<N> worktree path (record derives transcript-dir + session from it)
#   $6 win       tmux window id for the summary cache, or "" (autoclean: the window is gone)
#   $7 session   fleet session for the summary cache, or ""
#   $8 pr        merged PR number if the caller already knows it, else "" to resolve from branch
#   $9 branch    issue-<N> / scratch-<N> branch — used to resolve the merged PR when
#                $8 is empty, and to derive the scratch key when $4 is empty
#   $10 title    optional display title for the row — the SessionEnd hook passes the
#                window NAME here (the one human-readable identity it has at exit),
#                so an exit-recorded row is never "(untitled)": before this the hook
#                recorded first with NO title and then DEDUPED away ledger-watch's
#                titled row for the same session. record/record-closed use it as a
#                fallback only (a gh-resolved PR title still wins on the landed path).
#   $11 origin   optional spawn provenance (issue #503) — the window's @origin
#                (issue-<N> | scratch-<N> | autofill | bridge), read by the caller
#                BEFORE the window dies, exactly like $10. Empty ≡ hub-spawned;
#                a caller with no window left to ask (worktree-autoclean) omits it.
# Best-effort: never fails the caller (a missing fleet-history.sh / gh just skips).
# Empty --pr/--win/--session are tolerated by fleet-history.sh (treated as unset),
# so they are passed uniformly rather than juggling optional flags (keeps this POSIX
# — fleet-lib is sourced by /bin/sh callers too, so no bash arrays here).
fleet_reap_record() {
  local outcome="${1:-}" repo="${2:-}" main="${3:-}" issue="${4:-}" \
        wt="${5:-}" win="${6:-}" sess="${7:-}" pr="${8:-}" branch="${9:-}" \
        title="${10:-}" origin="${11:-}"
  # KEY: the issue number for a worker; for a SCRATCH reap (no issue) the
  # `scratch-<N>` slug, derived from the branch first (authoritative — the reaper
  # knows it) and the worktree path second (the SessionEnd hook has no branch).
  # Ledger col 2 holds either shape (issue #466).
  local key="$issue"
  if [ -z "$key" ]; then
    key=$(fleet_scratch_key "$branch")
    [ -z "$key" ] && key=$(fleet_scratch_key "$wt")
  fi
  [ -n "$key" ] || return 0
  local _bin hist
  _bin="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)"
  hist="$_bin/fleet-history.sh"
  [ -f "$hist" ] || return 0
  case "$outcome" in
    merged-pr|merged-PR|merged)
      # Resolve the merged PR for the branch when the caller didn't hand us one
      # (worktree-autoclean knows the branch, not the PR number).
      if [ -z "$pr" ] && [ -n "$branch" ] && [ -n "$repo" ] && command -v gh >/dev/null 2>&1; then
        pr="$(gh -R "$repo" pr list --head "$branch" --state merged \
                --json number -q '.[0].number' 2>/dev/null)"
      fi
      bash "$hist" record --repo "$repo" --main "$main" --session "$sess" \
        --pr "$pr" --key "$key" --worktree "$wt" --win "$win" \
        --title "$title" --origin "$origin" >/dev/null 2>&1 || return 0
      ;;
    ancestor|ancestor-of-*|unmerged|dirty)
      # No landed PR (clean tip is an ancestor of base; or a KEPT unmerged/dirty
      # worktree the SessionEnd hook indexes on hand-exit, #403) → record it as
      # closed-unlanded so it stays browsable/resumable. record-closed skips a
      # branch with no transcript and dedups on session-id (idempotent).
      bash "$hist" record-closed --repo "$repo" --session "$sess" \
        --key "$key" --worktree "$wt" --win "$win" \
        --title "$title" --origin "$origin" >/dev/null 2>&1 || return 0
      ;;
  esac
  return 0
}

# owner/name → filesystem-safe slug (owner-name).
fleet_slug() {
  printf '%s' "$1" | tr '/' '-' | tr -cd '[:alnum:]._-'
}

# --- fleet provenance: role + the `<!-- fleet:from … -->` marker (issue #224) --
# The ONE canonical source for "which fleet actor did this and from where". Born
# in bin/fleet-comment.sh's per-role footer; extracted here so the single
# issue-filer channel (bin/fleet-issue-file.sh, #332) stamps the SAME marker on a
# new issue's body that a comment carries — reuse, not a second copy.
#
# fleet_from_role [<explicit>] — resolve the posting role: an explicit value wins
# (a caller can force it), else the durable FLEET_HUB env (hub-session.sh exports
# it, surviving a Bash-tool subshell) ⇒ 'operator', else fleet_seat() ⇒ 'worker',
# else the generic word 'fleet'. Pure env — only the WORD carries identity (the
# charter scrub: never $(hostname) / $USER).
fleet_from_role() {
  local explicit="${1:-}"
  [ -n "$explicit" ] && { printf '%s' "$explicit"; return; }
  [ "${FLEET_HUB:-}" = 1 ] && { printf 'operator'; return; }
  local seat
  seat=$(fleet_seat 2>/dev/null)
  case "$seat" in
    worker)  printf 'worker';  return ;;
  esac
  printf 'fleet'
}

# fleet_from_marker <role> [<repo>] — build the invisible machine marker that
# records the SENDER's binding: role + this fleet's session (fallback: the repo
# slug) + the window's @issue when issue-bound. session/issue are omitted when
# empty, matching bin/fleet-comment.sh byte-for-byte so its footer selftest stays
# green. Repo-derived only, so nothing private leaks (the charter scrub).
fleet_from_marker() {
  local role="$1" repo="${2:-}" f_issue f_session mk
  f_issue=$(tmux display-message -p -t "${TMUX_PANE:-}" '#{@issue}' 2>/dev/null)
  f_issue="${f_issue//[^0-9]/}"
  f_session=$(fleet_current_session 2>/dev/null)
  [ -z "$f_session" ] && [ -n "$repo" ] && f_session=$(fleet_slug "$repo" 2>/dev/null)
  mk="<!-- fleet:from role=$role"
  [ -n "$f_session" ] && mk="$mk session=$f_session"
  [ -n "$f_issue" ]   && mk="$mk issue=$f_issue"
  mk="$mk -->"
  printf '%s' "$mk"
}

# --- fleet label taxonomy: the fixed, curated set (issue #333) -----------------
# The ONE canonical label taxonomy for a fleet repo — the curated labels this
# repo already uses, NOT a parallel `type:*` namespace. Two consumers share this
# single source of truth so they can never drift:
#   • bin/fleet-labels-seed.sh `gh label create`s every row (name/color/desc) so
#     a fresh-repo install ends up with the full set (nothing seeds labels at
#     install otherwise — `gh label` starts empty on a new repo).
#   • the issue-filer channel (bin/fleet-issue-file.sh, #332) validates a
#     requested label against fleet_labels_allowed — the FIXED set, not the live
#     `gh label list` — so no filer can file against an
#     off-taxonomy label even if one has been minted in the repo out of band.
#     Fixed seed, no minting.
# `autoland` is a known-stale label (its daemon retired in #277) but is kept in
# the set FOR NOW; retiring it is deferred to a separate follow-up.
#
# fleet_labels_canonical — prints the taxonomy as `name|color|description` rows,
# one per line (`|` never appears in a name/color/description). The seed script
# reads all three columns; fleet_labels_allowed reads only the first.
fleet_labels_canonical() {
  cat <<'EOF'
bug|D73A4A|A real defect
enhancement|a2eeef|New feature or request
cleanup|FEF2C0|Dead code, retirement, housekeeping
robustness|B60205|Reliability, races, error handling
portability|1D76DB|Cross-platform / dependency support
ci|0E8A16|Continuous integration & linting
docs-truth|5319E7|Docs that contradict the code
scout|0e8a16|Read-only investigation (no PR expected)
priority:p0|B60205|Highest priority — sorts first in the backlog (tier 0)
priority:p1|D93F0B|High priority — backlog tier 1 (after all p0)
priority:p2|FBCA04|Medium priority — backlog tier 2 (after all p1)
blocked|b60205|Blocked on another issue — excluded from autofill
autoland|0e8a16|Opt this issue's PR into hands-off auto-land
autofill|0e8a16|Opt this issue into hands-off auto-spawn (the autofill dispatcher)
EOF
}

# fleet_labels_allowed — just the label NAMES from the canonical taxonomy, one
# per line. The issue-filer channel validates against THIS fixed set (fixed
# seed, no minting, #333) — no `gh label list` round-trip, deterministic offline.
fleet_labels_allowed() {
  fleet_labels_canonical | cut -d'|' -f1
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
  done <<EOF
$(tmux -L "$(fleet_socket "$sess")" list-windows -t "$sess" -F '#{pane_current_path}' 2>/dev/null | awk '!seen[$0]++')
EOF
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
# ---- scratch worktree allocation (shared by the ⌃s spawner and the warm pool) --
# fleet_scratch_alloc <main> <base> — allocate the next free `scratch-<N>` branch
# and its sibling worktree off origin/<base> (falling back to the local base ref
# when there is no origin). `git worktree add -b` IS the serialization point — it
# FAILS if the branch or dir already exists — so concurrent callers retry with the
# next N rather than trusting a check-then-create gap. Prints "<slug>\t<worktree>".
fleet_scratch_alloc() {
  local main="$1" base="$2" dir bse cand cwt n=1
  dir="$(dirname "$main")"; bse="$(basename "$main")"
  git -C "$main" fetch origin "$base" --quiet 2>/dev/null
  while [ "$n" -le 999 ]; do
    cand="scratch-$n"; cwt="$dir/$bse-$cand"
    if git -C "$main" show-ref --verify --quiet "refs/heads/$cand" 2>/dev/null || [ -e "$cwt" ]; then
      n=$((n + 1)); continue
    fi
    # >/dev/null 2>&1, not just 2>/dev/null: `git worktree add` reports "Preparing
    # worktree …" on stderr but "HEAD is now at <sha>" on STDOUT, and under
    # `run-shell -b` any stdout becomes a view-mode overlay over the dash (#446).
    if git -C "$main" worktree add -b "$cand" "$cwt" "origin/$base" >/dev/null 2>&1 \
       || git -C "$main" worktree add -b "$cand" "$cwt" "$base" >/dev/null 2>&1; then
      printf '%s\t%s\n' "$cand" "$cwt"; return 0
    fi
    n=$((n + 1))
  done
  return 1
}

# fleet_scratch_free <main> <slug> <worktree> — undo an allocation (failed spawn,
# or a warm-pool entry retired unclaimed). Never fails the caller.
fleet_scratch_free() {
  git -C "$1" worktree remove --force "$3" >/dev/null 2>&1
  git -C "$1" branch -D "$2" >/dev/null 2>&1
  git -C "$1" worktree prune >/dev/null 2>&1
  return 0
}

# fleet_pool_session <sess> — the HOLDING session that parks pre-warmed scratch
# windows for <sess>, on the same socket. It deliberately has NO plan/dash window:
# that is what keeps warm entries invisible to fleet_session_count (which only
# counts sessions that HAVE a hub), to fleet_session_count_for (fleet-scoped) and
# to the dash rows (scoped by FLEET_SESSION) — no per-consumer opt-out to forget.
fleet_pool_session() { printf '%s-pool\n' "$1"; }

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

# Compact "slots N/max" chip for the backlog header / dash (issue #331): the
# GLOBAL session cap (FLEET_GLOBAL_MAX_SESSIONS, default 8) silently blocks EVERY
# spawn path, but nothing surfaces fullness today — so a cap refusal is an ambush.
# This makes it expected: reuse fleet_session_count (the SAME cross-fleet count the
# cap measures — pure tmux+awk, no network) and render an ANSI-truecolor chip:
# dim with headroom, orange at the last free slot, red at/over the cap. Pass a
# precomputed count as $1 to avoid a second scan (and for hermetic tests). With the
# cap disabled (gmax=0 ⇒ unlimited) it shows a bare "slots N" (no denominator/color).
fleet_slots_chip() {
  local n="${1:-}" gmax="${FLEET_GLOBAL_MAX_SESSIONS:-8}" col reset
  reset=$(printf '\033[0m')                          # POSIX ESC[0m — $'…' is a bashism dash ignores
  case "$gmax" in ''|*[!0-9]*) gmax=8;; esac
  [ -n "$n" ] || n=$(fleet_session_count)
  case "$n" in ''|*[!0-9]*) n=0;; esac
  if [ "$gmax" -eq 0 ]; then                     # unlimited → no denominator, no color
    printf 'slots %s' "$n"; return
  fi
  if   [ "$n" -ge "$gmax" ];       then col='247;118;142'   # full      → red    (P0)
  elif [ "$n" -ge $((gmax - 1)) ]; then col='224;175;104'   # last slot → orange (P1)
  else                                  col='86;95;137'     # headroom  → dim    (GY)
  fi
  printf '\033[38;2;%sm slots %s/%s %s' "$col" "$n" "$gmax" "$reset"
}

# --- backlog modal column geometry (issue #371) ------------------------------
# The backlog rows (bin/tmux-issues-rows.sh) lay field-2 out as fixed-width
# columns so every title starts at the same screen column; the backlog header
# (bin/tmux-issues.sh) draws a matching column-title line so the modal reads as a
# table. Both derive from these VISIBLE-column widths: the two PADDINGS (NUM/MS)
# are consumed directly by the row printf; the CONTENT column (PRI) is the fixed
# 2-col literal it emits — a p0/p1/p2 tag — that this constant documents. The
# owner column (its 2-col MARK marker + 14-col NAME) was dropped in issue #389.
# backlog-header-cols-selftest.sh pins the header offsets against a REAL rendered
# row so a width change can't silently misalign them.
FLEET_BL_W_NUM=5      # #num         — %-5s
FLEET_BL_W_PRI=2      # priority tag — p0/p1/p2 or 2 spaces (content-defined)
FLEET_BL_W_MS=12      # milestone    — name or ·, DISPLAY-cell-padded (flat list — issue #377)

# fleet_pad_display <string> <cells> — the display-CELL-aware analogue of
# `printf "%-<cells>.<cells>s"`, for the CJK-bearing backlog milestone column.
# `printf`'s width/precision count BYTES: a CJK glyph is 3 UTF-8 bytes but 2
# screen cells, so `%-12.12s` sizes a Chinese milestone by bytes and every column
# after it drifts off the header (issue #432). This left-justifies <string> into
# EXACTLY <cells> terminal columns — truncating on a glyph boundary (never mid
# wide-glyph) and right-padding with spaces — so the title always starts at the
# header's title offset on ASCII and CJK rows alike. Cell rules mirror the
# dashboard summary clip (bin/tmux-dashboard-rows.sh): East-Asian wide / fullwidth
# = 2, zero-width combining = 0, else 1. Fast path — a pure-ASCII arg has
# width == byte count, so it forks nothing and renders byte-identical to the old
# printf; a non-ASCII arg pays one `perl -CO` fork. The `[:ascii:]` test is a
# bash/glibc class (this file's live callers are all #!/bin/bash); should it ever
# run under a shell that lacks it, or perl be missing, it falls back to the old
# byte-count printf — degraded (may misalign CJK) but never crashing or splitting
# a glyph into garbage.
fleet_pad_display() {
  local s="$1" cells="$2" out
  [ "$cells" -le 0 ] && return 0
  case $s in
    *[![:ascii:]]*)
      out=$(S="$s" N="$cells" perl -CO -MEncode -e '
        my $s = decode_utf8($ENV{S}); my $n = $ENV{N} + 0;
        my ($w, $o) = (0, "");
        for my $c (split //, $s) {
          my $x = ord $c;
          my $cw =
            ($x == 0x200B || ($x >= 0x0300 && $x <= 0x036F) || ($x >= 0x1AB0 && $x <= 0x1AFF) ||
             ($x >= 0x1DC0 && $x <= 0x1DFF) || ($x >= 0x20D0 && $x <= 0x20FF) ||
             ($x >= 0xFE20 && $x <= 0xFE2F)) ? 0 :
            ($x >= 0x1100 && (
               $x <= 0x115F || $x == 0x2329 || $x == 0x232A ||
               ($x >= 0x2E80 && $x <= 0x303E) || ($x >= 0x3041 && $x <= 0x33FF) ||
               ($x >= 0x3400 && $x <= 0x4DBF) || ($x >= 0x4E00 && $x <= 0x9FFF) ||
               ($x >= 0xA000 && $x <= 0xA4CF) || ($x >= 0xAC00 && $x <= 0xD7A3) ||
               ($x >= 0xF900 && $x <= 0xFAFF) || ($x >= 0xFE10 && $x <= 0xFE19) ||
               ($x >= 0xFE30 && $x <= 0xFE6F) || ($x >= 0xFF00 && $x <= 0xFF60) ||
               ($x >= 0xFFE0 && $x <= 0xFFE6) || ($x >= 0x1F000 && $x <= 0x1FAFF) ||
               ($x >= 0x20000 && $x <= 0x3FFFD))) ? 2 : 1;
          last if $w + $cw > $n;
          $w += $cw; $o .= $c;
        }
        print $o . (" " x ($n - $w));' 2>/dev/null)
      if [ -n "$out" ]; then printf '%s' "$out"; else printf '%-*.*s' "$cells" "$cells" "$s"; fi
      ;;
    *) printf '%-*.*s' "$cells" "$cells" "$s" ;;
  esac
}

# The backlog column-title line (issue #371): a dim/muted header row whose labels
# sit over field-2's fixed columns. Printed by bin/tmux-issues.sh as an extra
# --header line above the hint line. Label start offsets are DERIVED from the
# widths above (each `+ 1` is the inter-column space the row emits): `#` at the
# num column, `pri` at the priority column, `milestone` at the milestone column,
# `title` at the title column. The priority→milestone step is `+ 2` (a 2-col gap,
# matched by the row) so the 3-char `pri` label — one wider than the 2-col
# priority tag it heads — still clears the `milestone` label. The owner column was
# dropped in issue #389. fzf --ansi renders the color; dim so it reads as a
# header, not a row.
fleet_backlog_col_header() {
  local dim='86;95;137' reset
  reset=$(printf '\033[0m')                          # POSIX ESC[0m — $'…' is a bashism dash ignores
  local off_pri=$((FLEET_BL_W_NUM + 1))
  local off_ms=$((off_pri + FLEET_BL_W_PRI + 2))
  local off_title=$((off_ms + FLEET_BL_W_MS + 1))
  local s='#'
  while [ "${#s}" -lt "$off_pri" ];   do s="$s "; done; s="${s}pri"
  while [ "${#s}" -lt "$off_ms" ];    do s="$s "; done; s="${s}milestone"
  while [ "${#s}" -lt "$off_title" ]; do s="$s "; done; s="${s}title"
  printf '\033[38;2;%sm%s%s' "$dim" "$s" "$reset"
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

# ── display-width clip (shared by the live dash + /fleet-history producers) ────
# Clip <string> to at most <avail> TERMINAL COLUMNS and report the width it really
# occupies → $clip_out / $clip_w. A CJK or emoji glyph is ONE ${#} char but TWO
# columns, so a code-point clip lets through ~2x the intended width AND under-counts
# the pad computed from it — which shoved the right-pinned columns off the line
# (32 of 256 rows on a Chinese-language ledger, up to 142 cols against a 116 target).
# Both row producers used to carry their own copy of this reasoning and only one of
# them had the fix; the single implementation here is what stops the drift.
#
# Fast path: a pure-ASCII string has width == ${#}, so it stays fork-free and renders
# byte-identical to the old builtin clip (this is a 4Hz hot path for the live dash).
# Only a string carrying non-ASCII pays one perl/wcwidth fork.
# shellcheck disable=SC2034  # clip_out/clip_w are caller-facing OUTPUT globals
# (read cross-file by the dash + history row producers), like reltime_out above.
clip_out=""; clip_w=0
fleet_clip_display() {
  local avail="${1:-0}" s="${2:-}" res
  case "$avail" in ''|*[!0-9]*) avail=0 ;; esac
  case "$s" in
    *[![:ascii:]]*) ;;
    *) [ "${#s}" -gt "$avail" ] && s="${s:0:$avail}"
       clip_out="$s"; clip_w=${#s}; return 0 ;;
  esac
  res=$(S="$s" A="$avail" perl -CO -MEncode -e '
    my $s = decode_utf8($ENV{S}); my $a = $ENV{A} + 0;
    my ($w, $out) = (0, "");
    for my $c (split //, $s) {
      my $o = ord $c;
      my $cw = ($o >= 0x1100 && (
          $o <= 0x115F || $o == 0x2329 || $o == 0x232A ||
          ($o >= 0x2E80 && $o <= 0x303E) || ($o >= 0x3041 && $o <= 0x33FF) ||
          ($o >= 0x3400 && $o <= 0x4DBF) || ($o >= 0x4E00 && $o <= 0x9FFF) ||
          ($o >= 0xA000 && $o <= 0xA4CF) || ($o >= 0xAC00 && $o <= 0xD7A3) ||
          ($o >= 0xF900 && $o <= 0xFAFF) || ($o >= 0xFE10 && $o <= 0xFE19) ||
          ($o >= 0xFE30 && $o <= 0xFE6F) || ($o >= 0xFF00 && $o <= 0xFF60) ||
          ($o >= 0xFFE0 && $o <= 0xFFE6) || ($o >= 0x1F000 && $o <= 0x1FAFF) ||
          ($o >= 0x20000 && $o <= 0x3FFFD))) ? 2 : 1;
      last if $w + $cw > $a;
      $w += $cw; $out .= $c;
    }
    print "$w\t$out";' 2>/dev/null)
  if [ -n "$res" ]; then
    clip_w=${res%%$'\t'*}; clip_out=${res#*$'\t'}
  else
    # no perl: clip to avail/2 glyphs (each <=2 cols => never exceeds avail) and
    # OVER-estimate the width so any pad computed from it only shrinks — degrades,
    # never overruns.
    clip_out="${s:0:$(( avail / 2 ))}"
    # shellcheck disable=SC2034  # output global, read by the row producers
    clip_w=$(( ${#clip_out} * 2 ))
  fi
}
