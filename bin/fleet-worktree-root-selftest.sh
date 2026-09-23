#!/bin/bash
# fleet-worktree-root-selftest.sh — hermetic tests for the ONE worktree-path exit
# (issue #886): fleet_worktree_dir / fleet_worktree_create in bin/fleet-lib.sh, the
# FLEET_WORKTREE_ROOT conf key they read, the bin/fleet-worktree.sh shim `cw` uses,
# and the three creators that must all go through them.
#
# Why: worktrees are short-lived, but as siblings of the base checkout Spotlight
# indexed every one (92 worktrees / 77 GB on the machine that filed it). A root
# named `*.noindex` takes them out of the index — but only if EVERY creator lands
# there, which is what three hand-built path strings could not promise.
#
# Asserts:
#   DEFAULT    ROOT unset ⇒ the path is byte-identical to the historic
#              `$(dirname main)/$(basename main)-<slug>`, and issue + scratch land there.
#   ROOTED     ROOT set ⇒ issue, scratch and `cw` all land under ROOT; the basename
#              keeps its `<main>-issue-N` / `<main>-scratch-N` shape; `~/` expands;
#              the root is created on first use.
#   RECOGNISED fleet_seat reads a ROOT worktree as `worker`; fleet_scratch_key
#              resolves a ROOT scratch path to its key.
#   REUSE      --reuse checks out a surviving branch; without it `-b` failing is a
#              refusal (the scratch allocator's serialization point).
#   TRASH      a dropped ROOT worktree goes to ROOT/.fleet-trash, and
#              fleet_trash_sweep <main> empties BOTH that and the base's sibling trash.
#   SHIM       bin/fleet-worktree.sh reads FLEET_WORKTREE_ROOT from the conf of the
#              fleet owning <main>; an unowned checkout keeps the sibling layout.
#   CW         `cw` / `cwrm` (zsh) create and remove under ROOT through the shim.
#   ONE-EXIT   no fourth hand-built worktree path in bin/ or shell/.
#
# Real git, a temp HOME + FLEET_CONF_DIR, a PATH-shimmed tmux — no network, no gh,
# no live tmux server. Exit 0 = pass; non-zero = fail.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
LIB="$BIN/fleet-lib.sh"
SHIM="$BIN/fleet-worktree.sh"
CWZ="$BIN/../shell/cw.zsh"
[ -f "$LIB" ]  || { printf 'selftest: %s missing\n' "$LIB" >&2; exit 2; }
[ -x "$SHIM" ] || { printf 'selftest: %s missing/not executable\n' "$SHIM" >&2; exit 2; }
command -v git >/dev/null 2>&1 || { printf 'selftest: git not on PATH — SKIP\n' >&2; exit 0; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/fleet-wt-root.XXXXXX")" || exit 2
WORK="$(cd "$WORK" && pwd -P)"
trap 'rm -rf "$WORK"' EXIT
trap 'exit 130' INT TERM HUP

pass=0
ok()   { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
fail() { printf 'selftest FAIL: %s\n' "$1" >&2; [ -n "${2:-}" ] && printf -- '--- detail ---\n%s\n' "$2" >&2; exit 1; }

export HOME="$WORK/home"; mkdir -p "$HOME"
export FLEET_CONF_DIR="$WORK/conf"; mkdir -p "$FLEET_CONF_DIR"
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL="$WORK/home/.gitconfig"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
unset FLEET_WORKTREE_ROOT

# shellcheck source=/dev/null
. "$LIB"

MAIN="$WORK/src/repo"
mkdir -p "$WORK/src"
git init -q -b master "$MAIN" >/dev/null 2>&1 || git init -q "$MAIN" >/dev/null 2>&1 || fail "cannot git init"
git -C "$MAIN" checkout -q -B master >/dev/null 2>&1
echo seed > "$MAIN/README"
git -C "$MAIN" add README >/dev/null 2>&1
git -C "$MAIN" commit -qm seed >/dev/null 2>&1 || fail "cannot commit in $MAIN"
listed() { git -C "$MAIN" worktree list --porcelain 2>/dev/null | grep -qx "worktree $1"; }

# --- 1. DEFAULT: byte-identical to the historic string ------------------------
want="$(dirname "$MAIN")/$(basename "$MAIN")-issue-5"
got="$(fleet_worktree_dir "$MAIN" issue-5)"
[ "$got" = "$want" ] || fail "1 unset ROOT: '$got' != historic '$want'"
got="$(fleet_worktree_dir "$MAIN/" issue-5)"
[ "$got" = "$want" ] || fail "1 a trailing / on main changed the path: '$got'"
wt="$(fleet_worktree_create "$MAIN" issue-5 master)" || fail "1 create issue-5 failed"
[ "$wt" = "$want" ] && listed "$want" || fail "1 issue-5 not created at $want" "$wt"
alloc="$(fleet_scratch_alloc "$MAIN" master)" || fail "1 scratch alloc failed"
[ "$alloc" = "scratch-1	$WORK/src/repo-scratch-1" ] || fail "1 scratch alloc: '$alloc'"
listed "$WORK/src/repo-scratch-1" || fail "1 scratch-1 not in worktree list"
ok "1 ROOT unset: issue + scratch paths are byte-identical to the sibling layout"

# --- 2. ROOTED: every creator lands under ROOT, basenames unchanged -----------
export FLEET_WORKTREE_ROOT="$WORK/wt.noindex/"      # trailing / on purpose
ROOT="$WORK/wt.noindex"
[ -e "$ROOT" ] && fail "2 precondition: root exists already"
wt="$(fleet_worktree_create "$MAIN" issue-7 master)" || fail "2 create issue-7 under ROOT failed"
[ "$wt" = "$ROOT/repo-issue-7" ] || fail "2 issue-7 landed at '$wt'"
listed "$ROOT/repo-issue-7" || fail "2 issue-7 not in git worktree list"
alloc="$(fleet_scratch_alloc "$MAIN" master)" || fail "2 scratch alloc under ROOT failed"
[ "$alloc" = "scratch-2	$ROOT/repo-scratch-2" ] || fail "2 scratch alloc under ROOT: '$alloc'"
got="$(FLEET_WORKTREE_ROOT='~/wt.noindex' fleet_worktree_dir "$MAIN" issue-8)"
[ "$got" = "$HOME/wt.noindex/repo-issue-8" ] || fail "2 ~/ not expanded: '$got'"
ok "2 ROOT set: issue + scratch under ROOT (created on first use), basenames kept, ~/ expanded"

# --- 3. RECOGNISED: seat + scratch key read ROOT worktrees --------------------
tmux() { printf '7|%s\n' "$ROOT/repo-issue-7"; }     # the pane's @issue|@worktree
seat="$(cd "$ROOT/repo-issue-7" && fleet_seat)"
[ "$seat" = worker ] || fail "3 fleet_seat in a ROOT worktree = '$seat', want worker"
unset -f tmux
key="$(fleet_scratch_key "$ROOT/repo-scratch-2")"
[ "$key" = scratch-2 ] || fail "3 fleet_scratch_key on a ROOT scratch = '$key'"
ok "3 fleet_seat → worker and fleet_scratch_key → scratch-2 for ROOT worktrees"

# --- 4. REUSE vs the -b serialization point ------------------------------------
git -C "$MAIN" branch issue-9 >/dev/null 2>&1
fleet_worktree_create "$MAIN" issue-9 master >/dev/null && fail "4 without --reuse an existing branch must be refused"
[ -e "$ROOT/repo-issue-9" ] && fail "4 a refused create left a directory behind"
wt="$(fleet_worktree_create "$MAIN" issue-9 master --reuse)" || fail "4 --reuse did not check out the surviving branch"
[ "$(git -C "$wt" branch --show-current)" = issue-9 ] || fail "4 --reuse worktree is not on issue-9"
wt="$(fleet_worktree_create "$MAIN" feat-x "" --branch feat/x)" || fail "4 --branch create failed"
[ "$wt" = "$ROOT/repo-feat-x" ] && [ "$(git -C "$wt" branch --show-current)" = feat/x ] \
  || fail "4 --branch: '$wt' on '$(git -C "$wt" branch --show-current 2>&1)'"
ok "4 --reuse takes a surviving branch, plain create refuses it; --branch decouples name from slug"

# --- 5. TRASH lands under ROOT; the sweep empties both trashes ----------------
tok="$(fleet_worktree_drop "$MAIN" "$ROOT/repo-issue-9")" || fail "5 drop failed: $tok"
case "$tok" in "trashed:$ROOT/.fleet-trash/"*) ;; *) fail "5 dropped into '$tok', want $ROOT/.fleet-trash/" ;; esac
tok="$(fleet_worktree_drop "$MAIN" "$WORK/src/repo-issue-5")" || fail "5 sibling drop failed: $tok"
case "$tok" in "trashed:$WORK/src/.fleet-trash/"*) ;; *) fail "5 sibling dropped into '$tok'" ;; esac
sw="$(fleet_trash_sweep "$MAIN" 30)"
[ "$sw" = "swept:2 left:0" ] || fail "5 sweep with ROOT set = '$sw', want swept:2 (ROOT + sibling trash)"
ok "5 a ROOT worktree drops into ROOT/.fleet-trash; one sweep empties it and the sibling trash"

