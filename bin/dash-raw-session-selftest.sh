#!/bin/bash
# dash-raw-session-selftest.sh — hermetic tests for the RAW (non-issue-bound)
# scratch session (issue #214). Two surfaces:
#   1. bin/dash-raw-session.sh spawns a plain claude window — marked @raw=1, NO
#      @issue, named `scratch`/`scratch-N`, in $FLEET_MAIN — and is cap-checked.
#   2. bin/.fleet-restore-resolve.py DROPS @raw=1 rows (raw sessions are ephemeral,
#      never snapshotted/restored) while keeping normal WIN rows + old maps.
#
# No network, no real repo, no tmux server: the real script + fleet-lib.sh are
# symlinked into a temp bin, and a fake `tmux` logs new-window/set-window-option/
# display-message so we can assert what it spawns.
#
#   A. happy spawn        → new-window(-n scratch, -c $FLEET_MAIN), @raw=1 set, no @issue
#   B. cap refusal        → per-fleet cap reached → NO new-window, capacity message
#   C. name dedup         → a live `scratch` window → the next one is `scratch-2`
#   D. restore excludes    → resolver drops a @raw=1 row, keeps a normal WIN row
#   E. old-map back-compat → a 6-field WIN row (pre-#214, no @raw) is still kept
#
# Optional --name at creation (issue #225) — the name is display-only; the @raw=1
# / no-@issue invariants hold regardless:
#   F. --name foo          → window named `foo`, still @raw=1 + no @issue
#   G. empty --name        → auto `scratch` (empty input keeps today's behavior)
#   H. custom collision    → a live `foo` window → the next one is `foo-2`
#   I. reserved name       → --name plan/dash/backlog → fallback `scratch` + note
#   J. empties-after-sanitize → --name '###' → fallback `scratch` + note
#   K. sanitization        → control chars / `#` stripped, case/spacing kept, ≤24 chars
#   L. positional target   → --name foo <sess> still spawns `foo` into <sess>
#   M. ⌃s popup phase      → --prompt-read reads the name off one stdin line
#
# Exit 0 = pass; non-zero = fail (prints the failing assertion + captured output).
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
RAW="$BIN/dash-raw-session.sh"
LIB="$BIN/fleet-lib.sh"
RESOLVE="$BIN/.fleet-restore-resolve.py"
for f in "$RAW" "$LIB" "$RESOLVE"; do
  [ -f "$f" ] || { echo "selftest: $f missing" >&2; exit 2; }
done
command -v python3 >/dev/null 2>&1 || { echo "selftest: python3 absent — SKIP" >&2; exit 0; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/raw-selftest.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT

pass=0
ok()   { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1" >&2; [ -n "${2:-}" ] && printf -- '--- output ---\n%s\n' "$2" >&2; exit 1; }

mkdir -p "$WORK/bin" "$WORK/fakebin" "$WORK/conf" "$WORK/main" "$WORK/tmp/.claude-dash"
NEWWIN_LOG="$WORK/newwin"; OPTS_LOG="$WORK/opts"; DISPLAY_LOG="$WORK/display"; SELECT_LOG="$WORK/select"

ln -s "$RAW" "$WORK/bin/dash-raw-session.sh"
ln -s "$LIB" "$WORK/bin/fleet-lib.sh"
# fleet-claude.sh is never executed (new-window is faked), but the script's dir
# resolution references $BIN — the symlink target dir is the real bin, so nothing
# else to stub.

# --- fake tmux: strip -L/-S <sock>; answer session_name; log the mutations -------
cat > "$WORK/fakebin/tmux" <<'TMUXFAKE'
#!/bin/bash
if [ "${1:-}" = "-L" ] || [ "${1:-}" = "-S" ]; then shift 2; fi
cmd="${1:-}"; [ "$#" -gt 0 ] && shift
case "$cmd" in
  display-message)
    case "$*" in
      *-p*) case "$*" in *session_name*) echo "${SESS_NAME:-testsess}";; *) echo "";; esac ;;
      *)    printf '%s\n' "$*" >> "$DISPLAY_LOG" ;;
    esac ;;
  list-windows)     printf '%s\n' "${WINS:-}" ;;                 # -F window_name (ignored: WINS is the name set)
  new-window)       printf 'NEWWIN %s\n' "$*" >> "$NEWWIN_LOG"; echo '@9' ;;   # -P -F window_id
  set-window-option) printf 'SETOPT %s\n' "$*" >> "$OPTS_LOG" ;;
  select-window)    printf 'SELECT %s\n' "$*" >> "$SELECT_LOG" ;;
  *) : ;;
esac
exit 0
TMUXFAKE
chmod +x "$WORK/fakebin/tmux"

