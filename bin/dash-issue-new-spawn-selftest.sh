#!/bin/bash
# dash-issue-new-spawn-selftest.sh — hermetic tests for the prefix+n quick-dispatch
# path (issue #205): dash-issue-new.sh --spawn files an issue AND spawns its bound
# worker, sharing one script with the capture-only backlog ⌃n path. No network, no
# real repo, no tmux server — gh/tmux/fzf + the sibling spawn/collect scripts are faked.
#
# The interactive title read is `fzf --print-query` now (issue #429). Real fzf can't run
# in CI (it reads keys from /dev/tty), so we STUB fzf: the stub echoes $FZF_QUERY as the
# printed query and exits $FZF_RC — letting us drive the script's REAL exit-code handling
# (130 = Esc/Ctrl-C cancel; 0/1 = query accepted) and the whole create/spawn tail behind
# it, hermetically. (The structural shape of the input — fzf, no hand-rolled read loop — is
# pinned separately in dash-issue-new-fzf-input-selftest.sh.)
#
# The real dash-issue-new.sh + fleet-lib.sh are symlinked into a temp bin so the
# script computes BIN=<tempbin> and reaches our STUB dash-issue-session.sh /
# tmux-dash-collect.sh — letting us assert what it spawns without a tmux server.
#
#   A. --spawn + query + spawn-ok: files the issue, then BACKGROUND-spawns the
#      worker for the new issue number; the fzf header verb reads "New issue + worker"
#      and the filing is confirmed via a toast (issue #297).
#   B. --spawn + query + CAP REFUSAL (spawn exits non-zero): the issue is STILL
#      filed (gh create ran + the 'filed' toast) — the backlog item is never lost
#      (acceptance (c)); the spawn script owns the cap message.
#   C. capture-only (no --spawn): NEVER calls the spawn path (acceptance (d)); the fzf
#      header verb reads "New issue" WITHOUT the worker suffix.
#   D. --spawn + gh FAILS: no spurious spawn (the create failure surfaces instead).
#   F/G. fzf exit 130 (Esc/Ctrl-C) cancels the whole create on the spot (issue #429):
#      nothing is filed, nothing is spawned — whether the query is empty or partial.
#   H. empty query accepted (bare Enter, exit 1): the empty-title contract still cancels
#      (issue #297) — no create, no spawn.
#   E. dash ⌃n wiring: a fzf --bind on ctrl-n that runs this script with --spawn.
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
SPAWN_LOG="$WORK/spawns"; DISPLAY_LOG="$WORK/display"; GH_LOG="$WORK/ghcreate"; RS_LOG="$WORK/runshell"; FZF_LOG="$WORK/fzfargs"

# Symlink the REAL scripts under test; stub the siblings BIN resolves to.
ln -s "$NEW" "$WORK/bin/dash-issue-new.sh"
ln -s "$LIB" "$WORK/bin/fleet-lib.sh"
# The create now routes through the ONE issue channel (issue #332). Symlink the
# REAL fleet-issue-file.sh so the create actually runs (title-only, so it makes
# just the one faked `gh issue create` — no label list, no spawn from within it);
# dash-issue-new.sh still owns the background spawn + optimistic row.
ln -s "$BIN/fleet-issue-file.sh" "$WORK/bin/fleet-issue-file.sh"
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

# --- fake fzf: the interactive title widget is `fzf --print-query` now (issue #429).
# Real fzf needs a tty; the stub instead echoes $FZF_QUERY as the printed query and exits
# $FZF_RC, so we drive the script's REAL exit-code handling (130 = Esc/Ctrl-C cancel; the
# default 1 = Enter with no match, i.e. an accepted query). It logs its argv so the tests
# can assert the header verb ("New issue" vs "New issue + worker") the script builds. ----
cat > "$WORK/fakebin/fzf" <<FZFFAKE
#!/bin/bash
printf '%s\n' "\$*" >> "$FZF_LOG"          # record argv (header/prompt) for assertions
[ -n "\${FZF_QUERY:-}" ] && printf '%s\n' "\${FZF_QUERY}"   # --print-query echoes the typed line
exit "\${FZF_RC:-1}"                        # 130 = Esc/Ctrl-C; 0/1 = accepted (1 = no-match, our case)
FZFFAKE

