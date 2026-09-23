#!/bin/bash
# fleet-repo-session-selftest.sh — every session knows its repo (issue #789).
#
# On a throwaway two-repo fleet (o/a = the fleet conf's repo, o/b = an overlay)
# plus a one-repo fleet beside it:
#   A. issue spawn: 2+ repos and no --repo → refused; --repo o/b → a window with
#      @repo=o/b and @worktree under B's checkout, self-stamped BEFORE the launcher
#      ran (the launcher saw @repo=o/b and pre-trusted B's worktree); an unhosted
#      --repo is refused.
#   B. (repo, N) dedup: B#12 does not block A#12; a second B#12 is deduped.
#   C. no-repo scratch: @norepo=1, no @repo/@worktree/@raw, cwd $HOME, launched with
#      --session-id = @norepo_sid. A repo scratch carries @repo + a worktree under
#      that repo's checkout; under current repo `all` a bare spawn is no-repo, under
#      a current repo it is that repo.
#   D. keys: fleet_origin_key is `<slug>:issue-N` in the two-repo fleet and bare in
#      the one-repo fleet; fleet_win_for_key resolves a qualified key to the RIGHT
#      repo's window; fleet_origin_canon keeps a qualified key.
#   E. restore round-trip: the snapshot writes the repo column (and `-` for the
#      no-repo session), restore brings @repo / @norepo back and resumes the no-repo
#      session by its own id in $HOME; an OLD row (no column) gets its repo derived
#      from @worktree; the one-repo fleet's rows carry no column.
#   F. degenerate: the one-repo fleet's spawn command carries no self-stamp.
#
# Every tmux call goes to a private socket via a PATH shim (never the live server);
# `gh` fails, `claude` is a recorder, and HOME / CLAUDE_CONFIG_DIR / FLEET_CONF_DIR
# are all inside the sandbox.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
REAL_TMUX="$(command -v tmux 2>/dev/null)"
[ -n "$REAL_TMUX" ] || { printf 'selftest: tmux not installed — SKIP\n' >&2; exit 0; }
command -v git >/dev/null 2>&1 || { printf 'selftest: git not installed — SKIP\n' >&2; exit 0; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/fleet-repo-session-selftest.XXXXXX")" || exit 2
WORK="$(cd "$WORK" && pwd -P)"
SOCK="$WORK/tmux.sock"
mkdir -p "$WORK/bin" "$WORK/home" "$WORK/cc" "$WORK/rec"
# Every -L/-S the scripts pass is folded onto the private socket.
cat > "$WORK/bin/tmux" <<EOF
#!/bin/bash
while [ "\${1:-}" = -L ] || [ "\${1:-}" = -S ]; do shift 2; done
exec "$REAL_TMUX" -S "$SOCK" "\$@"
EOF
printf '#!/bin/sh\nexit 1\n' > "$WORK/bin/gh"
# The agent: records its argv and what its OWN window said at launch, then idles.
cat > "$WORK/bin/claude" <<EOF
#!/bin/bash
w=\$(tmux display-message -p -t "\$TMUX_PANE" '#{window_id}')
printf '%s\n' "\$*" > "$WORK/rec/\$w.args"
tmux display-message -p -t "\$TMUX_PANE" '#{@repo}|#{@norepo}|#{@worktree}' > "$WORK/rec/\$w.seen"
pwd -P > "$WORK/rec/\$w.cwd"
exec sleep 300
EOF
chmod +x "$WORK/bin/tmux" "$WORK/bin/gh" "$WORK/bin/claude"

cleanup() { "$REAL_TMUX" -S "$SOCK" kill-server 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT
trap 'exit 130' INT TERM HUP

export PATH="$WORK/bin:$PATH" HOME="$WORK/home" CLAUDE_CONFIG_DIR="$WORK/cc"
export FLEET_CONF_DIR="$WORK/conf" FLEET_SKIP_GLOBAL_CONF=1 TMPDIR="$WORK/tmp"
export FLEET_GLOBAL_MAX_SESSIONS=999 FLEET_PRESPAWN_DEDUP=0 FLEET_SCRATCH_POOL=0
mkdir -p "$FLEET_CONF_DIR" "$TMPDIR"
unset TMUX TMUX_PANE FLEET_MULTIREPO FLEET_MAIN FLEET_REPO FLEET_BASE_BRANCH FLEET_MODEL FLEET_AGENT
. "$BIN/fleet-lib.sh"

FAILS=0
fail() { printf 'FAIL: %s\n' "$*" >&2; FAILS=$((FAILS+1)); }
ok()   { printf 'ok   %s\n' "$*"; }
eq()   { if [ "$2" = "$3" ]; then ok "$1"; else fail "$1: expected [$3], got [$2]"; fi; }

mkrepo() {   # $1=dir $2=owner/name — a checkout with one commit and an origin/master
  git init -q "$1" && git -C "$1" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init \
    && git -C "$1" branch -q -M master \
    && git -C "$1" remote add origin "https://github.com/$2.git" \
    && git -C "$1" update-ref refs/remotes/origin/master HEAD
}
mkrepo "$WORK/mainA" o/a
mkrepo "$WORK/mainB" o/b
mkrepo "$WORK/mainD" o/d

S=ft; D=fd
mkdir -p "$FLEET_CONF_DIR/fleets/$S/repos" "$FLEET_CONF_DIR/fleets/$D"
printf 'FLEET_REPO="o/a"\nFLEET_MAIN="%s"\nFLEET_BASE_BRANCH="master"\n' "$WORK/mainA" > "$FLEET_CONF_DIR/fleets/$S/conf"
printf 'FLEET_REPO="o/b"\nFLEET_MAIN="%s"\nFLEET_BASE_BRANCH="master"\n' "$WORK/mainB" > "$FLEET_CONF_DIR/fleets/$S/repos/o-b.conf"
printf 'FLEET_REPO="o/d"\nFLEET_MAIN="%s"\nFLEET_BASE_BRANCH="master"\n' "$WORK/mainD" > "$FLEET_CONF_DIR/fleets/$D/conf"

"$REAL_TMUX" -S "$SOCK" -f /dev/null new-session -d -s "$S" -n plan -x 200 -y 50 || { echo "could not start isolated tmux" >&2; exit 1; }
tmux new-session -d -s "$D" -n plan

opt()  { tmux display-message -p -t "$1" "#{$2}"; }
wait_rec() {   # $1=window-id — the recorder has run
  local i; for i in $(seq 1 100); do [ -s "$WORK/rec/$1.seen" ] && return 0; sleep 0.1; done; return 1
}
wins_for() {   # $1=sess $2=issue → window ids bound to it
  tmux list-windows -t "$1" -F '#{@issue} #{window_id}' | awk -v n="$2" '$1==n{print $2}'
}
spawn() { bash "$BIN/dash-issue-session.sh" "$@" >"$WORK/out" 2>"$WORK/err"; }
raw()   { bash "$BIN/dash-raw-session.sh" "$@" >"$WORK/out" 2>"$WORK/err"; }
newest() { tmux list-windows -t "$1" -F '#{window_id}' | tail -1; }

# ---- A. issue spawn --------------------------------------------------------------
spawn 12 "$S"; rc=$?
eq "A 2+ repos, no --repo → refused (infra)" "$rc" 1
grep -q -- '--repo' "$WORK/err" || fail "A the refusal names --repo: $(cat "$WORK/err")"
[ -z "$(wins_for "$S" 12)" ] || fail "A the refused spawn opened a window"

spawn 12 "$S" --repo o/zzz; rc=$?
eq "A an unhosted --repo → refused" "$rc" 1

spawn 12 "$S" --repo o/b || fail "A --repo o/b spawn failed: $(cat "$WORK/err")"
wB=$(wins_for "$S" 12 | head -1)
eq "A @repo stamped" "$(opt "$wB" @repo)" o/b
eq "A @worktree under B's checkout" "$(opt "$wB" @worktree)" "$WORK/mainB-issue-12"
[ -d "$WORK/mainB-issue-12" ] || fail "A B's worktree was not created"
eq "A the worktree is B's" "$(git -C "$WORK/mainB-issue-12" remote get-url origin)" https://github.com/o/b.git
case "$(opt "$wB" pane_start_command)" in *"@repo 'o/b'"*) ok "A the window self-stamps @repo" ;;
  *) fail "A the window command carries no self-stamp: $(opt "$wB" pane_start_command)" ;; esac
