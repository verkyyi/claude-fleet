#!/bin/bash
# fleet-heavy-selftest.sh — the machine-wide heavy-job queue (issue #1295):
# bin/fleet-heavy.sh (flock counting semaphore) + the hooks/bash-guard.py rail
# that prefixes it onto heavy Bash statements.
#
#   semaphore   6 concurrent `-- sleep 2` never exceed 3 held; a SIGKILLed holder
#               frees its slot at once; --wait times out into a WARN and runs
#               anyway; exit codes pass through; FLEET_HEAVY=0 / nested holders
#               pass straight through; two logins (two HOMEs) share one slot set;
#               the shared dir is 1777 and slot files 0666.
#   hook        rewrites only a statement whose COMMAND matches FLEET_HEAVY_RE,
#               as a pure prefix (quotes, heredoc bodies, pipes, && chains keep
#               every byte); FLEET_HEAVY=0 (env / settings / inline) and non-fleet
#               panes are left alone; the default regex is in lockstep with
#               fleet-lib.sh.
#
# Hermetic: FLEET_HEAVY_DIR points the slots at a temp dir, HOME/FLEET_CONF_DIR
# are temp, no tmux. python3 absent → SKIP.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
HEAVY="$BIN/fleet-heavy.sh"
GUARD="$BIN/../hooks/bash-guard.py"
PY="$(command -v python3 2>/dev/null)"
[ -n "$PY" ] || { echo "selftest: python3 not installed — SKIP" >&2; exit 0; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/fleet-heavy-selftest.XXXXXX")" || exit 2
trap 'rm -rf "$TMP"' EXIT INT TERM
export FLEET_SKIP_GLOBAL_CONF=1 FLEET_CONF_DIR="$TMP/conf" HOME="$TMP/home"
mkdir -p "$FLEET_CONF_DIR" "$HOME"
unset FLEET_HEAVY FLEET_HEAVY_SLOTS FLEET_HEAVY_WAIT FLEET_HEAVY_RE FLEET_HEAVY_HELD TMUX TMUX_PANE FLEET_MAIN

fails=0
ok()   { printf 'ok   %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1" >&2; fails=$((fails + 1)); }
eq()   { if [ "$2" = "$3" ]; then ok "$1"; else fail "$1"; printf '  want: %s\n  got:  %s\n' "$2" "$3" >&2; fi; }
has()  { case "$3" in *"$2"*) ok "$1" ;; *) fail "$1"; printf '  want substring: %s\n  in: %s\n' "$2" "$3" >&2 ;; esac; }
hasnt(){ case "$3" in *"$2"*) fail "$1"; printf '  unwanted: %s\n  in: %s\n' "$2" "$3" >&2 ;; *) ok "$1" ;; esac; }
held_now() { "$HEAVY" --status 2>/dev/null | sed -n '1s/^heavy: \([0-9]*\)\/.*/\1/p'; }
wait_held() {  # wait_held <n> — up to ~5s for <n> slots to be held
  local i=0; while [ "$i" -lt 50 ]; do [ "$(held_now)" = "$1" ] && return 0; sleep 0.1; i=$((i + 1)); done; return 1
}

# ---------------------------------------------------------------- semaphore
export FLEET_HEAVY_DIR="$TMP/shared/heavy"

for i in 1 2 3 4 5 6; do "$HEAVY" --label "demo$i" -- sleep 2 2>/dev/null & done
peak=0; n=0
while [ "$n" -lt 60 ]; do
  h="$(held_now)"; [ -n "$h" ] && [ "$h" -gt "$peak" ] && peak="$h"
  sleep 0.1; n=$((n + 1))
done
wait
[ "$peak" -le 3 ] && [ "$peak" -ge 2 ] && ok "6 concurrent → peak held $peak ≤ 3" || fail "6 concurrent → peak held $peak (want 2..3)"
eq "all 6 ran" 6 "$(grep -c '	acquire	' "$FLEET_HEAVY_DIR/events.log")"
logpeak="$(sed -n 's/.*held=\([0-9]*\).*/\1/p' "$FLEET_HEAVY_DIR/events.log" | sort -n | tail -1)"
eq "event log never records held > 3" 3 "$logpeak"
eq "shared dir is 1777" drwxrwxrwt "$(ls -ld "$FLEET_HEAVY_DIR" | cut -c1-10)"
eq "parent dir is 1777" drwxrwxrwt "$(ls -ld "$TMP/shared" | cut -c1-10)"
eq "slot file is 0666" -rw-rw-rw- "$(ls -l "$FLEET_HEAVY_DIR/slot-1" | cut -c1-10)"

