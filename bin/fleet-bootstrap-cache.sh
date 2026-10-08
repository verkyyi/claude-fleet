#!/bin/bash
# fleet-bootstrap-cache.sh — what a new login needs, kept on this machine
# (issue #2297, EPIC #2293 C6). Opening a login used to reach abroad twice — a
# `git clone` of claude-fleet from github.com and `curl https://claude.ai/install.sh`
# — and on a mainland network either one hangs the newcomer's first minute. The
# admin's side already HAS both: its own claude-fleet checkout and its own
# Claude Code. This script copies them into one machine-wide cache that every
# login can read, and installs a new login from it; no cache = today's road.
#
#   <cache>/claude-fleet.git      a bare mirror: refs/tags/stable (the commit the
#                                 admin's install runs) + refs/heads/master
#   <cache>/claude/<ver>/claude   the admin's Claude Code native binary
#   <cache>/claude/current        <ver>
#
# <cache> is FLEET_BOOTSTRAP_CACHE, default /Library/Application Support/
# claude-fleet/cache on macOS (/var/cache/claude-fleet elsewhere): written by
# root (fleet-login-new.sh --apply runs `sudo … refresh` right before it clones
# for the login), read by everyone.
#
# Usage:
#   fleet-bootstrap-cache.sh refresh --from <claude-fleet checkout> [--claude <bin>]
#       fill / update the cache (as root). The git half is a LOCAL fetch — no
#       network; --claude defaults to the `claude` on PATH. Either half missing
#       is a note, not a failure: the other half is still cached.
#   fleet-bootstrap-cache.sh clone <dest> [--branch <b>]
#       clone claude-fleet from the cache (default branch: the mirror's HEAD,
#       master), then point origin at FLEET_BOOTSTRAP_GIT_BASE's URL so every
#       later fetch goes where it always went. Exit 3: no mirror in the cache.
#   fleet-bootstrap-cache.sh claude
#       install the cached Claude Code for THIS login the way the native
#       installer lays it out: ~/.local/share/claude/versions/<ver>, symlinked
#       from ~/.local/bin/claude. Exit 3: no binary in the cache.
#   fleet-bootstrap-cache.sh dir          print <cache>
#
# Env: FLEET_BOOTSTRAP_CACHE (`off` = no cache: refresh does nothing, clone /
#      claude exit 3) · FLEET_BOOTSTRAP_GIT_BASE (https://github.com)
# Exit: 0 ok · 1 failed · 2 usage · 3 nothing cached for it
set -uo pipefail

PROG=fleet-bootstrap-cache
FLEET_REPO_SELF=verkyyi/claude-fleet
if [ -n "${FLEET_BOOTSTRAP_CACHE:-}" ]; then CACHE=$FLEET_BOOTSTRAP_CACHE
elif [ "$(uname -s)" = Darwin ]; then CACHE='/Library/Application Support/claude-fleet/cache'
else CACHE=/var/cache/claude-fleet
fi
MIRROR="$CACHE/claude-fleet.git"
UPSTREAM="${FLEET_BOOTSTRAP_GIT_BASE:-https://github.com}/$FLEET_REPO_SELF.git"

say() { printf '%s: %s\n' "$PROG" "$*"; }
die() { printf '%s: %s\n' "$PROG" "$2" >&2; exit "$1"; }
# The cache is root's and the reader is a login, or the checkout is the admin's
# and the reader is root: git (≥ 2.45.1) refuses a repo another user owns, even
# for a local clone's upload-pack. Command-line config is the one place
# safe.directory is honoured, and its env form reaches the child processes.
g() { git -c "safe.directory=$MIRROR" -c "safe.directory=${SRC:-$MIRROR}" "$@"; }

