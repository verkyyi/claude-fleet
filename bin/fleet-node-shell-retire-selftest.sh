#!/bin/bash
# fleet-node-shell-retire-selftest.sh — a managed machine is no one's client
# (issue #2702):
#   A. bin/fleet on a managed machine (FLEET_NODE_STATE/machine.env): `fleet` and
#      `fleet <machine>` say where the client runs and take the client's road
#      (issue #2720 — stopping here at the terminal check, rc 2); `fleet claude` /
#      `fleet codex` answer one line, exit 3; an old client cache left here adds
#      the retire line; `--help` is untouched; the test identity and
#      FLEET_NODE_CLIENT=1 take the device client's road with no line; an
#      unmanaged machine is byte for byte what it was (rc 2, the terminal line).
#   B. fleet-node-shell-retire.sh --login <me> in a sandbox home: --dry-run
#      changes nothing; the run stops every process running from the cache (a
#      TERM-ignoring one too), removes the cache, takes the first-login block and
#      the cw.zsh / fleet-login.zsh lines out of ~/.zshrc — the PATH line, a
#      comment and the person's own lines kept, the old file kept beside — and a
#      rerun is all `skip`, rc 0. --if-idle (the daemon's own run, issue #2981)
#      with the client running: rc 3, nothing changed; once nothing runs: rc 0.
#   C. another login without root → rc 2, nothing touched; no --login → rc 2.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
FLEET="$here/fleet"
RETIRE="$here/fleet-node-shell-retire.sh"
T=$(mktemp -d "${TMPDIR:-/tmp}/fnsr.XXXXXX")
PIDS=()
cleanup() {
  for p in ${PIDS[@]+"${PIDS[@]}"}; do kill -9 "$p" 2>/dev/null; done
  rm -rf "$T"
}
trap cleanup EXIT
fail=0
ok()  { echo "  ok: $*"; }
bad() { echo "  FAIL: $*"; fail=1; }
ME=$(id -un)

# ---- A. bin/fleet ------------------------------------------------------------
# (the client a `fleet` typed there opens, issue #2720: fleet-node-hosted-selftest.sh)
echo "A. bin/fleet on a managed machine"
mkdir -p "$T/managed" "$T/unmanaged" "$T/home"
: > "$T/managed/machine.env"
# fl <state dir> <args…> → $out (stderr+stdout), $rc
fl() {
  local st=$1; shift
  out=$(env -u FLEET_CLIENT_IDENTITY -u FLEET_NODE_CLIENT HOME="$T/home" XDG_CACHE_HOME="$T/home/.cache" \
        FLEET_NODE_STATE="$st" FLEET_NODE_RUNTIME="$T/no-runtime" FLEET_CLIENT_UPDATED=1 \
        ${FL_ENV:-} sh "$FLEET" "$@" </dev/null 2>&1); rc=$?
}
for args in "" "m4"; do
  # shellcheck disable=SC2086  # the words are the command line
  fl "$T/managed" $args
  [ "$rc" = 2 ] && ok "fleet $args → the client's road (rc 2: no terminal here)" || bad "fleet $args → rc $rc: $out"
  case "$out" in "fleet · 客户端在 "*" 上运行；平时请在自己设备上用 fleet"*) ok "  … says where it runs, first" ;; *) bad "  … said: $out" ;; esac
done
for args in "claude" "codex hello"; do
  # shellcheck disable=SC2086
  fl "$T/managed" $args
  [ "$rc" = 3 ] && ok "fleet $args → exit 3" || bad "fleet $args → rc $rc: $out"
done
[ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = 1 ] && ok "one line" || bad "lines: $out"
mkdir -p "$T/home/.cache/claude-fleet/shell"
fl "$T/managed"
case "$out" in *"留着旧的常驻客户端（$T/home/.cache/claude-fleet/shell）："*"fleet-node-shell-retire.sh --login $ME"*) ok "an old client left here → the retire line" ;;
  *) bad "leftover hint: $out" ;; esac
rm -rf "$T/home/.cache"
fl "$T/managed" --help
[ "$rc" = 0 ] && ok "fleet --help untouched" || bad "--help rc $rc"
FL_ENV="FLEET_CLIENT_IDENTITY=test" fl "$T/managed"
[ "$rc" = 2 ] && case "$out" in *"客户端在 "*) false ;; *) true ;; esac \
  && ok "the test identity: the device client's road, no line" || bad "test identity rc $rc: $out"
FL_ENV="FLEET_NODE_CLIENT=1" fl "$T/managed"
[ "$rc" = 2 ] && case "$out" in *"客户端在 "*) false ;; *) true ;; esac \
  && ok "FLEET_NODE_CLIENT=1: the device client's road, no line" || bad "hatch rc $rc: $out"