wait_rec "$wB" || fail "A the launcher never reached claude"
eq "A the launcher saw its own repo" "$(cat "$WORK/rec/$wB.seen" 2>/dev/null)" "o/b||$WORK/mainB-issue-12"
grep -qF "$WORK/mainB-issue-12" "$WORK/cc/.claude.json" 2>/dev/null \
  && ok "A B's worktree pre-trusted (under B's MAIN)" \
  || fail "A B's worktree was not pre-trusted: $(cat "$WORK/cc/.claude.json" 2>/dev/null)"

# ---- B. (repo, N) dedup ------------------------------------------------------------
spawn 12 "$S" --repo o/a || fail "B A#12 spawn failed: $(cat "$WORK/err")"
eq "B B#12 does not block A#12" "$(wins_for "$S" 12 | wc -l | tr -d ' ')" 2
wA=$(wins_for "$S" 12 | grep -vxF "$wB" | head -1)
eq "B A#12's repo" "$(opt "$wA" @repo)" o/a
eq "B A#12's worktree" "$(opt "$wA" @worktree)" "$WORK/mainA-issue-12"
spawn 12 "$S" --repo o/b
eq "B a second B#12 is deduped" "$(wins_for "$S" 12 | wc -l | tr -d ' ')" 2

# ---- C. no-repo + repo scratch -------------------------------------------------------
raw --no-repo "$S" || fail "C --no-repo spawn failed: $(cat "$WORK/err")"
wN=$(newest "$S")
eq "C @norepo" "$(opt "$wN" @norepo)" 1
eq "C no @repo/@worktree/@raw" "$(opt "$wN" @repo)|$(opt "$wN" @worktree)|$(opt "$wN" @raw)" "||"
wait_rec "$wN" || fail "C the no-repo launcher never reached claude"
eq "C runs in \$HOME" "$(cat "$WORK/rec/$wN.cwd" 2>/dev/null)" "$(cd "$HOME" && pwd -P)"
nsid=$(opt "$wN" @norepo_sid)
case "$nsid" in ????????-????-????-????-????????????) ok "C @norepo_sid is a uuid" ;; *) fail "C @norepo_sid: [$nsid]" ;; esac
case "$(cat "$WORK/rec/$wN.args" 2>/dev/null)" in *"--session-id $nsid"*) ok "C launched with --session-id = @norepo_sid" ;;
  *) fail "C claude args: $(cat "$WORK/rec/$wN.args" 2>/dev/null)" ;; esac
