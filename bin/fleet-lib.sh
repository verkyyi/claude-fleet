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
_FLEET_GLOBAL_ONLY="FLEET_GLOBAL_MAX_SESSIONS FLEET_ISSUE_BRIDGE_SECRET FLEET_ISSUE_TTL FLEET_GH_TTL FLEET_GH_SHARE FLEET_PR_REFRESH_INTERVAL FLEET_STUCK_WORKING_SECS FLEET_STATE_IDLE_SECS FLEET_DEGENERATE_SECS FLEET_DEGENERATE_LINES FLEET_DEGENERATE_COOLDOWN_SECS FLEET_DEGENERATE_MARK_SECS FLEET_ACCOUNTS FLEET_ACCOUNT_LIMIT_TTL FLEET_ACCOUNT_CEILING FLEET_ACCOUNT_WARN_PCT FLEET_ACCOUNT_QUOTA_TTL FLEET_ACCOUNT_QUOTA_STALE FLEET_QUOTA_RL_TTL FLEET_ACCOUNT_QUOTA_BLIND_STREAK FLEET_ACCOUNT_QUOTA_VIA_BANNER_SECS FLEET_ACCOUNT_VERDICT_REFETCH FLEET_ACCOUNT_PICK FLEET_ACCOUNT_PICK_HYST FLEET_ACCOUNT_PACE_LEAD FLEET_ACCOUNT_PACE_HOLD FLEET_ACCOUNT_PACE_MARGIN FLEET_ACCOUNT_PACE_REBALANCE FLEET_ACCOUNT_PACE_COOLDOWN FLEET_ACCOUNT_PACE_SPREAD_WARN FLEET_ACCOUNT_PHASE FLEET_ACCOUNT_PHASE_AUTO FLEET_COLLECT_DEADLINE FLEET_COLLECT_GIT_BUDGET FLEET_COLLECT_GIT_SLOW FLEET_COLLECT_TICK_BUDGET FLEET_COLLECT_QUOTAWATCH_BUDGET FLEET_COLLECT_SOCKETS_BUDGET FLEET_COLLECT_SESSMAP_BUDGET FLEET_COLLECT_ISSUES_BUDGET FLEET_COLLECT_CTX_BUDGET FLEET_COLLECT_USAGE_BUDGET FLEET_COLLECT_SCRAPE_BUDGET FLEET_COLLECT_BANNER_BUDGET FLEET_COLLECT_BANNER_PER_WINDOW_MS FLEET_COLLECT_ESCALATE_BUDGET FLEET_COLLECT_SNAPSHOT_BUDGET FLEET_COLLECT_HUBSESS_BUDGET FLEET_NODE_ALIASES FLEET_COLLECT_STALE FLEET_COLLECT_KICK FLEET_COLLECT_KICK_COOLDOWN FLEET_COLLECT_KICK_TRACE FLEET_DAEMON_STALE_MULT FLEET_DAEMON_STALE_FLOOR FLEET_DAEMON_KICK FLEET_DAEMON_KICK_COOLDOWN FLEET_DAEMON_KICK_COOLDOWN_MULT FLEET_DAEMON_KICK_COOLDOWN_FLOOR FLEET_DAEMON_KICK_TRACE FLEET_DAEMON_RELOAD_AFTER FLEET_DAEMON_RELOAD_COOLDOWN FLEET_DAEMON_DOMAIN_MIN FLEET_DAEMON_DOMAIN_KICK_WINDOW FLEET_DAEMON_IDLE_AFTER FLEET_POLL_MAX_BACKOFF FLEET_LAUNCHD_PROBE FLEET_LAUNCHD_PROBE_WINDOW FLEET_LAUNCHD_PROBE_INTERVAL FLEET_LAUNCHD_PROBE_TTL FLEET_MODEL_FALLBACK FLEET_MODEL_LIMIT_TTL FLEET_MODEL_CAP_PCT FLEET_CLOSE_ON_EXIT FLEET_NOTIFY_CMD FLEET_ESCALATE_AFTER FLEET_STATUS_CONTAINER FLEET_STATUS_QUOTA_PCT FLEET_STATUS_CACHE_SECS FLEET_DISK_FLOOR_GB FLEET_DISK_WARN_GB FLEET_QUOTA_GATE FLEET_QUOTA_CEILING FLEET_QUOTA_ACCOUNT FLEET_QUOTA_BIN FLEET_RUNAWAY_CPU_PCT FLEET_RUNAWAY_CPU_SECS FLEET_RUNAWAY_CPU_ACTION FLEET_ORPHAN_CPU_PCT FLEET_ORPHAN_CPU_SECS FLEET_ORPHAN_CPU_ACTION FLEET_ORPHAN_EXTRA_RE FLEET_ORPHAN_LISTEN_SECS FLEET_ORPHAN_LISTEN_ACTION FLEET_ORPHAN_LISTEN_EVERY FLEET_LISTEN_EXEMPT_RE FLEET_LOAD_WARN_PER_CORE FLEET_FSEVENTSD_WARN_MB FLEET_DOCTOR_SPOTLIGHT FLEET_CODEX_VERSION_CHECK FLEET_DOCTOR_SLEEP FLEET_DOCTOR_SIRI FLEET_DOCTOR_ICLOUD FLEET_DOCTOR_NETWORK FLEET_DOCTOR_MCP FLEET_LOADGEN_MAX_PROCS FLEET_LOADGEN_MAX_SECS FLEET_LOADGEN_LOAD_PER_CORE FLEET_LOADGEN_CORE_PCT FLEET_USAGE_WARN_PCT FLEET_USAGE_CRIT_PCT FLEET_RATELIMIT_TTL FLEET_WEBHOOK_PORT FLEET_WEBHOOK_SECRET FLEET_OPEN_LAPTOP FLEET_REAP_KEPT_PROCS FLEET_REAP_KEPT_MINAGE FLEET_ROTATE_LEASE_TTL FLEET_HELPER_NO_MCP FLEET_SPAWN_GUARD_MS FLEET_INFLIGHT_TTL FLEET_INSTALL_SYNC FLEET_INSTALL_SYNC_TIMEOUT FLEET_INSTALL_LOOP_MARGIN_SECS FLEET_KEEP_AGENTS_KEY FLEET_INSTALL_FOLLOW_STUCK_SECS FLEET_INSTALL_VERSIONS_KEEP_SECS FLEET_NODE_FOLLOW FLEET_NODE_FOLLOW_RETRY_SECS FLEET_ONBOARD FLEET_GUIDE_WAIT_SECS FLEET_GUIDE_COOLDOWN FLEET_GUIDE_SPEAK_SECS FLEET_COLLECT_GUIDE_BUDGET FLEET_SSH_PUBLIC_HOST FLEET_SSH_PUBLIC_PORT FLEET_SSH_PROBE_HOST FLEET_DOCTOR_INGRESS FLEET_INGRESS_TTL FLEET_INGRESS_TIMEOUT FLEET_HEAVY FLEET_HEAVY_SLOTS FLEET_HEAVY_WAIT FLEET_HEAVY_RE FLEET_HEAVY_LIGHT_RE FLEET_MEMGUARD FLEET_MEM_SPIKE_GROW_MB FLEET_MEM_SPIKE_WINDOW FLEET_MEM_SPIKE_ACTION FLEET_MEM_PROC_HARD_PCT FLEET_MEM_EXEMPT_RE FLEET_MEM_ORPHAN_MB FLEET_MEM_ORPHAN_SECS FLEET_MEM_ORPHAN_ACTION FLEET_CLAUDE_RSS_WARN_MB FLEET_ADMIT FLEET_ADMIT_MEM_FREE_PCT FLEET_ADMIT_PRESSURE FLEET_ADMIT_LOAD_PER_CORE FLEET_ADMIT_RESERVE_MB FLEET_ADMIT_HYST_MB FLEET_ADMIT_SESSION_MB FLEET_ADMIT_SESSION_MB_MIN FLEET_ADMIT_SESSION_GROWTH FLEET_ADMIT_SETTLE_SECS FLEET_FILES_WARN_PCT FLEET_PTY_WARN_PCT FLEET_MEM_NOTIFY_COOLDOWN FLEET_TRANSCRIPT_KEEP_DAYS FLEET_TRANSCRIPT_HELPER_KEEP_HOURS FLEET_TRANSCRIPT_ARCHIVE FLEET_TRANSCRIPT_ARCHIVE_EVERY FLEET_TRANSCRIPT_ARCHIVE_BUDGET FLEET_MACHINE_MAX_SESSIONS FLEET_MACHINE_SESSIONS_STALE FLEET_MOD FLEET_AGENT_CFG FLEET_AGENT_LOCK FLEET_CFG_RESTART FLEET_CFG_RESTART_IDLE FLEET_CFG_RESTART_MAX FLEET_SIDEBAR_WIDTH_MAX FLEET_DASH_ORDER"

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
  # The team's defaults from the hub (issue #1722), FIRST so every file below
  # wins: written only by fleet-client-update.sh, each line fills a gap only.
  [ -f "$FLEET_CONF_DIR/hub-defaults.conf" ] && . "$FLEET_CONF_DIR/hub-defaults.conf"
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
  # The machine's ONE config file (issue #1623), read last so it wins: once
  # fleet-conf.sh migrate has folded the files above into it (each kept as .bak),
  # it is the only one there. Its [node] section sits in a FLEET_SHELL guard, so
  # the shell reads [common] + [client] from the same file, with no mirror.
  [ -f "$FLEET_CONF_DIR/fleet.conf" ] && . "$FLEET_CONF_DIR/fleet.conf"
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
# Kept past the source for fleet_identity_triplet, which re-reads the global conf
# from a clean slate (issue #1498).
_FLEET_LIB_DIR="$_flib_here"
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
# Once the machine has its ONE config file (issue #1623) that file is the login's
# settings file — a write lands there, never in a fleet.settings it replaced.
fleet_settings_file() {
  if [ -f "$FLEET_CONF_DIR/fleet.conf" ]; then printf '%s/fleet.conf' "$FLEET_CONF_DIR"
  else printf '%s/fleet.settings' "$FLEET_CONF_DIR"; fi
}
# The machine's ONE config file (issue #1623) — may not exist yet (fleet-conf.sh).
fleet_machine_conf_file() { printf '%s/fleet.conf' "$FLEET_CONF_DIR"; }

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
  # $FLEET_CONF_DIR/fleet.conf is the MACHINE's config (issue #1623), never the
  # legacy flat conf of a fleet named `fleet` — the default session name.
  case "$sess" in fleet|shell|hub-defaults) old='' ;; esac     # …nor the shell's shell.conf, nor the hub's defaults (#1722)
  if   [ -f "$new" ]; then printf '%s' "$new"
  elif [ -n "$old" ] && [ -f "$old" ]; then printf '%s' "$old"
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
    case "$sess" in fleet|shell|hub-defaults) continue ;; esac  # the machine's config + the shell's (#1623) + the hub's defaults (#1722), not fleets
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
  [ -n "${CLAUDE_SECURESTORAGE_CONFIG_DIR:-}" ] && return 0   # inherited hub-managed account (#1415)
  local _bin label tok
  _bin="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)"
  [ -n "$_bin" ] && [ -x "$_bin/fleet-account.sh" ] || return 0
  label="$(bash "$_bin/fleet-account.sh" active 2>/dev/null)"
  [ -n "$label" ] || return 0                          # multi-account off → ambient login
  tok="$(bash "$_bin/fleet-account.sh" token "$label" 2>/dev/null)"
  [ -n "$tok" ] || return 0
  fleet_claude_export_auth "$tok"
  return 0
}

# fleet_claude_export_auth <token-file-line> — export the credential a claude for
# one pool account runs on. A plain token (`claude setup-token`) goes in
# CLAUDE_CODE_OAUTH_TOKEN, as it always has. The marker `hub:<label>` (issue
# #1415) means the account is hub-managed: the ccquota agent keeps a SHORT-LIVED
# token in <accounts>/<label>.hub/.credentials.json and renews it before expiry.
# Claude Code re-reads that file on every request only when pointed at it through
# CLAUDE_SECURESTORAGE_CONFIG_DIR — the env var is read ONCE, at launch, so a
# session started on it would die when the token expires (measured, #1415).
# Sourced-library rules: no `set`, every expansion defaulted, always returns 0.
fleet_claude_export_auth() {
  case "${1:-}" in
    '') ;;
    hub:*)
      unset CLAUDE_CODE_OAUTH_TOKEN
      export CLAUDE_SECURESTORAGE_CONFIG_DIR="${FLEET_ACCOUNTS_DIR:-${FLEET_CONF_DIR:-$HOME/.config/claude-fleet}/accounts}/${1#hub:}.hub" ;;
    *)
      unset CLAUDE_SECURESTORAGE_CONFIG_DIR
      export CLAUDE_CODE_OAUTH_TOKEN="$1" ;;
  esac
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

# ---- view sessions (issue #1489) ----------------------------------------------
# A shell or proxy client of this machine's fleet (fleet-remote-view.sh attach)
# gets a GROUPED session of its own, `<fleet>@view-<id>`: the fleet's windows,
# its own current window — so two people looking at one machine each see the row
# they picked. tmux then holds every window under two session names, and asked
# which session a window, pane or client is in (a bare session_name from a
# `-t @w` / `-t %p` / `$TMUX_PANE` context, or with no -t at all) it answers with
# the MOST RECENTLY ACTIVE of them — a shell typing on m4 would make every hook
# in every worker pane resolve to its view session. Two rails:
#   • FLEET_SESSION_FMT — the fleet's own name from any context: a grouped
#     session's group is named after the fleet session it was grouped onto, so the
#     group name is the fleet's, and an ungrouped fleet has none. Every
#     display-message that resolves a window / pane / client to its fleet goes
#     through it (fleet-view-session-selftest.sh lints the bare session_name
#     form). fleet_session_canon does the same to a name already in hand.
#   • fleet_lw (below fleet_sockets) — `list-windows -a` prints every window once
#     PER SESSION that holds it; fleet_lw drops the view sessions' rows, so a
#     fleet script sees each window exactly once, under the fleet's name — the
#     pre-#1489 output byte for byte while no view session exists.
# A view session is never a fleet: fleet_sockets keys on the conf, and the
# list-sessions walkers (fleet-restore, the collector) skip it by name.
FLEET_SESSION_FMT='#{?#{session_group},#{session_group},#{session_name}}'
# fleet_session_canon <name> — the fleet session a session name belongs to.
fleet_session_canon() { printf '%s' "${1%%@view-*}"; }
# fleet_is_view_session <name> — a `<fleet>@view-<id>` session (never a fleet).
fleet_is_view_session() { case "${1:-}" in *@view-*) return 0 ;; esac; return 1; }

# fleet_pane_fmt <fmt> — <fmt> expanded for the CALLER'S OWN pane ($TMUX_PANE), or
# nothing + rc 1 when $TMUX_PANE is unset (issue #1537 ④). Never `-t ""`: tmux
# reads an empty target as "the current pane", which from a hook or a subshell
# that lost TMUX_PANE is whichever pane the operator happens to be looking at — a
# sender's @issue / @worktree read off someone else's window. Every read of the
# caller's own binding (fleet_seat, fleet_from_marker, fleet-comment.sh,
# fleet-claim-brief.sh, fleet-evidence.sh) goes through here.
fleet_pane_fmt() {
  [ -n "${TMUX_PANE:-}" ] || return 1
  tmux display-message -p -t "$TMUX_PANE" "$1" 2>/dev/null
}
# fleet_pane_lost — 0 when the caller is INSIDE tmux ($TMUX set) yet has no
# $TMUX_PANE: the one state where a pane-identity read would silently fall back to
# the operator's current pane. A daemon (no $TMUX at all) is not this.
fleet_pane_lost() { [ -n "${TMUX:-}" ] && [ -z "${TMUX_PANE:-}" ]; }

# The tmux session the caller is running in (pane-targeted, client fallback).
fleet_current_session() {
  local s
  s=$(tmux display-message -p -t "${TMUX_PANE:-}" "$FLEET_SESSION_FMT" 2>/dev/null)
  [ -z "$s" ] && s=$(tmux display-message -p "$FLEET_SESSION_FMT" 2>/dev/null)
  printf '%s' "$s"
}

# _fleet_conf_sans_global <conf> → the conf's text minus every line assigning a
# $_FLEET_GLOBAL_ONLY key (`[export ]KEY=`), for the callers to eval. ONE awk that
# takes the space-separated list as it is (issue #1530): the `grep -Ev` it replaces
# needed the list joined with `|`, and `${_FLEET_GLOBAL_ONLY// /|}` — a pattern
# substitution over ~3.7 KB — cost ~95 ms per call on macOS's bash 3.2 under a
# UTF-8 locale (13 ms under C), on every conf load of every hot path.
_fleet_conf_sans_global() {
  awk -v g=" $_FLEET_GLOBAL_ONLY " '{
    k = $0; sub(/^[ \t]*/, "", k)
    if (k ~ /^export[ \t]/) sub(/^export[ \t]+/, "", k)
    if (match(k, /^[A-Za-z0-9_]+=/) && index(g, " " substr(k, 1, RLENGTH - 1) " ")) next
    print
  }' "$1"
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
  local _flc_txt; _flc_txt=$(_fleet_conf_sans_global "$conf")
  eval "$_flc_txt"
  # The hub switch is per fleet (issue #1539): a conf that spells CCQUOTA_FLEET
  # hands ITS value to whatever this shell spawns (the claude in a pane, its hooks),
  # not just to this shell. A conf that does not spell it touches nothing.
  case "
$_flc_txt" in *"
CCQUOTA_FLEET="*|*"
export CCQUOTA_FLEET="*) export CCQUOTA_FLEET ;; esac
  # Window-aware (issue #788): inside a pane of THIS fleet whose window belongs to a
  # hosted repo, that repo's overlay goes on top — so every in-pane consumer (hooks,
  # commands/*.md, the launcher, the claim brief) sees its own repo's MAIN/base/model
  # without learning about repos. A fleet with no repos/ dir returns HERE, before any
  # tmux call: the degenerate case is byte-for-byte what it was. So does a caller
  # outside tmux (daemons), or one loading ANOTHER fleet's conf from inside a pane.
  [ -d "$FLEET_CONF_DIR/fleets/${1:-_}/repos" ] || return 0
  [ -n "${TMUX:-}" ] && [ -n "${TMUX_PANE:-}" ] || return 0
  local _wr
  [ "$(tmux display-message -p -t "$TMUX_PANE" "$FLEET_SESSION_FMT" 2>/dev/null)" = "$1" ] || return 0
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

# fleet_window_loop <sess> <window-target> → `active <reason>` | `none <reason>`
# (issue #1331), exit 0 iff active. "This window has a Loop pending": its @loop mark
# (ScheduleWakeup / CronCreate, written by the PostToolUse hook, expiry judged here
# by the reader) or a fleet-loop.py ledger that will still deliver. The ONE answer —
# bin/fleet_loop_mark.py is the implementation, Python readers import it directly.
# A window with neither option set answers `none unset` with one tmux read.
fleet_window_loop() {
  local sess="${1:-}" t="${2:-}" raw bin
  [ -n "$t" ] || { echo 'none no-target'; return 1; }
  raw=$(_fleet_tmux "$sess" display-message -p -t "$t" '#{@loop}#{@handoff_manifest}' 2>/dev/null)
  [ -n "$raw" ] || { echo 'none unset'; return 1; }
  bin="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)"
  if [ -n "${TMUX:-}" ]; then python3 "$bin/fleet_loop_mark.py" window "$t"
  else python3 "$bin/fleet_loop_mark.py" window "$t" --socket-name "$(fleet_socket "$sess")"; fi
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
  [ -n "$sess" ] || sess=$(_fleet_tmux '' display-message -p -t "$t" "$FLEET_SESSION_FMT" 2>/dev/null)
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
  local want f
  want=$(fleet_norm_repo "${2:-}"); [ -n "$want" ] || return 1
  f=$(fleet_repo_conf_file "$1" "$want")
  if [ "$(fleet_norm_repo "${FLEET_REPO:-}")" != "$want" ]; then
    [ -f "$f" ] || return 1
    eval "unset $_FLEET_REPO_SCOPED"
  fi
  [ -f "$f" ] || return 0
  eval "$(_fleet_conf_sans_global "$f")"
  return 0
}

