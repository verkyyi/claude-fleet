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
_FLEET_GLOBAL_ONLY="FLEET_GLOBAL_MAX_SESSIONS FLEET_ISSUE_BRIDGE_SECRET FLEET_ISSUE_TTL FLEET_GH_TTL FLEET_PR_REFRESH_INTERVAL FLEET_STUCK_WORKING_SECS FLEET_STATE_IDLE_SECS FLEET_ACCOUNTS FLEET_ACCOUNT_LIMIT_TTL FLEET_ACCOUNT_CEILING FLEET_ACCOUNT_WARN_PCT FLEET_ACCOUNT_QUOTA_TTL FLEET_ACCOUNT_QUOTA_STALE FLEET_ACCOUNT_QUOTA_BLIND_STREAK FLEET_ACCOUNT_QUOTA_VIA_BANNER_SECS FLEET_ACCOUNT_VERDICT_REFETCH FLEET_ACCOUNT_PICK FLEET_ACCOUNT_PICK_HYST FLEET_ACCOUNT_PHASE FLEET_ACCOUNT_PHASE_AUTO FLEET_COLLECT_DEADLINE FLEET_COLLECT_GIT_BUDGET FLEET_COLLECT_GIT_SLOW FLEET_COLLECT_TICK_BUDGET FLEET_COLLECT_QUOTAWATCH_BUDGET FLEET_COLLECT_SOCKETS_BUDGET FLEET_COLLECT_SESSMAP_BUDGET FLEET_COLLECT_ISSUES_BUDGET FLEET_COLLECT_CTX_BUDGET FLEET_COLLECT_USAGE_BUDGET FLEET_COLLECT_SCRAPE_BUDGET FLEET_COLLECT_BANNER_BUDGET FLEET_COLLECT_ESCALATE_BUDGET FLEET_COLLECT_SNAPSHOT_BUDGET FLEET_COLLECT_STALE FLEET_COLLECT_KICK FLEET_COLLECT_KICK_COOLDOWN FLEET_COLLECT_KICK_TRACE FLEET_DAEMON_STALE_MULT FLEET_DAEMON_STALE_FLOOR FLEET_DAEMON_KICK FLEET_DAEMON_KICK_COOLDOWN FLEET_DAEMON_KICK_COOLDOWN_MULT FLEET_DAEMON_KICK_COOLDOWN_FLOOR FLEET_DAEMON_KICK_TRACE FLEET_DAEMON_RELOAD_AFTER FLEET_DAEMON_RELOAD_COOLDOWN FLEET_DAEMON_DOMAIN_MIN FLEET_DAEMON_DOMAIN_KICK_WINDOW FLEET_DAEMON_IDLE_AFTER FLEET_POLL_MAX_BACKOFF FLEET_LAUNCHD_PROBE FLEET_LAUNCHD_PROBE_WINDOW FLEET_LAUNCHD_PROBE_INTERVAL FLEET_LAUNCHD_PROBE_TTL FLEET_MODEL_FALLBACK FLEET_MODEL_LIMIT_TTL FLEET_MODEL_CAP_PCT FLEET_CLOSE_ON_EXIT FLEET_NOTIFY_CMD FLEET_ESCALATE_AFTER FLEET_STATUS_CONTAINER FLEET_STATUS_CACHE_SECS FLEET_DISK_FLOOR_GB FLEET_DISK_WARN_GB FLEET_QUOTA_GATE FLEET_QUOTA_CEILING FLEET_QUOTA_ACCOUNT FLEET_QUOTA_BIN FLEET_RUNAWAY_CPU_PCT FLEET_RUNAWAY_CPU_SECS FLEET_RUNAWAY_CPU_ACTION FLEET_ORPHAN_CPU_PCT FLEET_ORPHAN_CPU_SECS FLEET_ORPHAN_CPU_ACTION FLEET_ORPHAN_EXTRA_RE FLEET_ORPHAN_LISTEN_SECS FLEET_ORPHAN_LISTEN_ACTION FLEET_ORPHAN_LISTEN_EVERY FLEET_LISTEN_EXEMPT_RE FLEET_LOAD_WARN_PER_CORE FLEET_FSEVENTSD_WARN_MB FLEET_DOCTOR_SPOTLIGHT FLEET_CODEX_VERSION_CHECK FLEET_DOCTOR_SLEEP FLEET_DOCTOR_SIRI FLEET_DOCTOR_ICLOUD FLEET_DOCTOR_NETWORK FLEET_DOCTOR_MCP FLEET_LOADGEN_MAX_PROCS FLEET_LOADGEN_MAX_SECS FLEET_LOADGEN_LOAD_PER_CORE FLEET_LOADGEN_CORE_PCT FLEET_USAGE_WARN_PCT FLEET_USAGE_CRIT_PCT FLEET_RATELIMIT_TTL FLEET_WEBHOOK_PORT FLEET_WEBHOOK_SECRET FLEET_REAP_KEPT_PROCS FLEET_REAP_KEPT_MINAGE FLEET_ROTATE_LEASE_TTL FLEET_HELPER_NO_MCP FLEET_SPAWN_GUARD_MS FLEET_INFLIGHT_TTL FLEET_INSTALL_SYNC FLEET_INSTALL_SYNC_TIMEOUT FLEET_INSTALL_FOLLOW_STUCK_SECS FLEET_ONBOARD FLEET_GUIDE_WAIT_SECS FLEET_GUIDE_COOLDOWN FLEET_COLLECT_GUIDE_BUDGET"

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
# THIS file's directory, resolved once per source and shared by the two blocks
# below. `${p%/*}` rather than `dirname` (issue #888): fleet-lib.sh is sourced by
# nearly every fleet script, so each `dirname` here was an exec on every dash
# repaint, every status render and every daemon tick.
# Inside the $(…) on purpose: `${BASH_SOURCE[0]}` is a "Bad substitution" under
# dash, and there it must kill only this subshell (→ empty, both blocks no-op),
# never the source — exactly as the old per-block `$(cd "$(dirname …)")` did.
_flib_here="$(_s="${BASH_SOURCE[0]:-$0}"; [ "${_s#*/}" = "$_s" ] && _s="./$_s"
  cd "${_s%/*}/" 2>/dev/null && pwd)" 2>/dev/null

if [ -z "${_FLEET_GLOBAL_CONF_SOURCED:-}" ] && [ -z "${FLEET_SKIP_GLOBAL_CONF:-}" ]; then
  _FLEET_GLOBAL_CONF_SOURCED=1
  _flib_dir="$_flib_here"
  if [ -n "$_flib_dir" ] && [ -f "$_flib_dir/../fleet.conf" ]; then
    . "$_flib_dir/../fleet.conf"
  fi
  # ONE settings file per login (issue #979): $FLEET_CONF_DIR/fleet.settings, read
  # AFTER the install's fleet.conf so it wins. The install file stays a dual-read
  # fallback, so a setup that was never merged (fleet-settings.sh merge) loads
  # byte for byte as before. Not a `*.conf` on purpose: fleet_each_conf reads every
  # legacy $FLEET_CONF_DIR/*.conf as a fleet, and `fleet.conf` there would be read
  # as a fleet named `fleet` — the new default session name.
  [ -f "$FLEET_CONF_DIR/fleet.settings" ] && . "$FLEET_CONF_DIR/fleet.settings"
  # eval so the space-separated NAME list re-tokenizes under zsh too (an unquoted
  # $var is NOT word-split there); export of a name the conf left unset is harmless.
  eval "export $_FLEET_GLOBAL_ONLY"
  unset _flib_dir
fi

# The language-preservation rules (issue #620) — FLEET_LANG_RULE_RESUME / _SEED /
# _NOTICE, the sentences every fleet-injected English text ends with so a Chinese
# (or any non-English) session is not dragged back to English by the fleet's own
# automation. Kept in their own POSIX file because bin/set-claude-state.sh is
# `sh`-wired and cannot source this bash-only lib; sourcing it here means every
# bash consumer that already sources fleet-lib.sh has the rules for free. Resolved
# relative to THIS file (BASH_SOURCE, $0 under zsh) like the global conf above; a
# bin/ without it is a clean no-op, and the ${VAR:-} defaults at every call site
# keep a missing file from breaking an injection.
if [ -z "${FLEET_LANG_RULE_SEED:-}" ]; then
  _flang_dir="$_flib_here"
  # shellcheck source=/dev/null
  [ -n "$_flang_dir" ] && [ -r "$_flang_dir/fleet-lang.sh" ] && . "$_flang_dir/fleet-lang.sh"
  unset _flang_dir
fi
unset _flib_here

# ----------------------------------------------------------------- layout (#181)
# ONE DIRECTORY PER FLEET. A fleet's DURABLE state is keyed by its tmux SESSION
# name and lives under $FLEET_CONF_DIR/fleets/<sess>/ (conf, restore.map,
# bridge/{seen,since}, watch/{keys,needs}, sweep.due). Its RUNTIME cache is keyed
# by repo SLUG and lives under $FLEET_C/fleets/<slug>/ (issues, prmap, labels, …).
# Machine-wide state (sessmap, account.*, git_*/ctx_* window caches,
# usage, collapsed) lives under $FLEET_C/global/. Truly global durable state
# (accounts/, diskguard/, restore/{autorestore.on,restore.log}) is unchanged.
#
# These helpers are the SINGLE source of the on-disk layout — no call site should
# hand-build a slug/session-suffixed path. For a transition window (land→migrate)
# the READ-side helpers accept BOTH the new layout and the legacy flat one, so a
# running fleet keeps working until bin/fleet-migrate-layout.sh moves its state.

# The login's ONE settings file (issue #979) — machine-wide keys and the fleet's
# settings together. Sourced at the top of this lib after the install fleet.conf.
fleet_settings_file() { printf '%s/fleet.settings' "$FLEET_CONF_DIR"; }

# Durable per-fleet state dir for <sess> (created on demand). WRITERS use this.
fleet_state_dir() {
  local d="$FLEET_CONF_DIR/fleets/${1:-_}"
  [ -d "$d" ] || mkdir -p "$d" 2>/dev/null   # test first: no exec once it exists (#888)
  printf '%s' "$d"
}

# --- «an EPIC batch is running on this login» (issue #953) -----------------------
# /fleet-epic-run stamps $FLEET_CONF_DIR/global/epic-running as the first command of
# every tick (bin/fleet-epic-heartbeat.sh); bin/fleet-install-sync.sh defers while
# it is fresh, so the live install is never fast-forwarded under a running batch —
# the loop's pane and its workers are idle between ticks, so the busy-window gate
# alone cannot see the batch. A LEASE, not a lock: fresh for its own `ttl:` (default
# 2700 s) counted from its `epoch:`, else from the file's mtime (a bare `touch` is a
# hand override). No gh, no tmux: the daemon that reads it has neither.
fleet_epic_running_file() { printf '%s/global/epic-running' "$FLEET_CONF_DIR"; }
# fleet_epic_running [<file>] — 0 fresh / 1 stale / 2 no mark; prints one line:
#   epic=<N> session=<sess> tick=<n> age=<s>s ttl=<s>s
fleet_epic_running() {
  local f="${1:-}" epoch ttl age epic sess tick
  [ -n "$f" ] || f=$(fleet_epic_running_file)
  [ -f "$f" ] || return 2
  epoch=$(sed -n 's/^epoch: //p' "$f" | head -1)
  case "$epoch" in ''|*[!0-9]*)
    # GNU stat FIRST: `stat -f %m` on GNU means "filesystem status" and exits 0
    # with non-mtime output, so it must not win (fleet_inflight_count, same trap).
    epoch=$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null || echo 0) ;;
  esac
  case "$epoch" in ''|*[!0-9]*) epoch=0 ;; esac
  ttl=$(sed -n 's/^ttl: //p' "$f" | head -1)
  case "$ttl" in ''|*[!0-9]*|0) ttl="${FLEET_EPIC_RUNNING_TTL:-2700}" ;; esac
  epic=$(sed -n 's/^epic: //p' "$f" | head -1)
  sess=$(sed -n 's/^session: //p' "$f" | head -1)
  tick=$(sed -n 's/^tick: //p' "$f" | head -1)
  age=$(( $(date +%s) - epoch )); [ "$age" -lt 0 ] && age=0
  printf 'epic=%s session=%s tick=%s age=%ss ttl=%ss' "${epic:--}" "${sess:--}" "${tick:--}" "$age" "$ttl"
  [ "$age" -lt "$ttl" ]
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
    sess=${conf##*/}; sess=${sess%.conf}          # basename … .conf, no fork (#888)
    # dedup only when the NEW-layout conf FILE exists — a fleets/<sess>/ dir that
    # holds just restore.map/bridge/watch (no conf yet) must NOT hide the legacy conf.
    [ -f "$FLEET_CONF_DIR/fleets/$sess/conf" ] && continue
    printf '%s\t%s\n' "$sess" "$conf"
  done
}

# The login's fleet (issue #979): one login runs ONE fleet, holding all its repos.
# Prints that fleet's session when exactly one fleet is configured (rc 0). None
# configured → nothing, rc 1 (a brand-new fleet is named "fleet"). Two or more — an
# estate from before the fold (fleet-repo.sh fold) — → nothing, rc 2: there is no
# single answer, and a caller must never guess one.
fleet_login_fleet() {
  local all rest
  all=$(fleet_each_conf); [ -n "$all" ] || return 1
  rest=${all#*
}
  [ "$rest" = "$all" ] || return 2
  printf '%s\n' "${all%%	*}"
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
  [ -d "$d" ] || mkdir -p "$d" 2>/dev/null   # test first: no exec once it exists (#888)
  printf '%s' "$d"
}

# Machine-wide (non-fleet) runtime cache dir — sessmap, account.*, git_*/ctx_*
# window caches, usage, ratelimit, collapsed, config scratch. Created on demand.
fleet_cache_global() {
  local d="$FLEET_C/global"
  [ -d "$d" ] || mkdir -p "$d" 2>/dev/null   # test first: no exec once it exists (#888)
  printf '%s' "$d"
}

# fleet_model_limited_until <ledger-file> <account> <lowercase-model> <now>
# → fleet_model_until (0 = not capped). Shared by the account CLI and the modelcap
# sweep so alias/full-id matching, account isolation and latest-reset selection
# cannot drift. The writer stores lowercase models and integer epoch seconds.
# Builtins only: modelcap calls this in its parent shell, once per distinct pair,
# instead of starting fleet-account.sh (and its libraries) for every window (#674).
# The caller supplies its clock and lowercases the query before calling.
fleet_model_limited_until() {
  local file="${1:-}" account="${2:-}" model="${3:-}" now="${4:-0}"
  local row rest label stored until
  fleet_model_until=0
  [ -n "$model" ] && [ -r "$file" ] || return 0
  while IFS= read -r row || [ -n "$row" ]; do
    # Split explicitly: tab is IFS whitespace, so `read a m u` would collapse an
    # empty field and mistake the banner for a timestamp. Ignore incomplete rows.
    case "$row" in *$'\t'*$'\t'*) ;; *) continue ;; esac
    label=${row%%$'\t'*}; rest=${row#*$'\t'}
    [ "$label" = "$account" ] || continue
    stored=${rest%%$'\t'*}; rest=${rest#*$'\t'}; until=${rest%%$'\t'*}
    case "$until" in ''|*[!0-9]*) continue ;; esac
    [ "$until" -gt "$now" ] 2>/dev/null && [ "$until" -gt "$fleet_model_until" ] 2>/dev/null || continue
    if [[ "$model" == *"$stored"* || "$stored" == *"$model"* ]]; then
      fleet_model_until="$until"
    fi
  done < "$file"
  return 0
}

# --- helper `claude -p` auth: ride the account POOL, not the ambient login (#497)
# The screen-classifier helper (bin/classify-sessions.sh — the dash summarizer that
# shared this wire retired in issue #535) shells out to `claude -p`. Left bare, that call authenticates from the machine's
# AMBIENT login — the macOS Keychain entry / ~/.claude credentials — which is a
# DIFFERENT credential from the one every worker runs on: bin/fleet-claude.sh exports
# CLAUDE_CODE_OAUTH_TOKEN for the active pool account before exec'ing claude, exactly
# as fleet-account.sh's header describes. So when the ambient login lapsed on
# 2026-08-25, all eleven workers kept running and only the dash's (then) summary
# column and the looping-detector died — the one credential nothing else in the fleet
# depends on was the one credential these helpers depended on.
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
# Forkless (issue #888) — the same four edits, in the same order, as the
#   sed -E 's#^git@[^:]*:##; s#^https?://[^/]*/##; s#\.git$##; s#/+$##'
# it replaces: pr-refresh normalizes every queued repo on every 15s tick. A value
# with a newline in it keeps the sed, whose edits are per LINE.
fleet_norm_repo() {
  local r="${1:-}"
  case "$r" in *"
"*) printf '%s' "$r" | sed -E 's#^git@[^:]*:##; s#^https?://[^/]*/##; s#\.git$##; s#/+$##'; return ;; esac
  case "$r" in git@*:*) r="${r#*:}" ;; esac
  case "$r" in http://*/*|https://*/*) r="${r#*://}"; r="${r#*/}" ;; esac
  r="${r%.git}"
  while :; do case "$r" in */) r="${r%/}" ;; *) break ;; esac; done
  printf '%s' "$r"
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
  local _ore="${_FLEET_GLOBAL_ONLY// /|}"   # space → `|`, no `tr` fork (#888)
  eval "$(grep -Ev "^[[:space:]]*(export[[:space:]]+)?(${_ore})=" "$conf")"
  # Window-aware (issue #788): inside a pane of THIS fleet whose window belongs to a
  # hosted repo, that repo's overlay goes on top — so every in-pane consumer (hooks,
  # commands/*.md, the launcher, the claim brief) sees its own repo's MAIN/base/model
  # without learning about repos. A fleet with no repos/ dir returns HERE, before any
  # tmux call: the degenerate case is byte-for-byte what it was. So does a caller
  # outside tmux (daemons), or one loading ANOTHER fleet's conf from inside a pane.
  [ -d "$FLEET_CONF_DIR/fleets/${1:-_}/repos" ] || return 0
  [ -n "${TMUX:-}" ] && [ -n "${TMUX_PANE:-}" ] || return 0
  local _wr
  [ "$(tmux display-message -p -t "$TMUX_PANE" '#{session_name}' 2>/dev/null)" = "$1" ] || return 0
  _wr=$(fleet_window_repo "$1" "$TMUX_PANE")
  [ -n "$_wr" ] && _fleet_repo_overlay "$1" "$_wr"
  return 0
}

# ---- repos a fleet hosts (issue #788) ---------------------------------------
# A fleet may host several repos, all equal (there is no main repo). The fleet
# conf's own FLEET_REPO/FLEET_MAIN/FLEET_BASE_BRANCH lines ARE one registry entry —
# no migration — and every further repo is an overlay at
#   $FLEET_CONF_DIR/fleets/<sess>/repos/<slug>.conf
# carrying FLEET_REPO / FLEET_MAIN / FLEET_BASE_BRANCH plus any per-repo override
# (FLEET_MODEL, FLEET_AGENT, FLEET_MCP_CONFIG, FLEET_DEPLOY_*). The fleet conf keeps
# the fleet-wide defaults an overlay may override. A window names its repo with the
# window option @repo=<owner/name>; `@norepo 1` marks a session that deliberately
# belongs to none. Every consumer resolves through the helpers below — never an
# ad-hoc `git remote` parse.

# Keys that describe the fleet conf's OWN repo, so they must not leak into another
# repo's view when its overlay is applied: identity, where it deploys, and whether
# it is the login's seed repo (FLEET_SEED, issue #1167 — a later repo is the user's).
_FLEET_REPO_SCOPED="FLEET_REPO FLEET_MAIN FLEET_BASE_BRANCH FLEET_DEPLOY_REF FLEET_DEPLOY_CHECK FLEET_REPO_SHORT FLEET_SEED"

# fleet_repo_conf_file <sess> <repo> → the overlay path for <repo> (may not exist).
fleet_repo_conf_file() {
  printf '%s/fleets/%s/repos/%s.conf' "$FLEET_CONF_DIR" "${1:-_}" "$(fleet_slug "$(fleet_norm_repo "${2:-}")")"
}

# fleet_repos <sess> → every repo the fleet hosts, owner/name, one per line: the
# fleet conf's FLEET_REPO first (when set), then each repos/*.conf, deduplicated.
# Reads confs in subshells, so the caller's env is untouched.
fleet_repos() {
  local sess="${1:-}" conf f r seen=' '
  [ -n "$sess" ] || return 0
  [ -n "${ZSH_VERSION:-}" ] && setopt local_options null_glob
  conf=$(fleet_conf_file "$sess")
  for f in "$conf" "$FLEET_CONF_DIR/fleets/$sess/repos"/*.conf; do
    [ -f "$f" ] || continue
    r=$( unset FLEET_REPO; . "$f" >/dev/null 2>&1; printf '%s' "${FLEET_REPO:-}" )
    r=$(fleet_norm_repo "$r")
    case "$r" in ?*/?*) ;; *) continue ;; esac
    case "$seen" in *" $r "*) continue ;; esac
    seen="$seen$r "
    printf '%s\n' "$r"
  done
  return 0
}

# fleet_has_repo_overlays <sess> → 0 iff fleets/<sess>/repos/ holds an overlay —
# the CHEAP "might this fleet host more than one repo?" gate for hot paths (the
# dash's 4Hz row producer, pr-refresh's per-window pass; issue #792). Builtins
# only, no fork. 1 = the degenerate one-repo fleet: callers keep today's
# per-session code path byte for byte.
fleet_has_repo_overlays() {
  local f
  [ -n "${ZSH_VERSION:-}" ] && setopt local_options null_glob
  for f in "$FLEET_CONF_DIR/fleets/${1:-_}/repos"/*.conf; do
    [ -f "$f" ] && return 0
  done
  return 1
}

# fleet_repo_hosted <sess> <repo> → 0 iff the fleet hosts <repo>.
fleet_repo_hosted() {
  local want all; want=$(fleet_norm_repo "${2:-}")
  [ -n "$want" ] || return 1
  # Captured, not piped into `grep -q`: grep quits on the first match, and under a
  # caller's `set -o pipefail` fleet_repos' SIGPIPE'd printf then fails the whole
  # pipeline — so the FIRST hosted repo read as not hosted (issue #793).
  all=$(fleet_repos "${1:-}")
  printf '%s\n' "$all" | grep -qxF "$want"
}

# fleet_repo_mains <sess> → each hosted repo's base checkout (FLEET_MAIN), one per
# line — what the base-readonly guard protects. Degenerate: the fleet conf's one.
fleet_repo_mains() {
  local r
  while IFS= read -r r; do
    [ -n "$r" ] || continue
    ( fleet_load_repo_conf "$1" "$r" >/dev/null 2>&1 && [ -n "${FLEET_MAIN:-}" ] \
        && printf '%s\n' "$FLEET_MAIN" )
  done <<EOF
$(fleet_repos "${1:-}")
EOF
  return 0
}

# fleet_window_repo <sess> <window-target> → the window's repo (owner/name), or
# NOTHING when unknown — the caller then skips the window, it never guesses:
#   1. @repo, when stamped;
#   2. @norepo=1 → deliberately none (empty);
#   3. derived ONCE from @worktree's git origin, and stamped as @repo;
#   4. the fleet's only repo, when it hosts exactly one (not stamped: it is a
#      default, not a fact about the window);
#   5. else unknown.
# Works inside a pane (bare tmux) and from a daemon (the fleet's own -L socket).
fleet_window_repo() {
  local sess="${1:-}" t="${2:-}" raw r norepo wt n
  [ -n "$t" ] || return 0
  # One read, '|'-separated: a printable sentinel (tmux <=3.4 vis-escapes control
  # bytes in formats), @worktree LAST so a path containing '|' stays intact.
  raw=$(_fleet_tmux "$sess" display-message -p -t "$t" '#{@repo}|#{@norepo}|#{@worktree}' 2>/dev/null)
  r=${raw%%|*}; raw=${raw#*|}; norepo=${raw%%|*}; wt=${raw#*|}
  [ -n "$r" ] && { printf '%s' "$r"; return 0; }
  [ "$norepo" = 1 ] && return 0
  if [ -n "$wt" ] && [ -d "$wt" ]; then
    r=$(fleet_norm_repo "$(git -C "$wt" remote get-url origin 2>/dev/null)")
    case "$r" in
      ?*/?*) _fleet_tmux "$sess" set-option -w -t "$t" @repo "$r" 2>/dev/null
             printf '%s' "$r"; return 0 ;;
    esac
  fi
  [ -n "$sess" ] || sess=$(_fleet_tmux '' display-message -p -t "$t" '#{session_name}' 2>/dev/null)
  r=$(fleet_repos "$sess")
  n=$(printf '%s' "$r" | grep -c .)
  [ "$n" = 1 ] && printf '%s' "$r"
  return 0
}

# _fleet_repo_overlay <sess> <repo> — apply <repo>'s overlay on top of the ALREADY
# loaded fleet conf, in the caller's shell. For the fleet conf's own repo the
# overlay is optional (it can only override); for any other repo it is required,
# and the conf repo's scoped keys are dropped first so they cannot leak across.
# Returns 1 (env untouched) when <repo> is not hosted.
_fleet_repo_overlay() {
  local want f _ore
  want=$(fleet_norm_repo "${2:-}"); [ -n "$want" ] || return 1
  f=$(fleet_repo_conf_file "$1" "$want")
  if [ "$(fleet_norm_repo "${FLEET_REPO:-}")" != "$want" ]; then
    [ -f "$f" ] || return 1
    eval "unset $_FLEET_REPO_SCOPED"
  fi
  [ -f "$f" ] || return 0
  _ore="${_FLEET_GLOBAL_ONLY// /|}"   # no `tr` fork: pr-refresh loads per repo (#888/#805)
  eval "$(grep -Ev "^[[:space:]]*(export[[:space:]]+)?(${_ore})=" "$f")"
  return 0
}

# fleet_load_repo_conf <sess> <repo> — like fleet_load_conf, but for a NAMED repo
# rather than the caller's window: the fleet conf, then <repo>'s overlay. Returns 1
# when the fleet does not host <repo> (the fleet conf is still loaded).
fleet_load_repo_conf() {
  local conf _ore; conf=$(fleet_conf_file "${1:-}")
  # A multi-repo fleet first puts the per-repo keys back to what they were before
  # ANY conf was loaded (issue #978): else, in a shell that already applied repo B's
  # overlay (a pane of B spawning for A), a key A's overlay leaves unset would keep
  # B's value instead of falling back to the fleet's. One-repo fleet: untouched.
  fleet_has_repo_overlays "${1:-}" && _fleet_repo_keys_reset
  if [ -f "$conf" ]; then
    _ore="${_FLEET_GLOBAL_ONLY// /|}"   # no `tr` fork: pr-refresh loads per repo (#888/#805)
    eval "$(grep -Ev "^[[:space:]]*(export[[:space:]]+)?(${_ore})=" "$conf")"
  fi
  _fleet_repo_overlay "${1:-}" "${2:-}"
}

# ---- per-repo settings (issue #978) -----------------------------------------
# Every key a repo overlay sets wins for THAT repo, falling back to the fleet
# conf's value when the overlay leaves it unset (then the global fleet.conf's, then
# the reader's own default). The keys readers DOCUMENTEDLY resolve per repo — keep
# in step with the "per-repo settings" block in fleet.conf.example:
#   identity/deploy (_FLEET_REPO_SCOPED)  FLEET_REPO FLEET_MAIN FLEET_BASE_BRANCH
#                                         FLEET_DEPLOY_REF FLEET_DEPLOY_CHECK FLEET_REPO_SHORT
#   launch                                FLEET_MODEL FLEET_AGENT FLEET_MCP_CONFIG
#   setup + switches (#978)   (+ autofill #799, webhook #800)  $_FLEET_REPO_OVERRIDABLE
# An in-pane reader gets its window's repo for free (fleet_load_conf is window-
# aware); a reader OUTSIDE the window (daemon, spawner, sleep/failover) resolves the
# repo first — fleet_window_repo / fleet_worktree_repo — then asks
# fleet_repo_conf_get, or loads fleet_load_repo_conf itself. A fleet with no
# repos/ overlay answers with the fleet conf's value, byte for byte.
_FLEET_REPO_OVERRIDABLE="FLEET_WORKTREE_SETUP FLEET_WORKTREE_SETUP_TIMEOUT FLEET_BASE_DEPS FLEET_SLEEP_MCP_RESTARTABLE FLEET_SCRATCH_POOL FLEET_ISSUE_BRIDGE FLEET_CLEANUP FLEET_AUTOFILL FLEET_WEBHOOK"

# The per-repo keys as they stood when this lib was sourced (global fleet.conf +
# the caller's environment): the baseline _fleet_repo_keys_reset restores. A key set
# then is re-ASSIGNED (keeps its export flag); one unset then is unset again.
_fleet_repo_keys_snapshot() {
  local _k
  for _k in $(printf '%s' "$_FLEET_REPO_OVERRIDABLE"); do
    if eval "[ -n \"\${$_k+x}\" ]"; then
      eval "printf '%s=%q\n' \"\$_k\" \"\${$_k}\""
    else
      printf 'unset %s\n' "$_k"
    fi
  done
}
_fleet_repo_keys_base=$(_fleet_repo_keys_snapshot)
_fleet_repo_keys_reset() { eval "$_fleet_repo_keys_base"; }

