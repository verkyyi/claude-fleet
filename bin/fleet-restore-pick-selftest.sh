#!/bin/bash
# fleet-restore-pick-selftest.sh — the task sidebar's restore picker (issue #901).
#
# Real tmux on a private socket (a PATH shim pins every bare `tmux` to it), the
# REAL fleet-restore-pick.sh → dash-restore-session.sh → fleet_bg chain, and three
# stubs: fleet-history.sh (the landed rows + a RESUME verdict), fzf (picks the row
# named by $PICK) and gh (a CLOSED PR for issue-5 when $CLOSED is set). The popup
# half — ⌃o / ⌥o / the row menu open it, @popup_open rises and falls — is pinned
# by fleet-sidebar-selftest.sh against an attached client.
#
#   A. a pick restores the session as a NEW window that is CURRENT (@restored 1)
#   B. header / filler / nothing picked → no window
#   C. an issue row with no PR → restores straight away, no gh reopen
#   D. #543: a CLOSED PR asks first — n cancels, r restores without reopen,
#      y reopens THEN restores, a failed reopen asks again (r restores, n cancels)
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
REAL_TMUX=$(command -v tmux 2>/dev/null) || { echo 'selftest SKIP: tmux missing'; exit 0; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/restore-pick-selftest.XXXXXX")" || exit 2
SOCK="$WORK/s"
cleanup() { "$REAL_TMUX" -S "$SOCK" kill-server >/dev/null 2>&1; rm -rf "$WORK"; }
trap cleanup EXIT

pass=0
ok()   { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1" >&2; [ -n "${2:-}" ] && printf -- '--- detail ---\n%s\n' "$2" >&2; exit 1; }

# --- sandbox install root: every script the shipped one but three stubs ----------
mkdir -p "$WORK/root/bin" "$WORK/path" "$WORK/conf/fleets/fleet-test" "$WORK/main/.git" "$WORK/wt"
for f in "$BIN"/*; do
  case "${f##*/}" in fleet-history.sh|fleet-claude.sh) ;; *) ln -s "$f" "$WORK/root/bin/${f##*/}" ;; esac
done
cat > "$WORK/root/bin/fleet-history.sh" <<HIST
#!/bin/bash
US=\$'\\x1f'
case "\${1:-}" in
  rows) printf 'hdr%shdr%s  issue window\n' "\$US" "\$US"
        printf 'landed:77%ssid77%s✓ #70 restored-worker\n' "\$US" "\$US"
        printf 'landed:issue:5%ssid5%s✗ #5 closed-worker\n' "\$US" "\$US" ;;
  meta) printf '%s\t%s\t-\n' "\${KEY:-70}" "\${TITLE:-restored worker}" ;;
  resume) printf 'RESUME\t%s\tsid\tclaude --resume sid --fork-session\n' "$WORK/wt" ;;
esac
HIST
printf '#!/bin/sh\nexec sleep 600\n' > "$WORK/root/bin/fleet-claude.sh"
chmod +x "$WORK/root/bin/fleet-history.sh" "$WORK/root/bin/fleet-claude.sh"
printf 'FLEET_GLOBAL_MAX_SESSIONS=0\n' > "$WORK/root/fleet.conf"
printf 'FLEET_MAIN=%s\nFLEET_REPO=example/repo\n' "$WORK/main" > "$WORK/conf/fleets/fleet-test/conf"

printf '#!/bin/sh\nexec %s -S %s "$@"\n' "$REAL_TMUX" "$SOCK" > "$WORK/path/tmux"
# fzf: print the row whose target is $PICK (none → fzf's own "no selection" = 1).
cat > "$WORK/path/fzf" <<'FZF'
#!/bin/sh
[ -n "${PICK:-}" ] || { cat >/dev/null; exit 130; }
grep -a "^$PICK$(printf '\037')" || exit 1
FZF
# gh: `pr list` prints $CLOSED (the jq already applied); `pr reopen` logs, fails on $REOPEN_FAIL.
cat > "$WORK/path/gh" <<GH
#!/bin/sh
case "\$1 \$2" in
  "pr list")   [ -n "\${CLOSED:-}" ] && printf '%s\n' "\$CLOSED"; exit 0 ;;
  "pr reopen") echo "reopen \$3" >> "$WORK/gh.log"
               [ -n "\${REOPEN_FAIL:-}" ] && { echo 'could not reopen: head branch deleted' >&2; exit 1; }
               exit 0 ;;
esac
exit 1
GH
chmod +x "$WORK/path/"*

export PATH="$WORK/path:$PATH" TMPDIR="$WORK" FLEET_CONF_DIR="$WORK/conf"
unset TMUX_PANE CLOSED REOPEN_FAIL PICK

tmux -f /dev/null new-session -d -s fleet-test -n worker 'sleep 600' || fail 'could not start the private tmux server'
export TMUX="$SOCK,1,0"
HOME_WIN=$(tmux display-message -p -t fleet-test: '#{window_id}')
PICK_SH="$WORK/root/bin/fleet-restore-pick.sh"