# fleet_load_repo_conf <sess> <repo> — like fleet_load_conf, but for a NAMED repo
# rather than the caller's window: the fleet conf, then <repo>'s overlay. Returns 1
# when the fleet does not host <repo> (the fleet conf is still loaded).
fleet_load_repo_conf() {
  local conf; conf=$(fleet_conf_file "${1:-}")
  # A multi-repo fleet first puts the per-repo keys back to what they were before
  # ANY conf was loaded (issue #978): else, in a shell that already applied repo B's
  # overlay (a pane of B spawning for A), a key A's overlay leaves unset would keep
  # B's value instead of falling back to the fleet's. One-repo fleet: untouched.
  fleet_has_repo_overlays "${1:-}" && _fleet_repo_keys_reset
  if [ -f "$conf" ]; then
    eval "$(_fleet_conf_sans_global "$conf")"
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

# fleet_hub_repo_shorts <cache> → fleet_repo_shorts' lines for the repos the hub
# cache's rows name (issue #1680): field 5 of every `wid:` line, owner/name only,
# sorted — the shell's list has no conf, so its repos are the rows'. Short tags
# are the derived ones (no conf to carry an override), deduplicated the same way.
fleet_hub_repo_shorts() {
  [ -s "${1:-}" ] || return 0
  awk -F'\037' '$1 ~ /^wid:/ && $5 ~ /^[^\/ ]+\/[^\/ ]+$/ { print $5 }' "$1" | LC_ALL=C sort -u \
  | awk '{
      n = $0; sub(/.*\//, "", n); s = tolower(n); gsub(/[^a-z0-9]+/, " ", s); k = split(s, w, " "); o = ""
      if (k >= 2) { for (i = 1; i <= k && length(o) < 3; i++) o = o substr(w[i], 1, 1) }
      else o = substr(w[1], 1, 2)
      sl = $0; gsub(/\//, "-", sl); gsub(/[^A-Za-z0-9._-]/, "", sl)
      r[NR] = $0; g[NR] = sl; t[NR] = o; c[o]++ }
    END { for (i = 1; i <= NR; i++) { o = t[i]; if (c[o] > 1) { o = r[i]; sub(/.*\//, "", o) }
                                       print r[i] "\t" g[i] "\t" o } }'
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
# THE SHELL (FLEET_SHELL=1, issue #1680) has no conf to host a repo: its list is
# the hub's rows (FLEET_SIDEBAR_SOURCE=hub, #1480), across machines, so its repos
# are the ones those rows name — each `wid:` line's repo field in the hub cache
# (global/remote_<sess>, fleet-hub-sessions.sh client mode), sorted, never a
# machine's conf. 2+ of them group the list exactly as a 2+ repo fleet does.
# shellcheck disable=SC2034  # RMANY/RSHORTMAP/RGRPMAP/RHEADS/RNREPO are caller-facing OUTPUT globals
fleet_dash_repo_frame() {
  local sess="${1:-}" shorts r s sh all=''
  RMANY=0; RSHORTMAP=$'\n'; RGRPMAP=$'\n'; RHEADS=''; RNREPO=0
  if [ ! -d "$FLEET_CONF_DIR/fleets/${sess:-_}/repos" ]; then
    [ "${FLEET_SHELL:-0}" = 1 ] && [ -n "$sess" ] || return 0
    shorts=$(fleet_hub_repo_shorts "$FLEET_C/global/remote_$sess")
  else
    shorts=$(fleet_repo_shorts "$sess")
  fi
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
     && [ "$(tmux display-message -p -t "$TMUX_PANE" "$FLEET_SESSION_FMT" 2>/dev/null)" = "$sess" ]; then
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

# ---- a wedged socket: a dying server that drops every client (issue #1729) ----
# A tmux server told to exit (kill-server, SIGTERM, its last session gone) stays
# alive until every connected client disconnects — and meanwhile accepts each NEW
# connection and closes it at once. One client that never answers (an attach from
# an ssh whose network froze, a hung control client) pins it there for good, and
# every `tmux -L <label> …` — ls, has-session, new-session, fleet-up's — prints
# `server exited unexpectedly` and fails. tmux never replaces a socket it can
# connect to, so nothing recovers until the file is removed (2026-10-05, m4). A
# socket NOBODY listens on is not this: tmux unlinks that one itself.
#
# fleet_socket_path <label> — the -L socket's path, as tmux builds it.
fleet_socket_path() {
  local tdir="${TMUX_TMPDIR:-/tmp}"
  printf '%s/tmux-%s/%s' "${tdir%/}" "$(id -u)" "$1"
}
# fleet_socket_wedged <label> → rc 0 when the socket file is there and the server
# on it drops every client (the condition above), 1 otherwise. One tmux call.
fleet_socket_wedged() {
  [ -S "$(fleet_socket_path "$1")" ] || return 1
  case "$(tmux -L "$1" list-sessions 2>&1 >/dev/null)" in
    *'server exited unexpectedly'*) return 0 ;;
  esac
  return 1
}
# fleet_socket_heal <label> → when wedged, remove the socket so the next tmux call
# starts a fresh server, print ONE line saying so (the caller routes it: stderr or
# its log) and append it to $FLEET_CONF_DIR/socket-heal.log (fleet-doctor's
# `socket` row); rc 0. Not wedged → silent, rc 1. Never silent when it removes
# anything: the operator needs to know this machine's fleet just died. The old
# server is left alone — it has no sessions, it exits when its stuck client goes,
# and that exit does not touch the new server's socket.
fleet_socket_heal() {
  local sp mt line
  fleet_socket_wedged "$1" || return 1
  sp=$(fleet_socket_path "$1")
  mt=$(stat -f %m "$sp" 2>/dev/null || stat -c %Y "$sp" 2>/dev/null)
  mt=$(date -r "$mt" '+%Y-%m-%d %H:%M' 2>/dev/null || date -d "@$mt" '+%Y-%m-%d %H:%M' 2>/dev/null)
  rm -f "$sp" 2>/dev/null
  if [ -e "$sp" ]; then
    line="fleet: socket $sp is stale (its server is exiting and drops every client — tmux says \"server exited unexpectedly\") and could NOT be removed; rm it by hand"
  else
    line="fleet: cleared stale socket $sp (socket from ${mt:-?}; its server was exiting and dropped every client — tmux said \"server exited unexpectedly\"). This fleet's tmux server died; a fresh one starts now"
  fi
  printf '%s\n' "$line"
  [ -n "${FLEET_CONF_DIR:-}" ] && [ -d "$FLEET_CONF_DIR" ] \
    && printf '%s\t%s\t%s\n' "$(date +%s)" "$1" "$line" >> "$FLEET_CONF_DIR/socket-heal.log" 2>/dev/null
  return 0
}
# fleet_wedged_note → when no fleet answers, why: " — WEDGED: <label> (…)" for
# each configured fleet whose socket is wedged, nothing otherwise. A daemon's
# «no fleet sessions found» appends it, so «nobody is using it» and «it cannot
# start» stop reading the same.
fleet_wedged_note() {
  local sess conf tab w=''
  [ -d "${FLEET_CONF_DIR:-}" ] || return 0
  tab=$(printf '\t')
  while IFS="$tab" read -r sess conf; do
    [ -n "$sess" ] || continue
    fleet_socket_wedged "$sess" && w="$w $sess"
  done <<EOF
$(fleet_each_conf)
EOF
  [ -n "$w" ] || return 0
  printf ' — WEDGED:%s (socket left by a dying tmux server; every client gets "server exited unexpectedly" — fleet-up.sh or the next fleet-restore --auto clears it)' "$w"
}

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

# Where claude and tmux live when PATH does not say (issue #1774, #1784). A shell
# started by ssh or a daemon on m4 had neither ~/.local/bin (Claude Code's native
# install) nor /opt/homebrew/bin (tmux) on PATH, so `exec claude` failed and a
# restore parked at a shell twice. FLEET_TOOL_DIRS is the fixed search order after
# PATH; a selftest points it at a sandbox.
FLEET_TOOL_DIRS="${FLEET_TOOL_DIRS:-$HOME/.local/bin /opt/homebrew/bin /usr/local/bin}"

# fleet_path_fill — PATH with every existing FLEET_TOOL_DIRS dir it lacks APPENDED:
# the order PATH already has wins, so a PATH that finds both tools is unchanged.
fleet_path_fill() {
  local dir out=$PATH
  for dir in $FLEET_TOOL_DIRS; do
    [ -d "$dir" ] || continue
    case ":$out:" in *":$dir:"*) ;; *) out="${out:+$out:}$dir" ;; esac
  done
  printf '%s' "$out"
}

# fleet_find_tool <claude|tmux> — the binary to run: $FLEET_CLAUDE_BIN /
# $FLEET_TMUX_BIN when it is executable, else the bare name when PATH (or a
# function) answers — byte for byte the old `exec claude` — else the first
# FLEET_TOOL_DIRS hit. rc 1 + one stderr line naming every place tried.
fleet_find_tool() {
  local name="$1" pin='' dir tried=''
  case "$name" in claude) pin=${FLEET_CLAUDE_BIN:-} ;; tmux) pin=${FLEET_TMUX_BIN:-} ;; esac
  if [ -n "$pin" ]; then
    [ -x "$pin" ] && { printf '%s\n' "$pin"; return 0; }
    tried="$pin "
  fi
  command -v "$name" >/dev/null 2>&1 && { printf '%s\n' "$name"; return 0; }
  tried="${tried}PATH"
  for dir in $FLEET_TOOL_DIRS; do
    [ -x "$dir/$name" ] && { printf '%s\n' "$dir/$name"; return 0; }
    tried="$tried $dir/$name"
  done
  printf 'fleet: %s not found — tried %s\n' "$name" "$tried" >&2
  return 1
}

# ---- a window's ROLE: home | panel | worker (issue #1844, EPIC #1851 C5) --------
# A window NAME is the person's to change (`prefix ,`): renaming home, or naming a
# worker `home`, made every name-keyed reader — home's heal, "is this a fleet", the
# session caps — pick the wrong window. So the fleet stamps what a window IS as
# @fleet_role when it opens one (fleet-up/hub-session: home and the plan panel;
# dash-issue-session / dash-raw-session / fleet-restore: worker) and reads it back
# through FLEET_ROLE_FMT / fleet_win_role, never the name. A window with no stamp
# (opened by an older version) falls back to the old name rule — so a fleet with
# no stamps reads byte for byte as before.
# The format prints `=<role>` for a stamped window and the bare NAME otherwise;
# FLEET_ROLE_AWK's frole() turns either into the role — one rule, in one place,
# and a reader handed plain names (an older server, a test's canned rows) sees
# exactly the old name rule. A window name may hold spaces: the format goes LAST
# on a row that has to stay split on spaces, or the caller cuts it off itself.
FLEET_ROLE_FMT='#{?@fleet_role,=#{@fleet_role},#{window_name}}'
FLEET_ROLE_AWK='function frole(t) { if (t ~ /^=/) return substr(t, 2); if (t == "home") return "home"; if (t == "plan" || t == "dash" || t == "backlog") return "panel"; return "worker" }'

# fleet_win_role <window> [socket] → home | panel | worker (rc 1: no such window)
fleet_win_role() {
  local r
  if [ -n "${2:-}" ]; then r=$(tmux -L "$2" display-message -p -t "$1" "$FLEET_ROLE_FMT" 2>/dev/null)
  else r=$(tmux display-message -p -t "$1" "$FLEET_ROLE_FMT" 2>/dev/null); fi
  [ -n "$r" ] || return 1
  printf '%s\n' "$r" | awk "$FLEET_ROLE_AWK"' { print frole($0) }'
}

# fleet_win_role_stamp <window> <home|panel|worker> [socket] — the one writer.
fleet_win_role_stamp() {
  if [ -n "${3:-}" ]; then tmux -L "$3" set-option -w -t "$1" @fleet_role "$2" 2>/dev/null
  else tmux set-option -w -t "$1" @fleet_role "$2" 2>/dev/null; fi
  return 0
}

# fleet_server_resident <socket> [session] — a fleet's server outlives its last session
# (issue #1784): `exit-empty off`, so the last window closing never takes the
# server — and with it every client view of this machine — down.
fleet_server_resident() {
  tmux -L "$1" set-option -s exit-empty off 2>/dev/null
  [ -n "${2:-}" ] && fleet_home_resident "$1" "$2"
  return 0
}

# fleet_server_conf — the file a fleet's tmux server starts from (issue #1845):
# conf/tmux-fleet-server.conf loads the fleet layer first, then the person's own
# tmux conf with -q, so an error in theirs skips only theirs.
fleet_server_conf() { printf '%s\n' "${_FLEET_LIB_DIR%/}/../conf/tmux-fleet-server.conf"; }

# fleet_server_new_session <socket> <new-session args…> — `new-session` on a fleet's
# socket, starting the server from fleet_server_conf when it is not running yet
# (`-f` is read only at server start; a live server ignores it). No such file (a
# partial install) → tmux's default config, as before.
fleet_server_new_session() {
  local sock="$1" cf; shift
  cf=$(fleet_server_conf)
  if [ -f "$cf" ]; then tmux -L "$sock" -f "$cf" new-session "$@"
  else tmux -L "$sock" new-session "$@"; fi
}

# fleet_tmuxconf_check <socket> — is the fleet layer live on that server? One line:
#   ok <marker>                     — the marker matches conf/tmux-attention.conf's,
#                                     the reap hook and the rename guard are on
#   stale <live> (want <marker>)    — rules on, from an older conf (rc 2)
#   missing <what…>                 — the layer is not on that server (rc 1)
# `fleet doctor`'s tmuxconf row (issue #1845).
fleet_tmuxconf_check() {
  local want live miss=''
  want=$(sed -n 's/^set -g @fleet_conf_loaded "\([^"]*\)".*/\1/p' "${_FLEET_LIB_DIR%/}/../conf/tmux-attention.conf" 2>/dev/null | tail -1)
  live=$(tmux -L "$1" show-options -gqv @fleet_conf_loaded 2>/dev/null)
  [ -n "$live" ] || miss="$miss @fleet_conf_loaded"
  tmux -L "$1" show-hooks -g window-unlinked 2>/dev/null | grep -q 'fleet-window-reap\.sh' || miss="$miss 回收hook"
  [ "$(tmux -L "$1" show-options -gv allow-rename 2>/dev/null)" = off ] || miss="$miss 改名保护"
  if [ -n "$miss" ]; then printf 'missing%s\n' "$miss"; return 1; fi
  if [ -n "$want" ] && [ "$live" != "$want" ]; then printf 'stale %s (want %s)\n' "$live" "$want"; return 2; fi
  printf 'ok %s\n' "$live"
}

# fleet_home_resident <socket> <session> [window] — the fleet's `home` window never closes
# (issue #1784): its shell exiting (a stray Ctrl+D, `exit`) leaves the pane in
# place (`remain-on-exit`) and a window `pane-died` hook starts a fresh shell in
# it, so the session always keeps one window however many tasks end. No home
# window → nothing (a FLEET_DASH_WINDOW=1 fleet rests on its dash instead).
fleet_home_resident() {
  local sock="$1" sess="$2" win="${3:-}"
  [ -n "$win" ] || win=$(tmux -L "$sock" list-windows -t "$sess" -F "#{window_id} $FLEET_ROLE_FMT" 2>/dev/null \
                         | awk "$FLEET_ROLE_AWK"' { t=$0; sub(/^[^ ]* /, "", t) } frole(t)=="home" {print $1; exit}')
  [ -n "$win" ] || return 0
  fleet_win_role_stamp "$win" home "$sock"       # found by name once; by role from now on (#1844)
  tmux -L "$sock" set-option -w -t "$win" remain-on-exit on 2>/dev/null
  tmux -L "$sock" set-hook -w -t "$win" pane-died 'respawn-pane -k' 2>/dev/null
  return 0
}

# fleet_home_heal <socket> <session> — the tick's backstop for fleet_home_resident
# (issue #1801). tmux 3.3/3.4 on a busy box can miss the SIGCHLD of home's exited
# shell: the pane reads dead, the shell stays a zombie, and `pane-died` never fires
# until some other child of that server exits — on a quiet node, never. A home
# pane found dead is respawned here. Prints `healed <window id>` when it did; rc 0.
fleet_home_heal() {
  local win
  win=$(tmux -L "$1" list-windows -t "$2" -F "#{window_id} #{pane_dead} $FLEET_ROLE_FMT" 2>/dev/null \
        | awk "$FLEET_ROLE_AWK"' { t=$0; sub(/^[^ ]* [^ ]* /, "", t) } $2==1 && frole(t)=="home" {print $1; exit}')
  [ -n "$win" ] || return 0
  tmux -L "$1" respawn-pane -k -t "$win" 2>/dev/null && printf 'healed %s\n' "$win"
  return 0
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

# ---- fleet_lw: `list-windows -a`, every window ONCE (issue #1489) -----------
# A view session (`<fleet>@view-<id>`, see FLEET_SESSION_FMT) shares the fleet's
# windows, and `list-windows -a` lists a window once per session holding it — so
# a bare scan counted a worker twice and fleet-peer-send called it AMBIGUOUS
# (why #1424 first settled for a plain client). fleet_lw is the one scan every
# fleet script uses; fleet-view-session-selftest.sh lints the bare form.
#
# fleet_lw_fmt <fmt> — the format fleet_lw asks tmux for: `@wid:$sid:<session> `
# in front of the caller's, split off again by fleet_lw_filter. The shape is
# unmistakable — a session name never holds `:`, so the three colon-joined fields
# then a SPACE (a fleet session name carries none, fleet-up sanitizes; a view id
# is [A-Za-z0-9-]) cannot be a row of anyone else's, and a row without it (a
# selftest's fake tmux printing canned lines) passes through untouched. No
# control byte: tmux ≤3.4 prints one as the literal `\037`.
fleet_lw_fmt() { printf '#{window_id}:#{session_id}:#{session_name} %s' "$1"; }
# fleet_lw_filter — stdin: fleet_lw_fmt rows; stdout: the caller's rows, one per
# WINDOW — a view session's rows dropped, a window seen twice printed once, a row
# that is not fleet_lw_fmt's left as it is.
fleet_lw_filter() {
  awk '{ if ($0 !~ /^@[0-9]+:\$[0-9]+:[^ ]+ /) { print; next }    # not a fleet_lw_fmt row (a test shim: canned rows): untouched
         i = index($0, " "); pre = substr($0, 1, i - 1); id = pre; sub(/:.*/, "", id)
         s = pre; sub(/^[^:]*:[^:]*:/, "", s)
         if (index(s, "@view-") || (id in seen)) next
         seen[id] = 1; print substr($0, i + 1) }'
}
# fleet_lw <fmt> [tmux-cmd…] — `<tmux-cmd> list-windows -a -F <fmt>`, every window
# once. The command defaults to bare `tmux` (a pane's own server); pass
# `tmux -L <sock>`, a `tm` array or a wrapper function for another. tmux's exit
# status is the result's, so a dead server still reads as the failure it is.
fleet_lw() {
  local fmt="$1" out; shift
  [ $# -gt 0 ] || set -- tmux
  out=$("$@" list-windows -a -F "$(fleet_lw_fmt "$fmt")" 2>/dev/null) || return $?
  [ -n "$out" ] || return 0
  printf '%s\n' "$out" | fleet_lw_filter
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
    fleet_lw "$fmt" tmux -L "$label"
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

# Is this transcript one a crash-restore must NOT resume (issue #1296)? Stricter
# than fleet_internal_transcript, which history/autoclean key off and which stays
# as it is. On 2026-10-03 a restore reopened four windows — the memory-system
# owner's among them — on classifier transcripts: the newest file in a worktree's
# project dir was the fleet's own `claude -p`, not the session that lived there.
# Two kinds, and FLEET_HELPER_REASON says which matched:
#   marker  a known helper prompt in the head (the classifier rubrics, the
#           retired summarizer's, the sleep digest's) — never a real session
#   thin    under 50 lines with no tool call — a helper with an unknown prompt, or
#           a session that never did anything. A picker MAY still fall back to a
#           thin one when nothing substantive exists (fleet_newest_resumable_session).
# Canonical copy; bin/.fleet-restore-resolve.py mirrors it (helper_reason),
# and fleet-restore-helper-selftest.sh holds the two on the same fixtures.
FLEET_HELPER_REASON=''
fleet_is_helper_transcript() {   # $1=jsonl path → 0 = helper (see FLEET_HELPER_REASON), 1 = resumable
  local f="${1:-}" head_bytes n
  FLEET_HELPER_REASON=''
  [ -f "$f" ] || return 1
  if fleet_internal_transcript "$f"; then FLEET_HELPER_REASON=marker; return 0; fi
  head_bytes=$(head -c 16384 "$f" 2>/dev/null)
  case "$head_bytes" in
    *"You write the status card of a paused coding assistant"*) FLEET_HELPER_REASON=marker; return 0 ;;
  esac
  n=$(wc -l < "$f" 2>/dev/null | tr -d ' ')
  case "$n" in ''|*[!0-9]*) return 1 ;; esac
  if [ "$n" -lt 50 ] && ! grep -q '"type":"tool_use"' "$f" 2>/dev/null; then
    FLEET_HELPER_REASON=thin; return 0
  fi
  return 1
}

# Newest RESUMABLE session id in a transcript dir, or empty (issue #1296): skip
# every helper; when only `thin` ones remain, the newest thin one beats nothing —
# a short real chat is still that window's conversation. Each skip is printed to
# stderr as `skip <id> <reason>` for the caller's log. Same no-`| head` rule as
# fleet_newest_human_session below.
fleet_newest_resumable_session() {
  local dir="${1:-}" list f n=0 thin=''
  [ -d "$dir" ] || return 0
  list=$(ls -t "$dir"/*.jsonl 2>/dev/null)
  [ -n "$list" ] || return 0
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    n=$((n + 1)); [ "$n" -gt 200 ] && break
    if fleet_is_helper_transcript "$f"; then
      printf 'skip %s %s\n' "$(basename "$f" .jsonl)" "$FLEET_HELPER_REASON" >&2
      [ "$FLEET_HELPER_REASON" = thin ] && [ -z "$thin" ] && thin=$(basename "$f" .jsonl)
      continue
    fi
    basename "$f" .jsonl
    return 0
  done <<EOF
$list
EOF
  [ -n "$thin" ] && printf '%s\n' "$thin"
  return 0
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
  # The caller's OWN pane only (fleet_pane_fmt): no TMUX_PANE ⇒ no binding ⇒ no
  # seat — never the current pane's (issue #1537 ④).
  o=$(fleet_pane_fmt '#{@issue}|#{@worktree}')
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

# Retire a SLEEPING worker's sleep record before its window is killed (issue
# #1244). A sleeper is reaped WITHOUT a wake — its pane is the park page, no agent
# — so the record must stop describing a retained worker, or a crash-restore could
# resurrect a window whose worktree the reap just removed. A non-sleeper is a
# no-op (rc 0). rc 1 = the record could not be retired (a wake raced us, the lock
# is held, the original agent is somehow alive) — the caller must NOT kill.
# Args: <@window-id> <fleet-session>
fleet_sleep_dispose() {
  local _win="${1:-}" _sess="${2:-}" _life _bin
  [ -n "$_win" ] && [ -n "$_sess" ] || return 0
  _life=$(tmux -L "$(fleet_socket "$_sess")" display-message -p -t "$_win" '#{@worker_lifecycle}' 2>/dev/null) || return 0
  [ "$_life" = sleeping ] || return 0
  _bin="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)"
  python3 "$_bin/fleet-sleep.py" dispose --session "$_sess" "$_win" >/dev/null
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
# caller's `gh pr list --state merged` output). A line may carry the PR's head sha
# after its name (`<branch><TAB|space>…<40-hex sha>`, issue #1842): when ANY line for
# the branch does, a merged PR counts only if the branch is still AT (or behind) one
# of those heads, or its tip is already on the base — a commit made after the merge
# would otherwise be reaped with the worktree. A bare name is the pre-#1842 answer.
# A caller that only wants the two safe outcomes can just test the return code.
# Safe under a `set -u` caller.
fleet_reap_ok() {
  local wtdir="${1:-}" root="${2:-}" branch="${3:-}" head="${4:-}" base="${5:-}" merged="${6:-}"
  # $7 (optional, issue #1542): the merged PR's epoch — the probe waives the
  # young-agent / `looping` gates for an agent alive at that merge (#1329, #1356).
  local merged_at="${7:-}"
  case "$merged_at" in ''|0|*[!0-9]*) merged_at="" ;; esac
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
          --socket-names "$_reap_sockets" ${merged_at:+--merged-at "$merged_at"} >/dev/null 2>&1; then
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
  if [ -n "$branch" ] && fleet_reap_merged_at_head "$root" "$branch" "$head" "$base" "$merged"; then
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

# fleet_reap_ok's merged-PR evidence (issue #1842). rc 0 = <branch> has a merged PR
# AND nothing on the branch post-dates it: the tip IS (or is behind) a merged PR's
# head sha, or is already on <base>. Lines with no sha (an older caller) keep the
# old name-only answer; a sha the repo does not hold fails closed (kept).
# Args: <repo-root> <branch> <head> <base> <merged-lines>
fleet_reap_merged_at_head() {
  local root="${1:-}" branch="${2:-}" head="${3:-}" base="${4:-}" merged="${5:-}"
  local line tok shas="" named=0 tip
  while IFS= read -r line; do
    line=$(printf '%s' "$line" | tr '\t' ' ')
    [ "${line%% *}" = "$branch" ] || continue
    named=1
    for tok in ${line#"$branch"}; do
      case "$tok" in *[!0-9a-f]*) ;; *) [ "${#tok}" = 40 ] && shas="$shas $tok" ;; esac
    done
  done <<EOF
$merged
EOF
  [ "$named" = 1 ] || return 1
  [ -n "$shas" ] || return 0                         # name only: the pre-#1842 answer
  [ -n "$head" ] && [ -n "$root" ] || return 1
  tip=$(git -C "$root" rev-parse --verify -q "$head^{commit}" 2>/dev/null) || return 1
  for tok in $shas; do
    [ "$tip" = "$tok" ] && return 0
    git -C "$root" merge-base --is-ancestor "$tip" "$tok" 2>/dev/null && return 0
  done
  [ -n "$base" ] && git -C "$root" merge-base --is-ancestor "$tip" "$base" 2>/dev/null && return 0
  return 1
}

# Release the claim on an issue whose work did not land (issue #1842): drop this
# login's assignee — the assignee IS the claim (#283), so the dispatcher sees the
# issue as free again — and leave one record-only line saying why. The ONE copy:
# dash ⌃x (dash-reap.sh settle_issue) and the recovery page's q
# (session-end-hook.sh --recycle) both call it. The caller decides the issue is
# OPEN and unlanded. Args: <repo> <issue> <what happened, one clause>
fleet_issue_release_claim() {
  local repo="${1:-}" iss="${2:-}" what="${3:-}"
  [ -n "$repo" ] && [ -n "$iss" ] && command -v gh >/dev/null 2>&1 || return 0
  gh -R "$repo" issue edit "$iss" --remove-assignee @me >/dev/null 2>&1 || true
  gh -R "$repo" issue comment "$iss" --body "$what. The issue stays OPEN and the claim is released, so it can be picked up again.

<!-- fleet:no-relay -->" >/dev/null 2>&1 || true
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

# --- the fleet mod (issue #1335, EPIC #1334) ------------------------------------
# mod/fleet/ is a Claude Code plugin every fleet-launched Claude session loads
# (bin/fleet-claude.sh adds `--plugin-dir`). It writes three window options and
# nothing else of its own: @mod_state (`on` | `off:version`), @mod_ver (the mod's
# version) and @mod_alive (epoch seconds, rewritten every 15s while it lives).
# FLEET_MOD (global, default 1) switches the whole thing; 0 = byte for byte the
# launch of before the mod existed, and every fleet_mod_alive reads false.
#
# fleet_mod_on — is the mod switched on for this login? (the default lives HERE)
fleet_mod_on() { [ "${FLEET_MOD:-1}" != 0 ]; }

# fleet_mod_dir — the plugin folder beside this lib's bin/ (the live install's
# ~/.claude/fleet/mod/fleet), printed only when it holds a manifest; else exit 1.
fleet_mod_dir() {
  local d
  d="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." 2>/dev/null && pwd)/mod/fleet"
  [ -f "$d/.claude-plugin/plugin.json" ] || return 1
  printf '%s\n' "$d"
}

# fleet_mod_alive <win> [session] — exit 0 when <win>'s mod heartbeat is fresh
# (@mod_alive within FLEET_MOD_ALIVE_SECS, default 45 = three missed beats), so
# the caller takes the mod's path; 1 when stale, missing, non-numeric or
# FLEET_MOD=0 — take today's path, which is never removed (EPIC #1334 rule 2).
# Every EPIC member decides new-path-vs-old with THIS, never its own read.
# Inside a pane bare tmux is right; outside one, [session] picks the socket.
fleet_mod_alive() {
  local win="${1:-}" sess="${2:-}" at now max="${FLEET_MOD_ALIVE_SECS:-45}"
  [ -n "$win" ] || return 1
  fleet_mod_on || return 1
  if [ -n "${TMUX:-}" ] || [ -z "$sess" ]; then
    at=$(tmux display-message -p -t "$win" '#{@mod_alive}' 2>/dev/null)
  else
    at=$(_fleet_tmux "$sess" display-message -p -t "$win" '#{@mod_alive}' 2>/dev/null)
  fi
  case "$at" in ''|*[!0-9]*) return 1 ;; esac
  case "$max" in ''|*[!0-9]*) max=45 ;; esac
  now=$(date +%s)
  # A beat a few seconds in the future (clock skew between writer and reader) is fresh.
  [ $((now - at)) -le "$max" ]
}

# --- the mod's command inbox (issue #1337, EPIC #1334 C3) -----------------------
# A slash command the fleet used to TYPE into a pane (`/clear`, `/compact …`,
# `/model …`, the handoff pickup) is posted to the pane's inbox instead; the mod
# (mod/fleet/hooks/inbox.ts) takes it on its 1s timer and runs it with
# `$.command.run`, which the engine queues until the session is idle. No
# keystroke, no bracketed-paste race, no draft with "/clear" glued on.
#
#   $FLEET_CONF_DIR/global/mod-inbox/<socket-label>/<pane-id>/
#     <seq>.json   {"cmd":"/clear","args":"","from":"handoff-cycle"} — posted by
#                  rename from a dot-temp, so the mod never reads half a file
#     <seq>.taken  the mod's CLAIM: an atomic `mv` of the .json, so exactly one
#                  of {mod runs it, the poster cancels it} ever happens
#     <seq>.done   {"ok":true} | {"ok":false,"error":"…"} once the command ran
#     <seq>.cancel the poster gave up before the mod took it
#
# Keyed by socket label AND pane id: a pane id is unique per tmux SERVER only, and
# every fleet runs its own (issue #159) — `%7` exists once per fleet.
fleet_mod_inbox_root() { printf '%s/global/mod-inbox' "${FLEET_CONF_DIR:-$HOME/.config/claude-fleet}"; }

# fleet_mod_inbox_reset <socket-label> — empty that socket's inbox when its tmux
# SERVER is not the one that wrote it (issue #1538). A pane id is unique per server
# LIFETIME only: after a restart the new server hands out `%7` again, and a `/clear`
# left in the old `%7`'s dir (a poster SIGKILLed before it could cancel) would run
# in whatever session the new `%7` is. The inbox remembers its server as
# `.server` = `<pid>.<start_time>`; a different (or unreadable) server wipes every
# pane dir under the label first. Called before every post and by fleet-up when it
# starts the server. Never fails the caller.
fleet_mod_inbox_reset() {
  local sock="${1:-}" root id old=''
  sock="${sock##*/}"
  [ -n "$sock" ] || return 0
  id=$(tmux -L "$sock" display-message -p '#{pid}.#{start_time}' 2>/dev/null)
  case "$id" in [0-9]*.[0-9]*) : ;; *) return 0 ;; esac
  root="$(fleet_mod_inbox_root)/$sock"
  [ -f "$root/.server" ] && old=$(cat "$root/.server" 2>/dev/null)
  [ "$old" = "$id" ] && return 0
  if [ -d "$root" ]; then
    find "$root" -mindepth 1 -maxdepth 1 -name '[0-9]*' -exec rm -rf {} + 2>/dev/null
  fi
  mkdir -p "$root" 2>/dev/null || return 0
  printf '%s\n' "$id" > "$root/.server.$$" 2>/dev/null && mv -f "$root/.server.$$" "$root/.server" 2>/dev/null
  return 0
}

# fleet_session_command [--socket <label>] [--from <who>] <target> '/cmd args'
# Run a slash command in <target>'s Claude session through the mod. Exit codes —
# the caller falls back to today's send-keys path on 3, 4 and 5, and must NOT on
# 0 or 6 (the command ran, or is running: typing it again would run it twice):
#   0  executed (the mod wrote .done ok)
#   3  the mod is not here (fleet_mod_alive false, FLEET_MOD=0, no pane, no socket)
#   4  timed out before the mod TOOK it — cancelled, it will never run
#   5  the engine refused it (.done ok=false: unknown command, turn-bound hook…)
#   6  taken but not done within the wait — running (a long /compact); outcome unknown
#   2  usage
# Knobs: FLEET_MOD_TAKE_SECS (5) to be taken, FLEET_MOD_DONE_SECS (20) to finish.
# Outside a pane, --socket names the fleet's server (the label == the session).
fleet_session_command() {
  local sock='' from='' target line
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --socket) sock="${2:-}"; shift 2 ;;
      --from)   from="${2:-}"; shift 2 ;;
      *) break ;;
    esac
  done
  target="${1:-}" line="${2:-}"
  [ -n "$target" ] || return 2
  case "$line" in /?*) : ;; *) return 2 ;; esac
  fleet_mod_on || return 3
  [ -n "$sock" ] || sock="${TMUX%%,*}"
  sock="${sock##*/}"
  [ -n "$sock" ] || return 3
  # Always by label: from inside a pane `-L <its own label>` is the same server.
  local pane
  pane=$(tmux -L "$sock" display-message -p -t "$target" '#{pane_id}' 2>/dev/null)
  case "$pane" in %[0-9]*) : ;; *) return 3 ;; esac
  # fleet_mod_alive's [session] arg is the socket label (fleet_socket is identity).
  ( unset TMUX; fleet_mod_alive "$pane" "$sock" ) || return 3

  local cmd args dir seq f j t tw dw
  cmd="${line%% *}"; cmd="${cmd#/}"
  case "$line" in *' '*) args="${line#* }" ;; *) args='' ;; esac
  fleet_mod_inbox_reset "$sock"
  dir="$(fleet_mod_inbox_root)/$sock/${pane#%}"
  mkdir -p "$dir" 2>/dev/null || return 3
  seq="$(date +%s)-$$-${RANDOM:-0}"
  f="$dir/$seq"
  j=$(FC_CMD="/$cmd" FC_ARGS="$args" FC_FROM="${from:-?}" python3 -c '
import json, os
print(json.dumps({"cmd": os.environ["FC_CMD"], "args": os.environ["FC_ARGS"], "from": os.environ["FC_FROM"]}, ensure_ascii=False))' 2>/dev/null) || return 3
  printf '%s\n' "$j" > "$dir/.$seq.tmp" 2>/dev/null && mv -f "$dir/.$seq.tmp" "$f.json" 2>/dev/null || { rm -f "$dir/.$seq.tmp"; return 3; }

  tw="${FLEET_MOD_TAKE_SECS:-5}"; dw="${FLEET_MOD_DONE_SECS:-20}"
  case "$tw" in ''|*[!0-9]*) tw=5 ;; esac
  case "$dw" in ''|*[!0-9]*) dw=20 ;; esac
  t=0
  while [ -f "$f.json" ] && [ "$t" -lt $((tw * 4)) ]; do sleep 0.25 2>/dev/null || sleep 1; t=$((t + 1)); done
  if [ -f "$f.json" ]; then
    # Cancel by the same atomic rename the mod claims with: whichever mv wins decides.
    if mv "$f.json" "$f.cancel" 2>/dev/null; then rm -f "$f.cancel"; return 4; fi
  fi
  t=0
  while [ ! -f "$f.done" ] && [ "$t" -lt $((dw * 4)) ]; do sleep 0.25 2>/dev/null || sleep 1; t=$((t + 1)); done
  [ -f "$f.done" ] || return 6   # .taken stays: the mod writes .done when it finishes
  local ok
  ok=$(python3 -c 'import json,sys; print(1 if json.load(open(sys.argv[1])).get("ok") else 0)' "$f.done" 2>/dev/null)
  if [ "$ok" = 1 ]; then rm -f "$f.taken" "$f.done"; return 0; fi
  sed -n 's/.*"error" *: *"\([^"]*\)".*/fleet_session_command: refused: \1/p' "$f.done" >&2 2>/dev/null
  rm -f "$f.taken" "$f.done"
  return 5
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
  local pid ppid age exp addrs cwd cmdline anc
  fleet_listen_rows | while IFS="$(printf '\t')" read -r pid ppid age exp addrs cwd cmdline; do
    [ -n "$pid" ] || continue
    printf '%s' "$cmdline" | grep -Eq "$re" && continue
    anc="$(fleet_listen_anchor "$cwd")"; [ -n "$anc" ] || continue
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$pid" "$ppid" "$age" "$exp" "$addrs" "$cwd" "$cmdline" "$anc"
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
  local pid ppid age exp addrs cwd cmdline kind key top tcwd live
  printf '%s\n' "$rows" | while IFS="$(printf '\t')" read -r pid ppid age exp addrs cwd cmdline kind key; do
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
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$pid" "$ppid" "$age" "$exp" "$addrs" "$cwd" "$cmdline" "$kind" "$key" "$top"
  done
}

