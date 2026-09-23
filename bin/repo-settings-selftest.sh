#!/bin/bash
# repo-settings-selftest.sh — every repo keeps its own setup (issue #978).
#
# Fleet M hosts o/a (its conf) + o/b + o/e (overlays). The fleet conf sets the
# fleet-wide values; o/b's overlay overrides every per-repo key; o/e's sets none,
# so it must read the fleet's. Fleet D is the degenerate case — ONE repo (o/c), no
# repos/ dir — and every leg asserts it reads exactly what it always did.
#
#   lockstep  fleet.conf.example's per-repo line == _FLEET_REPO_OVERRIDABLE
#   get       fleet_repo_conf_get / fleet-repo.sh get: overlay, else fleet value
#   leak      a shell that applied o/b's overlay, then loads o/a or o/e, keeps
#             none of o/b's per-repo values
#   setup     FLEET_WORKTREE_SETUP: o/a, o/b, o/e worktrees each run their own
#             hook (lib spawn path + the `cw` shim, fleet-worktree.sh)
#   basesync  fleet-base-sync.sh walks every hosted repo, each with its own deps
#   sleep     FLEET_SLEEP_MCP_RESTARTABLE resolved per window/worktree repo
#             (fleet_sleep_mcp.restartable), the hint naming the repo's conf
#   switches  FLEET_CLEANUP (cleanup daemon), FLEET_ISSUE_BRIDGE (hub message
#             gate), FLEET_SCRATCH_POOL (the pool's own repo)
#
# tmux: a PATH shim maps every `-L <label>` to a private socket under $WORK —
# never the live server. gh is shimmed to fail and every origin is a local bare
# repo, so nothing touches the network.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
REAL_TMUX="$(command -v tmux 2>/dev/null)"
[ -n "$REAL_TMUX" ] || { printf 'selftest: tmux not installed — SKIP\n' >&2; exit 0; }
command -v git >/dev/null 2>&1 || { printf 'selftest: git not installed — SKIP\n' >&2; exit 0; }
command -v python3 >/dev/null 2>&1 || { printf 'selftest: python3 not installed — SKIP\n' >&2; exit 0; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/repo-settings-selftest.XXXXXX")" || exit 2
WORK="$(cd "$WORK" && pwd -P)"
mkdir -p "$WORK/bin" "$WORK/home" "$WORK/tmp"
cat > "$WORK/bin/tmux" <<EOF
#!/bin/bash
if [ "\${1:-}" = -L ]; then s="$WORK/sock.\$2"; shift 2; exec "$REAL_TMUX" -S "\$s" "\$@"; fi
[ -n "\${TMUX:-}" ] || exec "$REAL_TMUX" -S "$WORK/sock.none" "\$@"
exec "$REAL_TMUX" "\$@"
EOF
printf '#!/bin/sh\nexit 1\n' > "$WORK/bin/gh"
chmod +x "$WORK/bin/tmux" "$WORK/bin/gh"
export PATH="$WORK/bin:$PATH"

cleanup() {
  local s; for s in "$WORK"/sock.*; do [ -S "$s" ] && "$REAL_TMUX" -S "$s" kill-server 2>/dev/null; done
  rm -rf "$WORK"
}
trap cleanup EXIT
trap 'exit 130' INT TERM HUP

export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8
export HOME="$WORK/home" FLEET_CONF_DIR="$WORK/conf" FLEET_SKIP_GLOBAL_CONF=1 TMPDIR="$WORK/tmp"
export FLEET_DISK_FLOOR_GB=0 FLEET_WORKTREE_SETUP_LOG="$WORK/setup.log"
export LAND_LEASE_DIR="$WORK/leases" FLEET_LAND_LEASE_DIR="$WORK/leases"
unset TMUX TMUX_PANE FLEET_MAIN FLEET_REPO FLEET_BASE_BRANCH FLEET_SESSION FLEET_WORKTREE_ROOT
unset FLEET_WORKTREE_SETUP FLEET_WORKTREE_SETUP_TIMEOUT FLEET_BASE_DEPS FLEET_SLEEP_MCP_RESTARTABLE
unset FLEET_SCRATCH_POOL FLEET_ISSUE_BRIDGE FLEET_CLEANUP
. "$BIN/fleet-lib.sh"

FAILS=0
fail() { printf 'FAIL: %s\n' "$*" >&2; FAILS=$((FAILS+1)); }
eq()   { [ "$2" = "$3" ] || fail "$1: expected [$3], got [$2]"; }
has()  { case "$2" in *"$3"*) ;; *) fail "$1: [$3] not in: $2" ;; esac; }
hasnt(){ case "$2" in *"$3"*) fail "$1: [$3] unexpectedly in: $2" ;; esac; }
leg()  { # leg <name> — PASS when no new failure since the last leg
  if [ "$FAILS" = "${_legf:-0}" ]; then printf 'PASS %s\n' "$1"; else printf 'FAIL %s\n' "$1"; fi
  _legf=$FAILS
}

