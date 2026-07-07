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

FLEET_C="${TMPDIR:-/tmp}/.claude-dash"

# git remote URL (or owner/name) → owner/name. Empty if it isn't GitHub-ish.
fleet_norm_repo() {
  printf '%s' "$1" | sed -E 's#^git@[^:]*:##; s#^https?://[^/]*/##; s#\.git$##; s#/+$##'
}

# owner/name → filesystem-safe slug (owner-name).
fleet_slug() {
  printf '%s' "$1" | tr '/' '-' | tr -cd '[:alnum:]._-'
}

# EXPENSIVE: resolve a tmux session's repo. Order: per-session conf override
# (~/.config/claude-fleet/<sess>.conf, Phase 2), else the origin remote of the
# first git checkout among its windows, else the global FLEET_REPO. Prints
# owner/name or empty. Collector-only (runs once per cycle).
fleet_resolve_repo_for_session() {
  local sess="$1" conf repo path
  conf="$HOME/.config/claude-fleet/${sess}.conf"
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

# Pick the cache file for <base> (prmap|issues) for a session: the slug'd file if
# the session resolved and the file is non-empty, else the flat fallback.
fleet_cache() {
  local base="$1" slug
  slug=$(fleet_slug_cached "$2")
  if [ -n "$slug" ] && [ -s "$FLEET_C/${base}_${slug}" ]; then
    printf '%s' "$FLEET_C/${base}_${slug}"
  else
    printf '%s' "$FLEET_C/${base}"
  fi
}
