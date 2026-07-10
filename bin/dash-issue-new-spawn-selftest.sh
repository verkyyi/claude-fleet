#!/bin/bash
# dash-issue-new-spawn-selftest.sh — hermetic tests for the prefix+n quick-dispatch
# path (issue #205): dash-issue-new.sh --spawn files an issue AND spawns its bound
# worker, sharing one script with the capture-only backlog ⌃n path. No network, no
# real repo, no tmux server — gh/tmux + the sibling spawn/collect scripts are faked.
#
# The real dash-issue-new.sh + fleet-lib.sh are symlinked into a temp bin so the
# script computes BIN=<tempbin> and reaches our STUB dash-issue-session.sh /
# tmux-dash-collect.sh — letting us assert what it spawns without a tmux server.
#
#   A. --spawn + gh-ok + spawn-ok: files the issue, then spawns the worker for the
#      new issue number; the popup verb reads "New issue + worker".
#   B. --spawn + gh-ok + CAP REFUSAL (spawn exits non-zero): the issue is STILL
#      filed (gh create ran) and the popup announces filed-without-spawning — the
#      backlog item is never lost (acceptance (c)).
#   C. capture-only (no --spawn): NEVER calls the spawn path (acceptance (d)).
#   D. --spawn + gh FAILS: no spurious spawn (the create failure surfaces instead).
#
# Exit 0 = pass; non-zero = fail (prints the failing assertion + captured output).
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
NEW="$BIN/dash-issue-new.sh"
LIB="$BIN/fleet-lib.sh"
[ -f "$NEW" ] || { echo "selftest: $NEW missing" >&2; exit 2; }
[ -f "$LIB" ] || { echo "selftest: $LIB missing" >&2; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/newspawn-selftest.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT

pass=0
ok()   { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1" >&2; [ -n "${2:-}" ] && printf -- '--- output ---\n%s\n' "$2" >&2; exit 1; }

mkdir -p "$WORK/bin" "$WORK/fakebin" "$WORK/conf" "$WORK/tmp/.claude-dash"
SPAWN_LOG="$WORK/spawns"; DISPLAY_LOG="$WORK/display"; GH_LOG="$WORK/ghcreate"

# Symlink the REAL scripts under test; stub the siblings BIN resolves to.
ln -s "$NEW" "$WORK/bin/dash-issue-new.sh"
ln -s "$LIB" "$WORK/bin/fleet-lib.sh"
cat > "$WORK/bin/dash-issue-session.sh" <<SPAWNSTUB
#!/bin/bash
printf '%s\n' "\$*" >> "$SPAWN_LOG"
exit "\${SPAWN_RC:-0}"
SPAWNSTUB
printf '#!/bin/bash\nexit 0\n' > "$WORK/bin/tmux-dash-collect.sh"
chmod +x "$WORK/bin/dash-issue-session.sh" "$WORK/bin/tmux-dash-collect.sh"

# --- fake gh: log + control `issue create`; report a URL with the new number ----
cat > "$WORK/fakebin/gh" <<GHFAKE
#!/bin/bash
case "\${1:-} \${2:-}" in
  "issue create")
    printf 'create\n' >> "$GH_LOG"
    [ "\${GH_FAIL:-0}" = 1 ] && exit 1
    printf 'https://github.com/acme/widgets/issues/%s\n' "\${NEW_NUM:-205}" ;;
  *) : ;;
esac
exit 0
GHFAKE

# --- fake tmux: answer session_name via -p; log status display-message text -----
cat > "$WORK/fakebin/tmux" <<TMUXFAKE
#!/bin/bash
if [ "\${1:-}" = "-L" ] || [ "\${1:-}" = "-S" ]; then shift 2; fi
case "\${1:-}" in
  display-message)
    case "\$*" in
      *-p*) case "\$*" in *session_name*) echo testsess ;; *) echo '' ;; esac ;;
      *) shift; printf '%s\n' "\$*" >> "$DISPLAY_LOG" ;;
    esac ;;
  *) : ;;
esac
exit 0
TMUXFAKE
chmod +x "$WORK/fakebin/gh" "$WORK/fakebin/tmux"

