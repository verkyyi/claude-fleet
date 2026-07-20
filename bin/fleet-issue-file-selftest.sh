#!/bin/bash
# fleet-issue-file-selftest.sh — hermetic tests for the ONE issue-filer channel
# bin/fleet-issue-file.sh (issue #332). No network, no real repo, no tmux server:
# gh + tmux are faked and the script runs from a temp bin so it sources the real
# fleet-lib.sh copy. Asserts the channel's contract:
#   A. title-only: `gh issue create` is called and the body carries the invisible
#      `<!-- fleet:from … -->` provenance marker; the URL is echoed on stdout.
#   B. --label + --priority: each valid label reaches `gh issue create`, and
#      --priority pN is mapped to the priority:pN label.
#   C. off-taxonomy label: REJECTED up front (exit 3) with NO `gh issue create`.
#   D. bad --priority: rejected (exit 2), no create.
#   E. missing --title: rejected (exit 2), no create.
#   F. --parent N: links the new issue as a sub-issue of N (the sub_issues POST
#      carries the child's numeric database id, not its #number).
#   G. --spawn: hands the new number to dash-issue-session.sh with the --title;
#      a spawn refusal (non-zero) still leaves the issue FILED (exit 0, URL echoed).
#   H. --from ROLE: forces the provenance marker's role word.
#   I. fixed taxonomy (issue #333): validation is against the FIXED
#      fleet_labels_allowed set, NOT the live `gh label list` — a canonical label
#      absent from the repo's live labels is still ACCEPTED, and the channel makes
#      NO `gh label` read at all (deterministic, offline, no minting).
#   J. default milestone (issue #433): with FLEET_DEFAULT_MILESTONE set and NO
#      --milestone, the channel idempotently ensures the milestone exists and
#      passes `--milestone <default>` to `gh issue create`.
#   K. explicit --milestone WINS over the default (no ensure call for the default).
#   L. unset FLEET_DEFAULT_MILESTONE: unregressed — no ensure, no --milestone.
#   M. ensure-failure is BEST-EFFORT (issue #297): the milestone can't be created
#      and isn't present, so the issue still FILES (exit 0) WITHOUT a --milestone.
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

# --- fake gh: issue create (log body + args, echo a URL) · api (issue id lookup +
# sub_issues POST log). GH_CREATE_FAIL=1 fails create. The filer no longer reads
# labels (it validates against the fixed fleet_labels_allowed taxonomy, #333), so
# any `gh label` call is logged — a regression that re-introduces a round-trip is
# then caught by test I. --
cat > "$WORK/fakebin/gh" <<'GHFAKE'
#!/bin/bash
case "$1" in
  label)
    printf 'label %s\n' "$*" >> "$GH_LOG"
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
    # --- milestones (issue #433): POST create vs GET list. The path can sit after
    # `--method POST` so it isn't $2 — match anywhere in the args. MS_CREATE_FAIL=1
    # fails the idempotent create; MS_MISSING=1 makes the list omit it (together =
    # ensure-failure). Otherwise the list echoes MS_TITLE so the filer confirms it.
    if printf '%s ' "$@" | grep -q 'milestones'; then
      if printf '%s ' "$@" | grep -q -- '--method POST'; then
        [ "${MS_CREATE_FAIL:-0}" = 1 ] && exit 1        # create failed (perms/etc.)
      else
        [ "${MS_MISSING:-0}" = 1 ] || printf '%s\n' "${MS_TITLE:-Triage}"
      fi
      exit 0
    fi
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
  # FLEET_CONF_DIR points at an empty temp dir so the filer's per-fleet conf load
  # (issue #433, FLEET_DEFAULT_MILESTONE) finds nothing — the knob is driven only
  # by the env we pass, keeping every case hermetic.
  PATH="$WORK/fakebin:$PATH" GH_LOG="$GH_LOG" SPAWN_LOG="$SPAWN_LOG" BODY="$BODY" \
  FLEET_REPO="acme/widgets" FLEET_CONF_DIR="$WORK/conf" \
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

# ============================ C: off-taxonomy label rejected ===============
run_fif --title "Bad" --label "enhancement,not-a-real-label"
[ "$RC" -eq 3 ]                    || fail "C off-taxonomy label must exit 3 (got $RC)" "$(cat "$WORK/err")"
[ -s "$GH_LOG" ] && grep -q 'issue create' "$GH_LOG" && fail "C must NOT create when a label is off-taxonomy" "$(cat "$GH_LOG")"
grep -qi 'off-taxonomy label' "$WORK/err" || fail "C should explain the off-taxonomy label" "$(cat "$WORK/err")"
ok "C an off-taxonomy label is rejected up front (exit 3, no create)"

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