# fleet_reap_orphan_listeners [kill|dry] [minage-secs] — the periodic backstop
# (diskguard's tick). Kills each candidate's WHOLE tree from its top (an `npm run
# dev` wrapper and its node child go together). Prints one line per candidate:
# "reaped|would reap <pid> <exposure> <addrs> cwd=<cwd> age=<s>s top=<top>".
fleet_reap_orphan_listeners() {
  local mode="${1:-kill}" minage="${2:-0}" pid ppid age exp addrs cwd cmdline kind key top
  fleet_orphan_listeners "$minage" | while IFS="$(printf '\t')" read -r pid ppid age exp addrs cwd cmdline kind key top; do
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

# ---- a closed window takes its process trees with it (issue #1298) ------------
# The reapers above all run at a worktree's REMOVAL or on a timer, so a tree a
# window started and abandoned — a disowned job, a Bash-tool `&`, the headless
# browser an MCP server forks — outlives the window as a PPID=1 orphan until a
# scan finds it. On 2026-10-03 three such browsers held ~50 GB for five days.
# So the close itself sweeps: tmux's window-unlinked / pane-exited hooks run
# bin/fleet-window-reap.sh, which kills every ORPHANED TREE that the window
# leaves with nobody working in its anchor.
#
# tmux cannot say which worktree the closed window had (window-unlinked expands
# its formats against the session's NEW current window, and pane-exited does not
# fire for kill-window), and macOS has no session id to follow (`ps -o sess` is
# 0). So the question is asked from the process table, with the same three
# guards memguard rule B and the listener reaper use:
#   1. the tree's top is a direct child of init (PPID=1), owned by this user —
#      a shell in Terminal.app or a launchd job's child is never a top;
#   2. the top's cwd is a fleet anchor of kind worktree or session
#      (fleet_listen_anchor: a `*-issue-N` / `*-scratch-N` worktree, even a
#      removed one, or one session's scratchpad dir) — never ~/.claude, never
#      the scratchpad root, never anywhere else on the machine;
#   3. NO live pane process and no live `claude` has its cwd in that anchor —
#      another window still in the worktree keeps every orphan there (a worker's
#      own `nohup … &` server is PPID=1 from birth and must live while it does).
# Plus: the top is not a tmux server and not an agent, no argv in its tree is exempt
# (doc-preview, the fleet's own detached teardown scripts — FLEET_WINDOW_REAP_EXEMPT_RE
# extends), and its worktree is not under a rotation lease (#550: a close→resume
# move leaves the worktree briefly windowless on purpose).
# FLEET_WINDOW_REAP_ROOT (selftests) narrows the sweep to tops whose cwd is under it.
FLEET_WINDOW_REAP_EXEMPT_RE_DEFAULT='/bin/(session-end-hook|dash-reap|fleet-[a-z0-9-]+|worktree-autoclean|tmux-[a-z0-9-]+)\.(sh|py)'

# fleet_orphan_trees — the candidates, one row per tree:
#   top \t age_s \t kind \t key \t cwd \t argv
fleet_orphan_trees() {
  local me tops cwds
  me="$(id -u 2>/dev/null)"; [ -n "$me" ] || return 0
  command -v lsof >/dev/null 2>&1 || return 0
  local re="$FLEET_LISTEN_EXEMPT_RE_DEFAULT|$FLEET_WINDOW_REAP_EXEMPT_RE_DEFAULT${FLEET_WINDOW_REAP_EXEMPT_RE:+|$FLEET_WINDOW_REAP_EXEMPT_RE}"
  # PPID=1 tops of ours that are neither a tmux server nor an agent, and whose
  # tree holds no exempt argv anywhere (doc-preview's server under a wrapper
  # shell is still doc-preview's server).
  tops="$(ps -eo pid=,ppid=,uid=,etime=,command= 2>/dev/null | awk -v me="$me" -v self="$$" -v re="$re" '
    function secs(et,   f, n) {
      n = split(et, f, /[-:]/)
      if (n == 4) return f[1]*86400 + f[2]*3600 + f[3]*60 + f[4]
      if (n == 3) return f[1]*3600 + f[2]*60 + f[3]
      if (n == 2) return f[1]*60 + f[2]
      return 0 }
    { p = $1 + 0; par[p] = $2 + 0
      a = ""; for (i = 5; i <= NF; i++) a = a (i > 5 ? " " : "") $i
      if (a ~ re) ex[p] = 1
      if ($2 != 1 || $3 != me || p == self) next
      b = $5; sub(/.*\//, "", b)
      if (b == "tmux" || b ~ /^tmux:/ || b == "claude" || b == "codex" || $5 ~ /\/claude\/versions\//) next
      if (b == "node" && ($6 ~ /claude-code|\/codex/)) next
      top[p] = 1; ag[p] = secs($4); av[p] = a; ids[++n] = p }
    END {
      for (p in ex) { q = p; h = 0
        while (q > 1 && h++ < 64) { if (q in top) { bad[q] = 1; break }; if (!(q in par)) break; q = par[q] } }
      for (i = 1; i <= n; i++) { p = ids[i]; if (!(p in bad)) printf "%d\t%d\t%s\n", p, ag[p], av[p] } }')"
  [ -n "$tops" ] || return 0
  cwds="$(lsof -w -a -p "$(printf '%s\n' "$tops" | cut -f1 | paste -sd, -)" -d cwd -Fpn 2>/dev/null \
    | awk '/^p/{p=substr($0,2)} /^n/{print p "\t" substr($0,2)}')"
  [ -n "$cwds" ] || return 0
  local pid age cmdline cwd anc kind key rows="" panes="" live roots
  # A login carries hundreds of PPID=1 processes (every launchd agent), so the
  # cheap shape test runs once in awk and only its few survivors pay for
  # fleet_listen_anchor's exact verdict.
  roots="$(fleet_claude_tmp_roots | paste -sd' ' -)"
  while IFS="$(printf '\t')" read -r pid age cwd cmdline; do
    [ -n "$pid" ] || continue
    anc="$(fleet_listen_anchor "$cwd")"
    kind="${anc%%	*}"; key="${anc#*	}"
    case "$kind" in worktree|session) ;; *) continue ;; esac
    rows="$rows$pid	$age	$kind	$key	$cwd	$cmdline
"
  done <<EOT
$({ printf '%s\n' "$cwds" | sed 's/^/C\t/'; printf '%s\n' "$tops" | sed 's/^/T\t/'; } \
  | awk -F'\t' -v roots="$roots" -v only="${FLEET_WINDOW_REAP_ROOT:-}" '
      BEGIN { nr = split(roots, R, / +/) }
      function shaped(c,   i) {
        if (only != "" && c != only && index(c, only "/") != 1) return 0
        for (i = 1; i <= nr; i++) if (R[i] != "" && (c == R[i] "" || index(c, R[i] "/") == 1)) return 1
        return (c ~ /-(issue|scratch)-[0-9]+(\/|$)/ || c ~ /\/\.fleet-trash(\/|$)/) }
      $1 == "C" { cw[$2] = $3; next }
      $1 == "T" && ($2 in cw) && shaped(cw[$2]) { print $2 "\t" $3 "\t" cw[$2] "\t" $4 }')
EOT
  [ -n "$rows" ] || return 0
  panes="$(_fleet_pane_cwd_keys)"
  printf '%s' "$rows" | while IFS="$(printf '\t')" read -r pid age kind key cwd cmdline; do
    [ -n "$pid" ] || continue
    live=0
    case "$kind" in
      worktree) printf '%s\n' "$panes" | awk -F'\t' -v k="$key" '
                  $1=="D" && ($2==k || index($2, k "/")==1) {f=1} END{exit !f}' && live=1
                [ "$live" = 0 ] && fleet_rotate_lease_held "$key" >/dev/null 2>&1 && live=1 ;;
      session)  printf '%s\n' "$panes" | awk -F'\t' -v k="$key" '
                  $1=="M" && ($2==k || index($2, k "-")==1) {f=1} END{exit !f}' && live=1 ;;
    esac
    [ "$live" = 1 ] && continue
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$pid" "$age" "$kind" "$key" "$cwd" "$cmdline"
  done
}

# fleet_reap_orphan_trees [kill|dry] [grace] — kill each candidate's WHOLE tree
# from its top (fleet_kill_tree: TERM, grace, KILL, re-enumerated). One line each:
# "reaped|would reap <top> <kind> cwd=<cwd> age=<s>s argv=<argv>".
fleet_reap_orphan_trees() {
  local mode="${1:-kill}" grace="${2:-2}" top age kind key cwd cmdline verb=reaped
  [ "$mode" = dry ] && verb='would reap'
  fleet_orphan_trees | while IFS="$(printf '\t')" read -r top age kind key cwd cmdline; do
    [ "$top" -gt 1 ] 2>/dev/null || continue
    [ "$top" = "$$" ] && continue
    [ "$mode" = dry ] || fleet_kill_tree "$top" "$grace" >/dev/null 2>&1
    printf '%s %s %s cwd=%s age=%ss argv=%.160s\n' "$verb" "$top" "$kind" "$cwd" "$age" "$cmdline"
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

# ---- memory: the readings memguard acts on (issue #1292, EPIC #1291) -----------
# 2026-10-03 the Mac mini froze and rebooted with every session on it: one `git`
# went from nothing to ~40 GB in about two seconds, beside three headless-browser
# orphans that had been holding ~50 GB for five days without anyone knowing.
# Nothing here watched memory at all. These are the shared READINGS — the
# watchdog (bin/fleet-memguard.sh), the doctor's memory line and the admission
# gate all ask the same three questions through them, so they cannot disagree.

# fleet_mem_probe — the machine's memory pressure, ONE line, space-separated:
#   <level> <avail_pct> <compressor_pct> <swap_used_mb>
# level uses the kernel's own numbering (macOS kern.memorystatus_vm_pressure_level):
# 1 normal, 2 warn, 4 critical. On Linux it is derived from MemAvailable (<5% → 4,
# <15% → 2). FLEET_MEM_PROBE_CMD replaces the whole reading (a selftest stub:
# `echo 4 5 97 0`). Prints nothing when the machine will not say.
fleet_mem_probe() {
  if [ -n "${FLEET_MEM_PROBE_CMD:-}" ]; then
    sh -c "$FLEET_MEM_PROBE_CMD" 2>/dev/null | awk 'NF{print; exit}'; return 0
  fi
  if [ -r /proc/meminfo ]; then
    awk '/^MemTotal:/{t=$2} /^MemAvailable:/{a=$2} /^SwapTotal:/{st=$2} /^SwapFree:/{sf=$2}
      END { if (t <= 0) exit; p = int(a * 100 / t); l = (p < 5 ? 4 : (p < 15 ? 2 : 1))
            printf "%d %d 0 %d\n", l, p, int((st - sf) / 1024) }' /proc/meminfo 2>/dev/null
    return 0
  fi
  command -v vm_stat >/dev/null 2>&1 || return 0
  { sysctl -n kern.memorystatus_vm_pressure_level hw.memsize vm.swapusage 2>/dev/null
    printf '%s\n' '--vm'; vm_stat 2>/dev/null; } | awk '
    function pages(s) { s = $NF; gsub(/[^0-9]/, "", s); return s + 0 }
    $0 == "--vm" { vm = 1; next }
    !vm { n++
          if (n == 1) lvl = $1 + 0
          else if (n == 2) mem = $1 + 0
          else if ($0 ~ /used = /) { u = $0; sub(/.*used = /, "", u); sub(/M.*/, "", u); sw = u + 0 }
          next }
    /page size of/ { ps = $0; sub(/.*page size of /, "", ps); ps += 0; next }
    /^Pages free:/ { fr = pages() } /^Pages inactive:/ { in_ = pages() }
    /^Pages speculative:/ { sp = pages() } /^Pages occupied by compressor:/ { co = pages() }
    END { if (mem <= 0 || ps <= 0) exit
          tp = mem / ps; if (lvl != 1 && lvl != 2 && lvl != 4) lvl = 1
          printf "%d %d %d %d\n", lvl, int((fr + in_ + sp) * 100 / tp), int(co * 100 / tp), int(sw) }'
}

# fleet_mem_total_mb — physical memory in MB (FLEET_MEM_TOTAL_MB overrides — a
# stub, or a host that wants its percentages taken of a smaller figure).
fleet_mem_total_mb() {
  case "${FLEET_MEM_TOTAL_MB:-}" in ''|*[!0-9]*) : ;; *) printf '%s\n' "$FLEET_MEM_TOTAL_MB"; return 0 ;; esac
  if [ -r /proc/meminfo ]; then awk '/^MemTotal:/{printf "%d\n", $2/1024; exit}' /proc/meminfo; return 0; fi
  sysctl -n hw.memsize 2>/dev/null | awk 'NF{printf "%d\n", $1/1048576; exit}'
}

# fleet_proc_mem_rows — every process of THIS user, from ONE `ps` (cheap enough to
# run every 2s), one row each, sorted by RSS descending:
#   pid \t ppid \t rss_mb \t age_s \t class \t argv
# class answers "is this ours?" from the process tree alone, no lsof:
#   agent   a claude / codex session process itself (executable basename, the
#           native build's …/claude/versions/<semver>, or node running one) —
#           never killed by memguard's spike rule: losing a session is the outage
#   fleet   a DESCENDANT of an agent, or of a tmux server on a NAMED socket (`-L`
#           — every fleet runs on one, issue #159; an ad-hoc default-socket tmux
#           is not a fleet), so: a command some session started
#   orphan  reparented to init (PPID=1) and not an agent — ours only if its cwd is
#           a fleet anchor (fleet_listen_anchor); the caller decides, with lsof,
#           only for the rare row that crosses a line
#   other   everything else (the operator's own apps, launchd agents) — not ours
# FLEET_MEM_PS_CMD replaces the `ps` (a selftest stub); its output is
# `pid ppid uid rss_kb etime command…`, the shape `ps -Ao` prints below.
fleet_proc_mem_rows() {
  local uid; uid="$(id -u 2>/dev/null)"
  { if [ -n "${FLEET_MEM_PS_CMD:-}" ]; then sh -c "$FLEET_MEM_PS_CMD" 2>/dev/null
    else ps -Ao pid=,ppid=,uid=,rss=,etime=,command= 2>/dev/null; fi; } | awk -v me="$uid" '
    function secs(et,   f, n) {
      n = split(et, f, /[-:]/)
      if (n == 4) return f[1]*86400 + f[2]*3600 + f[3]*60 + f[4]
      if (n == 3) return f[1]*3600 + f[2]*60 + f[3]
      if (n == 2) return f[1]*60 + f[2]
      return 0 }
    function base(s) { sub(/.*\//, "", s); return s }
    { if ($3 != me) next
      p = $1 + 0; par[p] = $2 + 0; rss[p] = int($4 / 1024); ag[p] = secs($5)
      a = ""; for (i = 6; i <= NF; i++) a = a (i > 6 ? " " : "") $i; av[p] = a
      b0 = base($6); b1 = base($7)
      agent[p] = (b0 == "claude" || b0 == "codex" || $6 ~ /\/claude\/versions\// \
                  || (b0 == "node" && ($7 ~ /claude-code|\/codex/ || b1 == "claude" || b1 == "codex")))
      srv[p] = ((b0 == "tmux" || b0 ~ /^tmux:/) && a ~ / -L /)
      ids[++n] = p }
    END {
      for (i = 1; i <= n; i++) { p = ids[i]
        if (agent[p]) c = "agent"
        else {
          c = ""; q = par[p]; h = 0
          while (q > 1 && h++ < 64) {
            if (agent[q] || srv[q]) { c = "fleet"; break }
            if (!(q in par)) break
            q = par[q] }
          if (c == "") c = (par[p] == 1 && !srv[p] ? "orphan" : "other") }
        printf "%d\t%d\t%d\t%d\t%s\t%s\n", p, par[p], rss[p], ag[p], c, av[p] } }' \
    | sort -t "$(printf '\t')" -k3,3nr
}

# fleet_files_probe / fleet_pty_probe — the two kernel tables that can run out
# under a big fleet and take the whole machine with them (issue #1293, EPIC #1291
# "④ handles / terminals exhausted"): ONE line `<used> <max>`, or nothing when the
# machine will not say. Files: macOS kern.num_files / kern.maxfiles; Linux
# /proc/sys/fs/file-nr (allocated − free, max). Ptys: macOS /dev/ttys* nodes /
# kern.tty.ptmx_max; Linux /dev/pts/N / /proc/sys/kernel/pty/max.
# FLEET_FILES_PROBE_CMD / FLEET_PTY_PROBE_CMD replace the reading (a selftest stub).
fleet_files_probe() {
  if [ -n "${FLEET_FILES_PROBE_CMD:-}" ]; then
    sh -c "$FLEET_FILES_PROBE_CMD" 2>/dev/null | awk 'NF{print; exit}'; return 0
  fi
  if [ -r /proc/sys/fs/file-nr ]; then
    awk 'NF >= 3 && $3 > 0 { printf "%d %d\n", $1 - $2, $3; exit }' /proc/sys/fs/file-nr 2>/dev/null
    return 0
  fi
  sysctl -n kern.num_files kern.maxfiles 2>/dev/null \
    | awk 'NF { v[++n] = $1 + 0 } END { if (n == 2 && v[2] > 0) printf "%d %d\n", v[1], v[2] }'
}
fleet_pty_probe() {
  local n=0 max f
  if [ -n "${FLEET_PTY_PROBE_CMD:-}" ]; then
    sh -c "$FLEET_PTY_PROBE_CMD" 2>/dev/null | awk 'NF{print; exit}'; return 0
  fi
  if [ -r /proc/sys/kernel/pty/max ]; then
    max="$(cat /proc/sys/kernel/pty/max 2>/dev/null)"
    for f in /dev/pts/[0-9]*; do [ -e "$f" ] && n=$((n + 1)); done
  else
    max="$(sysctl -n kern.tty.ptmx_max 2>/dev/null)"
    for f in /dev/ttys[0-9]*; do [ -e "$f" ] && n=$((n + 1)); done
  fi
  case "$max" in ''|*[!0-9]*|0) return 0 ;; esac
  printf '%d %d\n' "$n" "$max"
}

# fleet_proc_cwd <pid> — the process's working directory, or nothing.
fleet_proc_cwd() {
  if [ -d "/proc/${1:-x}" ]; then readlink "/proc/$1/cwd" 2>/dev/null; return 0; fi
  command -v lsof >/dev/null 2>&1 || return 0
  lsof -w -a -p "${1:-0}" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p' | head -1
}

# fleet_is_fleet_proc <pid> — 0 iff <pid> is ours: an agent, a command an agent /
# fleet pane started, or an orphan whose cwd is a fleet anchor (a scratchpad, a
# `*-issue-N` / `*-scratch-N` worktree, ~/.claude). Never a machine-wide verdict.
fleet_is_fleet_proc() {
  local pid="${1:-}" cls
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  cls="$(fleet_proc_mem_rows | awk -F'\t' -v p="$pid" '$1 == p { print $5; exit }')"
  case "$cls" in
    agent|fleet) return 0 ;;
    orphan) [ -n "$(fleet_listen_anchor "$(fleet_proc_cwd "$pid")")" ] ;;
    *) return 1 ;;
  esac
}

# ---- machine metrics: the record a crash leaves behind (issue #1294) ----------
# After the 2026-10-03 reboot the system's own reports said WHAT died, but there
# was no curve of the minutes before it — memory, files, ptys, which of our
# processes were growing — so the cause had to be inferred. The diskguard tick
# appends one row a minute; memguard one every 10s while pressure is ≥ warn, so
# the run-up to a freeze has resolution. One file a day, kept FLEET_METRICS_KEEP_DAYS
# (7). Columns are named in the file's header comment and only ever APPENDED to,
# so a reader written against today's file keeps working on tomorrow's.
FLEET_METRICS_COLS='ts	load1	cores	pressure	avail_pct	compressor_pct	swap_mb	num_files	ptys	claude_procs	top_rss	src'

fleet_machine_dir() { printf '%s/machine\n' "${FLEET_CONF_DIR:-$HOME/.config/claude-fleet}"; }

# fleet_metrics_row [src] — one TSV row (no newline handling beyond the trailing \n).
# Every reading is best-effort: an unreadable one is `-`, never a missing column.
fleet_metrics_row() {
  local src="${1:-diskguard}" load cores mem nf pty=0 cl top t
  load="$({ sysctl -n vm.loadavg 2>/dev/null || cat /proc/loadavg 2>/dev/null; } | tr -d '{}' | awk 'NF{print $1+0; exit}')"
  cores="$({ sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null; } | awk 'NF{print $1+0; exit}')"
  mem="$(fleet_mem_probe)"; [ -n "$mem" ] || mem='- - - -'
  nf="$({ sysctl -n kern.num_files 2>/dev/null || awk '{print $1}' /proc/sys/fs/file-nr 2>/dev/null; } | awk 'NF{print $1+0; exit}')"
  for t in /dev/pts/[0-9]* /dev/ttys[0-9]*; do [ -e "$t" ] && pty=$((pty + 1)); done
  cl="$(ps -axo comm= 2>/dev/null | awk '{ n = $0; sub(/.*\//, "", n); if (n == "claude" || $0 ~ /\/claude\/versions\//) c++ } END { print c+0 }')"
  # the three largest of OUR processes (fleet_proc_mem_rows is RSS-sorted) as name:MB
  top="$(fleet_proc_mem_rows | awk -F'\t' '$5 != "other" { split($6, w, " "); n = w[1]; sub(/.*\//, "", n)
      gsub(/[^A-Za-z0-9._+-]/, "", n); if (n == "") n = "?"; o = o (k++ ? "," : "") n ":" $3; if (k == 3) exit }
      END { print (o == "" ? "-" : o) }')"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "${load:--}" "${cores:--}" \
    "$(printf '%s' "$mem" | tr ' ' '\t')" "${nf:--}" "${pty:--}" "${cl:--}" "${top:--}" "$src"
}

# fleet_metrics_append [src] — append a row to today's metrics-YYYYMMDD.tsv (header
# on a new file) and drop files past the retention. Never fails the caller.
fleet_metrics_append() {
  local d f keep cut old
  d="$(fleet_machine_dir)"; mkdir -p "$d" 2>/dev/null || return 0
  f="$d/metrics-$(date '+%Y%m%d').tsv"
  [ -s "$f" ] || printf '# fleet machine metrics (issue #1294) — columns only ever appended\n# %s\n' "$FLEET_METRICS_COLS" > "$f" 2>/dev/null
  fleet_metrics_row "${1:-diskguard}" >> "$f" 2>/dev/null
  keep="${FLEET_METRICS_KEEP_DAYS:-7}"; case "$keep" in ''|*[!0-9]*|0) keep=7 ;; esac
  cut="$(date -v-"${keep}"d '+%Y%m%d' 2>/dev/null || date -d "-$keep days" '+%Y%m%d' 2>/dev/null)"  # portable-ok: BSD/GNU both-ways
  [ -n "$cut" ] || return 0
  for old in "$d"/metrics-*.tsv; do
    [ -f "$old" ] || continue
    case "${old##*/metrics-}" in [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9].tsv) ;; *) continue ;; esac
    [ "${old##*/metrics-}" \< "$cut.tsv" ] && rm -f "$old" 2>/dev/null
  done
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
  # FLEET_LOAD_PROBE_CMD replaces the whole reading (a selftest stub: `echo 3.50`).
  if [ -n "${FLEET_LOAD_PROBE_CMD:-}" ]; then
    l=$(sh -c "$FLEET_LOAD_PROBE_CMD" 2>/dev/null | awk 'NF{print $1; exit}')
    case "$l" in ''|*[!0-9.]*) return 0 ;; esac
    printf '%s' "$l"; return 0
  fi
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
  local o iss owt pth k pre
  o=$(tmux display-message -p -t "$TMUX_PANE" \
        '#{@issue}|#{@worktree}|#{pane_current_path}' 2>/dev/null)
  [ -n "$o" ] || return 0
  iss=${o%%|*}; o=${o#*|}; owt=${o%%|*}; pth=${o#*|}
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
  [ -z "$k" ] && k=$(fleet_scratch_key "$pth")
  [ -n "$k" ] && printf '%s%s' "$pre" "$k"
  return 0
}

# fleet_epic_parent_key <sess> <repo> <epic> → the key an EPIC loop's ledger is
# kept under (issue #1110): this pane's own key (fleet_origin_key) when it has
# one — a scratch, or a worker — else the EPIC's, `[<slug>:]issue-<epic>`. A hub
# pane has no key, and a loop run there (or picked up there after a handoff) used
# to spawn every member with an empty @origin: no child reported anywhere, and
# `fleet-children.sh` answered `no parent key` for the whole batch. The loop
# passes the key it gets here as `--origin` on every spawn and names it to
# fleet-children.sh / fleet-epic-backstop.sh, so the book is the same on every
# tick whichever pane drives it. No window answers to the EPIC's key, so a report
# is ledgered (never relayed) — the loop reads the ledger each tick anyway.
#
# No pane key ⇒ rc 1 and one stderr line, never the EPIC's key (issue #1355, EPIC
# #1645 C2). The EPIC fallback named a parent no window answers to: every member's
# report was ledgered and never relayed, and a spawn's live-parent gate
# (fleet_origin_gate) now refuses such a key anyway. Drive the loop from a scratch
# (or a worker) pane — that window IS the parent the children report to.
fleet_epic_parent_key() {
  local k
  k=$(fleet_origin_key)
  [ -n "$k" ] && { printf '%s' "$k"; return 0; }
  printf 'fleet: this pane has no session key (hub, or no $TMUX_PANE) — run the EPIC loop from a scratch or worker pane, so its children have a live parent to report to\n' >&2
  return 1
}

