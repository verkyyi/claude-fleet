#!/bin/bash
# fleet-node-shell-retire-selftest.sh — a managed machine is no one's client
# (issue #2702). bin/fleet on a managed machine is fleet-node-hosted-selftest.sh's A.
#   B. fleet-node-shell-retire.sh --login <me> in a sandbox home: --dry-run
#      changes nothing; the run stops every process running from the cache (a
#      TERM-ignoring one too), removes the cache, takes the first-login block and
#      the cw.zsh / fleet-login.zsh lines out of ~/.zshrc — the PATH line, a
#      comment and the person's own lines kept, the old file kept beside — and a
#      rerun is all `skip`, rc 0. --if-idle (the daemon's own run, issue #2981)
#      with the client running: rc 3, nothing changed; once nothing runs: rc 0.
#   C. another login without root → rc 2, nothing touched; no --login → rc 2.
set -uo pipefail
unset FLEET_CLIENT
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/selftest-lib.sh"
RETIRE="$here/fleet-node-shell-retire.sh"
T=$(mktemp -d "${TMPDIR:-/tmp}/fnsr.XXXXXX")
PIDS=()
cleanup() {
  for p in ${PIDS[@]+"${PIDS[@]}"}; do kill -9 "$p" 2>/dev/null; done
  rm -rf "$T"
}
trap cleanup EXIT
st_tally
ME=$(id -un)

# ---- B. the retire script ----------------------------------------------------
echo "B. fleet-node-shell-retire.sh"
U="$T/Users"; H="$U/$ME"; C="$H/.cache/claude-fleet/shell"
mkdir -p "$C/bin"
printf 'trap "" TERM\nwhile :; do sleep 1; done\n' > "$C/bin/keeper.sh"
printf 'while :; do sleep 1; done\n' > "$C/bin/loop.sh"
bash "$C/bin/keeper.sh" </dev/null >/dev/null 2>&1 & PIDS+=($!); disown $!
bash "$C/bin/loop.sh" </dev/null >/dev/null 2>&1 & PIDS+=($!); disown $!
own='alias y=yazi'
pathl='case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) export PATH="$HOME/.local/bin:$PATH";; esac  # claude-fleet: Claude Code lives in ~/.local/bin (issue #1191)'
cat > "$H/.zshrc" <<EOF
$pathl

# >>> claude-fleet (bin/fleet-login-bootstrap.sh, issue #1165) >>>
if [[ -o interactive ]]; then
  :
fi
[[ -r ~/.claude/fleet/shell/cw.zsh ]] && source ~/.claude/fleet/shell/cw.zsh
# banner, then an SSH login goes straight into the fleet (issue #1166)
[[ -r ~/.claude/fleet/shell/fleet-login.zsh ]] && source ~/.claude/fleet/shell/fleet-login.zsh
# <<< claude-fleet <<<
source ~/.claude/fleet/shell/cw.zsh
# source ~/.claude/fleet/shell/fleet-login.zsh
$own
EOF
before=$(cat "$H/.zshrc")
rt() { out=$(FLEET_NODE_USERS="$U" FLEET_RETIRE_GRACE=1 FLEET_RETIRE_QUIT_WAIT=2 bash "$RETIRE" "$@" 2>&1); rc=$?; }
rt --login "$ME" --dry-run
[ "$rc" = 0 ] && st_ok_all "dry run rc 0" || st_miss "dry run rc $rc: $out"
case "$out" in *"client: would stop 2 process(es)"*"cache: would remove"*"zshrc: would take out 9 line(s)"*"dry run — nothing changed"*) st_ok_all "dry run says what it would do" ;;
  *) st_miss "dry run said: $out" ;; esac
[ -d "$C" ] && [ "$(cat "$H/.zshrc")" = "$before" ] && kill -0 "${PIDS[0]}" 2>/dev/null \
  && st_ok_all "dry run changed nothing" || st_miss "dry run changed something"
rt --login "$ME" --if-idle
[ "$rc" = 3 ] && [ -d "$C" ] && [ "$(cat "$H/.zshrc")" = "$before" ] && kill -0 "${PIDS[0]}" 2>/dev/null \
  && case "$out" in *"left for later (--if-idle), nothing changed"*) true ;; *) false ;; esac \
  && st_ok_all "--if-idle with the client running: rc 3, nothing changed (issue #2981)" || st_miss "--if-idle rc $rc: $out"
rt --login "$ME"
[ "$rc" = 0 ] && st_ok_all "run rc 0" || st_miss "run rc $rc: $out"
case "$out" in *"client: stopped 2 process(es)"*"cache: removed $C"*"zshrc: took out 9 line(s)"*"retired: $ME"*) st_ok_all "each step said what it did" ;;
  *) st_miss "run said: $out" ;; esac
sleep 0.2
alive=0; for p in ${PIDS[@]+"${PIDS[@]}"}; do kill -0 "$p" 2>/dev/null && alive=$((alive + 1)); done
[ "$alive" = 0 ] && st_ok_all "every client process gone (the TERM-ignoring one too)" || st_miss "$alive still alive"
[ ! -e "$C" ] && st_ok_all "cache removed" || st_miss "cache still there"
[ "$(cat "$H/.zshrc")" = "$pathl

# source ~/.claude/fleet/shell/fleet-login.zsh
$own" ] && st_ok_all "zshrc: PATH line, comment and own lines kept, hooks gone" || { st_miss "zshrc now:"; cat "$H/.zshrc"; }
[ "$(cat "$H/.zshrc.pre-shell-retire")" = "$before" ] && st_ok_all "old zshrc kept beside" || st_miss "no backup"
rt --login "$ME"
[ "$rc" = 0 ] && [ "$(printf '%s\n' "$out" | grep -c ': skip — ')" = 3 ] && st_ok_all "rerun: every step skip, rc 0" || st_miss "rerun rc $rc: $out"

rt --login "$ME" --if-idle
[ "$rc" = 0 ] && st_ok_all "--if-idle once nothing runs: rc 0" || st_miss "--if-idle idle rc $rc: $out"

# the fleet's header comments an older retire left without their hook (issue #2991,
# mac-c's guest logins): the same rule the daemon's status counts takes them out
cat > "$H/.zshrc" <<'EOF'
export PATH="$HOME/.local/bin:$PATH"

# cfguest:shell — claude-fleet helpers: cf (enter/attach a fleet), cw (worktree + window)

# claude-fleet login: banner (+ machine lines from intro.d, e.g. `vnc`), then an SSH login goes straight into the fleet
EOF
rt --login "$ME" --if-idle
[ "$rc" = 0 ] && case "$out" in *"zshrc: took out 2 line(s)"*) true ;; *) false ;; esac \
  && [ "$(cat "$H/.zshrc")" = 'export PATH="$HOME/.local/bin:$PATH"' ] \
  && st_ok_all "leftover fleet header comments taken out, PATH line kept" || { st_miss "headers rc $rc: $out"; cat "$H/.zshrc"; }

# ---- C. refusals -------------------------------------------------------------
echo "C. refusals"
if [ "$(id -u)" != 0 ]; then
  mkdir -p "$U/someone-else/.cache/claude-fleet/shell"
  rt --login someone-else
  [ "$rc" = 2 ] && [ -d "$U/someone-else/.cache/claude-fleet/shell" ] && st_ok_all "another login without root → rc 2, nothing touched" \
    || st_miss "another login rc $rc: $out"
fi
rt
[ "$rc" = 2 ] && st_ok_all "no --login → rc 2" || st_miss "no --login rc $rc"

st_done