windows() { tmux list-windows -t fleet-test -F '#{window_id}' | wc -l | tr -d ' '; }
current() { tmux display-message -p -t fleet-test: '#{window_id}'; }
# Wait for the background restore (fleet_bg → run-shell -b) to add a window.
wait_windows() {
  local want=$1 i=0
  while [ "$i" -lt 100 ]; do [ "$(windows)" = "$want" ] && return 0; sleep 0.1; i=$((i+1)); done
  return 1
}
# Close every window but the first, and put the first back in view.
reset_windows() {
  local w
  for w in $(tmux list-windows -t fleet-test -F '#{window_id}'); do
    [ "$w" = "$HOME_WIN" ] || tmux kill-window -t "$w"
  done
  tmux select-window -t "$HOME_WIN"; rm -f "$WORK/gh.log"
}
# No window may appear — give a stray background restore time to land first.
assert_no_restore() {
  sleep 1.5
  [ "$(windows)" = 1 ] || fail "$1" "$(tmux list-windows -t fleet-test)"
}

# --- A. pick → restored, current ---------------------------------------------------
PICK=landed:77 bash "$PICK_SH" --pick --session fleet-test </dev/null
wait_windows 2 || fail 'A: picking a landed row did not bring a window back' "$(tmux list-windows -t fleet-test)"
new=$(tmux list-windows -t fleet-test -F '#{window_id}' | grep -vxF "$HOME_WIN")
# The window exists before dash-restore-session.sh stamps it; wait for the stamp.
i=0; while [ "$i" -lt 50 ] && [ "$(tmux show-options -wqv -t "$new" @restored)" != 1 ]; do sleep 0.1; i=$((i+1)); done
[ "$(tmux show-options -wqv -t "$new" @restored)" = 1 ] || fail 'A: the new window is not marked restored'
[ "$(current)" = "$new" ] || fail 'A: the restored window is not the current one'
[ "$(tmux display-message -p -t "$new" '#{window_name}')" = restored-worker ] \
  || fail 'A: the restored window lost its ledger name' "$(tmux display-message -p -t "$new" '#{window_name}')"
ok 'A  a pick restores the session as the CURRENT window'
reset_windows

# --- B. nothing to restore ---------------------------------------------------------
bash "$PICK_SH" --pick --session fleet-test </dev/null
PICK=hdr bash "$PICK_SH" --pick --session fleet-test </dev/null
bash "$PICK_SH" --select none --session fleet-test </dev/null
assert_no_restore 'B: an esc / the header / the filler row restored something'
ok 'B  esc, the header and the filler row restore nothing'

# --- C. a PR-less issue row, no closed PR: no question ----------------------------
KEY=5 TITLE='closed worker' bash "$PICK_SH" --select landed:issue:5 --session fleet-test </dev/null >"$WORK/out" 2>&1
wait_windows 2 || fail 'C: an issue row with no PR was not restored' "$(cat "$WORK/out")"
grep -q 'reopen' "$WORK/out" && fail 'C: asked about a PR that does not exist' "$(cat "$WORK/out")"
[ -e "$WORK/gh.log" ] && fail 'C: reopened a PR that does not exist'
ok 'C  an issue row without a closed PR restores straight away'
reset_windows

# --- D. #543: a CLOSED PR asks first -----------------------------------------------
export CLOSED=12 KEY=5 TITLE='closed worker'
printf 'n' | bash "$PICK_SH" --select landed:issue:5 --session fleet-test >"$WORK/out" 2>&1
grep -q 'PR #12 已关闭' "$WORK/out" || fail 'D: a closed PR did not ask before restoring' "$(cat "$WORK/out")"
assert_no_restore 'D: n (cancel) still restored'
[ -e "$WORK/gh.log" ] && fail 'D: n (cancel) reopened the PR'
ok 'D1 a closed PR asks first; n cancels'

printf 'r' | bash "$PICK_SH" --select landed:issue:5 --session fleet-test >"$WORK/out" 2>&1
wait_windows 2 || fail 'D: r did not restore' "$(cat "$WORK/out")"
[ -e "$WORK/gh.log" ] && fail 'D: r (restore anyway) reopened the PR'
ok 'D2 r restores without reopening'
reset_windows

printf 'y' | bash "$PICK_SH" --select landed:issue:5 --session fleet-test >"$WORK/out" 2>&1
wait_windows 2 || fail 'D: y did not restore after the reopen' "$(cat "$WORK/out")"
[ "$(cat "$WORK/gh.log" 2>/dev/null)" = 'reopen 12' ] || fail 'D: y did not reopen PR #12' "$(cat "$WORK/gh.log" 2>/dev/null)"
ok 'D3 y reopens the PR, then restores'
reset_windows

printf 'yn' | REOPEN_FAIL=1 bash "$PICK_SH" --select landed:issue:5 --session fleet-test >"$WORK/out" 2>&1
grep -q 'reopen 失败：could not reopen' "$WORK/out" || fail 'D: a failed reopen was not reported' "$(cat "$WORK/out")"
assert_no_restore 'D: a failed reopen + n still restored'
printf 'yr' | REOPEN_FAIL=1 bash "$PICK_SH" --select landed:issue:5 --session fleet-test >"$WORK/out" 2>&1
wait_windows 2 || fail 'D: a failed reopen + r did not restore' "$(cat "$WORK/out")"
ok 'D4 a failed reopen says why and asks again (r restores, n cancels)'
reset_windows
unset CLOSED

echo "fleet-restore-pick-selftest: all $pass passed"