# fleet_origin_gate <sess> <explicit> <origin> [<origin-wid>] — a spawn's parent
# must be a LIVE session (issue #1355, EPIC #1645 C2). Run by both spawners
# (dash-issue-session.sh, dash-raw-session.sh) after fleet_origin_canon, before any
# window exists. rc 0 = go; rc 4 = refuse, the reason on stdout (the caller says
# it through its own refuse/exit 4). <explicit> is the caller's RAW --origin
# (before canon: `hub` canonicalizes to empty), <origin> the canonical value.
#   - Inside tmux with no $TMUX_PANE (fleet_pane_lost) and no --origin: detection
#     read nothing, so an empty @origin here is not "the hub", it is "unknown" — the
#     orphan #1355 found (a reset hub env, rc 0, no child-report ever delivered).
#     `--origin hub` (the operator), `--origin <key>` or a pane says who it is.
#   - A key (`[<slug>:]issue-<N>` / `scratch-<N>`): fleet_worker_locate must place
#     it — `local` (a window answers here) or `remote` (the hub sees it on another
#     machine; <origin-wid> is the address then). `unknown` (closed, never was, or
#     ambiguous) ⇒ refuse: a report to it could only be ledgered, never delivered.
#   - <origin-wid> given: the parent is on ANOTHER machine, which placed this
#     spawn here and ran this same gate before asking — trusted, not re-asked
#     (a node with no hub session cache could only answer `unknown`).
#   - Empty (hub / headless), the literals (`autofill`, `bridge`) and a free label
#     (a #516 source-fleet name) pass: none of them is a session to report to.
fleet_origin_gate() {
  local sess="${1:-}" ex="${2:-}" o="${3:-}" ow="${4:-}" v
  [ "${FLEET_ORIGIN_GATE:-1}" = 0 ] && return 0   # seam: a test whose subject is not the parent
  [ -n "$ow" ] && return 0
  if [ -z "$ex" ] && fleet_pane_lost; then
    printf 'cannot tell who is spawning — $TMUX is set but $TMUX_PANE is not; run it from a scratch/worker pane, or pass --origin hub (you, the operator) / --origin <key>'
    return 4
  fi
  case "$o" in
    issue-[0-9]*|scratch-[0-9]*|*:issue-[0-9]*|*:scratch-[0-9]*) ;;
    *) return 0 ;;
  esac
  v=$(fleet_worker_locate "wid:$o" "$sess" 2>/dev/null)
  case "$v" in local\ *|remote\ *) return 0 ;; esac
  printf '上级 %s 不是活着的会话 (parent %s is not a live session) — no window answers to it here and the hub cannot place it; pass --origin hub to spawn it as your own' "$o" "$o"
  return 4
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
#   scratch-<N>  @worktree when stamped, else the pane cwd — through the SAME
#                strict digits-only basename rule as fleet_scratch_key / the dash's
#                okey_v (inlined here for the same reason okey_v inlines it: no
#                subshell per window)
#
# THE ONE RESOLVER (issue #1537, EPIC #1529 E8). Every cross-session address — a
# child's report to its parent, fleet-await's child, fleet-peer-send's issue:<N> /
# scratch-<N>, the hub's inbound relay, the children digest — resolves HERE, and a
# key that does not resolve cleanly is a refusal, never a guess:
#   rc 0  exactly one live window answers: its id on stdout
#   rc 1  NOTFOUND: nothing on stdout, nothing on stderr
#   rc 2  AMBIGUOUS: nothing on stdout, ONE stderr line saying why — two windows
#         answer to the key, or the key is a bare `issue-<N>` in a fleet hosting
#         2+ repos (every repo's #N spells that; the key must carry the repo slug,
#         `<slug>:issue-<N>`, as @origin / worker_ids have since #789)
#   ① a warm-pool window never answers (`@pool 1`, or parked in the fleet's
#     `<sess>-pool` holding session): it sits in a pre-warmed scratch worktree whose
#     NUMBER a closed scratch may have had (fleet_scratch_free recycles it), so
#     before this a parent that had gone was "found" in the pool and its child's
#     report woke a window nobody was using
#   ② @worktree, once stamped, is the scratch's identity; the pane cwd is read ONLY
#     when no @worktree exists (a crash-restored scratch) — never as a second chance
#     for a window whose stamp said otherwise
# A one-repo fleet with one window per key behaves byte for byte as before.
fleet_win_for_key() {
  local key="${1:-}" sock="${2:-}" wl line wid rest iss wt pth cand bn sn pre='' wsess pool fleet hits='' n names
  # `<slug>:<key>` (issue #789): match the bare key, then require the window's repo.
  case "$key" in ?*:?*) pre=${key%%:*}; key=${key#*:} ;; esac
  case "$key" in
    issue-*|scratch-*) sn=${key#*-}; case "$sn" in ''|*[!0-9]*) return 1 ;; esac ;;
    *) return 1 ;;
  esac
  fleet="$sock"; [ -n "$fleet" ] || fleet=$(fleet_current_session 2>/dev/null)
  if [ -z "$pre" ] && [ -n "$fleet" ]; then
    case "$key" in issue-*)
      if fleet_multirepo "$fleet"; then
        printf 'fleet: %s is ambiguous in %s — the fleet hosts several repos and each may bind #%s; qualify the key with the repo slug (<slug>:%s)\n' \
          "$key" "$fleet" "${key#issue-}" "$key" >&2
        return 2
      fi ;;
    esac
  fi
  # window_name is NOT read here: the free-text field would have to ride the same
  # `|` separator (a tab/0x1f separator prints as a literal `\037` on tmux ≤3.4).
  if [ -n "$sock" ]; then
    wl=$(fleet_lw '#{window_id}|#{session_name}|#{@issue}|#{@pool}|#{@worktree}|#{pane_current_path}' tmux -L "$sock")
  else
    wl=$(fleet_lw '#{window_id}|#{session_name}|#{@issue}|#{@pool}|#{@worktree}|#{pane_current_path}')
  fi
  [ -n "$wl" ] || return 1
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    wid=${line%%|*};  rest=${line#*|}
    wsess=${rest%%|*}; rest=${rest#*|}
    iss=${rest%%|*};  rest=${rest#*|}
    pool=${rest%%|*}; rest=${rest#*|}
    wt=${rest%%|*};   pth=${rest#*|}
    [ "$pool" = 1 ] && continue                                   # ① a warm-pool window
    fleet_is_pool_session "$wsess" ${fleet:+"$fleet"} && continue  # ① parked in the pool session
    case "$key" in
      issue-*)
        [ -n "$iss" ] && [ "issue-$iss" = "$key" ] && _fleet_wfk_repo_ok && hits="$hits$wid"$'\n'
        ;;
      scratch-*)
        if [ -n "$wt" ]; then cand=$wt; else cand=$pth; fi   # ② the stamp, else the cwd — not both
        bn=${cand##*/}
        case "$bn" in
          scratch-*)   sn=${bn#scratch-} ;;
          *-scratch-*) sn=${bn##*-scratch-} ;;
          *)           sn='' ;;
        esac
        case "$sn" in
          ''|*[!0-9]*) ;;
          *) [ "scratch-$sn" = "$key" ] && _fleet_wfk_repo_ok && hits="$hits$wid"$'\n' ;;
        esac
        ;;
    esac
  done <<EOF
$wl
EOF
  n=$(printf '%s' "$hits" | grep -c .)
  case "$n" in
    0) return 1 ;;
    1) printf '%s' "${hits%%$'\n'*}"; return 0 ;;
  esac
  # Two (or more) windows answer to one key: AMBIGUOUS. Named on stderr so the
  # operator can see which; nothing on stdout, so no caller can act on a pick.
  names=$(printf '%s' "$hits" | while IFS= read -r wid; do
      [ -n "$wid" ] || continue
      if [ -n "$sock" ]; then tmux -L "$sock" display-message -p -t "$wid" "$FLEET_SESSION_FMT:#{window_name}" 2>/dev/null
      else tmux display-message -p -t "$wid" "$FLEET_SESSION_FMT:#{window_name}" 2>/dev/null; fi
    done | paste -sd, - | sed 's/,/, /g')
  printf 'fleet: %s%s is ambiguous — %s windows match: %s\n' "${pre:+$pre:}" "$key" "$n" "$names" >&2
  return 2
}

# ---- worker identity → where it lives (issue #1420, EPIC #1419 C1) -------------
# A window id or `<sess>:<idx>` means something only on the server that minted it;
# the durable address of a worker is its worker_id (docs/FLEET-HUB.md «Worker
# identity»): `<fleet UUID>/<key>`, the key being the same `issue-<N>` /
# `scratch-<N>` / `<slug>:issue-<N>` spelling @origin carries. These helpers answer
# "is that worker HERE, and in which window?" — and, only when it is not and the
# cross-machine hub is switched on (CCQUOTA_FLEET=1), "which node has it?". The
# local answer is today's fleet_win_for_key, unchanged; the hub branch only ever
# reads a local cache, never the network.
#
# Scripts take such a target as `wid:<worker_id>` (or `wid:<key>`, meaning THIS
# fleet). A local hit runs the script's existing path; `remote`/`unknown` refuse
# with a one-line reason, and never fall through to a same-numbered local window.

# fleet_identity_triplet <sess> → `<sess>\0<repo>\0<checkout>\0` — the fleet's OWN
# identity, the three things its UUID hashes: the fleet conf's FLEET_REPO and
# FLEET_MAIN (its first repo), never a pane's. The ONE place it is read, shared by
# fleet_uuid below and fleet-control-read.sh's inventory (what fleet_control.py
# mints the UUID the hub registers from), so the two cannot drift (issue #1498).
# The inventory runs under a scrubbed environment (fleet_control.py environment())
# with no TMUX, so this rebuilds exactly that view from inside any pane:
#   - TMUX unset: fleet_load_conf lays the WINDOW's repo overlay on top (issue
#     #788) — a pane of the second repo minted that repo's UUID (issue #1491);
#   - FLEET_REPO / FLEET_MAIN unset and the global conf re-read: a pane's
#     environment can carry the window's repo exported (a launcher, a hook, a
#     caller that loaded another conf) — the conf then fills only what it sets,
#     and a value it leaves out would come from the pane, never the fleet.
# NUL-separated (a checkout path is arbitrary text); pipe it, never `$(…)` it.
fleet_identity_triplet() {
  local sess="${1:-}"
  [ -n "$sess" ] || return 1
  ( unset TMUX TMUX_PANE FLEET_REPO FLEET_MAIN
    if [ -z "${FLEET_SKIP_GLOBAL_CONF:-}" ]; then
      [ -n "${_FLEET_LIB_DIR:-}" ] && [ -f "$_FLEET_LIB_DIR/../fleet.conf" ] && . "$_FLEET_LIB_DIR/../fleet.conf" >/dev/null 2>&1
      [ -f "$FLEET_CONF_DIR/fleet.settings" ] && . "$FLEET_CONF_DIR/fleet.settings" >/dev/null 2>&1
      [ -f "$FLEET_CONF_DIR/fleet.conf" ] && . "$FLEET_CONF_DIR/fleet.conf" >/dev/null 2>&1
    fi
    fleet_load_conf "$sess" >/dev/null 2>&1
    printf '%s\0' "$sess" "${FLEET_REPO:-}" "${FLEET_MAIN:-}" )
}

# fleet_uuid <sess> → the fleet's durable UUID — byte-for-byte what
# fleet_control.py's inventory mints: uuid5(<machine id>, canonical JSON of
# fleet_identity_triplet) — the fleet conf's OWN repo and checkout, whichever
# pane asks (issues #1491, #1498).
# READ-ONLY: a machine whose control database has no machine id yet
# (fleet-control.py never ran) has no fleet UUID — nothing, rc 1 — and so no
# worker_id either; nothing here creates one.
fleet_uuid() {
  local sess="${1:-}" db="$FLEET_CONF_DIR/control/state.sqlite3"
  [ -n "$sess" ] && [ -f "$db" ] || return 1
  fleet_identity_triplet "$sess" | python3 -c '
import json, sqlite3, sys, uuid
from urllib.parse import quote
try:
    parts = sys.stdin.buffer.read().decode("utf-8").split("\0")
    if len(parts) != 4 or parts[3] != "":
        sys.exit(1)
    con = sqlite3.connect("file:%s?mode=ro" % quote(sys.argv[1]), uri=True)
    row = con.execute("SELECT value FROM metadata WHERE key='"'"'machine_id'"'"'").fetchone()
    print(uuid.uuid5(uuid.UUID(row[0]), json.dumps(parts[:3], ensure_ascii=False,
                                                   sort_keys=True, separators=(",", ":"))))
except Exception:
    sys.exit(1)
' "$db" 2>/dev/null
}

# ---- a session's lifelong identity: @fleet_id (issue #1646, EPIC #1645 C1) ------
# A key (`issue-<N>` / `scratch-<N>`) is a NAME a window wears, and it changes under
# the session: a scratch bound to an issue (`fleet-issue-file.sh --bind`) stops
# answering to `scratch-<N>`, so every child whose @origin said so lost its parent —
# reports ledgered into a book nobody reads, sidebar rows sunk to the top level.
# @fleet_id is a UUID minted ONCE per session — at spawn (dash-issue-session.sh /
# dash-raw-session.sh stamp it with the window's first command), else on the first
# fleet_window_fid that asks — and carried verbatim by every road a session takes
# to another window: fleet-restore (the map's FID row), fleet-migrate, fleet-move
# (local and through the hub). It is never re-minted; /clear and a handoff never
# touch it. A spawn records the parent's as @origin_fid beside @origin, and every
# resolver asks for it FIRST, falling back to the key only when it has none.
# Its worker_id is `<fleet UUID>/<fleet_id>`; the old `<fleet UUID>/<key>` stays a
# readable alias for one version (EPIC #1645 rule 2): _fleet_wid_split takes both.
FLEET_FID_RE='[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'

# fleet_is_fid <s> — a canonical (lowercase, hyphenated) UUID?
fleet_is_fid() {
  [ -n "${1:-}" ] && printf '%s' "$1" | grep -Eqx "$FLEET_FID_RE"
}

# fleet_fid_mint → a fresh @fleet_id (uuid4), rc 1 when nothing on PATH can mint.
fleet_fid_mint() {
  local f
  f=$(uuidgen 2>/dev/null | tr 'A-F' 'a-f')
  fleet_is_fid "$f" || f=$(python3 -c 'import uuid; print(uuid.uuid4())' 2>/dev/null)
  fleet_is_fid "$f" || return 1
  printf '%s' "$f"
}

# fleet_window_fid <sess> <window> [<sock>] → that window's @fleet_id, minting and
# stamping one first if it has none (a window spawned before #1646, or by a road
# that does not stamp). rc 1: no such window, or nothing could mint. The stored
# value is re-read after the stamp, so two racing first asks print the same one.
fleet_window_fid() {
  local sess="${1:-}" w="${2:-}" sock="${3:-}" f
  [ -n "$w" ] || return 1
  if [ -n "$sock" ]; then f=$(tmux -L "$sock" show-options -wqv -t "$w" @fleet_id 2>/dev/null)
  else f=$(_fleet_tmux "$sess" show-options -wqv -t "$w" @fleet_id 2>/dev/null); fi
  fleet_is_fid "$f" && { printf '%s' "$f"; return 0; }
  f=$(fleet_fid_mint) || return 1
  if [ -n "$sock" ]; then
    tmux -L "$sock" set-window-option -t "$w" @fleet_id "$f" 2>/dev/null || return 1
    f=$(tmux -L "$sock" show-options -wqv -t "$w" @fleet_id 2>/dev/null)
  else
    _fleet_tmux "$sess" set-window-option -t "$w" @fleet_id "$f" 2>/dev/null || return 1
    f=$(_fleet_tmux "$sess" show-options -wqv -t "$w" @fleet_id 2>/dev/null)
  fi
  fleet_is_fid "$f" || return 1
  printf '%s' "$f"
}

# ---- a session's birth: @born (issue #1750) ------------------------------------
# The epoch a session was spawned — the list's ORDER (tmux-dashboard-rows.sh seg_v):
# a row sits where it was born, whatever its state, so it never jumps. Stamped once
# at spawn (dash-issue-session.sh / dash-raw-session.sh) with the time of the
# spawn — NOT the window's window_created: a warm-pool window (#448) was built
# long before the session it now holds was asked for — and carried verbatim beside
# @fleet_id by fleet-migrate and fleet-move (the bundle's `<sid>.born`, beside
# `<sid>.fleet-id`), so a session taken over on another machine keeps its place
# on every list. A window with no @born (spawned before #1750, or by a road that
# does not stamp) reads as its window_created: the list and the hub's inventory
# both read `#{?@born,#{@born},#{window_created}}`.

# fleet_window_born <sess> <window> [<sock>] → that window's @born, stamping it with
# NOW first if it has none (the spawn). Never re-stamped: a window that already
# carries one (a migrated / moved session) keeps it. rc 1: no such window.
fleet_window_born() {
  local sess="${1:-}" w="${2:-}" sock="${3:-}" b
  [ -n "$w" ] || return 1
  if [ -n "$sock" ]; then b=$(tmux -L "$sock" show-options -wqv -t "$w" @born 2>/dev/null)
  else b=$(_fleet_tmux "$sess" show-options -wqv -t "$w" @born 2>/dev/null); fi
  case "$b" in ''|*[!0-9]*) ;; *) printf '%s' "$b"; return 0 ;; esac
  b=$(date +%s)
  if [ -n "$sock" ]; then tmux -L "$sock" set-window-option -t "$w" @born "$b" 2>/dev/null || return 1
  else _fleet_tmux "$sess" set-window-option -t "$w" @born "$b" 2>/dev/null || return 1; fi
  printf '%s' "$b"
}

# fleet_win_for_fid <fleet_id> [<sock>] — fleet_win_for_key's twin for an identity:
# the live window carrying @fleet_id <fleet_id> on this fleet's socket. Same rails:
# rc 0 + the id, rc 1 NOTFOUND, rc 2 AMBIGUOUS (two windows carry it — a copy made
# by hand — said on stderr, never a pick); a warm-pool window never answers.
fleet_win_for_fid() {
  local fid="${1:-}" sock="${2:-}" fleet wl line wid rest wsess pool f hits='' n
  fleet_is_fid "$fid" || return 1
  fleet="$sock"; [ -n "$fleet" ] || fleet=$(fleet_current_session 2>/dev/null)
  if [ -n "$sock" ]; then wl=$(fleet_lw '#{window_id}|#{session_name}|#{@pool}|#{@fleet_id}' tmux -L "$sock")
  else wl=$(fleet_lw '#{window_id}|#{session_name}|#{@pool}|#{@fleet_id}'); fi
  [ -n "$wl" ] || return 1
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    wid=${line%%|*};   rest=${line#*|}
    wsess=${rest%%|*}; rest=${rest#*|}
    pool=${rest%%|*};  f=${rest#*|}
    [ "$f" = "$fid" ] || continue
    [ "$pool" = 1 ] && continue
    fleet_is_pool_session "$wsess" ${fleet:+"$fleet"} && continue
    hits="$hits$wid"$'\n'
  done <<EOF
$wl
EOF
  n=$(printf '%s' "$hits" | grep -c .)
  case "$n" in
    0) return 1 ;;
    1) printf '%s' "${hits%%$'\n'*}"; return 0 ;;
  esac
  printf 'fleet: identity %s is ambiguous — %s windows carry it: %s\n' "$fid" "$n" \
    "$(printf '%s' "$hits" | paste -sd, - | sed 's/,/, /g')" >&2
  return 2
}

# fleet_win_for_addr <key | fleet_id> [<sock>] — the one entry for an address that
# may be either: an identity goes to fleet_win_for_fid, a key to fleet_win_for_key.
fleet_win_for_addr() {
  if fleet_is_fid "${1:-}"; then fleet_win_for_fid "$@"; else fleet_win_for_key "$@"; fi
}

# fleet_worker_id <sess> <window> → that window's worker_id, `<fleet UUID>/<fleet_id>`
# (issue #1646), or nothing (no fleet UUID on this machine, or a window with no
# durable key — fleet_window_okey: a panel is no worker). A window that cannot get
# an identity (nothing can mint) keeps the old `<fleet UUID>/<key>`.
fleet_worker_id() {
  local u k f
  k=$(fleet_window_okey "${1:-}" "${2:-}"); [ -n "$k" ] || return 1
  u=$(fleet_uuid "${1:-}") && [ -n "$u" ] || return 1
  f=$(fleet_window_fid "${1:-}" "${2:-}") || f=''
  printf '%s/%s' "$u" "${f:-$k}"
}

# fleet_worker_id_key <sess> <window> → the OLD form, `<fleet UUID>/<key>` — a
# readable label (a relay's `from`, the hub's lease holder), never an address.
fleet_worker_id_key() {
  local u k
  k=$(fleet_window_okey "${1:-}" "${2:-}"); [ -n "$k" ] || return 1
  u=$(fleet_uuid "${1:-}") && [ -n "$u" ] || return 1
  printf '%s/%s' "$u" "$k"
}

# _fleet_wid_split <target> → `<uuid>\t<key-or-fleet_id>` (uuid empty for a bare
# one), rc 1 when the target (an optional `wid:` prefix stripped) is no worker_id:
# `<fleet UUID>/<fleet_id>` (issue #1646), the old `<fleet UUID>/<key>`, or either
# half alone (this fleet's).
_fleet_wid_split() {
  local t="${1#wid:}" u='' k
  case "$t" in */*) u=${t%%/*}; k=${t#*/} ;; *) k=$t ;; esac
  if [ -n "$u" ]; then
    fleet_is_fid "$u" || return 1
  fi
  if ! fleet_is_fid "$k"; then
    printf '%s' "$k" | grep -Eqx '([A-Za-z0-9][A-Za-z0-9._-]{0,127}:)?(issue|scratch)-[1-9][0-9]{0,9}' || return 1
  fi
  printf '%s\t%s' "$u" "$k"
}

# fleet_wid_home <target> [<sess>] → the LOCAL fleet a worker_id belongs to: the
# fleet whose UUID it names, or <sess> (default: the caller's) for a bare key.
# rc 1 = another machine's fleet (or a fleet no longer configured here), rc 2 =
# not a worker_id at all. Says nothing about whether the worker is live.
fleet_wid_home() {
  local sp u s
  sp=$(_fleet_wid_split "${1:-}") || return 2
  u=${sp%%$'\t'*}
  if [ -z "$u" ]; then
    s="${2:-}"; [ -n "$s" ] || s=$(fleet_current_session 2>/dev/null)
    [ -n "$s" ] || return 1
    printf '%s' "$s"; return 0
  fi
  fleet_uuid_home "$u"
}

# fleet_uuid_home <fleet UUID> → the fleet configured HERE under that UUID; rc 1
# for another machine's (or a fleet no longer configured here).
fleet_uuid_home() {
  local s _c
  [ -n "${1:-}" ] || return 1
  while IFS=$'\t' read -r s _c; do
    [ -n "$s" ] || continue
    [ "$(fleet_uuid "$s")" = "$1" ] && { printf '%s' "$s"; return 0; }
  done <<EOF
$(fleet_each_conf)
EOF
  return 1
}

# A message no worker sent (issue #1649, EPIC #1645 C10): a shell, a daemon or the
# hub pane — no pane bound to a session key — sends as the PERSON at this login,
# `<fleet UUID>/operator@<login>`. The hub takes it only from the node reporting
# that fleet and only when <login> is the login the fleet runs under, so it labels
# the message truthfully and cannot be picked. A `from`, never an address.
#
# fleet_sender_session [<socket>] → the fleet a pane-less sender speaks from: the
# caller's session, else the one on <socket>, else this login's first fleet (one
# fleet per login, issue #980). Empty (rc 1) when the login has none.
fleet_sender_session() {
  local s='' _c first=''
  # Outside tmux a bare `tmux display-message` asks the DEFAULT server — not a fleet.
  [ -n "${TMUX:-}" ] && s=$(fleet_current_session 2>/dev/null)
  [ -n "$s" ] && { printf '%s' "$s"; return 0; }
  while IFS=$'\t' read -r s _c; do
    [ -n "$s" ] || continue
    [ -n "$first" ] || first=$s
    [ -n "${1:-}" ] && [ "$(fleet_socket "$s")" = "$1" ] && { printf '%s' "$s"; return 0; }
  done <<EOF
$(fleet_each_conf)
EOF
  [ -n "$first" ] && [ -z "${1:-}" ] || return 1
  printf '%s' "$first"
}

# fleet_operator_sender <sess> → `<fleet UUID>/operator@<login>`; rc 1 without a
# fleet UUID or with a login the hub's pattern would refuse.
fleet_operator_sender() {
  local u l
  u=$(fleet_uuid "${1:-}") && [ -n "$u" ] || return 1
  l=$(id -un 2>/dev/null)
  case "$l" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
  [ "${#l}" -le 64 ] || return 1
  printf '%s/operator@%s' "$u" "$l"
}

# fleet_is_operator_sender <from> — 0 for `<fleet UUID>/operator@<login>`.
fleet_is_operator_sender() {
  case "${1:-}" in */operator@*) ;; *) return 1 ;; esac
  fleet_is_fid "${1%%/*}" || return 1
  case "${1#*/operator@}" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
  return 0
}

# ---- the hub switch, per fleet (issue #1539) ---------------------------------
# CCQUOTA_FLEET=1 switches the cross-machine hub module on. docs/FLEET-HUB.md has
# always said «in the fleet's conf», but the collector, the status bar and the
# spawn path read it from the ENVIRONMENT — the install's fleet.conf /
# fleet.settings — so it was machine-wide in practice. fleet_hub_on <sess> is the
# per-fleet read: the fleet conf's own CCQUOTA_FLEET line decides for that fleet
# (`=0` opts one fleet out of a login-wide 1, `=1` opts one in); a conf that does
# not spell it — and no <sess> at all — reads the environment exactly as before
# (the degenerate case). Pure shell, no fork: the sidebar calls it per render.
# docs/LOCAL-AND-HUB.md is the matrix of what each mode decides.
fleet_hub_on() {
  local sess="${1:-}" f line v='' hit=0
  if [ -n "$sess" ]; then
    f="$FLEET_CONF_DIR/fleets/$sess/conf"; [ -f "$f" ] || f="$FLEET_CONF_DIR/$sess.conf"
    if [ -f "$f" ]; then
      while IFS= read -r line || [ -n "$line" ]; do
        line="${line#"${line%%[![:space:]]*}"}"
        case "$line" in "export "*|"export	"*) line="${line#export}"; line="${line#"${line%%[![:space:]]*}"}" ;; esac
        case "$line" in CCQUOTA_FLEET=*) ;; *) continue ;; esac
        v=${line#*=}; v=${v%%#*}; v=${v%"${v##*[![:space:]]}"}
        v=${v#\"}; v=${v%\"}; v=${v#\'}; v=${v%\'}; hit=1
      done < "$f"
    fi
  fi
  [ "$hit" = 1 ] || v="${CCQUOTA_FLEET:-0}"
  [ "$v" = 1 ]
}

# fleet_hub_any → rc 0 when the hub is on for ANY fleet configured on this login
# (a machine-wide daemon serving every fleet runs its hub phase when one fleet
# needs it). No fleet configured: the environment, as before.
fleet_hub_any() {
  local s _c n=0
  while IFS='	' read -r s _c; do
    [ -n "$s" ] || continue
    n=1; fleet_hub_on "$s" && return 0
  done <<EOF
$(fleet_each_conf)
EOF
  [ "$n" = 0 ] && [ "${CCQUOTA_FLEET:-0}" = 1 ]
}

# fleet_hub_nudge — «a window's state just changed: report it now» (issue #1481).
# The ccquota agent reports every window every 5 s; the other machines' sidebars
# fetch the hub's list every 10 s; a window that just went 「在问你」 took up to
# 15 s to show up on another machine. This is the ONE entry point that shortens
# it: touch $FLEET_CONF_DIR/global/hub-nudge — one file per login, the agent's
# own scope — whose mtime the agent polls (250 ms, no fsnotify) and answers with
# an extra heartbeat at once, debounced (100 ms, #1526) and capped (2/s per node), so a
# burst of writes is one beat and a runaway writer cannot flood the hub. Call it
# right after every write of @claude_state / @claude_needs that CHANGES them
# (bin/set-claude-state.sh and bin/tmux-spinner.sh are `sh` and cannot source this
# lib: each carries a byte-equivalent inline copy — KEEP THEM IN SYNC). Off
# unless CCQUOTA_FLEET=1: an empty function, so a one-machine fleet writes
# nothing (CLAUDE.md «Degenerate case is sacred»). A builtin redirection, no
# fork: `: >` truncates an already-empty file and still moves its mtime (APFS,
# ext4 — the agent's test pins it).
fleet_hub_nudge() {
  [ "${CCQUOTA_FLEET:-0}" = 1 ] || return 0
  [ -d "$FLEET_CONF_DIR/global" ] || mkdir -p "$FLEET_CONF_DIR/global" 2>/dev/null || return 0
  : > "$FLEET_CONF_DIR/global/hub-nudge" 2>/dev/null
  return 0
}

# _fleet_hub_node <uuid> <key> → the node the cross-machine hub last saw this
# worker on, or rc 1. Off unless CCQUOTA_FLEET=1. Reads ONE local cache,
# $FLEET_CONF_DIR/control/hub-workers.tsv — `<worker_id>\t<node>` per line, the
# hub's fleet_status flattened — trusted while younger than FLEET_HUB_CACHE_SECS
# (30). A stale or missing cache is refreshed by FLEET_HUB_STATUS_CMD when one is
# configured (it prints that TSV on stdout; EPIC #1419 C2 supplies it); otherwise,
# or when it fails, the hub counts as unreachable: one stderr note, rc 1, and the
# caller carries on as a one-machine fleet. A bare key (no uuid) matches a row
# only when exactly one row ends in it.
_fleet_hub_node() {
  local u="${1:-}" k="${2:-}" f="$FLEET_CONF_DIR/control/hub-workers.tsv" ttl m tmp hits
  [ "${CCQUOTA_FLEET:-0}" = 1 ] || return 1
  ttl="${FLEET_HUB_CACHE_SECS:-30}"; case "$ttl" in ''|*[!0-9]*) ttl=30 ;; esac
  # GNU stat FIRST: `stat -f %m` on GNU means "filesystem status" and exits 0.
  m=$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null) || m=0
  if [ $(( $(date +%s) - ${m:-0} )) -gt "$ttl" ]; then
    if [ -n "${FLEET_HUB_STATUS_CMD:-}" ] && mkdir -p "${f%/*}" 2>/dev/null \
       && tmp=$(mktemp "$f.XXXXXX" 2>/dev/null); then
      if bash -c "$FLEET_HUB_STATUS_CMD" >"$tmp" 2>/dev/null </dev/null; then mv -f "$tmp" "$f"
      else rm -f "$tmp"; printf 'fleet: hub unreachable (FLEET_HUB_STATUS_CMD failed) — only this machine is searched\n' >&2; return 1; fi
    else
      printf 'fleet: hub status cache %s is stale or missing — only this machine is searched\n' "$f" >&2
      return 1
    fi
  fi
  if [ -n "$u" ]; then
    awk -F'\t' -v w="$u/$k" '$1 == w && $2 != "" { print $2; f = 1; exit } END { exit !f }' "$f" 2>/dev/null
    return
  fi
  hits=$(awk -F'\t' -v s="/$k" 'length($1) > length(s) && substr($1, length($1) - length(s) + 1) == s && $2 != "" { print $2 }' "$f" 2>/dev/null)
  [ -n "$hits" ] && [ "$(printf '%s\n' "$hits" | grep -c .)" -eq 1 ] || return 1
  printf '%s' "$hits"
}

# ---- the node token the hub commands act with (issue #1491) ---------------------
# `ccquota lease|place|move` act AS THIS MACHINE'S AGENT: they need CCQUOTA_HUB_URL
# + CCQUOTA_TOKEN — the agent's own enrollment — or they exit 1 「no hub configured」.
# A fleet pane has the URL (fleet conf) but never the token: fleet-node-join.sh
# keeps it in $FLEET_CONF_DIR/node.env (0600) and nothing exported it, so until
# #1491 every hub call from a pane fell back silently, misreported as 「hub
# unreachable」. The token stays OUT of the pane's environment — a worker spawned
# from a pane that carried it would hold a node credential — so it is exported only
# inside the command substitution that runs the hub command (`_fleet_hub_env`), and
# dies with it. A login whose agent predates node.env (its token only in the launchd
# plist) writes the file once with `fleet-hub-node.sh env --write`.