eq "C @norepo stamped before the launcher" "$(cut -d'|' -f2 "$WORK/rec/$wN.seen" 2>/dev/null)" 1

raw --repo o/b "$S" || fail "C --repo o/b scratch failed: $(cat "$WORK/err")"
wS=$(newest "$S")
eq "C repo scratch @repo" "$(opt "$wS" @repo)" o/b
case "$(opt "$wS" @worktree)" in "$WORK/mainB-scratch-"*) ok "C repo scratch worktree under B" ;;
  *) fail "C repo scratch worktree: $(opt "$wS" @worktree)" ;; esac
eq "C repo scratch @raw" "$(opt "$wS" @raw)" 1

raw "$S"; w=$(newest "$S")
eq "C current repo all → no-repo" "$(opt "$w" @norepo)" 1
fleet_current_repo_set "$S" o/b
raw "$S"; w=$(newest "$S")
eq "C current repo o/b → o/b" "$(opt "$w" @repo)" o/b
fleet_current_repo_set "$S" all

# ---- D. keys -------------------------------------------------------------------------
inpane() {   # $1=window — run the rest as if inside that window's pane
  local w="$1"; shift
  TMUX="$SOCK,1,0" TMUX_PANE="$(tmux display-message -p -t "$w" '#{pane_id}')" "$@"
}
eq "D origin key, 2+ repos (issue)" "$(inpane "$wB" fleet_origin_key)" o-b:issue-12
eq "D origin key, 2+ repos (scratch)" "$(inpane "$wS" fleet_origin_key)" "o-b:$(basename "$(opt "$wS" @worktree)" | sed 's/^mainB-//')"
eq "D origin key, no-repo session → none" "$(inpane "$wN" fleet_origin_key)" ""
eq "D qualified key → B's window" "$(fleet_win_for_key o-b:issue-12 "$S")" "$wB"
eq "D qualified key → A's window" "$(fleet_win_for_key o-a:issue-12 "$S")" "$wA"
fleet_win_for_key o-c:issue-12 "$S" >/dev/null && fail "D an unhosted slug matched a window" || ok "D an unhosted slug matches nothing"
eq "D canon keeps a qualified key" "$(fleet_origin_canon o-b:issue-12 '')" o-b:issue-12
eq "D canon folds a qualified basename" "$(fleet_origin_canon o-b:mainB-scratch-4 '')" o-b:scratch-4
eq "D canon: plain keys unchanged" "$(fleet_origin_canon cd-scratch-52 '')" scratch-52

