#!/bin/bash
# sidebar-anchor-repo-selftest.sh — under `all`, a session started from the
# sidebar takes the selected/focused row's repo (issue #1009).
#
#   A. a one-repo fleet runs the SAME rule as B (issue #1938): a row's own hosted
#      repo, `none` for a @norepo row, else the fleet's only repo (an unknown
#      window, the hub) — and a repo the fleet does not host anchors nothing.
#   B. 2-repo fleet viewing `all`: a row in repo B (@repo, or @worktree derived)
#      → the scratch gets `--repo o/b` and ⌃n's title `CF_REPO=o/b`; a @norepo
#      row → `--no-repo` ($HOME, issue #997), and ⌃n's title line offers the
#      repos on Tab (issue #1620: it was a popup asking), the first by default;
#      an unknown window → nothing anchored, the same Tab choice.
#   C. a stale current-repo file (the retired picker's, #1034) changes no anchor.
#   T. Heading taps (issue #1032), over the REAL sidebar rows: in a one-repo
#      fleet no row is a heading key, so every tap is today's jump/menu and the
#      input line keeps its plain hint (byte for byte). Under `all`, a repo
#      heading's 1st tap selects it (no switch), the 2nd asks ⌃n's title with
#      the repo pinned; the line names the target; `no repo` selects (⌃n offers
#      the repos on Tab); the `?` heading stays inert.
#
# The sidebar half imports fleet-sidebar.py and runs its real selection_repo /
# spawn_scratch / ask_new + submit against a shadow bin/ whose
# dash-raw-session.sh and dash-issue-new.sh only record what they were handed. Every tmux call goes to a private socket
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
# The hint line is localized since #1188 (fleet-sidebar.py: FLEET_UI_LANG, else the
# login locale) — pin the Chinese the hints below assert.
export FLEET_UI_LANG=zh
mkdir -p "$FLEET_CONF_DIR" "$TMPDIR"
unset TMUX TMUX_PANE FLEET_MAIN FLEET_REPO FLEET_BASE_BRANCH FLEET_SESSION CF_REPO
. "$BIN/fleet-lib.sh"

FAILS=0
fail() { printf 'FAIL: %s\n' "$*" >&2; FAILS=$((FAILS+1)); }
eq()   { [ "$2" = "$3" ] || fail "$1: expected [$3], got [$2]"; }

# The shadow bin/: every script the real one, but the two spawn entry points
# only record what they were handed.
for f in "$BIN"/*; do ln -s "$f" "$WORK/shadow/${f##*/}"; done
rm -f "$WORK/shadow/dash-raw-session.sh" "$WORK/shadow/dash-issue-new.sh"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" > "%s/dash-raw-session.sh.argv"\n' "$WORK" > "$WORK/shadow/dash-raw-session.sh"
# the title's file is a fresh mktemp path: recorded as the repo it goes to + the mode
printf '#!/bin/bash\nprintf "CF_REPO=%%s %%s %%s\\n" "${CF_REPO-unset}" "$1" "$2" > "%s/dash-issue-new.sh.argv"\n' "$WORK" > "$WORK/shadow/dash-issue-new.sh"

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

