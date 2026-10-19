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


# ── what the fleet installed: <dir>/installed.list (issue #4827) ─────────────
# One line per file the install line (or fc_served) put in <dir>: its path
# relative to <dir> TAB its sha256. Only a file listed there AND still holding
# those bytes is the fleet's to delete on an upgrade; anything else in <dir> —
# a file the person put in, a fleet file they edited — is theirs and stays,
# carried into the next whole version too. No list (an install from before
# it) ⇒ nothing is known to be the fleet's.

# fleet_installed_write <dir> <rel>... — <dir>/installed.list for the files
# named (one that is not there is skipped), written whole by one rename(2).
fleet_installed_write() {
  python3 -c 'import hashlib, os, sys
d = sys.argv[1]
out = []
for rel in sys.argv[2:]:
    p = os.path.join(d, rel)
    if os.path.isfile(p) and not os.path.islink(p):
        with open(p, "rb") as f:
            out.append("%s\t%s\n" % (rel, hashlib.sha256(f.read()).hexdigest()))
t = os.path.join(d, "installed.list.tmp.%d" % os.getpid())
with open(t, "w") as f:
    f.write("".join(out))
os.chmod(t, 0o644)
os.replace(t, os.path.join(d, "installed.list"))' "$@"
}

# fleet_installed_owned <dir> — every path installed.list names whose file in
# <dir> still holds the listed bytes: the fleet's own, unchanged. rc 1: no list.
fleet_installed_owned() {
  [ -f "$1/installed.list" ] || return 1
  python3 -c 'import hashlib, os, sys
d = sys.argv[1]
for line in open(os.path.join(d, "installed.list")):
    rel, _, want = line.rstrip("\n").partition("\t")
    if not rel or ".." in rel.split("/") or rel.startswith("/"):
        continue
    p = os.path.join(d, rel)
    try:
        if os.path.islink(p):
            continue
        with open(p, "rb") as f:
            if hashlib.sha256(f.read()).hexdigest() == want:
                print(rel)
    except OSError:
        pass' "$1"
}

# fleet_versions_carry <from> <to> — a whole-version switch keeps what is the
# person's: every file under <from> that <to> lacks and that is not the fleet's
# own unchanged copy (fleet_installed_owned) is copied into <to>, mode kept. A
# file <to> also has is the new version's — <to> wins. The marks at the top
# (.client-version, .staged, installed.list) are never carried. No list in
# <from> ⇒ nothing carried (compat-1v: 下一批删 — the old rule, a hand edit is
# gone at the switch). Prints each carried path.
fleet_versions_carry() {
  [ -f "$1/installed.list" ] || return 0
  fleet_installed_owned "$1" | python3 -c 'import os, shutil, sys
src, dst = sys.argv[1], sys.argv[2]
owned = set(l.rstrip("\n") for l in sys.stdin)
for top, dirs, files in os.walk(src):
    dirs[:] = [x for x in dirs if not (top == src and x.startswith("."))]
    for n in files:
        p = os.path.join(top, n)
        rel = os.path.relpath(p, src)
        if top == src and (n.startswith(".") or n == "installed.list"):
            continue
        if rel in owned or os.path.islink(p) or os.path.lexists(os.path.join(dst, rel)):
            continue
        os.makedirs(os.path.dirname(os.path.join(dst, rel)), exist_ok=True)
        shutil.copy2(p, os.path.join(dst, rel))
        print(rel)' "$1" "$2"
}
