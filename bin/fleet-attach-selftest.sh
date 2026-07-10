#!/bin/bash
# fleet-attach-selftest.sh — hermetic test for bin/fleet-attach.sh, the `cf`
# fast-path reattach to an already-running fleet (issue #212).
#
# Asserts the selection + cross-socket rules WITHOUT a real tmux server, by faking
# tmux (has-session drives the live set; detach-client/attach are logged, not run)
# and sandboxing FLEET_CONF_DIR so fleet_sockets enumerates only our fake fleets:
#   • 0 live fleets                 → exit 10 (cf falls through to fleet-up).
#   • 1 live, OUTSIDE tmux          → `tmux -L <sess> attach -t <sess>` (plain attach).
#   • 1 live, INSIDE another fleet  → detach-client -E targeting the other socket.
#   • 1 live, ALREADY in it         → no-op ("already on"), no attach/detach issued.
#   • N live, non-interactive       → most-recently-active fleet (no picker).
# Exit 0 = pass.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
SRC="$BIN/fleet-attach.sh"
[ -x "$SRC" ] || { printf 'selftest: %s not found/executable\n' "$SRC" >&2; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/fleet-attach-selftest.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT

fail() { printf 'selftest FAIL: %s\n' "$1" >&2; [ -n "${2:-}" ] && printf -- '--- %s\n' "$2" >&2; exit 1; }
CHECKS=0
ok() { CHECKS=$((CHECKS+1)); }

# --- fake tmux ----------------------------------------------------------------
# Drives liveness from $FLEET_LIVE (space-separated live session names), the
# current session from $FLEET_CUR, and activity from $FLEET_ACT_<sess>. Logs every
# invocation to $FLEET_TMUXLOG; detach-client/attach just log + exit 0 (never
# actually attach). Parses the -t target out of the global+subcommand args.
mkdir -p "$WORK/fakepath"
cat > "$WORK/fakepath/tmux" <<'FAKE'
#!/bin/bash
log="${FLEET_TMUXLOG:-/dev/null}"
printf '%s\n' "$*" >> "$log"
# Find the subcommand (skip global -L/-S<val> and their args) and the -t target.
sub=""; target=""; want_t=0
for a in "$@"; do
  if [ "$want_t" = 1 ]; then target="$a"; want_t=0; continue; fi
  case "$a" in
    -L|-S) skip_next=1; continue ;;
    -t) want_t=1; continue ;;
    -t*) target="${a#-t}" ;;
    -*) : ;;
    *) if [ "${skip_next:-0}" = 1 ]; then skip_next=0; else [ -z "$sub" ] && sub="$a"; fi ;;
  esac
done
case "$sub" in
  has-session)
    for s in $FLEET_LIVE; do [ "$s" = "$target" ] && exit 0; done
    exit 1 ;;
  display-message)
    case "$*" in
      *'#S'*)                printf '%s\n' "${FLEET_CUR:-}" ;;
      *session_activity*)    t2="${target//-/_}"; eval "printf '%s\n' \"\${FLEET_ACT_${t2}:-0}\"" ;;
      *)                     : ;;
    esac
    exit 0 ;;
  detach-client|attach) exit 0 ;;   # logged above; never really (de|at)tach
  *) exit 0 ;;
esac
FAKE
chmod +x "$WORK/fakepath/tmux"

CONF_DIR="$WORK/conf"
mkfleet() { mkdir -p "$CONF_DIR/fleets/$1"; printf 'FLEET_REPO="acme/%s"\n' "$1" > "$CONF_DIR/fleets/$1/conf"; }

# run fleet-attach.sh with the fake tmux + a fresh log; extra args are env=val.
run() {
  local log="$WORK/tmuxlog"; : > "$log"
  env -i PATH="$WORK/fakepath:$PATH" HOME="$WORK" \
      FLEET_CONF_DIR="$CONF_DIR" TMPDIR="$WORK" FLEET_TMUXLOG="$log" "$@" \
      bash "$SRC" >"$WORK/out" 2>"$WORK/err"
  RC=$?; LOG="$log"; return 0
}

# --- 0 live → exit 10 ---------------------------------------------------------
mkfleet fleet-a; mkfleet fleet-b            # configured but NOT live (FLEET_LIVE empty)
run FLEET_LIVE=""
[ "$RC" -eq 10 ] || fail "0 live fleets must exit 10 (fall through to fleet-up), got $RC" "$(cat "$WORK/err")"
ok
printf 'selftest: 0-live leg PASS (exit 10 → cf falls through to fleet-up)\n' >&2

# --- 1 live, OUTSIDE tmux → plain attach --------------------------------------
run FLEET_LIVE="fleet-a"                     # no TMUX in the scrubbed env = outside tmux
[ "$RC" -eq 0 ] || fail "1 live outside tmux should attach cleanly, got $RC" "$(cat "$WORK/err")"
grep -q 'attach -t fleet-a' "$LOG" || fail "1 live outside tmux must run 'tmux -L fleet-a attach -t fleet-a'" "$(cat "$LOG")"
grep -q 'detach-client' "$LOG" && fail "outside tmux must NOT detach-client (no client to detach)" "$(cat "$LOG")"
ok
printf 'selftest: 1-live-outside leg PASS (plain attach, no detach)\n' >&2

# --- 1 live, INSIDE another fleet → cross-socket detach+attach ----------------
run FLEET_LIVE="fleet-a" TMUX="/tmp/fake,1,0" FLEET_CUR="fleet-other"
[ "$RC" -eq 0 ] || fail "1 live inside another fleet should switch cleanly, got $RC" "$(cat "$WORK/err")"
grep -q 'detach-client' "$LOG" || fail "inside another fleet must detach-client -E to cross sockets" "$(cat "$LOG")"
grep -q "attach -t 'fleet-a'" "$LOG" || grep -q 'fleet-a' "$LOG" \
  || fail "the detach -E command must re-attach to fleet-a's socket" "$(cat "$LOG")"
ok
printf 'selftest: 1-live-cross-socket leg PASS (detach-client -E → target socket)\n' >&2

# --- 1 live, ALREADY inside it → no-op ----------------------------------------
run FLEET_LIVE="fleet-a" TMUX="/tmp/fake,1,0" FLEET_CUR="fleet-a"
[ "$RC" -eq 0 ] || fail "already on the only live fleet should be a clean no-op, got $RC" "$(cat "$WORK/err")"
grep -q 'detach-client' "$LOG" && fail "already-on must NOT detach (no pointless reattach)" "$(cat "$LOG")"
grep -qi 'already on' "$WORK/err" || fail "already-on should say so" "$(cat "$WORK/err")"
ok
printf 'selftest: already-on leg PASS (no-op, no detach)\n' >&2

# --- N live, non-interactive → most-recently-active ---------------------------
# fleet-b has the higher session_activity, so a non-interactive caller must land
# on fleet-b (not the picker, which needs an interactive tty inside tmux).
run FLEET_LIVE="fleet-a fleet-b" FLEET_ACT_fleet_a="100" FLEET_ACT_fleet_b="200"
[ "$RC" -eq 0 ] || fail "N live non-interactive should attach to most-recent, got $RC" "$(cat "$WORK/err")"
grep -q 'fleet-b' "$LOG" || fail "most-recent (higher activity) fleet-b should be attached" "$(cat "$LOG")"
ok
printf 'selftest: N-live-most-recent leg PASS (highest session_activity wins)\n' >&2

printf 'selftest OK: fleet-attach fast-path (%s assertions — 0→exit10, single attach in/out of tmux, already-on no-op, multi→most-recent)\n' "$CHECKS"