# run the raw spawner. The per-case env (WINS, FLEET_MAX_SESSIONS,
# FLEET_SPAWN_FOCUS) is set as a prefix on the `run_raw` call — bash exports those
# into the function's command environment, so the child `bash` inherits them. Any
# args passed to run_raw are forwarded to the script (--name / --prompt-read /
# positional <target-session>); stdin is inherited, so a caller can pipe the
# --prompt-read line in.
run_raw() {
  : > "$NEWWIN_LOG"; : > "$OPTS_LOG"; : > "$DISPLAY_LOG"; : > "$SELECT_LOG"
  PATH="$WORK/fakebin:$PATH" TMPDIR="$WORK/tmp" FLEET_CONF_DIR="$WORK/conf" \
  FLEET_REPO="acme/widgets" FLEET_MAIN="$WORK/main" \
  FLEET_GLOBAL_MAX_SESSIONS=0 \
  DISPLAY_LOG="$DISPLAY_LOG" NEWWIN_LOG="$NEWWIN_LOG" OPTS_LOG="$OPTS_LOG" SELECT_LOG="$SELECT_LOG" \
    bash "$WORK/bin/dash-raw-session.sh" "$@" >"$WORK/out" 2>"$WORK/err"
}

# ============================ A: happy spawn =================================
WINS=$'plan\ndash' FLEET_MAX_SESSIONS=0 FLEET_SPAWN_FOCUS=1 run_raw
grep -q 'NEWWIN' "$NEWWIN_LOG"           || fail "A a raw window was not created" "$(cat "$WORK/err")"
grep -q -- '-n scratch\b' "$NEWWIN_LOG"  || fail "A window not named 'scratch'" "$(cat "$NEWWIN_LOG")"
grep -q -- "-c $WORK/main" "$NEWWIN_LOG"  || fail "A window not opened in FLEET_MAIN" "$(cat "$NEWWIN_LOG")"
grep -q -- '-d' "$NEWWIN_LOG"            || fail "A raw spawn should be -d (non-invasive)" "$(cat "$NEWWIN_LOG")"
grep -q 'SETOPT .*@raw 1' "$OPTS_LOG"    || fail "A @raw=1 marker not set" "$(cat "$OPTS_LOG")"
grep -q '@issue' "$OPTS_LOG"             && fail "A a raw window must NOT get an @issue" "$(cat "$OPTS_LOG")"
grep -q 'SELECT .*@9' "$SELECT_LOG"      || fail "A FLEET_SPAWN_FOCUS=1 should jump to the new window" "$(cat "$SELECT_LOG")"
ok "A raw spawn creates a @raw scratch window in FLEET_MAIN, no @issue"

# ============================ B: cap refusal ================================
# per-fleet cap of 1 with one live non-panel worker window ⇒ refuse before spawning.
WINS=$'plan\nworker-1' FLEET_MAX_SESSIONS=1 run_raw
[ -s "$NEWWIN_LOG" ] && fail "B a cap refusal must NOT create a window" "$(cat "$NEWWIN_LOG")"
grep -qi 'capacity' "$DISPLAY_LOG"       || fail "B cap refusal should surface a capacity message" "$(cat "$DISPLAY_LOG")"
ok "B raw spawn honours the session cap (refuses, no window)"

# ============================ C: name dedup =================================
WINS=$'plan\ndash\nscratch' FLEET_MAX_SESSIONS=0 run_raw
grep -q -- '-n scratch-2\b' "$NEWWIN_LOG" || fail "C a second scratch should be named scratch-2" "$(cat "$NEWWIN_LOG")"
ok "C a live 'scratch' window makes the next one 'scratch-2'"

# ==================== F: --name names the window (issue #225) ================
WINS=$'plan\ndash' FLEET_MAX_SESSIONS=0 run_raw --name foo
grep -q -- '-n foo\b' "$NEWWIN_LOG"    || fail "F --name foo should name the window foo" "$(cat "$NEWWIN_LOG")"
grep -q 'SETOPT .*@raw 1' "$OPTS_LOG"  || fail "F a named raw window must still be @raw=1" "$(cat "$OPTS_LOG")"
grep -q '@issue' "$OPTS_LOG"           && fail "F a named raw window must NOT get an @issue" "$(cat "$OPTS_LOG")"
ok "F --name foo → window 'foo', still @raw=1 and no @issue"

# ==================== G: empty --name keeps the auto name ====================
WINS=$'plan\ndash' FLEET_MAX_SESSIONS=0 run_raw --name ''
grep -q -- '-n scratch\b' "$NEWWIN_LOG" || fail "G empty --name should fall back to auto scratch" "$(cat "$NEWWIN_LOG")"
ok "G an empty --name keeps the auto 'scratch' name"

# ==================== H: custom-name dedup ==================================
WINS=$'plan\nfoo' FLEET_MAX_SESSIONS=0 run_raw --name foo
grep -q -- '-n foo-2\b' "$NEWWIN_LOG" || fail "H a taken custom name should get a -2 suffix" "$(cat "$NEWWIN_LOG")"
ok "H a live 'foo' window makes the next --name foo → 'foo-2'"