mkrepo() { # origin = a local bare repo: base-sync's fetch never leaves the box
  local bare="$WORK/origin-${2%/*}-${2#*/}.git"
  git init -q --bare "$bare"
  git init -q -b master "$1" && git -C "$1" remote add origin "$bare"
  git -C "$1" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
  git -C "$1" push -q origin master
}
mkrepo "$WORK/mainA" o/a; mkrepo "$WORK/mainB" o/b; mkrepo "$WORK/mainE" o/e; mkrepo "$WORK/mainC" o/c

# Setup hooks: each stamps its name into the new worktree.
for h in a b c; do
  printf '#!/bin/sh\nprintf %s > "$1/.setup"\n' "$h" > "$WORK/setup-$h.sh"; chmod +x "$WORK/setup-$h.sh"
done

M=M D=D
mkdir -p "$FLEET_CONF_DIR/fleets/$M/repos" "$FLEET_CONF_DIR/fleets/$D"
cat > "$FLEET_CONF_DIR/fleets/$M/conf" <<EOF
FLEET_REPO="o/a"
FLEET_MAIN="$WORK/mainA"
FLEET_BASE_BRANCH="master"
FLEET_WORKTREE_ROOT="$WORK/wt"
FLEET_WORKTREE_SETUP="$WORK/setup-a.sh"
FLEET_SLEEP_MCP_RESTARTABLE="fleetmcp"
FLEET_ISSUE_BRIDGE=1
FLEET_SCRATCH_POOL=2
EOF
cat > "$(fleet_repo_conf_file "$M" o/b)" <<EOF
FLEET_REPO="o/b"
FLEET_MAIN="$WORK/mainB"
FLEET_BASE_BRANCH="master"
FLEET_WORKTREE_SETUP="$WORK/setup-b.sh"
FLEET_BASE_DEPS=1
FLEET_SLEEP_MCP_RESTARTABLE="bmcp,playwright"
FLEET_ISSUE_BRIDGE=0
FLEET_SCRATCH_POOL=0
FLEET_CLEANUP=0
EOF
cat > "$(fleet_repo_conf_file "$M" o/e)" <<EOF
FLEET_REPO="o/e"
FLEET_MAIN="$WORK/mainE"
FLEET_BASE_BRANCH="master"
EOF
cat > "$FLEET_CONF_DIR/fleets/$D/conf" <<EOF
FLEET_REPO="o/c"
FLEET_MAIN="$WORK/mainC"
FLEET_BASE_BRANCH="master"
FLEET_WORKTREE_ROOT="$WORK/wt"
FLEET_WORKTREE_SETUP="$WORK/setup-c.sh"
FLEET_SLEEP_MCP_RESTARTABLE="cmcp"
FLEET_CLEANUP=0
EOF

# --- lockstep --------------------------------------------------------------------
ex=$(sed -n 's/^#[[:space:]]*per-repo:[[:space:]]*//p' "$BIN/../fleet.conf.example")
eq 'example per-repo line == _FLEET_REPO_OVERRIDABLE' "$ex" "$_FLEET_REPO_OVERRIDABLE"
leg lockstep

# --- get -------------------------------------------------------------------------
eq 'a setup (fleet)'        "$(fleet_repo_conf_get $M o/a FLEET_WORKTREE_SETUP)" "$WORK/setup-a.sh"
eq 'b setup (overlay)'      "$(fleet_repo_conf_get $M o/b FLEET_WORKTREE_SETUP)" "$WORK/setup-b.sh"
eq 'e setup (fallback)'     "$(fleet_repo_conf_get $M o/e FLEET_WORKTREE_SETUP)" "$WORK/setup-a.sh"
eq 'b restartable'          "$(fleet_repo_conf_get $M o/b FLEET_SLEEP_MCP_RESTARTABLE)" "bmcp,playwright"
eq 'e restartable fallback' "$(fleet_repo_conf_get $M o/e FLEET_SLEEP_MCP_RESTARTABLE)" "fleetmcp"
eq 'a cleanup unset'        "$(fleet_repo_conf_get $M o/a FLEET_CLEANUP)" ""
eq 'b cleanup'              "$(fleet_repo_conf_get $M o/b FLEET_CLEANUP)" "0"
fleet_repo_conf_get $M o/zz FLEET_CLEANUP >/dev/null; eq 'unhosted rc' "$?" 1
fleet_repo_conf_get $M o/a 'x;y' >/dev/null; eq 'bad key rc' "$?" 2
eq 'cli b'       "$(bash "$BIN/fleet-repo.sh" get FLEET_SCRATCH_POOL o/b --session $M)" "0"
eq 'cli e tsv'   "$(bash "$BIN/fleet-repo.sh" get FLEET_SCRATCH_POOL o/e --session $M --tsv)" \
                 "o/e	$(fleet_repo_conf_file $M o/e)	2"