# fleet_repo_conf_get <sess> <repo> <KEY> → KEY's value as a reader loading <repo>'s
# conf sees it (overlay, else fleet conf, else inherited); empty when unset — the
# caller applies its own default. rc 1 (nothing printed) when the fleet does not
# host <repo>; rc 2 on a malformed KEY. Subshelled: the caller's env is untouched.
fleet_repo_conf_get() {
  case "${3:-}" in ''|[!A-Z_]*|*[!A-Za-z0-9_]*) return 2 ;; esac
  ( fleet_load_repo_conf "${1:-}" "${2:-}" >/dev/null 2>&1 || exit 1
    eval "printf '%s' \"\${$3:-}\"" )
}

# ---- the seed repo (issue #1167) --------------------------------------------
# A new login's fleet comes up on claude-fleet itself (`fleet-up.sh --seed`) only so
# the fleet works from its first minute; the login has no write access there, and
# the operator's own fleet watches the same backlog. So the seed repo only LOOKS:
# FLEET_SEED=1 in the fleet conf marks the conf's OWN repo (it is repo-scoped above,
# so a repo added later never inherits it), and the dispatcher + issue-bridge skip
# it whatever FLEET_AUTOFILL / FLEET_ISSUE_BRIDGE say. The one marker every consumer
# reads — the onboarding wizard included — through fleet_repo_is_seed.

# fleet_repo_is_seed <sess> <repo> → 0 iff <repo> is <sess>'s seed repo.
fleet_repo_is_seed() {
  [ "$(fleet_repo_conf_get "${1:-}" "${2:-}" FLEET_SEED)" = 1 ]
}

# fleet_conf_set <conf> <KEY> <value> — set one assignment in a conf file: every
# existing KEY= line (optionally `export`ed) is dropped and ONE `KEY="value"` line
# appended; everything else is kept verbatim. Atomic (temp + mv). rc 2 on a bad KEY.
fleet_conf_set() {
  local conf="${1:-}" key="${2:-}" val="${3:-}" tmp
  case "$key" in ''|[!A-Z_]*|*[!A-Za-z0-9_]*) return 2 ;; esac
  [ -n "$conf" ] || return 2
  tmp="$conf.tmp.$$"
  {
    [ -f "$conf" ] && grep -Ev "^[[:space:]]*(export[[:space:]]+)?${key}[[:space:]]*=" "$conf"
    printf '%s="%s"\n' "$key" "$val"
  } > "$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$conf" || { rm -f "$tmp"; return 1; }
}

# fleet_conf_unset <conf> <KEY>... — drop every assignment of each KEY (optionally
# `export`ed) from a conf file; everything else is kept verbatim. Atomic (temp +
# mv). A KEY that is not there is a no-op; rc 2 on a bad KEY.
fleet_conf_unset() {
  local conf="${1:-}" key re='' tmp
  [ -n "$conf" ] || return 2
  shift
  for key in "$@"; do
    case "$key" in ''|[!A-Z_]*|*[!A-Za-z0-9_]*) return 2 ;; esac
    re="$re${re:+|}$key"
  done
  [ -n "$re" ] && [ -f "$conf" ] || return 0
  tmp="$conf.tmp.$$"
  # `|| true`: grep exits 1 when NOTHING is left, which is a legal (empty) conf.
  { grep -Ev "^[[:space:]]*(export[[:space:]]+)?(${re})[[:space:]]*=" "$conf" || true; } > "$tmp" \
    || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$conf" || { rm -f "$tmp"; return 1; }
}

# fleet_repo_conf_file_for <sess> <repo> → where <repo>'s own value of a key lives:
# its overlay when one exists, else the fleet conf (the conf repo without an
# overlay). What a "set KEY=… in <file>" hint should name.
fleet_repo_conf_file_for() {
  local f; f=$(fleet_repo_conf_file "${1:-}" "${2:-}")
  [ -f "$f" ] || f=$(fleet_conf_file "${1:-}")
  printf '%s' "$f"
}

# ---- reapers stay inside their own repo (issue #791) ------------------------
# Every automatic reaper (cleanup daemon, idle close, SessionEnd, the worktree
# janitor) and every mover that decides "is this worktree ours" resolves its repo
# from the WINDOW it acts on, never from the fleet conf alone, and joins windows on
# (repo, issue) — never a bare issue number. A window whose repo is unknown or
# deliberately none (@norepo) is never reaped automatically. A fleet with no
# overlay (fleet_has_repo_overlays) takes the historic single-repo path in every
# caller, byte for byte.

# fleet_load_window_conf <sess> <window> — for a caller acting ON <window> (a
# reaper, not the window's own pane): the fleet conf with THAT window's repo
# overlay on top. Degenerate (no overlay): exactly fleet_load_conf. Otherwise
# returns 1 when the window's repo is unknown, none (@norepo) or no longer hosted —
# with FLEET_REPO/FLEET_MAIN/FLEET_BASE_BRANCH UNSET, so a caller that ignores the
# status still cannot reach any repo's worktrees.
fleet_load_window_conf() {
  local sess="${1:-}" r
  fleet_load_conf "$sess"
  fleet_has_repo_overlays "$sess" || return 0
  r=$(fleet_window_repo "$sess" "${2:-}")
  if [ -z "$r" ] || ! fleet_load_repo_conf "$sess" "$r"; then
    eval "unset $_FLEET_REPO_SCOPED"
    return 1
  fi
  return 0
}

# fleet_resolved_repo <sess> — the repo a reaper acts on, read AFTER a
# fleet_load_*conf. A one-repo fleet keeps the historic rule (the collector's
# sessmap wins over FLEET_REPO); a multi-repo fleet must not: the sessmap holds ONE
# repo per session and would drag every window back to the conf's own repo.
fleet_resolved_repo() {
  local r=''
  fleet_has_repo_overlays "${1:-}" || r=$(fleet_repo_cached "${1:-}")
  printf '%s' "${r:-${FLEET_REPO:-}}"
}

# fleet_issue_windows <sess> <repo> <issue> → the window ids bound to (repo,
# issue), one per line. In a multi-repo fleet a window matches only when its own
# repo (fleet_window_repo) IS <repo> — an unknown/@norepo window never matches, so
# repo B's #12 is invisible to repo A's cleanup. Degenerate: every window whose
# @issue is <issue>, as before.
fleet_issue_windows() {
  local sess="${1:-}" want i w wi multi=0
  want=$(fleet_norm_repo "${2:-}"); i="${3:-}"
  [ -n "$i" ] || return 0
  fleet_has_repo_overlays "$sess" && multi=1
  _fleet_tmux "$sess" list-windows -t "$sess" -F '#{window_id} #{@issue}' 2>/dev/null |
  while read -r w wi; do
    [ "$wi" = "$i" ] || continue
    if [ "$multi" = 1 ]; then
      [ -n "$want" ] || continue
      [ "$(fleet_norm_repo "$(fleet_window_repo "$sess" "$w")")" = "$want" ] || continue
    fi
    printf '%s\n' "$w"
  done
  return 0
}

# fleet_worktree_repo <sess> <worktree> → "<repo><TAB><main>" of the hosted repo
# whose base checkout registers <worktree> as a linked worktree (physical paths
# compared); nothing when no hosted repo does. "Registered to this fleet" means
# registered to ANY repo it hosts.
fleet_worktree_repo() {
  local sess="${1:-}" wt r m
  wt=$(cd "${2:-/nonexistent}" 2>/dev/null && pwd -P) || return 0
  while IFS= read -r r; do
    [ -n "$r" ] || continue
    m=$( fleet_load_repo_conf "$sess" "$r" >/dev/null 2>&1 || exit 0
         cd "${FLEET_MAIN:-/nonexistent}" 2>/dev/null && pwd -P )
    [ -n "$m" ] && [ "$m" != "$wt" ] || continue
    git -C "$m" worktree list --porcelain 2>/dev/null | grep -Fxq "worktree $wt" || continue
    printf '%s\t%s' "$r" "$m"; return 0
  done <<EOF
$(fleet_repos "$sess")
EOF
  return 0
}

# There is no CURRENT repo (issue #1034): the grouped `all` list is the only view,
# and a repo heading (or the highlighted row) picks where a new session goes. The
# footer picker that used to narrow it (#793) and the `fleet_current_repo` that
# answered `all` for its readers (#1038) are both gone; the picker's stale state
# file on disk is read by nothing and deleted by fleet-up.sh.

# fleet_selection_repo <sess> <row-id> → where a session started FROM the highlighted
# row goes (issues #1009/#997): only in a 2+ repo fleet. <row-id> is a
# window (`@12` — its repo via fleet_window_repo, never a guess; `none` for a
# deliberate `@norepo 1` window) or a repo heading, `hdr:<owner/name>` (a hosted
# repo) or `hdr:none` (the `no repo` group). A trailing `:<anything>` after a window
# id is ignored, so a caller may always send `<id>:<heading-repo>` (the hub's id is
# fzf field 2 — field 1 is the `sess:idx` jump target, issue #1010). Prints the repo,
# `none` (start in $HOME, --no-repo), or NOTHING — a one-repo fleet, an unknown
# window, the `?` heading, a landed row — and the caller keeps today's behavior.
# The one resolver the sidebar and hub share.
fleet_selection_repo() {
  local sess="${1:-}" id="${2:-}" r
  [ -n "$id" ] || return 0
  fleet_multirepo "$sess" || return 0
  case "$id" in
    hdr:none) r=none ;;
    hdr:?*/?*) r=$(fleet_norm_repo "${id#hdr:}"); fleet_repo_hosted "$sess" "$r" || r='' ;;
    @[0-9]*)
      id=${id%%:*}
      r=$(fleet_window_repo "$sess" "$id")
      if [ -n "$r" ]; then fleet_repo_hosted "$sess" "$r" || r=''
      elif [ "$(_fleet_tmux "$sess" display-message -p -t "$id" '#{@norepo}' 2>/dev/null)" = 1 ]; then r=none; fi ;;
    *) r='' ;;
  esac
  [ -n "$r" ] && printf '%s\n' "$r"
  return 0
}

# ---- a repo's names on screen (issue #793) ----------------------------------
# fleet_repo_short <owner/name> [<override>] → the short tag a repo wears on the
# dash badge (window names no longer carry it — issue #1023): <override> when given
# (FLEET_REPO_SHORT in the repo's conf/overlay), else the initials of the name's
# -/_/. words when it has 2+ (claude-fleet → cf), else its first two characters
# (tokenledger → to). Lowercase ASCII; never empty for a real name.
fleet_repo_short() {
  if [ -n "${2:-}" ]; then printf '%s' "$2"; return 0; fi
  printf '%s\n' "${1##*/}" | awk '{
    s = tolower($0); gsub(/[^a-z0-9]+/, " ", s); k = split(s, w, " "); o = ""
    if (k >= 2) { for (i = 1; i <= k && length(o) < 3; i++) o = o substr(w[i], 1, 1) }
    else o = substr(w[1], 1, 2)
    printf "%s", o }'
}

# fleet_repo_shorts <sess> → "<repo>\t<slug>\t<short>" per hosted repo, in
# fleet_repos order. A short two repos share falls back to each one's full name,
# so a badge never names the wrong repo. Reads each conf in a subshell.
fleet_repo_shorts() {
  local sess="${1:-}" r f o rows='' dup
  while IFS= read -r r; do
    [ -n "$r" ] || continue
    f=$(fleet_repo_conf_file "$sess" "$r")
    [ -f "$f" ] || f=$(fleet_conf_file "$sess")
    o=$( unset FLEET_REPO_SHORT; . "$f" >/dev/null 2>&1; printf '%s' "${FLEET_REPO_SHORT:-}" )
    rows="$rows$r"$'\t'"$(fleet_slug "$r")"$'\t'"$(fleet_repo_short "$r" "$o")"$'\n'
  done <<EOF
$(fleet_repos "$sess")
EOF
  dup=$(printf '%s' "$rows" | awk -F'\t' 'NF { n[$3]++ } END { for (s in n) if (n[s] > 1) print s }')
  printf '%s' "$rows" | awk -F'\t' -v dup="$dup" '
    BEGIN { m = split(dup, d, "\n"); for (i = 1; i <= m; i++) if (d[i] != "") x[d[i]] = 1 }
    NF { s = $3; if (s in x) { s = $1; sub(/.*\//, "", s) } print $1 "\t" $2 "\t" s }'
}

# fleet_repo_short_of <sess> <repo> → that hosted repo's short tag ('' if not hosted).
fleet_repo_short_of() {
  local want; want=$(fleet_norm_repo "${2:-}")
  fleet_repo_shorts "${1:-}" | awk -F'\t' -v r="$want" '$1 == r && !f { print $3; f = 1 }'
}

# fleet_repo_name <sess> <repo> → how the dash NAMES a hosted repo (issue #995):
# its bare name (`tokenledger`), or `owner/name` when another hosted repo shares
# that bare name — for those repos only, so a name never points at the wrong
# repo. The group headings wear it; '' when <repo> is not hosted.
# fleet_repo_names <sess> → "<repo>\t<name>" per hosted repo, in fleet_repos order.
fleet_repo_names() {
  local list all='' r
  list=$(fleet_repos "${1:-}")
  while IFS= read -r r; do [ -n "$r" ] && all+=$'\t'"${r##*/}"$'\t'; done <<EOF
$list
EOF
  while IFS= read -r r; do
    [ -n "$r" ] || continue
    _fleet_repo_name_v "$all" "$r"; printf '%s\t%s\n' "$r" "$_frn"
  done <<EOF
$list
EOF
}
fleet_repo_name() {
  local want; want=$(fleet_norm_repo "${2:-}")
  fleet_repo_names "${1:-}" | awk -F'\t' -v r="$want" '$1 == r && !f { print $2; f = 1 }'
}
# _fleet_repo_name_v <all> <repo> → $_frn, fork-free: <all> is every hosted
# repo's bare name wrapped as TAB<name>TAB; 2+ copies of <repo>'s = a collision.
_fleet_repo_name_v() {
  local p=$'\t'"${2##*/}"$'\t' t
  t=${1//"$p"/}
  if [ $(( (${#1} - ${#t}) / ${#p} )) -gt 1 ]; then _frn=$2; else _frn=${2##*/}; fi
}

# fleet_dash_repo_frame <sess> — once per dash frame, for the row renderers (the
# dash, the sidebar, the fold toggle). Sets globals, no output:
#   RMANY     1 iff the fleet hosts 2+ repos; 0 = a one-repo fleet, and then the
#             others stay empty and every renderer takes today's path;
#   RSHORTMAP $'\n'<slug>\t<short>$'\n'… — the badge per repo;
#   RGRPMAP   $'\n'<slug>\t<i>$'\n'… — the repo's group under `all` (issue #974):
#             its 0-based place in fleet_repos order, so the heading rows sort
#             the way the repos are registered;
#   RHEADS    <i>\t<name>\t<owner/name>$'\n'… — each group heading names its repo
#             by fleet_repo_name (bare, owner/name on a collision; issue #995);
#   RNREPO    how many repos are hosted (the unknown/no-repo groups sort after).
# A fleet with no repos/ dir costs nothing: the directory test returns first.
# shellcheck disable=SC2034  # RMANY/RSHORTMAP/RGRPMAP/RHEADS/RNREPO are caller-facing OUTPUT globals
fleet_dash_repo_frame() {
  local sess="${1:-}" shorts r s sh all=''
  RMANY=0; RSHORTMAP=$'\n'; RGRPMAP=$'\n'; RHEADS=''; RNREPO=0
  [ -d "$FLEET_CONF_DIR/fleets/${sess:-_}/repos" ] || return 0
  shorts=$(fleet_repo_shorts "$sess")
  case "$shorts" in *$'\n'*) ;; *) return 0 ;; esac          # one repo: nothing to filter
  RMANY=1
  while IFS=$'\t' read -r r s sh; do [ -n "$r" ] && all+=$'\t'"${r##*/}"$'\t'; done <<EOF
$shorts
EOF
  while IFS=$'\t' read -r r s sh; do
    [ -n "$r" ] || continue
    RSHORTMAP+="$s"$'\t'"$sh"$'\n'
    RGRPMAP+="$s"$'\t'"$RNREPO"$'\n'
    _fleet_repo_name_v "$all" "$r"
    RHEADS+="$RNREPO"$'\t'"$_frn"$'\t'"$r"$'\n'
    RNREPO=$((RNREPO + 1))
  done <<EOF
$shorts
EOF
}

# ---- the backlog for any repo (issue #794) ----------------------------------
# The backlog (tmux-issues.sh + its rows producer, preview and row actions) reads
# every hosted repo's issues in a 2+ repo fleet, each row carrying its repo. A
# one-repo fleet never enters any helper's multi branch: its backlog keeps the
# per-session cache and repo chain it always had.

# fleet_backlog_repos <sess> → the repos the backlog lists, one per line: NOTHING in
# a one-repo fleet (the caller keeps today's path), every hosted repo (fleet_repos
# order) otherwise.
fleet_backlog_repos() {
  fleet_multirepo "${1:-}" || return 0
  fleet_repos "$1"
}

# fleet_backlog_cache <base> <sess> <repo> → the runtime cache file <base>
# (issues / labels / parents) the backlog reads for <repo>: that repo's own
# fleets/<slug>/ dir in a 2+ repo fleet, else fleet_cache's per-session file.
fleet_backlog_cache() {
  if [ -n "${3:-}" ] && fleet_multirepo "${2:-}"; then
    printf '%s/%s' "$(fleet_cache_dir "$(fleet_slug "$(fleet_norm_repo "$3")")")" "${1:-}"
  else
    fleet_cache "${1:-}" "${2:-}"
  fi
}

# fleet_backlog_repo <sess> [<row-repo>] → the repo a backlog action targets, or
# NOTHING (the caller refuses) — never a guess:
#   2+ repos: the row's repo (must be hosted), else $CF_REPO (carried through a
#             popup), else nothing (a new issue asks — fleet-repo-ask.sh);
#   one repo: the historic chain — $CF_REPO, else the sessmap's, else FLEET_REPO.
fleet_backlog_repo() {
  local sess="${1:-}" r c
  r=$(fleet_norm_repo "${2:-}")
  if fleet_multirepo "$sess"; then
    if [ -n "$r" ]; then fleet_repo_hosted "$sess" "$r" && printf '%s' "$r"; return 0; fi
    if [ -n "${CF_REPO:-}" ]; then
      r=$(fleet_norm_repo "$CF_REPO"); fleet_repo_hosted "$sess" "$r" && printf '%s' "$r"; return 0
    fi
    return 0
  fi
  r="${FLEET_REPO:-}"
  [ -n "$sess" ] && c=$(fleet_repo_cached "$sess") && [ -n "$c" ] && r=$c
  [ -n "${CF_REPO:-}" ] && r=$CF_REPO
  printf '%s' "$r"
}

# ---- (repo, issue) identity (issue #790) -------------------------------------
# Two repos in one fleet can both have an issue #12, so nothing that finds a
# session by its issue number may join on the bare number there. The join key is
# (repo, N), spelled `<owner/name>#<N>`. A ONE-repo fleet keeps the bare N it has
# always used — the degenerate case, byte-for-byte — so every existing cache,
# snapshot and ledger row still matches. (The dash's grouping keys are a
# different spelling of the same idea, `<slug>:issue-<N>`, because they must equal
# what a spawn stamps into @origin — see fleet_okey_prefix.)

# fleet_multirepo <sess> → 0 iff the fleet hosts 2+ repos. A fleet with no repos/
# dir answers from one [ -d ] — no fork, no tmux — so a 4Hz path may ask it.
fleet_multirepo() {
  [ -d "$FLEET_CONF_DIR/fleets/${1:-_}/repos" ] || return 1
  [ "$(fleet_repos "$1" | grep -c .)" -ge 2 ]
}

# fleet_target_repo <sess> [<repo>] → the ONE repo a repo-wide command (the EPIC
# trio, fleet-epic-preflight.sh, fleet-evidence.sh; issue #803) acts on:
#   1. <repo>, when given — it must be hosted (exit 1 otherwise);
#   2. a one-repo fleet: its repo (FLEET_REPO, else the collector's cached one);
#   3. the caller pane's own window repo (a worker, a scratch bound to a repo);
#   4. else exit 4 — AMBIGUOUS: the caller ASKS (fleet_repos lists the choices),
#      never guesses. Exit 1 = <repo> not hosted / nothing resolvable.
# Degenerate (no repos/ overlay): 1 → the conf's own repo, unvalidated, as before.
fleet_target_repo() {
  local sess="${1:-}" want r
  want=$(fleet_norm_repo "${2:-}")
  if ! fleet_multirepo "$sess"; then
    r=$( fleet_load_conf "$sess" >/dev/null 2>&1; printf '%s' "${FLEET_REPO:-}" )
    [ -n "$r" ] || r=$(fleet_repo_cached "$sess" 2>/dev/null)
    r=$(fleet_norm_repo "$r")
    printf '%s\n' "${want:-$r}"
    [ -n "${want:-$r}" ]; return
  fi
  if [ -n "$want" ]; then
    fleet_repo_hosted "$sess" "$want" || return 1
    printf '%s\n' "$want"; return 0
  fi
  if [ -n "${TMUX:-}" ] && [ -n "${TMUX_PANE:-}" ] \
     && [ "$(tmux display-message -p -t "$TMUX_PANE" '#{session_name}' 2>/dev/null)" = "$sess" ]; then
    r=$(fleet_norm_repo "$(fleet_window_repo "$sess" "$TMUX_PANE")")
    if [ -n "$r" ] && fleet_repo_hosted "$sess" "$r"; then printf '%s\n' "$r"; return 0; fi
  fi
  return 4
}

# fleet_issue_key <sess> <repo> <N> → the join key for issue N of <repo>.
fleet_issue_key() {
  if fleet_multirepo "${1:-}"; then printf '%s#%s' "$(fleet_norm_repo "${2:-}")" "${3:-}"
  else printf '%s' "${3:-}"; fi
}

# fleet_window_key <sess> <window-target> → the window's join key, the same
# spelling fleet_issue_key gives its (repo, N): nothing for a window with no
# @issue; `#<N>` for a multi-repo window whose repo is unknown (see below).
fleet_window_key() {
  local n
  n=$(_fleet_tmux "${1:-}" display-message -p -t "${2:-}" '#{@issue}' 2>/dev/null)
  [ -n "$n" ] || return 0
  if fleet_multirepo "${1:-}"; then printf '%s#%s' "$(fleet_window_repo "$1" "$2")" "$n"
  else printf '%s' "$n"; fi
}

# fleet_repo_for_slug <sess> <repo|slug|name> → the hosted owner/name it names,
# or nothing (1) when it names none or more than one. Lets an operator-typed
# `<slug>#12` / `<slug>:issue-12` resolve without spelling the owner.
fleet_repo_for_slug() {
  local want="${2:-}" r hit='' n=0
  [ -n "$want" ] || return 1
  while IFS= read -r r; do
    [ -n "$r" ] || continue
    case "$want" in "$r"|"$(fleet_slug "$r")"|"${r#*/}") hit=$r; n=$((n+1)) ;; esac
  done <<EOF
$(fleet_repos "${1:-}")
EOF
  [ "$n" = 1 ] || return 1
  printf '%s' "$hit"
}

# fleet_okey_prefix <sess> <repo> → `<slug>:` in a multi-repo fleet, else nothing:
# what goes in front of `issue-<N>` / `scratch-<N>` in a dash grouping key, so a
# key built here equals the @origin a multi-repo spawn stamps (issue #789).
fleet_okey_prefix() {
  fleet_multirepo "${1:-}" || return 0
  printf '%s:' "$(fleet_slug "$(fleet_norm_repo "${2:-}")")"
}

# fleet_bound_windows <sess> → one `<key>\t<window_id>\t<window_name>` line per
# window of the fleet bound to an issue — by @issue, else by a bare `issue-<N>`
# window NAME (a window whose binding was cleared is still that issue's session).
# <key> is fleet_issue_key's spelling; a multi-repo window whose repo is unknown
# gets `#<N>` — equal to no real key, so a join never picks it by guesswork (a
# caller that must be conservative, e.g. spawn dedup, matches `#<N>` on purpose).
# (fleet_issue_windows, #791, answers the narrower question: the ids bound to ONE
# given (repo, issue).)
fleet_bound_windows() {
  local sess="${1:-}" multi=0 wid iss name r n
  fleet_multirepo "$sess" && multi=1
  while IFS='|' read -r wid iss name; do
    [ -n "$wid" ] || continue
    n=$iss
    if [ -z "$n" ]; then
      case "$name" in issue-*) n=${name#issue-} ;; *) continue ;; esac
    fi
    case "$n" in ''|*[!0-9]*) continue ;; esac
    if [ "$multi" = 1 ]; then
      r=$(fleet_window_repo "$sess" "$wid")
      printf '%s#%s\t%s\t%s\n' "$r" "$n" "$wid" "$name"
    else
      printf '%s\t%s\t%s\n' "$n" "$wid" "$name"
    fi
  done <<EOF
$(_fleet_tmux "$sess" list-windows -t "$sess" -F '#{window_id}|#{@issue}|#{window_name}' 2>/dev/null)
EOF
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
#   1. FLEET_WORKER_PROMPT_FILE — the RETIRED twin of the @path form below (issue
#      #1101), still read so an old conf is unchanged.
#   2. FLEET_WORKER_PROMPT — an inline body string, or "@<path>": a file whose
#      contents are the body (for a long/multi-line template the single-line config
#      modal can't hold). A path's leading ~/ is expanded; set-but-unreadable ⇒
#      warn on stderr and fall through to the default.
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
  case "$f:${FLEET_WORKER_PROMPT:-}" in :@?*) f="${FLEET_WORKER_PROMPT#@}" ;; esac
  if [ -n "$f" ]; then
    # A leading ~/ from the conf/modal is a LITERAL tilde (the shell never
    # expanded it in a quoted assignment), so match it literally and expand by
    # hand — the "~/" here is a case PATTERN, not an attempted expansion.
    # shellcheck disable=SC2088
    case "$f" in "~/"*) f="$HOME/${f#\~/}" ;; esac
    if [ -r "$f" ]; then
      body=$(cat "$f")
    else
      printf 'fleet: worker prompt file not readable (%s) — using inline/default\n' "$f" >&2
    fi
  fi
  case "${FLEET_WORKER_PROMPT:-}" in @?*) : ;; *) [ -n "$body" ] || body="${FLEET_WORKER_PROMPT:-}" ;; esac
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

# ---- base branch: the repo's TRUNK, never "the branch you happened to be on" --
# (issue #603) FLEET_BASE_BRANCH is what every worker branches from and opens its
# PR against, so getting it wrong fails in the worst possible way: NOTHING looks
# broken. Workers claim, branch, push, CI goes green, PRs merge — onto a branch
# nobody ships from. The trunk just silently never moves.
#   2026-09-12: fleet-ccquota was written with FLEET_BASE_BRANCH="dashboard-redesign"
#   while the ccquota repo's default branch was `main`. A full round of correct work
#   landed five commits behind main, where no user would ever see it. ccquota's own
#   PR #11 was the same mistake in a push trigger. Pointing at "the branch that
#   happened to be checked out" instead of the repo's real trunk has now bitten twice.
#
# So: the ONE authoritative answer is the repo's GitHub default branch, and every
# other answer is a GUESS that must announce itself. Resolution order:
#   flag         an explicit --base — the operator's deliberate override
#   default      `gh repo view --json defaultBranchRef` — authoritative
#   origin-head  refs/remotes/origin/HEAD — the default branch as of the last clone
#                / `git remote set-head`; right unless it has moved since
#   checkout     the branch $dir is standing on — a real guess, and precisely the
#                one that bit us, so it sits LAST-but-one, never first
#   fallback     'main' — nothing else was knowable
#
# The gh lookup runs even when --base was passed: knowing the authoritative answer
# is what lets the caller SAY that an explicit base disagrees with it (the silent
# disagreement is the whole bug). Costs one API call on a path taken once per fleet.
#
# Args: $1=owner/repo  $2=checkout dir  $3=explicit --base ('' when not given)
# Prints ONE tab-separated line: <branch> <TAB> <source> <TAB> <authoritative-default>
# where <source> is one of the five tags above and <authoritative-default> is '' when
# gh could not answer (missing / unauthed / offline). Branch names cannot contain a
# tab, so the caller can split on it:
#   IFS=$'\t' read -r base src default < <(fleet_resolve_base_branch "$repo" "$dir" "$flag")
# This function NEVER warns or prompts — that is the caller's job (fleet-up.sh), the
# only place that knows whether a human is watching.
fleet_resolve_base_branch() {
  local repo="${1:-}" dir="${2:-}" flag="${3:-}" default='' b=''
  if command -v gh >/dev/null 2>&1; then
    default=$(gh repo view "$repo" --json defaultBranchRef \
                -q .defaultBranchRef.name 2>/dev/null) || default=''
  fi
  if [ -n "$flag" ]; then
    printf '%s\t%s\t%s\n' "$flag" flag "$default"; return 0
  fi
  if [ -n "$default" ]; then
    printf '%s\t%s\t%s\n' "$default" default "$default"; return 0
  fi
  b=$(git -C "$dir" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##')
  if [ -n "$b" ]; then printf '%s\t%s\t%s\n' "$b" origin-head "$default"; return 0; fi
  b=$(git -C "$dir" branch --show-current 2>/dev/null)
  if [ -n "$b" ]; then printf '%s\t%s\t%s\n' "$b" checkout "$default"; return 0; fi
  printf '%s\t%s\t%s\n' main fallback "$default"
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

# ---- adding a repo: the ONE implementation (issue #1104) ---------------------
# fleet-up.sh (a fleet's first repo) and fleet-repo.sh add (every further one) used
# to hand-write the checkout step twice, and only fleet-up followed it through: the
# trust warning, the daemon wake, the collector kick. A repo added later got none of
# them — its first worker could park on "trust this folder?", and the daemons could
# sleep a whole idle cycle before looking at it. Both now go through the pieces below.

# fleet_repo_checkout <repo> <dir> [tag] — reuse <dir> when it already IS <repo>'s
# checkout, else clone it there. Progress on stdout, the reason on stderr as
# "<tag>: …". rc 0 ok · 3 <dir> is another repo's checkout · 4 <dir> exists but is
# not a checkout · 5 the clone failed.
fleet_repo_checkout() {
  local repo="${1:-}" dir="${2:-}" tag="${3:-fleet}" have
  if [ -d "$dir/.git" ]; then
    have=$(fleet_norm_repo "$(git -C "$dir" remote get-url origin 2>/dev/null)")
    [ "$have" = "$repo" ] || { echo "$tag: $dir is a checkout of '$have', not '$repo'" >&2; return 3; }
    echo "$tag: reusing existing checkout $dir"
  elif [ -e "$dir" ]; then
    echo "$tag: $dir exists but is not a git checkout" >&2; return 4
  else
    echo "$tag: cloning $repo → $dir"
    mkdir -p "$(dirname "$dir")"
    if command -v gh >/dev/null 2>&1; then gh repo clone "$repo" "$dir" || { echo "$tag: clone failed" >&2; return 5; }
    else git clone "https://github.com/$repo.git" "$dir" || { echo "$tag: clone failed" >&2; return 5; }; fi
  fi
  return 0
}

# fleet_repo_trust_warn <dir> [tag] — say it loudly (stderr) when Claude Code has
# not trusted <dir> (issue #563): it keys trust on a worktree's MAIN checkout, so an
# untrusted one parks every worker a pre-#563 launcher spawns on the trust dialog.
# Silent when trusted, unknown, or fleet-trust.sh is absent. Always returns 0.
fleet_repo_trust_warn() {
  local dir="${1:-}" tag="${2:-fleet}" bin pad
  bin="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)"
  [ -n "$bin" ] && [ -f "$bin/fleet-trust.sh" ] || return 0
  case "$(sh "$bin/fleet-trust.sh" check "$dir" 2>/dev/null)" in
    untrusted)
      pad=$(printf '%*s' "$(( ${#tag} + 2 ))" '')
      echo "$tag: WARNING — $dir is not trusted in $(sh "$bin/fleet-trust.sh" file):" >&2
      echo "${pad}workers spawned by a pre-#563 launcher hang at Claude Code's \"trust this folder?\" dialog." >&2
      echo "${pad}fix now:  sh $bin/fleet-trust.sh grant --main '$dir'" >&2 ;;
  esac
  return 0
}

# fleet_repo_register <sess> <owner/name> [<dir>] [--base <branch>] — add a repo to
# a fleet: validate, clone-or-reuse (<dir> defaults to ~/projects/<name>), resolve
# the base branch (#603), write repos/<slug>.conf atomically, then the same follow-
# through fleet-up gives the first repo — the trust warning, a daemon wake (#1077)
# and a collector kick, so the daemons look at it within their next tick instead of
# an idle cycle later. (No label seed: fleet-up seeds none either; doctor's labels
# row names a repo that lacks them.)
# stdout is ONE result token — the contract the dash's add-repo popup reads (#1103),
# the same shape as dash-reap.sh's; everything human goes to stderr:
#   added:<slug>              0  overlay written, daemons woken
#   refused:invalid-repo      1  not owner/name
#   refused:hosted            1  the fleet already hosts it
#   refused:origin-mismatch   1  <dir> is a checkout of another repo
#   refused:not-a-checkout    1  <dir> exists and is not a git checkout
#   failed:clone              1  the clone failed
#   failed:write              1  the overlay could not be written
# Nothing is written unless the token is added:*.
fleet_repo_register() {
  local sess="" repo="" dir="" base="" base_src="" base_default="" tab f bin rc
  while [ $# -gt 0 ]; do
    case "$1" in
      --base) base="${2:-}"; shift; [ $# -gt 0 ] && shift ;;
      *) if [ -z "$sess" ]; then sess="$1"; elif [ -z "$repo" ]; then repo="$1"
         elif [ -z "$dir" ]; then dir="$1"; fi; shift ;;
    esac
  done
  repo=$(fleet_norm_repo "$repo")
  case "$repo" in
    *[!A-Za-z0-9_./-]* | */*/* | /* | */) repo="" ;;
    ?*/?*) : ;;
    *) repo="" ;;
  esac
  if [ -z "$repo" ]; then
    echo "fleet-repo: invalid repo — expected owner/repo" >&2; echo "refused:invalid-repo"; return 1
  fi
  if fleet_repo_hosted "$sess" "$repo"; then
    echo "fleet-repo: $sess already hosts $repo" >&2; echo "refused:hosted"; return 1
  fi
  dir="${dir:-$HOME/projects/$(basename "$repo")}"
  fleet_repo_checkout "$repo" "$dir" fleet-repo >&2; rc=$?
  case "$rc" in
    0) : ;;
    3) echo "refused:origin-mismatch"; return 1 ;;
    4) echo "refused:not-a-checkout"; return 1 ;;
    *) echo "failed:clone"; return 1 ;;
  esac
  dir=$(cd "$dir" && pwd)
  # Split base<TAB>source<TAB>default by hand: this file must stay POSIX-sh parseable,
  # so no `read … < <(…)` here.
  tab=$(printf '\t')
  base=$(fleet_resolve_base_branch "$repo" "$dir" "$base")
  base_default=${base#*"$tab"}; base=${base%%"$tab"*}
  base_src=${base_default%%"$tab"*}; base_default=${base_default#*"$tab"}
  case "$base_src" in
    default) : ;;
    flag) if [ -n "$base_default" ] && [ "$base" != "$base_default" ]; then
            echo "fleet-repo: WARNING — --base '$base' is NOT $repo's default branch ('$base_default')." >&2
          fi ;;
    *) echo "fleet-repo: WARNING — could not read $repo's default branch from GitHub; using '$base' ($base_src) — verify it is the trunk." >&2 ;;
  esac
  f=$(fleet_repo_conf_file "$sess" "$repo")
  if ! mkdir -p "$(dirname "$f")" 2>/dev/null || ! {
      printf "# claude-fleet: repo '%s' hosted by fleet '%s' — written by fleet-repo.sh %s\n" \
        "$repo" "$sess" "$(date '+%Y-%m-%d %H:%M:%S')"
      printf '# Overlays the fleet conf for this repo'\''s windows. Optional overrides:\n'
      printf '# FLEET_MODEL, FLEET_AGENT, FLEET_MCP_CONFIG, FLEET_DEPLOY_*.\n'
      printf 'FLEET_REPO="%s"\n' "$repo"
      printf 'FLEET_MAIN="%s"\n' "$dir"
      printf 'FLEET_BASE_BRANCH="%s"\n' "$base"
    } > "$f.tmp.$$" || ! mv -f "$f.tmp.$$" "$f"; then
    rm -f "$f.tmp.$$"; echo "fleet-repo: failed to write $f" >&2; echo "failed:write"; return 1
  fi
  echo "fleet-repo: $sess now hosts $repo (main=$dir base=$base) — $f" >&2
  # --- the follow-through fleet-up gives its first repo ---
  fleet_repo_trust_warn "$dir" fleet-repo
  bin="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)"
  [ -f "$bin/fleet-daemon-lib.sh" ] && ( . "$bin/fleet-daemon-lib.sh" && fleet_daemon_wake "$bin/.." ) 2>/dev/null
  # The collector walks fleet_repos per live fleet, so this tick already fetches the
  # new repo's backlog — no need to wait out its 60s interval (or an idle cycle).
  # _FLEET_REGISTER_NO_KICK=1 skips it for `fleet-repo.sh fold`: the tick's restore
  # snapshot would rewrite <from>'s restore maps while fold is archiving them.
  [ "${_FLEET_REGISTER_NO_KICK:-0}" = 1 ] || [ ! -f "$bin/tmux-dash-collect.sh" ] \
    || ( GH_TTL=0 bash "$bin/tmux-dash-collect.sh" >/dev/null 2>&1 & )
  echo "added:$(fleet_slug "$repo")"
  return 0
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

