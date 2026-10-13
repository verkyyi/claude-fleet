#!/bin/bash
# fleet-versions-lib.sh — ONE way to switch an install between whole versions
# (issue #1894, EPIC #1906 C1; the client's half — fleet-client-update.sh and
# the install line, fleet-install.sh — is C7 #1900). POSIX sh, not just bash:
# the install line sources it from the client it just downloaded.
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

# fleet_versions_prune <home> <keep>... — every version dir under
# <home>.versions/ but the ones named goes (the client keeps the current one,
# .prev's and .next's; a dot-dir — .staging, .lock — is never touched).
fleet_versions_prune() {
  local vh="$1" vd vn
  shift
  for vd in "$vh.versions"/*/; do
    [ -d "$vd" ] || continue
    vn=${vd%/}; vn=${vn##*/}
    case " $* " in *" $vn "*) continue ;; esac
    rm -rf "$vd"
  done
  return 0
}

# ---- the release lanes (issue #3868, EPIC #3863 C5, 共同约定 3) ---------------
# stable means "Linux has verified it"; a Mac follows refs/tags/stable-macos —
# never ahead of stable (fleet-stable.sh refuses that move), behind it while the
# macOS half of a release runs. No stable-macos tag ⇒ every machine follows
# stable, byte for byte as before. These two functions are the ONE place a
# platform picks its tag (fleet-lib.sh sources this file, so they are its too);
# the hub's /version says the same as client_version_macos. Never spell a
# platform test anywhere else.

# fleet_platform — this computer's release platform: darwin | linux | … (uname
# -s in lower case). FLEET_PLATFORM overrides it (a selftest playing a Mac).
fleet_platform() {
  if [ -n "${FLEET_PLATFORM:-}" ]; then printf '%s\n' "$FLEET_PLATFORM"; return 0; fi
  uname -s 2>/dev/null | tr 'ABCDEFGHIJKLMNOPQRSTUVWXYZ' 'abcdefghijklmnopqrstuvwxyz'
}

# fleet_stable_refs [<platform>] — the tags a machine of <platform> (default
# this one) follows, most preferred first: darwin → "stable-macos stable",
# anything else → "stable". A reader that is not git (GitHub's API, the hub)
# asks for each in turn and takes the first that exists.
fleet_stable_refs() {
  case "${1:-$(fleet_platform)}" in
    darwin) printf 'stable-macos stable\n' ;;
    *)      printf 'stable\n' ;;
  esac
}

# fleet_stable_ref_for <platform> <git dir> <remote> — the ONE tag <platform>
# follows on <remote>: the first of fleet_stable_refs that the remote carries
# (git ls-remote, no fetch). rc 0 + the name (stable when the remote has neither:
# the caller's own fetch then says "no stable yet"); rc 1 + nothing when the
# remote could not be read — never "stable" on a guess, or a Mac whose
# ls-remote blinked would take a release its lane has not reached.
fleet_stable_ref_for() {
  local sp="$1" sg="$2" sr="$3" sl st
  sl=$(git -C "$sg" ls-remote --tags "$sr" $(for st in $(fleet_stable_refs "$sp"); do printf 'refs/tags/%s ' "$st"; done) 2>/dev/null </dev/null) || return 1
  for st in $(fleet_stable_refs "$sp"); do
    case "$sl" in *"refs/tags/$st"|*"refs/tags/$st"[!a-zA-Z0-9_-]*) printf '%s\n' "$st"; return 0 ;; esac
  done
  printf 'stable\n'
}