# ==================== I: reserved panel names fall back ======================
for r in plan dash backlog; do
  WINS=$'other' FLEET_MAX_SESSIONS=0 run_raw --name "$r"
  grep -q -- '-n scratch\b' "$NEWWIN_LOG" || fail "I reserved --name $r should fall back to scratch" "$(cat "$NEWWIN_LOG")"
  grep -qi 'reserved' "$DISPLAY_LOG"      || fail "I reserved --name $r should surface a note" "$(cat "$DISPLAY_LOG")"
done
ok "I --name plan/dash/backlog → fallback 'scratch' + a reserved note"

# ==================== J: empties-after-sanitize falls back ===================
WINS=$'other' FLEET_MAX_SESSIONS=0 run_raw --name '###'
grep -q -- '-n scratch\b' "$NEWWIN_LOG"        || fail "J a name that sanitizes empty should fall back to scratch" "$(cat "$NEWWIN_LOG")"
grep -qi 'empty after sanitize' "$DISPLAY_LOG"  || fail "J empties-after-sanitize should surface a note" "$(cat "$DISPLAY_LOG")"
ok "J --name '###' (empties after sanitize) → fallback 'scratch' + note"

# ==================== K: sanitization (strip / preserve / cap) ===============
# tab (control char) + '#' stripped; internal space + casing preserved.
WINS=$'plan' FLEET_MAX_SESSIONS=0 run_raw --name $'A\tB C#D'
grep -qF -- '-n AB CD -c' "$NEWWIN_LOG" || fail "K control chars + '#' stripped, space/case kept" "$(cat "$NEWWIN_LOG")"
# length cap: a 36-char name is truncated to 24.
WINS=$'plan' FLEET_MAX_SESSIONS=0 run_raw --name 'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789'
grep -q -- '-n ABCDEFGHIJKLMNOPQRSTUVWX\b' "$NEWWIN_LOG" || fail "K a long name should be capped at ~24 chars" "$(cat "$NEWWIN_LOG")"
ok "K sanitize strips control chars + '#', preserves case/spacing, caps at ~24"

# ==================== L: positional target alongside --name ==================
WINS=$'plan' FLEET_MAX_SESSIONS=0 run_raw --name foo othersess
grep -q -- '-n foo\b' "$NEWWIN_LOG"       || fail "L --name foo <sess> should still name the window foo" "$(cat "$NEWWIN_LOG")"
grep -q -- '-t othersess:' "$NEWWIN_LOG"  || fail "L a positional <target-session> should still be honored" "$(cat "$NEWWIN_LOG")"
ok "L --name foo <target-session> spawns 'foo' into the target"

# ==================== M: ⌃s popup phase reads name off stdin =================
printf 'mybox\n' | WINS=$'plan' FLEET_MAX_SESSIONS=0 run_raw --prompt-read
grep -q -- '-n mybox\b' "$NEWWIN_LOG" || fail "M --prompt-read should read the name off stdin" "$(cat "$NEWWIN_LOG")"
printf '\n'        | WINS=$'plan' FLEET_MAX_SESSIONS=0 run_raw --prompt-read
grep -q -- '-n scratch\b' "$NEWWIN_LOG" || fail "M an empty --prompt-read line → auto scratch" "$(cat "$NEWWIN_LOG")"
ok "M --prompt-read (⌃s popup) reads the name from one stdin line"

# ============================ D: restore drops @raw ==========================
out=$(printf 'scratch|%s|-|done|-|-|1\nissue-7|%s|7|working|#12|✓|\n__STEWARD__|%s|-\n' \
        "$WORK/main" "$WORK/main-issue-7" "$WORK/main" | python3 "$RESOLVE")
printf '%s\n' "$out" | grep -q $'^WIN\tissue-7\t'  || fail "D a normal WIN row must survive" "$out"
printf '%s\n' "$out" | grep -q $'^STEWARD\t'       || fail "D the STEWARD row must survive" "$out"
printf '%s\n' "$out" | grep -q 'scratch'           && fail "D a @raw=1 row must be DROPPED (never restored)" "$out"
ok "D the restore resolver drops @raw=1 rows, keeps normal + steward rows"

# ============================ E: old-map back-compat ========================
# a pre-#214 WIN row has only 6 fields (no @raw) — raw defaults to '' → kept.
out=$(printf 'issue-9|%s|9|done|-|-\n' "$WORK/main-issue-9" | python3 "$RESOLVE")
printf '%s\n' "$out" | grep -q $'^WIN\tissue-9\t'  || fail "E a 6-field (pre-#214) WIN row must still parse+survive" "$out"
ok "E an old 6-field map row (no @raw) is unaffected"

printf '\nselftest OK: %s assertions passed (raw non-issue-bound session, #214)\n' "$pass"
exit 0