# --- fake tmux: answer session_name via -p; log status display-message text; and
# LOG + EXECUTE run-shell so the backgrounded create (issue #304) actually runs and
# its gh create / spawn / toast are observable, mirroring real `run-shell -b`. ----
cat > "$WORK/fakebin/tmux" <<TMUXFAKE
#!/bin/bash
if [ "\${1:-}" = "-L" ] || [ "\${1:-}" = "-S" ]; then shift 2; fi
case "\${1:-}" in
  run-shell)
    shift; [ "\${1:-}" = "-b" ] && shift
    printf '%s\n' "\$1" >> "$RS_LOG"          # prove the create was backgrounded
    sh -c "\$1" ;;                             # mirror real run-shell: actually run it
  display-message)
    case "\$*" in
      *-p*) case "\$*" in *session_name*) echo testsess ;; *) echo '' ;; esac ;;
      *) shift; printf '%s\n' "\$*" >> "$DISPLAY_LOG" ;;
    esac ;;
  *) : ;;
esac
exit 0
TMUXFAKE
chmod +x "$WORK/fakebin/gh" "$WORK/fakebin/fzf" "$WORK/fakebin/tmux"

# Drive dash-issue-new.sh through the interactive phase with the fzf stub. The typed title
# and the fzf exit code come from FZF_QUERY / FZF_RC in the CALLER's env (e.g.
# `FZF_QUERY='...' run_new confirm --spawn`), so they reach the fzf subprocess. GH_FAIL /
# SPAWN_RC / NEW_NUM pass through the same way. stdin is /dev/null (fzf reads its own tty;
# the script feeds it `< /dev/null` regardless).
run_new() {
  : > "$SPAWN_LOG"; : > "$DISPLAY_LOG"; : > "$GH_LOG"; : > "$RS_LOG"; : > "$FZF_LOG"
  PATH="$WORK/fakebin:$PATH" TMPDIR="$WORK/tmp" FLEET_CONF_DIR="$WORK/conf" \
  FLEET_REPO="acme/widgets" \
    bash "$WORK/bin/dash-issue-new.sh" "$@" </dev/null >"$WORK/out" 2>"$WORK/err"
}

# The --spawn worker is spawned in the BACKGROUND (issue #297), so the stub may land a beat
# after dash-issue-new.sh has already returned. Poll the spawn log rather than asserting
# instantly. Up to ~3s.
wait_spawn() { # $1 = grep -E pattern
  local n=0
  while [ "$n" -lt 60 ]; do
    grep -Eq "$1" "$SPAWN_LOG" && return 0
    n=$((n + 1)); sleep 0.05
  done
  return 1
}

# ============================ A: happy quick-dispatch =========================
# title accepted via the fzf query; spawn succeeds in the background (SPAWN_RC unset → 0).
FZF_QUERY='Add a widget' run_new confirm --spawn
grep -q create "$GH_LOG"          || fail "A gh issue create was not called" "$(cat "$WORK/err")"
wait_spawn '^205( |$)'            || fail "A spawn not invoked for the new issue #205" "$(cat "$SPAWN_LOG")"
# The spawn must carry the descriptive title so the window is named after the WORK,
# not the bare issue-<N> slug (issue #216). The stub logs $* → the quoted title
# flattens to space-separated words after --title.
grep -q -- '--title Add a widget' "$SPAWN_LOG" || fail "A spawn should pass the descriptive --title (issue #216)" "$(cat "$SPAWN_LOG")"
grep -qi 'filed' "$DISPLAY_LOG"   || fail "A success should toast that the issue was filed" "$(cat "$DISPLAY_LOG")"
# The fzf header verb (issue #429: the popup label is fzf's --header now) reads the spawn
# variant — this is the interactive path telling the operator a worker will spawn too.
grep -q 'New issue + worker' "$FZF_LOG" || fail "A --spawn fzf header should read 'New issue + worker'" "$(cat "$FZF_LOG")"
# The whole create must be BACKGROUNDED (issue #304): dispatched via run-shell -b as
# a --title-file re-exec, so the popup returns before the create runs.
grep -q -- '--title-file=' "$RS_LOG" || fail "A create must be dispatched via run-shell -b (--title-file)" "$(cat "$RS_LOG")"
ok "A --spawn files the issue AND background-spawns the bound worker (descriptive --title, backgrounded)"

