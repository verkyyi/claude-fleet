#!/bin/bash
# mod-state-selftest.sh — the session reports its own state (issue #1336, EPIC #1334 C2).
#
# The fleet mod (mod/fleet/hooks/state.ts) says turn.start / turn.complete / an open
# AskUserQuestion through `set-claude-state.sh --via mod`, and the screen classifier
# stands down for a window whose mod is alive. Its plugin half is
# mod/fleet/tests/state.test.ts (run by fleet-mod-selftest.sh's leg D); this is the
# bash half, on an isolated tmux socket (PATH shim, never the live server):
#
#   CLASSIFY   fleet_mod_alive true  ⇒ classify-sessions.sh --window makes NO model
#              call, leaves the state, logs one `skip:mod` line;
#              stale beat / no beat / FLEET_MOD=0 ⇒ exactly today: one call, verdict applied
#   VIA-MOD    working → working; ask → needs/ask; done → done; done with a pending
#              @loop → looping — the same state write the hooks make
#   STATE-ONLY a `--via mod done` past the auto-handoff line prints NO Stop decision and
#              arms nothing (the Stop hook owns that) — while the hook path on the same
#              pane does nudge, so the assertion is load-bearing
#   NO-STDIN   `--via mod` never waits on stdin: an open pipe returns at once
#   STICKY     a worker's needs/blocked survives the mod's working/done (#704)
#
# tmux or python3 absent → SKIP (exit 0). Exit 0 = pass.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
# Conf-free shadow root (#1251): classify.log / .classify-cache / fleet.conf are
# $BIN/..-relative, so a direct run must not touch the live install's.
if [ "${_MODSTATE_SELFTEST_ROOT:-}" != "$BIN" ]; then
  _root="$(sh "$BIN/selftest-shadow-root.sh" "$BIN/..")" || exit 2
  _MODSTATE_SELFTEST_ROOT="$(cd "$_root/bin" && pwd)" bash "$_root/bin/${0##*/}" "$@"; _rc=$?
  rm -rf "$_root"; exit "$_rc"
fi
CLS="$BIN/classify-sessions.sh"
SCS="$BIN/set-claude-state.sh"
for f in "$CLS" "$SCS" "$BIN/fleet-lib.sh" "$BIN/fleet_loop_mark.py"; do
  [ -f "$f" ] || { printf 'selftest: %s not found\n' "$f" >&2; exit 2; }