# ---- the first-login guide (issues #1169 / #1204 / #1215) --------------------
# The guide is a pinned scratch window running /fleet-onboard. Two halves decide
# whether it is ALIVE, and both must hold:
#   • RUNNING — the pinned `guide` window exists and its pane holds a non-shell
#     process (a failed agent leaves the window at a bare shell, so the window's
#     existence alone is not a success).
#   • SPOKE — the wizard actually reached its step 0 on this login:
#     `fleet-onboard.sh brief` writes $FLEET_CONF_DIR/global/guide.spoke the first
#     time it runs. A claude that came up but only printed
#     `Unknown command: /fleet-onboard` (the commands never got installed, #1210
#     defect ③) is RUNNING and never SPOKE — before #1215 that counted as alive and
#     `onboarded` was written over a guide that never said a word.
# The marker is written by fleet-onboard.sh ONLY; everything here reads it. It is
# global, like onboarded: a login has exactly one fleet (EPIC #977).
fleet_guide_spoke_file() { printf '%s/global/guide.spoke' "$FLEET_CONF_DIR"; }
fleet_guide_spoke() { [ -e "$(fleet_guide_spoke_file)" ]; }

fleet_guide_agent_child() {
  local parent="$1" depth="${2:-0}" child cmd
  [ "$depth" -lt 3 ] || return 1
  for child in $(pgrep -P "$parent" 2>/dev/null); do
    cmd=$(ps -o comm= -p "$child" 2>/dev/null)
    case "${cmd##*/}" in sh|bash|zsh|dash|fish|ksh|csh|tcsh|'')
      fleet_guide_agent_child "$child" "$((depth + 1))" && return 0 ;;
      *) return 0 ;;
    esac
  done
  return 1
}

# fleet_guide_running <session> — the RUNNING half: a pinned guide window whose
# pane holds an agent process, spoken or not.
fleet_guide_running() {
  # tmux on Linux escapes control bytes in -F output; keep the separator printable.
  local sess="$1" name pin cmd pid sep='|'
  while IFS="$sep" read -r name pin cmd pid; do
    [ "$name" = guide ] && [ "$pin" = 1 ] || continue
    case "${cmd##*/}" in
      sh|bash|zsh|dash|fish|ksh|csh|tcsh) fleet_guide_agent_child "$pid" && return 0 ;;
      '') ;;
      *) return 0 ;;
    esac
  done <<EOF
$(tmux -L "$sess" list-windows -t "$sess" -F "#{window_name}${sep}#{@pin}${sep}#{pane_current_command}${sep}#{pane_pid}" 2>/dev/null)
EOF
  return 1
}

# fleet_guide_alive <session> — SPOKE and RUNNING. This is what `onboarded`
# (fleet-up's first-fleet wait, the collector's confirm) and fleet-doctor's
# onboard row read. An agent that exited, a window left at a bare shell, or a
# running claude that never reached the brief are all NOT alive.
fleet_guide_alive() { fleet_guide_spoke && fleet_guide_running "$1"; }

# fleet_guide_respawn <session> — restart the original command in the existing
# pinned guide window (kills whatever is in it), or create a seeded pinned
# scratch when there is none. Respawning reuses the worktree instead of leaking
# one on every failed attempt. A guide window that is NOT pinned is someone's
# own scratch that happens to be called guide — refused, never killed.
fleet_guide_respawn() {
  local sess="$1" bin name wid pin sep='|'
  while IFS="$sep" read -r name wid pin; do
    [ "$name" = guide ] || continue
    [ "$pin" = 1 ] || return 1
    tmux -L "$sess" respawn-window -k -t "$wid" >/dev/null 2>&1
    return $?
  done <<EOF
$(tmux -L "$sess" list-windows -t "$sess" -F "#{window_name}${sep}#{window_id}${sep}#{@pin}" 2>/dev/null)
EOF
  bin="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  TMUX='' bash "$bin/dash-raw-session.sh" --name guide --prompt /fleet-onboard --pin "$sess"
}

# fleet_guide_open <session> — make sure a guide agent is up: reuse a RUNNING
# one (spoken or still starting — `cf --guide` five seconds after fleet-up must
# not kill a claude that is still loading), else respawn / create. Killing a
# running-but-silent guide is the collector tick's call, on its own clock.
fleet_guide_open() {
  fleet_guide_running "$1" && return 0
  fleet_guide_respawn "$1"
}

# A live guide has to survive a second look before onboarded is durable.
fleet_guide_confirmed() {
  fleet_guide_alive "$1" || return 1
  sleep 1
  fleet_guide_alive "$1"
}

fleet_guide_wait() {
  local sess="$1" limit="${2:-30}" deadline
  case "$limit" in ''|*[!0-9]*) limit=30 ;; esac
  deadline=$(( $(date +%s) + limit ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    fleet_guide_confirmed "$sess" && return 0
    sleep 1
  done
  return 1
}

# Called once per collector tick. The pending marker is created ONLY by a new
# fleet's first guide attempt; missing onboarded alone never opts old fleets in.
# Two clocks, both measured from the last open (global/onboard.retry):
#   FLEET_GUIDE_COOLDOWN   (60s)  a guide that is DEAD — agent exited, window at a
#                                 bare shell, no window — is reopened after this.
#   FLEET_GUIDE_SPEAK_SECS (180s) a guide that is RUNNING but has not spoken is
#                                 given this long to reach its brief before it is
#                                 killed and restarted. A real claude gets there in
#                                 well under a minute; the one this exists for
#                                 (`Unknown command: /fleet-onboard`, #1215) never
#                                 will, and restarting a claude that is merely
#                                 slow would only restart its clock.
fleet_guide_tick() {
  local sockets="$1" sock retry cooldown stamp
  [ "${FLEET_ONBOARD:-1}" != 0 ] || return 0
  [ -f "$FLEET_CONF_DIR/global/onboard.pending" ] || return 0
  [ ! -e "$FLEET_CONF_DIR/global/onboarded" ] || return 0
  for sock in $sockets; do
    if fleet_guide_confirmed "$sock"; then
      date '+%Y-%m-%d %H:%M:%S' > "$FLEET_CONF_DIR/global/onboarded"
      rm -f "$FLEET_CONF_DIR/global/onboard.pending"
      return 0
    fi
  done
  [ -n "$sockets" ] || return 0
  sock=${sockets%%$'\n'*}
  retry=$(cat "$FLEET_CONF_DIR/global/onboard.retry" 2>/dev/null || true)
  case "$retry" in ''|*[!0-9]*) retry=0 ;; esac
  if fleet_guide_running "$sock"; then cooldown="${FLEET_GUIDE_SPEAK_SECS:-180}"
  else cooldown="${FLEET_GUIDE_COOLDOWN:-60}"; fi
  case "$cooldown" in ''|*[!0-9]*) cooldown=60 ;; esac
  stamp=$(date +%s)
  [ $((stamp - retry)) -ge "$cooldown" ] || return 0
  printf '%s\n' "$stamp" > "$FLEET_CONF_DIR/global/onboard.retry"
  fleet_guide_respawn "$sock" >/dev/null 2>&1 || printf 'fleet-guide: could not reopen onboarding guide in %s\n' "$sock" >&2
}

# ~/.local/bin on the PATH a fleet's tmux server runs under (issue #1191). Claude
# Code is a per-login NATIVE install — ~/.local/bin/claude, nothing system-wide.
# Where a new pane's PATH comes from (tmux 3.6, measured): a pane spawned BY A
# CLIENT (`tmux new-window` from a shell, a daemon) gets THAT CLIENT's PATH — the
# zshrc line and the launchd plists' PATH cover those; a pane spawned SERVER-SIDE
# (a dash bind's run-shell, a hook, anything the server itself runs) gets the
# server's GLOBAL environment, which is the PATH of the process that started the
# server, for the server's whole life. A server started from a login whose PATH
# lacked the dir never found claude on that path again (#1183: the guide window
# died at spawn with `exec: claude: not found`). Two halves, both exact no-ops
# when the dir is already there:
#   fleet_local_bin_path        — this process: PATH with $HOME/.local/bin in
#                                 front (export it BEFORE the server forks, and
#                                 before this process spawns any window)
#   fleet_server_local_bin <s>  — a server already running on socket <s>: stamp
#                                 it onto the global environment, for every
#                                 server-side spawn from now on (an older
#                                 fleet-up, a daemon's PATH); open panes keep theirs
fleet_local_bin_path() {
  case ":$PATH:" in
    *":$HOME/.local/bin:"*) printf '%s' "$PATH" ;;
    *) printf '%s' "$HOME/.local/bin:$PATH" ;;
  esac
}
fleet_server_local_bin() {
  local sock="$1" cur
  cur=$(tmux -L "$sock" show-environment -g PATH 2>/dev/null) || cur=''
  case "$cur" in PATH=*) cur=${cur#PATH=} ;; *) cur=$PATH ;; esac
  case ":$cur:" in *":$HOME/.local/bin:"*) return 0 ;; esac
  tmux -L "$sock" set-environment -g PATH "$HOME/.local/bin:$cur" 2>/dev/null
}

# fleet_bg [-L <socket>] <shell-command> — the shared "background this bind body"
# helper (issue #304). Dispatch <shell-command> as a DETACHED, server-side
# background job (via `tmux run-shell -b`) so the interactive fzf bind / popup that
# invoked it returns INSTANTLY instead of freezing the dash on a slow gh (network)
# or `git worktree` op. This is the ONE place the fleet's non-blocking-bind
# convention lives; the fix pattern is: keep the CHEAP/authoritative checks +
# optimistic UI synchronous on the bind, hand ONLY the slow tail to fleet_bg.
#
# SILENCING IS THIS FUNCTION'S JOB (issue #575). `tmux run-shell` captures its
# command's stdout and, when non-empty, opens a full-pane view-mode OVERLAY on the
# attached client that the operator must dismiss with Esc/q — so a backgrounded
# job that prints ANYTHING hijacks whatever window they were in. The rule used to
# live in this comment as a contract each call site had to honour, and call sites
# duly missed it (quotawatch/collector/usage-modal all redirected the OUTER tmux's
# stderr — `2>/dev/null` outside the quotes — and handed the inner script's stdout
# straight to tmux). So the wrap now happens HERE, once: the command is run as
#     ( <shell-command>
#     ) >/dev/null 2>&1 || :
# which no caller can forget. An inner redirect a caller already has is harmless —
# it just wins inside the group. Two details of that one line are load-bearing:
#   • the closing paren sits on its OWN line, so a command ending in `&`, `;` or a
#     trailing `#comment` still closes;
#   • it is a SUBSHELL, not a `{ … }` brace group, because the `|| :` has to catch
#     an `exit <n>` from the command — inside braces that exits the whole `sh -c`
#     and the `|| :` never runs.
#
# The trailing `|| :` closes the SECOND route to the same overlay: tmux opens the
# view on a NONZERO EXIT too, even when the job printed nothing (verified on tmux
# 3.7 — it appends its own "did not exit successfully" line). dash-zoom.sh and
# hub-zoom.sh each end in a hand-written `exit 0` for exactly this reason; a
# backgrounded job has no such tail to add one to, so fleet_bg swallows the status
# here. Nothing reads it anyway — `-b` is fire-and-forget.
#
# Contract for <shell-command> (it runs LATER, decoupled from the now-gone caller):
#   • self-contained — it runs under `sh -c` with NO cwd/unexported-env guarantee,
#     so use absolute paths (a self re-exec `bash "$0" … --bg` is the usual shape);
#   • reports its OWN outcome — the caller has already returned AND its output is
#     discarded, so both a result and a failure must surface via
#     `tmux display-message` (the `--toast` flag the fleet scripts carry), never
#     via stdout or an exit status nobody reads.
#
# Socket: run from INSIDE a fleet pane/popup, where $TMUX names THIS fleet's
# server, bare `fleet_bg` is correct and the backgrounded job inherits the same
# $TMUX (its nested `tmux` calls stay on this fleet's socket). A HEADLESS caller
# with no $TMUX (a daemon fanning out over fleet_sockets, a selftest) names the
# target socket with `-L <label>` — or, for a whole script, FLEET_BG_SOCK; the
# explicit flag wins. Safe under a `set -u` caller.
fleet_bg() {
  local _sock="${FLEET_BG_SOCK:-}" _body
  if [ "${1:-}" = "-L" ]; then _sock="${2:-}"; shift 2; fi
  # Newline before the paren: a command ending in `&`/`;`/`#…` must still close.
  # Subshell + `|| :`: a nonzero exit opens the same view-mode overlay as output
  # does, and only a subshell lets `|| :` catch an `exit` from the command.
  _body="( ${1:-:}
) >/dev/null 2>&1 || :"
  if [ -n "$_sock" ]; then
    tmux -L "$_sock" run-shell -b "$_body" 2>/dev/null
  else
    tmux run-shell -b "$_body" 2>/dev/null
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

# fleet_server_cwds — print the PROCESS working directory of every live fleet
# tmux server, one per line (deduped upstream by the caller if needed).
#
# Why this exists (issue #509): a tmux server chdir's ITSELF into the panes it
# spawns with `-c <dir>`, so over a fleet's life the server's own cwd drifts into
# whatever worktree was last spawned — cross-fleet, since the drift follows pane
# creation regardless of which repo the worktree belongs to. If a reaper then
# removes the worktree the server is sitting in, the server is stranded on a
# deleted inode and getcwd() fails for good: EVERY window it spawns afterwards —
# even one launched with an explicit, valid `-c` — is born in that dead cwd,
# because tmux resolves the new pane's directory against the server's own broken
# cwd and falls back to `.`. Claude Code then aborts at launch with
#   "The current working directory was deleted, so that command didn't work."
# and the whole fleet can no longer open a usable scratch/worker window until its
# server is restarted. The janitor consults this so a worktree a server is cwd'd
# into is treated as LIVE and never reaped — closing the hole at the reaper.
#
# Cross-platform: readlink /proc/<pid>/cwd on Linux (strip a trailing
# " (deleted)"), lsof -Fn on macOS/BSD. The server pid is the `#{pid}` format,
# read via list-sessions so it resolves in a headless daemon (no attached client).
fleet_server_cwds() {
  local label pid cwd
  while IFS= read -r label; do
    [ -n "$label" ] || continue
    pid=$(tmux -L "$label" list-sessions -F '#{pid}' 2>/dev/null | head -1)
    case "$pid" in ''|*[!0-9]*) continue ;; esac
    if [ -r "/proc/$pid/cwd" ]; then
      cwd=$(readlink "/proc/$pid/cwd" 2>/dev/null); cwd=${cwd% (deleted)}
    else
      cwd=$(lsof -a -p "$pid" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p' | head -1)
    fi
    [ -n "$cwd" ] && printf '%s\n' "$cwd"
  done <<EOF
$(fleet_sockets)
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
# a human ran? The status classifier (and, until issue #535, the dashboard
# summarizer) runs from INSIDE a window's worktree, so its transcripts land in the
# SAME project dir as the session they describe — and it runs on every Stop, so
# they are usually the NEWEST file there. Recognise them by their own rubric text
# (RUBRIC= in bin/classify-sessions.sh; fleet-history-selftest.sh pins that string
# against the file so the two cannot drift apart silently). The summarizer's rubric
# stays in the list below: its transcripts outlive the retired script on disk.
# Canonical copy — bin/fleet-history.sh (indexing) and bin/worktree-autoclean.sh
# (the conversation-scratch keep gate) both key off it.
#
# Read into a variable, then match — `head -c … | grep -q` would exit 141 under
# pipefail when grep closes the pipe early.
fleet_internal_transcript() {   # $1=jsonl path → 0 = fleet-internal, 1 = a real session
  local head_bytes; head_bytes=$(head -c 16384 "${1:-}" 2>/dev/null)
  case "$head_bytes" in
    *"You are a status classifier for a Claude Code"*)          return 0 ;;
    *"You are a status classifier for a coding-agent"*)         return 0 ;;
    *"You are labeling a Claude Code session for a dashboard"*) return 0 ;;
  esac
  return 1
}

# newest HUMAN *.jsonl session id in a transcript dir (basename sans .jsonl), or
# empty when the dir holds nothing but the fleet's own helper transcripts (a warm
# scratch-pool worktree is exactly that — all 21 transcripts in one such dir were
# classifier/summarizer runs — the latter before #535).
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