# sidebar <window> → "<scratch argv>|<⌃n's create, Tab choices>" as the sidebar
# in that window's pane would spawn them (⌃n: a title typed and ↵), the anchor
# row being that window.
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
repo = mod.selection_repo(sys.argv[3], sys.argv[4], env)
mod.spawn_scratch("n", env, repo).wait()
ask = mod.ask_new(sys.argv[3], env, repo)
mod.submit(ask, "t", sys.argv[3], env).wait()
open(os.environ["CHOICES"], "w").write(str(len(ask.choices)))
PY
  printf '%s|%s %s' "$(cat "$WORK/dash-raw-session.sh.argv" 2>/dev/null)" \
                    "$(cat "$WORK/dash-issue-new.sh.argv" 2>/dev/null)" "$(cat "$CHOICES" 2>/dev/null)"
}
CHOICES="$WORK/choices"; export CHOICES
# taps <anchor window> → one line per sidebar row as that window's view reads
# it: `<key> <1st tap> <2nd tap> <input hint>` (a bare heading prints `hdr`).
taps() {
  TMUX="$SOCK,1,0" TMUX_PANE=$(pane "$1") FLEET_SESSION="$S" \
  FLEET_SIDEBAR_CURRENT="$(wid "$1")" \
  python3 - "$BIN/fleet-sidebar.py" "$(wid "$1")" <<'PY' 2>/dev/null
import importlib.util, os, subprocess, sys
spec = importlib.util.spec_from_file_location("sidebar", sys.argv[1])
mod = importlib.util.module_from_spec(spec); spec.loader.exec_module(mod)
out = subprocess.run(["bash", str(mod.BIN / "tmux-dashboard-rows.sh"), "--sidebar"],
                     capture_output=True, text=True).stdout
for line in out.split("\n"):
    row = line.split(mod.US, 4)
    if len(row) != 5:
        continue
    key = mod.key_of(row)
    print(key, mod.tap(key, sys.argv[2]), mod.tap(key, key), mod.placeholder(key))
PY
}
# tapnew <window> <heading key> → the repo + Tab choices of the title a 2nd tap
# on that heading asks.
tapnew() {
  rm -f "$WORK"/*.argv
  TMUX="$SOCK,1,0" TMUX_PANE=$(pane "$1") FLEET_SESSION="$S" \
  python3 - "$BIN/fleet-sidebar.py" "$WORK/shadow" "$S" "$2" <<'PY' >/dev/null 2>&1
import importlib.util, os, sys
from pathlib import Path
spec = importlib.util.spec_from_file_location("sidebar", sys.argv[1])
mod = importlib.util.module_from_spec(spec); spec.loader.exec_module(mod)
mod.BIN = Path(sys.argv[2])
class Stub:
    def endwin(self): pass
    def clear(self): pass
mod.curses = Stub()
ask = mod.open_tap(sys.argv[3], mod.tap(sys.argv[4], sys.argv[4]), sys.argv[4], dict(os.environ))
open(os.environ["CHOICES"], "w").write("%s %d" % (ask.repo or "-", len(ask.choices)))
PY
  cat "$CHOICES" 2>/dev/null
}
TO_B="--name n --origin hub --repo o/b|CF_REPO=o/b confirm --spawn 0"
PICK="CF_REPO=o/a confirm --spawn 2"   # no anchor in a 2-repo fleet: Tab, first repo by default

# --- A. one repo: the same rule, one candidate (issue #1938) ----------------------
for w in wA wUNK plan; do
  eq "A: one-repo fleet anchors its only repo ($w)" "$(fleet_selection_repo "$S" "$(wid $w)")" o/a
done
for w in wB wWT; do
  eq "A: an unhosted repo's row anchors nothing ($w)" "$(fleet_selection_repo "$S" "$(wid $w)")" ""
done
eq "A: @norepo row resolves to none, as in B" "$(fleet_selection_repo "$S" "$(wid wNO)")" none
eq "A: no window anchors nothing, as in B" "$(fleet_selection_repo "$S" "")" ""
eq "A: one-repo sidebar on an A row → scratch + ⌃n go to A" "$(sidebar wA)" "--name n --origin hub --repo o/a|CF_REPO=o/a confirm --spawn 0"
eq "A: one-repo sidebar on a norepo row → --no-repo scratch, as in B" "$(sidebar wNO)" "--name n --origin hub --no-repo|CF_REPO=unset confirm --spawn 0"
T_A="$(taps wA)"
[ -n "$T_A" ] || fail "T: one-repo sidebar produced no rows"
eq "T: one-repo fleet has no heading key or heading tap" \
   "$(printf '%s\n' "$T_A" | grep -c 'hdr:\| select \| new ')" 0
eq "T: one-repo input hint unchanged" \
   "$(printf '%s\n' "$T_A" | awk '$4 != "新会话名…"' | wc -l | tr -d ' ')" 0
eq "T: one-repo row taps jump, then menu" \
   "$(printf '%s\n' "$T_A" | grep '^@' | grep -v "^$(wid wA) " | awk '{print $2, $3}' | sort -u)" "jump menu"
tmux set-option -wu -t "$S:wWT" @repo

# --- B. two repos, viewing all ----------------------------------------------------
mkdir -p "$FLEET_CONF_DIR/fleets/$S/repos"
printf 'FLEET_REPO="o/b"\nFLEET_MAIN="%s"\nFLEET_BASE_BRANCH="main"\n' "$WORK/mainB" \
  > "$FLEET_CONF_DIR/fleets/$S/repos/o-b.conf"
eq "B: @repo row anchors its repo"        "$(fleet_selection_repo "$S" "$(wid wB)")"  o/b
eq "B: @repo row in A anchors A"          "$(fleet_selection_repo "$S" "$(wid wA)")"  o/a
eq "B: @worktree row anchors its derived repo" "$(fleet_selection_repo "$S" "$(wid wWT)")" o/b
eq "B: @norepo row resolves to none (#997)" "$(fleet_selection_repo "$S" "$(wid wNO)")" none
eq "B: unknown row anchors nothing"       "$(fleet_selection_repo "$S" "$(wid wUNK)")" ""
eq "B: hub anchors nothing"               "$(fleet_selection_repo "$S" "$(wid plan)")" ""
eq "B: no window anchors nothing"         "$(fleet_selection_repo "$S" "")" ""
tmux set-option -w -t "$S:wUNK" @repo o/gone
eq "B: a repo the fleet does not host anchors nothing" "$(fleet_selection_repo "$S" "$(wid wUNK)")" ""
tmux set-option -wu -t "$S:wUNK" @repo
eq "B: sidebar on a B row → scratch + ⌃n go to B" "$(sidebar wB)" "$TO_B"
eq "B: sidebar on a norepo row → --no-repo scratch, ⌃n offers the repos" "$(sidebar wNO)" "--name n --origin hub --no-repo|$PICK"
eq "B: sidebar on an unknown row → nothing anchored, ⌃n offers the repos" "$(sidebar wUNK)" "--name n --origin hub|$PICK"

T_B="$(taps wA)"
eq "T: heading B — 1st tap selects, 2nd opens new, hint names it" \
   "$(printf '%s\n' "$T_B" | grep '^hdr:o/b ')" "hdr:o/b select new 新会话 → b…"
eq "T: no-repo heading selects as \$HOME" \
   "$(printf '%s\n' "$T_B" | grep '^hdr:none ')" "hdr:none select new 新会话 → 无仓库…"
eq "T: the ? heading stays inert" \
   "$(printf '%s\n' "$T_B" | grep -c '^hdr None None 新会话名…$')" 1
eq "T: a session row still jumps, then opens its menu" \
   "$(printf '%s\n' "$T_B" | grep "^$(wid wB) " | awk '{print $2, $3, $4}')" "jump menu 新会话名…"
eq "T: 2nd tap on heading B → ⌃n pinned to B" "$(tapnew wA hdr:o/b)" "o/b 0"
eq "T: 2nd tap on no-repo heading → ⌃n offers the repos" "$(tapnew wA hdr:none)" "o/a 2"

# --- C. a stale current-repo file ---------------------------------------------------
printf 'o/a\n' > "$FLEET_CONF_DIR/fleets/$S/current-repo"
eq "C: a stale current-repo file — a B row still anchors B" "$(fleet_selection_repo "$S" "$(wid wB)")" o/b
eq "C: …and the sidebar still sends B's row to B" "$(sidebar wB)" "$TO_B"
rm -f "$FLEET_CONF_DIR/fleets/$S/current-repo"

if [ "$FAILS" -gt 0 ]; then
  printf 'sidebar-anchor-repo-selftest: %s failure(s)\n' "$FAILS" >&2; exit 1
fi
printf 'sidebar-anchor-repo-selftest: all passed\n'