done
REAL_TMUX="$(command -v tmux 2>/dev/null)"
[ -n "$REAL_TMUX" ] || { printf 'selftest: tmux not installed — SKIP\n' >&2; exit 0; }
command -v python3 >/dev/null 2>&1 || { printf 'selftest: python3 not installed — SKIP\n' >&2; exit 0; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/mod-state-selftest.XXXXXX")" || exit 2
pass=0
ok()   { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
fail() { printf 'selftest FAIL: %s\n' "$1" >&2; [ -n "${2:-}" ] && printf -- '--- detail ---\n%s\n' "$2" >&2; exit 1; }

SOCK="$WORK/tmux.sock"
mkdir -p "$WORK/bin"
cat > "$WORK/bin/tmux" <<EOS
#!/bin/sh
exec "$REAL_TMUX" -S "$SOCK" "\$@"
EOS
cat > "$WORK/bin/claude" <<EOS
#!/bin/sh
echo call >> "$WORK/claude-calls"
cat > /dev/null
cat "$WORK/claude-out" 2>/dev/null
EOS
chmod +x "$WORK/bin/tmux" "$WORK/bin/claude"
export PATH="$WORK/bin:$PATH"

cleanup() { tmux kill-server 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT
trap 'exit 130' INT TERM HUP

export TMPDIR="$WORK" FLEET_CONF_DIR="$WORK/conf" CLASSIFY_SETTLE=0
unset CLASSIFY_SOCK CLASSIFY_BACKEND FLEET_MOD FLEET_MOD_ALIVE_SECS CLAUDE_CODE_ENTRYPOINT TMUX TMUX_PANE

tmux -f /dev/null new-session -d -s fleet-t -x 140 -y 40 || fail "could not start isolated tmux server"
ww="$(tmux display-message -p '#{window_id}')"
pane="$(tmux display-message -p -t "$ww" '#{pane_id}')"
tmux set-window-option -t "$ww" @issue 1336
tmux respawn-pane -k -t "$ww" "printf 'recap of the turn\nall done\n'; sleep 300" 2>/dev/null || fail "could not seed the pane"
i=0; while [ "$i" -lt 40 ] && [ -z "$(tmux capture-pane -p -t "$ww" | tr -d '[:space:]')" ]; do i=$((i+1)); sleep 0.1; done

wopt()  { tmux show-options -w -t "$ww" -v "$1" 2>/dev/null; }
ncall() { [ -f "$WORK/claude-calls" ] && wc -l < "$WORK/claude-calls" | tr -d ' ' || echo 0; }
CCACHE="$BIN/../logs/.classify-cache"; LOGF="$BIN/../logs/classify.log"; mkdir -p "$CCACHE"
ckey="$(printf '%s' "$ww" | tr '/:@' '___')"
fresh() {   # fresh <state> <@mod_alive or ''>
  tmux set-window-option -t "$ww" @claude_state "$1"; tmux set-window-option -t "$ww" @claude_needs ''
  if [ -n "$2" ]; then tmux set-window-option -t "$ww" @mod_alive "$2"; else tmux set-window-option -u -t "$ww" @mod_alive; fi
  rm -f "$CCACHE/$ckey.hash" "$WORK/claude-calls"; : > "$LOGF"
}
classify() { bash "$CLS" --window "$ww" || fail "classifier exited non-zero"; }
printf 'WAITING\n' > "$WORK/claude-out"
now=$(date +%s)

# ================================================================ CLASSIFY
fresh 'done' "$((now - 3))"; classify
[ "$(ncall)" = 0 ] || fail "CLASSIFY: a live mod must not cost a model call (got $(ncall))"
[ "$(wopt @claude_state)" = 'done' ] || fail "CLASSIFY: a live mod's state was overwritten to [$(wopt @claude_state)]"
grep -q ' skip:mod$' "$LOGF" || fail "CLASSIFY: no skip:mod line" "$(cat "$LOGF")"
ok "CLASSIFY mod alive: no model call, state kept, one skip:mod line"

for leg in stale none off; do
  case "$leg" in stale) fresh 'done' "$((now - 100))" ;; none) fresh 'done' '' ;; off) fresh 'done' "$((now - 3))" ;; esac
  if [ "$leg" = off ]; then FLEET_MOD=0 classify; else classify; fi
  [ "$(ncall)" = 1 ] || fail "CLASSIFY $leg: expected today's one model call, got $(ncall)"
  [ "$(wopt @claude_state)" = needs ] || fail "CLASSIFY $leg: the verdict was not applied [$(wopt @claude_state)]"
  grep -q 'skip:mod' "$LOGF" && fail "CLASSIFY $leg: skip:mod logged without a live mod"
done
ok "CLASSIFY stale beat / no beat / FLEET_MOD=0: exactly today — one call, verdict applied"

# ================================================================ VIA-MOD
scs() { TMUX="$SOCK,1,0" TMUX_PANE="$pane" sh "$SCS" "$@" </dev/null; }
tmux set-window-option -u -t "$ww" @mod_alive
tmux set-window-option -t "$ww" @claude_state 'done'
out=$(scs --via mod working); [ "$(wopt @claude_state)/$(wopt @claude_needs)" = working/ ] || fail "VIA-MOD working → [$(wopt @claude_state)/$(wopt @claude_needs)]"
[ -z "$out" ] || fail "VIA-MOD working printed: $out"
scs --via mod ask >/dev/null; [ "$(wopt @claude_state)/$(wopt @claude_needs)" = needs/ask ] || fail "VIA-MOD ask → [$(wopt @claude_state)/$(wopt @claude_needs)]"
scs --via mod working >/dev/null; [ "$(wopt @claude_needs)" = '' ] || fail "VIA-MOD working did not clear the ask subtype"
scs --via mod 'done' >/dev/null; [ "$(wopt @claude_state)" = 'done' ] || fail "VIA-MOD done → [$(wopt @claude_state)]"
[ -n "$(wopt @claude_state_ts)" ] || fail "VIA-MOD: no @claude_state_ts stamp"
tmux set-window-option -t "$ww" @loop "kind=wakeup next=$((now + 600)) ttl=600"
scs --via mod 'done' >/dev/null; [ "$(wopt @claude_state)" = looping ] || fail "VIA-MOD done with a pending @loop → [$(wopt @claude_state)], want looping"
tmux set-window-option -u -t "$ww" @loop
ok "VIA-MOD: working / needs+ask / done / looping-on-@loop, written by set-claude-state.sh"

