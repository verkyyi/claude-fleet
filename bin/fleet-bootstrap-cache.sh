#!/bin/bash
# fleet-bootstrap-cache.sh — what a new login needs, kept on this machine
# (issue #2297, EPIC #2293 C6). Opening a login used to reach abroad twice — a
# `git clone` of claude-fleet from github.com and `curl https://claude.ai/install.sh`
# — and on a mainland network either one hangs the newcomer's first minute. The
# admin's side already HAS Claude Code; this script copies it into one
# machine-wide cache that every login can read, and installs a new login from it;
# no cache = today's road.
#
#   <cache>/claude/<ver>/claude   the admin's Claude Code native binary
#   <cache>/claude/current        <ver>
#
# The claude-fleet half is RETIRED (issue #2775, EPIC #2770 C5): a new login's
# install is the machine's runtime or the hub's signed stable
# (fleet-login-install.sh) — a mirror filled at the last opening was usually an
# old version, and its origin was GitHub. `refresh` writes no <cache>/claude-fleet.git
# any more (`--from` is accepted and ignored for one version); `clone` still reads
# a mirror an older refresh left, for one version, and nothing calls it.
# On a managed machine the Claude Code half is the machine updater's cache step
# (fleet-node-update.py), the same <cache>/claude.
#
# <cache> is FLEET_BOOTSTRAP_CACHE, default /Library/Application Support/
# claude-fleet/cache on macOS (/var/cache/claude-fleet elsewhere): written by
# root (fleet-login-new.sh --apply runs `sudo … refresh`), read by everyone.
#
# Usage:
#   fleet-bootstrap-cache.sh refresh [--claude <bin>]
#       fill / update the cache (as root). --claude defaults to the `claude` on
#       PATH; none is a note, and rc 1 (nothing cached).
#   fleet-bootstrap-cache.sh claude
#       install the cached Claude Code for THIS login the way the native
#       installer lays it out: ~/.local/share/claude/versions/<ver>, symlinked
#       from ~/.local/bin/claude. Exit 3: no binary in the cache.
#   fleet-bootstrap-cache.sh dir          print <cache>
#
# Env: FLEET_BOOTSTRAP_CACHE (`off` = no cache: refresh does nothing, clone /
#      claude exit 3)
# Exit: 0 ok · 1 failed · 2 usage · 3 nothing cached for it
set -uo pipefail

PROG=fleet-bootstrap-cache
FLEET_REPO_SELF=verkyyi/claude-fleet
if [ -n "${FLEET_BOOTSTRAP_CACHE:-}" ]; then CACHE=$FLEET_BOOTSTRAP_CACHE
elif [ "$(uname -s)" = Darwin ]; then CACHE='/Library/Application Support/claude-fleet/cache'
else CACHE=/var/cache/claude-fleet
fi
MIRROR="$CACHE/claude-fleet.git"
UPSTREAM="${FLEET_BOOTSTRAP_GIT_BASE:-https://github.com}/$FLEET_REPO_SELF.git"  # dist-ok: compat-1v (下一批删) — clone's origin; no caller since #2775

say() { printf '%s: %s\n' "$PROG" "$*"; }
die() { printf '%s: %s\n' "$PROG" "$2" >&2; exit "$1"; }
# The cache is root's and the reader is a login: git (≥ 2.45.1) refuses a repo
# another user owns, even for a local clone's upload-pack. Command-line config is
# the one place safe.directory is honoured, and its env form reaches the children.
g() { git -c "safe.directory=$MIRROR" "$@"; }

refresh() {
  cl=''
  while [ $# -gt 0 ]; do
    case "$1" in
      --from) shift; [ $# -gt 0 ] && shift ;;  # compat-1v: 下一批删 — the claude-fleet mirror retired (issue #2775)
      --claude) cl="${2:-}"; shift 2 ;;
      *) die 2 "refresh: unknown arg $1" ;;
    esac
  done
  mkdir -p "$CACHE" || die 1 "cannot create $CACHE"
  chmod 755 "$CACHE" 2>/dev/null || true
  local ok=0
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

# compat-1v: 下一批删 — reads a claude-fleet.git an older refresh left; no caller
# since issue #2775 (a new login installs from the runtime or the hub)
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
  *) die 2 "usage: $PROG refresh [--claude <bin>] | claude | dir" ;;
esac