# --- 6. SHIM reads the owning fleet's conf ------------------------------------
unset FLEET_WORKTREE_ROOT
mkdir -p "$FLEET_CONF_DIR/fleets/fleet-x"
printf 'FLEET_MAIN="%s"\nFLEET_WORKTREE_ROOT="%s"\n' "$MAIN" "$WORK/shim.noindex" > "$FLEET_CONF_DIR/fleets/fleet-x/conf"
got="$("$SHIM" dir "$MAIN" issue-3)"
[ "$got" = "$WORK/shim.noindex/repo-issue-3" ] || fail "6 shim for an owned checkout = '$got'"
OTHER="$WORK/src/other"; git init -q "$OTHER" >/dev/null 2>&1
got="$("$SHIM" dir "$OTHER" issue-3)"
[ "$got" = "$WORK/src/other-issue-3" ] || fail "6 shim for an unowned checkout = '$got'"
ok "6 shim: owning fleet's FLEET_WORKTREE_ROOT applies; an unowned checkout stays a sibling"

# --- 7. CW / CWRM through the shim (zsh, tmux PATH-shimmed) --------------------
if command -v zsh >/dev/null 2>&1 && [ -f "$CWZ" ]; then
  mkdir -p "$WORK/fakebin"
  printf '#!/bin/sh\nexit 0\n' > "$WORK/fakebin/tmux"; chmod +x "$WORK/fakebin/tmux"
  out="$(cd "$MAIN" && env -u TMUX -u TMUX_PANE PATH="$WORK/fakebin:$PATH" zsh -fc ". '$CWZ'; cw feat/cw" 2>&1)"
  listed "$WORK/shim.noindex/repo-feat-cw" || fail "7 cw did not create under the fleet's ROOT" "$out"
  out="$(cd "$MAIN" && env -u TMUX -u TMUX_PANE PATH="$WORK/fakebin:$PATH" zsh -fc ". '$CWZ'; cwrm feat/cw" 2>&1)"
  listed "$WORK/shim.noindex/repo-feat-cw" && fail "7 cwrm did not remove the ROOT worktree" "$out"
  ok "7 cw creates and cwrm removes under the fleet's FLEET_WORKTREE_ROOT"
