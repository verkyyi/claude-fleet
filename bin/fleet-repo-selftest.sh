#!/bin/bash
# fleet-repo-selftest.sh — the repos a fleet can host (issue #788).
#
# Pins the foundation every multi-repo slice builds on:
#   A. DEGENERATE — with no repos/ dir, fleet_load_conf yields byte-identical env
#      to the pre-#788 body, and makes NO tmux call (even inside a pane).
#   B. fleet-repo.sh add REFUSES without=1; with it, writes the
#      overlay; list shows both repos; a duplicate add is refused.
#   C. helpers — fleet_repos, fleet_repo_hosted, fleet_load_repo_conf,
#      fleet_current_repo/_set, fleet_repo_mains.
#   D. window-aware fleet_load_conf — a pane whose window has @repo=B sees B's
#      MAIN/base/model, and the conf repo's deploy keys do not leak into it; @repo
#      derived once from @worktree and stamped; @norepo and unknown windows keep
#      the fleet conf; a one-repo fleet's window resolves to its only repo.
#   E. base-readonly guard — refuses an edit in B's base checkout (and A's), allows
#      the worktree, including when the seat exports FLEET_MAIN=A.
#   F. remove — refused while a live window belongs to the repo, --force removes.
#
# Every tmux call goes to a private socket via a PATH shim (never the live
# server); `gh` is shimmed to fail so nothing touches the network.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
REAL_TMUX="$(command -v tmux 2>/dev/null)"
[ -n "$REAL_TMUX" ] || { printf 'selftest: tmux not installed — SKIP\n' >&2; exit 0; }
command -v git >/dev/null 2>&1 || { printf 'selftest: git not installed — SKIP\n' >&2; exit 0; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/fleet-repo-selftest.XXXXXX")" || exit 2
WORK="$(cd "$WORK" && pwd -P)"
SOCK="$WORK/tmux.sock"
mkdir -p "$WORK/bin"
cat > "$WORK/bin/tmux" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$WORK/tmux.calls"
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
unset TMUX TMUX_PANE FLEET_MAIN FLEET_REPO FLEET_BASE_BRANCH FLEET_MODEL FLEET_DEPLOY_REF FLEET_GLOBAL_MAX_SESSIONS
. "$BIN/fleet-lib.sh"

FAILS=0
fail() { printf 'FAIL: %s\n' "$*" >&2; FAILS=$((FAILS+1)); }
eq()   { [ "$2" = "$3" ] || fail "$1: expected [$3], got [$2]"; }

mkrepo() {   # $1=dir $2=owner/name
  git init -q "$1" && git -C "$1" remote add origin "https://github.com/$2.git"
}
mkrepo "$WORK/mainA" o/a
mkrepo "$WORK/mainB" o/b
mkrepo "$WORK/wtB"   o/b     # stands in for B's issue worktree

S=ft
mkdir -p "$FLEET_CONF_DIR/fleets/$S"
cat > "$FLEET_CONF_DIR/fleets/$S/conf" <<EOF
FLEET_REPO="o/a"
FLEET_MAIN="$WORK/mainA"
FLEET_BASE_BRANCH="master"
FLEET_MODEL="opus"
FLEET_DEPLOY_REF="~/deployed-a"
FLEET_GLOBAL_MAX_SESSIONS=99
EOF

"$REAL_TMUX" -S "$SOCK" new-session -d -s "$S" -n plan -x 200 -y 50 || { echo "could not start isolated tmux" >&2; exit 1; }
paneOf() { tmux display-message -p -t "$S:$1" '#{pane_id}'; }
tmux new-window -d -t "$S" -n wB
tmux new-window -d -t "$S" -n wWT
tmux new-window -d -t "$S" -n wNO
tmux new-window -d -t "$S" -n wUNK
tmux set-option -w -t "$S:wB"  @repo o/b
tmux set-option -w -t "$S:wWT" @worktree "$WORK/wtB"
tmux set-option -w -t "$S:wNO" @norepo 1

# in_pane <window> <cmd…> — run as if inside that window's pane.
in_pane() { local w="$1"; shift; ( export TMUX="$SOCK,1,0" TMUX_PANE; TMUX_PANE=$(paneOf "$w"); "$@" ); }
envdump() { ( set -o posix; set ) | grep -E '^FLEET_(REPO|MAIN|BASE_BRANCH|MODEL|DEPLOY_REF|GLOBAL_MAX_SESSIONS)='; }

# --- A. degenerate: no repos/ dir ------------------------------------------------
ref_load() {   # the pre-#788 fleet_load_conf body, verbatim
  local conf; conf=$(fleet_conf_file "$1")
  [ -f "$conf" ] || return 0
  local _ore; _ore=$(printf '%s' "$_FLEET_GLOBAL_ONLY" | tr ' ' '|')
  eval "$(grep -Ev "^[[:space:]]*(export[[:space:]]+)?(${_ore})=" "$conf")"
  return 0
}
want=$( ref_load "$S"; envdump )
: > "$WORK/tmux.calls"
got=$( in_pane wB bash -c '. "$1"; fleet_load_conf "$2"; ( set -o posix; set ) | grep -E "^FLEET_(REPO|MAIN|BASE_BRANCH|MODEL|DEPLOY_REF|GLOBAL_MAX_SESSIONS)="' _ "$BIN/fleet-lib.sh" "$S" )
calls=$(grep -c 'display-message -p -t %' "$WORK/tmux.calls" 2>/dev/null || true)
eq "A: degenerate in-pane env byte-identical" "$got" "$want"
eq "A: degenerate makes no tmux lookup" "${calls:-0}" 0
eq "A: fleet_repos (one repo)" "$(fleet_repos "$S")" "o/a"
eq "A: one-repo fleet window resolves to its only repo" "$(fleet_window_repo "$S" "$S:wUNK")" "o/a"
eq "A: ...and is not stamped" "$(tmux display-message -p -t "$S:wUNK" '#{@repo}')" ""

# --- B. add: gate, then write ------------------------------------------------------
# No gate since #795: is gone, an unset one no longer refuses.
out=$(bash "$BIN/fleet-repo.sh" add --session "$S" o/b "$WORK/mainB" --base main 2>&1) \
  || fail "B: add failed: $out"
f="$FLEET_CONF_DIR/fleets/$S/repos/o-b.conf"
[ -f "$f" ] || fail "B: overlay not written at $f"
printf 'FLEET_MODEL="sonnet"\n' >> "$f"
bash "$BIN/fleet-repo.sh" add --session "$S" o/b "$WORK/mainB" >/dev/null 2>&1 \
  && fail "B: duplicate add accepted"
bash "$BIN/fleet-repo.sh" add --session "$S" o/c "$WORK/mainA" >/dev/null 2>&1 \
  && fail "B: add accepted a checkout of a different repo"
list=$(bash "$BIN/fleet-repo.sh" list --session "$S")
case "$list" in *"o/a"*"main=$WORK/mainA"*"o/b"*"main=$WORK/mainB"*"base=main"*) ;; *) fail "B: list: $list" ;; esac