# fleet_node_env_file → this login's node.env path.
fleet_node_env_file() { printf '%s/node.env' "$FLEET_CONF_DIR"; }

# _fleet_node_env_val <KEY> → the value node.env assigns KEY ('' when none; rc 1
# when there is no readable file). READ, never sourced: it holds a credential.
_fleet_node_env_val() {
  local f; f=$(fleet_node_env_file)
  [ -r "$f" ] || return 1
  sed -n "s/^$1=//p" "$f" | head -n 1
}

# fleet_spawn_node_default → what a spawn follows when neither --node nor
# FLEET_SPAWN_NODE names a machine (issue #1721, EPIC #1718 C3): `local` on a
# person's own computer (node.env CCQUOTA_FLEET_PERSONAL=1 while compute is on —
# `fleet node compute on --personal`, a laptop's default), so what its client
# opens runs on it; `auto` everywhere else, exactly as before.
fleet_spawn_node_default() {
  if [ "$(_fleet_node_env_val CCQUOTA_FLEET_PERSONAL 2>/dev/null)" = 1 ] \
     && [ "$(_fleet_node_env_val CCQUOTA_FLEET_COMPUTE 2>/dev/null)" != 0 ]; then
    echo local
  else
    echo auto
  fi
}

# _fleet_hub_env — export the hub credentials the environment lacks, from node.env.
# Call it ONLY inside the subshell that runs the hub command
# (`out=$(_fleet_hub_env; bash -c … )`): the exports must die with that call and
# never reach the caller, nor anything the caller spawns.
_fleet_hub_env() {
  local v
  if [ -z "${CCQUOTA_TOKEN:-}" ]; then v=$(_fleet_node_env_val CCQUOTA_TOKEN); [ -n "$v" ] && export CCQUOTA_TOKEN="$v"; fi
  if [ -z "${CCQUOTA_HUB_URL:-}" ]; then v=$(_fleet_node_env_val CCQUOTA_HUB_URL); [ -n "$v" ] && export CCQUOTA_HUB_URL="$v"; fi
  return 0
}

# _fleet_hub_creds_missing → rc 0 and ONE phrase on stdout — what is missing, and
# the fix — when the default `ccquota …` would exit 1 for want of credentials: no
# token in the environment and none in node.env (or no hub URL anywhere). rc 1 =
# all there. Only the DEFAULT command is held to this: a FLEET_HUB_*_CMD seam (a
# test fake, the operator's place-local.sh) may need no token at all.
_fleet_hub_creds_missing() {
  local f why=''
  f=$(fleet_node_env_file)
  if [ -z "${CCQUOTA_TOKEN:-}" ] && [ -z "$(_fleet_node_env_val CCQUOTA_TOKEN)" ]; then
    if [ -f "$f" ]; then why="CCQUOTA_TOKEN unset and $f has no CCQUOTA_TOKEN= line"
    else why="CCQUOTA_TOKEN unset and $f missing"; fi
  elif [ -z "${CCQUOTA_HUB_URL:-}" ] && [ -z "$(_fleet_node_env_val CCQUOTA_HUB_URL)" ]; then
    why="CCQUOTA_HUB_URL unset and not in $f"
  fi
  [ -n "$why" ] || return 1
  printf 'no node token (%s); fix: `fleet-hub-node.sh env --write` on this login writes node.env from its agent service, or re-join with fleet-node-join.sh' "$why"
}

# _fleet_hub_fail <what> <cmd> <rc> <errfile> → ONE phrase naming why a hub
# command failed, off the command's own stderr (issue #1507). Until then every
# failure read 「hub unreachable」 — including a hub that ANSWERED 403 (a fleet UUID
# the node's heartbeat never registered), which sent the debugging to the network.
# Three forms, fixed:
#   hub unreachable (<cause>)      no answer came back: Go's `Post "<url>": <cause>`
#                                  (dial / DNS / TLS / timeout)
#   <what> refused: HTTP N — <e>   the hub answered non-OK (`hub answered HTTP N: …`);
#                                  <e> = its JSON "error", else the rest of the line
#   <cmd> exit N: <first line>     anything else — `(no stderr)` when there was none
_fleet_hub_fail() {
  local what="$1" cmd="$2" rc="$3" f="$4" l code e
  l=$(grep -v '^[[:space:]]*$' "$f" 2>/dev/null | head -n 1 | sed -E 's/^ccquota( [a-z]+)?: //' | cut -c 1-300)
  case "$l" in
    *'hub answered HTTP '*)
      code=$(printf '%s\n' "$l" | sed -n 's/.*hub answered HTTP \([0-9][0-9]*\).*/\1/p')
      e=$(printf '%s\n' "$l" | sed -n 's/.*"error"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
      [ -n "$e" ] || e=$(printf '%s\n' "$l" | sed 's/.*hub answered HTTP [0-9]*:* *//')
      printf '%s refused: HTTP %s%s' "$what" "$code" "${e:+ — $e}" ;;
    'Post "'*|*'dial tcp'*|*'no such host'*|*'connection refused'*|*'Client.Timeout'*|*'i/o timeout'*|*'context deadline exceeded'*|*'x509:'*|*'tls:'*)
      printf 'hub unreachable (%s)' "$(printf '%s\n' "$l" | sed 's/^Post "[^"]*": //')" ;;
    *) printf '%s exit %s: %s' "${cmd%% *}" "$rc" "${l:-(no stderr)}" ;;
  esac
}

# fleet_hub_lease acquire|release <sess> <repo> <issue> [--force] — the hub's
# lease on (repo, issue) (issue #1422, EPIC #1419 C3): taken before a session is
# opened so two machines can never both open one issue. Off unless CCQUOTA_FLEET=1.
# Prints the lease command's one line — `GRANTED <node>` / `FORCED <node> <from>
# <wid>` / `HELD <node> <wid> <expires>` / `RELEASED` / `NOT_HELD` — and returns:
#   0  granted / released          3  held by another node (the line names it)
#   1  the hub could not be asked: no lease command, no node token (#1491), no
#      fleet UUID here, or the command failed — one stderr note, and the caller
#      carries on as today
#  10  the hub module is off (CCQUOTA_FLEET unset): nothing ran, nothing printed
# The command is FLEET_HUB_LEASE_CMD, else `ccquota lease` when ccquota is on
# PATH; it is run as `<cmd> <action> [--force] <repo> <issue> <worker_id>`, with
# the node token from node.env in ITS environment only (`_fleet_hub_env`). Node
# names in the line go through FLEET_NODE_ALIASES, as the sidebar's do.
# The worker_id is `<fleet UUID>/<key>`, the key spelled as the session's own
# heartbeat will spell it (`<slug>:issue-<N>` in a multi-repo fleet), so the
# hub's heartbeat renewal recognises the session once its window exists.
fleet_hub_lease() {
  local act="${1:-}" sess="${2:-}" repo="${3:-}" num="${4:-}" force='' cmd u pre='' out rc why ef
  fleet_hub_on "$sess" || return 10
  [ "${5:-}" = --force ] && force=--force
  case "$act" in acquire|release) ;; *) return 1 ;; esac
  case "$num" in ''|*[!0-9]*) return 1 ;; esac
  cmd="${FLEET_HUB_LEASE_CMD:-}"
  if [ -z "$cmd" ]; then
    if command -v ccquota >/dev/null 2>&1; then cmd='ccquota lease'
    else printf 'fleet: hub lease unavailable (no FLEET_HUB_LEASE_CMD, no ccquota on PATH) — only the GitHub claim guards #%s\n' "$num" >&2; return 1; fi
    # ccquota acts as the agent: without its token it exits 1 「no hub configured」,
    # which read as 「hub unreachable」 until issue #1491. Say what is actually missing.
    if why=$(_fleet_hub_creds_missing); then
      printf 'fleet: %s — only the GitHub claim guards #%s\n' "$why" "$num" >&2; return 1
    fi
  fi
  u=$(fleet_uuid "$sess") && [ -n "$u" ] || {
    printf 'fleet: hub lease unavailable (no fleet UUID for %s on this machine) — only the GitHub claim guards #%s\n' "$sess" "$num" >&2; return 1; }
  _fleet_hosts_many "$sess" && pre="$(fleet_slug "$(fleet_norm_repo "$repo")"):"
  ef=$(mktemp "${TMPDIR:-/tmp}/fleet-hub-err.XXXXXX" 2>/dev/null) || ef=/dev/null
  out=$(_fleet_hub_env; bash -c "$cmd \"\$@\"" lease "$act" ${force:+"$force"} "$repo" "$num" "$u/${pre}issue-$num" </dev/null 2>"$ef"); rc=$?
  # Name machines the way the sidebar does (FLEET_NODE_ALIASES, `macmini=m5`): the
  # hub only knows a hostname's first label.
  out=$(printf '%s\n' "$out" | head -n1 | awk -v al="${FLEET_NODE_ALIASES:-}" '
    BEGIN { n = split(al, a, " "); for (i = 1; i <= n; i++) if ((p = index(a[i], "=")) > 1) m[substr(a[i], 1, p - 1)] = substr(a[i], p + 1) }
    $1 == "HELD" || $1 == "GRANTED" || $1 == "FORCED" { if ($2 in m) $2 = m[$2] }
    $1 == "FORCED" { if ($3 in m) $3 = m[$3] }
    { print }')
  case "$rc" in
    0|3) [ "$ef" = /dev/null ] || rm -f "$ef"; printf '%s\n' "$out"; return "$rc" ;;
  esac
  printf 'fleet: %s — no lease on #%s, falling back to the GitHub claim only\n' "$(_fleet_hub_fail lease "$cmd" "$rc" "$ef")" "$num" >&2
  [ "$ef" = /dev/null ] || rm -f "$ef"
  return 1
}

# fleet_node_is_self <name> — is <name> this machine? `local` / `here`, this
# host's short name, or its FLEET_NODE_ALIASES alias (`macmini=m5` → m5), any case.
fleet_node_is_self() {
  local n h
  n=$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')
  case "$n" in '') return 1 ;; local|here) return 0 ;; esac
  h=$(hostname -s 2>/dev/null | tr '[:upper:]' '[:lower:]'); h=${h%%.*}
  [ -n "$h" ] || return 1
  [ "$n" = "$h" ] && return 0
  printf '%s\n' ${FLEET_NODE_ALIASES:-} | tr '[:upper:]' '[:lower:]' | grep -qx -- "$h=$n"
}

# fleet_hub_place <sess> <repo> <issue|scratch> <node> [<origin_wid>] [<agent>] [<wait>]
# [<account_class>] [<name>] — ask the hub which machine opens a session on (repo,
# issue) (issue #1425, EPIC #1419 C6), or a raw scratch session of <repo> (issue
# #1541: `scratch` in place of the issue — no lease, the scratch-<N> is minted
# where it opens, so the asker names its fleet UUID; <name> is the scratch's
# optional name). <account_class> (issue #1540) is `local` / `pool` to bind the
# kind of subscription; anything else adds nothing.
# Run AFTER fleet_hub_lease granted the lease: a REMOTE answer means the hub
# already handed that lease to the chosen machine's fleet and sent it the start
# (a journalled worker_start carrying <origin_wid>, the parent) — and, since issue
# #1586, waited for what became of it: <wait> seconds (`--wait`), the hub's own 30
# when empty, 0 = answer on acceptance. Off unless CCQUOTA_FLEET=1. <node> is
# `auto` or a machine name (an alias is turned back into the hostname the hub
# knows). Prints the place command's one line, machine names through
# FLEET_NODE_ALIASES — `LOCAL <m>\t<reason>` / `REMOTE <m> <op> <status>\t<reason>` /
# `REMOTE <m> <op> done <window>\t<reason>` / `DECLINED <m> <op> <exit>\t<line>` /
# `UNKNOWN <m> <op>\t<msg>` / `HELD <m>\t<msg>` / `REFUSED <code>\t<msg>` — and returns:
#   0  LOCAL or REMOTE             3  the issue is leased elsewhere
#   4  refused: no machine can take it, or the chosen one would not
#   5  the start was sent and that machine's spawn refused it (<exit> is its
#      code: 2 at capacity, 3 claimed, 1 anything else); the lease is ours again
#   6  sent, but no final state within the wait — unknown, never a success
#   1  the hub could not be asked (no command, no node token — #1491 —, no fleet
#      UUID, or the command failed) — one stderr note; open it here as today
#  10  the hub module is off: nothing ran, nothing printed
# <account_class> (issue #1540) is `local` / `pool` — the kind of subscription the
# session must run on, carried to the machine that opens it as `--account`;
# anything else (`any`, empty) adds nothing to the command.
# The command is FLEET_HUB_PLACE_CMD, else `ccquota place`; it is run as
# `<cmd> --node <node> [--origin-wid <wid>] [--agent <a>] [--account <c>] <repo> <issue> <worker_id>`
# — for a scratch `[--name <n>] <repo> scratch <fleet UUID>` —
# with the node token from node.env in ITS environment only (`_fleet_hub_env`).
fleet_hub_place() {
  local sess="${1:-}" repo="${2:-}" num="${3:-}" node="${4:-auto}" owid="${5:-}" agent="${6:-}" wait="${7:-}" acct="${8:-}" name="${9:-}" cmd u pre='' out rc why ef what wid
  fleet_hub_on "$sess" || return 10
  case "$num" in scratch) what='a scratch session' ;; ''|*[!0-9]*) return 1 ;; *) what="#$num" ;; esac
  cmd="${FLEET_HUB_PLACE_CMD:-}"
  if [ -z "$cmd" ]; then
    if command -v ccquota >/dev/null 2>&1; then cmd='ccquota place'
    else printf 'fleet: hub placement unavailable (no FLEET_HUB_PLACE_CMD, no ccquota on PATH) — opening %s here\n' "$what" >&2; return 1; fi
    if why=$(_fleet_hub_creds_missing); then
      printf 'fleet: %s — opening %s here\n' "$why" "$what" >&2; return 1
    fi
  fi
  u=$(fleet_uuid "$sess") && [ -n "$u" ] || {
    printf 'fleet: hub placement unavailable (no fleet UUID for %s on this machine) — opening %s here\n' "$sess" "$what" >&2; return 1; }
  if [ "$num" = scratch ]; then wid="$u"; name=$(printf '%s' "$name" | LC_ALL=C tr -d '[:cntrl:]#')
  else _fleet_hosts_many "$sess" && pre="$(fleet_slug "$(fleet_norm_repo "$repo")"):"; wid="$u/${pre}issue-$num"; name=''; fi
  # An alias the operator typed (`m5`) is the hub's hostname (`macmini`).
  [ "$node" != auto ] && node=$(printf '%s\n' ${FLEET_NODE_ALIASES:-} | awk -F= -v n="$node" '$2 == n { print $1; f = 1; exit } END { if (!f) print n }')
  ef=$(mktemp "${TMPDIR:-/tmp}/fleet-hub-err.XXXXXX" 2>/dev/null) || ef=/dev/null
  case "$wait" in *[!0-9]*) wait='' ;; esac
  case "$acct" in local|pool) ;; *) acct='' ;; esac
  out=$(_fleet_hub_env; bash -c "$cmd \"\$@\"" place --node "$node" ${owid:+--origin-wid "$owid"} ${agent:+--agent "$agent"} \
        ${wait:+--wait "$wait"} ${acct:+--account "$acct"} ${name:+--name "$name"} "$repo" "$num" "$wid" </dev/null 2>"$ef"); rc=$?
  out=$(printf '%s\n' "$out" | head -n1 | awk -F'\t' -v al="${FLEET_NODE_ALIASES:-}" '
    BEGIN { n = split(al, a, " "); for (i = 1; i <= n; i++) if ((p = index(a[i], "=")) > 1) m[substr(a[i], 1, p - 1)] = substr(a[i], p + 1) }
    { k = split($1, w, " ")
      if ((w[1] == "LOCAL" || w[1] == "REMOTE" || w[1] == "HELD" || w[1] == "DECLINED" || w[1] == "UNKNOWN") && (w[2] in m)) w[2] = m[w[2]]
      h = w[1]; for (i = 2; i <= k; i++) h = h " " w[i]
      $1 = h; print }' OFS='\t')
  case "$rc" in
    0|3|4|5|6) [ "$ef" = /dev/null ] || rm -f "$ef"; printf '%s\n' "$out"; return "$rc" ;;
  esac
  printf 'fleet: %s — placing %s, opening it here\n' "$(_fleet_hub_fail placement "$cmd" "$rc" "$ef")" "$what" >&2
  [ "$ef" = /dev/null ] || rm -f "$ef"
  return 1
}

# fleet_hub_move plan|send [<flag>…] <repo> <worker_id> — move a session to another
# machine through the hub (issue #1426, EPIC #1419 C7; fleet-move.sh --via hub).
# Off unless CCQUOTA_FLEET=1. A `--node <m>` flag naming an alias (`m5`) is turned
# back into the hostname the hub knows; machine names in the answer go through
# FLEET_NODE_ALIASES, as the sidebar's do. Prints the move command's one line:
#   plan → `LOCAL <m>\t<reason>` / `REMOTE <m> movable|old\t<reason>` / `REFUSED <code>\t<msg>`
#   send → `MOVED <m> <window> <pid>\t<new wid>` / `HELD <m>\t<msg>` /
#          `REFUSED <code>\t<msg>` / `FAILED <code>\t<msg>` / `UNKNOWN <op>\t<msg>`
# and returns the command's code (0 / 3 held / 4 refused / 5 failed / 6 unknown),
# 1 when the hub could not be asked (one stderr note: no command, no node token —
# #1491 —, or the command failed), 10 when the module is off.
# The command is FLEET_HUB_MOVE_CMD, else `ccquota move`, run with the node token
# from node.env in ITS environment only (`_fleet_hub_env`).
fleet_hub_move() {
  local cmd out rc a prev='' n why ef
  [ "${CCQUOTA_FLEET:-0}" = 1 ] || return 10
  cmd="${FLEET_HUB_MOVE_CMD:-}"
  if [ -z "$cmd" ]; then
    if command -v ccquota >/dev/null 2>&1; then cmd='ccquota move'
    else printf 'fleet: hub move unavailable (no FLEET_HUB_MOVE_CMD, no ccquota on PATH)\n' >&2; return 1; fi
    if why=$(_fleet_hub_creds_missing); then
      printf 'fleet: %s — the move cannot be asked for\n' "$why" >&2; return 1
    fi
  fi
  # Rotate the argv in place (no arrays: this lib must parse under POSIX sh).
  n=$#
  while [ "$n" -gt 0 ]; do
    a=$1; shift; n=$((n - 1))
    if [ "$prev" = --node ] && [ "$a" != auto ]; then
      a=$(printf '%s\n' ${FLEET_NODE_ALIASES:-} | awk -F= -v n="$a" '$2 == n { print $1; f = 1; exit } END { if (!f) print n }')
    fi
    set -- "$@" "$a"; prev=$a
  done
  ef=$(mktemp "${TMPDIR:-/tmp}/fleet-hub-err.XXXXXX" 2>/dev/null) || ef=/dev/null
  out=$(_fleet_hub_env; bash -c "$cmd \"\$@\"" move "$@" </dev/null 2>"$ef"); rc=$?
  out=$(printf '%s\n' "$out" | head -n1 | awk -F'\t' -v al="${FLEET_NODE_ALIASES:-}" '
    BEGIN { n = split(al, a, " "); for (i = 1; i <= n; i++) if ((p = index(a[i], "=")) > 1) m[substr(a[i], 1, p - 1)] = substr(a[i], p + 1) }
    { k = split($1, w, " ")
      if ((w[1] == "LOCAL" || w[1] == "REMOTE" || w[1] == "MOVED" || w[1] == "HELD") && (w[2] in m)) w[2] = m[w[2]]
      h = w[1]; for (i = 2; i <= k; i++) h = h " " w[i]
      $1 = h; print }' OFS='\t')
  case "$rc" in
    0|3|4|5|6) [ "$ef" = /dev/null ] || rm -f "$ef"; printf '%s\n' "$out"; return "$rc" ;;
  esac
  printf 'fleet: %s — the move\n' "$(_fleet_hub_fail move "$cmd" "$rc" "$ef")" >&2
  [ "$ef" = /dev/null ] || rm -f "$ef"
  return 1
}