# SIGKILL the holder → the slot is free immediately.
"$HEAVY" --slots 1 --label victim -- sh -c "echo \$\$ > '$TMP/victim.pid'; exec sleep 30" 2>/dev/null &
holder=$!
wait_held 1 || fail "victim never took the slot"
kill -9 "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
err="$("$HEAVY" --slots 1 --wait 0 --label next -- true 2>&1)"; rc=$?
eq "after SIGKILL of holder: next runs" 0 "$rc"
hasnt "after SIGKILL of holder: no timeout WARN" "WARN" "$err"
kill "$(cat "$TMP/victim.pid" 2>/dev/null)" 2>/dev/null

# --wait expires → WARN, runs anyway, does not wait for the holder.
"$HEAVY" --slots 1 --label hog -- sleep 4 2>/dev/null &
hog=$!
wait_held 1 || fail "hog never took the slot"
t0=$SECONDS
out="$("$HEAVY" --slots 1 --wait 1 --label late -- echo RAN 2>"$TMP/late.err")"; rc=$?
eq "--wait timeout: command still runs" "RAN/0" "$out/$rc"
has "--wait timeout: WARN on stderr" "WARN waited 1s" "$(cat "$TMP/late.err")"
has "--wait timeout: names the holder" "hog(" "$(cat "$TMP/late.err")"
[ $((SECONDS - t0)) -lt 4 ] && ok "--wait timeout: did not wait out the holder" || fail "--wait timeout waited the holder out"
has "--wait timeout: logged" "	timeout	" "$(cat "$FLEET_HEAVY_DIR/events.log")"
has "--status shows the holder" "hog" "$("$HEAVY" --slots 1 --status)"

# Another login (another HOME) shares the same slots.
out="$(HOME="$TMP/other-login" "$HEAVY" --slots 1 --wait 0 --label other -- true 2>&1)"
has "other HOME queues behind the same slot" "WARN waited 0s" "$out"
kill "$hog" 2>/dev/null; wait "$hog" 2>/dev/null

eq "exit code passes through" 7 "$("$HEAVY" -- sh -c 'exit 7' 2>/dev/null; echo $?)"
eq "stdin reaches the command" hello "$(printf hello | "$HEAVY" -- cat)"
eq "missing command → 127" 127 "$("$HEAVY" -- /nonexistent/xyz 2>/dev/null; echo $?)"
before="$(wc -l < "$FLEET_HEAVY_DIR/events.log")"
FLEET_HEAVY=0 "$HEAVY" -- true
FLEET_HEAVY_HELD=1 "$HEAVY" -- true
eq "FLEET_HEAVY=0 / nested holder take no slot" "$before" "$(wc -l < "$FLEET_HEAVY_DIR/events.log")"
eq "nested holder sees FLEET_HEAVY_HELD=1" 1 "$("$HEAVY" -- sh -c 'echo $FLEET_HEAVY_HELD')"
"$HEAVY" --bogus -- true 2>/dev/null; eq "unknown option → exit 2" 2 "$?"

# ---------------------------------------------------------------- hook
WRAP="$HEAVY"
QW="$("$PY" -c 'import shlex,sys;print(shlex.quote(sys.argv[1]))' "$WRAP")"
# rewrite <cmd> [extra tool_input json] → the rewritten command, or "" when none.
rewrite() {
  "$PY" - "$1" "${2:-}" <<'PY' | FLEET_HEAVY_BIN="$WRAP" FLEET_MAIN="${HOOK_MAIN-/x}" "$PY" "$GUARD" | "$PY" -c 'import json,sys
d=sys.stdin.read().strip()
print(json.loads(d)["hookSpecificOutput"]["updatedInput"]["command"] if d else "", end="")'
import json, sys
ti = {"command": sys.argv[1]}
if sys.argv[2]:
    ti.update(json.loads(sys.argv[2]))
print(json.dumps({"tool_name": "Bash", "tool_input": ti, "cwd": "/"}))
PY
}
P="$QW --label git-push --wait 60 -- "

eq "git push → prefixed" "${P}git push origin b" "$(rewrite 'git push origin b')"
eq "git -C dir push → prefixed" "$QW --label git-push --wait 60 -- git -C /r push" "$(rewrite 'git -C /r push')"
eq "&& chain + pipe: only the heavy statement" \
   "cd x && $QW --label pytest --wait 60 -- pytest -q | tail -5" "$(rewrite 'cd x && pytest -q | tail -5')"
