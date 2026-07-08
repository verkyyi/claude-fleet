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
# Per-fleet configs live here, one <session>.conf per fleet (Phase 2). Override
# FLEET_CONF_DIR to relocate (used by the test harness).
FLEET_CONF_DIR="${FLEET_CONF_DIR:-$HOME/.config/claude-fleet}"

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
fleet_load_conf() {
  local conf="$FLEET_CONF_DIR/${1}.conf"
  [ -f "$conf" ] && . "$conf"
  return 0
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
  case "$cwd" in
    */issue-[0-9]*)
      [ -n "$issue" ] && { printf 'worker'; return; } ;;
  esac
  if [ -z "$issue" ] && [ -n "${FLEET_MAIN:-}" ]; then
    main=$(cd "$FLEET_MAIN" 2>/dev/null && pwd -P)
    [ -n "$main" ] && [ "$cwd" = "$main" ] && { printf 'steward'; return; }
  fi
  return 0
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

# EXPENSIVE: resolve a tmux session's repo. Order: per-session conf override
# (~/.config/claude-fleet/<sess>.conf, Phase 2), else the origin remote of the
# first git checkout among its windows, else the global FLEET_REPO. Prints
# owner/name or empty. Collector-only (runs once per cycle).
fleet_resolve_repo_for_session() {
  local sess="$1" conf repo path
  conf="$FLEET_CONF_DIR/${sess}.conf"
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
  done < <(tmux list-windows -t "$sess" -F '#{pane_current_path}' 2>/dev/null | awk '!seen[$0]++')
  fleet_norm_repo "${FLEET_REPO:-}"
}

# CHEAP: session → slug from the collector's sessmap (single awk, no forks into
# git/tmux). Prints slug or empty.
fleet_slug_cached() {
  [ -f "$FLEET_C/sessmap" ] || return 0
  awk -F'\t' -v s="$1" '$1==s{print $2; exit}' "$FLEET_C/sessmap"
}

# CHEAP: session → repo (owner/name) from the sessmap. Prints repo or empty.
fleet_repo_cached() {
  [ -f "$FLEET_C/sessmap" ] || return 0
  awk -F'\t' -v s="$1" '$1==s{print $3; exit}' "$FLEET_C/sessmap"
}

# CHEAP: count the live Claude WORKING-session windows across every fleet on this
# tmux server (the system-wide count issue #28's cap measures). A fleet session
# is one that owns a hub window ('plan' or 'dash'); inside it, windows named
# dash/plan/backlog are panels — everything else is a Claude working session
# (the same rule the dashboard uses). Pure tmux + awk, no git/tmux-per-window
# forks. Prints an integer (0 if tmux isn't running or no fleets are up).
fleet_session_count() {
  tmux list-windows -a -F '#{session_name} #{window_name}' 2>/dev/null | awk '
    { rows[NR]=$0; if ($2=="plan" || $2=="dash") fleet[$1]=1 }
    END {
      for (i=1; i<=NR; i++) {
        split(rows[i], a, " "); s=a[1]; w=a[2]
        if (fleet[s] && w!="dash" && w!="plan" && w!="backlog") c++
      }
      print c+0
    }'
}

# Global cap on concurrent Claude working sessions (issue #28). Returns 0 if a
# new session may be spawned, non-zero if the cap is already reached. The limit
# is FLEET_GLOBAL_MAX_SESSIONS (default 8) — a SYSTEM-WIDE ceiling on concurrent
# Claude working sessions across all fleets; set it to 0 to
# disable the cap entirely. On refusal, prints a human-readable reason on stdout
# for the caller to surface (tmux display-message); prints nothing when allowed.
fleet_session_cap_ok() {
  local max="${FLEET_GLOBAL_MAX_SESSIONS:-8}" n
  case "$max" in ''|*[!0-9]*) max=8;; esac   # tolerate a garbled conf value
  [ "$max" -eq 0 ] && return 0               # 0 ⇒ unlimited
  n=$(fleet_session_count)
  if [ "$n" -ge "$max" ]; then
    printf 'fleet at capacity: %s/%s Claude sessions running — raise FLEET_GLOBAL_MAX_SESSIONS or close one first' "$n" "$max"
    return 1
  fi
  return 0
}

# Pick the cache file for <base> (prmap|issues) for a session: the slug'd file if
# the session resolved AND its fetch has COMPLETED (the .ts marker exists, even if
# the repo has 0 rows), else the flat fallback. Keying off .ts — not file size —
# so a fleet whose repo genuinely has 0 issues/PRs shows empty, not the primary's.
fleet_cache() {
  local base="$1" slug
  slug=$(fleet_slug_cached "$2")
  if [ -n "$slug" ] && [ -f "$FLEET_C/${base}_${slug}.ts" ]; then
    printf '%s' "$FLEET_C/${base}_${slug}"
  else
    printf '%s' "$FLEET_C/${base}"
  fi
}
