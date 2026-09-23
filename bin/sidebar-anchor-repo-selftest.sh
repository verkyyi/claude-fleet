#!/bin/bash
# sidebar-anchor-repo-selftest.sh — under `all`, a session started from the
# sidebar takes the selected/focused row's repo (issue #1009).
#
#   A. DEGENERATE — a one-repo fleet: fleet_anchor_repo prints nothing for any
#      window, and the sidebar's Enter / ⌃n spawn exactly as before (no --repo,
#      no CF_REPO).
#   B. 2-repo fleet viewing `all`: a row in repo B (@repo, or @worktree derived)
#      → the scratch gets `--repo o/b` and ⌃n's popup `CF_REPO=o/b`; a @norepo
#      row, the hub, an unknown window → today's behavior (nothing passed).
#   C. 2-repo fleet viewing ONE repo: nothing passed — that repo still wins.
#
# The sidebar half imports fleet-sidebar.py and runs its real anchor_repo /
# spawn_scratch / new_task against a shadow bin/ whose dash-raw-session.sh and
# dash-popup.sh only record their argv. Every tmux call goes to a private socket
# via a PATH shim (never the live server); `gh` is shimmed to fail.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
REAL_TMUX="$(command -v tmux 2>/dev/null)"
[ -n "$REAL_TMUX" ] || { printf 'selftest: tmux not installed — SKIP\n' >&2; exit 0; }
command -v git >/dev/null 2>&1 || { printf 'selftest: git not installed — SKIP\n' >&2; exit 0; }
command -v python3 >/dev/null 2>&1 || { printf 'selftest: python3 not installed — SKIP\n' >&2; exit 0; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/sidebar-anchor-selftest.XXXXXX")" || exit 2
WORK="$(cd "$WORK" && pwd -P)"
SOCK="$WORK/tmux.sock"
mkdir -p "$WORK/bin" "$WORK/shadow"
cat > "$WORK/bin/tmux" <<EOF
#!/bin/sh
exec "$REAL_TMUX" -S "$SOCK" "\$@"
EOF
printf '#!/bin/sh\nexit 1\n' > "$WORK/bin/gh"
chmod +x "$WORK/bin/tmux" "$WORK/bin/gh"
export PATH="$WORK/bin:$PATH"

cleanup() { "$REAL_TMUX" -S "$SOCK" kill-server 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT
trap 'exit 130' INT TERM HUP

export FLEET_CONF_DIR="$WORK/conf" FLEET_SKIP_GLOBAL_CONF=1 TMPDIR="$WORK/tmp"
mkdir -p "$FLEET_CONF_DIR" "$TMPDIR"
unset TMUX TMUX_PANE FLEET_MAIN FLEET_REPO FLEET_BASE_BRANCH FLEET_SESSION CF_REPO
. "$BIN/fleet-lib.sh"

FAILS=0
fail() { printf 'FAIL: %s\n' "$*" >&2; FAILS=$((FAILS+1)); }
eq()   { [ "$2" = "$3" ] || fail "$1: expected [$3], got [$2]"; }

# The shadow bin/: every script the real one, but the two spawn entry points
# only record what they were handed.
for f in "$BIN"/*; do ln -s "$f" "$WORK/shadow/${f##*/}"; done
for f in dash-raw-session.sh dash-popup.sh; do
  rm -f "$WORK/shadow/$f"
  printf '#!/bin/bash\nprintf "%%s\\n" "$*" > "%s/%s.argv"\n' "$WORK" "$f" > "$WORK/shadow/$f"
done

mkrepo() { git init -q "$1" && git -C "$1" remote add origin "https://github.com/$2.git"; }
mkrepo "$WORK/mainA" o/a
mkrepo "$WORK/mainB" o/b
mkrepo "$WORK/wtB"   o/b     # stands in for B's issue worktree

S=fa
mkdir -p "$FLEET_CONF_DIR/fleets/$S"
cat > "$FLEET_CONF_DIR/fleets/$S/conf" <<EOF
FLEET_REPO="o/a"
FLEET_MAIN="$WORK/mainA"
FLEET_BASE_BRANCH="master"
EOF

"$REAL_TMUX" -S "$SOCK" new-session -d -s "$S" -n plan -x 200 -y 50 || { echo "could not start isolated tmux" >&2; exit 1; }
for w in wA wB wWT wNO wUNK; do tmux new-window -d -t "$S" -n "$w"; done
tmux set-option -w -t "$S:wA"  @repo o/a
tmux set-option -w -t "$S:wB"  @repo o/b
tmux set-option -w -t "$S:wWT" @worktree "$WORK/wtB"
tmux set-option -w -t "$S:wNO" @norepo 1
wid() { tmux display-message -p -t "$S:$1" '#{window_id}'; }
pane() { tmux display-message -p -t "$S:$1" '#{pane_id}'; }

# sidebar <window> → "<scratch argv>|<⌃n popup argv>" as the sidebar in that
# window's pane would spawn them, the anchor row being that window.
sidebar() {
  rm -f "$WORK"/*.argv
  TMUX="$SOCK,1,0" TMUX_PANE=$(pane "$1") FLEET_SESSION="$S" \
  python3 - "$BIN/fleet-sidebar.py" "$WORK/shadow" "$S" "$(wid "$1")" <<'PY' >/dev/null 2>&1
import importlib.util, os, sys
from pathlib import Path
spec = importlib.util.spec_from_file_location("sidebar", sys.argv[1])
mod = importlib.util.module_from_spec(spec); spec.loader.exec_module(mod)
mod.BIN = Path(sys.argv[2])
class Stub:
    def endwin(self): pass
    def clear(self): pass
mod.curses = Stub()
env = dict(os.environ)
repo = mod.anchor_repo(sys.argv[3], sys.argv[4], env)
mod.spawn_scratch("n", env, repo).wait()
mod.new_task(Stub(), env, repo)
PY
  printf '%s|%s' "$(cat "$WORK/dash-raw-session.sh.argv" 2>/dev/null)" \
                 "$(cat "$WORK/dash-popup.sh.argv" 2>/dev/null)"
}
SH="$WORK/shadow"
PLAIN="--name n --origin hub|-w 90% -h 12 -- bash $SH/dash-issue-new.sh confirm --spawn"
TO_B="--name n --origin hub --repo o/b|-w 90% -h 12 -- env CF_REPO=o/b bash $SH/dash-issue-new.sh confirm --spawn"

# --- A. degenerate: one repo ------------------------------------------------------
for w in wA wB wWT wNO wUNK plan; do
  eq "A: one-repo fleet anchors nothing ($w)" "$(fleet_anchor_repo "$S" "$(wid $w)")" ""
done
eq "A: one-repo sidebar spawns unchanged" "$(sidebar wA)" "$PLAIN"
eq "A: one-repo sidebar spawns unchanged (norepo row)" "$(sidebar wNO)" "$PLAIN"
tmux set-option -wu -t "$S:wWT" @repo

# --- B. two repos, viewing all ----------------------------------------------------
mkdir -p "$FLEET_CONF_DIR/fleets/$S/repos"
printf 'FLEET_REPO="o/b"\nFLEET_MAIN="%s"\nFLEET_BASE_BRANCH="main"\n' "$WORK/mainB" \
  > "$FLEET_CONF_DIR/fleets/$S/repos/o-b.conf"
eq "B: current repo is all" "$(fleet_current_repo "$S")" all
eq "B: @repo row anchors its repo"        "$(fleet_anchor_repo "$S" "$(wid wB)")"  o/b
eq "B: @repo row in A anchors A"          "$(fleet_anchor_repo "$S" "$(wid wA)")"  o/a
eq "B: @worktree row anchors its derived repo" "$(fleet_anchor_repo "$S" "$(wid wWT)")" o/b
eq "B: @norepo row anchors nothing"       "$(fleet_anchor_repo "$S" "$(wid wNO)")" ""
eq "B: unknown row anchors nothing"       "$(fleet_anchor_repo "$S" "$(wid wUNK)")" ""
eq "B: hub anchors nothing"               "$(fleet_anchor_repo "$S" "$(wid plan)")" ""
eq "B: no window anchors nothing"         "$(fleet_anchor_repo "$S" "")" ""
tmux set-option -w -t "$S:wUNK" @repo o/gone
eq "B: a repo the fleet does not host anchors nothing" "$(fleet_anchor_repo "$S" "$(wid wUNK)")" ""
tmux set-option -wu -t "$S:wUNK" @repo
eq "B: sidebar on a B row → scratch + ⌃n go to B" "$(sidebar wB)" "$TO_B"
eq "B: sidebar on a norepo row → today's behavior" "$(sidebar wNO)" "$PLAIN"
eq "B: sidebar on an unknown row → today's behavior" "$(sidebar wUNK)" "$PLAIN"

# --- C. two repos, viewing one ----------------------------------------------------
fleet_current_repo_set "$S" o/a >/dev/null 2>&1 || fail "C: could not set current repo"
eq "C: single repo in view anchors nothing" "$(fleet_anchor_repo "$S" "$(wid wB)")" ""
eq "C: sidebar on a B row keeps the viewed repo's path" "$(sidebar wB)" "$PLAIN"

if [ "$FAILS" -gt 0 ]; then
  printf 'sidebar-anchor-repo-selftest: %s failure(s)\n' "$FAILS" >&2; exit 1
fi
printf 'sidebar-anchor-repo-selftest: all passed\n'