# WHEN did the human session in this transcript dir last speak? — mtime (epoch
# seconds) of the newest NON-fleet-internal *.jsonl, or empty when the dir holds
# no real session. This is the "is anybody still working here" clock the
# closed-unmerged reap gate reads (issue #544): a PR going CLOSED says nothing
# about whether its worker is still typing — #534's worker spent four minutes
# resolving a conflict AFTER GitHub auto-closed its PR, and got SIGKILLed for it.
#
# Same two hazards as fleet_newest_human_session, handled the same way: skip the
# fleet's OWN classifier transcripts (they land in the same dir and are usually
# the newest file there), and no `| head` — an early-closing consumer under
# pipefail makes `ls` die of SIGPIPE and reports 141 for the busiest dirs.
fleet_newest_human_mtime() {
  local dir="${1:-}" list f n=0 m
  [ -d "$dir" ] || return 0
  list=$(ls -t "$dir"/*.jsonl 2>/dev/null)
  [ -n "$list" ] || return 0
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    n=$((n + 1)); [ "$n" -gt 200 ] && break
    fleet_internal_transcript "$f" && continue
    # GNU stat FIRST: `stat -f %m` on GNU means "filesystem status" and exits 0
    # with non-mtime output, so it must not win (fleet_inflight_count, same trap).
    m=$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null || echo '')
    case "$m" in ''|*[!0-9]*) return 0;; esac
    printf '%s\n' "$m"
    return 0
  done <<EOF
$list
EOF
  return 0
}

# CHEAP: which SEAT is the caller running in? (see commands/README.md — the
# fleet-skill role-guard.) Prints:
#   worker  — the current tmux window has @issue set AND cwd is inside the
#             worktree it is bound to (a session bound to one issue)
#   ""      — not a worker (the operator's hub pane, a panel, or a stray shell)
# Since issue #439 the fleet has ONE seat: `worker`. The hub pane is the
# operator's own Claude session, not a fleet role — it is identified by the @hub
# pane marker / FLEET_HUB env (see fleet_hub_pane), never by a seat.
#
# TWO worktree shapes count, because a worker can be born either way:
#   * SPAWNED  — dash-issue-session.sh puts it in an `issue-<N>` directory, which
#                the cwd glob below recognises on its own.
#   * BOUND IN PLACE — fleet-bind.sh (issue #520) promotes a SCRATCH: it renames
#                the branch to `issue-<N>` but deliberately leaves the DIRECTORY
#                named `<repo>-scratch-<K>` (moving it would strand a running
#                Claude's cwd), so the glob cannot see it. That window carries
#                both @issue and @worktree, so "cwd is inside my own @worktree"
#                is the identity — and it is strictly narrower than the glob: a
#                plain scratch has @worktree but no @issue, and stays seatless.
# Pure tmux + shell builtins, no git/gh forks.
fleet_seat() {
  local o issue wt cwd
  o=$(tmux display-message -p -t "${TMUX_PANE:-}" '#{@issue}|#{@worktree}' 2>/dev/null)
  issue=${o%%|*}; wt=${o#*|}
  [ "$wt" = "$o" ] && wt=""            # no separator came back ⇒ no @worktree
  [ -n "$issue" ] || return 0          # the binding is required in BOTH shapes
  cwd=$(pwd -P 2>/dev/null)
  # Match both the bare `issue-<N>` worktree name and the `<repo>-issue-<N>`
  # form every creator names it (fleet_worktree_dir: `<main-basename>-<slug>`), where
  # `issue-<N>` is preceded by `-`, not `/`. `*/*issue-[0-9]*` still requires a
  # path separator (a real nested path) but tolerates the `<repo>-` prefix.
  case "$cwd" in
    */*issue-[0-9]*) printf 'worker'; return ;;
  esac
  # Bound-in-place worker: cwd is the bound window's own @worktree, or under it.
  case "$wt" in
    /*)
      case "$cwd" in
        "$wt"|"$wt"/*) printf 'worker'; return ;;
      esac
      # The conf-derived @worktree may be unresolved where cwd is not (/tmp vs
      # /private/tmp on macOS), so pay for one subshell resolve only on a miss.
      local rwt; rwt=$(cd "$wt" 2>/dev/null && pwd -P 2>/dev/null)
      case "$cwd" in
        "$rwt"|"$rwt"/*) [ -n "$rwt" ] && { printf 'worker'; return; } ;;
      esac ;;
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
#   live        (rc 1) — active bound window or unreadable liveness/Git metadata
#   merged-pr   (rc 0) — clean AND a MERGED PR exists for the branch
#   ancestor    (rc 0) — clean AND the tip is a STRICT ancestor of the base ref
#   dirty       (rc 1) — has uncommitted/untracked changes (untracked counts)
#   unmerged    (rc 1) — clean but no merged PR or strict ancestry (includes tip == base)
# Args: <worktree-dir> <repo-root> <branch> <head-sha> <base-ref> <merged-branches>
# <merged-branches> is a newline-separated list of merged PR head-ref names (the
# caller's `gh pr list --state merged` output). A caller that only wants the two
# safe outcomes can just test the return code. Safe under a `set -u` caller.
fleet_reap_ok() {
  local wtdir="${1:-}" root="${2:-}" branch="${3:-}" head="${4:-}" base="${5:-}" merged="${6:-}"
  # Liveness precedes Git eligibility (#565). Scan the registered fleet sockets
  # using bound worktrees and every pane cwd; a failed probe is never permission
  # to remove data. Callers retain their additional identity/rotation guards.
  local _reap_sockets _reap_bin
  if [ -n "$wtdir" ]; then
    _reap_sockets=$(fleet_sockets)
    if [ -n "$_reap_sockets" ]; then
      _reap_bin="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)"
      if ! FLEET_REAP_MIN_AGE="${FLEET_REAP_MIN_AGE:-1800}" \
        python3 "$_reap_bin/fleet-reap-live.py" --worktree "$wtdir" \
          --socket-names "$_reap_sockets" >/dev/null 2>&1; then
        printf 'live'; return 1
      fi
    fi
  fi
  local _reap_status
  if [ -n "$wtdir" ] && [ -e "$wtdir" ]; then
    if ! _reap_status=$(git -C "$wtdir" status --porcelain 2>/dev/null); then
      printf 'live'; return 1
    fi
    if [ -n "$_reap_status" ]; then printf 'dirty'; return 1; fi
  fi
  if [ -n "$branch" ] && printf '%s\n' "$merged" | grep -qxF "$branch"; then
    printf 'merged-pr'; return 0
  fi
  # Equality also satisfies --is-ancestor, but a just-created branch has exactly
  # that shape (#565). Resolve refs to commits before comparing: base may be a
  # branch/ref rather than a SHA. Missing refs fail closed through unmerged.
  # A merged PR above remains independent evidence, even when tip == base.
  local head_commit base_commit
  if [ -n "$head" ] && [ -n "$base" ] \
     && head_commit=$(git -C "$root" rev-parse --verify "$head^{commit}" 2>/dev/null) \
     && base_commit=$(git -C "$root" rev-parse --verify "$base^{commit}" 2>/dev/null) \
     && [ "$head_commit" != "$base_commit" ] \
     && git -C "$root" merge-base --is-ancestor "$head_commit" "$base_commit" 2>/dev/null; then
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

# tmux for a NAMED fleet from either side of the #159 dividing line: inside a pane
# $TMUX already carries this fleet's socket (bare `tmux` is correct); outside one a
# daemon must name the fleet's OWN socket by label. Private to fleet_wt_window —
# every other caller in the tree spells its own two-line `ftmux()` inline.
_fleet_tmux() {
  local sess="${1:-}"; shift
  if [ -n "${TMUX:-}" ]; then tmux "$@"
  else tmux -L "$(fleet_socket "$sess")" "$@"; fi
}

# fleet_wt_window <session> <worktree-dir> — the live window sitting in a worktree,
# addressed by PANE CWD (issue #589). An `issue-<N>` worker is addressed by its
# @issue binding instead, which is cwd-INdependent and therefore the better key
# (issue #353); a scratch / ad-hoc worktree carries no such binding, so cwd is the
# only link back to its window. Match the worktree root or any subdir of it —
# the same exact-or-prefix rule the worktree janitor's liveness gate uses, so a
# session whose cwd wandered into a subdir still reads as live.
# Prints "<window_id><TAB><@claude_state>" for the FIRST pane that matches ('-'
# when the state option is unset) and NOTHING when no live pane sits in the
# worktree. Two reads rather than one combined format on purpose: an unset
# @claude_state would collapse to nothing mid-line and shift the path field.
fleet_wt_window() {
  local sess="${1:-}" dir="${2:-}" wid st
  [ -n "$sess" ] && [ -n "$dir" ] || return 0
  dir="${dir%/}"
  wid=$(_fleet_tmux "$sess" list-panes -s -t "$sess" \
          -F '#{window_id} #{pane_current_path}' 2>/dev/null \
        | awk -v d="$dir" '{ w=$1; p=$0; sub(/^[^ ]* /, "", p)
                             if (p == d || index(p, d "/") == 1) { print w; exit } }')
  [ -n "$wid" ] || return 0
  st=$(_fleet_tmux "$sess" list-windows -t "$sess" \
          -F '#{window_id} #{@claude_state}' 2>/dev/null \
       | awk -v w="$wid" '$1 == w { print $2; exit }')
  printf '%s\t%s' "$wid" "${st:--}"
}

# fleet_pid_alive <pid> — has this process NOT exited? `kill -0` alone answers
# "does the pid exist", and an exited child stays a zombie until its parent reaps
# it. tmux 3.4 (the Linux CI runner) sometimes never handles SIGCHLD for a pane
# process, so an agent that quit on /exit lingers as `Z` for 40s+ and every
# `kill -0` wait times out on a process that is already gone (issue #842, same
# root as #781's `source_alive` in fleet-sleep.py). A zombie is exited. Only a
# positive `Z` reads as exited: a failed `ps` keeps the kill -0 answer (alive),
# so a caller that launches a replacement on "exited" can never be told so early.
fleet_pid_alive() {
  local st
  kill -0 "$1" 2>/dev/null || return 1
  st=$(ps -o stat= -p "$1" 2>/dev/null) || st=''
  case "$st" in *Z*) return 1 ;; esac
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

# Kill a process AND every descendant it has — TERM the whole tree, brief grace,
# then SIGKILL whatever survived (issue #582) — and then VERIFY that it is
# actually gone (issue #682). Two reasons a plain `kill -TERM <pid>` is not
# enough for a wedged daemon tick:
#
#   (1) bash DEFERS a trapped signal until the current FOREGROUND command
#       returns. A tick blocked inside `x=$(slow-child)` keeps running for as
#       long as the child takes — a 2026-09-13 quotawatch tick survived its
#       supersede by 26 MINUTES against a 120 s deadline, because it sat in a
#       `tmux display-message` that never came back.
#   (2) killing only the script leaves its children (the actual tmux clients)
#       attached to a loaded server, which is what made the next tick slow too.
#
# TWO ways to reach the tree, used together (issue #682):
#
#   (a) PROCESS GROUP, when <root> leads its own — `kill -<sig> -<pgid>`. This is
#       the one that cannot race: one syscall reaches every descendant, including
#       the ones forked AFTER the sweep began, and it keeps reaching orphans
#       after the root itself is gone (they keep the pgid; they lose the parent).
#       fleet_timebox launches under `set -m` precisely so its job is a leader.
#   (b) the `pgrep -P` walk, for a root we did not launch — quotawatch supersedes
#       a pid read off its lock dir — or where the leader bit is not ours to have.
#
# Why (b) alone was not enough, i.e. the #682 incident. fleet_timebox logged
# "killed" for phase after phase whose trees were still running, and the next tick
# started fresh ones on top of them: at load 170+ under launchd
# `ProcessType=Background`, every `pgrep` fork in the walk is itself starved for
# tens of seconds, so the set being signalled was already minutes stale when the
# signal landed, and everything forked in the gap survived as an orphan. Budgets
# were being enforced against a SNAPSHOT of a tree, which is not enforcement:
# `FLEET_COLLECT_TICK_BUDGET` read 120s while the tick ran 3259s.
#
# Returns 0 when the tree is gone, 1 when something outlived the SIGKILL — so a
# caller that must not proceed over a live tree can finally tell. It still never
# fails on a race with a normally-exiting child: a tree that leaves on its own
# reads as gone.
#
#   $1  root pid (required)
#   $2  grace seconds between TERM and KILL (default 2)

# _fleet_proc_tree <root> [pgid] — every live pid in the tree, root first, one per
# line. Walks `pgrep -P` breadth-first; when <pgid> is given, the group membership
# is unioned in, which is what still sees ORPHANS once the root has been reaped.
# Never lists this process or pid ≤ 1. No pgrep ⇒ just the root.
_fleet_proc_tree() {
  local root="${1:-}" pgid="${2:-}" all="" frontier="" next="" p c
  case "$root" in ''|*[!0-9]*) return 0 ;; esac
  frontier="$root"
  while [ -n "$frontier" ]; do
    all="$all $frontier"; next=""
    for p in $frontier; do
      for c in $(pgrep -P "$p" 2>/dev/null); do
        [ "$c" != "$$" ] && next="$next $c"
      done
    done
    frontier="${next# }"
  done
  case "$pgid" in
    ''|*[!0-9]*) : ;;
    *) for p in $(pgrep -g "$pgid" 2>/dev/null); do
         [ "$p" != "$$" ] && all="$all $p"
       done ;;
  esac
  for p in $all; do
    [ "$p" -gt 1 ] 2>/dev/null || continue
    [ "$p" = "$$" ] && continue
    kill -0 "$p" 2>/dev/null && printf '%s\n' "$p"
  done | sort -un
}

fleet_kill_tree() {
  local root="${1:-}" grace="${2:-2}" pgid="" live="" round=0
  case "$root" in ''|*[!0-9]*) return 0 ;; esac
  [ "$root" -gt 1 ] || return 0
  [ "$root" != "$$" ] || return 0
  case "$grace" in ''|*[!0-9]*) grace=2 ;; esac

  # Is the root its own group leader? Only then may we signal the GROUP — a
  # negative pid that is not our own job's group could reach a whole unrelated
  # session, so this is checked, never assumed.
  pgid=$(ps -o pgid= -p "$root" 2>/dev/null | tr -d ' ')
  case "$pgid" in ''|*[!0-9]*) pgid='' ;; esac
  [ "$pgid" = "$root" ] || pgid=''
  [ "$pgid" = "$$" ] && pgid=''

  # Round 1 — TERM. Parents first: a TERMed parent cannot fork a replacement
  # child mid-sweep. The group signal goes first because it is the one that does
  # not depend on the walk finishing in time.
  [ -n "$pgid" ] && kill -TERM -"$pgid" 2>/dev/null
  live=$(_fleet_proc_tree "$root" "$pgid")
  [ -n "$live" ] || return 0
  kill -TERM $live 2>/dev/null
  sleep "$grace"

  # Rounds 2-3 — SIGKILL, RE-ENUMERATING each round. The re-read is the whole
  # point: the previous round's signal landed on a set that may have grown while
  # the walk was being starved. SIGKILL cannot be deferred or trapped, so a tree
  # that is still there after two rounds is not merely slow to die.
  while [ "$round" -lt 2 ]; do
    [ -n "$pgid" ] && kill -KILL -"$pgid" 2>/dev/null
    live=$(_fleet_proc_tree "$root" "$pgid")
    [ -n "$live" ] || return 0
    kill -KILL $live 2>/dev/null
    round=$((round+1))
  done

  # The verdict is a READ, never an assumption — that is the #682 lesson.
  live=$(_fleet_proc_tree "$root" "$pgid")
  [ -n "$live" ] || return 0
  return 1
}

# Run a command under a WALL-CLOCK budget (issue #582). Prints the command's
# stdout/stderr through untouched, returns its exit status — or 124, GNU
# timeout's convention, when the budget ran out and the whole tree was killed.
#
# Why not `timeout(1)`: it is coreutils, and macOS ships neither it nor
# `gtimeout` unless someone installed them. This machine has neither, and the
# daemons that most need a budget are exactly the ones running unattended there.
#
# A private FIFO wakes the caller when the background job exits (issue #701).
# Waiting uses bash's builtin `read -t 1`: no fork per poll, and normal completion
# wakes it immediately instead of paying a mandatory `sleep 1`. Integer timeouts
# work on macOS bash 3.2 too; fractional `read -t` and `{fd}<>` do not. The FIFO is
# unlinked as soon as it is open, and never carries the job's stdout/stderr.
# If a job replaces its EXIT trap or execs, the one-second liveness check still
# catches its exit. An already-open fd 9 is left to the caller and its children;
# that case uses the old bounded loop. Safe inside `$( )`: stdout is unchanged.
#
# The poll compares against a WALL-CLOCK DEADLINE, and this is load-bearing
# (issue #653). It used to count iterations instead —
#
#     while [ "$waited" -lt "$budget" ]; do …; sleep 1; waited=$((waited+1)); done
#
# — on the assumption that one iteration costs one second. That assumption breaks
# exactly when a budget matters. The collector runs under launchd
# `ProcessType=Background` (lowest CPU + I/O tier); at load 40+ the `sleep`
# fork/exec in each iteration cost SECONDS, so a 30s git budget spent 56s and then
# 126s of wall clock — 1.9x and 4.2x — while `waited` counted dutifully to 30. The
# budget inflated by the very factor that made the work slow, i.e. it was loosest
# at the moment it was needed, and the tick it was meant to bound ran 454s against
# a 60s interval. A deadline cannot drift that way: however long an iteration
# takes, the loop stops at the first poll past it, so the overshoot is bounded by
# ONE poll instead of multiplying with the load.
#
# READING that deadline must itself be free, which is the #682 half. The check
# used to be `$(date +%s)` — a FORK, once per poll — and a fork is precisely what
# is starved under `ProcessType=Background`: measured on the incident host at load
# 170+, a background-QoS process could not complete three 5-second budgets in 600
# seconds, while the same script at normal priority took 6. So the loop could not
# OBSERVE its own deadline often enough to enforce it, and #653's honest budget
# went unread. `SECONDS` is a bash builtin counting wall clock since the shell
# started: same clock, no fork. The FIFO removes the remaining `sleep` fork from
# the normal poll path. Setup uses mkfifo/rm once per call, never per poll;
# if that setup fails, retain the old bounded sleep loop rather than run unbounded.
#
#   $1   budget in seconds (0 or non-numeric ⇒ run unbudgeted)
#   $2+  the command and its arguments (not a shell string — no eval)
fleet_timebox() {
  local budget="${1:-0}"; shift
  case "$budget" in ''|*[!0-9]*) budget=0 ;; esac
  [ "$budget" -gt 0 ] || { "$@"; return $?; }

  if { : >&9; } 2>/dev/null; then
    _fleet_timebox_run '' "$budget" "$@"
    return $?
  fi
  # mkfifo creates exclusively: a collision/symlink fails without touching the
  # existing path. Mode 600 keeps this private without a separate temp directory.
  local wake="${TMPDIR:-/tmp}/fleet-timebox.$$.$RANDOM.$RANDOM" opened=0 rc=0
  if mkfifo -m 600 "$wake" 2>/dev/null; then
    # Scoped redirection restores fd 9. Read/write avoids an open rendezvous or
    # EOF spin. Only the wrapper's EXIT trap writes; the job gets fd 9 closed.
    { opened=1; _fleet_timebox_run "$wake" "$budget" "$@"; } 9<> "$wake"; rc=$?
    [ "$opened" = 1 ] || rm -f "$wake"   # also clean up if opening fd 9 failed
    return "$rc"
  fi
  _fleet_timebox_run '' "$budget" "$@"
}

_fleet_timebox_run() {
  local wake="$1" budget="$2"; shift 2
  [ -z "$wake" ] || rm -f "$wake"

  # Launch the job as its own PROCESS-GROUP LEADER (issue #682), so the kill below
  # is a group signal and not a race against a tree that keeps forking. `set -m`
  # in a non-interactive shell does exactly that; it is restored immediately, so
  # the caller's job-control setting is untouched.
  # stdin from /dev/null EXPLICITLY. Without job control bash gives a background
  # job /dev/null by itself; with `set -m` it hands over the caller's stdin
  # instead, which on a tty would let a phase stop on SIGTTIN rather than see EOF.
  # No caller feeds a timeboxed command anything on stdin, so this just keeps the
  # behaviour the job always effectively had.
  local mflag=0; case "$-" in *m*) mflag=1 ;; esac
  set -m
  if [ -n "$wake" ]; then
    ( trap 'printf "\n" 2>/dev/null >&9' EXIT; "$@" 9>&- ) </dev/null &
  else
    "$@" </dev/null &
  fi
  local job=$!
  [ "$mflag" = 1 ] || set +m

  local start=$SECONDS name="${1:-job}" notice=''
  # Poll order is: is the job done? → is the clock up? → wait for completion. A job
  # that finishes is always noticed before the deadline is declared blown, and the
  # loop never sleeps past a deadline it has already reached.
  while :; do
    kill -0 "$job" 2>/dev/null || { wait "$job"; return $?; }
    [ $(( SECONDS - start )) -lt "$budget" ] || break
    if [ -n "$wake" ]; then
      if IFS= read -r -t 1 -u 9 notice && [ -z "$notice" ]; then
        # Only the wrapper's EXIT trap sends this: the job is already exiting, so
        # wait returns its actual status, including failures and explicit exit.
        wait "$job"; return $?
      fi
    else
      sleep 1
    fi
  done
  kill -0 "$job" 2>/dev/null || { wait "$job"; return $?; }

  # SAY SO when the kill did not take. Before #682 this path returned 124 either
  # way and every caller printed "killed", which is how a machine came to be
  # running fifty-four minutes of phases that the log said had been killed.
  if ! fleet_kill_tree "$job" 1; then
    printf 'fleet_timebox: %s (pid %s) SURVIVED its %ss budget and the SIGKILL — orphans are still running; the next tick will start another one on top\n' \
      "$name" "$job" "$budget" >&2
  fi
  wait "$job" 2>/dev/null
  return 124
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
# Never touches this process, its parent, pid≤1, the shared tmux server, or a
# process running under a live tmux PANE (issue #550). Prints a one-line summary to
# stdout (the caller logs it). Best-effort: absent pgrep/lsof simply narrow the
# search; it never fails the caller.
#
# The MATCHER itself is _fleet_worktree_anchored_pids below — the same three ways,
# without the killing — because the janitor has to ask the question too, and a
# second copy of it would be a second thing to get wrong.
# Candidate pids ANCHORED to a worktree by the three matchers above. Split out of
# the reaper (issue #550) so a caller can ask the SAME question without killing
# anything — "is anything still running in here?" is the janitor's liveness
# question, and it must be answered by the process table, not by tmux metadata.
# Prints one numeric pid per line, sorted + deduped; prints NOTHING for an empty
# dir or a broad root (each caller does its own refusing).
# fleet_mangle_path <path> — the directory name Claude Code derives from a path
# for its per-session scratch + transcript dirs: EVERY non-alphanumeric byte
# becomes `-`, not just `/` (issue #1154). `tr '/' '-'` alone left the dots in, so
# every worktree under a `*.noindex` FLEET_WORKTREE_ROOT (#886's recommended
# layout — `/…/.fleet-worktrees.noindex/…` is `-…--fleet-worktrees-noindex-…` on
# disk) silently fell out of matcher (3) below.
fleet_mangle_path() {
  printf '%s' "${1:-}" | LC_ALL=C tr -c 'A-Za-z0-9' '-'
}

_fleet_worktree_anchored_pids() {
  local dir="${1:-}"
  [ -n "$dir" ] || return 0
  dir="${dir%/}"
  case "$dir" in /|/Users|/home|/tmp|/var|"$HOME") return 0 ;; esac

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
  mp1="/$(fleet_mangle_path "$cdir")/"
  mp2="/$(fleet_mangle_path "$dir")/"
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

  printf '%s\n' $pids | grep -E '^[0-9]+$' | sort -un
}

# Live tmux SERVER pids — the root of every pane's process tree (issue #550).
# Socket-agnostic on purpose: this answers "is a tmux running it", which is true of
# a pane on ANY socket, including a fleet whose conf this process cannot read and a
# selftest's private `-S` one.
#
# Read from `ps`, NOT pgrep, and that is the whole point: macOS pgrep excludes the
# CALLER'S OWN ANCESTORS from every match unless given -a. So a `pgrep -x tmux` run
# from inside a pane silently omits the one server that matters — the server that
# is running the caller — which is how a reaper invoked from a fleet pane could
# fail to recognise its own tmux (verified on macOS 25.4: the fleet's server was
# absent from `pgrep -x tmux` while `ps` listed it). `comm` is the executable, so
# a basename match is immune to tmux's setproctitle rename ("tmux: server (…)").
fleet_tmux_server_pids() {
  ps -eo pid=,comm= 2>/dev/null | awk '
    { c = $2; sub(/.*\//, "", c)
      if (c == "tmux" || c ~ /^tmux:/) print $1 + 0 }' | sort -un
}

# fleet_pids_under_tmux <pid>… — of the pids given, print those whose ancestry
# reaches a live tmux server, i.e. the ones running inside a live PANE (issue
# #550). A tmux server is the parent of every pane's shell, so this is the one
# liveness signal that does not depend on a window option being set yet: during an
# account rotation's close→resume gap the new window exists with no @issue binding
# and a pane_current_path that has not settled, and every tmux-metadata gate reads
# it as dead while a very much alive claude runs under it.
#
# ONE `ps` snapshot — parent map and server set from the same rows, so the two can
# never disagree — walked upward per pid with a hop cap (a table read while the
# machine forks can contain a cycle). `want` is SPACE-joined because macOS awk
# rejects a literal newline inside a -v assignment. No usable ps → prints nothing,
# which leaves every caller exactly as conservative as it was before this existed.
fleet_pids_under_tmux() {
  [ "$#" -gt 0 ] || return 0
  ps -eo pid=,ppid=,comm= 2>/dev/null | awk -v want="$(printf '%s ' "$@")" '
    { p = $1 + 0; par[p] = $2 + 0
      c = $3; sub(/.*\//, "", c)
      if (c == "tmux" || c ~ /^tmux:/) srv[p] = 1 }
    END {
      m = split(want, w, /[ \t\n]+/)
      for (i = 1; i <= m; i++) {
        pid = w[i] + 0; if (pid <= 1) continue
        p = pid; hops = 0
        while (p > 1 && hops++ < 64) {
          if (srv[p]) { print pid; break }
          if (!(p in par)) break
          q = par[p]; if (q == p) break
          p = q
        }
      }
    }'
}

# fleet_worktree_live_procs <dir> — the pids anchored to <dir> that are running
# under a live tmux pane, space-separated (empty = nothing live in there). This is
# the janitor's THIRD liveness gate (issue #550): the first two ask tmux what it
# thinks is bound where, this one asks the process table what is actually running.
fleet_worktree_live_procs() {
  local pids; pids="$(_fleet_worktree_anchored_pids "${1:-}")"
  [ -n "$pids" ] || return 0
  # shellcheck disable=SC2086
  fleet_pids_under_tmux $pids | tr '\n' ' ' | sed 's/ *$//'
}

# ---- rotation lease: "this worktree is mid-account-move" (issue #550) ---------
# An account rotation (bin/fleet-migrate.sh) is a CLOSE + RESUME, never an in-place
# swap: the window is asked to /exit, the SessionEnd hook closes it, and a NEW
# window is opened and re-bound seconds later. Through that gap the worktree has no
# window, no @issue binding and — for part of it — no process at all, so it reads
# to any timer-driven reaper exactly like a worker that finished. On 2026-09-11 the
# janitor ran inside one and swept 15 pids of a live worker, claude included.
#
# The lease is the one thing a scan cannot infer: the mover STATES that the gap is
# deliberate. It is a hint that fails OPEN — TTL-bounded (FLEET_ROTATE_LEASE_TTL,
# default 900s, stamped in the file so a long move can ask for more) so a mover
# that dies mid-move can never make a worktree unreapable, and an unwritable state
# dir simply means no lease rather than a broken rotation.
fleet_rotate_lease_file() {   # $1=worktree dir → path (creates the dir)
  local dir="${1:-}"; [ -n "$dir" ] || return 1
  dir="${dir%/}"
  # Key on the PHYSICAL path: the mover reads the window's @worktree while the
  # janitor reads `git worktree list`, and on macOS those two can spell the same
  # directory differently (/var vs /private/var). A lease nobody can find again is
  # worse than no lease, so both sides resolve before hashing.
  local phys; phys="$(cd "$dir" 2>/dev/null && pwd -P)"; [ -n "$phys" ] && dir="$phys"
  local d="$FLEET_CONF_DIR/rotating"
  mkdir -p "$d" 2>/dev/null || return 1
  printf '%s/%s' "$d" "$(printf '%s' "$dir" | LC_ALL=C tr -c 'A-Za-z0-9._-' '_')"
}

fleet_rotate_lease_take() {   # $1=worktree dir  [$2=note]  [$3=ttl seconds]
  local f; f="$(fleet_rotate_lease_file "${1:-}")" || return 1
  printf '%s %s %s %s\n' "$$" "$(date +%s 2>/dev/null || echo 0)" \
    "${3:-${FLEET_ROTATE_LEASE_TTL:-900}}" "${2:-}" > "$f" 2>/dev/null || return 1
  return 0
}

# Transition exclusion is distinct from the janitor's TTL lease. All movers use
# transfer's atomic mkdir; a crashed owner is left for inspection, never guessed.
fleet_transition_lock_take() {
  local lock
  lock="$(fleet_rotate_lease_file "$1").transfer-lock" || return 1
  mkdir "$lock" 2>/dev/null || return 1
  printf '%s\n' "$$" > "$lock/pid"
}
fleet_transition_lock_drop() {
  local lock
  lock="$(fleet_rotate_lease_file "$1").transfer-lock" || return 1
  [ "$(cat "$lock/pid" 2>/dev/null)" = "$$" ] || return 0
  [ ! -e "$lock/request" ] || return 0
  rm -f "$lock/pid"; rmdir "$lock" 2>/dev/null || :
}

fleet_rotate_lease_drop() {   # $1=worktree dir
  local f; f="$(fleet_rotate_lease_file "${1:-}")" || return 1
  rm -f "$f" 2>/dev/null
  return 0
}

# exit 0 iff a lease on $1 exists and has not expired; prints "<age>s <note>".
# An unreadable/garbled stamp reads as epoch 0 ⇒ expired ⇒ NOT held: a lease file
# that cannot be understood must not park a worktree forever.
fleet_rotate_lease_held() {   # $1=worktree dir
  local f pid took ttl note now
  f="$(fleet_rotate_lease_file "${1:-}")" || return 1
  [ -f "$f" ] || return 1
  read -r pid took ttl note < "$f" 2>/dev/null
  case "${took:-}" in ''|*[!0-9]*) took=0 ;; esac
  case "${ttl:-}"  in ''|*[!0-9]*) ttl="${FLEET_ROTATE_LEASE_TTL:-900}" ;; esac
  now="$(date +%s 2>/dev/null || echo 0)"
  [ "$took" -gt 0 ] 2>/dev/null || return 1
  [ $((now - took)) -lt "$ttl" ] 2>/dev/null || return 1
  printf '%ss%s' "$((now - took))" "${note:+ $note}"
  return 0
}

fleet_reap_worktree_procs() {
  local dir="${1:-}" mode="${2:-kill}" grace="${3:-2}" minage="${4:-0}"
  [ -n "$dir" ] || { printf 'no worktree dir\n'; return 0; }
  dir="${dir%/}"
  # Never sweep a broad root — a bad caller must not turn this into a mass kill.
  case "$dir" in ""|/|/Users|/home|/tmp|/var|"$HOME") printf 'refused (broad root: %s)\n' "$dir"; return 0 ;; esac

  local pids p list="" tmuxpid="" livepids=""
  pids="$(_fleet_worktree_anchored_pids "$dir")"

  # Drop self, parent, pid≤1, the shared tmux server, and anything running UNDER a
  # live tmux pane → keep runnable.
  local self=$$ parent="${PPID:-0}"
  tmuxpid="$(fleet_tmux_server_pids)"
  # The pane-ancestry rail (issue #550). A process whose ancestry reaches a live
  # tmux server is a PANE's process — by definition not an orphan, whatever the
  # window's @issue binding reads at this instant. Without it the sweep is only as
  # correct as tmux's metadata: on 2026-09-11 an account rotation's close→resume
  # gap made a live worker's worktree look unbound, and this reaper killed all 15
  # of its processes — claude and the pane's shell included, so the window went
  # with them. An orphan proper (its window long gone) is reparented to init, has
  # no tmux ancestor, and is still reaped exactly as #151/#469 intend.
  #
  # The explicit reapers (dash ⌃x, the SessionEnd hook, the janitor's own prune
  # path) kill the WINDOW first, so by the time they get here the guard has nothing
  # to spare. Should one of them beat the kernel's reparenting by a moment, the cost
  # is a lingering orphan that the next hourly sweep takes — which is the deal
  # #469 already makes, and strictly cheaper than the reverse mistake.
  # shellcheck disable=SC2086
  [ -n "$pids" ] && livepids="$(fleet_pids_under_tmux $pids)"
  for p in $pids; do
    [ "$p" -gt 1 ] 2>/dev/null || continue
    [ "$p" = "$self" ] && continue
    [ "$p" = "$parent" ] && continue
    printf '%s\n' $tmuxpid | grep -qx "$p" && continue
    printf '%s\n' $livepids | grep -qx "$p" && continue
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

# ---- orphaned LISTENERS: the LAN leak (issue #1154) ----------------------------
# The reapers above find their targets THROUGH a worktree or a session scratchpad,
# and only at the moments a worktree is pruned or swept. A 2026-09-24 audit still
# found three agent-started `python3 -m http.server` orphans (PPID=1) bound to
# `*:<port>` — one serving the WHOLE scratchpad root /private/tmp/claude-<uid>
# (every session's scratch dir, to anyone on the LAN), one in a scratchpad whose
# window was long gone, one in a worktree built weeks earlier — plus four node dev
# servers on another host. Three shapes no worktree matcher can reach: a cwd that
# belongs to NO single session (the scratchpad root), a cwd whose worktree was
# already removed (lsof still reports the old path), and a KEPT worktree whose
# process outlived its window by weeks.
#
# So this half asks the question from the other end: start from the sockets. A
# LISTEN socket is rare, cheap to enumerate (one lsof for this user), and the one
# kind of orphan that is not just waste but exposure.
#
# fleet_claude_tmp_roots — Claude Code's scratchpad roots (claude-<uid>), physical
# form, one per line. FLEET_CLAUDE_TMP_ROOT overrides (the selftest's sandbox).
fleet_claude_tmp_roots() {
  if [ -n "${FLEET_CLAUDE_TMP_ROOT:-}" ]; then
    printf '%s\n' "${FLEET_CLAUDE_TMP_ROOT%/}"; return 0
  fi
  local uid d r; uid="$(id -u 2>/dev/null)"; [ -n "$uid" ] || return 0
  for d in /tmp /private/tmp "${TMPDIR:-/tmp}"; do
    r="$(cd "${d%/}/claude-$uid" 2>/dev/null && pwd -P)" && printf '%s\n' "$r"
  done | sort -u
}

# fleet_listen_anchor <cwd> — is <cwd> a place only a fleet/Claude session puts a
# process? Prints "<kind>\t<key>", or nothing:
#   scratchroot  <root>        the claude-<uid> root ITSELF — no session owns it
#   session      <mangled>     inside one session's dir under that root; <mangled>
#                              is the worktree path with / turned to - (how Claude
#                              Code names it), the key a live pane is matched on
#   worktree     <dir>         inside a fleet worktree (`…-issue-N` / `…-scratch-N`,
#                              existing or already removed) or a .fleet-trash
#   home         ~/.claude     under the Claude/fleet config tree
# A path anywhere else (an operator's own project, launchd's `/`) prints nothing —
# this is never a machine-wide listener hunt.
fleet_listen_anchor() {
  local c="${1:-}" r rest
  c="${c% (deleted)}"   # Linux /proc spells a removed cwd this way
  [ -n "$c" ] || return 0
  while IFS= read -r r; do
    [ -n "$r" ] || continue
    case "$c" in
      "$r") printf 'scratchroot\t%s\n' "$r"; return 0 ;;
      "$r"/*) rest="${c#"$r"/}"; printf 'session\t%s\n' "${rest%%/*}"; return 0 ;;
    esac
  done <<EOF
$(fleet_claude_tmp_roots)
EOF
  local wt
  wt="$(printf '%s' "$c" | awk -F/ '{
      out=""; for (i=2;i<=NF;i++) { out=out "/" $i
        if ($i ~ /-(issue|scratch)-[0-9]+$/ || $i == ".fleet-trash") { print out; exit } } }')"
  [ -n "$wt" ] && { printf 'worktree\t%s\n' "$wt"; return 0; }
  case "$c" in "$HOME/.claude"|"$HOME/.claude/"*) printf 'home\t%s\n' "$HOME/.claude" ;; esac
  return 0
}

# Legitimate fleet listeners that must never be counted or reaped: doc-preview's
# server (sticky until --stop, cwd = wherever share.sh ran), its tunnel, the fleet
# webhook receiver. FLEET_LISTEN_EXEMPT_RE extends it.
FLEET_LISTEN_EXEMPT_RE_DEFAULT='doc-preview/server\.py|cloudflared|fleet-webhook|tailscale'

# fleet_listen_rows — every TCP LISTEN socket this user owns, one row per PROCESS:
#   pid \t ppid \t age_s \t exposure \t addrs \t cwd \t argv
# exposure is the WORST of its sockets: lan (`*`, 0.0.0.0, [::], a LAN address)
# > tailnet (100.64/10, fd7a:115c:a1e0::/48 — tailscale's ranges, deliberate) >
# local (loopback). Three process-table reads, whatever the number of listeners.
fleet_listen_rows() {
  command -v lsof >/dev/null 2>&1 || return 0
  local me socks pids
  me="$(id -un 2>/dev/null)"; [ -n "$me" ] || return 0
  socks="$(lsof -nP -w -a -u "$me" -iTCP -sTCP:LISTEN -Fpn 2>/dev/null \
    | awk '/^p/{p=substr($0,2)} /^n/{print p "\t" substr($0,2)}')"
  [ -n "$socks" ] || return 0
  pids="$(printf '%s\n' "$socks" | cut -f1 | sort -un | paste -sd, -)"
  {
    printf '%s\n' "$socks" | sed 's/^/S\t/'
    lsof -w -a -p "$pids" -d cwd -Fpn 2>/dev/null \
      | awk '/^p/{p=substr($0,2)} /^n/{print "C\t" p "\t" substr($0,2)}'
    ps -o pid=,ppid=,etime=,command= -p "$pids" 2>/dev/null \
      | awk '{ a=""; for (i=4;i<=NF;i++) a=a (i>4?" ":"") $i
               print "P\t" $1 "\t" $2 "\t" $3 "\t" a }'
  } | awk -F'\t' '
    function cls(n,   a) {
      a = n; sub(/:[0-9]+$/, "", a)
      if (a ~ /^127\./ || a == "[::1]" || a == "localhost") return 1
      if (a ~ /^100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\./ || a ~ /^\[fd7a:115c:a1e0:/) return 2
      return 3 }
    function secs(et,   f, n) {
      n = split(et, f, /[-:]/)
      if (n == 4) return f[1]*86400 + f[2]*3600 + f[3]*60 + f[4]
      if (n == 3) return f[1]*3600 + f[2]*60 + f[3]
      if (n == 2) return f[1]*60 + f[2]
      return 0 }
    $1 == "S" { c = cls($3); if (c > w[$2]) w[$2] = c
                ad[$2] = (ad[$2] == "" ? $3 : ad[$2] "," $3); next }
    $1 == "C" { cw[$2] = $3; next }
    $1 == "P" { pp[$2] = $3; ag[$2] = secs($4); av[$2] = $5; next }
    END { for (p in w) {
            if (!(p in pp)) continue          # exited between the reads
            e = (w[p] == 3 ? "lan" : (w[p] == 2 ? "tailnet" : "local"))
            printf "%s\t%s\t%d\t%s\t%s\t%s\t%s\n", p, pp[p], ag[p], e, ad[p], cw[p], av[p] } }' \
    | sort -n
}

# fleet_listen_fleet_rows — fleet_listen_rows narrowed to fleet-ANCHORED, non-exempt
# listeners, with the anchor appended: … \t argv \t kind \t key. The doctor's list.
fleet_listen_fleet_rows() {
  local re="$FLEET_LISTEN_EXEMPT_RE_DEFAULT${FLEET_LISTEN_EXEMPT_RE:+|$FLEET_LISTEN_EXEMPT_RE}"
  local pid ppid age exp addrs cwd argv anc
  fleet_listen_rows | while IFS="$(printf '\t')" read -r pid ppid age exp addrs cwd argv; do
    [ -n "$pid" ] || continue
    printf '%s' "$argv" | grep -Eq "$re" && continue
    anc="$(fleet_listen_anchor "$cwd")"; [ -n "$anc" ] || continue
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$pid" "$ppid" "$age" "$exp" "$addrs" "$cwd" "$argv" "$anc"
  done
}

# _fleet_pane_cwd_keys — for every process running under a live tmux pane, and
# every live `claude` anywhere (a session outside tmux still owns its scratchpad),
# its cwd (physical) AND that cwd mangled the way Claude Code names a session dir,
# one per line. The liveness question for a worktree/session anchor: "is some
# session still working there?" Only asked when there is a candidate, so the full
# cwd read is rare.
_fleet_pane_cwd_keys() {
  local tree; tree="$(ps -eo pid=,ppid=,comm= 2>/dev/null | awk '
    { p=$1+0; par[p]=$2+0; c=$3; sub(/.*\//,"",c); if (c=="tmux"||c~/^tmux:/) srv[p]=1
      if (c=="claude" || $3 ~ /\/claude\/versions\//) cl[p]=1 }
    END { for (p in par) { if (cl[p]) { print p; continue }; q=p; h=0
            while (q>1 && h++<64) { if (srv[par[q]]) { print p; break }; q=par[q] } } }' \
    | paste -sd, -)"
  [ -n "$tree" ] || return 0
  lsof -w -a -p "$tree" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p' | sort -u \
    | while IFS= read -r c; do
        printf 'D\t%s\n' "$c"
        printf 'M\t%s\n' "$(fleet_mangle_path "$c")"
      done
}

# fleet_orphan_listeners <minage-secs> — the reap candidates: a fleet-anchored,
# non-exempt listener that has been up >= minage AND whose process tree is
# ORPHANED: walking up from it reaches init without passing a tmux server or a
# `claude` (a live pane / a live session outside tmux owns it), and the topmost
# process below init is itself fleet-anchored (so a server started from the
# operator's own terminal — Terminal.app sits below launchd with cwd `/` — is
# never taken). A worktree/session anchor is also spared while any live pane
# still has its cwd there. Rows: … \t kind \t key \t top (the pid to kill the tree of).
fleet_orphan_listeners() {
  local minage="${1:-0}" rows tops panes
  case "$minage" in ''|*[!0-9]*) minage=0 ;; esac
  rows="$(fleet_listen_fleet_rows | awk -F'\t' -v m="$minage" '$3+0 >= m')"
  [ -n "$rows" ] || return 0
  # top-below-init for each candidate, or "" when a tmux/claude ancestor owns it
  tops="$(ps -eo pid=,ppid=,comm= 2>/dev/null | awk -v want="$(printf '%s\n' "$rows" | cut -f1 | tr '\n' ' ')" '
    { p=$1+0; par[p]=$2+0; c=$3; sub(/.*\//,"",c); cm[p]=c
      # the native build runs as …/claude/versions/<semver>, so its comm is a version
      if ($3 ~ /\/claude\/versions\//) cm[p]="claude" }
    END { n=split(want, w, / +/)
      for (i=1;i<=n;i++) { p=w[i]+0; if (p<=1) continue; q=p; h=0; top=""; owned=0
        while (q>1 && h++<64) {
          if (cm[q]=="tmux" || cm[q] ~ /^tmux:/ || cm[q]=="claude") { owned=1; break }
          if (!(q in par)) break
          if (par[q]==1) { top=q; break }
          q=par[q] }
        if (!owned && top!="") print p "\t" top } }')"
  [ -n "$tops" ] || return 0
  panes="$(_fleet_pane_cwd_keys)"
  local pid ppid age exp addrs cwd argv kind key top tcwd live
  printf '%s\n' "$rows" | while IFS="$(printf '\t')" read -r pid ppid age exp addrs cwd argv kind key; do
    top="$(printf '%s\n' "$tops" | awk -F'\t' -v p="$pid" '$1==p{print $2; exit}')"
    [ -n "$top" ] || continue
    if [ "$top" != "$pid" ]; then
      tcwd="$(lsof -w -a -p "$top" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p' | head -1)"
      [ -n "$(fleet_listen_anchor "$tcwd")" ] || continue
    fi
    live=0
    case "$kind" in
      worktree) printf '%s\n' "$panes" | awk -F'\t' -v k="$key" '
                  $1=="D" && ($2==k || index($2, k "/")==1) {f=1} END{exit !f}' && live=1 ;;
      session)  printf '%s\n' "$panes" | awk -F'\t' -v k="$key" '
                  $1=="M" && ($2==k || index($2, k "-")==1) {f=1} END{exit !f}' && live=1 ;;
    esac
    [ "$live" = 1 ] && continue
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$pid" "$ppid" "$age" "$exp" "$addrs" "$cwd" "$argv" "$kind" "$key" "$top"
  done
}

# fleet_reap_orphan_listeners [kill|dry] [minage-secs] — the periodic backstop
# (diskguard's tick). Kills each candidate's WHOLE tree from its top (an `npm run
# dev` wrapper and its node child go together). Prints one line per candidate:
# "reaped|would reap <pid> <exposure> <addrs> cwd=<cwd> age=<s>s top=<top>".
fleet_reap_orphan_listeners() {
  local mode="${1:-kill}" minage="${2:-0}" pid ppid age exp addrs cwd argv kind key top
  fleet_orphan_listeners "$minage" | while IFS="$(printf '\t')" read -r pid ppid age exp addrs cwd argv kind key top; do
    [ -n "$pid" ] || continue
    [ "$top" -gt 1 ] 2>/dev/null || continue
    [ "$top" = "$$" ] && continue
    if [ "$mode" = dry ]; then
      printf 'would reap %s %s %s cwd=%s age=%ss top=%s\n' "$pid" "$exp" "$addrs" "$cwd" "$age" "$top"
    else
      fleet_kill_tree "$top" 2 >/dev/null 2>&1
      printf 'reaped %s %s %s cwd=%s age=%ss top=%s\n' "$pid" "$exp" "$addrs" "$cwd" "$age" "$top"
    fi
  done
}

# fleet_reap_worktree_listeners <dir> [wait-secs] — TEARDOWN half (issue #1154):
# called right after a worker's window is closed on a path that KEEPS its worktree
# (dirty/unmerged), where fleet_reap_worktree_procs does not run. Kills only the
# LISTENERS anchored to <dir> or its session scratchpad — the exposure — and leaves
# every other process to the kept-worktree sweep's age-gated judgement. A listener
# still under a tmux pane is spared as ever (#550); since the window was JUST
# killed, its tree may not have reparented yet, so this waits up to [wait] seconds
# (default 5) for that before giving up — the diskguard sweep is the backstop.
fleet_reap_worktree_listeners() {
  local dir="${1:-}" wait="${2:-5}" anchored lpids cand live i=0 p out=""
  [ -n "$dir" ] || return 0
  case "$wait" in ''|*[!0-9]*) wait=5 ;; esac
  while :; do
    anchored="$(_fleet_worktree_anchored_pids "$dir")"
    [ -n "$anchored" ] || break
    lpids="$(fleet_listen_rows | cut -f1)"
    cand="$(printf '%s\n' $anchored $lpids | sort -n | uniq -d)"
    [ -n "$cand" ] || break
    # shellcheck disable=SC2086
    live="$(fleet_pids_under_tmux $cand)"
    cand="$(printf '%s\n' $cand $live $live | sort -n | uniq -u)"
    for p in $cand; do
      [ "$p" -gt 1 ] 2>/dev/null || continue
      [ "$p" = "$$" ] && continue
      fleet_kill_tree "$p" 2 >/dev/null 2>&1; out="$out $p"
    done
    [ -n "$live" ] && [ "$i" -lt "$wait" ] || break
    i=$((i+1)); sleep 1
  done
  [ -n "$out" ] && printf 'reaped listeners:%s\n' "$out"
  return 0
}

# ---- retiring a worktree without paying for its bytes (issue #586) ------------
# `git worktree remove` deletes the tree SYNCHRONOUSLY, one unlink at a time. In a
# monorepo worktree that is 2.8 GB / 308k files of node_modules, and it measured
# ~0.4 files/s on a live machine: ONE teardown held the cleanup daemon for 67
# minutes on 54 seconds of CPU. That daemon is a single-process loop on
# `StartInterval=60`, so launchd will not start the next tick while the old one
# lives — and the reaping of THREE fleets stopped dead behind it: merged workers
# stayed on the dash holding their slots, and the base fast-forward (same script)
# stalled with master four commits behind, so new workers branched off a stale base.
# The second occurrence the same night was worse: the tick outlived its 300 s lease
# TTL, the next tick stole the lease and SIGTERMed it mid-unlink, leaving a
# half-deleted 359 MB orphan directory behind.
#
# So an UNATTENDED teardown never deletes a tree inline. It RENAMES it into a
# sibling `.fleet-trash/` — one `mv`, O(1), milliseconds regardless of file count —
# prunes git's admin entry so the worktree is gone from `git worktree list` at once,
# and leaves the bytes to fleet_trash_sweep, which runs under a wall-clock budget
# and can be interrupted at any point without consequence: what it does not finish
# is already OUT of the worktree list and out of everyone's way, and the next sweep
# picks it up.
#
# fleet_trash_dir <path> — the trash directory for a worktree: a `.fleet-trash`
# SIBLING of it. Sibling, not a fixed location, because a rename is only O(1) (and
# only atomic) within one filesystem, and a sibling shares one by construction.
# Fleet worktrees are siblings of the base checkout, so passing either the worktree
# or `$FLEET_MAIN` names the same trash — which is what lets the sweep find it.
fleet_trash_dir() {
  local d="${1:-}"
  [ -n "$d" ] || return 1
  d="${d%/}"
  printf '%s/.fleet-trash' "$(dirname "$d")"
}

# ---- worktree placement (issue #886) — the ONE exit for a new worktree's path ----
# Every code path that creates a worktree (issue spawn, scratch alloc, `cw`) asks
# these two functions where it goes, so moving the whole estate is one conf key,
# not three hand-built strings. Any NEW worktree-creating code must go through them.
#
# FLEET_WORKTREE_ROOT unset/empty (the default) ⇒ `<dirname main>/<basename main>-<slug>`,
# the historic sibling-of-the-base layout, byte for byte. Set ⇒
# `$FLEET_WORKTREE_ROOT/<basename main>-<slug>`: the BASENAME keeps its shape
# (`<main>-issue-N` / `<main>-scratch-N`), so everything that recognises a worktree
# by its basename — fleet_seat, fleet_scratch_key, the dash rows, the fold toggle —
# needs no change, and fleet_trash_dir (a sibling of the worktree) lands under the
# root on its own. The point of a root is a directory Spotlight skips: name it
# `*.noindex` (e.g. ~/projects/.fleet-worktrees.noindex) — fleet-doctor says so.
#
# fleet_worktree_root — the resolved root (a leading ~/ expanded, trailing / cut),
# or empty for the sibling layout.
fleet_worktree_root() {
  local r="${FLEET_WORKTREE_ROOT:-}"
  # shellcheck disable=SC2088  # a LITERAL ~ from a quoted conf value, expanded by hand
  case "$r" in
    '~')   r="$HOME" ;;
    '~/'*) r="$HOME/${r#\~/}" ;;
  esac
  while [ "${#r}" -gt 1 ] && [ "${r%/}" != "$r" ]; do r="${r%/}"; done
  printf '%s' "$r"
}