fl "$T/unmanaged"
[ "$rc" = 2 ] && case "$out" in *"客户端要在终端里运行"*) true ;; *) false ;; esac \
  && ok "unmanaged machine: as before (rc 2, the terminal line)" || bad "unmanaged rc $rc: $out"

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
[ "$rc" = 0 ] && ok "dry run rc 0" || bad "dry run rc $rc: $out"
case "$out" in *"client: would stop 2 process(es)"*"cache: would remove"*"zshrc: would take out 9 line(s)"*"dry run — nothing changed"*) ok "dry run says what it would do" ;;
  *) bad "dry run said: $out" ;; esac
[ -d "$C" ] && [ "$(cat "$H/.zshrc")" = "$before" ] && kill -0 "${PIDS[0]}" 2>/dev/null \
  && ok "dry run changed nothing" || bad "dry run changed something"
rt --login "$ME" --if-idle
[ "$rc" = 3 ] && [ -d "$C" ] && [ "$(cat "$H/.zshrc")" = "$before" ] && kill -0 "${PIDS[0]}" 2>/dev/null \
  && case "$out" in *"left for later (--if-idle), nothing changed"*) true ;; *) false ;; esac \
  && ok "--if-idle with the client running: rc 3, nothing changed (issue #2981)" || bad "--if-idle rc $rc: $out"
rt --login "$ME"
[ "$rc" = 0 ] && ok "run rc 0" || bad "run rc $rc: $out"
case "$out" in *"client: stopped 2 process(es)"*"cache: removed $C"*"zshrc: took out 9 line(s)"*"retired: $ME"*) ok "each step said what it did" ;;
  *) bad "run said: $out" ;; esac
sleep 0.2
alive=0; for p in ${PIDS[@]+"${PIDS[@]}"}; do kill -0 "$p" 2>/dev/null && alive=$((alive + 1)); done
[ "$alive" = 0 ] && ok "every client process gone (the TERM-ignoring one too)" || bad "$alive still alive"
[ ! -e "$C" ] && ok "cache removed" || bad "cache still there"
[ "$(cat "$H/.zshrc")" = "$pathl

# source ~/.claude/fleet/shell/fleet-login.zsh
$own" ] && ok "zshrc: PATH line, comment and own lines kept, hooks gone" || { bad "zshrc now:"; cat "$H/.zshrc"; }
[ "$(cat "$H/.zshrc.pre-shell-retire")" = "$before" ] && ok "old zshrc kept beside" || bad "no backup"
rt --login "$ME"
[ "$rc" = 0 ] && [ "$(printf '%s\n' "$out" | grep -c ': skip — ')" = 3 ] && ok "rerun: every step skip, rc 0" || bad "rerun rc $rc: $out"

rt --login "$ME" --if-idle
[ "$rc" = 0 ] && ok "--if-idle once nothing runs: rc 0" || bad "--if-idle idle rc $rc: $out"

# the fleet's header comments an older retire left without their hook (issue #2991,
# macmini's guest logins): the same rule the daemon's status counts takes them out
cat > "$H/.zshrc" <<'EOF'
export PATH="$HOME/.local/bin:$PATH"

# cfguest:shell — claude-fleet helpers: cf (enter/attach a fleet), cw (worktree + window)

# claude-fleet login: banner (+ machine lines from intro.d, e.g. `vnc`), then an SSH login goes straight into the fleet
EOF
rt --login "$ME" --if-idle
[ "$rc" = 0 ] && case "$out" in *"zshrc: took out 2 line(s)"*) true ;; *) false ;; esac \
  && [ "$(cat "$H/.zshrc")" = 'export PATH="$HOME/.local/bin:$PATH"' ] \
  && ok "leftover fleet header comments taken out, PATH line kept" || { bad "headers rc $rc: $out"; cat "$H/.zshrc"; }

# ---- C. refusals -------------------------------------------------------------
echo "C. refusals"
if [ "$(id -u)" != 0 ]; then
  mkdir -p "$U/someone-else/.cache/claude-fleet/shell"
  rt --login someone-else
  [ "$rc" = 2 ] && [ -d "$U/someone-else/.cache/claude-fleet/shell" ] && ok "another login without root → rc 2, nothing touched" \
    || bad "another login rc $rc: $out"
fi
rt
[ "$rc" = 2 ] && ok "no --login → rc 2" || bad "no --login rc $rc"

[ "$fail" -eq 0 ] && echo "PASS: fleet-node-shell-retire-selftest" || echo "FAIL: fleet-node-shell-retire-selftest"
exit "$fail"