refresh() {
  SRC='' cl=''
  while [ $# -gt 0 ]; do
    case "$1" in
      --from) SRC="${2:-}"; shift 2 ;;
      --claude) cl="${2:-}"; shift 2 ;;
      *) die 2 "refresh: unknown arg $1" ;;
    esac
  done
  [ -n "$SRC" ] || die 2 'refresh: --from <claude-fleet checkout> is required'
  mkdir -p "$CACHE" || die 1 "cannot create $CACHE"
  chmod 755 "$CACHE" 2>/dev/null || true
  local ok=0 head
  # stable = the commit this checkout RUNS (its HEAD): the admin's live install
  # is a versioned worktree install-sync moved to stable, and its own
  # refs/tags/stable may lag the one it switched to. master = its origin/master
  # (else its master, else stable) — what bootstrap's `checkout -B master`
  # tracks.
  if head=$(g -C "$SRC" rev-parse -q --verify 'HEAD^{commit}' 2>/dev/null) && [ -n "$head" ]; then
    { [ -d "$MIRROR/objects" ] || git init -q --bare "$MIRROR"; } \
      && g -C "$MIRROR" fetch -q --no-tags --force "$SRC" 'HEAD:refs/tags/stable' 2>/dev/null \
      && { g -C "$MIRROR" fetch -q --no-tags --force "$SRC" 'refs/remotes/origin/master:refs/heads/master' 2>/dev/null \
           || g -C "$MIRROR" fetch -q --no-tags --force "$SRC" 'refs/heads/master:refs/heads/master' 2>/dev/null \
           || git -C "$MIRROR" update-ref refs/heads/master "$head"; } \
      && git -C "$MIRROR" symbolic-ref HEAD refs/heads/master \
      && chmod -R a+rX "$MIRROR" \
      && { say "claude-fleet: stable $(git -C "$MIRROR" rev-parse --short stable) → $MIRROR"; ok=1; } \
      || say "claude-fleet: NOT cached — fetching from $SRC failed"
  else
    say "claude-fleet: NOT cached — $SRC is not a checkout"
  fi
  [ -n "$cl" ] || cl=$(command -v claude 2>/dev/null) || cl=''
  local real ver
  real=$cl
  # ~/.local/bin/claude is a symlink into versions/<ver>: cache the file itself
  while [ -L "$real" ]; do
    l=$(readlink "$real"); case "$l" in /*) real=$l ;; *) real="$(dirname "$real")/$l" ;; esac
  done
  if [ -n "$real" ] && [ -x "$real" ] && ver=$("$real" --version 2>/dev/null | awk 'NR==1{print $1}') && [ -n "$ver" ]; then
    local d="$CACHE/claude/$ver"
    if [ -x "$d/claude" ] && cmp -s "$real" "$d/claude"; then :
    else
      mkdir -p "$d" && cp "$real" "$d/claude.tmp.$$" && chmod 755 "$d/claude.tmp.$$" \
        && mv -f "$d/claude.tmp.$$" "$d/claude" || { rm -f "$d/claude.tmp.$$"; say "claude: NOT cached — copying $real failed"; ver=''; }
    fi
    if [ -n "$ver" ]; then
      printf '%s\n' "$ver" > "$CACHE/claude/current.tmp.$$" && mv -f "$CACHE/claude/current.tmp.$$" "$CACHE/claude/current"
      chmod -R a+rX "$CACHE/claude"
      # older versions go: a login installs the one the admin runs
      for o in "$CACHE/claude"/*/; do [ "${o%/}" = "$d" ] || rm -rf "${o%/}"; done
      say "claude: $ver → $d/claude"; ok=$((ok + 2))
    fi
  else
    say "claude: NOT cached — no runnable claude${cl:+ at $cl}"
  fi
  [ "$ok" -gt 0 ] || return 1
  return 0
}

clone() {
  local dest='' br=''
  while [ $# -gt 0 ]; do
    case "$1" in
      --branch|-b) br="${2:-}"; shift 2 ;;
      -*) die 2 "clone: unknown arg $1" ;;
      *) [ -z "$dest" ] || die 2 "clone: one <dest>"; dest=$1; shift ;;
    esac
  done
  [ -n "$dest" ] || die 2 'clone: <dest> is required'
  [ -d "$MIRROR/objects" ] || return 3
  # --no-local: copy the objects, never hardlink root's files into the login's repo
  if g -c advice.detachedHead=false clone -q --no-local ${br:+-b "$br"} "$MIRROR" "$dest" 2>/dev/null \
     && git -C "$dest" remote set-url origin "$UPSTREAM"; then
    return 0
  fi
  rm -rf "$dest"
  return 1
}

claude_install() {
  local ver src
  ver=$(cat "$CACHE/claude/current" 2>/dev/null) || ver=''
  src="$CACHE/claude/$ver/claude"
  [ -n "$ver" ] && [ -x "$src" ] || return 3
  local vd="$HOME/.local/share/claude/versions" lb="$HOME/.local/bin"
  mkdir -p "$vd" "$lb" || return 1
  if ! { [ -x "$vd/$ver" ] && cmp -s "$src" "$vd/$ver"; }; then
    cp "$src" "$vd/$ver.tmp.$$" && chmod 755 "$vd/$ver.tmp.$$" && mv -f "$vd/$ver.tmp.$$" "$vd/$ver" \
      || { rm -f "$vd/$ver.tmp.$$"; return 1; }
  fi
  ln -sfn "$vd/$ver" "$lb/claude" || return 1
  "$lb/claude" --version >/dev/null 2>&1 || return 1
  say "claude: installed $ver from $CACHE → $lb/claude"
}

# off: no cache at all — today's road, byte for byte (a test seam, and a way out)
if [ "$CACHE" = off ]; then
  case "${1:-}" in
    dir) echo off; exit 0 ;;
    refresh) say "off (FLEET_BOOTSTRAP_CACHE=off) — nothing cached"; exit 0 ;;
    clone|claude) exit 3 ;;
  esac
fi
case "${1:-}" in
  refresh) shift; refresh "$@" ;;
  clone) shift; clone "$@" ;;
  claude) shift; claude_install ;;
  dir) printf '%s\n' "$CACHE" ;;
  -h|--help) sed -n '2,/^set -uo pipefail/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//' ;;
  *) die 2 "usage: $PROG refresh --from <checkout> [--claude <bin>] | clone <dest> [--branch b] | claude | dir" ;;
esac