# fleet_worktree_dir <main> <slug> — the path a worktree for <slug> lives at.
#
# A shared root can hold two checkouts with the SAME basename — two hosted repos
# (issue #795: …/a/app and …/b/app both map to <root>/app-issue-12), or two
# fleets sharing one FLEET_WORKTREE_ROOT. The spawner reuses an existing dir, so
# the second repo's worker would open inside the FIRST repo's worktree. So when
# the plain path is a worktree of a DIFFERENT checkout, this main takes
# `<basename main>-r<cksum of main>-<slug>` instead, and keeps it for as long as
# that dir exists (a respawn finds its worktree again after the plain path frees
# up). The basename still ends `-issue-N` / `-scratch-N`, which is all any reader
# parses. A path that is free, or already this main's, is unchanged — so every
# fleet without a clash lays out exactly as before.
fleet_worktree_dir() {
  local main="${1:-}" slug="${2:-}" root dir alt
  [ -n "$main" ] && [ -n "$slug" ] || return 1
  root="$(fleet_worktree_root)"
  [ -n "$root" ] || root="$(dirname "$main")"
  dir="$root/$(basename "$main")-$slug"
  alt="$root/$(basename "$main")-r$(printf '%s' "${main%/}" | cksum | awk '{print $1}')-$slug"
  if [ -e "$alt" ] || { [ -e "$dir" ] && ! _fleet_wt_of "$dir" "$main"; }; then dir="$alt"; fi
  printf '%s\n' "$dir"
}

# _fleet_wt_of <dir> <main> — 0 unless <dir> is a git checkout/worktree whose
# common git dir is NOT <main>'s. A plain dir (no git) counts as <main>'s: that is
# the historic reuse, and nothing else can claim it.
_fleet_wt_of() {
  local a b
  [ -e "$1/.git" ] || return 0      # not a checkout/worktree root of its own
  a=$(cd "$1" 2>/dev/null && d=$(git rev-parse --git-common-dir 2>/dev/null) && cd "$d" 2>/dev/null && pwd -P) || return 0
  [ -n "$a" ] || return 0
  b=$(cd "$2" 2>/dev/null && d=$(git rev-parse --git-common-dir 2>/dev/null) && cd "$d" 2>/dev/null && pwd -P) || return 0
  [ "$a" = "$b" ]
}

# fleet_worktree_create <main> <slug> <base> [--reuse] [--branch <b>] — create the
# worktree for <slug> at fleet_worktree_dir, on a NEW branch (<slug>, or --branch
# for a name the slug had to flatten, e.g. `cw feat/x` → slug `feat-x`) off
# origin/<base>, falling back to the local <base>; an empty <base> = the checkout's
# HEAD. --reuse also accepts an EXISTING branch of that name (a respawn whose
# branch survived); without it, `-b` failing IS the answer — the scratch allocator
# relies on that as its serialization point. Creates the root on first use. Silent
# on both streams (under `run-shell -b` any stdout becomes an overlay over the
# dash, #401/#446); prints the worktree path on success, rc 1 on failure.
# What a new worktree gets beyond the checkout is fleet_worktree_setup's (#885).
fleet_worktree_create() {
  local main="" slug="" base="" br="" reuse=0 n=0 wt
  while [ $# -gt 0 ]; do
    case "$1" in
      --reuse)  reuse=1 ;;
      --branch) br="${2:-}"; shift ;;
      *) n=$((n + 1)); case "$n" in 1) main="$1" ;; 2) slug="$1" ;; 3) base="$1" ;; esac ;;
    esac
    shift
  done
  [ -n "$main" ] && [ -n "$slug" ] || return 1
  [ -n "$br" ] || br="$slug"
  wt="$(fleet_worktree_dir "$main" "$slug")" || return 1
  mkdir -p "$(dirname "$wt")" 2>/dev/null
  if [ -n "$base" ]; then
    git -C "$main" worktree add -b "$br" "$wt" "origin/$base" >/dev/null 2>&1 \
      || git -C "$main" worktree add -b "$br" "$wt" "$base" >/dev/null 2>&1 \
      || { [ "$reuse" = 1 ] && git -C "$main" worktree add "$wt" "$br" >/dev/null 2>&1; } \
      || return 1
  else
    git -C "$main" worktree add -b "$br" "$wt" >/dev/null 2>&1 \
      || { [ "$reuse" = 1 ] && git -C "$main" worktree add "$wt" "$br" >/dev/null 2>&1; } \
      || return 1
  fi
  fleet_worktree_setup "$main" "$wt"
  printf '%s\n' "$wt"
}

# fleet_worktree_setup <main> <wt> — the per-worktree setup hook (issue #885). When
# the conf sets FLEET_WORKTREE_SETUP, run it as `<cmd> <wt> <main>` with cwd = the
# new worktree, under fleet_timebox (FLEET_WORKTREE_SETUP_TIMEOUT, default 120 s).
# The stock one is bin/fleet-deps-link.sh (borrow the base's node_modules).
#
# It can never cost the spawn: every outcome — not found, non-zero, timed out — is
# one line in <install>/logs/worktree-setup.log and rc 0 here. Its streams go to
# that log too, because fleet_worktree_create must stay silent on both (#401/#446).
# A relative path resolves against the install root (`bin/fleet-deps-link.sh`), a
# bare name against bin/, a leading ~/ against $HOME. Unset (the default) = no-op.
fleet_worktree_setup() {
  local main="${1:-}" wt="${2:-}" cmd="${FLEET_WORKTREE_SETUP:-}" budget bin log rc
  [ -n "$cmd" ] && [ -n "$wt" ] || return 0
  budget="${FLEET_WORKTREE_SETUP_TIMEOUT:-120}"
  case "$budget" in ''|*[!0-9]*) budget=120 ;; esac
  bin="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)"
  # shellcheck disable=SC2088  # a LITERAL ~ from a quoted conf value, expanded by hand
  case "$cmd" in
    '~/'*) cmd="$HOME/${cmd#\~/}" ;;
    /*)    ;;
    */*)   cmd="$(dirname "$bin")/$cmd" ;;
    *)     cmd="$bin/$cmd" ;;
  esac
  log="${FLEET_WORKTREE_SETUP_LOG:-$(dirname "$bin")/logs/worktree-setup.log}"
  mkdir -p "$(dirname "$log")" 2>/dev/null
  {
    printf '%s start %s (%s)\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$wt" "$cmd"
    if [ -x "$cmd" ]; then
      ( cd "$wt" && fleet_timebox "$budget" "$cmd" "$wt" "$main" ) </dev/null 2>&1; rc=$?
    else
      printf 'not executable: %s\n' "$cmd"; rc=127
    fi
    case "$rc" in
      0)   printf '%s ok %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$wt" ;;
      124) printf '%s TIMEOUT after %ss %s — spawn continues\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$budget" "$wt" ;;
      *)   printf '%s FAILED rc=%s %s — spawn continues\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$rc" "$wt" ;;
    esac
  } >>"$log" 2>&1
  return 0
}

# fleet_base_deps_on — rc 0 iff this (loaded) fleet keeps its BASE checkout's
# dependencies installed from the current lockfile (issue #961): base-sync then
# runs `fleet-deps-link.sh --refresh-base` after each tick. FLEET_BASE_DEPS=1/0 says
# so explicitly; unset, it follows the stock shared-deps hook — on exactly when
# FLEET_WORKTREE_SETUP runs fleet-deps-link, whose links are only safe if the tree
# they point into keeps up with master. Anything else: off (the historic default).
fleet_base_deps_on() {
  case "${FLEET_BASE_DEPS:-}" in
    1) return 0 ;;
    0) return 1 ;;
  esac
  case "${FLEET_WORKTREE_SETUP:-}" in *fleet-deps-link*) return 0 ;; esac
  return 1
}

# fleet_base_off_branch <main> <base> — rc 0 iff the base checkout at <main> is
# NOT on <base> (issue #1044), printing what it IS on: the branch name, or
# `detached HEAD`. rc 1 = on <base> (prints nothing) or <main> is unreadable.
# Every base-mover (base-sync, the cleaner) asks this BEFORE `pull --ff-only`,
# because the pull follows whatever branch is checked out: a base left on a side
# branch is level with ITS OWN upstream, so the pull is a clean no-op that reads
# "already current" forever while the real base branch runs away (2026-09-23: the
# monorepo base sat 834 commits behind for 10 days on an ops/* branch).
fleet_base_off_branch() {
  git -C "$1" rev-parse --git-dir >/dev/null 2>&1 || return 1
  local cur
  cur=$(git -C "$1" symbolic-ref --quiet --short HEAD 2>/dev/null) || cur="detached HEAD"
  [ "$cur" = "$2" ] && return 1
  printf '%s\n' "$cur"
}