# fleet_worker_locate <worker_id | wid:… | key | window> [<sess>] → ONE line:
#   local <window_id> <sess>   live on this machine, in that window of fleet <sess>
#   remote <node>              not here; the hub last saw it on <node>
#   unknown                    neither — never live here, and the hub can't place it
# rc 0 for every verdict above; rc 2 (and `unknown`) for a target that is no
# worker_id, key or window. A window target (@id / %pane / sess:idx / sess:name)
# is local or unknown, nothing else — which is why a repo-qualified key
# (`<slug>:issue-<N>`, the same shape as `sess:name`) needs its `wid:` prefix. A worker_id of a fleet configured HERE never asks the hub:
# its fleet is this machine, so not-live-here is `unknown`.
fleet_worker_locate() {
  local t="${1:-}" sess="${2:-}" sp u k home w node rc
  [ -n "$sess" ] || sess=$(fleet_current_session 2>/dev/null)
  case "$t" in
    wid:*|*/*|issue-*|scratch-*) sp=$(_fleet_wid_split "$t") || { echo unknown; return 2; } ;;
    *) sp='' ;;
  esac
  if [ -n "$sp" ]; then
    u=${sp%%$'\t'*}; k=${sp#*$'\t'}
    if home=$(fleet_wid_home "$t" "$sess"); then
      # The ONE resolver (fleet_win_for_key, issue #1537): a bare issue key in a
      # 2+ repo fleet, or a key two windows answer to, is AMBIGUOUS (rc 2, said on
      # stderr) — `unknown` here, never a first-match pick, and never the hub.
      # An identity (issue #1646) resolves through fleet_win_for_fid, same rails.
      w=$(fleet_win_for_addr "$k" "$(fleet_socket "$home")"); rc=$?
      [ "$rc" -eq 0 ] && [ -n "$w" ] && { printf 'local %s %s\n' "$w" "$home"; return 0; }
      [ "$rc" -eq 2 ] && { echo unknown; return 0; }
      [ -n "$u" ] && { echo unknown; return 0; }
    fi
    if node=$(_fleet_hub_node "$u" "$k"); then printf 'remote %s\n' "$node"; else echo unknown; fi
    return 0
  fi
  case "$t" in
    @*|%*)
      w=$(_fleet_tmux "$sess" display-message -p -t "$t" '#{window_id}' 2>/dev/null)
      if [ -n "$w" ]; then printf 'local %s %s\n' "$w" "$(_fleet_tmux "$sess" display-message -p -t "$w" "$FLEET_SESSION_FMT" 2>/dev/null)"
      else echo unknown; fi
      return 0 ;;
    *:*)
      # `<sess>:<idx>` is a POSITION (renumbered under you) and `<sess>:<name>` a
      # prefix-matched NAME (scratch-1 → scratch-12): neither is an address
      # (issue #1537 ③). A repo-qualified key is spelled `wid:<slug>:issue-<N>`.
      printf 'fleet: %s is a window position or name, not an address — use wid:<key>, @<window-id> or %%<pane-id>\n' "$t" >&2
      echo unknown; return 2 ;;
  esac
  echo unknown; return 2
}

# fleet_hub_reap <worker_id> [<wait-secs>] — reap a worker that lives on ANOTHER
# machine through the hub's worker_reap (issue #1589): the node runs `dash-reap.sh
# <key> --yes` on its own server, by its own rules, and writes back #1586's
# terminal fields (exit / stderr1 / token). Answers exactly as a local
# `dash-reap.sh … --yes` would: the result token on stdout, the reason as one
# `reap: …` line on stderr, the same exit status —
#   reaped:full | reaped:keep        0
#   skip:live | skip:<why>           3   nothing touched there (the node's reason)
#   refused:<slug>                   4   nothing touched; refused:hub = the hub said
#                                        no, or could not be asked (nothing was sent)
#   failed:<slug>                    5   the outcome is UNKNOWN — never counted as
#                                        reaped (an old node, a timeout, a lost write)
# An older node that does not write the fields back is read off its error message.
# The write goes through fleet-hub-write.sh (FLEET_HUB_WRITE_CMD is its test seam).
fleet_hub_reap() {
  local wid="${1:-}" wait="${2:-90}" ef rec rc out
  case "$wid" in */*) ;; *) printf 'refused:hub\n'; printf 'reap: %s is not a worker_id\n' "$wid" >&2; return 4 ;; esac
  case "$wait" in ''|*[!0-9]*) wait=90 ;; esac
  ef=$(mktemp "${TMPDIR:-/tmp}/fleet-hub-reap.XXXXXX" 2>/dev/null) || ef=/dev/null
  rec=$(bash "$_FLEET_LIB_DIR/fleet-hub-write.sh" worker_reap \
        "$(printf '{"worker_id":"%s"}' "$wid")" --wait "$wait" 2>"$ef" </dev/null)
  out=$(printf '%s' "$rec" | FHR_NOTE="$(tail -n1 "$ef" 2>/dev/null)" FHR_WAIT="$wait" python3 -c '
import json, os, re, sys
note = os.environ.get("FHR_NOTE", "").replace("fleet-hub-write: ", "", 1)
def say(token, rc, why):
    print("%d\t%s\t%s" % (rc, token, " ".join(str(why or "no detail").split())[:300]))
    sys.exit(0)
try:
    o = json.loads(sys.stdin.read() or "null")
except ValueError:
    o = None
if not isinstance(o, dict):
    say("refused:hub", 4, "nothing sent — " + (note or "the hub gave no answer"))
if "error" in o and not o.get("operation_id"):
    e = o["error"] if isinstance(o["error"], dict) else {"message": str(o["error"])}
    say("refused:hub", 4, "the hub refused — %s: %s" % (e.get("code", "?"), e.get("message", "")))
st = o.get("status", "?")
res = o.get("result") if isinstance(o.get("result"), dict) else {}
err = res.get("error") if isinstance(res.get("error"), dict) else {}
op = o.get("operation_id", "?")
if st == "succeeded":
    tok = str(res.get("token") or res.get("how") or "")
    if tok.startswith("reaped:"):
        say(tok, 0, res.get("kept", ""))
    say("failed:unconfirmed", 5, "the node answered succeeded without a reap token (op=%s)" % op)
msg = err.get("message", "")
tok = str(err.get("token") or "")
if not tok:
    m = re.search(r"\b((?:skip|refused|failed):[a-z0-9-]+)", msg)
    tok = m.group(1) if m else ""
why = err.get("stderr1") or msg
if st == "failed":
    if err.get("code") == "NOT_FOUND" and not tok:
        tok = "refused:no-target"
    if tok.startswith("skip:"):
        say(tok, 3, why)
    if tok.startswith("refused:"):
        say(tok, 4, why)
    say("refused:" + (err.get("code") or "node").lower().replace("_", "-"), 4, why)
if st == "unknown":
    say(tok if tok.startswith("failed:") else "failed:unknown", 5,
        "outcome unknown — not counted as reaped: %s (op=%s)" % (why, op))
say("failed:unconfirmed", 5, "still %s on the node after %ss — not counted as reaped (op=%s)"
    % (st, os.environ.get("FHR_WAIT", "?"), op))
' 2>/dev/null)
  [ "$ef" = /dev/null ] || rm -f "$ef"
  [ -n "$out" ] || out=$(printf '5\tfailed:unreadable\tthe hub answer could not be read')
  rc=${out%%	*}; out=${out#*	}
  printf '%s\n' "${out%%	*}"
  printf 'reap: %s\n' "${out#*	}" >&2
  return "$rc"
}

# fleet_stamp_origin_wid <sess> <window> <origin> [<sock>] — beside the @origin key a spawn
# stamps, record the PARENT's worker_id as @origin_wid, so a child that ends up on
# another machine can still address its parent. Only for a key-shaped origin (not
# empty/hub, autofill, bridge or a cross-fleet name) and only when this machine
# has a fleet UUID; otherwise nothing is set — the one-machine case, as before.
# Since issue #1646 the parent is named by its IDENTITY: the key is resolved to the
# parent's window NOW, while it is fresh (fleet_win_for_key — the same rails), and
# that window's @fleet_id is stamped as @origin_fid — with or without a fleet UUID,
# since a rename on one machine needs no hub — and @origin_wid becomes
# `<fleet UUID>/<fleet_id>`. A key no single live window answers to keeps the old
# `<fleet UUID>/<key>` and no @origin_fid: resolution falls back to the key.
fleet_stamp_origin_wid() {
  local s="${1:-}" w="${2:-}" o="${3:-}" k="${4:-}" pf ow
  [ -n "$w" ] && _fleet_wid_split "$o" >/dev/null || return 0
  fleet_is_fid "$o" && return 0          # @origin is a key, never an identity
  pf=$(_fleet_key_fid "$s" "$o" "$k") || pf=''
  if [ -n "$pf" ]; then
    if [ -n "$k" ]; then tmux -L "$k" set-window-option -t "$w" @origin_fid "$pf" 2>/dev/null
    else _fleet_tmux "$s" set-window-option -t "$w" @origin_fid "$pf" 2>/dev/null; fi
  fi
  ow=$(fleet_key_wid "$s" "$o" "$k" "$pf") || return 0
  if [ -n "$k" ]; then tmux -L "$k" set-window-option -t "$w" @origin_wid "$ow" 2>/dev/null
  else _fleet_tmux "$s" set-window-option -t "$w" @origin_wid "$ow" 2>/dev/null; fi
  return 0
}

# _fleet_key_fid <sess> <key> [<sock>] → the @fleet_id of the ONE live window that
# answers to <key> right now (minted if it has none), rc 1 when none or several do.
_fleet_key_fid() {
  local pw
  pw=$(fleet_win_for_key "${2:-}" "${3:-}" 2>/dev/null) && [ -n "$pw" ] || return 1
  fleet_window_fid "${1:-}" "$pw" "${3:-}"
}

# fleet_key_wid <sess> <key> [<sock>] [<fleet_id>] → the worker_id to NAME the
# session that answers to <key> on this fleet by: `<fleet UUID>/<fleet_id>` when one
# live window does (issue #1646), else the old `<fleet UUID>/<key>`. rc 1 when this
# machine has no fleet UUID. A <fleet_id> already resolved skips the lookup.
fleet_key_wid() {
  local u f="${4:-}"
  u=$(fleet_uuid "${1:-}") && [ -n "$u" ] || return 1
  [ -n "$f" ] || f=$(_fleet_key_fid "${1:-}" "${2:-}" "${3:-}") || f=''
  printf '%s/%s' "$u" "${f:-${2:-}}"
}

# fleet_origin_win <sess> <window> [<sock>] → the live window of <window>'s PARENT:
# by @origin_fid first (issue #1646 — the parent may have changed its key since),
# else by @origin through fleet_win_for_key. rc as the resolver that answered;
# a parent with neither is rc 1.
fleet_origin_win() {
  local s="${1:-}" w="${2:-}" k="${3:-}" row pf po rc
  [ -n "$w" ] || return 1
  if [ -n "$k" ]; then row=$(tmux -L "$k" display-message -p -t "$w" '#{@origin_fid}|#{@origin}' 2>/dev/null)
  else row=$(_fleet_tmux "$s" display-message -p -t "$w" '#{@origin_fid}|#{@origin}' 2>/dev/null); fi
  pf=${row%%|*}; po=${row#*|}
  if fleet_is_fid "$pf"; then
    fleet_win_for_fid "$pf" "$k"; rc=$?
    [ "$rc" -eq 1 ] || return "$rc"
  fi
  [ -n "$po" ] || return 1
  fleet_win_for_key "$po" "$k"
}

# fleet_restore_wins <restore.map> → its WIN rows, the way restore() reads them: a
# `FID<TAB><fleet_id>` row (issue #1646, written just before its window's WIN row)
# tags that row, whose column 1 then reads `WIN:<fleet_id>`; every other column is
# byte for byte the map's. A map without FID rows prints exactly `$1=="WIN"`.
fleet_restore_wins() {
  awk -F'\t' 'BEGIN { OFS = "\t" }
    $1 == "FID" { f = $2; next }
    $1 == "WIN" { if (f != "") $1 = "WIN:" f; f = ""; print; next }
    { f = "" }' "${1:-/dev/null}" 2>/dev/null
}

# fleet_origin_heal <sess> [<sock>] — keep every child's @origin the key its
# parent answers to NOW (issue #1646). The parent is found by the child's
# @origin_fid; when that window's key is no longer what @origin says (a scratch
# bound to an issue, fleet-bind.sh / the dash's rebind), @origin — and its
# @origin_gen, which belonged to the old key — are rewritten. So every reader that
# joins on keys (the sidebar's nesting, the k/N badge, fleet-children.sh, the
# report digest) follows the parent without learning about identities. A child
# with no @origin_fid, or whose parent is not live here, is left alone. Prints one
# `healed <window> <old> → <new>` line per rewrite; never fails.
fleet_origin_heal() {
  local sess="${1:-}" sock="${2:-}" wl line wid rest wsess pool f of o ids='' pw pk
  [ -n "$sess" ] || return 0
  if [ -n "$sock" ]; then
    wl=$(fleet_lw '#{window_id}|#{session_name}|#{@pool}|#{@fleet_id}|#{@origin_fid}|#{@origin}' tmux -L "$sock")
  else
    wl=$(fleet_lw '#{window_id}|#{session_name}|#{@pool}|#{@fleet_id}|#{@origin_fid}|#{@origin}' _fleet_tmux "$sess")
  fi
  [ -n "$wl" ] || return 0
  case "$wl" in *'|'????????-????-????-????-????????????'|'*) ;; *) return 0 ;; esac   # nobody has an @origin_fid
  while IFS= read -r line; do               # pass 1: identity → window, this fleet's own
    [ -n "$line" ] || continue
    wid=${line%%|*}; rest=${line#*|}; wsess=${rest%%|*}; rest=${rest#*|}
    pool=${rest%%|*}; rest=${rest#*|}; f=${rest%%|*}
    [ "$wsess" = "$sess" ] && [ "$pool" != 1 ] && [ -n "$f" ] && ids="$ids$f $wid"$'\n'
  done <<EOF
$wl
EOF
  while IFS= read -r line; do               # pass 2: each child whose parent's key moved
    [ -n "$line" ] || continue
    wid=${line%%|*}; rest=${line#*|}; wsess=${rest%%|*}; rest=${rest#*|}
    rest=${rest#*|}; rest=${rest#*|}; of=${rest%%|*}; o=${rest#*|}
    [ "$wsess" = "$sess" ] && fleet_is_fid "$of" || continue
    pw=$(printf '%s' "$ids" | awk -v f="$of" '$1 == f { print $2; n++ } END { exit n != 1 }') || continue
    [ "$pw" != "$wid" ] || continue
    pk=$(fleet_window_okey "$sess" "$pw" 2>/dev/null)
    [ -n "$pk" ] && [ "$pk" != "$o" ] || continue
    if [ -n "$sock" ]; then
      tmux -L "$sock" set-window-option -t "$wid" @origin "$pk" 2>/dev/null || continue
      tmux -L "$sock" set-window-option -u -t "$wid" @origin_gen 2>/dev/null
    else
      _fleet_tmux "$sess" set-window-option -t "$wid" @origin "$pk" 2>/dev/null || continue
      _fleet_tmux "$sess" set-window-option -u -t "$wid" @origin_gen 2>/dev/null
    fi
    fleet_stamp_origin_gen "$sess" "$wid" "$pk" "$sock"
    printf 'healed %s %s → %s\n' "$wid" "${o:--}" "$pk"
  done <<EOF
$wl
EOF
  return 0
}

# ---- across machines: the hub outbox + the worker map (issue #1421, EPIC #1419 C2) --
# A worker whose parent — or whose message's target — lives on another machine
# reaches it through the hub, and the only door to the hub on this machine is the
# ccquota agent's control channel. So nothing here dials the network: a relay is a
# JSON file dropped in the OUTBOX (the agent sends it, and deletes it once the hub
# has stored it), and where a worker lives is the WORKER MAP the agent keeps
# (`<worker_id>\t<node>[:lost]\t<parent worker_id>` per line, pushed by the hub
# about every 10 s). `bin/fleet-hub-node.sh` is the agent's half (paths, deliver).
# All of it is off unless CCQUOTA_FLEET=1; with it off — or the map stale — a
# fleet behaves as the one-machine fleet it always was.

fleet_hub_outbox() { printf '%s/control/hub-outbox' "$FLEET_CONF_DIR"; }
fleet_hub_cache()  { printf '%s/control/hub-workers.tsv' "$FLEET_CONF_DIR"; }
# Where this login's ccquota agent downloads a session's transcript bundle when
# the hub moves one HERE (issue #1426); fleet-control-read.sh movein reads it.
fleet_hub_movein() { printf '%s/control/move-in' "$FLEET_CONF_DIR"; }

# fleet_hub_wid <uuid> <key> → the FULL worker_id the hub map holds for that
# (uuid may be empty: a bare key, matched only when exactly one row ends in it).
# Reads the cache as fleet_worker_locate does (same freshness rule); rc 1 when
# there is no such worker or no fresh map.
fleet_hub_wid() {
  local u="${1:-}" k="${2:-}" f hits
  _fleet_hub_node "$u" "$k" >/dev/null 2>&1 || return 1
  f=$(fleet_hub_cache)
  if [ -n "$u" ]; then
    awk -F'\t' -v w="$u/$k" '$1 == w { print $1; f = 1; exit } END { exit !f }' "$f" 2>/dev/null
    return
  fi
  hits=$(awk -F'\t' -v s="/$k" 'length($1) > length(s) && substr($1, length($1) - length(s) + 1) == s { print $1 }' "$f" 2>/dev/null)
  [ -n "$hits" ] && [ "$(printf '%s\n' "$hits" | grep -c .)" -eq 1 ] || return 1
  printf '%s' "$hits"
}

# fleet_hub_put <kind> <from_wid> <to_wid> <id-suffix> <payload-json> → drop one
# relay in the outbox (atomically: written aside, then renamed to *.json — the
# agent reads only those). The relay id is `<from_wid>#<id-suffix>`, the hub's
# idempotency key: the same suffix twice is ONE delivery. Prints the file; rc 1
# when the hub is off or the file could not be written.
fleet_hub_put() {
  local kind="${1:-}" from="${2:-}" to="${3:-}" suf="${4:-}" payload="${5:-}" d tmp f
  [ "${CCQUOTA_FLEET:-0}" = 1 ] || return 1
  [ -n "$kind" ] && [ -n "$from" ] && [ -n "$to" ] && [ -n "$suf" ] || return 1
  d=$(fleet_hub_outbox)
  mkdir -p "$d" 2>/dev/null || return 1
  tmp=$(mktemp "$d/.put.XXXXXX" 2>/dev/null) || return 1
  if ! python3 - "$kind" "$from" "$to" "$suf" "$payload" >"$tmp" 2>/dev/null <<'PY'
import json, os, sys
kind, frm, to, suf, payload = sys.argv[1:6]
p = json.loads(payload or "{}")
if not isinstance(p, dict):
    sys.exit(1)
r = dict(id=frm + "#" + suf, kind=kind, **{"from": frm}, to=to, payload=p)
# The session's worker assertion (issue #1810): handed to the sending script by its
# tool service (fleet-mcp.py), in the environment only; the hub checks it and
# audits the session. Absent = the node's own relay, byte for byte as before.
w = os.environ.get("FLEET_WORKER_ASSERT", "").strip()
if w:
    r["worker"] = w
print(json.dumps(r, ensure_ascii=False, separators=(",", ":")))
PY
  then rm -f "$tmp"; return 1; fi
  # The name sorts oldest-first (the agent sends in name order); the suffix keeps
  # two relays of one second apart.
  f="$d/$(date -u +%Y%m%dT%H%M%SZ)-$$-${tmp##*.}.json"
  mv -f "$tmp" "$f" 2>/dev/null || { rm -f "$tmp"; return 1; }
  printf '%s' "$f"
}

# fleet_hub_wait_sent <file> [<secs>] — rc 0 once the agent has handed <file> to the
# hub (it deletes it on the hub's ack), rc 1 if it is still queued after <secs> (3).
fleet_hub_wait_sent() {
  local f="${1:-}" n="${2:-3}" i=0
  case "$n" in ''|*[!0-9]*) n=3 ;; esac
  while [ -e "$f" ]; do
    [ "$i" -ge $((n * 5)) ] && return 1
    sleep 0.2; i=$((i + 1))
  done
  return 0
}

# fleet_remote_children <sess> <parent-key> → `<child-key>\t<node>\t<child wid>`,
# one line per worker on ANOTHER machine whose @origin_wid is this parent's
# worker_id, per the hub map. Nothing (rc 1) when the hub is off, this machine
# has no fleet UUID, or the map is older than FLEET_HUB_RETAIN_SECS (600): a
# hub gone that long is a one-machine fleet again (EPIC #1419 rule 6). A child
# whose node is lost carries `<node>:lost`.
fleet_remote_children() {
  local sess="${1:-}" key="${2:-}" u f m ttl pf
  fleet_hub_on "$sess" && [ -n "$key" ] || return 1
  f=$(fleet_hub_cache); [ -f "$f" ] || return 1
  ttl="${FLEET_HUB_RETAIN_SECS:-600}"; case "$ttl" in ''|*[!0-9]*) ttl=600 ;; esac
  m=$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null) || m=0
  [ $(( $(date +%s) - ${m:-0} )) -le "$ttl" ] || return 1
  u=$(fleet_uuid "$sess") && [ -n "$u" ] || return 1
  # …or by this parent's IDENTITY (issue #1646): a child spawned since names it
  # `<fleet UUID>/<fleet_id>`, whatever key the parent answers to now. The map
  # lists a child under both its worker_ids; only the key-form row is printed.
  pf=$(_fleet_key_fid "$sess" "$key" "$(fleet_socket "$sess")" 2>/dev/null) || pf=''
  awk -F'\t' -v me="$u/$key" -v mef="${pf:+$u/$pf}" -v mine="$u/" '
    ($3 == me || (mef != "" && $3 == mef)) && $2 != "" && index($1, mine) != 1 {
      k = $1; sub(/^[^\/]*\//, "", k)
      if (length(k) == 36 && k !~ /[^0-9a-f-]/) next   # the identity-form row
      print k "\t" $2 "\t" $1; n++ }
    END { exit !n }' "$f" 2>/dev/null
}

# --- the child-report ledger as a PARENT MAP (issue #1352) ----------------------
# A reaped middle window takes its @origin with it, so a grandchild's chain used to
# break there and sink to the dash's orphan bottom. But the parent link is already
# written down: every child report lands in `children/<parent-key>.ndjson` (#937),
# so `{"child":"issue-11101"}` in `issue-10550.ndjson` IS "11101's parent is 10550".
# The close path is untouched; this only READS that book.
#
# fleet_origin_map <sess> → path of `children/.origin-map`, one `<child>\t<parent>`
# line per child, rebuilt only when the ledger changed. The ledger is append-only,
# so the signature is the files' byte sizes (`wc -c`, portable, one fork) kept in
# `.origin-map.sig` — an mtime test can miss an append in the same second. A
# `relayed_from` row (a report forwarded to an ancestor, below) is NOT a parent
# link and is skipped; a child named in two books keeps its first. Prints nothing
# and returns 1 when the fleet has no ledger.
#
# Generations (issue #1538): a row whose child is a key that has been re-allocated
# since (`children/.gen`, below) is the PREVIOUS holder's link — it is skipped, so
# a new scratch-3 never inherits the old one's parent. A row is current when its
# `child_gen` equals the key's current generation (`child_key`, the repo-qualified
# spelling, is looked up first); a row without one is generation 0. No `.gen` ⇒
# every row is current, byte for byte the map it always was.
fleet_origin_map() {
  local d sig old='' f g=''
  [ -n "${1:-}" ] || return 1
  d="$FLEET_CONF_DIR/fleets/$1/children"
  [ -d "$d" ] || return 1
  f="$d/.origin-map"
  [ -f "$d/.gen" ] && g=.gen
  sig=$(cd "$d" 2>/dev/null && wc -c -- *.ndjson $g 2>/dev/null)
  [ -f "$f.sig" ] && old=$(cat "$f.sig" 2>/dev/null)
  if [ ! -f "$f" ] || [ "$sig" != "$old" ]; then
    (cd "$d" 2>/dev/null && awk '
      FILENAME == ".gen" { t = index($0, "\t"); if (t > 1) gen[substr($0, 1, t - 1)] = substr($0, t + 1); next }
      FNR == 1 { p = FILENAME; sub(/\.ndjson$/, "", p) }
      /"relayed_from": *"[^"]/ { next }
      match($0, /"child": *"[^"]*"/) {
        c = substr($0, RSTART, RLENGTH); sub(/^"child": *"/, "", c); sub(/"$/, "", c)
        if (c == "" || c == p || (c in seen)) next
        ck = c
        if (match($0, /"child_key": *"[^"]*"/)) { ck = substr($0, RSTART, RLENGTH); sub(/^"child_key": *"/, "", ck); sub(/"$/, "", ck) }
        cg = ""
        if (match($0, /"child_gen": *"[^"]*"/)) { cg = substr($0, RSTART, RLENGTH); sub(/^"child_gen": *"/, "", cg); sub(/"$/, "", cg) }
        if ((ck in gen) && gen[ck] != cg) next
        seen[c] = 1; print c "\t" p
      }' $g *.ndjson 2>/dev/null) > "$f.$$" && mv -f "$f.$$" "$f"
    printf '%s' "$sig" > "$f.sig.$$" && mv -f "$f.sig.$$" "$f.sig"
  fi
  printf '%s' "$f"
}

# fleet_origin_of <key> [sess] [sock] → the key's parent key, or nothing (exit 1).
# A live window answers with its own @origin; a reaped one with the ledger's
# record. A bare ledger child (`issue-N`, what a report writes) also answers for a
# repo-qualified `<slug>:issue-N` (issue #789), which is what @origin carries.
fleet_origin_of() {
  local key="${1:-}" sess="${2:-}" sock="${3:-}" w o map t m
  [ -n "$key" ] || return 1
  if w=$(fleet_win_for_key "$key" "$sock") && [ -n "$w" ]; then
    if [ -n "$sock" ]; then o=$(tmux -L "$sock" display-message -p -t "$w" '#{@origin}' 2>/dev/null)
    else o=$(tmux display-message -p -t "$w" '#{@origin}' 2>/dev/null); fi
    [ -n "$o" ] && { printf '%s' "$o"; return 0; }
    return 1
  fi
  [ -n "$sess" ] || sess="$sock"
  [ -n "$sess" ] || sess=$(fleet_current_session 2>/dev/null)
  map=$(fleet_origin_map "$sess") || return 1
  t=$'\n'$(cat "$map" 2>/dev/null)$'\n'
  m=${t#*$'\n'"$key"$'\t'}
  if [ "$m" = "$t" ] && [ "${key#*:}" != "$key" ]; then m=${t#*$'\n'"${key#*:}"$'\t'}; fi
  [ "$m" = "$t" ] && return 1
  m=${m%%$'\n'*}
  [ -n "$m" ] || return 1
  printf '%s' "$m"
}

# fleet_live_ancestor <key> [sess] [sock] → `<key>\t<window-id>` of the nearest
# ancestor of <key> (itself excluded) that still has a window, climbing through
# reaped ones by the ledger; nothing (exit 1) when the chain leaves the ledger
# (hub, daemon, cross-fleet) first. ≤16 hops — the dash's CHAIN_MAX.
fleet_live_ancestor() {
  local cur="${1:-}" sess="${2:-}" sock="${3:-}" n=0 w
  while [ "$n" -lt 16 ]; do
    n=$((n + 1))
    cur=$(fleet_origin_of "$cur" "$sess" "$sock") || return 1
    case "$cur" in issue-*|scratch-*|?*:issue-*|?*:scratch-*) ;; *) return 1 ;; esac
    if w=$(fleet_win_for_key "$cur" "$sock") && [ -n "$w" ]; then
      printf '%s\t%s' "$cur" "$w"; return 0
    fi
  done
  return 1
}

# --- generations of a recycled key (issue #1538, EPIC #1529 E9) ----------------
# A scratch NUMBER is recycled: fleet_scratch_free gives scratch-3 back, and the
# next ⌃s (or the warm pool) allocates it again. Every book keyed by it — the
# child ledger `children/scratch-3.ndjson`, the parent map, a child still out
# there with `@origin scratch-3` — used to carry straight over, so the new
# scratch-3 opened showing the old one's children, and the old one's grandchild
# reported (or relayed) into a session that had never heard of it.
#
# So a key has a GENERATION, minted each time it is allocated:
#   children/.gen          `<key>\t<gen>` per allocation, the last line wins;
#                          <gen> = `<epoch>.<pid>`. No line ≡ generation 0 — every
#                          key before this change, and every issue key (an issue
#                          number is never reused, so it is never minted).
#   children/<key>.ndjson.<gen>
#                          a retired generation's book (`.0` for generation 0),
#                          moved aside when the key is minted again. A late report
#                          from that generation's child is appended here too.
#   @origin_gen            stamped on a child beside @origin: the parent's
#                          generation at spawn. A report whose @origin_gen is not
#                          the key's current generation is archived, never
#                          delivered and never relayed (the old parent's ancestry
#                          is not the new one's). A child with NO @origin_gen
#                          (spawned before this, or re-created by a restore) is
#                          taken as it always was: a live one was already moved
#                          aside at the mint (@origin_retired, below).
#   @origin_retired        `<key>#<old-gen>` on a child that was still running when
#                          its parent's key was minted again (fleet_scratch_gen_new
#                          moves @origin here, so no reader nests it under the new
#                          holder); its report goes to that retired book.
# Ledger rows carry `gen` (the parent generation they were filed under) and
# `child_gen` / `child_key` (the child's own) — fields added, none renamed.

# fleet_key_gen <sess> <key> → the key's current generation; nothing for gen 0.
fleet_key_gen() {
  local f="$FLEET_CONF_DIR/fleets/${1:-_}/children/.gen"
  [ -n "${2:-}" ] && [ -f "$f" ] || return 0
  awk -F'\t' -v k="$2" '$1 == k { g = $2 } END { if (g != "") print g }' "$f" 2>/dev/null
}

# fleet_key_gen_new <sess> <key> → mint the next generation of <key> (printed):
# its book and digest cursor are retired to `.<old-gen>` first, so the new holder
# starts with an empty ledger and the old one stays readable.
fleet_key_gen_new() {
  local sess="${1:-}" key d old g
  key=$(printf '%s' "${2:-}" | LC_ALL=C tr -cd 'A-Za-z0-9._:-')
  case "$key" in ''|.*) return 1 ;; esac
  [ -n "$sess" ] || return 1
  d="$(fleet_state_dir "$sess")/children"
  mkdir -p "$d" 2>/dev/null || return 1
  old=$(fleet_key_gen "$sess" "$key"); [ -n "$old" ] || old=0
  if [ -f "$d/$key.ndjson" ]; then
    cat "$d/$key.ndjson" >> "$d/$key.ndjson.$old" 2>/dev/null && rm -f "$d/$key.ndjson"
  fi
  [ -f "$d/$key.cursor" ] && mv -f "$d/$key.cursor" "$d/$key.cursor.$old" 2>/dev/null
  g="$(date +%s).$$"
  printf '%s\t%s\n' "$key" "$g" >> "$d/.gen" || return 1
  printf '%s' "$g"
}

# fleet_key_gen_stale <sess> <parent-key> <child's @origin_gen> → rc 0 when the
# child was stamped under a generation of <parent-key> that is no longer current;
# rc 1 when it is this generation's, or unstamped (nothing says otherwise).
fleet_key_gen_stale() {
  [ -n "${3:-}" ] || return 1
  [ "$3" != "$(fleet_key_gen "${1:-}" "${2:-}")" ]
}

# fleet_stamp_origin_gen <sess> <window> <origin> [<sock>] — beside @origin, the
# parent key's current generation as @origin_gen. Nothing for generation 0 (no
# `.gen` line): the window is stamped exactly as it always was.
fleet_stamp_origin_gen() {
  local s="${1:-}" w="${2:-}" o="${3:-}" k="${4:-}" g
  [ -n "$w" ] || return 0
  case "$o" in issue-*|scratch-*|?*:issue-*|?*:scratch-*) ;; *) return 0 ;; esac
  g=$(fleet_key_gen "$s" "$o")
  [ -n "$g" ] || return 0
  if [ -n "$k" ]; then tmux -L "$k" set-window-option -t "$w" @origin_gen "$g" 2>/dev/null
  else _fleet_tmux "$s" set-window-option -t "$w" @origin_gen "$g" 2>/dev/null; fi
  return 0
}

# fleet_scratch_gen_new <sess> <slug> <worktree> — mint the generation of a freshly
# allocated scratch under the key a spawn from it will stamp as @origin
# (fleet_origin_key): bare in a one-repo fleet, `<repo-slug>:scratch-N` in a 2+
# repo one — and nothing there when the worktree's repo cannot be told.
#
# A child of the RETIRED generation may still be running (its parent closed, its
# own work did not). Every reader of @origin — the dash and sidebar nesting,
# fleet-children.sh, the peer channel, the report — would take the new holder for
# its parent, so its link moves aside here: `@origin_retired <key>#<old-gen>`, and
# @origin / @origin_wid / @origin_gen are unset. It renders as a root, and its
# report goes to the retired book (fleet-report-parent.sh). The new holder was
# allocated a moment ago, so no window can be ITS child yet.
fleet_scratch_gen_new() {
  local pre='' r key old sock w o
  [ -n "${1:-}" ] && [ -n "${2:-}" ] || return 0
  if fleet_multirepo "$1"; then
    r=$(fleet_worktree_repo "$1" "${3:-}"); r=${r%%$'\t'*}
    [ -n "$r" ] || return 0
    pre="$(fleet_slug "$r"):"
  fi
  key="$pre$2"
  old=$(fleet_key_gen "$1" "$key"); [ -n "$old" ] || old=0
  fleet_key_gen_new "$1" "$key" >/dev/null || return 0
  sock=$(fleet_socket "$1")
  [ -n "$sock" ] || return 0
  fleet_lw '#{window_id}|#{@origin}' tmux -L "$sock" | while IFS='|' read -r w o; do
    [ -n "$w" ] && [ "$o" = "$key" ] || continue
    tmux -L "$sock" set-window-option -t "$w" @origin_retired "$key#$old" \; \
      set-window-option -u -t "$w" @origin \; \
      set-window-option -u -t "$w" @origin_wid \; \
      set-window-option -u -t "$w" @origin_gen >/dev/null 2>&1
  done
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
  # Hand what the worker left — its evidence files and the row just written — to
  # the hub (issue #1609), so the machine that spawned it sees them when this one
  # is not that machine. Not a hub node (no node token) → exit 3, nothing sent.
  if [ -f "$_bin/fleet-worker-records.sh" ] && [ -n "$repo" ]; then
    bash "$_bin/fleet-worker-records.sh" push --session "$sess" --repo "$repo" \
      --key "$key" ${win:+--win "$win"} >/dev/null 2>&1 || :
  fi
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
  f_issue=$(fleet_pane_fmt '#{@issue}')     # the caller's own pane, never `-t ""` (#1537)
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
  case "$s" in dash|plan|backlog|home) s='' ;; esac
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
  local sess="$1" conf repo pth
  conf=$(fleet_conf_file "$sess")
  if [ -f "$conf" ]; then
    repo=$( . "$conf" >/dev/null 2>&1; printf '%s' "${FLEET_REPO:-}" )
    [ -n "$repo" ] && { fleet_norm_repo "$repo"; return; }
  fi
  while IFS= read -r pth; do
    [ -z "$pth" ] && continue
    git -C "$pth" rev-parse --git-dir >/dev/null 2>&1 || continue
    repo=$(git -C "$pth" remote get-url origin 2>/dev/null) || continue
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