# --- C. helpers --------------------------------------------------------------------
eq "C: fleet_repos" "$(fleet_repos "$S" | tr '\n' ' ')" "o/a o/b "
fleet_repo_hosted "$S" https://github.com/o/b.git || fail "C: o/b (URL form) not hosted"
fleet_repo_hosted "$S" o/zzz && fail "C: o/zzz reported hosted"
got=$( fleet_load_repo_conf "$S" o/b; printf '%s|%s|%s|%s|%s' "$FLEET_REPO" "$FLEET_MAIN" "$FLEET_BASE_BRANCH" "$FLEET_MODEL" "${FLEET_DEPLOY_REF:-}" )
eq "C: fleet_load_repo_conf B" "$got" "o/b|$WORK/mainB|main|sonnet|"
got=$( fleet_load_repo_conf "$S" o/a; printf '%s|%s|%s' "$FLEET_MAIN" "$FLEET_MODEL" "$FLEET_DEPLOY_REF" )
eq "C: fleet_load_repo_conf A" "$got" "$WORK/mainA|opus|~/deployed-a"
( fleet_load_repo_conf "$S" o/zzz ) && fail "C: fleet_load_repo_conf accepted an unhosted repo"
eq "C: current repo default" "$(fleet_current_repo "$S")" all
fleet_current_repo_set "$S" o/b || fail "C: set o/b refused"
eq "C: current repo set" "$(fleet_current_repo "$S")" o/b
fleet_current_repo_set "$S" o/zzz && fail "C: set to an unhosted repo accepted"
fleet_current_repo_set "$S" all
eq "C: fleet_repo_mains" "$(fleet_repo_mains "$S" | tr '\n' ' ')" "$WORK/mainA $WORK/mainB "