# fleet_worktree_drop <main> <worktree-dir> [--force] — retire a worktree WITHOUT
# paying for its bytes. Prints exactly one token; rc 0 ⇔ the worktree is gone from
# `git worktree list`:
#
#   trashed:<path>   renamed into .fleet-trash/ — the normal path
#   removed:<dir>    the rename was impossible (unwritable parent, a mount point,
#                    a cross-device layout) so it fell back to the old synchronous
#                    `git worktree remove --force` rather than leave debris behind
#   gone             nothing there — the admin entry is pruned anyway (idempotent)
#   dirty            rc 1: uncommitted or untracked work and no --force. Same gate
#                    plain `git worktree remove` (without -f) enforces: never move
#                    someone's unsaved work out from under them.
#   error:<reason>   rc 2 (usage, a refused broad root, no main checkout, failure)
#
# The dirty gate is the ONLY thing --force overrides; nothing here is destructive
# by itself — the bytes survive in the trash until a sweep gets to them.
fleet_worktree_drop() {
  local main="" dir="" force=0 a
  for a in "$@"; do
    case "$a" in
      --force|-f) force=1 ;;
      -*)         printf 'error:bad-flag\n'; return 2 ;;
      *)          if [ -z "$main" ]; then main="$a"; elif [ -z "$dir" ]; then dir="$a"; fi ;;
    esac
  done
  [ -n "$main" ] && [ -n "$dir" ] || { printf 'error:usage\n'; return 2; }
  dir="${dir%/}"
  # Never accept a broad root — a caller with an empty variable must not turn this
  # into a mass mv (the same refusal fleet_reap_worktree_procs makes).
  case "$dir" in
    ''|/|.|..|"$HOME"|/Users|/home|/tmp|/var|/private) printf 'error:refused\n'; return 2 ;;
  esac
  [ -e "$main/.git" ] || { printf 'error:no-main\n'; return 2; }

  if [ ! -e "$dir" ]; then
    git -C "$main" worktree prune >/dev/null 2>&1
    printf 'gone\n'; return 0
  fi

  if [ "$force" != 1 ]; then
    local st rc
    st=$(git -C "$dir" status --porcelain 2>/dev/null); rc=$?
    [ "$rc" -eq 0 ] || { printf 'error:not-a-worktree\n'; return 2; }
    [ -n "$st" ] && { printf 'dirty\n'; return 1; }
  fi

  # Borrowed dependencies (issue #885): a node_modules that is a LINK into the base
  # checkout goes as a link — removed here, before the tree moves, so neither the
  # trash sweep's rm -rf nor the `worktree remove` fallback below ever holds a path
  # into the base's live tree. Only what fleet-deps-link recorded, and only a link.
  local gd l
  gd=$(git -C "$dir" rev-parse --absolute-git-dir 2>/dev/null)
  if [ -n "$gd" ] && [ -f "$gd/fleet-deps-links" ]; then
    while IFS= read -r l; do
      case "$l" in ''|/*|..|../*|*/../*|*/..) continue ;; esac
      [ "$l" = . ] && l="$dir/node_modules" || l="$dir/$l/node_modules"
      [ -L "$l" ] && rm -f "$l"
    done < "$gd/fleet-deps-links"
  fi

  local trash target n=0
  trash="$(fleet_trash_dir "$dir")"
  if mkdir -p "$trash" 2>/dev/null; then
    # Self-ignoring: a layout that parks worktrees INSIDE a checkout would otherwise
    # make the trash show up as untracked in every `git status` (and read as dirty
    # to the gate above). A `.gitignore` of `*` covers itself, so the directory has
    # no non-ignored content and git stops reporting it, wherever it lands.
    [ -f "$trash/.gitignore" ] || printf '*\n' > "$trash/.gitignore" 2>/dev/null
    target="$trash/${dir##*/}.$(date +%s 2>/dev/null || echo 0).$$"
    while [ -e "$target" ] && [ "$n" -lt 99 ]; do
      n=$((n + 1)); target="$trash/${dir##*/}.$(date +%s 2>/dev/null || echo 0).$$.$n"
    done
    if mv "$dir" "$target" 2>/dev/null; then
      git -C "$main" worktree prune >/dev/null 2>&1
      printf 'trashed:%s\n' "$target"; return 0
    fi
  fi

  # Rename impossible → the old synchronous delete. Slow, but a worktree left
  # behind is worse: it holds a dash slot and blocks the next spawn on that issue.
  if git -C "$main" worktree remove --force "$dir" >/dev/null 2>&1; then
    git -C "$main" worktree prune >/dev/null 2>&1
    printf 'removed:%s\n' "$dir"; return 0
  fi
  printf 'error:drop-failed\n'; return 2
}

# fleet_trash_sweep <main-or-worktree> [budget_seconds] — delete what
# fleet_worktree_drop set aside, under a WALL-CLOCK BUDGET. This is the ONLY place
# the fleet pays for those bytes, and it pays in bounded instalments: an entry the
# budget cuts short stays half-deleted in the trash and the next sweep continues it.
# That is safe precisely because a trashed tree is already unlinked from git's
# worktree list — nothing waits on it.
#
# Budget: $2, else $FLEET_TRASH_SWEEP_BUDGET, else 20 s; 0 ⇒ unbudgeted.
# Prints "swept:<n> left:<m>" and always returns 0 — a janitor never fails its
# caller. Dotfiles are skipped, which is what keeps the trash's own .gitignore.
#
# SLOW PURGE (issue #893), off unless $FLEET_TRASH_PURGE_PER_TICK is a positive N.
# A trashed worktree with its node_modules is ~200k unlinks, and emptying several
# in one go floods the file-event daemon (fseventsd) exactly the way an install
# does. Set, the sweep deletes at most N entries per call (the rest are `left:`),
# each under `nice -n 19`, and defers the WHOLE call — "swept:0 left:<m>
# deferred:load <x>/core" — when the 1-minute load per core is over
# $FLEET_TRASH_PURGE_MAX_LOAD (default 1; 0 ⇒ never defer). Deferral is the one
# thing an urgent caller must be able to override: $FLEET_TRASH_PURGE_URGENT=1
# (the cleanup daemon sets it when the disk gate is closed) drops both the cap and
# the load check, because the bytes in the trash are what frees a full disk.
fleet_trash_sweep() {
  local main="${1:-}" budget="${2:-${FLEET_TRASH_SWEEP_BUDGET:-20}}"
  case "$budget" in ''|*[!0-9]*) budget=20 ;; esac
  [ "$budget" -gt 0 ] || budget=86400
  [ -n "$main" ] || { printf 'swept:0 left:0\n'; return 0; }
  local cap="${FLEET_TRASH_PURGE_PER_TICK:-0}" maxload="${FLEET_TRASH_PURGE_MAX_LOAD:-1}"
  case "$cap" in ''|*[!0-9]*) cap=0 ;; esac
  case "$maxload" in ''|*[!0-9.]*) maxload=1 ;; esac
  [ "${FLEET_TRASH_PURGE_URGENT:-0}" = 1 ] && cap=0
  # Two trashes when FLEET_WORKTREE_ROOT is set (issue #886): the root's, where
  # every worktree created since lives and is dropped, and the base's sibling one,
  # which still holds whatever was created before the root was switched on.
  local trash root rtrash; trash="$(fleet_trash_dir "$main")"
  root="$(fleet_worktree_root)"
  rtrash=""; [ -n "$root" ] && rtrash="$root/.fleet-trash"
  [ "$rtrash" = "$trash" ] && rtrash=""

  local deadline swept=0 left=0 t e remaining per="" nice_n=0
  if [ "$cap" -gt 0 ]; then
    nice_n=19
    per="$(_fleet_load_per_core)"
    if [ -n "$per" ] && awk -v p="$per" -v m="$maxload" 'BEGIN{ exit !(m > 0 && p > m) }'; then
      for t in "$trash" "$rtrash"; do
        case "${t##*/}" in .fleet-trash) ;; *) continue ;; esac
        for e in "$t"/*; do [ -e "$e" ] && left=$((left + 1)); done
      done
      [ "$left" -gt 0 ] || { printf 'swept:0 left:0\n'; return 0; }
      printf 'swept:0 left:%s deferred:load %s/core\n' "$left" "$per"
      return 0
    fi
  fi
  deadline=$(( $(date +%s 2>/dev/null || echo 0) + budget ))
  for t in "$trash" "$rtrash"; do
    case "${t##*/}" in .fleet-trash) ;; *) continue ;; esac
    [ -d "$t" ] || continue
    for e in "$t"/*; do
      [ -e "$e" ] || continue                     # empty trash → the glob is literal
      if [ "$cap" -gt 0 ] && [ "$swept" -ge "$cap" ]; then left=$((left + 1)); continue; fi
      remaining=$(( deadline - $(date +%s 2>/dev/null || echo 0) ))
      if [ "$remaining" -le 0 ]; then left=$((left + 1)); continue; fi
      if fleet_timebox "$remaining" nice -n "$nice_n" rm -rf "$e" >/dev/null 2>&1; then
        swept=$((swept + 1))
      else
        left=$((left + 1))                        # timed out mid-delete — next sweep
      fi
    done
  done
  printf 'swept:%s left:%s\n' "$swept" "$left"
  return 0
}

# _fleet_load_per_core → the 1-minute load average divided by the core count, two
# decimals, or empty when the load is unreadable (the caller then does not defer).
# Same sources as fleet-diskguard.sh's machine_load/machine_cores (macOS sysctl,
# Linux /proc).
_fleet_load_per_core() {
  local c l
  c=$({ sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null; } \
      | head -1 | awk '{ n=$1+0; print (n>0 ? n : 1) }')
  l=$({ sysctl -n vm.loadavg 2>/dev/null | tr -d '{}' || awk '{print $1}' /proc/loadavg 2>/dev/null; } \
      | head -1 | awk '{ print $1 }')
  case "$l" in ''|*[!0-9.]*) return 0 ;; esac
  awk -v l="$l" -v c="${c:-1}" 'BEGIN{ printf "%.2f", l / c }'
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

# ---- repo-qualified keys + self-stamping windows (issue #789) ----------------
# _fleet_hosts_many <sess> → 0 iff the fleet hosts 2+ repos. No repos/ dir ⇒ 1 before
# reading any conf, so a one-repo fleet pays nothing (the degenerate case).
_fleet_hosts_many() { fleet_multirepo "$@"; }   # one rule for every key (#790)

# _fleet_key_prefix <sess> <window-target> → "" in a one-repo fleet, "<slug>:" of the
# window's repo in a 2+ repo fleet; exit 1 there when the window's repo is unknown or
# it is a no-repo session — the caller then mints no key rather than guess.
_fleet_key_prefix() {
  local r
  _fleet_hosts_many "${1:-}" || return 0
  r=$(fleet_window_repo "${1:-}" "${2:-}")
  [ -n "$r" ] || return 1
  printf '%s:' "$(fleet_slug "$r")"
}

# fleet_win_stamp_cmd <opt> <val> [<opt> <val>…] → shell text a new window's OWN
# command runs first, stamping window options on itself before the launcher reads
# them. fleet_load_conf is window-aware (#788), so a spawner's set-option AFTER
# new-window races the launcher: a repo-B session would load repo A's trust, model and
# MCP. Bare tmux + $TMUX_PANE: inside the pane both name its own server and window.
fleet_win_stamp_cmd() {
  local out='' v
  while [ "$#" -ge 2 ]; do
    v=$(printf '%s' "$2" | sed "s/'/'\\\\''/g")
    out="${out}tmux set-option -w -t \"\$TMUX_PANE\" $1 '$v' 2>/dev/null; "
    shift 2
  done
  printf '%s' "$out"
}

# fleet_origin_key — spawn provenance (issue #503): which fleet session is running
# THIS script? Prints the CALLER's own ledger key — `issue-<N>` when the calling
# pane's window carries @issue, `scratch-<N>` when it sits in a scratch worktree
# (key derived from @worktree, else the pane cwd, via the STRICT fleet_scratch_key;
# NO @raw precondition — see below) — and prints NOTHING for everything else: the
# dash/backlog/plan panels, the hub, a headless caller (no $TMUX). Empty ≡ "hub"
# everywhere downstream (@origin unset, blank ledger column), so the operator's own
# spawns stay untagged.
# Spawn scripts call this in their FOREGROUND pass — a run-shell -b / fleet_bg
# tail has no caller pane, so the detected value must ride a --origin flag into
# any backgrounded re-invocation. Bare tmux on purpose: inside a pane $TMUX
# already names the right per-fleet socket (the CLAUDE.md socket rail).
#
# In a fleet that hosts 2+ repos (issue #789) the key is repo-qualified —
# `<slug>:issue-<N>` / `<slug>:scratch-<N>`, slug = fleet_slug(owner/name) — since
# issue-12 and scratch-4 exist once PER REPO there. A window whose repo is unknown
# yields NOTHING (≡ hub) rather than a bare key that could name the other repo's
# window. A one-repo fleet's keys are unchanged.
fleet_origin_key() {
  [ -n "${TMUX:-}" ] && [ -n "${TMUX_PANE:-}" ] || return 0
  local o iss owt path k pre
  o=$(tmux display-message -p -t "$TMUX_PANE" \
        '#{@issue}|#{@worktree}|#{pane_current_path}' 2>/dev/null)
  [ -n "$o" ] || return 0
  iss=${o%%|*}; o=${o#*|}; owt=${o%%|*}; path=${o#*|}
  pre=$(_fleet_key_prefix "$(fleet_current_session)" "$TMUX_PANE") || return 0
  case "$iss" in
    ''|*[!0-9]*) : ;;
    *) printf '%sissue-%s' "$pre" "$iss"; return 0 ;;
  esac
  # Scratch: @worktree first (the stamped path), else the pane cwd — deliberately
  # WITHOUT an @raw=1 gate. A crash-restored scratch carries neither @raw nor
  # @worktree (fleet-restore.sh re-stamps only @issue/@origin/@claude_state), yet
  # its cwd IS the scratch worktree — the very path-only rule the dash's okey_v keys
  # the PARENT side by. Gated on @raw, every spawn from such a window read as
  # hub-spawned (#4594 on the monorepo dash, filed from a restored scratch-28).
  # fleet_scratch_key is STRICT (…-scratch-<digits> only), so a plain window whose
  # cwd is the base checkout never keys as a scratch.
  k=$(fleet_scratch_key "$owt")
  [ -z "$k" ] && k=$(fleet_scratch_key "$path")
  [ -n "$k" ] && printf '%s%s' "$pre" "$k"
  return 0
}

# fleet_origin_canon <explicit> <detected> [<target-sess>] [<src-sess>] — the ONE
# provenance decision both spawners make (dash-issue-session.sh, dash-raw-session.sh);
# prints the value to stamp into @origin (empty ≡ hub).
#   <explicit>   the caller's --origin, if any. Headless callers state theirs (the
#                dispatcher `autofill`, the bridge `bridge`, a backgrounded tail the
#                key its foreground pass resolved). A Claude in a pane that read the
#                spawner's header tends to pass one too — and gets it wrong: the
#                live #4591 spawn passed its worktree BASENAME, `cd-conductor-
#                scratch-52`, which the dash can neither nest under nor resolve (it
#                groups by KEY: issue-<N> / scratch-<N>), so the row showed a bare
#                `↳cd-conductor-scratch-52` tag and no parent. So an explicit value
#                is CANONICALIZED: `…-scratch-<N>`/`scratch-<N>` → scratch-<N>,
#                `…issue-<N>` → issue-<N>; a canonical key and the known literals
#                pass through (`hub` → empty: stamp nothing, issue #896); anything else yields to <detected> when there is
#                one (a stderr warning names the swap — a Claude caller sees it in
#                its tool output) and is otherwise kept as a free-form label
#                (`↳<label>`, no nesting — how a source-fleet name renders).
#   <detected>   fleet_origin_key's pane-derived key, or empty.
#   <target-sess> <src-sess>  the #516 cross-fleet rule: a detected key names a
#                window in the SPAWNER's fleet, so when the target is a different
#                fleet the SOURCE fleet name is stamped instead. Applies to whatever
#                was detected — including the garbage-explicit fallback — never to
#                an explicit key (honoured as given, per #516).
# Always sanitized to the key charset (window option + run-shell embed), ≤32 chars.
fleet_origin_canon() {
  local ex="${1:-}" det="${2:-}" tgt="${3:-}" src="${4:-}" k n pre=''
  # A repo-qualified key (issue #789, `<slug>:issue-<N>` / `<slug>:scratch-<N>`) keeps
  # its prefix; the rest canonicalizes as below. ':' survives ONLY in that shape.
  case "$ex" in
    ?*:?*) pre=$(printf '%s' "${ex%%:*}" | LC_ALL=C tr -cd 'A-Za-z0-9._-' | cut -c1-96)
           [ -n "$pre" ] && ex=${ex#*:} ;;
  esac
  ex=$(printf '%s' "$ex" | LC_ALL=C tr -cd 'A-Za-z0-9._-' | cut -c1-32)
  if [ -n "$pre" ]; then
    k=$(fleet_scratch_key "$ex")
    case "$ex" in issue-*) n=${ex#issue-}; case "$n" in ''|*[!0-9]*) : ;; *) k="issue-$n" ;; esac ;; esac
    if [ -n "$k" ]; then printf '%s:%s' "$pre" "$k"; return 0; fi
    ex=$(printf '%s%s' "$pre" "$ex" | cut -c1-32)   # not a key: fold back, as before
  fi
  [ -n "$det" ] && [ -n "$tgt" ] && [ -n "$src" ] && [ "$src" != "$tgt" ] && det=$src
  [ -z "$ex" ] && { printf '%s' "$det"; return 0; }
  case "$ex" in autofill|bridge) printf '%s' "$ex"; return 0 ;; esac
  # `hub` (issue #896): the caller IS the hub's ⌃s by another road — the worker
  # sidebar's input line runs inside a worker's window, so detection would nest
  # the new session under that worker. Empty ≡ hub, whatever was detected.
  [ "$ex" = hub ] && return 0
  k=$(fleet_scratch_key "$ex")                    # scratch-<N> and *-scratch-<N>
  if [ -z "$k" ]; then
    case "$ex" in
      *issue-*) n=${ex##*issue-}; case "$n" in ''|*[!0-9]*) : ;; *) k="issue-$n" ;; esac ;;
    esac
  fi
  if [ -n "$k" ]; then printf '%s' "$k"; return 0; fi
  if [ -n "$det" ]; then
    printf 'fleet: --origin %s is not a provenance key (issue-<N> / scratch-<N>); stamping the detected %s instead\n' "$ex" "$det" >&2
    printf '%s' "$det"; return 0
  fi
  printf '%s' "$ex"
}

# fleet_win_for_key's repo gate (issue #789), run only on a window whose bare key
# already matched: no prefix ⇒ any window; a prefix ⇒ the window's repo must be KNOWN
# and carry that slug. Reads the caller's $pre/$wsess/$wid (bash dynamic scope).
_fleet_wfk_repo_ok() {
  [ -n "$pre" ] || return 0
  local r; r=$(fleet_window_repo "$wsess" "$wid")
  [ -n "$r" ] && [ "$(fleet_slug "$r")" = "$pre" ]
}

# fleet_win_for_key <key> [socket] — the INVERSE of fleet_origin_key (issue #574):
# a provenance key (`issue-<N>` / `scratch-<N>`) → the window id currently carrying
# it on THIS fleet's socket, or nothing (exit 1). @origin has been stamped on every
# spawned window since #503, but every consumer of it was display/archive (the dash's
# `↳#483` tag + grouping, the ledger's provenance column) — nothing ever resolved it
# back to a LIVE window. That resolution is what turns @origin into an ADDRESS, so a
# finished child can push its outcome to the session that spawned it instead of the
# parent polling for it.
#
# SCOPE is this socket, i.e. this fleet — which is the whole truth a key carries: a
# key names a window in the fleet that minted it (#516 stamps the SOURCE FLEET NAME,
# not a key, when a spawn crosses fleets, so a cross-fleet origin never reaches the
# key branch here). `-a`: the server, matching fleet_wid_used — a warm-pool window
# carries neither @issue nor a scratch worktree, so it can never answer to a key.
#
# Matching mirrors the two readers that already exist, so the three never disagree:
#   issue-<N>    the window's @issue (what the spawner binds, fleet_origin_key's
#                first branch)
#   scratch-<N>  @worktree FIRST, pane cwd as the fallback, through the SAME strict
#                digits-only basename rule as fleet_scratch_key / the dash's okey_v
#                (inlined here for the same reason okey_v inlines it: no subshell
#                per window)
# First match wins; the spawners already refuse a second window for a bound issue.
fleet_win_for_key() {
  local key="${1:-}" sock="${2:-}" wl line wid rest iss wt path cand bn sn pre='' wsess
  # `<slug>:<key>` (issue #789): match the bare key, then require the window's repo.
  case "$key" in ?*:?*) pre=${key%%:*}; key=${key#*:} ;; esac
  case "$key" in
    issue-*|scratch-*) sn=${key#*-}; case "$sn" in ''|*[!0-9]*) return 1 ;; esac ;;
    *) return 1 ;;
  esac
  # window_name is NOT read here: the free-text field would have to ride the same
  # `|` separator (a tab/0x1f separator prints as a literal `\037` on tmux ≤3.4).
  if [ -n "$sock" ]; then
    wl=$(tmux -L "$sock" list-windows -a -F '#{window_id}|#{session_name}|#{@issue}|#{@worktree}|#{pane_current_path}' 2>/dev/null)
  else
    wl=$(tmux list-windows -a -F '#{window_id}|#{session_name}|#{@issue}|#{@worktree}|#{pane_current_path}' 2>/dev/null)
  fi
  [ -n "$wl" ] || return 1
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    wid=${line%%|*};  rest=${line#*|}
    wsess=${rest%%|*}; rest=${rest#*|}
    iss=${rest%%|*};  rest=${rest#*|}
    wt=${rest%%|*};   path=${rest#*|}
    case "$key" in
      issue-*)
        [ -n "$iss" ] && [ "issue-$iss" = "$key" ] && _fleet_wfk_repo_ok && { printf '%s' "$wid"; return 0; }
        ;;
      scratch-*)
        for cand in "$wt" "$path"; do
          bn=${cand##*/}
          case "$bn" in
            scratch-*)   sn=${bn#scratch-} ;;
            *-scratch-*) sn=${bn##*-scratch-} ;;
            *)           continue ;;
          esac
          case "$sn" in ''|*[!0-9]*) continue ;; esac
          [ "scratch-$sn" = "$key" ] && _fleet_wfk_repo_ok && { printf '%s' "$wid"; return 0; }
        done
        ;;
    esac
  done <<EOF
$wl
EOF
  return 1
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

  # Resolve the merged PR for the branch when the caller didn't hand us one
  # (worktree-autoclean knows the branch, not the PR number). Hoisted out of the
  # record case below so the lifecycle emit and the ledger row report the same
  # PR number — the emit runs even on installs where fleet-history.sh is absent.
  if [ -z "$pr" ] && [ -n "$branch" ] && [ -n "$repo" ] && command -v gh >/dev/null 2>&1; then
    case "$outcome" in
      merged-pr|merged-PR|merged)
        pr="$(gh -R "$repo" pr list --head "$branch" --state merged \
                --json number -q '.[0].number' 2>/dev/null)" ;;
    esac
  fi

  # THE session.end LIFECYCLE FACT (issue #625). This function is the ONE choke
  # point every reaper funnels through — the SessionEnd hook's detached --exec, the
  # dash ⌃x reap, the cleanup daemon, ledger-watch — so hanging the emit here is
  # what keeps "how the work ended" a single source of truth instead of a fifth
  # copy of the reap rules. `via=reap` distinguishes it from the SessionEnd hook's
  # `via=hook` end, which knows the Claude session id and the CLI's reason but not
  # the outcome; together they are the whole picture. Off unless the fleet
  # configured an endpoint, and it can never affect the reap (the row still gets
  # written below, whatever this does).
  local _oc=''
  case "$outcome" in
    merged-pr|merged-PR|merged)             _oc=landed ;;
    ancestor|ancestor-of-*|unmerged|dirty|live)  _oc=closed-unlanded ;;
  esac
  if [ -n "$_oc" ] && [ -n "$_bin" ] && [ -f "$_bin/fleet-emit.sh" ]; then
    bash "$_bin/fleet-emit.sh" session.end --via reap \
      --session "$sess" --repo "$repo" --issue "$issue" --pr "$pr" \
      --branch "${branch:-$key}" --outcome "$_oc" --verdict "$outcome" \
      >/dev/null 2>&1 || :
  fi

  hist="$_bin/fleet-history.sh"
  [ -f "$hist" ] || return 0
  case "$outcome" in
    merged-pr|merged-PR|merged)
      bash "$hist" record --repo "$repo" --main "$main" --session "$sess" \
        --pr "$pr" --key "$key" --worktree "$wt" --win "$win" \
        --title "$title" --origin "$origin" >/dev/null 2>&1 || return 0
      ;;
    ancestor|ancestor-of-*|unmerged|dirty|live)
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
# Forkless for the common case (issue #888): a value already made only of ASCII
# letters, digits, `.`, `_`, `-` and `/` loses nothing to `tr -cd`, so swapping
# `/` → `-` is the whole job. Anything else keeps the original two `tr`s, so
# their locale's idea of [:alnum:] still decides.
fleet_slug() {
  case "${1:-}" in
    *[!abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._/-]*)
      printf '%s' "$1" | tr '/' '-' | tr -cd '[:alnum:]._-' ;;
    *) printf '%s' "${1//\//-}" ;;
  esac
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
# DESCRIPTIONS ARE READ BY STRANGERS (issue #678). This set is seeded into every
# fleet repo, and a fleet repo is not always the operator's own sandbox — on a
# TEAM repo these labels appear in the label picker of people who have never
# heard of claude-fleet. So each description says what the label MEANS and who
# acts on it in plain words, and names claude-fleet where the actor is the fleet
# rather than a human; "the autofill dispatcher" told a teammate nothing.
# `epic` is the tracking parent of a planned batch (`/fleet-epic`): the EPIC
# issue carries it, each slice is an ordinary sub-issue underneath.
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
blocked|b60205|Blocked on other work — claude-fleet skips it when picking what to start next
autoland|0e8a16|Opt this issue's PR into hands-off auto-land
autofill|0e8a16|Opt this issue into hands-off auto-start: claude-fleet spawns a worker for it when a slot frees
epic|8250DF|Tracking parent for a batch of sub-issues planned and run together by claude-fleet
EOF
}

# fleet_labels_allowed — just the label NAMES from the canonical taxonomy, one
# per line. The issue-filer channel validates against THIS fixed set (fixed
# seed, no minting, #333) — no `gh label list` round-trip, deterministic offline.
fleet_labels_allowed() {
  fleet_labels_canonical | cut -d'|' -f1
}

# issue title → short kebab window name. Used to name a session's tmux window
# after the issue CONTENT instead of a bare "issue-<N>". Prints empty when the
# title carries no usable LETTER/DIGIT content (emoji-only, punctuation-only) —
# every caller falls back to its own slug (issue-<N> / scratch-<N> / the branch).
#
# UTF-8 AWARE since issue #579. The old filter was `LC_ALL=C tr -c 'a-z0-9\n' '-'`,
# which is BYTE-wise: every byte of a 3-byte CJK codepoint fails the a-z0-9 test,
# so a fully-Chinese title collapsed to hyphens → squeezed → stripped → EMPTY, and
# on a Chinese-language fleet EVERY worker window degraded to `issue-<N>` (the dash
# then showed a column of numbers with no hint of what any worker was doing). The
# rest of the CJK story is already told (#432 column widths, #429/#422 echo, #408
# locale, #534 the dash window cell) — the window NAME was the last place still
# throwing multibyte text away.
#
# The rule now: keep Unicode letters/digits (\p{Alnum}) plus combining marks
# (\p{M}, so Indic/Thai graphemes survive intact); map every other run — spaces,
# punctuation, symbols, EMOJI — to a single '-'. Emoji and punctuation are NOT
# letters, so a `★★★` or 🎉-only title still washes out to empty and still takes
# the caller's slug fallback, exactly as before.
#
# Three invariants this must not break:
#   • DETERMINISTIC — same title in, byte-identical name out, forever and on any
#     machine/locale (perl decodes UTF-8 explicitly; `lc` is Unicode-default, not
#     locale-sensitive). bin/fleet-restore.sh reconciles a snapshot against the
#     live window names with `grep -qxF`, so a name that drifts would make restore
#     fail to recognise a LIVE window and open a SECOND Claude on the same
#     worktree (the reason #455 rejected summary-derived names).
#   • CLIPPED BY DISPLAY WIDTH, never by bytes or codepoints — a CJK glyph is one
#     codepoint but TWO terminal columns, and `cut -c` under LC_ALL=C would slice a
#     3-byte character in half and render tofu (#422's bug class). The budget stays
#     32 but is now read as 32 COLUMNS: that is byte-identical to the old cap for
#     ASCII (width == length), and gives ~16 CJK glyphs — comfortably more than the
#     22-column window cell the dash and /fleet-history clip it to again anyway.
#     The width table is NOT re-implemented here; fleet_clip_display (#432/#534) is
#     the one copy.
#   • NEVER a RESERVED PANEL NAME — fleet_session_count/_for and the dash treat a
#     window named dash/plan/backlog as a panel, so a derived collision would make
#     the window vanish from the dash AND leak out of the session cap. An issue
#     titled exactly "Plan" could already do this in pure ASCII; now that the
#     character set is open it is guarded explicitly, by falling back to the slug.
#
# Degradation: no perl ⇒ the non-ASCII branch yields empty and the caller takes its
# slug — i.e. exactly the pre-#579 behaviour, never a crash or a mangled name.
fleet_win_name() {
  # clip_out/clip_w are fleet_clip_display's OUTPUT globals; shadowing them with
  # locals here (bash scopes dynamically, so the callee writes these) keeps a row
  # producer that is mid-render from having its own clip result stolen.
  local t="${1:-}" s cols=32 clip_out='' clip_w=0
  case "$t" in
    *[![:ascii:]]*)
      # One perl fork, and only for a title that actually carries non-ASCII. The
      # program is a pure function of $S: decode → Unicode-lowercase → keep
      # letters/digits/marks → squeeze the rest to single hyphens → trim. `exit 1
      # unless /\p{Alnum}/` is what keeps an emoji/punctuation-only title empty.
      s=$(S="$t" perl -CO -MEncode -e '
        my $s = decode_utf8($ENV{S});
        $s = lc $s;
        $s =~ s/[^\p{Alnum}\p{M}]+/-/g;
        $s =~ s/^-+//; $s =~ s/-+$//;
        exit 1 unless $s =~ /\p{Alnum}/;
        print $s;' 2>/dev/null) || s=''
      ;;
    *)
      # Pure ASCII keeps the original pipeline verbatim, so every name this fleet
      # has ever derived from an ASCII title still comes out byte-for-byte the same.
      s=$(printf '%s' "$t" \
        | LC_ALL=C tr '[:upper:]' '[:lower:]' \
        | LC_ALL=C tr -c 'a-z0-9\n' '-' \
        | LC_ALL=C tr -s '-' \
        | sed -e 's/^-//' -e 's/-$//')
      ;;
  esac
  [ -n "$s" ] || return 0
  # Clip by display width (ASCII takes fleet_clip_display's fork-free path, so this
  # is still the old `cut -c1-32` for ASCII), then drop a hyphen the cut exposed.
  fleet_clip_display "$cols" "$s"; s="${clip_out:-}"; s="${s%-}"
  # Reserved panel names — keep this set in lockstep with fleet_session_count /
  # fleet_session_count_for / the dash's panel filter.
  case "$s" in dash|plan|backlog) s='' ;; esac
  printf '%s' "$s"
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
  # portability-selftest.sh (issue #696) exempts a both-ways fallback only when it
  # is spelled on ONE logical line (`gnu … || bsd …`) — deliberately, so the
  # exemption stays local instead of scanning a window a later edit could drift
  # out of. This pair is spelled across two lines, so it carries the marker.
  date -u -d "$iso" +%s 2>/dev/null && return 0   # portable-ok: BSD form is the next line
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
fleet_slug_cached() { _fleet_sessmap_field 2 "${1:-}"; }

