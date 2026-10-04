#!/bin/bash
# fleet-session-command-selftest.sh — the mod's command inbox, bash half (issue
# #1337, EPIC #1334 C3).
#
#   H  fleet_session_command's exit codes, each against a stand-in mod that does
#      what mod/fleet/hooks/inbox.ts does (claim by atomic mv, write .done):
#      0 ran · 3 no mod (FLEET_MOD=0 / stale beat / no pane / no socket) ·
#      4 never taken → cancelled, so a late mod can never run it · 5 refused ·
#      6 taken, not done · 2 usage. The post itself is the documented JSON.
#   C  bin/fleet-compact-send.sh: mod alive → `/compact …` posted, ZERO send-keys,
#      `via mod` logged; no mod → today's exact keystrokes (Escape · text · Enter),
#      `via send-keys` logged.
#
# (bin/fleet-handoff-selftest.sh's VIA-MOD legs and bin/fleet-model-switch-
# selftest.sh's mod leg cover the other two callers.) Hermetic: a fake tmux on
# PATH answers the reads from files and records every send-keys; no tmux server
# is touched.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
LIB="$BIN/fleet-lib.sh"
for f in "$LIB" "$BIN/fleet-session-command.sh" "$BIN/fleet-compact-send.sh"; do
  [ -f "$f" ] || { printf 'selftest: %s missing\n' "$f" >&2; exit 2; }
done

WORK="$(mktemp -d "${TMPDIR:-/tmp}/fleet-session-command.XXXXXX")" || exit 2
MODPID=''
trap '[ -n "$MODPID" ] && kill "$MODPID" 2>/dev/null; rm -rf "$WORK"' EXIT
trap 'exit 130' INT TERM HUP

pass=0
ok()   { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
fail() { printf 'selftest FAIL: %s\n' "$1" >&2; [ -n "${2:-}" ] && printf -- '--- detail ---\n%s\n' "$2" >&2; exit 1; }

mkdir -p "$WORK/fakebin" "$WORK/conf" "$WORK/logs"
INJECT="$WORK/inject"; : > "$INJECT"
# fake tmux: strips -L <label>; answers pane_id / @mod_alive / the compact gates
# from files; records send-keys.
cat > "$WORK/fakebin/tmux" <<EOF
#!/bin/bash
if [ "\${1:-}" = -L ]; then shift 2; fi
args="\$*"
case "\${1:-}" in
  send-keys) printf '%s\n' "\$args" >> "$INJECT" ;;
  display-message)
    case "\$args" in
      *pane_id*)        cat "$WORK/pane" 2>/dev/null ;;
      *@mod_alive*)     cat "$WORK/alive" 2>/dev/null ;;
      *@compact_stage*) cat "$WORK/stage" 2>/dev/null ;;
      *@claude_state*)  printf 'done\n' ;;
      *window_id*)      printf '@7\n' ;;
    esac ;;
  set-window-option)
    case "\$args" in *@compact_stage*compacting*) printf 'compacting\n' > "$WORK/stage" ;; esac ;;
esac
exit 0
EOF
chmod +x "$WORK/fakebin/tmux"
printf '%%7\n' > "$WORK/pane"
MDIR="$WORK/conf/global/mod-inbox/fleet-x/7"
TOOK="$WORK/took"

# A stand-in mod: claim each post the way inbox.ts does (mv .json → .taken), copy
# it to $TOOK, then answer per <mode>: ok | refuse | hang (taken, never done).
mod() {
  local mode="$1"
  : > "$TOOK"
  ( end=$((SECONDS + 20))
    while [ "$SECONDS" -lt "$end" ]; do
      for f in "$MDIR"/*.json; do
        [ -f "$f" ] || continue
        b="${f%.json}"
        mv "$f" "$b.taken" 2>/dev/null || continue
        cat "$b.taken" >> "$TOOK"
        case "$mode" in
          ok)     printf '{"ok":true}\n' > "$b.done" ;;
          refuse) printf '{"ok":false,"error":"Unknown command: /nosuch"}\n' > "$b.done" ;;
        esac
      done
      sleep 0.1
    done ) &
  MODPID=$!
}
unmod() { [ -n "$MODPID" ] && kill "$MODPID" 2>/dev/null; wait "$MODPID" 2>/dev/null; MODPID=''; }

sc() {   # sc [VAR=val …] -- <helper args> → the helper's exit code
  local envs=()
  while [ "$#" -gt 0 ] && [ "$1" != -- ]; do envs+=("$1"); shift; done
  shift
  # shellcheck disable=SC2046  # word-split on purpose: one variable name per word
  ( unset $(env | sed -n 's/^\(FLEET_[A-Za-z0-9_]*\)=.*/\1/p')
    export PATH="$WORK/fakebin:$PATH" FLEET_CONF_DIR="$WORK/conf" TMUX="/tmp/tmux-1/fleet-x,1,0"
    export FLEET_MOD_TAKE_SECS=1 FLEET_MOD_DONE_SECS=1
    export ${envs[@]+"${envs[@]}"}
    bash "$BIN/fleet-session-command.sh" "$@" ) >/dev/null 2>"$WORK/err"
}
fresh() { date +%s > "$WORK/alive"; }

# --- H: exit codes ----------------------------------------------------------------
fresh; mod ok
sc -- --from selftest %7 '/compact Keep the map; see /a b' || fail "H: a mod that answers ok must give 0 (got $?)" "$(cat "$WORK/err")"
unmod
want='{"cmd": "/compact", "args": "Keep the map; see /a b", "from": "selftest"}'
[ "$(cat "$TOOK")" = "$want" ] || fail "H: the post is not the documented JSON" "$(cat "$TOOK")"
[ -n "$(ls -A "$MDIR" 2>/dev/null)" ] && fail "H: a finished post must leave the inbox empty" "$(ls -A "$MDIR")"
ok "H 0: posted as {cmd,args,from}, claimed, done ok; inbox left empty"