eq 'cli degenerate' "$(bash "$BIN/fleet-repo.sh" get FLEET_WORKTREE_SETUP o/c --session $D --tsv)" \
                    "o/c	$(fleet_conf_file $D)	$WORK/setup-c.sh"
leg get

# --- leak ------------------------------------------------------------------------
eq 'b then a: cleanup falls back' \
   "$( fleet_load_repo_conf $M o/b; fleet_load_repo_conf $M o/a; printf '%s' "${FLEET_CLEANUP-unset}" )" unset
eq 'b then e: setup = fleet' \
   "$( fleet_load_repo_conf $M o/b; fleet_load_repo_conf $M o/e; printf '%s' "$FLEET_WORKTREE_SETUP" )" "$WORK/setup-a.sh"
eq 'b then e: deps unset' \
   "$( fleet_load_repo_conf $M o/b; fleet_load_repo_conf $M o/e; printf '%s' "${FLEET_BASE_DEPS-unset}" )" unset
eq 'caller env survives (baseline)' \
   "$( FLEET_CLEANUP=9 bash -c ". '$BIN/fleet-lib.sh'; fleet_load_repo_conf $M o/b; fleet_load_repo_conf $M o/a; printf %s \"\$FLEET_CLEANUP\"" )" 9
# Degenerate: no reset at all — a one-repo fleet's load is what it always was.
eq 'degenerate untouched' \
   "$( FLEET_SCRATCH_POOL=7; fleet_load_repo_conf $D o/c; printf '%s' "$FLEET_SCRATCH_POOL" )" 7
leg leak

# --- setup -----------------------------------------------------------------------
mk() { # mk <repo> <main> <slug> → the .setup stamp of the new worktree
  local wt
  wt=$( fleet_load_repo_conf $M o/b    # dirty the shell first: a pane of o/b spawning
        fleet_load_repo_conf "$1" "$2" && fleet_worktree_create "$3" "$4" master )
  cat "$wt/.setup" 2>/dev/null
}
eq 'lib a' "$(mk $M o/a "$WORK/mainA" issue-1)" a
eq 'lib b' "$(mk $M o/b "$WORK/mainB" issue-1)" b
eq 'lib e' "$(mk $M o/e "$WORK/mainE" issue-1)" a
wt=$( fleet_load_repo_conf $D o/c && fleet_worktree_create "$WORK/mainC" issue-1 master )
eq 'lib degenerate' "$(cat "$wt/.setup" 2>/dev/null)" c
wt=$(bash "$BIN/fleet-worktree.sh" create "$WORK/mainB" issue-2 master)
eq 'cw b' "$(cat "$wt/.setup" 2>/dev/null)" b
wt=$(bash "$BIN/fleet-worktree.sh" create "$WORK/mainC" issue-2 master)
eq 'cw degenerate' "$(cat "$wt/.setup" 2>/dev/null)" c
leg setup

# --- basesync --------------------------------------------------------------------
out=$(bash "$BIN/fleet-base-sync.sh" --dry-run $M 2>&1)
has   'base-sync a'        "$out" "base $WORK/mainA already current"
has   'base-sync b'        "$out" "base $WORK/mainB already current"
has   'base-sync e'        "$out" "base $WORK/mainE already current"
has   'b deps (overlay)'   "$out" "would keep $WORK/mainB's shared deps current"
hasnt 'a deps off'         "$out" "would keep $WORK/mainA's shared deps"
out=$(bash "$BIN/fleet-base-sync.sh" --dry-run $D 2>&1)
has   'degenerate base'    "$out" "base $WORK/mainC already current"
hasnt 'degenerate deps'    "$out" "shared deps"
leg basesync

