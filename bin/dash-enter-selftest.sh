#!/bin/bash
# dash-enter-selftest.sh — the dash prompt-line Enter handler, focused on the
# paste-storm guard (issue #531).
#
# The bug: the dash's always-visible prompt line ("type a task, ↵ → scratch")
# is an fzf input. A terminal delivers a MULTI-LINE PASTE as one Enter PER LINE
# (fzf has no bracketed-paste awareness on the input line — measured on 0.74.3),
# so pasting a ~250-line stack trace fired `dash-enter.sh → dash-raw-session.sh
# --prompt` 250 times: 244 concurrent `git worktree add`s, the global session cap
# bypassed (a spawn holds no slot until its window exists), disk 30→6 GB. See #531.
#
# The guard (a 1s debounce, timestamp-based): an Enter that trails another by
# < FLEET_SPAWN_GUARD_MS is a burst member and is DROPPED. An Enter with quiet
# before it is a candidate: it DEFERS FLEET_SPAWN_GUARD_SLEEP, then spawns IFF
# nothing followed it within the guard (it was isolated). So a lone task spawns
# (after a ~1s wait), a paste spawns nothing, and two tasks typed > 1s apart both
# spawn. Timestamp-based, not a counter: a counter would drop the EARLIER of two
# legitimately-spaced tasks (a later Enter exists ⇒ "not newest" ⇒ dropped).
#
# Two surfaces:
#   1. bin/fleet-lib.sh fleet_spawn_is_burst — the pure gap predicate (unit).
#   2. bin/dash-enter.sh — end-to-end: a lone Enter → exactly one spawn; a rapid
#      burst → ZERO spawns + one "pasted text is not a task" message. The spawn is
#      faked (a logging stub), the defer is driven for real via a backgrounded
#      run-shell (mirroring the live `fleet_bg`), with tiny guard knobs.
#
# No network, no live tmux (a fake `tmux` logs display-message + EXECUTES
# run-shell -b in the background, like the real one). Exit 0 = pass; non-zero =
# fail (prints the failing assertion). git/python3 absent is irrelevant here.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
ENTER="$BIN/dash-enter.sh"
LIB="$BIN/fleet-lib.sh"
for f in "$ENTER" "$LIB"; do
  [ -f "$f" ] || { echo "selftest: $f missing" >&2; exit 2; }
done

WORK="$(mktemp -d "${TMPDIR:-/tmp}/dash-enter-selftest.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT

pass=0
ok()   { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1" >&2; [ -n "${2:-}" ] && printf -- '--- output ---\n%s\n' "$2" >&2; exit 1; }

mkdir -p "$WORK/bin" "$WORK/fakebin" "$WORK/tmp/.claude-dash/global"
ln -s "$ENTER" "$WORK/bin/dash-enter.sh"
ln -s "$LIB"   "$WORK/bin/fleet-lib.sh"
# a no-op rows script (dash-enter only names it inside an emitted `reload(...)`).
printf '#!/bin/sh\n:\n' > "$WORK/bin/tmux-dashboard-rows.sh"; chmod +x "$WORK/bin/tmux-dashboard-rows.sh"

SPAWN_LOG="$WORK/spawns"; DISPLAY_LOG="$WORK/display"
# Fake dash-raw-session.sh: the guard's job is WHETHER (and how often) a spawn is
# dispatched — record each call (with the prompt it carried) and do nothing else.
cat > "$WORK/bin/dash-raw-session.sh" <<RAWFAKE
#!/bin/bash
p=""
for a in "\$@"; do case "\$a" in --prompt-file=*) p="\$(cat "\${a#--prompt-file=}" 2>/dev/null)";; esac; done
printf 'SPAWN %s\n' "\$p" >> "$SPAWN_LOG"
RAWFAKE
chmod +x "$WORK/bin/dash-raw-session.sh"

# Fake tmux: strip -L/-S <sock>; run-shell -b runs the body in the BACKGROUND
# (the real one is async — the deferred decider must not block the caller); log
# display-message text; answer session_name for fleet_current_session.
cat > "$WORK/fakebin/tmux" <<'TMUXFAKE'
#!/bin/bash
if [ "${1:-}" = "-L" ] || [ "${1:-}" = "-S" ]; then shift 2; fi
cmd="${1:-}"; [ "$#" -gt 0 ] && shift
case "$cmd" in
  run-shell) [ "${1:-}" = "-b" ] && shift; sh -c "$1" & ;;   # async, like the real -b
  display-message)
    case "$*" in
      *-p*) case "$*" in *session_name*) echo "${SESS_NAME:-testsess}";; *) echo "";; esac ;;
      *)    printf '%s\n' "$*" >> "$DISPLAY_LOG" ;;
    esac ;;
  *) : ;;
esac
exit 0
TMUXFAKE
chmod +x "$WORK/fakebin/tmux"