sc FLEET_MOD=0 -- %7 /clear; rc=$?
[ "$rc" = 3 ] || fail "H: FLEET_MOD=0 must give 3 (got $rc)"
printf '%s\n' "$(( $(date +%s) - 600 ))" > "$WORK/alive"
sc -- %7 /clear; rc=$?
[ "$rc" = 3 ] || fail "H: a stale beat must give 3 (got $rc)"
fresh; : > "$WORK/pane"
sc -- %7 /clear; rc=$?
[ "$rc" = 3 ] || fail "H: an unknown pane must give 3 (got $rc)"
printf '%%7\n' > "$WORK/pane"
( unset TMUX; sc TMUX= -- %7 /clear ); rc=$?
[ "$rc" = 3 ] || fail "H: no \$TMUX and no --socket must give 3 (got $rc)"
ls "$MDIR"/*.json >/dev/null 2>&1 && fail "H: a 3 must post nothing"
ok "H 3: FLEET_MOD=0 / stale beat / unknown pane / no socket — nothing posted"

fresh
sc -- %7 /clear; rc=$?
[ "$rc" = 4 ] || fail "H: nobody taking it must give 4 (got $rc)"
[ -n "$(ls -A "$MDIR" 2>/dev/null)" ] && fail "H: a timed-out post must be cancelled (removed), never left for a late mod" "$(ls -A "$MDIR")"
ok "H 4: never taken → cancelled by the same atomic rename; nothing left behind"

fresh; mod refuse
sc -- %7 /nosuch; rc=$?
unmod
[ "$rc" = 5 ] || fail "H: a refused command must give 5 (got $rc)"
grep -q 'Unknown command' "$WORK/err" || fail "H: the refusal reason must reach stderr" "$(cat "$WORK/err")"
ok "H 5: refused → 5, the engine's reason on stderr"

fresh; mod hang
sc -- %7 '/compact x'; rc=$?
unmod
[ "$rc" = 6 ] || fail "H: taken but not done must give 6 (got $rc)"
ok "H 6: taken, not done → 6 (running — the caller must not type it again)"
rm -rf "$MDIR"

sc -- %7 clear; rc=$?;  [ "$rc" = 2 ] || fail "H: a line without a slash is usage (got $rc)"
sc -- '' /clear; rc=$?; [ "$rc" = 2 ] || fail "H: no target is usage (got $rc)"
ok "H 2: usage"

sc --  --socket fleet-x %7 /clear; rc=$?
[ "$rc" = 4 ] || fail "H: --socket must address the same inbox (got $rc)"
ok "H --socket: an outside caller lands in the same <label>/<pane> inbox"

# --- C: fleet-compact-send.sh, both paths ---------------------------------------
compact() {   # compact — run the sender against the fake pane
  # shellcheck disable=SC2046  # word-split on purpose: one variable name per word
  ( unset $(env | sed -n 's/^\(FLEET_[A-Za-z0-9_]*\)=.*/\1/p')
    export PATH="$WORK/fakebin:$PATH" FLEET_CONF_DIR="$WORK/conf" TMUX="/tmp/tmux-1/fleet-x,1,0"
    export FLEET_COMPACT_SEND_GRACE=0 FLEET_HANDOFF_DEFER_SECS=0 FLEET_HANDOFF_LOG_DIR="$WORK/logs"
    export FLEET_MOD_TAKE_SECS=1 FLEET_MOD_DONE_SECS=1
    sh "$BIN/fleet-compact-send.sh" %7 /tmp/map.md ) >/dev/null 2>&1
}
fresh; printf 'prep\n' > "$WORK/stage"; : > "$INJECT"; mod ok
compact
unmod
[ -s "$INJECT" ] && fail "C: with the mod alive NOTHING may be typed" "$(cat "$INJECT")"
grep -q '"cmd": "/compact"' "$TOOK" && grep -q 'RECOVERY MAP' "$TOOK" && grep -q '/tmp/map.md' "$TOOK" \
  || fail "C: the mod must take /compact with the keep-the-map instruction" "$(cat "$TOOK")"
tail -1 "$WORK/logs/compact-send.log" | grep -q '/compact via mod' || fail "C: the log must say via mod" "$(cat "$WORK/logs/compact-send.log")"
[ "$(cat "$WORK/stage")" = compacting ] || fail "C: the stage must still flip to compacting first"
ok "C mod alive: /compact posted with the map instruction, zero send-keys, 'via mod' logged"

printf '%s\n' "$(( $(date +%s) - 600 ))" > "$WORK/alive"; printf 'prep\n' > "$WORK/stage"; : > "$INJECT"
compact
want=$(printf '%s\n' 'send-keys -t %7 Escape' "send-keys -t %7 -l -- /compact Keep the fleet RECOVERY MAP verbatim (issue, branch, PR, done, in progress, next steps); it is also saved at /tmp/map.md" 'send-keys -t %7 Enter')
[ "$(cat "$INJECT")" = "$want" ] || fail "C: no mod must type exactly today's three keystrokes" "$(cat "$INJECT")"
tail -1 "$WORK/logs/compact-send.log" | grep -q '/compact via send-keys' || fail "C: the log must say via send-keys"
ok "C no mod: today's keystrokes byte for byte (Escape · text · Enter), 'via send-keys' logged"

printf 'fleet-session-command-selftest: %d passed\n' "$pass"