# --- sleep -----------------------------------------------------------------------
TMX() { tmux -L "$(fleet_socket "$1")" "${@:2}"; }
TMX $M new-session -d -s $M -n hub -x 80 -y 24
wa=$(TMX $M new-window -d -P -F '#{window_id}' -t "$M:" -n wa); TMX $M set-option -w -t "$wa" @repo o/a
wb=$(TMX $M new-window -d -P -F '#{window_id}' -t "$M:" -n wb); TMX $M set-option -w -t "$wb" @repo o/b
we=$(TMX $M new-window -d -P -F '#{window_id}' -t "$M:" -n we); TMX $M set-option -w -t "$we" @repo o/e
wtb=$( fleet_load_repo_conf $M o/b && fleet_worktree_dir "$WORK/mainB" issue-1 )
restartable() { # restartable <session> <window> <worktree> → "names|conf"
  FLEET_SLEEP_MCP_RESTARTABLE="$4" python3 - "$BIN" "$1" "$2" "$3" <<'PY'
import runpy, sys
m = runpy.run_path(sys.argv[1] + '/fleet_sleep_mcp.py')
src = {k: v for k, v in (('session', sys.argv[2]), ('window', sys.argv[3]), ('worktree', sys.argv[4])) if v}
names, conf = m['restartable'](src)
print(','.join(sorted(names)) + '|' + str(conf))
PY
}
eq 'window a'   "$(restartable $M "$wa" '' fleetmcp)" "fleetmcp|$(fleet_conf_file $M)"
eq 'window b'   "$(restartable $M "$wb" '' fleetmcp)" "bmcp,playwright|$(fleet_repo_conf_file $M o/b)"
eq 'window e'   "$(restartable $M "$we" '' fleetmcp)" "fleetmcp|$(fleet_repo_conf_file $M o/e)"
eq 'worktree b' "$(restartable $M '' "$wtb" fleetmcp)" "bmcp,playwright|$(fleet_repo_conf_file $M o/b)"
eq 'degenerate' "$(restartable $D '@9' '' cmcp)" "cmcp|$(fleet_conf_file $D)"
hint=$(python3 - "$BIN" "$(fleet_repo_conf_file $M o/b)" <<'PY'
import runpy, sys
from pathlib import Path
m = runpy.run_path(sys.argv[1] + '/fleet_sleep_mcp.py')
print(m['contract_hint']({'session': 'M'}, {'bmcp'}, 'x', Path(sys.argv[2])))
PY
)
has 'hint names overlay' "$hint" "FLEET_SLEEP_MCP_RESTARTABLE=bmcp,x to $(fleet_repo_conf_file $M o/b)"
leg sleep

# --- switches --------------------------------------------------------------------
out=$(bash "$BIN/fleet-cleanup-daemon.sh" --dry-run $M 2>&1)
has   'cleanup b off'        "$out" "[o/b] cleanup off (FLEET_CLEANUP=0)"
hasnt 'cleanup a runs'       "$out" "[o/a] cleanup off"
hasnt 'cleanup e runs'       "$out" "[o/e] cleanup off"
hasnt 'fleet not skipped'    "$out" "$M: cleanup off"
out=$(bash "$BIN/fleet-cleanup-daemon.sh" --dry-run $D 2>&1)
has   'cleanup degenerate'   "$out" "$D: cleanup off (FLEET_CLEANUP=0) — skip"
printf 'hi\n' | bash "$BIN/fleet-control-read.sh" message $M o-b:issue-5 >/dev/null 2>&1
eq 'bridge b off → 5' "$?" 5
printf 'hi\n' | bash "$BIN/fleet-control-read.sh" message $M o-e:issue-5 >/dev/null 2>&1; rc=$?
[ "$rc" != 5 ] || fail 'bridge e (fleet value 1) refused as off'
printf 'hi\n' | bash "$BIN/fleet-control-read.sh" message $D issue-5 >/dev/null 2>&1
eq 'bridge degenerate off → 5' "$?" 5
has 'pool a (fleet)'   "$(bash "$BIN/scratch-pool.sh" status $M 2>&1)" "want=2"
printf 'FLEET_REPO="o/a"\nFLEET_SCRATCH_POOL=0\n' > "$(fleet_repo_conf_file $M o/a)"
has 'pool a (own overlay off)' "$(bash "$BIN/scratch-pool.sh" status $M 2>&1)" "want=0"
has 'pool degenerate' "$(bash "$BIN/scratch-pool.sh" status $D 2>&1)" "want=0"
leg switches

if [ "$FAILS" -eq 0 ]; then echo "repo-settings-selftest: all PASS"; exit 0; fi
echo "repo-settings-selftest: $FAILS failure(s)"; exit 1