# ================================================================ STATE-ONLY
printf 'FLEET_AUTO_HANDOFF_PCT=50\nFLEET_HANDOFF_DEFER_SECS=0\n' > "$BIN/../fleet.conf"
tmux set-window-option -t "$ww" @ctx_pct 90
tmux set-window-option -u -t "$ww" @handoff_armed
hookrun() { ( unset FLEET_SKIP_GLOBAL_CONF _FLEET_GLOBAL_CONF_SOURCED; scs "$@" ); }
out=$(hookrun --via mod 'done')
[ -z "$out" ] || fail "STATE-ONLY: --via mod done printed a Stop decision" "$out"
[ -z "$(wopt @handoff_armed)" ] || fail "STATE-ONLY: --via mod done armed the handoff latch"
out=$(hookrun 'done')
case "$out" in *'"decision":"block"'*) : ;; *) rm -f "$BIN/../fleet.conf"; fail "STATE-ONLY: the hook path did not nudge on the same pane — the assertion above proves nothing" "$out" ;; esac
rm -f "$BIN/../fleet.conf"; tmux set-window-option -u -t "$ww" @ctx_pct; tmux set-window-option -u -t "$ww" @handoff_armed
ok "STATE-ONLY: --via mod done writes the state alone; the Stop hook keeps the handoff decision"

# ================================================================ NO-STDIN
# stdin = a FIFO whose one writer (fd 9 here) stays open and silent: a reader blocks
# until fd 9 closes. Each leg ends by closing it, so nothing is left waiting.
mkfifo "$WORK/fifo" || fail "NO-STDIN: mkfifo"
stdin_leg() {   # stdin_leg <args…> → 0 when the script returned while stdin was still open
  TMUX="$SOCK,1,0" TMUX_PANE="$pane" sh "$SCS" "$@" <"$WORK/fifo" >/dev/null 2>&1 &
  _p=$!
  exec 9>"$WORK/fifo"
  _i=0; while [ "$_i" -lt 30 ] && kill -0 "$_p" 2>/dev/null; do _i=$((_i+1)); sleep 0.1; done
  kill -0 "$_p" 2>/dev/null; _alive=$?
  exec 9>&-                      # EOF: a reader still waiting returns now
  wait "$_p" 2>/dev/null
  return $(( _alive == 0 ))
}
stdin_leg --via mod 'done' || fail "NO-STDIN: --via mod waited on an open stdin"
stdin_leg 'done' && fail "NO-STDIN: the hook path returned without reading stdin — the leg proves nothing"
ok "NO-STDIN: --via mod never reads stdin (the hook path does)"

# ================================================================ STICKY
tmux set-window-option -t "$ww" @claude_state needs; tmux set-window-option -t "$ww" @claude_needs blocked
scs --via mod working >/dev/null; scs --via mod 'done' >/dev/null
[ "$(wopt @claude_state)/$(wopt @claude_needs)" = needs/blocked ] || fail "STICKY: the mod cleared a worker's blocked [$(wopt @claude_state)/$(wopt @claude_needs)]"
ok "STICKY: needs/blocked survives the mod's working/done"

printf 'mod-state-selftest: %d passed\n' "$pass"