# $1 = stdin text ; rest = args to dash-issue-new.sh ; env GH_FAIL / SPAWN_RC pass through
run_new() {
  local stdin="$1"; shift
  : > "$SPAWN_LOG"; : > "$DISPLAY_LOG"; : > "$GH_LOG"
  printf '%s' "$stdin" | \
  PATH="$WORK/fakebin:$PATH" TMPDIR="$WORK/tmp" FLEET_CONF_DIR="$WORK/conf" \
  FLEET_REPO="acme/widgets" \
    bash "$WORK/bin/dash-issue-new.sh" "$@" >"$WORK/out" 2>"$WORK/err"
}

# ============================ A: happy quick-dispatch =========================
# title + empty body; spawn succeeds (SPAWN_RC unset → 0).
run_new $'Add a widget\n\n' confirm --spawn
grep -q create "$GH_LOG"          || fail "A gh issue create was not called" "$(cat "$WORK/err")"
grep -Eq '^205( |$)' "$SPAWN_LOG" || fail "A spawn not invoked for the new issue #205" "$(cat "$SPAWN_LOG")"
# The spawn must carry the descriptive title so the window is named after the WORK,
# not the bare issue-<N> slug (issue #216). The stub logs $* → the quoted title
# flattens to space-separated words after --title.
grep -q -- '--title Add a widget' "$SPAWN_LOG" || fail "A spawn should pass the descriptive --title (issue #216)" "$(cat "$SPAWN_LOG")"
grep -qi 'spawned' "$DISPLAY_LOG" || fail "A success should display 'filed + spawned'" "$(cat "$DISPLAY_LOG")"
grep -qi 'New issue + worker' "$WORK/out" || fail "A --spawn popup verb should read 'New issue + worker'" "$(cat "$WORK/out")"
ok "A --spawn files the issue AND spawns the bound worker (with a descriptive --title)"

# ============================ B: cap refusal =================================
# spawn exits non-zero (cap reached). Feed a 3rd char for the 'press any key' read.
SPAWN_RC=1 run_new $'Add a widget\nsome body\nx' confirm --spawn
grep -q create "$GH_LOG"           || fail "B the issue must still be FILED on a cap refusal" "$(cat "$WORK/err")"
grep -Eq '^205( |$)' "$SPAWN_LOG"  || fail "B spawn should have been attempted" "$(cat "$SPAWN_LOG")"
grep -qi 'NOT spawned' "$WORK/out" || fail "B cap refusal must announce filed-without-spawning" "$(cat "$WORK/out")"
grep -qi 'backlog' "$WORK/out"     || fail "B cap refusal should say the issue sits in the backlog" "$(cat "$WORK/out")"
ok "B cap refusal files-without-spawning (issue not lost)"

# ============================ C: capture-only ================================
# no --spawn → the backlog ⌃n path: never touches the spawn script (acceptance d).
run_new $'Add a widget\n\n' confirm
grep -q create "$GH_LOG"              || fail "C gh issue create was not called" "$(cat "$WORK/err")"
[ -s "$SPAWN_LOG" ] && fail "C capture-only must NOT spawn a worker" "$(cat "$SPAWN_LOG")"
grep -qi 'filed new issue' "$DISPLAY_LOG" || fail "C capture-only should display 'filed new issue'" "$(cat "$DISPLAY_LOG")"
grep -qi 'New issue + worker' "$WORK/out" && fail "C capture-only popup must NOT show the worker verb" "$(cat "$WORK/out")"
ok "C capture-only (no --spawn) files without spawning (⌃n behavior unchanged)"

# ============================ D: gh create fails =============================
# gh fails → surface the failure, do NOT spawn a phantom worker. 3rd char for read.
GH_FAIL=1 run_new $'Add a widget\n\nx' confirm --spawn
grep -q create "$GH_LOG"        || fail "D gh issue create should have been attempted" "$(cat "$WORK/err")"
[ -s "$SPAWN_LOG" ] && fail "D a failed create must NOT spawn a worker" "$(cat "$SPAWN_LOG")"
grep -qi 'failed' "$WORK/out"   || fail "D create failure should surface in the popup" "$(cat "$WORK/out")"
ok "D a failed create surfaces and spawns nothing"

printf '\nselftest OK: %s assertions passed (prefix+n quick-dispatch)\n' "$pass"
exit 0
