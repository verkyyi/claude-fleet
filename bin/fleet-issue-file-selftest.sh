#!/bin/bash
# fleet-issue-file-selftest.sh — hermetic tests for the ONE issue-filer channel
# bin/fleet-issue-file.sh (issue #332). No network, no real repo, no tmux server:
# gh + tmux are faked and the script runs from a temp bin so it sources the real
# fleet-lib.sh copy. Asserts the channel's contract:
#   A. title-only: `gh issue create` is called and the body carries the invisible
#      `<!-- fleet:from … -->` provenance marker; the URL is echoed on stdout.
#   B. --label + --priority: each valid label reaches `gh issue create`, and
#      --priority pN is mapped to the priority:pN label.
#   C. unknown label: REJECTED up front (exit 3) with NO `gh issue create`.
#   D. bad --priority: rejected (exit 2), no create.
#   E. missing --title: rejected (exit 2), no create.
#   F. --parent N: links the new issue as a sub-issue of N (the sub_issues POST
#      carries the child's numeric database id, not its #number).
#   G. --spawn: hands the new number to dash-issue-session.sh with the --title;
#      a spawn refusal (non-zero) still leaves the issue FILED (exit 0, URL echoed).
#   H. --from ROLE: forces the provenance marker's role word.
#   I. label set unreadable (gh label list empty): validation is SKIPPED and the
#      create proceeds (degrade-to-proceed, never a false reject during an outage).
#
# Exit 0 = pass; non-zero = fail (prints the failing assertion + captured output).
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
SRC="$BIN/fleet-issue-file.sh"
LIB="$BIN/fleet-lib.sh"
[ -f "$SRC" ] || { echo "selftest: $SRC missing" >&2; exit 2; }
[ -f "$LIB" ] || { echo "selftest: $LIB missing" >&2; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/fif-selftest.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT

pass=0
ok()   { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1" >&2; [ -n "${2:-}" ] && printf -- '--- output ---\n%s\n' "$2" >&2; exit 1; }

mkdir -p "$WORK/bin" "$WORK/fakebin"
GH_LOG="$WORK/ghlog"; SPAWN_LOG="$WORK/spawns"; BODY="$WORK/body"

# real channel + lib run from $WORK/bin so BIN resolves the copies and ../fleet.conf
# is absent (env FLEET_REPO wins) — fully hermetic.
cp "$SRC" "$WORK/bin/fleet-issue-file.sh"; cp "$LIB" "$WORK/bin/fleet-lib.sh"
chmod +x "$WORK/bin/fleet-issue-file.sh"
# Stub the spawn choke point the channel hands to on --spawn: log its args, honour
# SPAWN_RC so a cap-refusal (non-zero) can be simulated.
cat > "$WORK/bin/dash-issue-session.sh" <<'SPAWNSTUB'
#!/bin/bash
printf '%s\n' "$*" >> "$SPAWN_LOG"
exit "${SPAWN_RC:-0}"
SPAWNSTUB
chmod +x "$WORK/bin/dash-issue-session.sh"

# --- fake gh: label list (canonical set) · issue create (log body + args, echo a
# URL) · api (issue id lookup + sub_issues POST log). LABELS_EMPTY=1 makes the
# label list empty (an outage / label-less repo). GH_CREATE_FAIL=1 fails create. --
cat > "$WORK/fakebin/gh" <<'GHFAKE'
#!/bin/bash
case "$1" in
  label)
    [ "$2" = list ] && { [ "${LABELS_EMPTY:-0}" = 1 ] || printf 'enhancement\ncleanup\nbug\npriority:p0\npriority:p1\npriority:p2\n'; }
    ;;
  issue)
    if [ "$2" = create ]; then
      printf '%s\n' "$*" >> "$GH_LOG"
      # capture the --body verbatim so the marker can be asserted
      shift 2; b=''
      while [ "$#" -gt 0 ]; do case "$1" in --body) shift; b="$1";; esac; shift; done
      printf '%s' "$b" > "$BODY"
      [ "${GH_CREATE_FAIL:-0}" = 1 ] && exit 1
      printf 'https://github.com/acme/widgets/issues/%s\n' "${NEW_NUM:-777}"
    fi
    ;;
  api)
    printf 'api %s\n' "$*" >> "$GH_LOG"
    case "$2" in
      repos/*/issues/*) case "$2" in */sub_issues) : ;; *) echo "${CHILD_ID:-999888}" ;; esac ;;
    esac
    ;;
esac
exit 0
GHFAKE

# --- fake tmux: answer session_name via -p; everything else no-ops -------------
cat > "$WORK/fakebin/tmux" <<'TMUXFAKE'
#!/bin/bash
if [ "${1:-}" = -L ] || [ "${1:-}" = -S ]; then shift 2; fi
case "${1:-}" in
  display-message) case "$*" in *-p*) case "$*" in *session_name*) echo fifsess ;; *) echo '' ;; esac ;; esac ;;
esac
exit 0
TMUXFAKE
chmod +x "$WORK/fakebin/gh" "$WORK/fakebin/tmux"

# $@ = args to fleet-issue-file.sh ; env (GH_CREATE_FAIL / LABELS_EMPTY / SPAWN_RC
# / NEW_NUM / CHILD_ID) passes through. Records exit code in $RC, stdout/stderr.
run_fif() {
  : > "$GH_LOG"; : > "$SPAWN_LOG"; : > "$BODY"
  PATH="$WORK/fakebin:$PATH" GH_LOG="$GH_LOG" SPAWN_LOG="$SPAWN_LOG" BODY="$BODY" \
  FLEET_REPO="acme/widgets" \
    bash "$WORK/bin/fleet-issue-file.sh" "$@" >"$WORK/out" 2>"$WORK/err"
  RC=$?
}

