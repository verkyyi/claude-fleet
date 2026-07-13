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
#   A. --spawn + gh-ok + spawn-ok: files the issue, then BACKGROUND-spawns the
#      worker for the new issue number; the popup verb reads "New issue + worker"
#      and the filing is confirmed via a toast (issue #297).
#   B. --spawn + gh-ok + CAP REFUSAL (spawn exits non-zero): the issue is STILL
#      filed (gh create ran + the 'filed' toast) — the backlog item is never lost
#      (acceptance (c)); the spawn script owns the cap message.
#   C. capture-only (no --spawn): NEVER calls the spawn path (acceptance (d)).
#   D. --spawn + gh FAILS: no spurious spawn (the create failure surfaces instead).
#   F/G. Esc (0x1b) cancels the whole create on the spot (issue #297): nothing is
#      filed, nothing is spawned — whether Esc is the first key or follows a partial
#      title.
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
    printf 'create %s\n' "\$*" >> "$GH_LOG"
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

# The --spawn worker is now spawned in the BACKGROUND (issue #297), so the stub
# may land a beat after dash-issue-new.sh has already returned. Poll the spawn log
# for the expected line rather than asserting on it instantly. Up to ~3s.
wait_spawn() { # $1 = grep -E pattern
  local n=0
  while [ "$n" -lt 60 ]; do
    grep -Eq "$1" "$SPAWN_LOG" && return 0
    n=$((n + 1)); sleep 0.05
  done
  return 1
}

# ============================ A: happy quick-dispatch =========================
# title only — no body prompt anymore (issue #297); spawn succeeds in the
# background (SPAWN_RC unset → 0).
run_new $'Add a widget\n' confirm --spawn
grep -q create "$GH_LOG"          || fail "A gh issue create was not called" "$(cat "$WORK/err")"
wait_spawn '^205( |$)'            || fail "A spawn not invoked for the new issue #205" "$(cat "$SPAWN_LOG")"
# The spawn must carry the descriptive title so the window is named after the WORK,
# not the bare issue-<N> slug (issue #216). The stub logs $* → the quoted title
# flattens to space-separated words after --title.
grep -q -- '--title Add a widget' "$SPAWN_LOG" || fail "A spawn should pass the descriptive --title (issue #216)" "$(cat "$SPAWN_LOG")"
grep -qi 'filed' "$DISPLAY_LOG"   || fail "A success should toast that the issue was filed" "$(cat "$DISPLAY_LOG")"
grep -qi 'New issue + worker' "$WORK/out" || fail "A --spawn popup verb should read 'New issue + worker'" "$(cat "$WORK/out")"
ok "A --spawn files the issue AND background-spawns the bound worker (descriptive --title)"

# ============================ B: cap refusal =================================
# spawn exits non-zero (cap reached) in the background. The issue is STILL filed
# (the 'filed' toast + optimistic row); dash-issue-session.sh owns the cap message.
SPAWN_RC=1 run_new $'Add a widget\n' confirm --spawn
grep -q create "$GH_LOG"           || fail "B the issue must still be FILED on a cap refusal" "$(cat "$WORK/err")"
wait_spawn '^205( |$)'             || fail "B spawn should have been attempted" "$(cat "$SPAWN_LOG")"
grep -qi 'filed' "$DISPLAY_LOG"    || fail "B a cap refusal must still confirm the issue was filed (not lost)" "$(cat "$DISPLAY_LOG")"
ok "B cap refusal files-without-spawning (issue not lost)"

# ============================ C: capture-only ================================
# no --spawn → the backlog ⌃n path: never touches the spawn script (acceptance d).
run_new $'Add a widget\n' confirm
grep -q create "$GH_LOG"              || fail "C gh issue create was not called" "$(cat "$WORK/err")"
[ -s "$SPAWN_LOG" ] && fail "C capture-only must NOT spawn a worker" "$(cat "$SPAWN_LOG")"
grep -qi 'filed new issue' "$DISPLAY_LOG" || fail "C capture-only should display 'filed new issue'" "$(cat "$DISPLAY_LOG")"
grep -qi 'New issue + worker' "$WORK/out" && fail "C capture-only popup must NOT show the worker verb" "$(cat "$WORK/out")"
ok "C capture-only (no --spawn) files without spawning (⌃n behavior unchanged)"

# ============================ D: gh create fails =============================
# gh fails → surface the failure, do NOT spawn a phantom worker. 2nd char for read.
GH_FAIL=1 run_new $'Add a widget\nx' confirm --spawn
grep -q create "$GH_LOG"        || fail "D gh issue create should have been attempted" "$(cat "$WORK/err")"
[ -s "$SPAWN_LOG" ] && fail "D a failed create must NOT spawn a worker" "$(cat "$SPAWN_LOG")"
grep -qi 'failed' "$WORK/out"   || fail "D create failure should surface in the popup" "$(cat "$WORK/out")"
ok "D a failed create surfaces and spawns nothing"

# ============================ F: Esc cancels (first key) =====================
# Esc (0x1b) as the very first byte cancels the whole create on the spot (issue
# #297): no gh create, no spawn — even in --spawn mode.
run_new $'\x1b' confirm --spawn
[ -s "$GH_LOG" ]    && fail "F Esc must cancel before any gh issue create" "$(cat "$GH_LOG")"
[ -s "$SPAWN_LOG" ] && fail "F Esc must cancel before any spawn" "$(cat "$SPAWN_LOG")"
ok "F Esc cancels the create directly (no issue filed, no worker spawned)"

# ============================ G: Esc cancels (mid-title) =====================
# Esc after a partial title still cancels — the typed chars are discarded, unfiled.
run_new $'partial\x1b' confirm --spawn
[ -s "$GH_LOG" ]    && fail "G Esc after typing must still cancel (nothing filed)" "$(cat "$GH_LOG")"
[ -s "$SPAWN_LOG" ] && fail "G Esc after typing must not spawn" "$(cat "$SPAWN_LOG")"
ok "G Esc after a partial title cancels the create"

# ============================ E: dash ⌃n wiring =============================
# The dashboard fzf pane exposes this same quick-dispatch path as a ⌃n bind, so
# file+spawn is reachable from INSIDE the dash pane too, not just prefix+n
# (issue #226). Static assertion: a fzf --bind on ctrl-n that runs the very
# script under test with --spawn. Purely an extra entry point — behaviour is the
# prefix+n path already exercised by A–D above.
DASH="$BIN/tmux-dashboard.sh"
[ -f "$DASH" ] || fail "E $DASH missing"
grep -Eq -- 'ctrl-n:.*dash-issue-new\.sh.*--spawn' "$DASH" \
  || fail "E dashboard has no ⌃n bind invoking dash-issue-new.sh --spawn" "$(grep -n 'ctrl-n' "$DASH" || true)"
ok "E dash ⌃n bind wires into the quick-dispatch (dash-issue-new.sh --spawn)"

printf '\nselftest OK: %s assertions passed (quick-dispatch: title-only, bg spawn, Esc-cancel + dash ⌃n)\n' "$pass"
exit 0