# CHEAP: session → repo (owner/name) from the sessmap. Prints repo or empty.
fleet_repo_cached() { _fleet_sessmap_field 3 "${1:-}"; }

# _fleet_sessmap_field <2|3> <session> — field N of the first sessmap row whose
# field 1 is <session> (what `awk -F'\t' '$1==s{print $N; exit}'` printed). Pure
# builtins (issue #888): the sessmap is a handful of rows and these are asked per
# window per tick (pr-refresh, the dash), so an awk exec each was the cost. Split
# with parameter expansion, not `read`: IFS=<tab> would fold an EMPTY field away.
_fleet_sessmap_field() {
  local sm line rest tab
  sm=$(fleet_sessmap_file)
  [ -f "$sm" ] || return 0
  tab=$(printf '\t')
  while IFS= read -r line || [ -n "$line" ]; do
    [ "${line%%"$tab"*}" = "$2" ] || continue
    case "$line" in *"$tab"*) rest="${line#*"$tab"}" ;; *) rest='' ;; esac
    if [ "$1" = 3 ]; then
      case "$rest" in *"$tab"*) rest="${rest#*"$tab"}" ;; *) rest='' ;; esac
    fi
    printf '%s\n' "${rest%%"$tab"*}"
    return 0
  done < "$sm"
  return 0
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
# A hibernated worker holds NO slot (issue #1058): a window whose
# @worker_lifecycle is `sleeping` or `failed` has no live agent, so it is left out
# and tallied apart — `fleet_session_sleepers` prints that tally (the slots chip's
# `· z8`). preparing / waking still count: the agent is (about to be) live.
# The lifecycle rides as a trailing ` @L=<value>` field, because a window NAME may
# itself hold spaces; a reader that never sees the field (no sleepers, an old
# server) counts exactly as before.
_fleet_session_tally() {   # → "<awake> <sleepers>" across every fleet
  fleet_list_windows_all '#{session_name} #{window_name} @L=#{@worker_lifecycle}' | awk '
    { rows[NR]=$0; if ($2=="plan" || $2=="dash") fleet[$1]=1 }
    END {
      for (i=1; i<=NR; i++) {
        n=split(rows[i], a, " "); s=a[1]; w=a[2]; l=""
        if (n>=3 && a[n] ~ /^@L=/) l=substr(a[n], 4)
        if (!fleet[s] || w=="dash" || w=="plan" || w=="backlog") continue
        if (l=="sleeping" || l=="failed") z++; else c++
      }
      print c+0, z+0
    }'
}
fleet_session_count() { local t; t=$(_fleet_session_tally); printf '%s\n' "${t%% *}"; }
fleet_session_sleepers() { local t; t=$(_fleet_session_tally); printf '%s\n' "${t##* }"; }

# CHEAP: count the live Claude WORKING-session windows in ONE fleet session (the
# per-fleet analogue of fleet_session_count, for issue #70's FLEET_MAX_SESSIONS).
# Only counts if the session is a real fleet (owns a 'plan'/'dash' hub window);
# inside it, dash/plan/backlog are panels, everything else is a working session —
# the same rule the dashboard and the global count use. Prints an integer (0 if
# the session isn't a fleet, doesn't exist, or tmux isn't running). Sleeping /
# failed workers are left out the same way (issue #1058).
# NB: the hub/panel names (plan/dash/backlog) AND the sleeping/failed rule are
# duplicated in _fleet_session_tally above — keep BOTH in sync, or the global and
# per-fleet caps count different sets.
_fleet_session_tally_for() {   # <sess> → "<awake> <sleepers>" in that fleet
  tmux -L "$(fleet_socket "$1")" list-windows -t "$1" -F '#{window_name} @L=#{@worker_lifecycle}' 2>/dev/null | awk '
    { l=""
      if (match($0, / @L=[^ ]*$/)) { l=substr($0, RSTART+4); name=substr($0, 1, RSTART-1) } else name=$0
      if (name=="plan" || name=="dash") hub=1; rows[NR]=name; life[NR]=l }
    END {
      if (!hub) { print 0, 0; exit }
      for (i=1; i<=NR; i++) {
        n=rows[i]
        if (n=="dash" || n=="plan" || n=="backlog") continue
        if (life[i]=="sleeping" || life[i]=="failed") z++; else c++
      }
      print c+0, z+0
    }'
}
fleet_session_count_for() { local t; t=$(_fleet_session_tally_for "$1"); printf '%s\n' "${t%% *}"; }
fleet_session_sleepers_for() { local t; t=$(_fleet_session_tally_for "$1"); printf '%s\n' "${t##* }"; }

# Cap on concurrent Claude working sessions (issues #28, #70). Returns 0 if a new
# session may be spawned, non-zero if a cap is already reached. Two ceilings:
#   • GLOBAL   FLEET_GLOBAL_MAX_SESSIONS (default 8) — SYSTEM-WIDE across all
#              fleets; 0 ⇒ unlimited. Always checked.
#   • PER-FLEET FLEET_MAX_SESSIONS (default 0 = unlimited) — checked ONLY when a
#              session name is passed as $1 (so existing no-arg callers keep the
#              global-only behaviour unchanged) AND the cap is a positive number.
# On refusal, prints a human-readable reason on stdout for the caller to surface
# (tmux display-message); prints nothing when allowed. Both ceilings count AWAKE
# workers only — a sleeper holds no slot (issue #1058, docs/WORKER-SLEEP.md) —
# and a sleeper's own wake reads them through fleet_cap_full below.
# ---- scratch worktree allocation (shared by the ⌃s spawner and the warm pool) --
# fleet_scratch_alloc <main> <base> — allocate the next free `scratch-<N>` branch
# and its worktree (fleet_worktree_dir) off origin/<base> (falling back to the local base ref
# when there is no origin). `git worktree add -b` IS the serialization point — it
# FAILS if the branch or dir already exists — so concurrent callers retry with the
# next N rather than trusting a check-then-create gap. Prints "<slug>\t<worktree>".
fleet_scratch_alloc() {
  local main="$1" base="$2" cand cwt n=1
  git -C "$main" fetch origin "$base" --quiet 2>/dev/null
  while [ "$n" -le 999 ]; do
    cand="scratch-$n"; cwt="$(fleet_worktree_dir "$main" "$cand")"
    if git -C "$main" show-ref --verify --quiet "refs/heads/$cand" 2>/dev/null || [ -e "$cwt" ]; then
      n=$((n + 1)); continue
    fi
    # No --reuse: `-b` failing on a branch a racing caller just took is the signal
    # to move on to the next N. Silent on both streams (#446).
    if fleet_worktree_create "$main" "$cand" "$base" >/dev/null; then
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

# fleet_is_pool_session <name> [socket] — true when <name> is a warm-pool HOLDING
# session, not a fleet (issue #1020). The pool shares its fleet's socket, so a
# per-socket loop (restore snapshot, the collector's sessmap) meets it beside the
# real fleet; every such reader must skip it or it grows a phantom fleet — a
# fleets/<sess>-pool/ state dir, a restore map --if-down reads as DOWN forever, a
# `○ <sess>-pool` row in fleet-list. With [socket] the test is EXACT: <name> is
# the pool of the fleet that socket belongs to. Without one (a state dir name,
# a map on disk) it inverts fleet_pool_session — never an ad-hoc suffix guess — and
# a name that has its OWN conf is a real fleet that merely ends in "-pool".
fleet_is_pool_session() {
  local n="${1:-}" own
  [ -n "$n" ] || return 1
  if [ -n "${2:-}" ]; then [ "$n" = "$(fleet_pool_session "$2")" ]; return; fi
  case "$n" in *-pool) own="${n%-pool}" ;; *) return 1 ;; esac
  [ -n "$own" ] && [ "$(fleet_pool_session "$own")" = "$n" ] || return 1
  [ ! -f "$(fleet_conf_file "$n")" ]
}

# Milliseconds since the epoch, portable. BSD `date` has no %N/%3N, so use perl
# (already a fleet dependency — the sub-second spinner needs Time::HiRes), then
# python3, then whole seconds ×1000 as a last-resort coarse fallback. Digits only.
fleet_now_ms() {
  perl -MTime::HiRes=time -e 'printf "%d\n", time()*1000' 2>/dev/null && return
  python3 -c 'import time;print(int(time.time()*1000))' 2>/dev/null && return
  echo $(( $(date +%s 2>/dev/null || echo 0) * 1000 ))
}

# fleet_spawn_is_burst <now_ms> <last_ms> <guard_ms> — 0 (true) iff this dash
# prompt-line Enter TRAILS the previous one by < guard_ms, i.e. it is one line of a
# multi-line PASTE (issue #531). A terminal delivers a paste as one Enter per line,
# fired milliseconds apart, and fzf has no bracketed-paste awareness on the input
# line — so 250 pasted lines fired 250 seeded spawns. dash-enter.sh drops a burst
# Enter and only spawns an ISOLATED one (quiet before AND after, within the guard).
# A "no prior Enter" (last_ms=0) is never a burst — the gap is huge.
fleet_spawn_is_burst() {
  local now="${1:-0}" last="${2:-0}" guard="${3:-1000}"
  case "$now$last$guard" in *[!0-9]*) return 1;; esac   # non-numeric → treat as not-a-burst
  [ "$last" -gt 0 ] && [ $((now - last)) -lt "$guard" ]
}

# In-flight scratch-spawn markers (issue #531). A spawn's SLOW half — git fetch +
# `git worktree add` + window launch — holds NO session slot until its window
# exists, so a flood of spawns (the paste storm; a wedged Enter/⌃s key) could all
# pass fleet_session_cap_ok and launch hundreds of concurrent `worktree add`s
# before the first one counted (the 2026-09-03 incident: 244 adds, cap=4 bypassed,
# disk 30→6 GB). Each spawn drops a marker for the duration of its slow half; the
# cap check counts fresh markers so concurrent spawns SEE one another. Markers are
# machine-wide like the session cache, keyed <fleet-slug>.<pid>; a crashed spawn's
# marker ages out (FLEET_INFLIGHT_TTL, default 180s) rather than wedging the cap.
FLEET_INFLIGHT_DIR="$FLEET_C/global/spawn-inflight"
fleet_inflight_mark() {   # <sess> → create a marker for THIS process; echo its path
  local sess="${1:-_}" f
  mkdir -p "$FLEET_INFLIGHT_DIR" 2>/dev/null || { printf ''; return; }
  f="$FLEET_INFLIGHT_DIR/$(fleet_slug "$sess").$$"
  : > "$f" 2>/dev/null
  printf '%s' "$f"
}
fleet_inflight_count() {  # [sess] → count FRESH markers (all fleets, or one), reaping stale
  local sess="${1:-}" ttl="${FLEET_INFLIGHT_TTL:-180}" now cut n=0 f m pat
  [ -d "$FLEET_INFLIGHT_DIR" ] || { printf 0; return; }
  now=$(date +%s 2>/dev/null || echo 0); cut=$((now - ttl))
  pat='*'; [ -n "$sess" ] && pat="$(fleet_slug "$sess").*"
  while IFS= read -r f; do
    [ -e "$f" ] || continue
    # GNU stat FIRST: `stat -f %m` on GNU means "filesystem status" and exits 0 with
    # non-mtime output, so it must not win — `stat -c %Y` (GNU) errors cleanly on BSD.
    m=$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null || echo 0)
    case "$m" in ''|*[!0-9]*) m=0;; esac
    if [ "$m" -ge "$cut" ]; then n=$((n + 1)); else rm -f "$f" 2>/dev/null; fi
  done <<EOF
$(find "$FLEET_INFLIGHT_DIR" -maxdepth 1 -type f -name "$pat" 2>/dev/null)
EOF
  printf '%s' "$n"
}

fleet_session_cap_ok() {
  local sess="${1:-}"
  local gmax="${FLEET_GLOBAL_MAX_SESSIONS:-8}" fmax="${FLEET_MAX_SESSIONS:-0}" n
  case "$gmax" in ''|*[!0-9]*) gmax=8;; esac   # tolerate a garbled conf value
  case "$fmax" in ''|*[!0-9]*) fmax=0;; esac
  if [ "$gmax" -ne 0 ]; then                   # 0 ⇒ unlimited
    # count LIVE session windows PLUS spawns still building their window (#531), so
    # a burst of concurrent spawns cannot all slip past before any lands a window.
    # Sleepers hold no slot (issue #1058); the refusal names them so a full fleet
    # of sleepers is legible, never a mystery (read only on a refusal).
    n=$(( $(fleet_session_count) + $(fleet_inflight_count) ))
    if [ "$n" -ge "$gmax" ]; then
      printf 'fleet at capacity: %s/%s Claude sessions running (global)%s — raise FLEET_GLOBAL_MAX_SESSIONS or close one first' \
        "$n" "$gmax" "$(_fleet_sleepers_note "$(fleet_session_sleepers)")"
      return 1
    fi
  fi
  if [ -n "$sess" ] && [ "$fmax" -ne 0 ]; then
    n=$(( $(fleet_session_count_for "$sess") + $(fleet_inflight_count "$sess") ))
    if [ "$n" -ge "$fmax" ]; then
      printf 'fleet at capacity: %s/%s Claude sessions in this fleet%s — raise FLEET_MAX_SESSIONS or close one first' \
        "$n" "$fmax" "$(_fleet_sleepers_note "$(fleet_session_sleepers_for "$sess")")"
      return 1
    fi
  fi
  return 0
}
_fleet_sleepers_note() { [ "${1:-0}" -gt 0 ] 2>/dev/null && printf ' · z%s sleeping' "$1"; return 0; }

# fleet_cap_full [sess] — the same two ceilings as fleet_session_cap_ok, read for
# a WAKE rather than a spawn (issue #1058): exit 0 + "<n> <max>" on stdout when a
# cap is reached (the one that binds — global first), exit 1 + nothing when a
# sleeper may wake into a free slot. An automatic wake (a due loop, a message)
# defers on 0; the operator's own wake goes through and the sleeping page quotes
# the pair as `fleet full N/M — waking makes N+1`.
fleet_cap_full() {
  local sess="${1:-}"
  local gmax="${FLEET_GLOBAL_MAX_SESSIONS:-8}" fmax="${FLEET_MAX_SESSIONS:-0}" n
  case "$gmax" in ''|*[!0-9]*) gmax=8;; esac
  case "$fmax" in ''|*[!0-9]*) fmax=0;; esac
  if [ "$gmax" -ne 0 ]; then
    n=$(( $(fleet_session_count) + $(fleet_inflight_count) ))
    [ "$n" -ge "$gmax" ] && { printf '%s %s\n' "$n" "$gmax"; return 0; }
  fi
  if [ -n "$sess" ] && [ "$fmax" -ne 0 ]; then
    n=$(( $(fleet_session_count_for "$sess") + $(fleet_inflight_count "$sess") ))
    [ "$n" -ge "$fmax" ] && { printf '%s %s\n' "$n" "$fmax"; return 0; }
  fi
  return 1
}

# Compact "slots N/max" chip for the backlog header / dash (issue #331): the
# GLOBAL session cap (FLEET_GLOBAL_MAX_SESSIONS, default 8) silently blocks EVERY
# spawn path, but nothing surfaces fullness today — so a cap refusal is an ambush.
# This makes it expected: reuse fleet_session_count (the SAME cross-fleet count the
# cap measures — pure tmux+awk, no network) and render an ANSI-truecolor chip:
# dim with headroom, orange at the last free slot, red at/over the cap. Pass a
# precomputed count as $1 (and sleeper count as $2, default 0 then) to avoid a
# second scan (and for hermetic tests); sleepers render as `· zN` (#1058). With the
# cap disabled (gmax=0 ⇒ unlimited) it shows a bare "slots N" (no denominator/color).
fleet_slots_chip() {
  local n="${1:-}" z="${2:-}" gmax="${FLEET_GLOBAL_MAX_SESSIONS:-8}" col reset t zs=''
  reset=$(printf '\033[0m')                          # POSIX ESC[0m — $'…' is a bashism dash ignores
  case "$gmax" in ''|*[!0-9]*) gmax=8;; esac
  if [ -z "$n" ]; then t=$(_fleet_session_tally); n=${t%% *}; [ -n "$z" ] || z=${t##* }; fi
  case "$n" in ''|*[!0-9]*) n=0;; esac
  case "$z" in ''|*[!0-9]*) z=0;; esac
  # Sleepers hold no slot (issue #1058) — shown apart as `· zN`, only when any.
  [ "$z" -gt 0 ] && zs=" · z$z"
  if [ "$gmax" -eq 0 ]; then                     # unlimited → no denominator, no color
    printf 'slots %s%s' "$n" "$zs"; return
  fi
  if   [ "$n" -ge "$gmax" ];       then col='247;118;142'   # full      → red    (P0)
  elif [ "$n" -ge $((gmax - 1)) ]; then col='224;175;104'   # last slot → orange (P1)
  else                                  col='86;95;137'     # headroom  → dim    (GY)
  fi
  printf '\033[38;2;%sm slots %s/%s%s %s' "$col" "$n" "$gmax" "$zs" "$reset"
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

# ── prmap jq program — the ONE fold from `gh pr list --json` to the prmap TSV ─────
# (issue #533). bin/tmux-pr-refresh.sh (the single prmap writer) feeds this to
# `gh --jq`; bin/pr-refresh-jq-selftest.sh feeds the byte-identical program to the
# system `jq` against fixture JSON, so the taxonomy below is tested offline. It used
# to be inlined in the refresher, where it silently drifted from the merge gate
# (fleet-pr-verdict.sh → land_verdict): the dash showed `#N✓` on a PR the worker's
# verdict called DRAFT / FAILING / PENDING. Keep the two in step — the ci fold here
# IS the verdict's `fail|pending|pass`, spelled as glyphs.
#
# Input: the JSON array from
#   gh pr list --state all --json number,headRefName,state,mergeable,mergeStateStatus,isDraft,statusCheckRollup,mergeCommit
# Output: one line per branch (newest PR wins):  branch<TAB>#num<TAB>state<TAB>ci<TAB>ready<TAB>sha
#   ci    ·  no checks at all
#         ✗  any red: a CheckRun whose conclusion is FAILURE / TIMED_OUT / CANCELLED /
#            ACTION_REQUIRED, or a StatusContext (the OTHER rollup shape — it has
#            `.state`, not `.status`/`.conclusion`) in FAILURE / ERROR
#         …  anything not final yet (a CheckRun not COMPLETED, a StatusContext not SUCCESS)
#         ✓  every check final and none red (NEUTRAL / SKIPPED count as green — same as
#            the verdict's `pass`)
#   ready only for an OPEN + ✓ PR, else "" — the dash decorates the ✓ with it:
#         draft    isDraft — wins over everything; a draft can't land whatever CI says (✓d)
#         conflict mergeable CONFLICTING or mergeStateStatus DIRTY               (✓!)
#         ready    CLEAN | HAS_HOOKS | UNSTABLE (UNSTABLE = a NON-required check is
#                  red; with ci=✓ nothing is, so it's mergeable — as land_classify)  (✓)
#         behind   BEHIND — update-branch                                        (✓↑)
#         blocked  BLOCKED — branch protection (review required / other)         (✓·)
#         unknown  UNKNOWN / "" — GitHub hasn't computed mergeability yet (every
#                  fresh push for a few seconds) — NOT the same as ready          (✓?)
#   sha   the MERGE commit (mergeCommit.oid) of a MERGED PR, "" otherwise (issue #541).
#         The deploy probe below keys its fleets/<slug>/deploy_<sha> cache on it; the
#         ledger's own sha is the pre-squash worktree HEAD, which is NOT on master.
# The first 4 fields are a stable contract (fleet-cleanup-daemon.sh keys off
# branch/#num/state); readers tab-guard a missing 5th/6th field to "" (older caches).
# shellcheck disable=SC2016,SC2034  # jq vars ($r/$ci/$ready) not shell — keep single-quoted; read cross-file by pr-refresh + its selftest
FLEET_PRMAP_JQ='group_by(.headRefName)[] | max_by(.number) |
  (.statusCheckRollup // []) as $r |
  (if   ($r|length)==0                                                       then "·"
   elif ($r|any(.conclusion=="FAILURE" or .conclusion=="TIMED_OUT"
                or .conclusion=="CANCELLED" or .conclusion=="ACTION_REQUIRED"
                or .state=="FAILURE" or .state=="ERROR"))                    then "✗"
   elif ($r|any(.status!="COMPLETED" and .state!="SUCCESS"))                 then "…"
   else "✓" end) as $ci |
  (if .state=="OPEN" and $ci=="✓" then
     (if   .isDraft==true                                                    then "draft"
      elif (.mergeable=="CONFLICTING" or .mergeStateStatus=="DIRTY")         then "conflict"
      elif (.mergeStateStatus=="CLEAN" or .mergeStateStatus=="HAS_HOOKS"
            or .mergeStateStatus=="UNSTABLE")                                then "ready"
      elif .mergeStateStatus=="BEHIND"                                       then "behind"
      elif .mergeStateStatus=="BLOCKED"                                      then "blocked"
      else "unknown" end)
   else "" end) as $ready |
  .headRefName + "\t#" + (.number|tostring) + "\t" + .state + "\t" + $ci + "\t" + $ready
  + "\t" + (.mergeCommit.oid // "")'

# ── poll backoff for the 15s GitHub pollers (issue #892) ─────────────────────────
# pr-refresh and the issue-bridge poll each fire every ~15s and each fire used to
# run `gh` for every repo — while almost every fire saw nothing new. With
# FLEET_POLL_MAX_BACKOFF above the unit's base interval, a repo whose poll came
# back UNCHANGED waits twice as long before the next one (15 → 30 → 60, capped at
# the knob); any change drops it straight back to the base, and an event (the
# webhook's targeted kick, a bridge --deliver) resets it outright. Default 15 =
# the base = no backoff, and then no state file is written or read at all: the
# degenerate path is the pre-#892 behaviour, byte for byte.
#
# State: one small file per repo, `<interval> <last-poll-epoch>`. Missing or
# garbled ⇒ the base interval and "due now" (fail open: a wrongly-skipped poll is
# a stale dash, a wrongly-run one is one gh call). Forkless — builtins only.

# fleet_poll_backoff_read <file> <base> — sets FLEET_PB_MAX / FLEET_PB_INT /
# FLEET_PB_TS. Returns 1 when backoff is OFF (knob ≤ base): keep the historic path.
fleet_poll_backoff_read() {
  FLEET_PB_INT=$2 FLEET_PB_TS=0
  FLEET_PB_MAX="${FLEET_POLL_MAX_BACKOFF:-15}"
  case "$FLEET_PB_MAX" in ''|*[!0-9]*) FLEET_PB_MAX=15 ;; esac
  [ "$FLEET_PB_MAX" -gt "$2" ] || { FLEET_PB_MAX=$2; return 1; }
  _pb_i='' _pb_t=''
  [ -f "$1" ] && read -r _pb_i _pb_t < "$1" 2>/dev/null
  case "$_pb_i" in ''|*[!0-9]*) ;; *) [ "$_pb_i" -gt "$2" ] && FLEET_PB_INT=$_pb_i ;; esac
  [ "$FLEET_PB_INT" -le "$FLEET_PB_MAX" ] || FLEET_PB_INT=$FLEET_PB_MAX
  case "$_pb_t" in ''|*[!0-9]*) ;; *) FLEET_PB_TS=$_pb_t ;; esac
  return 0
}

# fleet_poll_backoff_due <file> <base> <now> — 0 = poll this tick. Always 0 when
# backoff is off. Floored 3s below the interval, like pr-refresh's PR_TTL, so
# integer-second timer jitter never costs a whole extra tick.
fleet_poll_backoff_due() {
  fleet_poll_backoff_read "$1" "$2" || return 0
  _pb_ttl=$(( FLEET_PB_INT > 4 ? FLEET_PB_INT - 3 : 1 ))
  [ $(( $3 - FLEET_PB_TS )) -ge "$_pb_ttl" ]
}

# fleet_poll_backoff_note <file> <base> <changed 0|1> <now> — record a completed
# poll: changed → back to the base, unchanged → double (capped). Off → no file.
fleet_poll_backoff_note() {
  fleet_poll_backoff_read "$1" "$2" || { [ -f "$1" ] && rm -f "$1" 2>/dev/null; return 0; }
  if [ "$3" = 1 ]; then
    _pb_n=$2
  else
    _pb_n=$(( FLEET_PB_INT * 2 )); [ "$_pb_n" -le "$FLEET_PB_MAX" ] || _pb_n=$FLEET_PB_MAX
  fi
  printf '%s %s\n' "$_pb_n" "$4" > "$1.$$" 2>/dev/null && mv -f "$1.$$" "$1" 2>/dev/null
  return 0
}

# fleet_poll_backoff_reset <file> — an event arrived: the next tick polls, at the base.
fleet_poll_backoff_reset() { [ -f "$1" ] && rm -f "$1" 2>/dev/null; return 0; }

# ── deploy state of a MERGED PR (issue #541) ────────────────────────────────────
# "Merged" is not "live": claude-fleet's own tooling only runs once /fleet-sync-install
# fast-forwards ~/.claude/fleet, and an app repo deploys off a post-merge workflow.
# Two per-fleet knobs (fleet.conf; neither set ⇒ the feature is off and the dash keeps
# rendering `merged`):
#   FLEET_DEPLOY_REF=<path>     a local git checkout that IS the deployment — live ⇔
#                               the merge sha is an ancestor of its HEAD. Zero network.
#                               Wins over FLEET_DEPLOY_CHECK when both are set.
#   FLEET_DEPLOY_CHECK=actions  GitHub Actions runs for the merge sha (push runs +
#                               the workflow_dispatch deploys a conductor fans out with
#                               the same head_sha): folded by FLEET_DEPLOY_RUNS_JQ.
# States: live (terminal) · deploying · failed · unknown. bin/tmux-pr-refresh.sh (the
# single prmap writer) caches them at fleets/<slug>/deploy_<sha> as `<state>\t<epoch>`;
# the dash (`live` / `deploy…` / `deploy✗`) and the ⌃t landed list (`dep` column) read
# that file fork-free. bin/deploy-state-selftest.sh pins both programs offline.
#
# One run → one token: its status while not completed (queued / in_progress / waiting
# / requested / pending), else its conclusion. Any red token → failed (a broken
# post-merge run is attention, whichever workflow it is); any still-running → deploying;
# all green (success / skipped / neutral) → live; no runs at all → unknown.
# shellcheck disable=SC2016,SC2034  # jq vars ($s) not shell — keep single-quoted; read cross-file
FLEET_DEPLOY_RUNS_JQ='[.workflow_runs[]? | (if .status=="completed" then (.conclusion // "unknown") else .status end)] as $s |
  if   ($s|length)==0                                                                    then "unknown"
  elif ($s|any(.=="failure" or .=="cancelled" or .=="timed_out" or .=="action_required"
               or .=="startup_failure" or .=="stale"))                                  then "failed"
  elif ($s|any(.!="success" and .!="skipped" and .!="neutral"))                          then "deploying"
  else "live" end'

# fleet_deploy_probe <repo> <sha> <ref> <check> — print live|deploying|failed|unknown
# for one merge sha under the given knobs; "" (rc 0) when the feature is off for this
# repo or the sha is empty; rc 1 with "" when the actions read itself failed (the
# caller keeps whatever it cached rather than downgrading on a transient gh error).
fleet_deploy_probe() {
  local repo="${1:-}" sha="${2:-}" ref="${3:-}" check="${4:-}" out
  [ -n "$sha" ] || return 0
  if [ -n "$ref" ]; then
    # rc 1 = not an ancestor, rc 128 = sha not in that checkout's object db (it has
    # not fetched master yet) — both read as "not live here", never as an error.
    if git -C "$ref" merge-base --is-ancestor "$sha" HEAD >/dev/null 2>&1; then printf 'live'; else printf 'unknown'; fi
    return 0
  fi
  case "$check" in
    actions)
      out=$(gh api "repos/$repo/actions/runs?head_sha=$sha&per_page=100" --jq "$FLEET_DEPLOY_RUNS_JQ" 2>/dev/null) || return 1
      case "$out" in live|deploying|failed|unknown) printf '%s' "$out" ;; *) return 1 ;; esac ;;
    *) : ;;
  esac
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