# ============================ A: title-only ================================
run_fif --title "Add a widget"
[ "$RC" -eq 0 ]                         || fail "A title-only should succeed" "$(cat "$WORK/err")"
grep -q 'issue create' "$GH_LOG"        || fail "A gh issue create not called" "$(cat "$GH_LOG")"
grep -q 'github.com/acme/widgets/issues/777' "$WORK/out" || fail "A the URL must be echoed on stdout" "$(cat "$WORK/out")"
grep -q '<!-- fleet:from role=' "$BODY" || fail "A body must carry the fleet:from provenance marker" "$(cat "$BODY")"
ok "A title-only files + echoes the URL + stamps the fleet:from marker"

# ============================ B: labels + priority =========================
run_fif --title "Tidy" --label "enhancement,cleanup" --priority p1
[ "$RC" -eq 0 ]                               || fail "B valid labels should succeed" "$(cat "$WORK/err")"
grep -q -- '--label enhancement' "$GH_LOG"    || fail "B --label enhancement should reach create" "$(cat "$GH_LOG")"
grep -q -- '--label cleanup' "$GH_LOG"        || fail "B --label cleanup should reach create" "$(cat "$GH_LOG")"
grep -q -- '--label priority:p1' "$GH_LOG"    || fail "B --priority p1 should map to the priority:p1 label" "$(cat "$GH_LOG")"
ok "B valid labels + --priority pN reach gh issue create"

# ============================ C: unknown label rejected ====================
run_fif --title "Bad" --label "enhancement,not-a-real-label"
[ "$RC" -eq 3 ]                    || fail "C unknown label must exit 3 (got $RC)" "$(cat "$WORK/err")"
[ -s "$GH_LOG" ] && grep -q 'issue create' "$GH_LOG" && fail "C must NOT create when a label is unknown" "$(cat "$GH_LOG")"
grep -qi 'unknown label' "$WORK/err" || fail "C should explain the unknown label" "$(cat "$WORK/err")"
ok "C an unknown label is rejected up front (exit 3, no create)"

# ============================ D: bad priority ==============================
run_fif --title "x" --priority p9
[ "$RC" -eq 2 ]                       || fail "D bad --priority must exit 2 (got $RC)" "$(cat "$WORK/err")"
grep -q 'issue create' "$GH_LOG" && fail "D must NOT create on a bad --priority" "$(cat "$GH_LOG")"
ok "D a bad --priority is rejected (exit 2, no create)"

# ============================ E: missing title =============================
run_fif --body "orphan body"
[ "$RC" -eq 2 ]                       || fail "E missing --title must exit 2 (got $RC)" "$(cat "$WORK/err")"
grep -q 'issue create' "$GH_LOG" && fail "E must NOT create without a title" "$(cat "$GH_LOG")"
ok "E a missing --title is rejected (exit 2, no create)"

# ============================ F: --parent sub-issue link ===================
run_fif --title "Nest me" --parent 42
[ "$RC" -eq 0 ]                                   || fail "F parent link should succeed" "$(cat "$WORK/err")"
grep -q 'api repos/acme/widgets/issues/777 -q .id' "$GH_LOG" || fail "F must resolve the child's database id" "$(cat "$GH_LOG")"
grep -q 'api --method POST repos/acme/widgets/issues/42/sub_issues -F sub_issue_id=999888' "$GH_LOG" \
  || fail "F must POST the child DB id to the parent's sub_issues" "$(cat "$GH_LOG")"
ok "F --parent links the new issue as a sub-issue (child DB id, not #number)"

# ============================ G: --spawn hands off =========================
# happy: the spawn choke point is invoked with the descriptive --title.
run_fif --title "Ship it" --spawn
[ "$RC" -eq 0 ]                        || fail "G --spawn should succeed" "$(cat "$WORK/err")"
grep -q -- '--title Ship it' "$SPAWN_LOG" || fail "G --spawn must pass the descriptive --title" "$(cat "$SPAWN_LOG")"
grep -q '^777' "$SPAWN_LOG"           || fail "G --spawn must hand the new number to the choke point" "$(cat "$SPAWN_LOG")"
ok "G --spawn hands the new number + title to the spawn choke point"

# files-without-spawning: a spawn refusal (non-zero) must NOT fail the create.
SPAWN_RC=1 run_fif --title "Ship it" --spawn
[ "$RC" -eq 0 ]                       || fail "G2 a spawn refusal must still exit 0 (issue filed)" "$(cat "$WORK/err")"
grep -q 'issues/777' "$WORK/out"      || fail "G2 the issue must still be FILED (URL echoed) on a spawn refusal" "$(cat "$WORK/out")"
ok "G2 a spawn refusal files-without-spawning (issue not lost)"

# ============================ H: --from role ===============================
run_fif --title "By worker" --from worker
grep -q '<!-- fleet:from role=worker' "$BODY" || fail "H --from must force the marker role word" "$(cat "$BODY")"
ok "H --from ROLE forces the provenance marker's role"

# ============================ I: label set unreadable ======================
# gh label list empty (outage / no labels) → validation SKIPPED, create proceeds.
LABELS_EMPTY=1 run_fif --title "Degraded" --label "whatever-label"
[ "$RC" -eq 0 ]                        || fail "I an unreadable label set must degrade to proceed (got $RC)" "$(cat "$WORK/err")"
grep -q 'issue create' "$GH_LOG"       || fail "I create should still run when the label set is unreadable" "$(cat "$GH_LOG")"
ok "I an unreadable label set degrades to proceed (no false reject)"

printf '\nselftest OK: %s assertions passed (channel: validate · provenance · create · parent · spawn)\n' "$pass"
exit 0