# ============================ I: fixed taxonomy, no gh read ================
# `scout` is canonical (fleet_labels_allowed) but was NOT in any live label list —
# it must be ACCEPTED (validation is against the FIXED set, #333), and the channel
# must make NO `gh label` call at all (deterministic, offline, no minting).
run_fif --title "Off-list canonical" --label "scout"
[ "$RC" -eq 0 ]                        || fail "I a canonical label must be accepted (got $RC)" "$(cat "$WORK/err")"
grep -q -- '--label scout' "$GH_LOG"   || fail "I the canonical label must reach create" "$(cat "$GH_LOG")"
grep -q '^label ' "$GH_LOG" && fail "I the channel must NOT read gh labels (fixed taxonomy)" "$(cat "$GH_LOG")"
ok "I validation is the fixed taxonomy, not the live label list (no gh label read)"

# ============================ J: default milestone applied ================
# FLEET_DEFAULT_MILESTONE set + NO --milestone → ensure the milestone (idempotent
# create) and pass --milestone <default> to create.
FLEET_DEFAULT_MILESTONE=Triage run_fif --title "Unsorted"
[ "$RC" -eq 0 ]                                        || fail "J default milestone should succeed" "$(cat "$WORK/err")"
grep -q 'api --method POST repos/acme/widgets/milestones' "$GH_LOG" \
  || fail "J must idempotently ensure the milestone (POST milestones)" "$(cat "$GH_LOG")"
grep -q -- '--milestone Triage' "$GH_LOG"             || fail "J create must carry --milestone Triage" "$(cat "$GH_LOG")"
ok "J FLEET_DEFAULT_MILESTONE defaults a milestone-less filing (ensured + applied)"

# ============================ K: explicit --milestone wins ================
FLEET_DEFAULT_MILESTONE=Triage run_fif --title "Has one" --milestone Roadmap
[ "$RC" -eq 0 ]                                        || fail "K explicit milestone should succeed" "$(cat "$WORK/err")"
grep -q -- '--milestone Roadmap' "$GH_LOG"            || fail "K explicit --milestone must reach create" "$(cat "$GH_LOG")"
grep -q -- '--milestone Triage' "$GH_LOG" && fail "K the default must NOT override an explicit --milestone" "$(cat "$GH_LOG")"
grep -q 'milestones' "$GH_LOG" && fail "K must NOT ensure the default when --milestone is explicit" "$(cat "$GH_LOG")"
ok "K an explicit --milestone wins over FLEET_DEFAULT_MILESTONE (no ensure)"

# ============================ L: unset default = unregressed ===============
run_fif --title "Plain"
[ "$RC" -eq 0 ]                                        || fail "L plain filing should succeed" "$(cat "$WORK/err")"
grep -q -- '--milestone' "$GH_LOG" && fail "L must NOT add a milestone when the knob is unset" "$(cat "$GH_LOG")"
grep -q 'milestones' "$GH_LOG" && fail "L must NOT touch the milestones API when the knob is unset" "$(cat "$GH_LOG")"
ok "L an unset FLEET_DEFAULT_MILESTONE is unregressed (no milestone, no API)"

# ============================ M: ensure-failure is best-effort =============
# The milestone can't be created (MS_CREATE_FAIL) and isn't present (MS_MISSING):
# the issue must still FILE (exit 0), just without a --milestone (issue #297).
MS_CREATE_FAIL=1 MS_MISSING=1 FLEET_DEFAULT_MILESTONE=Triage run_fif --title "Best effort"
[ "$RC" -eq 0 ]                                        || fail "M a milestone-ensure failure must still exit 0" "$(cat "$WORK/err")"
grep -q 'github.com/acme/widgets/issues/777' "$WORK/out" || fail "M the issue must still be FILED (URL echoed)" "$(cat "$WORK/out")"
grep -q -- '--milestone' "$GH_LOG" && fail "M must NOT pass --milestone when ensure failed" "$(cat "$GH_LOG")"
grep -qi 'could not ensure milestone' "$WORK/err"     || fail "M should warn that the milestone was skipped" "$(cat "$WORK/err")"
ok "M an ensure-failure files-without-milestone (fast path never wedged)"

printf '\nselftest OK: %s assertions passed (channel: validate · provenance · create · milestone · parent · spawn)\n' "$pass"
exit 0