# ============================ B: cap refusal =================================
# spawn exits non-zero (cap reached) in the background. The issue is STILL filed
# (the 'filed' toast + optimistic row); dash-issue-session.sh owns the cap message.
FZF_QUERY='Add a widget' SPAWN_RC=1 run_new confirm --spawn
grep -q create "$GH_LOG"           || fail "B the issue must still be FILED on a cap refusal" "$(cat "$WORK/err")"
wait_spawn '^205( |$)'             || fail "B spawn should have been attempted" "$(cat "$SPAWN_LOG")"
grep -qi 'filed' "$DISPLAY_LOG"    || fail "B a cap refusal must still confirm the issue was filed (not lost)" "$(cat "$DISPLAY_LOG")"
ok "B cap refusal files-without-spawning (issue not lost)"

# ============================ C: capture-only ================================
# no --spawn → the backlog ⌃n path: never touches the spawn script (acceptance d), and the
# fzf header verb is "New issue" WITHOUT the worker suffix.
FZF_QUERY='Add a widget' run_new confirm
grep -q create "$GH_LOG"              || fail "C gh issue create was not called" "$(cat "$WORK/err")"
[ -s "$SPAWN_LOG" ] && fail "C capture-only must NOT spawn a worker" "$(cat "$SPAWN_LOG")"
grep -qi 'filed new issue' "$DISPLAY_LOG" || fail "C capture-only should display 'filed new issue'" "$(cat "$DISPLAY_LOG")"
grep -q 'New issue + worker' "$FZF_LOG" && fail "C capture-only fzf header must NOT show the worker verb" "$(cat "$FZF_LOG")"
grep -q 'New issue' "$FZF_LOG"        || fail "C capture-only fzf header should read 'New issue'" "$(cat "$FZF_LOG")"
ok "C capture-only (no --spawn) files without spawning (⌃n behavior unchanged)"

# ============================ D: gh create fails =============================
# gh fails → surface the failure, do NOT spawn a phantom worker. The create runs in the
# BACKGROUND (issue #304), so the failure toasts via display-message (the popup is already
# gone) rather than printing to the popup's stdout.
GH_FAIL=1 FZF_QUERY='Add a widget' run_new confirm --spawn
grep -q create "$GH_LOG"           || fail "D gh issue create should have been attempted" "$(cat "$WORK/err")"
[ -s "$SPAWN_LOG" ] && fail "D a failed create must NOT spawn a worker" "$(cat "$SPAWN_LOG")"
grep -qi 'failed' "$DISPLAY_LOG"   || fail "D create failure should toast via display-message" "$(cat "$DISPLAY_LOG")"
ok "D a failed create surfaces (toast) and spawns nothing"

# ============================ F: fzf Esc cancels (empty query) ===============
# fzf exit 130 (Esc/Ctrl-C) cancels the whole create on the spot (issue #429): no gh
# create, no spawn — even in --spawn mode, even though a query may have been typed.
FZF_RC=130 run_new confirm --spawn
[ -s "$GH_LOG" ]    && fail "F fzf exit 130 must cancel before any gh issue create" "$(cat "$GH_LOG")"
[ -s "$SPAWN_LOG" ] && fail "F fzf exit 130 must cancel before any spawn" "$(cat "$SPAWN_LOG")"
ok "F fzf exit 130 (Esc/Ctrl-C) cancels the create directly (no issue filed, no worker spawned)"

# ============================ G: fzf Esc cancels (partial query) =============
# fzf reports 130 even with a partial query in the field (Esc discards it) — still cancels.
FZF_QUERY='partial' FZF_RC=130 run_new confirm --spawn
[ -s "$GH_LOG" ]    && fail "G fzf exit 130 after typing must still cancel (nothing filed)" "$(cat "$GH_LOG")"
[ -s "$SPAWN_LOG" ] && fail "G fzf exit 130 after typing must not spawn" "$(cat "$SPAWN_LOG")"
ok "G fzf exit 130 with a partial query cancels the create (Esc discards the typed title)"

# ============================ H: empty accepted query cancels ================
# An accepted-but-empty query (bare Enter → exit 1, no printed line) still cancels: the ⌃n
# one-line-filer's empty-title contract (issue #297) is unchanged by the fzf switch.
FZF_QUERY='' FZF_RC=1 run_new confirm --spawn
[ -s "$GH_LOG" ]    && fail "H an empty accepted query must cancel before any gh issue create" "$(cat "$GH_LOG")"
[ -s "$SPAWN_LOG" ] && fail "H an empty accepted query must not spawn" "$(cat "$SPAWN_LOG")"
ok "H an empty accepted query cancels the create (empty-title contract intact)"

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

printf '\nselftest OK: %s assertions passed (quick-dispatch: title-only, bg spawn, fzf exit-130 cancel + dash ⌃n)\n' "$pass"
exit 0