# CHEAP: list the tmux sessions that are FLEETS — i.e. own a home or panel window
# (@fleet_role via FLEET_ROLE_FMT, issue #1844; by name for an unstamped one) —
# one per line. The single source for "which sessions are fleets"; the
# plan/dash hub rule is otherwise copy-pasted across callers. Fans out across
# every live fleet socket (issue #159), since no single server sees them all now.
fleet_hub_sessions() {
  fleet_list_windows_all "#{session_name} $FLEET_ROLE_FMT" | awk "$FLEET_ROLE_AWK"'
    { r=frole($2); if (r=="home" || r=="panel") f[$1]=1 } END { for (s in f) print s }'
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
# server) counts exactly as before. A PROXY window onto another machine's session
# (@remote, issue #1424) rides the same field as `remote` and is no session here.
_fleet_session_tally() {   # → "<awake> <sleepers>" across every fleet
  fleet_list_windows_all "#{session_name} $FLEET_ROLE_FMT @L=#{?@remote,remote,#{@worker_lifecycle}}" | awk "$FLEET_ROLE_AWK"'
    { rows[NR]=$0; r=frole($2); if (r=="home" || r=="panel") fleet[$1]=1 }
    END {
      for (i=1; i<=NR; i++) {
        n=split(rows[i], a, " "); s=a[1]; w=frole(a[2]); l=""
        if (n>=3 && a[n] ~ /^@L=/) l=substr(a[n], 4)
        if (!fleet[s] || w!="worker" || l=="remote") continue
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
# NB: the role rule (home/panel = hub, only worker counts; FLEET_ROLE_FMT, #1844)
# AND the sleeping/failed rule are duplicated in _fleet_session_tally above — keep BOTH in sync, or the global and
# per-fleet caps count different sets.
_fleet_session_tally_for() {   # <sess> → "<awake> <sleepers>" in that fleet
  tmux -L "$(fleet_socket "$1")" list-windows -t "$1" -F "$FLEET_ROLE_FMT @L=#{?@remote,remote,#{@worker_lifecycle}}" 2>/dev/null | awk "$FLEET_ROLE_AWK"'
    { l=""
      if (match($0, / @L=[^ ]*$/)) { l=substr($0, RSTART+4); role=frole(substr($0, 1, RSTART-1)) } else role=frole($0)
      if (role=="home" || role=="panel") hub=1; rows[NR]=role; life[NR]=l }
    END {
      if (!hub) { print 0, 0; exit }
      for (i=1; i<=NR; i++) {
        if (rows[i]!="worker" || life[i]=="remote") continue
        if (life[i]=="sleeping" || life[i]=="failed") z++; else c++
      }
      print c+0, z+0
    }'
}
fleet_session_count_for() { local t; t=$(_fleet_session_tally_for "$1"); printf '%s\n' "${t%% *}"; }
fleet_session_sleepers_for() { local t; t=$(_fleet_session_tally_for "$1"); printf '%s\n' "${t##* }"; }

# Cap on concurrent Claude working sessions (issues #28, #70). Returns 0 if a new
# session may be spawned, non-zero if a cap is already reached. Two ceilings:
#   • GLOBAL   FLEET_GLOBAL_MAX_SESSIONS (default 0 = off since #1831 — the machine
#              admission below is the gate; set one to cap hard) — SYSTEM-WIDE
#              across all fleets. Checked whenever it is non-zero.
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
# With <sess>, the number's next GENERATION is minted (issue #1538): whatever the
# last scratch-<N> left in the child ledger is retired, never inherited.
fleet_scratch_alloc() {
  local main="$1" base="$2" sess="${3:-}" cand cwt n=1
  git -C "$main" fetch origin "$base" --quiet 2>/dev/null
  while [ "$n" -le 999 ]; do
    cand="scratch-$n"; cwt="$(fleet_worktree_dir "$main" "$cand")"
    if git -C "$main" show-ref --verify --quiet "refs/heads/$cand" 2>/dev/null || [ -e "$cwt" ]; then
      n=$((n + 1)); continue
    fi
    # No --reuse: `-b` failing on a branch a racing caller just took is the signal
    # to move on to the next N. Silent on both streams (#446).
    if fleet_worktree_create "$main" "$cand" "$base" >/dev/null; then
      [ -n "$sess" ] && fleet_scratch_gen_new "$sess" "$cand" "$cwt"
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
  local pat='*'
  [ -n "${1:-}" ] && pat="$(fleet_slug "$1").*"
  _fleet_fresh_markers "$FLEET_INFLIGHT_DIR" "${FLEET_INFLIGHT_TTL:-180}" "$pat"
}
# _fleet_fresh_markers <dir> <ttl-secs> <glob> → how many files matching <glob> in
# <dir> were touched within <ttl>; an older one is deleted on the way (a crashed
# writer ages out instead of holding its slot forever).
_fleet_fresh_markers() {
  local dir="$1" ttl="$2" pat="$3" now cut n=0 f m
  [ -d "$dir" ] || { printf 0; return; }
  case "$ttl" in ''|*[!0-9]*) ttl=180 ;; esac
  now=$(date +%s 2>/dev/null || echo 0); cut=$((now - ttl))
  while IFS= read -r f; do
    [ -e "$f" ] || continue
    # GNU stat FIRST: `stat -f %m` on GNU means "filesystem status" and exits 0 with
    # non-mtime output, so it must not win — `stat -c %Y` (GNU) errors cleanly on BSD.
    m=$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null || echo 0)
    case "$m" in ''|*[!0-9]*) m=0;; esac
    if [ "$m" -ge "$cut" ]; then n=$((n + 1)); else rm -f "$f" 2>/dev/null; fi
  done <<EOF
$(find "$dir" -maxdepth 1 -type f -name "$pat" 2>/dev/null)
EOF
  printf '%s' "$n"
}

# ---- admission is the ONLY capacity gate by default (issue #1831) --------------
# The count caps (FLEET_GLOBAL_MAX_SESSIONS / FLEET_MACHINE_MAX_SESSIONS) default
# to 0: a per-login number does not add up across logins, and the real limit is
# memory, which differs 4× between two machines. So fleet_machine_admit answers
# "is there room for ONE MORE" from three things it can measure:
#   cost      what one session takes — the median RSS of the live agent processes
#             × FLEET_ADMIT_SESSION_GROWTH (3: a transcript grows), never below
#             FLEET_ADMIT_SESSION_MB_MIN (512). FLEET_ADMIT_SESSION_MB pins it.
#   reserved  sessions admitted but not yet visible in the memory reading: the
#             reservations cap_ok drops at each admission (they live
#             FLEET_ADMIT_SETTLE_SECS, 120 — a window's agent needs that long to
#             boot and show up in `avail`), or the #531 in-flight markers when a
#             slow `worktree add` has outlived that — whichever is more. Without
#             it a burst of N spawns all read the same free memory and all pass.
#   floor     max(FLEET_ADMIT_MEM_FREE_PCT % of RAM, FLEET_ADMIT_RESERVE_MB 2048)
#             is never handed out; after a hold, FLEET_ADMIT_HYST_MB (1024) more
#             must free up before the gate opens again, so one session growing
#             back and forth across the line does not flap it.
# room = (avail − floor [− hyst] − reserved × cost) / cost; admit iff room ≥ 1.
FLEET_ADMIT_RESERVE_DIR="$FLEET_C/global/admit-reserve"
FLEET_ADMIT_HELD_FILE="$FLEET_C/global/admit-held"

# _fleet_session_cost → "<cost_mb>\t<median_mb>\t<agents>" (median 0 with no agent).
_fleet_session_cost() {
  local fixed="${FLEET_ADMIT_SESSION_MB:-0}" lo="${FLEET_ADMIT_SESSION_MB_MIN:-512}" g="${FLEET_ADMIT_SESSION_GROWTH:-3}"
  case "$fixed" in ''|*[!0-9]*) fixed=0 ;; esac
  case "$lo" in ''|*[!0-9]*) lo=512 ;; esac
  case "$g" in ''|*[!0-9.]*) g=3 ;; esac
  # fleet_proc_mem_rows is sorted by RSS descending, so the middle row IS the median.
  fleet_proc_mem_rows 2>/dev/null | awk -F'\t' -v fx="$fixed" -v lo="$lo" -v g="$g" '
    $5 == "agent" { r[n++] = $3 + 0 }
    END { med = (n > 0) ? r[int(n / 2)] : 0
          c = (fx > 0) ? fx : int(med * g + 0.5)
          if (fx <= 0 && c < lo) c = lo
          if (c < 1) c = 1
          printf "%d\t%d\t%d\n", c, med, n }'
}
fleet_session_cost_mb() { local c; c=$(_fleet_session_cost); printf '%s\n' "${c%%$'\t'*}"; }

# fleet_admit_reserved → sessions admitted and not yet in the memory reading.
fleet_admit_reserved() {
  local r i
  r=$(_fleet_fresh_markers "$FLEET_ADMIT_RESERVE_DIR" "${FLEET_ADMIT_SETTLE_SECS:-120}" '*')
  i=$(fleet_inflight_count)
  [ "${i:-0}" -gt "${r:-0}" ] 2>/dev/null && r=$i
  printf '%s\n' "${r:-0}"
}
# fleet_admit_reserve [sess] — hold ONE session's cost for the settle time.
fleet_admit_reserve() {
  mkdir -p "$FLEET_ADMIT_RESERVE_DIR" 2>/dev/null || return 0
  : > "$FLEET_ADMIT_RESERVE_DIR/$(fleet_slug "${1:-_}").$$.${RANDOM:-0}" 2>/dev/null
  return 0
}

# fleet_machine_headroom [avail_pct] — how many MORE sessions this machine takes
# right now. One line, space-separated, or nothing (rc 1) when memory is unreadable:
#   <room> <cost_mb> <avail_mb> <floor_mb> <reserved> <hyst_mb> <median_mb> <agents>
fleet_machine_headroom() {
  local ap="${1:-}" total c cost med agents pct rmb hyst=0 floor avail res room
  [ -n "$ap" ] || ap=$(fleet_mem_probe 2>/dev/null | awk 'NF>=2{print $2+0; exit}')
  total=$(fleet_mem_total_mb 2>/dev/null)
  case "$ap" in ''|*[!0-9]*) return 1 ;; esac
  case "$total" in ''|*[!0-9]*) return 1 ;; esac
  [ "$total" -gt 0 ] || return 1
  c=$(_fleet_session_cost); cost=${c%%$'\t'*}; c=${c#*$'\t'}; med=${c%%$'\t'*}; agents=${c#*$'\t'}
  case "$cost" in ''|*[!0-9]*) cost=512 ;; esac
  pct="${FLEET_ADMIT_MEM_FREE_PCT:-15}"; case "$pct" in ''|*[!0-9]*) pct=15 ;; esac
  rmb="${FLEET_ADMIT_RESERVE_MB:-2048}"; case "$rmb" in ''|*[!0-9]*) rmb=2048 ;; esac
  if [ -e "$FLEET_ADMIT_HELD_FILE" ]; then
    hyst="${FLEET_ADMIT_HYST_MB:-1024}"; case "$hyst" in ''|*[!0-9]*) hyst=1024 ;; esac
  fi
  avail=$(( total * ap / 100 ))
  floor=$(( total * pct / 100 )); [ "$rmb" -gt "$floor" ] && floor=$rmb
  res=$(fleet_admit_reserved)
  room=$(( (avail - floor - hyst - res * cost) / cost ))
  [ "$room" -lt 0 ] && room=0
  printf '%s %s %s %s %s %s %s %s\n' "$room" "$cost" "$avail" "$floor" "$res" "$hyst" "${med:-0}" "${agents:-0}"
}

# fleet_machine_admit [--short] — may the machine take ONE MORE session right now
# (issue #1090, EPIC #1291 C4; the only gate by default since #1831)? Exit 0 =
# admit (prints nothing). Exit 1 = hold, and stdout says why — the full line, or
# with --short just the dash/backlog tag (`暂停开新：内存紧张` / `暂停开新：负载过高`).
# Three readings, any one holds:
#   memory pressure  fleet_mem_probe level ≥ FLEET_ADMIT_PRESSURE (warn|critical|off,
#                    default warn = the kernel's own level 2)
#   memory room      fleet_machine_headroom < 1 — the cost of one more session
#                    does not fit above the floor once the reserved ones are paid
#                    for (block above). Unreadable total → the old avail% rule.
#   CPU load         1-min load/core > FLEET_ADMIT_LOAD_PER_CORE (0 = off). Defaults
#                    to FLEET_LOADGEN_LOAD_PER_CORE when the operator set one, else
#                    1.5 — a healthy 20-session afternoon reads 1.3/core (measured
#                    2026-10-03); the old 2 meant load 30 on 15 cores, which never
#                    fired (issue #1831).
# An unreadable probe admits (no reading is not a reason to stop the fleet).
# FLEET_ADMIT=0 switches it off. A hold is transient by design: every caller of
# fleet_session_cap_ok already treats a refusal as "retry later" (dispatch's next
# tick, the epic run's next refill), so spawns resume when the reading drops.
fleet_machine_admit() {
  [ "${FLEET_ADMIT:-1}" = 0 ] && return 0
  local short=0 free_min="${FLEET_ADMIT_MEM_FREE_PCT:-15}" pres="${FLEET_ADMIT_PRESSURE:-warn}"
  local lmax="${FLEET_ADMIT_LOAD_PER_CORE:-${FLEET_LOADGEN_LOAD_PER_CORE:-1.5}}" plim m lvl avail per pname
  local hr='' room=1 tight=0 why
  [ "${1:-}" = --short ] && short=1
  case "$free_min" in ''|*[!0-9]*) free_min=15 ;; esac
  case "$lmax" in ''|*[!0-9.]*) lmax=1.5 ;; esac
  case "$pres" in critical|4) plim=4 ;; off|0|none) plim=0 ;; *) plim=2 ;; esac
  m="$(fleet_mem_probe 2>/dev/null)"
  lvl=$(printf '%s\n' "$m" | awk 'NF{print $1+0; exit}')
  avail=$(printf '%s\n' "$m" | awk 'NF>=2{print $2+0; exit}')
  if [ -n "$lvl" ]; then
    [ "$plim" -gt 0 ] && [ "$lvl" -ge "$plim" ] && tight=1
    if [ -n "$avail" ]; then
      if hr=$(fleet_machine_headroom "$avail"); then
        room=${hr%% *}; [ "$room" -lt 1 ] && tight=1
      elif [ "$free_min" -gt 0 ] && [ "$avail" -lt "$free_min" ]; then
        tight=1
      fi
    fi
  fi
  if [ "$tight" = 1 ]; then
    mkdir -p "${FLEET_ADMIT_HELD_FILE%/*}" 2>/dev/null && : > "$FLEET_ADMIT_HELD_FILE" 2>/dev/null
    if [ "$short" = 1 ]; then printf '暂停开新：内存紧张'; return 1; fi
    case "$lvl" in 4) pname=critical ;; 2) pname=warn ;; *) pname=normal ;; esac
    why=''
    if [ -n "$hr" ]; then   # `read`, not `set -- $hr`: zsh (a skill's shell) does not split
      local h_room h_cost h_avail h_floor h_res h_hyst h_more
      read -r h_room h_cost h_avail h_floor h_res h_hyst h_more <<EOF
$hr
EOF
      : "${h_more:-}"   # median + agents: the doctor's, not this line's
      why="; room for $h_room more at ~$h_cost MB each: $h_avail MB available, $h_floor MB kept back"
      [ "${h_hyst:-0}" -gt 0 ] && why="$why + $h_hyst MB until it recovers"
      why="$why, $h_res admitted not yet counted"
    fi
    printf 'machine memory tight — 暂停开新：内存紧张 (pressure %s, %s%% free, floor %s%%%s): new sessions are held until it drops; running ones are untouched — retry later, or FLEET_ADMIT=0 to override' \
      "$pname" "${avail:-?}" "$free_min" "$why"
    return 1
  fi
  per="$(_fleet_load_per_core)"
  if [ -n "$per" ] && awk -v p="$per" -v m="$lmax" 'BEGIN{ exit !(m > 0 && p > m) }'; then
    if [ "$short" = 1 ]; then printf '暂停开新：负载过高'; return 1; fi
    printf 'machine load high — 暂停开新：负载过高 (%s/core, over FLEET_ADMIT_LOAD_PER_CORE=%s): new sessions are held until it drops; running ones are untouched — retry later, or FLEET_ADMIT=0 to override' \
      "$per" "$lmax"
    return 1
  fi
  [ -n "$hr" ] && rm -f "$FLEET_ADMIT_HELD_FILE" 2>/dev/null
  return 0
}

# ---- machine-wide session total across LOGINS (issue #1301, EPIC #1312 C4) ------
# Every login on a shared box runs its own fleets with its own caps, and none of
# them can see the others: five logins at 36 each is 180 sessions on one 64 GB
# machine, with nothing adding them up. Each login's collector publishes its own
# count (live session windows + in-flight spawns) once a tick to a MACHINE-level
# dir shared by every login — never under a $HOME, same convention as the heavy
# queue (#1295): dir 1777, one file per login, `<count> <epoch>`. A file older than
# FLEET_MACHINE_SESSIONS_STALE (300s) reads as 0: a login whose collector stopped
# is not holding sessions we can see. FLEET_MACHINE_SESSIONS_DIR overrides (the
# selftest seam). The login key is the basename of $HOME (= the account name on
# macOS), so a test can simulate several logins by switching HOME.
fleet_machine_sessions_dir() {
  if [ -n "${FLEET_MACHINE_SESSIONS_DIR:-}" ]; then printf '%s\n' "$FLEET_MACHINE_SESSIONS_DIR"
  elif [ "$(uname -s 2>/dev/null)" = Darwin ]; then printf '/Users/Shared/claude-fleet/sessions\n'
  else printf '/var/tmp/claude-fleet/sessions\n'
  fi
}
fleet_machine_login() {
  local l="${HOME%/}"; l="${l##*/}"
  [ -n "$l" ] || l="$(id -un 2>/dev/null)"
  printf '%s\n' "${l:-unknown}"
}
# fleet_machine_sessions_publish [count] — write THIS login's row (count defaults
# to the live awake sessions + in-flight spawns, what the caps count). Atomic:
# a hidden temp in the same dir, then rename. Creates the dir chain 1777 when it
# is the first login there. Never fails a caller that ignores its rc.
fleet_machine_sessions_publish() {
  local n="${1:-}" d f tmp p
  [ -n "$n" ] || n=$(( $(fleet_session_count) + $(fleet_inflight_count) ))
  case "$n" in ''|*[!0-9]*) return 1 ;; esac
  d="$(fleet_machine_sessions_dir)"
  for p in "${d%/*}" "$d"; do
    [ -d "$p" ] || (umask 0; mkdir "$p") 2>/dev/null
    [ -O "$p" ] && chmod 1777 "$p" 2>/dev/null
  done
  [ -d "$d" ] || return 1
  f="$d/$(fleet_machine_login)"; tmp="$d/.$(fleet_machine_login).$$"
  if printf '%s %s\n' "$n" "$(date +%s)" > "$tmp" 2>/dev/null && chmod 644 "$tmp" 2>/dev/null \
     && mv -f "$tmp" "$f" 2>/dev/null; then return 0; fi
  rm -f "$tmp" 2>/dev/null; return 1
}
# fleet_machine_sessions_rows [self-count] — one line per login:
#   `<login> <count> <age-secs> <self|fresh|stale>`
# THIS login first and LIVE (its file may be a tick old; a burst of our own spawns
# must count at once); every other login from its file, a stale or garbled one as
# 0. Dotfiles (an in-progress publish) are skipped by the glob.
fleet_machine_sessions_rows() {
  local self="${1:-}" d me stale now f l n ts age
  d="$(fleet_machine_sessions_dir)"; me="$(fleet_machine_login)"
  stale="${FLEET_MACHINE_SESSIONS_STALE:-300}"; case "$stale" in ''|*[!0-9]*) stale=300 ;; esac
  [ -n "$self" ] || self=$(( $(fleet_session_count) + $(fleet_inflight_count) ))
  now=$(date +%s)
  printf '%s %s 0 self\n' "$me" "$self"
  for f in "$d"/*; do
    [ -f "$f" ] || continue
    l="${f##*/}"; [ "$l" = "$me" ] && continue
    n=''; ts=''; read -r n ts < "$f" 2>/dev/null
    case "$n" in ''|*[!0-9]*) n=0; ts=0 ;; esac
    case "$ts" in ''|*[!0-9]*) ts=0 ;; esac
    age=$((now - ts))
    if [ "$age" -gt "$stale" ]; then printf '%s 0 %s stale\n' "$l" "$age"
    else printf '%s %s %s fresh\n' "$l" "$n" "$age"; fi
  done
}
# fleet_machine_sessions_summary [self-count] → "<total>\t<login n · login n · …>"
# (a stale login reads `alice 0 (stale)`), for the refusal and the doctor line.
fleet_machine_sessions_summary() {
  fleet_machine_sessions_rows "${1:-}" | awk '
    { t += $2; s = $1 " " $2; if ($4 == "stale") s = s " (stale)"
      out = (NR == 1) ? s : out " · " s }
    END { printf "%d\t%s\n", t, out }'
}

fleet_session_cap_ok() {
  local sess="${1:-}"
  local gmax="${FLEET_GLOBAL_MAX_SESSIONS:-0}" fmax="${FLEET_MAX_SESSIONS:-0}" n
  case "$gmax" in ''|*[!0-9]*) gmax=0;; esac   # tolerate a garbled conf value
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
  # The machine-wide total across EVERY login (issue #1301) — only when the
  # operator set a ceiling; the default 0 never reads a file. Same RC_CAP path.
  local mmax="${FLEET_MACHINE_MAX_SESSIONS:-0}" msum
  case "$mmax" in ''|*[!0-9]*) mmax=0;; esac
  if [ "$mmax" -ne 0 ]; then
    msum=$(fleet_machine_sessions_summary)
    n=${msum%%$'\t'*}
    if [ "$n" -ge "$mmax" ]; then
      printf 'machine at capacity — 全机会话已满: %s/%s Claude sessions across all logins (%s) — raise FLEET_MACHINE_MAX_SESSIONS or close one first' \
        "$n" "$mmax" "${msum#*$'\t'}"
      return 1
    fi
  fi
  # The machine's own headroom (issue #1090) — after the counts, so a full fleet
  # still reads as "at capacity". Crash restore, quota migration and a handoff's
  # continuation never come through here: they re-house a RUNNING session.
  # An admission RESERVES its session's cost until the memory reading can see it
  # (issue #1831), and the read + reserve is one step under a lock, so N
  # concurrent spawns cannot all read the same free memory and all pass.
  [ "${FLEET_ADMIT:-1}" = 0 ] && return 0
  local lk="$FLEET_C/global/admit.lock" i=0 rc
  mkdir -p "${lk%/*}" 2>/dev/null
  while ! mkdir "$lk" 2>/dev/null; do   # a holder dead > 10 s left it behind
    i=$((i + 1))
    [ "$i" -ge 50 ] && { rmdir "$lk" 2>/dev/null; mkdir "$lk" 2>/dev/null; break; }
    sleep 0.2 2>/dev/null || sleep 1
  done
  fleet_machine_admit; rc=$?
  [ "$rc" = 0 ] && fleet_admit_reserve "$sess"
  rmdir "$lk" 2>/dev/null
  return "$rc"
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
  local gmax="${FLEET_GLOBAL_MAX_SESSIONS:-0}" fmax="${FLEET_MAX_SESSIONS:-0}" n
  case "$gmax" in ''|*[!0-9]*) gmax=0;; esac
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
# GLOBAL session cap (FLEET_GLOBAL_MAX_SESSIONS, default 0 = off) silently blocks EVERY
# spawn path, but nothing surfaces fullness today — so a cap refusal is an ambush.
# This makes it expected: reuse fleet_session_count (the SAME cross-fleet count the
# cap measures — pure tmux+awk, no network) and render an ANSI-truecolor chip:
# dim with headroom, orange at the last free slot, red at/over the cap. Pass a
# precomputed count as $1 (and sleeper count as $2, default 0 then) to avoid a
# second scan (and for hermetic tests); sleepers render as `· zN` (#1058). With the
# cap disabled (gmax=0 ⇒ unlimited) it shows a bare "slots N" (no denominator/color).
fleet_slots_chip() {
  local n="${1:-}" z="${2:-}" gmax="${FLEET_GLOBAL_MAX_SESSIONS:-0}" col reset t zs=''
  reset=$(printf '\033[0m')                          # POSIX ESC[0m — $'…' is a bashism dash ignores
  case "$gmax" in ''|*[!0-9]*) gmax=0;; esac
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

# The same fold, over ONE listing of the base branch's newest runs, grouped by
# head_sha → `<sha>\t<state>` lines (claude-fleet#1211). Measured 2026-09-25: the
# per-sha read below, once per candidate per FLEET_DEPLOY_TTL, was 32 of the 41 REST
# calls in a 45 s sample — 18 monorepo candidates × two logins on one token ≈ the
# whole 5000/h core bucket. A sha absent from the listing (older than its 100-run
# window) is simply not printed; the caller falls back to the per-sha read for it.
# shellcheck disable=SC2016  # jq vars, not shell
FLEET_DEPLOY_BATCH_JQ='[.workflow_runs[]? | {sha: .head_sha, tok: (if .status=="completed" then (.conclusion // "unknown") else .status end)}]
  | group_by(.sha)[] | .[0].sha as $sha | [.[].tok] as $s
  | $sha + "\t" + (
      if   ($s|any(.=="failure" or .=="cancelled" or .=="timed_out" or .=="action_required"
                   or .=="startup_failure" or .=="stale"))                              then "failed"
      elif ($s|any(.!="success" and .!="skipped" and .!="neutral"))                      then "deploying"
      else "live" end)'

# fleet_deploy_probe_batch <repo> <branch> — one read of the newest 100 runs whose
# head_branch is <branch> (push runs + the workflow_dispatch deploys a conductor fans
# out on the same sha), folded per sha as above. rc 1 with no output when the read
# itself failed — the caller keeps its cache and may fall back per sha.
fleet_deploy_probe_batch() {
  local repo="${1:-}" branch="${2:-}" out
  [ -n "$repo" ] && [ -n "$branch" ] || return 1
  out=$(gh api "repos/$repo/actions/runs?branch=$branch&per_page=100" --jq "$FLEET_DEPLOY_BATCH_JQ" 2>/dev/null) || return 1
  printf '%s' "$out"
  return 0
}

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
  # A ZOMBIE is skipped (issue #1734): on Linux a process that just exited keeps
  # its comm (`claude`) until its parent reaps it, so a /exit'ed Claude read as
  # "another Claude appeared" for the few ms before tmux collected it (macOS shows
  # `<defunct>`, so it never hit there). fleet_pid_alive already treats Z as gone.
  { ps -axo pid=,ppid=,stat=,comm=; echo '---CMDS---'; ps -axo pid=,command=; } 2>/dev/null \
  | awk -v panes="$*" -v ccomm="${FLEET_CLAUDE_COMM:-}" '
      /^---CMDS---$/ { sec = 2; next }
      sec != 2 { if (NF >= 4 && index($3, "Z") == 0) { comm[$1] = $4; kids[$2] = kids[$2] " " $1 } next }
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
  local sess="${1:-}" win="${2:-}" br="${3:-}" raw wt iss repo n
  [ -n "$win" ] || return 1
  [ -n "$sess" ] || sess=$(fleet_current_session)
  [ -n "$sess" ] || return 1
  fleet_window_bg_busy "$sess" "$win" && { printf 'bg\n'; return 0; }
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

# --- is a session's configuration current? (issue #1783, EPIC #1776 C7) ----------
# A session's launcher stamps @agent_cfg — the fingerprint of the configuration it
# was started with (fleet-claude.sh / fleet-codex.sh, #1782); fleet-agent-team.py
# `expected --write` caches the one a fresh session would get NOW, per agent, in
# $FLEET_CONF_DIR/global/agent-cfg.expected (`<agent> <fp> <src>` lines; rewritten
# by every install-apply and every team apply). The two differ ⇒ the session runs
# an old configuration: the sidebar marks it 配置旧, the doctor counts it, and
# fleet-cfg-restart.sh reopens it once it has been idle long enough.
# fleet_cfg_expected_load — read that file ONCE into FCFG_EXP_CLAUDE /
# FCFG_EXP_CODEX (no fork: the rows producer runs it per frame).
fleet_cfg_expected_load() {
  FCFG_EXP_CLAUDE=''; FCFG_EXP_CODEX=''
  local f="${FLEET_CONF_DIR:-$HOME/.config/claude-fleet}/global/agent-cfg.expected" ag fp _rest
  [ -f "$f" ] || return 0
  while read -r ag fp _rest; do
    case "$ag" in claude) FCFG_EXP_CLAUDE=$fp ;; codex) FCFG_EXP_CODEX=$fp ;; esac
  done < "$f"
  return 0
}
# fleet_cfg_state <agent> <fp> → FCFG_STATE = stale | ok | unknown (no fork,
# nothing printed). <agent> is @cc_agent (`codex`, `codex:…` as the rows format
# spells it, else Claude); <fp> the window's @agent_cfg. No fingerprint on the
# window (a session from before #1782, FLEET_AGENT_CFG=0, a plain shell) or none
# expected ⇒ unknown — never stale: a window we cannot judge is never reopened.
fleet_cfg_state() {
  local exp
  case "${1:-}" in codex|codex:*) exp=${FCFG_EXP_CODEX:-} ;; *) exp=${FCFG_EXP_CLAUDE:-} ;; esac
  if [ -z "${2:-}" ] || [ -z "$exp" ]; then FCFG_STATE=unknown
  elif [ "$2" = "$exp" ]; then FCFG_STATE=ok
  else FCFG_STATE=stale; fi
}
# fleet_cfg_restart_why <session> <win> [idle-secs] — may <win> be reopened onto
# the current configuration NOW (issue #1783)? Exit 0 = yes. Else exit 1 and ONE
# word on stdout says why not: gone · panel · remote · codex · unknown · ok ·
# state:<s> · recent · asleep · looping · bg. The ONE judge — fleet-cfg-restart.sh
# picks with it and fleet-migrate.sh --cfg-stale asks it again right before /exit,
# so a session that started a turn in between is never interrupted. Only a Claude
# session whose @agent_cfg differs from the expected one, `done` for <idle-secs>
# (FLEET_CFG_RESTART_IDLE, 600), with no /loop round held and no Bash-tool job
# still running. needs/blocked never qualify: a pending question is the
# operator's, and a reopen would drop it.
fleet_cfg_restart_why() {
  local sess="${1:-}" win="${2:-}" idle="${3:-${FLEET_CFG_RESTART_IDLE:-600}}" o ag fp st ts lp slp rem hub nm bin
  case "$idle" in ''|*[!0-9]*) idle=600 ;; esac
  o=$(_fleet_tmux "$sess" display-message -p -t "$win" \
        '#{@cc_agent}|#{@agent_cfg}|#{@claude_state}|#{@claude_state_ts}|#{@loop}|#{@sleep_since}|#{@remote}|#{@hub}|#{window_name}' 2>/dev/null) \
    && [ -n "$o" ] || { echo gone; return 1; }
  # parameter expansion, not a here-string: this lib is sourced by plain sh too
  ag=${o%%|*}; o=${o#*|}; fp=${o%%|*}; o=${o#*|}; st=${o%%|*}; o=${o#*|}
  ts=${o%%|*}; o=${o#*|}; lp=${o%%|*}; o=${o#*|}; slp=${o%%|*}; o=${o#*|}
  rem=${o%%|*}; o=${o#*|}; hub=${o%%|*}; nm=${o#*|}
  case "$nm" in dash|plan|backlog|home) echo panel; return 1 ;; esac
  [ -z "$rem" ] && [ "$hub" != 1 ] || { echo remote; return 1; }
  [ "$ag" != codex ] || { echo codex; return 1; }
  fleet_cfg_expected_load; fleet_cfg_state "$ag" "$fp"
  [ "$FCFG_STATE" = stale ] || { echo "$FCFG_STATE"; return 1; }
  [ -z "$slp" ] || { echo asleep; return 1; }
  [ "$st" = "done" ] || { echo "state:${st:-none}"; return 1; }
  case "$ts" in ''|*[!0-9]*) ts=0 ;; esac
  [ $(( $(date +%s) - ts )) -ge "$idle" ] || { echo recent; return 1; }
  bin="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)"
  if [ -n "$lp" ] && [ -f "$bin/fleet_loop_mark.py" ] \
     && python3 "$bin/fleet_loop_mark.py" status --value "$lp" >/dev/null 2>&1; then
    echo looping; return 1
  fi
  fleet_window_bg_busy "$sess" "$win" 1 && { echo bg; return 1; }
  return 0
}