spawn 5 "$D" || fail "D one-repo spawn failed: $(cat "$WORK/err")"
wD=$(wins_for "$D" 5 | head -1)
eq "D origin key, one-repo fleet (bare)" "$(inpane "$wD" fleet_origin_key)" issue-5
eq "D bare key still resolves" "$(fleet_win_for_key issue-5 "$D")" "$wD"

# ---- F. degenerate ---------------------------------------------------------------------
case "$(opt "$wD" pane_start_command)" in *set-option*) fail "F one-repo spawn command carries a self-stamp" ;;
  *) ok "F one-repo spawn command unchanged (no self-stamp)" ;; esac
eq "F one-repo worktree" "$(opt "$wD" @worktree)" "$WORK/mainD-issue-5"

# ---- E. restore round-trip -------------------------------------------------------------
bash "$BIN/fleet-restore.sh" --snapshot >/dev/null 2>&1
MS="$FLEET_CONF_DIR/fleets/$S/restore.map"; MD="$FLEET_CONF_DIR/fleets/$D/restore.map"
[ -f "$MS" ] || fail "E no two-repo map written"
rowB=$(awk -F'\t' -v p="$WORK/mainB-issue-12" '$1=="WIN" && $3==p' "$MS")
eq "E B row's repo column" "$(printf '%s' "$rowB" | awk -F'\t' '{print $16}')" o/b
rowN=$(awk -F'\t' '$1=="WIN" && $16=="-"' "$MS" | head -1)
[ -n "$rowN" ] || fail "E no no-repo row (column 16 = -)"
eq "E no-repo row carries its own session id" "$(printf '%s' "$rowN" | awk -F'\t' '{print $4}' | grep -c "$nsid")" 1
eq "E one-repo rows carry no repo column" "$(awk -F'\t' '$1=="WIN" && NF>15' "$MD" | wc -l | tr -d ' ')" 0

# An OLD row (pre-#789, no column 16) for B's worktree: its repo comes from @worktree.
mkdir -p "$WORK/mainB-issue-77"; git -C "$WORK/mainB" worktree add -q -b issue-77 "$WORK/mainB-issue-77" master 2>/dev/null
printf 'WIN\told-b\t%s\t-\t77\tdone\t-\t-\t-\n' "$WORK/mainB-issue-77" >> "$MS"

nameN=$(opt "$wN" window_name)
tmux kill-window -t "$wB"; tmux kill-window -t "$wN"
rm -f "$WORK/rec/"*
bash "$BIN/fleet-restore.sh" >/dev/null 2>&1
rB=$(tmux list-windows -t "$S" -F '#{@worktree} #{window_id}' | awk -v p="$WORK/mainB-issue-12" '$1==p{print $2; exit}')
rN=$(tmux list-windows -t "$S" -F '#{window_name} #{window_id}' | awk -v n="$nameN" '$1==n{print $2; exit}')
rO=$(tmux list-windows -t "$S" -F '#{window_name} #{window_id}' | awk '$1=="old-b"{print $2; exit}')
[ -n "$rB" ] && eq "E restore round-trips @repo" "$(opt "$rB" @repo)" o/b || fail "E B window not restored"
if [ -n "$rN" ]; then
  eq "E restored no-repo session keeps @norepo" "$(opt "$rN" @norepo)" 1
  wait_rec "$rN" || fail "E restored no-repo launcher never reached claude"
  case "$(cat "$WORK/rec/$rN.args" 2>/dev/null)" in *"--resume $nsid"*) ok "E no-repo session resumed by its own id" ;;
    *) fail "E no-repo resume args: $(cat "$WORK/rec/$rN.args" 2>/dev/null)" ;; esac
  eq "E no-repo session resumed in \$HOME" "$(cat "$WORK/rec/$rN.cwd" 2>/dev/null)" "$(cd "$HOME" && pwd -P)"
else
  fail "E no-repo window not restored"
fi
if [ -n "$rO" ]; then
  wait_rec "$rO" || fail "E old-row launcher never reached claude"
  eq "E old row: repo derived from @worktree before launch" "$(cut -d'|' -f1 "$WORK/rec/$rO.seen" 2>/dev/null)" o/b
else
  fail "E old row not restored"
fi

[ "$FAILS" = 0 ] && { printf 'PASS fleet-repo-session-selftest\n'; exit 0; }
printf '%s failure(s)\n' "$FAILS" >&2; exit 1