# ============================================================================
# --- Claude Code process + session-registry probes (issues #511/#512/#513) ---
# Every running `claude` registers itself under ~/.claude/sessions/<pid>.json
# (sessionId, cwd, messagingSocketPath, …) with a sibling <pid>.<sha>.key holding
# the peer token its local inbox (/tmp/cc-socks/<pid>.sock) authenticates with.
# That registry is the SAME substrate the SendMessage/ListAgents tools ride, so
# reading it gives the fleet exact per-window truth — which session id a pane
# runs, which subscription token it was launched with — instead of the stamps
# (@cc_account) that #511 showed can be missing or stale. FLEET_CC_SESSIONS_DIR
# overrides the registry location so selftests can point it at a scratch tree.
FLEET_CC_SESSIONS_DIR="${FLEET_CC_SESSIONS_DIR:-$HOME/.claude/sessions}"

# fleet_pane_claude_pids <pane-pid>… — the BATCH form of fleet_pane_claude_pid
# (issue #706). Resolves MANY panes in THREE forks total — two `ps` snapshots and
# one awk that walks every tree in-process — where the per-pane form costs one
# `ps` plus two forked `awk`s for EVERY node it visits. Prints one
# "<pane-pid> <claude-pid>" line per pane that has a Claude under it; a pane with
# none prints nothing. Same matching grammar as the single form below, which is a
# wrapper around this one, so there is exactly ONE walk to keep correct.
#
# WHY the fork count is the whole point (issue #706). fleet-model-switch.sh's
# `--capped --dry-run` cap probe calls this once per window from inside
# fleet-quotawatch's 60 s tick — and that daemon runs at macOS
# ProcessType=Background, i.e. QoS BACKGROUND, where a fork costs ~10x what it
# costs in the foreground (issue #588 measured the same multiplier on bulk I/O
# and classified this unit as a "pure poller"; the poller had grown a fork-heavy
# half). Measured on a 9-window fleet: 1.7 s foreground, 21–25 s at background
# QoS, against a 20 s FLEET_QUOTAWATCH_PROBE_BUDGET — so the probe timed out on
# 69% of all ticks and 100% of recent ones, and that fleet's model-cap detection
# was blind for as long as the log goes back. Only 4.4 s of those 21 s was CPU:
# the rest was fork/exec scheduling latency. Cutting ~12 forks per window to ~0
# is therefore the fix, and unlike a bigger budget it also scales with fleet size.
#
# The two snapshots ride STDIN with a sentinel between them rather than `-v`:
# awk processes escape sequences in a `-v` assignment, and a command line is
# exactly the kind of string that carries backslashes. Pane pids are numeric, so
# those are safe to pass as `-v`.
fleet_pane_claude_pids() {
  [ "$#" -gt 0 ] || return 0
  { ps -axo pid=,ppid=,comm=; echo '---CMDS---'; ps -axo pid=,command=; } 2>/dev/null \
  | awk -v panes="$*" -v ccomm="${FLEET_CLAUDE_COMM:-}" '
      /^---CMDS---$/ { sec = 2; next }
      sec != 2 { if (NF >= 3) { comm[$1] = $3; kids[$2] = kids[$2] " " $1 } next }
      { p = $1; $1 = ""; cmd[p] = " " substr($0, 2) " " }
      function base(s,   k) { k = s; sub(/^.*\//, "", k); return k }
      # BFS from the pane pid, in the same order the shell form used. `gen` stands
      # in for `delete seen`: the whole-array delete is a gawk-ism this must not
      # depend on, and a per-walk generation number is exact on every awk.
      function walk(root, gen,   q, head, tail, p, b, k, nk, i) {
        q[1] = root; head = 1; tail = 1
        while (head <= tail) {
          p = q[head++]
          if (seen[p] == gen) continue
          seen[p] = gen
          b = base(comm[p])
          if (b == "claude") return p
          if (b == "bun" || b ~ /^node[0-9]*$/) {
            if (index(cmd[p], "claude-code/cli.js") > 0 || index(cmd[p], "/claude ") > 0) return p
          } else if (b == "bash" || b == "sh" || b == "zsh" || b == "dash") {
            # a selftest fake `claude` is a script: its comm is the interpreter, so
            # match ONLY the explicit FLEET_CLAUDE_COMM substring (never a bare
            # heuristic — a worker s `zsh -c ...fleet-claude.sh...` runner must not
            # count as Claude). No `next` here: the shell s children still get walked.
            if (ccomm != "" && index(cmd[p], ccomm) > 0) return p
          }
          nk = split(kids[p], k, " ")
          for (i = 1; i <= nk; i++) if (k[i] != "") q[++tail] = k[i]
        }
        return ""
      }
      END {
        np = split(panes, pl, " ")
        for (i = 1; i <= np; i++) {
          if (pl[i] == "") continue
          c = walk(pl[i], i)
          if (c != "") print pl[i] " " c
        }
      }
    '
}

# fleet_pane_claude_pid <tmux-target> [socket] — pid of the Claude process running
# under the target's pane (any descendant of pane_pid whose command is `claude`, or
# a node/bun running the npm-installed cli), or nothing (exit 1). THIS is the "is
# Claude alive here" gate (issue #511): `pane_current_command` reads the `zsh -c`
# runner for the whole life of a session on macOS, so it says "shell" while Claude
# is alive. Portable: `ps -axo` on macOS + Linux. [socket] = -L label for headless
# callers; bare tmux (the $TMUX socket) otherwise. FLEET_CLAUDE_COMM widens the
# command-name match (a selftest's fake `claude` is a bash script, whose comm is
# `bash` on macOS). The walk itself lives in fleet_pane_claude_pids above (#706).
fleet_pane_claude_pid() {
  local tgt="$1" sock="${2:-}" pp out
  if [ -n "$sock" ]; then pp=$(tmux -L "$sock" display-message -p -t "$tgt" '#{pane_pid}' 2>/dev/null)
  else                    pp=$(tmux display-message -p -t "$tgt" '#{pane_pid}' 2>/dev/null); fi
  [ -n "$pp" ] || return 1
  out=$(fleet_pane_claude_pids "$pp") || return 1
  [ -n "$out" ] || return 1
  printf '%s\n' "${out##* }"
}

# fleet_child_busy <session> <win> [branch] — is a child whose turn ENDED still
# working (issue #864)? Prints the reason and exits 0 when it is; prints nothing
# and exits 1 when it is not (or there is no repo/branch to ask GitHub about):
#   bg       its agent still owns a Bash-tool job — a run_in_background test, a
#            PR-gate waiter (`tools/await-pr.sh`). fleet-sleep.py `busy`: the walk
#            hibernation vetoes on, minus the MCP contract and the calling hook.
#   pr-open  its branch has an open PR — shipped and waiting on the gate.
#   pr-unknown  gh missing, failing or slow (5s) for a known repo + branch: the
#            report has never once been right on a shipped child, so an unread
#            gate counts as busy — quiet, never an error.
# A Stop that is only a turn boundary must not tell the parent the child STOPPED:
# in two monorepo EPICs that report was 15/15 false, every one a worker waiting
# on its PR gate. [branch] defaults to the @worktree's branch, else issue-<@issue>.
fleet_child_busy() {
  local sess="${1:-}" win="${2:-}" br="${3:-}" bin sock='' agent pid='' raw wt iss repo n
  [ -n "$win" ] || return 1
  [ -n "$sess" ] || sess=$(fleet_current_session)
  [ -n "$sess" ] || return 1
  [ -n "${TMUX:-}" ] || sock=$(fleet_socket "$sess")
  bin="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)"
  if [ -f "$bin/fleet-sleep.py" ] && command -v python3 >/dev/null 2>&1; then
    agent=$(_fleet_tmux "$sess" display-message -p -t "$win" '#{@cc_agent}' 2>/dev/null)
    [ "$agent" = codex ] || pid=$(fleet_pane_claude_pid "$win" "$sock" 2>/dev/null) || pid=''
    if [ "$agent" = codex ] || [ -n "$pid" ]; then
      python3 "$bin/fleet-sleep.py" busy --session "$sess" ${pid:+--pid "$pid"} "$win" \
        >/dev/null 2>&1 </dev/null && { printf 'bg\n'; return 0; }
    fi
  fi
  if [ -z "$br" ]; then
    raw=$(_fleet_tmux "$sess" display-message -p -t "$win" '#{@issue}|#{@worktree}' 2>/dev/null)
    iss=${raw%%|*}; wt=${raw#*|}
    [ -n "$wt" ] && [ -d "$wt" ] && br=$(git -C "$wt" branch --show-current 2>/dev/null)
    case "$iss" in ''|*[!0-9]*) ;; *) [ -n "$br" ] || br="issue-$iss" ;; esac
  fi
  [ -n "$br" ] || return 1
  repo=$(fleet_window_repo "$sess" "$win"); [ -n "$repo" ] || repo="${FLEET_REPO:-}"
  case "$repo" in ?*/?*) ;; *) return 1 ;; esac
  command -v gh >/dev/null 2>&1 || { printf 'pr-unknown\n'; return 0; }
  # REST, not `gh pr list`: the core budget is separate from the GraphQL one the
  # prmap spends, and this runs on every unreported Stop.
  n=$(fleet_timebox 5 gh api "repos/$repo/pulls?state=open&head=${repo%%/*}:$br" \
        --jq length 2>/dev/null)
  case "$n" in
    0) return 1 ;;
    ''|*[!0-9]*) printf 'pr-unknown\n' ;;
    *) printf 'pr-open\n' ;;
  esac
}

# fleet_cc_session_json <pid> — path of the registry record for a Claude pid.
fleet_cc_session_json() { local f="$FLEET_CC_SESSIONS_DIR/$1.json"; [ -f "$f" ] && printf '%s' "$f"; }
# fleet_cc_session_field <pid> <field> — one string field off the registry record.
fleet_cc_session_field() {
  local f; f=$(fleet_cc_session_json "$1") || return 1
  sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" "$f" | head -n1
}
# fleet_cc_session_id <pid> — the session id (transcript uuid) the pid runs.
fleet_cc_session_id() { fleet_cc_session_field "$1" sessionId; }
# fleet_cc_peer_sock <pid> — the inbox socket path (registry value, else the default).
fleet_cc_peer_sock() { local s; s=$(fleet_cc_session_field "$1" messagingSocketPath); printf '%s' "${s:-/tmp/cc-socks/$1.sock}"; }
# fleet_cc_peer_token <pid> — the peer token off <pid>.<sha>.key (exit 1 = none).
fleet_cc_peer_token() {
  local f
  for f in "$FLEET_CC_SESSIONS_DIR/$1".*.key; do
    [ -f "$f" ] || continue
    sed -n 's/.*"peerToken"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$f" | head -n1
    return 0
  done
  return 1
}
# fleet_cc_pid_for_session <session-uuid> — the registry pid running that session.
fleet_cc_pid_for_session() {
  local f
  for f in "$FLEET_CC_SESSIONS_DIR"/*.json; do
    [ -f "$f" ] || continue
    grep -q "\"sessionId\"[[:space:]]*:[[:space:]]*\"$1\"" "$f" 2>/dev/null || continue
    f=${f##*/}; printf '%s' "${f%.json}"; return 0
  done
  return 1
}

# fleet_same_window <marker-file> <epoch> — 0 iff the marker file holds an epoch
# within 15 minutes of <epoch>, i.e. the same reset window (issue #513's once-per-
# window quota episodes). Tolerant, not exact: ccquota's resets_at jitters by a
# second or so between polls (…599 vs …600), and an exact compare re-armed the
# episode every tick — the 70% warning reached one session seven times. A missing
# or non-numeric marker is "not the same window".
fleet_same_window() {
  local m d; m=$(cat "$1" 2>/dev/null); case "$m" in ''|*[!0-9]*) return 1;; esac
  case "$2" in ''|*[!0-9]*) return 1;; esac
  d=$(( m - $2 )); [ "$d" -lt 0 ] && d=$(( -d )); [ "$d" -le 900 ]
}

# fleet_sha12 — stdin → first 12 hex of its sha256 (shasum on macOS, sha256sum on Linux).
fleet_sha12() { if command -v shasum >/dev/null 2>&1; then shasum -a 256 | cut -c1-12; else sha256sum | cut -c1-12; fi; }
# fleet_claude_token_sha <pid> — sha12 of CLAUDE_CODE_OAUTH_TOKEN in the process's
# environment; exit 1 when it carries none (ambient Keychain login). This is the
# TRUTH about which pool account a running session spends (issue #511) — a
# `claude` bakes the token in at launch and cannot change it. macOS: `ps -E`;
# Linux: /proc/<pid>/environ (own-uid processes only, which is all the fleet has).
# FLEET_TOKEN_PROBE=<cmd> is the selftest seam: `<cmd> <pid>` prints the token
# (macOS strips the environment of Apple-signed binaries — a selftest's perl fake
# — from `ps -E`, so a hermetic test cannot read it the production way).
fleet_claude_token_sha() {
  local pid="$1" tok=""
  if [ -n "${FLEET_TOKEN_PROBE:-}" ]; then
    tok=$("$FLEET_TOKEN_PROBE" "$pid" 2>/dev/null | head -n1)
  elif [ -r "/proc/$pid/environ" ]; then
    tok=$(tr '\0' '\n' < "/proc/$pid/environ" | sed -n 's/^CLAUDE_CODE_OAUTH_TOKEN=//p' | head -n1)
  else
    tok=$(ps -E -ww -o command= -p "$pid" 2>/dev/null | tr ' ' '\n' | sed -n 's/^CLAUDE_CODE_OAUTH_TOKEN=//p' | head -n1)
  fi
  [ -n "$tok" ] || return 1
  printf '%s' "$tok" | fleet_sha12
}

# fleet_peer_send <pid> <text> [from-name] — deliver <text> to a running Claude
# session as a cross-session message: the SendMessage tool's LOCAL channel. An
# auth frame with the session's peer token, then a user frame, newline-delimited
# JSON over its inbox socket. The session sees it as a message from another
# session on its next turn (queued while it is busy). This is the sanctioned way
# for fleet tooling to talk to a live session — NOT tmux send-keys into its
# prompt (#437: bracketed paste eats the Enter, and a keystroke lands in whatever
# the TUI is showing).
#
# The body rides the CLI's own canonical envelope, `<cross-session-message
# from-name="…" from-mode="…">`, because of the recipient's inbound policy: a
# session running bypassPermissions HOLDS a peer message whose sender did not
# attest its permission mode (a blocking approve/deny dialog in the pane —
# exactly the stall this tooling exists to prevent), and a "prompting" sender
# into a bypass session is a mode mismatch (also held). Fleet sessions run
# bypassPermissions (settings.json defaultMode), so the envelope attests
# FLEET_PEER_MODE (default bypass); an operator whose sessions prompt sets it to
# `prompting`. The envelope must be byte-canonical (attribute order fixed:
# from, from-session, hop-chain, from-name, from-mode; the receiver re-serializes
# and compares) — do not reorder or pad it. [from-name] must not contain " < > or
# a newline. python3 writes the socket (pure bash has no unix-socket client);
# `nc -U` is the fallback. Exit 0 iff the frame was written.
fleet_peer_send() {
  local pid="$1" text="$2" from="${3:-fleet}" tok sock
  tok=$(fleet_cc_peer_token "$pid") || return 1
  [ -n "$tok" ] || return 1
  sock=$(fleet_cc_peer_sock "$pid")
  [ -S "$sock" ] || return 1
  from=$(printf '%s' "$from" | tr -d '"<>\n\r'); [ -n "$from" ] || from=fleet
  text="<cross-session-message from-name=\"$from\" from-mode=\"${FLEET_PEER_MODE:-bypass}\">"$'\n'"$text"$'\n'"</cross-session-message>"
  if command -v python3 >/dev/null 2>&1; then
    FPS_TOK="$tok" FPS_TEXT="$text" FPS_SOCK="$sock" python3 - <<'PY'
import json, os, socket, sys, time
frame = (json.dumps({"type": "auth", "token": os.environ["FPS_TOK"]}) + "\n"
         + json.dumps({"type": "user", "message": {"role": "user", "content": os.environ["FPS_TEXT"]}}) + "\n")
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); s.settimeout(5)
try:
    s.connect(os.environ["FPS_SOCK"]); s.sendall(frame.encode())
    time.sleep(0.2)                      # let the server read before the FIN (as the CLI does)
except OSError as e:
    print("fleet_peer_send: %s" % e, file=sys.stderr); sys.exit(1)
finally:
    s.close()
PY
  elif command -v nc >/dev/null 2>&1; then
    local esc
    # minimal JSON string escaping: backslash, quote, tab, newline
    esc=$(printf '%s' "$text" | sed 's/\\/\\\\/g; s/"/\\"/g; s/\t/\\t/g' | awk 'NR>1{printf "\\n"} {printf "%s", $0}')
    { printf '{"type":"auth","token":"%s"}\n' "$tok"
      printf '{"type":"user","message":{"role":"user","content":"%s"}}\n' "$esc"
      sleep 0.2; } | nc -U "$sock" 2>/dev/null
  else
    return 1
  fi
}

# ============================================================================
# --- per-fleet window handles: `@wid` (issue #566) --------------------------
# ============================================================================
# A window's tmux `window_id` (`@382`) is NOT a name the operator can use: it is
# re-minted every time the window is re-created, and that happens constantly —
# `fleet-migrate.sh` re-created 21 windows in one night, and every
# `dash-restore-session.sh` / warm-pool claim mints another. So the fleet stamps
# its own SHORT handle on each window: `@wid` = letter + digit, `a1`…`z9` (234),
# lowercase and digit-1-up so nothing reads as `0`/`O` or `1`/`l` on a soft
# keyboard. It is rendered in the dash's leftmost `id` column and accepted
# wherever a window target is (`fleet_wid_target`), so "reap a1" / "migrate b3"
# are things the operator can actually type.
#
# SCOPE: unique among the LIVE windows on this fleet's socket — that is all the
# operator asked for. A handle is REUSED once its window is gone, which is what
# keeps it two characters forever instead of growing. Durable identity for the
# history ledger stays the session/transcript id; `@wid` never appears there.
#
# ALLOCATION IS STATELESS — derived from tmux, never from a counter file. To
# allocate: read `@wid` off every window on the socket and take the lowest unused.
# Nothing to corrupt, self-healing after any crash, and correct across
# fleet-up/fleet-down. A short mkdir-lock in the fleet's state dir serialises
# concurrent spawns; on lock timeout the caller FAILS OPEN (no handle) and the
# dash's render-time backfill assigns one on the next tick.
FLEET_WID_ALPHA=abcdefghijklmnopqrstuvwxyz
FLEET_WID_DIGITS=123456789

# fleet_wid_valid <handle> — 0 iff it is a well-formed handle. The sets are spelled
# out rather than written `[a-z][1-9]`: a RANGE in a glob follows the locale's
# collation, and under en_US.UTF-8 `[a-z]` happily matches `A` — which would let
# `A1` through as a handle and, worse, let fleet_wid_target shadow a window
# legitimately named `A1`.
fleet_wid_valid() {
  case "${1:-}" in
    [abcdefghijklmnopqrstuvwxyz][123456789]) return 0 ;;
    *) return 1 ;;
  esac
}

# fleet_wid_next <taken> — the lowest handle NOT in <taken> (whitespace/newline
# separated). Pure bash, no forks, no tmux: this is the allocator's whole policy,
# so bin/dash-wid-selftest.sh can pin it without a server. Exit 1 = all 234 taken.
# (POSIX `while` loops, not `for (( … ))`: fleet-lib.sh must PARSE under a strict
# /bin/sh — the conf sources it under `sh` for the ⌂ hub tap, and a C-style for is
# a syntax error in dash, which would leave every later function undefined. That
# is the #414 class, and bin/posix-lib-parse-selftest.sh is its net.)
fleet_wid_next() {
  local taken=" ${1//$'\n'/ } " i=0 j h la ld
  la=${#FLEET_WID_ALPHA}; ld=${#FLEET_WID_DIGITS}
  while [ "$i" -lt "$la" ]; do
    j=0
    while [ "$j" -lt "$ld" ]; do
      h="${FLEET_WID_ALPHA:$i:1}${FLEET_WID_DIGITS:$j:1}"
      case "$taken" in
        *" $h "*) : ;;
        *) printf '%s' "$h"; return 0 ;;
      esac
      j=$((j + 1))
    done
    i=$((i + 1))
  done
  return 1
}

# fleet_wid_taken <handle> <taken> — 0 iff <handle> appears in the list. Pure.
fleet_wid_taken() {
  case " ${2//$'\n'/ } " in *" $1 "*) return 0;; *) return 1;; esac
}

# fleet_wid_used [socket] — every handle stamped on the socket, one per line
# (blank lines for unstamped windows are harmless — fleet_wid_next ignores them).
# `-a`: the scope is the SERVER, so the warm pool session's windows count too and
# a claimed pool window never collides with a live one.
fleet_wid_used() {
  if [ -n "${1:-}" ]; then tmux -L "$1" list-windows -a -F '#{@wid}' 2>/dev/null
  else                     tmux list-windows -a -F '#{@wid}' 2>/dev/null; fi
}

# fleet_wid_get <window-target> [socket] — the handle stamped on that window ('').
fleet_wid_get() {
  if [ -n "${2:-}" ]; then tmux -L "$2" display-message -p -t "$1" '#{@wid}' 2>/dev/null
  else                     tmux display-message -p -t "$1" '#{@wid}' 2>/dev/null; fi
}

# fleet_wid_sess [socket] — the fleet whose state dir holds the allocation lock.
# The socket LABEL is the session name (fleet_socket is identity), so a socket is
# already the answer; with none, ask the caller's own server. The `-pool` holding
# session shares its fleet's socket, hence its lock.
fleet_wid_sess() {
  local s="${1:-}"
  [ -n "$s" ] || s=$(tmux display-message -p '#{session_name}' 2>/dev/null)
  printf '%s' "${s%-pool}"
}

# fleet_wid_lock <dir> / fleet_wid_unlock <dir> — mkdir-lock (portable; macOS has
# no flock). A lock whose holder pid is gone is STOLEN, so a crash mid-allocation
# cannot wedge handle assignment forever. ~2s ceiling, then exit 1 = fail open.
fleet_wid_lock() {
  local d="$1" i=0 p alive
  mkdir -p "${d%/*}" 2>/dev/null
  while [ "$i" -lt 40 ]; do
    if mkdir "$d" 2>/dev/null; then printf '%s' "$$" > "$d/pid" 2>/dev/null; return 0; fi
    i=$((i + 1))
    # No pid file yet = a holder mid-mkdir; give it a few ticks before stealing.
    p=$(cat "$d/pid" 2>/dev/null); alive=1
    case "$p" in
      ''|*[!0-9]*) [ "$i" -ge 5 ] && alive=0 ;;
      *)           kill -0 "$p" 2>/dev/null || alive=0 ;;
    esac
    if [ "$alive" = 0 ]; then rm -rf "$d" 2>/dev/null; else sleep 0.05; fi
  done
  return 1
}
fleet_wid_unlock() { rm -rf "$1" 2>/dev/null; return 0; }

# fleet_wid_stamp <window-target> [socket] [wanted] — THE allocator. Prints the
# window's handle, assigning the lowest free one when it has none. Idempotent: a
# window that already carries a handle keeps it (so the dash's backfill is a
# no-op after the first tick, and a double-stamped spawn is harmless).
#
# <wanted> is the RE-STAMP path (fleet-migrate.sh closes a window and opens a new
# one for the same session): keep that handle if it is still free, else take the
# next one rather than letting two windows answer to `b3`.
#
# Exit 1 + no output = no handle this time (lock timeout, or all 234 in use) —
# deliberately non-fatal for every caller: a spawn proceeds without one and the
# dash backfills it on the next repaint.
fleet_wid_stamp() {
  local win="$1" sock="${2:-}" want="${3:-}" cur used lk
  cur=$(fleet_wid_get "$win" "$sock")
  [ -n "$cur" ] && { printf '%s' "$cur"; return 0; }
  lk="$(fleet_state_dir "$(fleet_wid_sess "$sock")")/wid.lock"
  fleet_wid_lock "$lk" || return 1
  cur=$(fleet_wid_get "$win" "$sock")        # re-read UNDER the lock
  if [ -z "$cur" ]; then
    used=$(fleet_wid_used "$sock")
    cur=''
    if [ -n "$want" ] && fleet_wid_valid "$want" && ! fleet_wid_taken "$want" "$used"; then
      cur=$want
    else
      cur=$(fleet_wid_next "$used") || cur=''
    fi
    if [ -n "$cur" ]; then
      if [ -n "$sock" ]; then tmux -L "$sock" set-window-option -t "$win" @wid "$cur" 2>/dev/null
      else                    tmux set-window-option -t "$win" @wid "$cur" 2>/dev/null; fi
    fi
  fi
  fleet_wid_unlock "$lk"
  [ -n "$cur" ] || return 1
  printf '%s' "$cur"
}

# fleet_wid_resolve <handle> [socket] — handle → `window_id` (`@382`). Empty +
# exit 1 when no live window carries it. Space-separated -F, never a control byte:
# tmux ≤3.4 vis-escapes 0x1f/0x09 in format output (the `\037` trap from #208).
fleet_wid_resolve() {
  local h="${1:-}" sock="${2:-}" w v
  fleet_wid_valid "$h" || return 1
  while read -r w v; do
    [ -n "$w" ] || continue
    if [ "$v" = "$h" ]; then printf '%s' "$w"; return 0; fi
  done <<EOF
$(if [ -n "$sock" ]; then tmux -L "$sock" list-windows -a -F '#{window_id} #{@wid}' 2>/dev/null
  else                    tmux list-windows -a -F '#{window_id} #{@wid}' 2>/dev/null; fi)
EOF
  return 1
}

# fleet_wid_target <target> [socket] — the window-target normaliser every
# target-taking script runs its argument through. A handle resolves to its
# `window_id`; ANYTHING else (an `@id`, an index, `sess:idx`, a window name) is
# passed back untouched, so every form that works today keeps working. Handles
# win the tie by design — a window merely NAMED `a1` is addressable by index.
fleet_wid_target() {
  local t="${1:-}" sock="${2:-}" w
  if fleet_wid_valid "$t"; then
    w=$(fleet_wid_resolve "$t" "$sock") && [ -n "$w" ] && { printf '%s' "$w"; return 0; }
  fi
  printf '%s' "$t"
}

# --- fleet commands: bare vs. plugin-namespaced (issue #611) ------------------
# The fleet's slash commands reach a session by ONE of two install paths:
#
#   copy install   `commands/*.md` → ~/.claude/commands/   → typed `/fleet-claim`
#   plugin install fleet@claude-fleet via /plugin          → typed `/fleet:fleet-claim`
#
# Claude Code NAMESPACES every plugin-provided command as `/<plugin>:<command>`
# (that is why the built-ins show up as `superpowers:brainstorming`,
# `frontend-design:frontend-design`, …). A bare `/fleet-claim` therefore does NOT
# resolve in a plugin-only install — and the spawn seed is exactly that bare slash
# (bin/dash-issue-session.sh, issue #299), so every spawn would land on an
# unexpanded literal. `fleet_cmd` is the one place that knows which form to type.
#
# Resolution order, cheapest first — a filesystem probe, no `claude` round-trip:
#   1. FLEET_CMD_PREFIX set   → honour it verbatim ('' = bare; 'fleet' = /fleet:…)
#   2. ~/.claude/commands/<name>.md exists → BARE. The copy install wins because
#      it is what every pre-#611 fleet has, and a bare command still resolves when
#      BOTH are installed (they coexist — different invocation paths).
#   3. the plugin ships <name>.md in its cache → `/<plugin>:<name>`
#   4. neither → BARE (unchanged behaviour; a missing command is the operator's
#      problem to see, not something to paper over with a wrong prefix)
FLEET_PLUGIN_NAME="${FLEET_PLUGIN_NAME:-fleet}"

# fleet_plugin_installed [<file>] — 0 when the fleet plugin is installed, and (with
# <file>) ships that path. Probes the plugin cache directly: `claude plugin list`
# costs a node startup and this runs on the spawn path.
fleet_plugin_installed() {
  local want="${1:-}" cdir base d
  cdir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
  base="$cdir/plugins/cache"
  [ -d "$base" ] || return 1
  # cache/<marketplace>/<plugin>/<version>/ — the version dir moves on every
  # update, so glob it rather than remembering one.
  for d in "$base"/*/"$FLEET_PLUGIN_NAME"/*/; do
    [ -d "$d" ] || continue
    [ -n "$want" ] && { [ -e "$d$want" ] || continue; }
    return 0
  done
  return 1
}

# fleet_cmd <name> [<args…>] — the slash command to TYPE for fleet command <name>.
# Echoes it with any args appended, so a caller can seed it verbatim.
fleet_cmd() {
  local name="${1:-}" pfx
  [ -n "$name" ] || return 1
  shift
  if [ -n "${FLEET_CMD_PREFIX+x}" ]; then
    pfx="$FLEET_CMD_PREFIX"
  elif [ -f "${CLAUDE_COMMANDS_DIR:-$HOME/.claude/commands}/$name.md" ]; then
    pfx=''
  elif fleet_plugin_installed "commands/$name.md"; then
    pfx="$FLEET_PLUGIN_NAME"
  else
    pfx=''
  fi
  printf '/%s%s' "${pfx:+$pfx:}" "$name"
  [ "$#" -gt 0 ] && printf ' %s' "$*"
  return 0
}