eq "two heavy statements → both prefixed" \
   "$QW --label npm-test --wait 60 -- npm run test && ${P}git push" "$(rewrite 'npm run test && git push')"
eq "VAR=\"a b\" stays before the wrapper" \
   "FOO=\"a b\" $QW --label npm-test --wait 60 -- npm test" "$(rewrite 'FOO="a b" npm test')"
eq "timeout prefix goes inside the wrapper" \
   "$QW --label pytest --wait 60 -- timeout 300 pytest" "$(rewrite 'timeout 300 pytest')"
eq "if-statement keyword stays outside" \
   "if ${P}git push; then echo ok; fi" "$(rewrite 'if git push; then echo ok; fi')"
eq "script path form" "$QW --label run-selftests.sh --wait 60 -- bin/run-selftests.sh fleet-heavy" \
   "$(rewrite 'bin/run-selftests.sh fleet-heavy')"
eq "bash <script> form" "$QW --label pre-pr.sh --wait 60 -- bash scripts/pre-pr.sh" \
   "$(rewrite 'bash scripts/pre-pr.sh')"
HD="$(printf 'scripts/pre-pr.sh <<'"'"'EOF'"'"'\ngit push "$x" `y`\nEOF\necho done')"
eq "heredoc body kept byte for byte" "$QW --label pre-pr.sh --wait 60 -- $HD" "$(rewrite "$HD")"
eq "run_in_background → no --wait cap" "$QW --label git-push -- git push" \
   "$(rewrite 'git push' '{"run_in_background": true}')"
eq "timeout 600000ms → --wait 300" "$QW --label git-push --wait 300 -- git push" \
   "$(rewrite 'git push' '{"timeout": 600000}')"

eq "quoted mention is data"       "" "$(rewrite 'git commit -m "then git push and pytest"')"
eq "argument mention is data"     "" "$(rewrite 'echo git push')"
eq "heredoc mention is data"      "" "$(rewrite "$(printf 'cat <<EOF\npytest\nEOF')")"
eq "git pushy is not git push"    "" "$(rewrite 'git pushy')"
eq "already wrapped → no double"  "" "$(rewrite "$WRAP -- git push")"
eq "inline FLEET_HEAVY=0 → off"   "" "$(rewrite 'FLEET_HEAVY=0 git push')"
eq "env FLEET_HEAVY=0 → off"      "" "$(FLEET_HEAVY=0 rewrite 'git push')"
eq "not a fleet pane → off"       "" "$(HOOK_MAIN='' rewrite 'git push')"
eq "wrapper missing → off"        "" "$(WRAP=/nonexistent rewrite 'git push')"

printf 'FLEET_HEAVY=0\n' > "$FLEET_CONF_DIR/fleet.settings"
eq "settings FLEET_HEAVY=0 → off" "" "$(rewrite 'git push')"
printf 'FLEET_HEAVY_RE='"'"'cat\\b|make\\b'"'"'\nFLEET_HEAVY_WAIT=20\n' > "$FLEET_CONF_DIR/fleet.settings"
eq "custom FLEET_HEAVY_RE: git push no longer heavy" "" "$(rewrite 'git push')"
eq "custom FLEET_HEAVY_RE + WAIT cap" "$QW --label make --wait 20 -- make build" "$(rewrite 'make build')"

# The rewritten command really runs: heredoc + quotes survive the wrapper.
HD2="$(printf 'cat <<'"'"'EOF'"'"' | tr a-z A-Z\nhello "q" $x `y`\nEOF')"
R="$(rewrite "$HD2")"; eq "rewritten heredoc command executes intact" 'HELLO "Q" $X `Y`' "$(bash -c "$R" 2>/dev/null)"
rm -f "$FLEET_CONF_DIR/fleet.settings"

# Lockstep: hook default == fleet-lib default.
lib_re="$(FLEET_SKIP_GLOBAL_CONF=1 bash -c '. "$1/fleet-lib.sh"; printf %s "$FLEET_HEAVY_RE_DEFAULT"' _ "$BIN")"
hook_re="$("$PY" -c 'import importlib.util,sys
s=importlib.util.spec_from_file_location("g",sys.argv[1]);m=importlib.util.module_from_spec(s);s.loader.exec_module(m)
print(m.HEAVY_RE_DEFAULT,end="")' "$GUARD")"
eq "default FLEET_HEAVY_RE in lockstep (fleet-lib.sh == bash-guard.py)" "$lib_re" "$hook_re"

if [ "$fails" -eq 0 ]; then echo "fleet-heavy-selftest: PASS"; exit 0; fi
echo "fleet-heavy-selftest: $fails FAILED" >&2; exit 1