# --- D. window-aware fleet_load_conf ------------------------------------------------
lc() { in_pane "$1" bash -c '. "$1"; fleet_load_conf "$2"; printf "%s|%s|%s|%s|%s|%s" "$FLEET_REPO" "$FLEET_MAIN" "$FLEET_BASE_BRANCH" "$FLEET_MODEL" "${FLEET_DEPLOY_REF:-}" "${FLEET_GLOBAL_MAX_SESSIONS:-}"' _ "$BIN/fleet-lib.sh" "$S"; }
eq "D: @repo=B pane sees B" "$(lc wB)" "o/b|$WORK/mainB|main|sonnet||"
eq "D: @worktree-derived pane sees B" "$(lc wWT)" "o/b|$WORK/mainB|main|sonnet||"
eq "D: ...and @repo was stamped" "$(tmux display-message -p -t "$S:wWT" '#{@repo}')" o/b
eq "D: @norepo pane keeps the fleet conf" "$(lc wNO)" "o/a|$WORK/mainA|master|opus|~/deployed-a|"
eq "D: unknown window keeps the fleet conf" "$(lc wUNK)" "o/a|$WORK/mainA|master|opus|~/deployed-a|"
eq "D: unknown window in a 2-repo fleet resolves to nothing" "$(fleet_window_repo "$S" "$S:wUNK")" ""
eq "D: @norepo resolves to nothing" "$(fleet_window_repo "$S" "$S:wNO")" ""
got=$( in_pane wB bash -c '. "$1"; fleet_load_conf other; printf "%s" "${FLEET_MAIN:-}"' _ "$BIN/fleet-lib.sh" )
eq "D: loading ANOTHER fleet's conf from a pane is not window-aware" "$got" ""
got=$( fleet_load_conf "$S"; printf '%s' "$FLEET_MAIN" )
eq "D: outside tmux fleet_load_conf is the fleet conf" "$got" "$WORK/mainA"
got=$( in_pane wB bash "$BIN/fleet-hook-conf.sh" FLEET_MAIN FLEET_BASE_BRANCH | tr '\n' '|' )
eq "D: fleet-hook-conf.sh in a B pane" "$got" "$WORK/mainB|main|"

# --- E. base-readonly guard ---------------------------------------------------------
guard() {   # $1=window $2=path [$3=FLEET_MAIN env] → exit code
  printf '{"tool_name":"Edit","tool_input":{"file_path":"%s"}}' "$2" \
    | in_pane "$1" env FLEET_LIB="$BIN/fleet-lib.sh" FLEET_MAIN="${3:-}" \
        python3 "$BIN/../hooks/base-readonly-guard.py" >/dev/null 2>&1
  echo $?
}
if command -v python3 >/dev/null 2>&1; then
  eq "E: edit in B's base (A pane) blocked" "$(guard wUNK "$WORK/mainB/x.txt")" 2
  eq "E: edit in A's base (B pane) blocked" "$(guard wB "$WORK/mainA/x.txt")" 2
  eq "E: edit in B's base with FLEET_MAIN=A exported blocked" "$(guard wUNK "$WORK/mainB/x.txt" "$WORK/mainA")" 2
  eq "E: edit in the worktree allowed" "$(guard wB "$WORK/wtB/x.txt")" 0
fi

# --- F. remove ----------------------------------------------------------------------
bash "$BIN/fleet-repo.sh" remove --session "$S" o/b >/dev/null 2>&1 && fail "F: remove with live @repo windows accepted"
[ -f "$f" ] || fail "F: refused remove deleted the overlay"
bash "$BIN/fleet-repo.sh" remove --session "$S" o/a >/dev/null 2>&1 && fail "F: removed the fleet conf's own repo"
bash "$BIN/fleet-repo.sh" remove --session "$S" o/b --force >/dev/null 2>&1 || fail "F: --force remove failed"
eq "F: after remove" "$(fleet_repos "$S")" "o/a"

[ "$FAILS" -eq 0 ] && { echo "fleet-repo-selftest: PASS"; exit 0; }
echo "fleet-repo-selftest: $FAILS failure(s)" >&2; exit 1