# Drive dash-enter's typed-task branch. Args: <query>. Per-call guard knobs ride
# in the environment (GUARD_MS/GUARD_SLEEP). The typed-task branch fires only with
# no rename/bind flag set and a non-blank query.
run_enter() {
  PATH="$WORK/fakebin:$PATH" TMPDIR="$WORK/tmp" FLEET_SESSION=testsess \
  FLEET_SPAWN_GUARD_MS="${GUARD_MS:-1000}" FLEET_SPAWN_GUARD_SLEEP="${GUARD_SLEEP:-1}" \
  DISPLAY_LOG="$DISPLAY_LOG" SPAWN_LOG="$SPAWN_LOG" \
    bash "$WORK/bin/dash-enter.sh" 'sess:1' "$1" >"$WORK/out" 2>"$WORK/err"
}
wait_bg() { sleep "${1:-0.6}"; }   # let the backgrounded decider(s) fire
# clear the debounce timestamp between cases so one case's last-Enter time can't
# make the next case's FIRST Enter look like a burst trailing it.
reset_debounce() { rm -f "$WORK/tmp/.claude-dash/global/spawn_last_ms_"* 2>/dev/null; }

# ===================== U: fleet_spawn_is_burst (unit) =======================
# gap < guard ⇒ burst (a paste's per-line Enters land ms apart); gap ≥ guard ⇒ not.
( . "$LIB"
  fleet_spawn_is_burst 1000 950 1000   || { echo "50ms gap must be a burst" >&2; exit 1; }
  fleet_spawn_is_burst 5000 3000 1000  && { echo "2000ms gap must NOT be a burst" >&2; exit 1; }
  fleet_spawn_is_burst 1000 0 1000     && { echo "no prior Enter (last=0) must NOT be a burst" >&2; exit 1; }
  exit 0
) || fail "U fleet_spawn_is_burst gap predicate wrong"
ok "U fleet_spawn_is_burst: <guard gap = burst, ≥guard gap / no-prior = not"

# ===================== A: a lone typed task spawns once ======================
reset_debounce; : > "$SPAWN_LOG"; : > "$DISPLAY_LOG"
GUARD_MS=1000 GUARD_SLEEP=0.3 run_enter 'refactor the login flow'
grep -q 'clear-query' "$WORK/out" || fail "A the Enter must clear the query line synchronously" "$(cat "$WORK/out")"
[ -s "$SPAWN_LOG" ] && fail "A the spawn must be DEFERRED, not synchronous (nothing yet)" "$(cat "$SPAWN_LOG")"
wait_bg 0.6
[ "$(grep -c '^SPAWN' "$SPAWN_LOG")" = 1 ] || fail "A a lone task must spawn exactly once after the defer" "$(cat "$SPAWN_LOG")"
grep -qF 'refactor the login flow' "$SPAWN_LOG" || fail "A the spawn must carry the typed task verbatim" "$(cat "$SPAWN_LOG")"
ok "A a lone typed task defers, then spawns exactly one seeded scratch"

# ===================== B: a multi-line paste spawns nothing ==================
# 6 Enters fired back-to-back (a paste's per-line Enters) — guard window wide
# enough that the whole loop is inside it, so every follower is an immediate drop
# and the one candidate, on wake, sees it was followed → drops too.
reset_debounce; : > "$SPAWN_LOG"; : > "$DISPLAY_LOG"
for line in 'xO @ D531DotG.js:2' 'Promise.then' 'CO @ D531DotG.js:2' 'by @ D531DotG.js:2' 'resolve @ D531DotG.js:4' 'at o2 (D-h-3-st.js:1:18145)'; do
  GUARD_MS=5000 GUARD_SLEEP=0.4 run_enter "$line"
  grep -q 'clear-query' "$WORK/out" || fail "B every burst Enter must still clear the query" "$(cat "$WORK/out")"
done
wait_bg 0.8
[ ! -s "$SPAWN_LOG" ] || fail "B a multi-line paste must spawn NOTHING" "$(cat "$SPAWN_LOG")"
grep -qi 'not a task\|pasted' "$DISPLAY_LOG" || fail "B a dropped paste must surface one explanatory message" "$(cat "$DISPLAY_LOG")"
[ "$(grep -ci 'not a task\|pasted' "$DISPLAY_LOG")" = 1 ] || fail "B the paste message must appear exactly once, not per line" "$(cat "$DISPLAY_LOG")"
ok "B a 6-line paste spawns nothing and reports once"

# ===================== C: a real rename still works (no regression) ==========
# With the rename flag set, Enter renames — it must NOT be treated as a typed task
# (no spawn, no defer), proving the guard sits only on the typed-task branch.
reset_debounce; : > "$SPAWN_LOG"; : > "$DISPLAY_LOG"
printf '%s' 'sess:1' > "$WORK/tmp/.claude-dash/rename_target"
GUARD_MS=1000 GUARD_SLEEP=0.1 run_enter 'my-new-name'
wait_bg 0.3
[ ! -s "$SPAWN_LOG" ] || fail "C a rename Enter must never spawn a scratch" "$(cat "$SPAWN_LOG")"
rm -f "$WORK/tmp/.claude-dash/rename_target"
ok "C the guard sits only on the typed-task branch (rename Enter still renames, no spawn)"

printf '\nselftest OK: %s assertions passed (dash prompt-line paste-storm guard, #531)\n' "$pass"
exit 0