else
  ok "7 SKIP — no zsh"
fi

# --- 8. ONE-EXIT: no fourth hand-built worktree path ---------------------------
# `worktree add` outside fleet_worktree_create is allowed only in fleet-history.sh,
# which RE-creates a worktree at the path the resume ledger recorded (a path this
# exit produced in the first place), and in selftests.
fn="$(awk '/^fleet_worktree_create\(\) \{/{s=NR} s&&/^\}/{print s" "NR; exit}' "$LIB")"
[ -n "$fn" ] || fail "8 cannot find fleet_worktree_create in $LIB"
hits="$(cd "$BIN/.." && grep -n 'worktree add ' bin/*.sh shell/*.zsh 2>/dev/null \
  | grep -v -- '-selftest\.sh:' | grep -v '^bin/fleet-history\.sh:' \
  | grep -v '^[^:]*:[0-9]*:[[:space:]]*#' \
  | awk -F: -v r="$fn" 'BEGIN{split(r,b," ")} !($1=="bin/fleet-lib.sh" && $2>b[1] && $2<b[2])')"
[ -z "$hits" ] || fail "8 a worktree is created outside fleet_worktree_create" "$hits"
hits="$(cd "$BIN/.." && grep -nE '\$\(dirname "\$(MAIN|main)"\)/\$\(basename|/\.\./\$\{repo\}-' bin/*.sh shell/*.zsh 2>/dev/null \
  | grep -v -- '-selftest\.sh:' | grep -v '^bin/fleet-lib\.sh:')"
[ -z "$hits" ] || fail "8 a hand-built worktree path outside fleet_worktree_dir" "$hits"
ok "8 every new worktree goes through fleet_worktree_create / fleet_worktree_dir"

printf 'fleet-worktree-root selftest: %d passed\n' "$pass"
