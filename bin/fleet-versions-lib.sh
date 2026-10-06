#!/bin/bash
# fleet-versions-lib.sh — ONE way to switch an install between whole versions
# (issue #1894, EPIC #1906 C1; the client's half is C7 #1900).
#
# An install HOME (~/.claude/fleet) is a SYMLINK to one directory under
# <home>.versions/<key>/; a switch is ONE rename(2) of a link made beside it, so
# a reader sees either the old version or the new one, never a mix, and a script
# already running keeps reading the files it opened. A HOME that is still a plain
# directory is adopted first (moved to <home>.versions/<key>/, the link put in
# its place). <home>.versions/.prev names the version before the last switch.
#
# Sourced, never run. No `local` takes a zsh special parameter's name (#1633).

# fleet_versions_point <home> <dir> — <home> → <dir>, in one rename(2).
# rc 1: nothing changed (no <dir>, or <home> is a plain directory: adopt it first).
fleet_versions_point() {
  [ -d "$2" ] || return 1
  { [ -e "$1" ] && [ ! -L "$1" ]; } && return 1
  python3 -c 'import os, sys
t, link = sys.argv[1], sys.argv[2]
tmp = link + ".switch.%d" % os.getpid()
try:
    os.unlink(tmp)
except OSError:
    pass
os.symlink(t, tmp)
os.replace(tmp, link)' "$2" "$1"
}

# fleet_versions_adopt <home> <key> — a plain-directory <home> moved to
# <home>.versions/<key>/ and <home> made the link to it. Nothing to do when
# <home> is already a link. rc 1: nothing changed (the move is undone when the
# link cannot be made). The two renames are back to back: a reader in between
# finds no <home> for microseconds, once, on the first switch of a login.
fleet_versions_adopt() {
  local vh="$1" vk="$2" vd
  { [ -e "$vh" ] && [ ! -L "$vh" ]; } || return 0
  vd="$vh.versions/$vk"
  [ -e "$vd" ] && return 1
  mkdir -p "$vh.versions" && mv "$vh" "$vd" || return 1
  if ! fleet_versions_point "$vh" "$vd"; then mv "$vd" "$vh"; return 1; fi
  return 0
}

# fleet_versions_current <home> — the key <home> points at ('' for a plain dir).
fleet_versions_current() {
  local vt
  [ -L "$1" ] || return 0
  vt=$(readlink "$1") || return 0
  vt=${vt%/}
  printf '%s\n' "${vt##*/}"
}