# fleet_window_bg_busy <session> <win> [quick] — does <win>'s agent still own a
# Bash-tool job (a run_in_background test, a PR-gate waiter) after its turn ended?
# fleet_child_busy's `bg` half (issue #864), shared with the Stop hook's and the
# reapers' "still waiting" answer (issue #1370). Exit 0 = busy. [quick]=1 first asks
# the cheap necessary condition — a Claude agent counts ONLY a Bash-tool shell
# (`…/shell-snapshots/snapshot-…` in its argv) among its direct children, exactly
# fleet-sleep.py's non-strict walk — so a pane with none never pays the python walk.
fleet_window_bg_busy() {
  local sess="${1:-}" win="${2:-}" quick="${3:-}" bin sock='' agent pid=''
  [ -n "$win" ] || return 1
  [ -n "$sess" ] || sess=$(fleet_current_session)
  [ -n "$sess" ] || return 1
  [ -n "${TMUX:-}" ] || sock=$(fleet_socket "$sess")
  bin="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)"
  [ -f "$bin/fleet-sleep.py" ] && command -v python3 >/dev/null 2>&1 || return 1
  agent=$(_fleet_tmux "$sess" display-message -p -t "$win" '#{@cc_agent}' 2>/dev/null)
  [ "$agent" = codex ] || pid=$(fleet_pane_claude_pid "$win" "$sock" 2>/dev/null) || pid=''
  [ "$agent" = codex ] || [ -n "$pid" ] || return 1
  if [ "$quick" = 1 ] && [ -n "$pid" ]; then
    ps -axo ppid=,command= 2>/dev/null \
      | awk -v p="$pid" '$1 == p && index($0, "/shell-snapshots/snapshot-") { f = 1 } END { exit !f }' \
      || return 1
  fi
  python3 "$bin/fleet-sleep.py" busy --session "$sess" ${pid:+--pid "$pid"} "$win" \
    >/dev/null 2>&1 </dev/null
}

# fleet_window_okey <session> <win> → <win>'s own ledger key — `issue-<N>` /
# `scratch-<N>` (`<slug>:`-qualified in a 2+ repo fleet) — the key its children's
# @origin carries; nothing when it has none. fleet_origin_key's rule, for any
# window rather than only the caller's pane.
fleet_window_okey() {
  local sess="${1:-}" t="${2:-}" o iss owt pth k pre
  [ -n "$t" ] || return 0
  o=$(_fleet_tmux "$sess" display-message -p -t "$t" \
        '#{@issue}|#{@worktree}|#{pane_current_path}' 2>/dev/null)
  [ -n "$o" ] || return 0
  iss=${o%%|*}; o=${o#*|}; owt=${o%%|*}; pth=${o#*|}
  pre=$(_fleet_key_prefix "$sess" "$t") || return 0
  case "$iss" in
    ''|*[!0-9]*) : ;;
    *) printf '%sissue-%s' "$pre" "$iss"; return 0 ;;
  esac
  k=$(fleet_scratch_key "$owt")
  [ -z "$k" ] && k=$(fleet_scratch_key "$pth")
  [ -n "$k" ] && printf '%s%s' "$pre" "$k"
  return 0
}

# fleet_window_waiting_children <session> <win> — is <win> waiting on a sub-task it
# spawned (issue #1370)? Prints `k/N` (finished/total of its live subtree) and exits
# 0 while k < N; prints nothing and exits 1 otherwise. The SAME count the dash's
# k/N badge draws (tmux-dashboard-rows.sh pass A2): every live window whose @origin
# chain climbs to <win>'s key, at any depth; finished = `done` with no live @loop.
# A child whose PR merged or whose issue closed is reaped by cleanup and leaves the
# count — it is "done" by leaving, as on the dash. One list-windows when <win> has
# no live direct child — the common case on every Stop.
fleet_window_waiting_children() {
  local sess="${1:-}" t="${2:-}" key all line ws wid st loop iss wt repo norepo origin pth name
  local tab='' pre slug k tot=0 dn=0 bin direct=0
  [ -n "$t" ] || return 1
  [ -n "$sess" ] || sess=$(fleet_current_session)
  key=$(fleet_window_okey "$sess" "$t"); [ -n "$key" ] || return 1
  all=$(fleet_lw '#{session_name}|#{window_id}|#{?@worker_lifecycle,#{@worker_lifecycle},#{@claude_state}}|#{@loop}|#{@issue}|#{@worktree}|#{@repo}|#{@norepo}|#{@origin}|#{pane_current_path}|#{window_name}' _fleet_tmux "$sess")
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    ws=${line%%|*}; [ -n "$sess" ] && [ "$ws" != "$sess" ] && continue
    line=${line#*|}; wid=${line%%|*}; line=${line#*|}; st=${line%%|*}; line=${line#*|}
    loop=${line%%|*}; line=${line#*|}; iss=${line%%|*}; line=${line#*|}
    wt=${line%%|*}; line=${line#*|}; repo=${line%%|*}; line=${line#*|}
    norepo=${line%%|*}; line=${line#*|}; origin=${line%%|*}
    [ "$origin" = "$key" ] && [ "$wid" != "$t" ] && { direct=1; break; }
  done <<EOF
$all
EOF
  # Children on another machine (issue #1421) count too: the hub map's, not lost,
  # finished once their last report here says MERGED. Off without CCQUOTA_FLEET=1.
  local rem='' rdn=0 rtot=0
  rem=$(_fleet_remote_tally "$sess" "$key") && { rdn=${rem%% *}; rtot=${rem##* }; }
  if [ "$direct" != 1 ]; then
    [ "$rtot" -gt "$rdn" ] 2>/dev/null || return 1
    printf '%s/%s\n' "$rdn" "$rtot"; return 0
  fi
  bin="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)"
  # every window that could be in the subtree (a key-shaped @origin) → key/origin/finished
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    ws=${line%%|*}; [ -n "$sess" ] && [ "$ws" != "$sess" ] && continue
    line=${line#*|}; wid=${line%%|*}; line=${line#*|}; st=${line%%|*}; line=${line#*|}
    loop=${line%%|*}; line=${line#*|}; iss=${line%%|*}; line=${line#*|}
    wt=${line%%|*}; line=${line#*|}; repo=${line%%|*}; line=${line#*|}
    norepo=${line%%|*}; line=${line#*|}; origin=${line%%|*}; line=${line#*|}
    pth=${line%%|*}; name=${line#*|}
    [ "$wid" = "$t" ] && continue
    case "$name" in dash|plan|backlog|home) continue ;; esac
    case "$origin" in issue-*|scratch-*|*:issue-*|*:scratch-*) ;; *) continue ;; esac
    pre=''
    if _fleet_hosts_many "$sess"; then
      [ -n "$repo" ] || repo=$(fleet_window_repo "$sess" "$wid")
      slug=''; [ "$norepo" != 1 ] && [ -n "$repo" ] && slug=$(fleet_slug "$repo")
      pre="${slug:-?}:"
    fi
    case "$iss" in
      ''|*[!0-9]*) k=$(fleet_scratch_key "$wt"); [ -n "$k" ] || k=$(fleet_scratch_key "$pth")
                   [ -n "$k" ] && k="$pre$k" ;;
      *) k="${pre}issue-$iss" ;;
    esac
    [ -n "$k" ] || continue
    if [ "$st" = 'done' ] && ! { [ -n "$loop" ] \
         && python3 "$bin/fleet_loop_mark.py" status --value "$loop" >/dev/null 2>&1; }; then
      st=1
    else st=0; fi
    tab="$tab$k	$origin	$st
"
  done <<EOF
$all
EOF
  # chain_v's walk (CHAIN_MAX 16): a row counts toward <win> when its @origin chain,
  # climbed through live keyed windows (first match wins), reaches <win>'s key.
  # One awk over the whole table, however deep or wide the subtree.
  line=$(printf '%s' "$tab" | awk -F '\t' -v key="$key" '
    NF >= 3 { n++; r[n] = $2; f[n] = $3; if (!($1 in o)) o[$1] = $2 }
    END {
      for (i = 1; i <= n; i++) {
        c = r[i]
        for (h = 0; h < 16; h++) {
          if (c == key) { t++; if (f[i] == 1) d++; break }
          if (!(c in o)) break
          c = o[c]
        }
      }
      print d + 0, t + 0
    }')
  dn=${line%% *}; tot=${line##* }
  case "$dn$tot" in ''|*[!0-9]*) return 1 ;; esac
  dn=$((dn + rdn)); tot=$((tot + rtot))
  [ "$tot" -gt "$dn" ] || return 1
  printf '%s/%s\n' "$dn" "$tot"
}

# _fleet_remote_tally <sess> <parent-key> → `<finished> <total>` of the parent's
# children on OTHER machines (issue #1421): every row of the hub map naming this
# parent's worker_id, minus those on a lost node (EPIC #1419 rule 5: a lost machine
# is marked, never waited on), finished = its last report in this parent's ledger
# is MERGED (or REAPED as merged). rc 1 (nothing) when there are none — or the hub
# is off, or its map is stale: then the parent is the one-machine parent it was.
_fleet_remote_tally() {
  local rows f
  rows=$(fleet_remote_children "${1:-}" "${2:-}") || return 1
  f=$(printf '%s/children/%s.ndjson' "$(fleet_state_dir "${1:-}")" "$(printf '%s' "${2:-}" | LC_ALL=C tr -cd 'A-Za-z0-9._:-')")
  printf '%s\n' "$rows" | python3 -c '
import json, sys
last = {}
try:
    for l in open(sys.argv[1], encoding="utf-8"):
        try:
            e = json.loads(l)
        except ValueError:
            continue
        if isinstance(e, dict) and e.get("child") and e.get("type") != "wake":
            last[e["child"]] = e
except OSError:
    pass
dn = tot = 0
for line in sys.stdin:
    p = line.rstrip("\n").split("\t")
    if len(p) < 2 or not p[0] or p[1].endswith(":lost"):
        continue
    tot += 1
    e = last.get(p[0])
    if e is None:   # one key, two spellings: bare `issue-N` / `<slug>:issue-N` (#1351)
        alt = [k for k in last if k.endswith(":" + p[0])] if ":" not in p[0] else [p[0].split(":", 1)[1]]
        e = last.get(alt[0]) if len(alt) == 1 else None
    e = e or {}
    if e.get("state") == "MERGED" or (e.get("state") == "REAPED" and str(e.get("verdict") or "").startswith("merged")):
        dn += 1
print(dn, tot)
sys.exit(0 if tot else 1)' "$f" 2>/dev/null
}

# fleet_window_wait <session> <win> — WHY an idle <win> is not finished (issue
# #1370). Prints the reasons it holds, comma-separated, in a fixed order, and
# exits 0 when there is at least one; prints nothing and exits 1 otherwise:
#   loop      a Loop is pending (fleet_window_loop: @loop / a fleet-loop ledger)
#   children  a sub-task it spawned is not finished (fleet_window_waiting_children)
#   bg        its agent still owns a Bash-tool job (fleet_window_bg_busy, quick)
# The Stop hook writes `looping` + @claude_wait from this; fleet-reap-live.py
# retains on it. A window with none of the three pays one list-windows, one tmux
# read and one ps.
fleet_window_wait() {
  local sess="${1:-}" t="${2:-}" out=''
  [ -n "$t" ] || return 1
  [ -n "$sess" ] || sess=$(fleet_current_session)
  fleet_window_loop "$sess" "$t" >/dev/null 2>&1 && out=loop
  fleet_window_waiting_children "$sess" "$t" >/dev/null 2>&1 && out="${out:+$out,}children"
  fleet_window_bg_busy "$sess" "$t" 1 && out="${out:+$out,}bg"
  [ -n "$out" ] || return 1
  printf '%s\n' "$out"
}

# fleet_stop_wait <win> [transcript] — the Stop hook's one question (issue #1370):
# fleet_window_wait's reasons, after first backfilling a missing @loop from the
# tail of this session's own transcript (fleet_loop_mark.py backfill) — a session
# whose wakeup was scheduled before the PostToolUse hook was installed. Only when
# the window has no @loop, no live mod heartbeat (the mod writes @loop itself) and
# the transcript's last FLEET_LOOP_BACKFILL_BYTES even mention a Loop tool; bounded
# by a 5s timebox, so a Stop is never held up by it.
fleet_stop_wait() {
  local t="${1:-}" tp="${2:-}" bin n="${FLEET_LOOP_BACKFILL_BYTES:-262144}"
  [ -n "$t" ] || return 1
  case "$n" in ''|*[!0-9]*) n=262144 ;; esac
  bin="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)"
  if [ -n "$tp" ] && [ -f "$tp" ] \
     && [ -z "$(tmux display-message -p -t "$t" '#{@loop}' 2>/dev/null)" ] \
     && ! fleet_mod_alive "$t" \
     && tail -c "$n" "$tp" 2>/dev/null | grep -qE '"(ScheduleWakeup|CronCreate)"'; then
    fleet_timebox 5 python3 "$bin/fleet_loop_mark.py" backfill "$t" --transcript "$tp" \
      --max-bytes "$n" >/dev/null 2>&1 </dev/null
  fi
  fleet_window_wait '' "$t"
}

# fleet_window_reeval <session> <win> [dry] — ask an IDLE window the Stop hook's
# question again, now (issue #1376). The Stop hook decides `looping` + @claude_wait
# once, at the edge; a child that finishes, a background job that ends, or a window
# that stopped before #1370 was synced stays as that edge left it until its next
# Stop. This re-asks fleet_window_wait and rewrites ONLY the two things the Stop
# decision owns: `done` ↔ `looping` and @claude_wait. It never touches
# working/needs, a sleep transition (@worker_lifecycle), or a `looping` with no
# @claude_wait (the classifier's screen read of a loop — not a reason it can
# re-ask); it never backfills @loop (fleet_loop_mark.py sweep does) and leaves
# @claude_state_ts alone — nothing ran in the pane. The write re-checks the state
# server-side, so a prompt that lands between the read and the write wins.
# Prints `<old>[ (<wait>)] -> <new>[ (<wait>)]` and exits 0 when it changed (or,
# with dry=1, would change); exits 1 otherwise.
fleet_window_reeval() {
  local sess="${1:-}" t="${2:-}" dry="${3:-}" raw st cw lc sp nw ns cmd
  [ -n "$t" ] || return 1
  [ -n "$sess" ] || sess=$(fleet_current_session)
  raw=$(_fleet_tmux "$sess" display-message -p -t "$t" \
          '#{@claude_state}|#{@worker_lifecycle}|#{@claude_wait}|#{socket_path}' 2>/dev/null) || return 1
  st=${raw%%|*}; raw=${raw#*|}; lc=${raw%%|*}; raw=${raw#*|}; cw=${raw%%|*}; sp=${raw#*|}
  [ -z "$lc" ] || return 1
  case "$st" in
    'done') ;;
    looping) [ -n "$cw" ] || return 1 ;;
    *) return 1 ;;
  esac
  nw=$(fleet_window_wait "$sess" "$t" 2>/dev/null) || nw=''
  if [ -n "$nw" ]; then ns=looping; else ns='done'; fi
  [ "$ns" = "$st" ] && [ "$nw" = "$cw" ] && return 1
  printf '%s%s -> %s%s\n' "$st" "${cw:+ ($cw)}" "$ns" "${nw:+ ($nw)}"
  [ "$dry" = 1 ] && return 0
  if [ -n "$nw" ]; then cmd="set-option -w -t $t @claude_wait $nw"
  else cmd="set-option -wu -t $t @claude_wait"; fi
  _fleet_tmux "$sess" if-shell -F -t "$t" "#{==:#{@claude_state},$st}" \
    "set-option -w -t $t @claude_state $ns ; $cmd" 2>/dev/null || return 1
  [ "$(_fleet_tmux "$sess" display-message -p -t "$t" '#{@claude_state}' 2>/dev/null)" = "$ns" ] || return 1
  # Wake the spinner (issue #887), the same marker the Stop hook touches.
  [ -n "$sp" ] && : > "$sp.dirty" 2>/dev/null
  fleet_hub_nudge   # …and the hub (issue #1481)
  return 0
}

# fleet_pr_merge_state <repo> <pr> — what GitHub says a PR's merge state IS, for a
# child about to report MERGED (issue #1247). Prints one token:
#   merged   .merged is true — the only token that makes a MERGED report true
#   armed    open, auto-merge armed — checks still running, NOT landed yet
#   open     open, nothing armed
#   closed   closed without merging
#   unknown  gh missing / failed / timed out — undetermined, never "merged"
# REST (the core budget), not GraphQL: a GraphQL-exhausted account still answers.
fleet_pr_merge_state() {
  local repo="${1:-}" n="${2//[^0-9]/}" raw
  case "$repo" in ?*/?*) ;; *) printf 'unknown\n'; return 0 ;; esac
  [ -n "$n" ] && command -v gh >/dev/null 2>&1 || { printf 'unknown\n'; return 0; }
  raw=$(fleet_timebox 10 gh api "repos/$repo/pulls/$n" \
          --jq '"\(.merged) \(.state) \(.auto_merge != null)"' 2>/dev/null)
  case "$raw" in
    'true '*)          printf 'merged\n' ;;
    'false open true') printf 'armed\n' ;;
    'false open '*)    printf 'open\n' ;;
    'false closed '*)  printf 'closed\n' ;;
    *)                 printf 'unknown\n' ;;
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
  local pid="$1" tok="" env_words="" hubdir=""
  if [ -n "${FLEET_TOKEN_PROBE:-}" ]; then
    tok=$("$FLEET_TOKEN_PROBE" "$pid" 2>/dev/null | head -n1)
  elif [ -r "/proc/$pid/environ" ]; then
    tok=$(tr '\0' '\n' < "/proc/$pid/environ" | sed -n 's/^CLAUDE_CODE_OAUTH_TOKEN=//p' | head -n1)
  else
    env_words=$(ps -E -ww -o command= -p "$pid" 2>/dev/null | tr ' ' '\n')
    tok=$(printf '%s\n' "$env_words" | sed -n 's/^CLAUDE_CODE_OAUTH_TOKEN=//p' | head -n1)
  fi
  # A hub-managed account (#1415) carries no token in its environment, only the
  # directory of its short-lived one: <accounts>/<label>.hub. Its pool file holds
  # `hub:<label>`, so that string is the "token" the shas are compared on.
  if [ -z "$tok" ] && [ -z "${FLEET_TOKEN_PROBE:-}" ]; then
    if [ -r "/proc/$pid/environ" ]; then
      env_words=$(tr '\0' '\n' < "/proc/$pid/environ")
    fi
    hubdir=$(printf '%s\n' "${env_words:-}" | sed -n 's/^CLAUDE_SECURESTORAGE_CONFIG_DIR=//p' | head -n1)
    case "$hubdir" in */*.hub) hubdir=${hubdir##*/}; tok="hub:${hubdir%.hub}" ;; esac
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
  if [ -n "${1:-}" ]; then fleet_lw '#{@wid}' tmux -L "$1"
  else                     fleet_lw '#{@wid}'; fi
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
  [ -n "$s" ] || s=$(tmux display-message -p "$FLEET_SESSION_FMT" 2>/dev/null)
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
$(if [ -n "$sock" ]; then fleet_lw '#{window_id} #{@wid}' tmux -L "$sock"
  else                    fleet_lw '#{window_id} #{@wid}'; fi)
EOF
  return 1
}

# fleet_wid_target <target> [socket] — the window-target normaliser every
# target-taking script runs its argument through. A handle resolves to its
# `window_id`; ANYTHING else (an `@id`, an index, `sess:idx`, a window name) is
# passed back untouched, so every form that works today keeps working. Handles
# win the tie by design — a window merely NAMED `a1` is addressable by index.
# A well-formed handle NO live window carries is refused (nothing printed, rc 1,
# one stderr line; issue #1537 ⑤): passed through, tmux would read `a1` as a
# window NAME — prefix-matched — and the reap / migrate / rename would land on a
# stranger. Callers must check the rc: an empty target is `-t ""`, the current
# window.
fleet_wid_target() {
  local t="${1:-}" sock="${2:-}" w
  if fleet_wid_valid "$t"; then
    w=$(fleet_wid_resolve "$t" "$sock") && [ -n "$w" ] && { printf '%s' "$w"; return 0; }
    printf 'fleet: no live window carries handle %s\n' "$t" >&2
    return 1
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

# ------------------------------------------------------------ heavy queue (#1295)
# Defaults for bin/fleet-heavy.sh (the machine-wide heavy-job semaphore) and the
# hooks/bash-guard.py rail that prefixes it onto matching Bash statements. The hook
# is python and cannot source this file, so it carries the same regex literal;
# fleet-heavy-selftest.sh holds the two in lockstep. The regex is a PYTHON `re`,
# matched at a statement's command position (after VAR=val / `time` / `nohup` /
# `timeout N` prefixes). FLEET_HEAVY_RE in the global settings replaces it.
# shellcheck disable=SC2034  # read by bin/fleet-heavy.sh + its selftest
FLEET_HEAVY_SLOTS_DEFAULT=3
# shellcheck disable=SC2034
FLEET_HEAVY_WAIT_DEFAULT=1800
# shellcheck disable=SC2034
FLEET_HEAVY_RE_DEFAULT='git\b(?:\s+(?:-[Cc]\s+\S+|-\S+))*\s+push\b|(?:python3?\s+-m\s+)?pytest\b|npm\s+(?:run\s+)?test\b|(?:(?:ba|z)?sh\s+)?(?:\S*/)?(?:run-selftests|local-prod-gate|pre-pr)\.sh\b'
# Matched BEFORE the heavy regex (issue #1313): a hit is a LIGHT test run — one
# file, one node (::), a -k / -t name filter, run-selftests.sh <name> — and is
# never queued. Still heavy: bare pytest, any xdist fan-out (-n/--dist/-p xdist),
# a glob or option to run-selftests.sh. FLEET_HEAVY_LIGHT_RE replaces it; `(?!)`
# turns the light list off. Mirrored in hooks/bash-guard.py (lockstep selftest).
# shellcheck disable=SC2034
FLEET_HEAVY_LIGHT_RE_DEFAULT='(?:python3?\s+-m\s+)?pytest\b(?!.*\s(?:-n|--numprocesses|--dist)(?![A-Za-z-])|.*\s-p\s*xdist\b)(?=.*\s(?:-k|\S*::|\S+\.py(?:\s|$)))|npm\s+(?:run\s+)?test\b(?=.*\s--\s(?:.*\s)?(?:-t\b|--testNamePattern\b|\S+\.[cm]?[jt]sx?(?:\s|$)))|(?:(?:ba|z)?sh\s+)?(?:\S*/)?run-selftests\.sh(?:\s+[A-Za-z][^\s*?\[<>&]*)+(?=\s*(?:\d*[<>&]|$))'

# fleet_heavy_dir — the MACHINE-level slot dir shared by every login (EPIC #1291
# convention 6): never under a $HOME. FLEET_HEAVY_DIR overrides (selftest seam).
fleet_heavy_dir() {
  if [ -n "${FLEET_HEAVY_DIR:-}" ]; then printf '%s\n' "$FLEET_HEAVY_DIR"
  elif [ "$(uname -s 2>/dev/null)" = Darwin ]; then printf '/Users/Shared/claude-fleet/heavy\n'
  else printf '/var/tmp/claude-fleet/heavy\n'
  fi
}

# ------------------------------------------------- context lines in tokens (#1317)
# The compact-prep / auto-handoff lines may be set as TOKENS USED instead of a %
# (FLEET_COMPACT_PREP_TOKENS / FLEET_AUTO_HANDOFF_TOKENS; 0/unset = use the *_PCT
# key). Every window is 1M tokens today, so "70%" meant 700k — long after quality
# had started to slide, and nobody saw it. A token line survives a model whose
# window is a different size: it is converted per Stop against the pane's
# @ctx_limit (the window SIZE conf/statusline.sh stamps), and a pane with no
# @ctx_limit falls back to the *_PCT key.
#
# fleet_ctx_line <tokens> <limit> — the % line <tokens> is in a <limit> window:
# rounded UP (a token line never fires before that many tokens are used) and
# clamped to 100 (a line at/over the window can never be crossed — fleet-doctor
# WARNs on it). Prints nothing and returns 1 on a non-positive / non-numeric input,
# so a caller keeps its *_PCT value. bin/set-claude-state.sh is `sh`-wired and
# cannot source this file: it carries the same arithmetic inline, and
# ctx-token-line-selftest.sh holds the two in lockstep.
# shellcheck disable=SC2034  # read by bin/fleet-doctor.sh
FLEET_CLAUDE_AUTOCOMPACT_PCT_DEFAULT=95   # Claude Code's own near-limit compaction (approx.; CLAUDE_AUTOCOMPACT_PCT_OVERRIDE wins)
fleet_ctx_line() {
  local t="${1:-}" l="${2:-}" p
  case "$t" in ''|*[!0-9]*) return 1 ;; esac
  case "$l" in ''|*[!0-9]*) return 1 ;; esac
  [ "$t" -gt 0 ] && [ "$l" -gt 0 ] || return 1
  p=$(( (t * 100 + l - 1) / l ))
  [ "$p" -gt 100 ] && p=100
  printf '%s\n' "$p"
}

# --- where a compact-in-place recovery map lives (issue #1318) -------------------
# fleet_recovery_map_path [<pane>] [<cwd>] — the file the compact-prep Stop
# (bin/set-claude-state.sh) asks a session to write its recovery map to, and the one
# bin/refocus-hook.sh reads back after the /compact. A worker's or scratch's
# worktree ⇒ `<git-dir>/fleet-recovery-map.md` (per worktree, never committed — the
# #1269 rule, unchanged); a scratch with no git dir (opened in $HOME, a 2+ repo hub
# dir) ⇒ `$FLEET_CONF_DIR/fleets/<sess>/recovery/w<window-id>.md` — one file per
# window, keyed by tmux's window id (stable for the window's life; a reused id after
# a server restart just overwrites a stale map, which every prep does anyway). The
# directory is NOT created here: the prep step does that. Prints nothing and returns
# 1 when neither resolves (no git dir, no fleet session or window).
fleet_recovery_map_path() {
  local pane="${1:-${TMUX_PANE:-}}" cwd="${2:-}" gd sess wid
  [ -n "$cwd" ] || cwd=$(pwd -P 2>/dev/null)
  gd=$(git -C "$cwd" rev-parse --absolute-git-dir 2>/dev/null)
  if [ -n "$gd" ]; then printf '%s/fleet-recovery-map.md\n' "$gd"; return 0; fi
  [ -n "$pane" ] || return 1
  sess=$(tmux display-message -p -t "$pane" "$FLEET_SESSION_FMT" 2>/dev/null)
  wid=$(tmux display-message -p -t "$pane" '#{window_id}' 2>/dev/null | tr -cd '0-9')
  [ -n "$sess" ] && [ -n "$wid" ] || return 1
  printf '%s/fleets/%s/recovery/w%s.md\n' "$FLEET_CONF_DIR" "$sess" "$wid"
}
