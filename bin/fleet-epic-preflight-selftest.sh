#!/bin/bash
# fleet-epic-preflight-selftest.sh — hermetic tests for bin/fleet-epic-preflight.sh,
# the "can this repo run an EPIC?" gate (issue #678).
#
# No network, no real repo, and NO tmux server: `gh` is faked, and so are the two
# scripts the preflight shells out to (fleet-labels-seed.sh, fleet-account.sh), so
# a `--fix` run here can never reach a real `gh label create`. The preflight runs
# from a temp bin/ beside a copy of the real fleet-lib.sh, with no ../fleet.conf —
# every input arrives as an env var. That is strictly more isolated than a scratch
# socket: there is no server for a stray call to land on at all.
#
# The contract under test is the THREE-WAY VERDICT the skill branches on, because
# a preflight that cannot tell "fix it yourself" from "wake the operator" is worse
# than none:
#   A. everything clear                        → READY,   exit 0
#   B. labels missing, nothing else wrong      → FIXABLE, exit 1  (read-only!)
#   C. --fix seeds them                        → READY,   exit 0, seeder invoked
#   D. gh unauthed                             → BLOCKED, exit 3
#   E. read-only permission                    → BLOCKED, exit 3
#   F. the sub-issues API 404s                 → BLOCKED, exit 3
#   G. a warn (base drift / slots / quota) never changes a READY verdict
#   H. no repo resolvable                      → exit 2
#   J. --session reads ANOTHER fleet's conf (repo + knobs together), and an
#      unknown fleet name is a usage error, not a half-answered screen
#
# Exit 0 = pass; non-zero = fail (prints the failing assertion + captured output).
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
SRC="$BIN/fleet-epic-preflight.sh"
LIB="$BIN/fleet-lib.sh"
[ -f "$SRC" ] || { echo "selftest: $SRC missing" >&2; exit 2; }
[ -f "$LIB" ] || { echo "selftest: $LIB missing" >&2; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/fep-selftest.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT

pass=0
ok()   { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1" >&2; [ -n "${2:-}" ] && printf -- '--- output ---\n%s\n' "$2" >&2; exit 1; }

mkdir -p "$WORK/bin" "$WORK/fakebin"
cp "$SRC" "$WORK/bin/fleet-epic-preflight.sh"; cp "$LIB" "$WORK/bin/fleet-lib.sh"
chmod +x "$WORK/bin/fleet-epic-preflight.sh"
SEED_LOG="$WORK/seedlog"

# --- fake gh -------------------------------------------------------------------
# Knobs (env): GH_AUTH=0 unauthed · GH_PERM=<viewerPermission> · GH_ISSUES=false
# · GH_SUBISSUE=404|err · GH_LABELS=<space-separated> · GH_NOISSUES=1 (nothing to
# probe). Writes nothing anywhere — the `label create` path is not even reachable
# from here, because the preflight only seeds through fleet-labels-seed.sh.
cat > "$WORK/fakebin/gh" <<'GHFAKE'
#!/bin/bash
case "$1 $2" in
  "auth status")  [ "${GH_AUTH:-1}" = 1 ] || exit 1; exit 0 ;;
  "repo view")
    printf '%s\t%s\t%s\n' "${GH_PERM:-WRITE}" "${GH_DEFBRANCH:-master}" "${GH_ISSUES:-true}"; exit 0 ;;
  "issue list")
    [ "${GH_NOISSUES:-0}" = 1 ] && { printf '\n'; exit 0; }
    printf '%s\n' "${GH_PROBE:-42}"; exit 0 ;;
  "label list")
    for l in ${GH_LABELS-epic autofill blocked bug}; do printf '%s\n' "$l"; done; exit 0 ;;
esac
# `gh api .../sub_issues` — the capability probe
case "$*" in
  *sub_issues*)
    case "${GH_SUBISSUE:-ok}" in
      404) echo 'gh: Not Found (HTTP 404)' >&2; exit 1 ;;
      err) echo 'gh: connection reset' >&2; exit 1 ;;
      *)   echo '[]'; exit 0 ;;
    esac ;;
esac
exit 0
GHFAKE

# --- fake tmux: answer session_name; everything else no-ops --------------------
cat > "$WORK/fakebin/tmux" <<'TMUXFAKE'
#!/bin/bash
if [ "${1:-}" = -L ] || [ "${1:-}" = -S ]; then shift 2; fi
case "${1:-}" in
  display-message) case "$*" in *session_name*) echo fepsess ;; *) echo '' ;; esac ;;
esac
exit 0
TMUXFAKE
chmod +x "$WORK/fakebin/gh" "$WORK/fakebin/tmux"

# --- fake seeder: log the invocation; make the labels "appear" via a marker file
# the fake gh cannot see, so the test drives the post-seed re-read explicitly with
# SEED_MAKES (the set the preflight should observe on its second `label list`).
cat > "$WORK/bin/fleet-labels-seed.sh" <<'SEEDFAKE'
#!/bin/bash
printf '%s\n' "$*" >> "$SEED_LOG"
[ -n "${SEED_MARKER:-}" ] && : > "$SEED_MARKER"
exit "${SEED_RC:-0}"
SEEDFAKE

# --- fake account pool: TSV rows exactly like fleet-account.sh quota --cached ---
# (label, 5h%, 7d%, headroom, …). QUOTA_ROWS='' ⇒ no pool at all.
cat > "$WORK/bin/fleet-account.sh" <<'ACCTFAKE'
#!/bin/bash
[ "${1:-}" = quota ] || exit 0
printf '%b' "${QUOTA_ROWS:-}"
exit 0
ACCTFAKE
chmod +x "$WORK/bin/fleet-labels-seed.sh" "$WORK/bin/fleet-account.sh"

# run_pf [args…] — env knobs pass through from the caller. Records $RC.
run_pf() {
  : > "$SEED_LOG"
  PATH="$WORK/fakebin:$PATH" SEED_LOG="$SEED_LOG" \
    bash "$WORK/bin/fleet-epic-preflight.sh" "$@" >"$WORK/out" 2>"$WORK/err"
  RC=$?
  OUT=$(cat "$WORK/out")
}

# A fleet whose every row is clean: WRITE, all labels, base == default, 5 slots,
# two roomy accounts. Each test perturbs exactly one thing.
# Every knob the preflight reads is named here, including CCQUOTA_HUB_URL: the pool
# state is an INPUT of the scenario, not something to inherit from whoever ran the
# test. (Not an "unset the operator's config" preamble — bin/run-selftests.sh's
# shadow root already owns that; this is the fixture declaring its own fleet.)
clean_env() {
  FLEET_REPO='acme/widgets' FLEET_BASE_BRANCH='master' FLEET_MAX_SESSIONS=5 \
  FLEET_GLOBAL_MAX_SESSIONS=8 FLEET_DEPLOY_REF='' FLEET_DEPLOY_CHECK='' \
  CCQUOTA_HUB_URL='https://quota.example' \
  QUOTA_ROWS='a\t10\t20\t80\nb\t30\t40\t60\n' "$@"
}

# ============================ A: all clear → READY / 0 =====================
clean_env run_pf
[ "$RC" -eq 0 ] || fail "A a clean repo must be READY (exit 0, got $RC)" "$OUT
$(cat "$WORK/err")"
printf '%s' "$OUT" | grep -q 'READY'          || fail "A must say READY" "$OUT"
printf '%s' "$OUT" | grep -q 'PASS  *labels'  || fail "A labels must PASS" "$OUT"
printf '%s' "$OUT" | grep -q 'PASS  *subissue' || fail "A subissue must PASS" "$OUT"
[ -s "$SEED_LOG" ] && fail "A a clean run must never invoke the seeder" "$(cat "$SEED_LOG")"
ok "A every gate clear → READY, exit 0, nothing written"

# ============================ B: missing labels → FIXABLE / 1 ==============
# The middle tier, and the reason the script exists: this must NOT read as a
# blocker, and must NOT seed anything without --fix.
GH_LABELS='bug enhancement' clean_env run_pf
[ "$RC" -eq 1 ] || fail "B missing labels must be FIXABLE (exit 1, got $RC)" "$OUT"
printf '%s' "$OUT" | grep -q 'FIXABLE'       || fail "B must say FIXABLE" "$OUT"
printf '%s' "$OUT" | grep -qE 'FIX .*labels' || fail "B the labels row must be FIX" "$OUT"
for l in epic autofill blocked; do
  printf '%s' "$OUT" | grep -q "$l" || fail "B must name the missing label $l" "$OUT"
done
[ -s "$SEED_LOG" ] && fail "B DEFAULT IS READ-ONLY — no --fix, no seeding" "$(cat "$SEED_LOG")"
ok "B missing labels are FIXABLE (exit 1) and nothing is seeded without --fix"

# ============================ B2: only `epic` missing is still FIXABLE =====
# The new label (#678) alone must be enough to hold the gate — a repo seeded
# before epic existed is exactly the case this catches.
GH_LABELS='autofill blocked bug' clean_env run_pf
[ "$RC" -eq 1 ]                                || fail "B2 a repo missing only epic must be FIXABLE (got $RC)" "$OUT"
printf '%s' "$OUT" | grep -qE 'FIX .*labels.*epic' || fail "B2 must name epic as the gap" "$OUT"
ok "B2 a repo seeded before \`epic\` existed is caught as FIXABLE"

# ============================ C: --fix seeds, then re-reads ================
# The fake gh flips to the full set once the seeder has run (SEED_MARKER), so this
# proves the preflight RE-READS rather than trusting the seeder's exit code.
cat > "$WORK/fakebin/gh" <<'GHFAKE2'
#!/bin/bash
case "$1 $2" in
  "auth status")  [ "${GH_AUTH:-1}" = 1 ] || exit 1; exit 0 ;;
  "repo view")    printf '%s\t%s\t%s\n' "${GH_PERM:-WRITE}" "${GH_DEFBRANCH:-master}" "${GH_ISSUES:-true}"; exit 0 ;;
  "issue list")   printf '%s\n' "${GH_PROBE:-42}"; exit 0 ;;
  "label list")
    if [ -n "${SEED_MARKER:-}" ] && [ -f "$SEED_MARKER" ]; then
      for l in epic autofill blocked bug; do printf '%s\n' "$l"; done
    else
      for l in ${GH_LABELS-bug}; do printf '%s\n' "$l"; done
    fi; exit 0 ;;
esac
case "$*" in *sub_issues*) echo '[]'; exit 0 ;; esac
exit 0
GHFAKE2
chmod +x "$WORK/fakebin/gh"

rm -f "$WORK/marker"
SEED_MARKER="$WORK/marker" GH_LABELS='bug' clean_env run_pf --fix
[ "$RC" -eq 0 ] || fail "C --fix must clear the gap → READY (exit 0, got $RC)" "$OUT
$(cat "$WORK/err")"
grep -q -- '--repo acme/widgets' "$SEED_LOG" || fail "C the seeder must be called for the resolved repo" "$(cat "$SEED_LOG")"
printf '%s' "$OUT" | grep -q 'PASS  *labels' || fail "C labels must PASS after the re-read" "$OUT"
ok "C --fix seeds through fleet-labels-seed.sh and re-reads the repo (READY, exit 0)"

# ============================ C2: --fix that does NOT help is a blocker ====
# Seeder ran, labels still absent ⇒ a human has to look. Never a silent READY.
rm -f "$WORK/marker"
SEED_MARKER='' GH_LABELS='bug' clean_env run_pf --fix
[ "$RC" -eq 3 ] || fail "C2 labels still missing after --fix must be BLOCKED (exit 3, got $RC)" "$OUT"
printf '%s' "$OUT" | grep -qE 'FAIL .*labels' || fail "C2 the labels row must FAIL" "$OUT"
ok "C2 a --fix that leaves the labels missing escalates to BLOCKED (never a silent pass)"

# restore the plain fake gh for the remaining cases
cat > "$WORK/fakebin/gh" <<'GHFAKE3'
#!/bin/bash
case "$1 $2" in
  "auth status")  [ "${GH_AUTH:-1}" = 1 ] || exit 1; exit 0 ;;
  "repo view")    printf '%s\t%s\t%s\n' "${GH_PERM:-WRITE}" "${GH_DEFBRANCH:-master}" "${GH_ISSUES:-true}"; exit 0 ;;
  "issue list")
    [ "${GH_NOISSUES:-0}" = 1 ] && { printf '\n'; exit 0; }
    printf '%s\n' "${GH_PROBE:-42}"; exit 0 ;;
  "label list")   for l in ${GH_LABELS-epic autofill blocked bug}; do printf '%s\n' "$l"; done; exit 0 ;;
esac
case "$*" in
  *sub_issues*)
    case "${GH_SUBISSUE:-ok}" in
      404) echo 'gh: Not Found (HTTP 404)' >&2; exit 1 ;;
      err) echo 'gh: connection reset' >&2; exit 1 ;;
      *)   echo '[]'; exit 0 ;;
    esac ;;
esac
exit 0
GHFAKE3
chmod +x "$WORK/fakebin/gh"

# ============================ D: gh unauthed → BLOCKED / 3 ================
GH_AUTH=0 clean_env run_pf
[ "$RC" -eq 3 ]                            || fail "D unauthed gh must be BLOCKED (exit 3, got $RC)" "$OUT"
printf '%s' "$OUT" | grep -q 'BLOCKED'     || fail "D must say BLOCKED" "$OUT"
printf '%s' "$OUT" | grep -qE 'FAIL .*gh'  || fail "D the gh row must FAIL" "$OUT"
ok "D an unauthed gh is a blocker (exit 3)"

# ============================ E: read-only permission → BLOCKED / 3 =======
GH_PERM=READ clean_env run_pf
[ "$RC" -eq 3 ]                              || fail "E READ permission must be BLOCKED (exit 3, got $RC)" "$OUT"
printf '%s' "$OUT" | grep -qE 'FAIL .*perm'  || fail "E the perm row must FAIL" "$OUT"
printf '%s' "$OUT" | grep -q 'READ'          || fail "E must name the permission it saw" "$OUT"
ok "E a repo the fleet cannot write to is a blocker (exit 3)"

# ============================ F: sub-issues API 404 → BLOCKED / 3 =========
GH_SUBISSUE=404 clean_env run_pf
[ "$RC" -eq 3 ]                                 || fail "F a 404 sub-issues API must be BLOCKED (exit 3, got $RC)" "$OUT"
printf '%s' "$OUT" | grep -qE 'FAIL .*subissue' || fail "F the subissue row must FAIL" "$OUT"
printf '%s' "$OUT" | grep -qi 'checklist'       || fail "F must name the checklist fallback as an operator decision" "$OUT"
ok "F a repo without the sub-issues API is a blocker, not a silent downgrade (exit 3)"

# ============================ F2: a transient probe error is a WARN =======
# "I could not ask" is not "the answer is no" — that distinction is the whole
# reason the 404 branch is narrow.
GH_SUBISSUE=err clean_env run_pf
[ "$RC" -eq 0 ]                                 || fail "F2 a transient probe error must not block (exit 0, got $RC)" "$OUT"
printf '%s' "$OUT" | grep -qE 'WARN .*subissue' || fail "F2 the subissue row must WARN" "$OUT"
ok "F2 an unreadable sub-issues probe warns; only a real 404 blocks"

# ============================ F3: nothing to probe against → WARN =========
GH_NOISSUES=1 clean_env run_pf
[ "$RC" -eq 0 ]                                 || fail "F3 an empty repo must not block (exit 0, got $RC)" "$OUT"
printf '%s' "$OUT" | grep -qE 'WARN .*subissue' || fail "F3 must warn that linking is unverified" "$OUT"
ok "F3 a repo with no issue to probe is warned about, not blocked"

# ============================ G: warns never change the verdict ===========
# Base drift, a too-wide session cap and an exhausted pool are all real problems
# — and all of them are the operator's call, so the exit code stays 0.
FLEET_REPO='acme/widgets' FLEET_BASE_BRANCH='dashboard-redesign' \
  FLEET_MAX_SESSIONS=0 FLEET_GLOBAL_MAX_SESSIONS=30 CCQUOTA_HUB_URL='https://quota.example' \
  QUOTA_ROWS='a\t97\t20\t3\nb\t40\t99\t1\n' run_pf
[ "$RC" -eq 0 ]                             || fail "G warns must not change a READY verdict (exit 0, got $RC)" "$OUT"
printf '%s' "$OUT" | grep -qE 'WARN .*base'  || fail "G base drift must WARN (#603)" "$OUT"
printf '%s' "$OUT" | grep -qE 'WARN .*slots' || fail "G a 30-wide cap must WARN (EPIC wants 4–6)" "$OUT"
printf '%s' "$OUT" | grep -qE 'WARN .*quota' || fail "G an exhausted pool must WARN" "$OUT"
printf '%s' "$OUT" | grep -q 'dashboard-redesign' || fail "G must name the drifted base" "$OUT"
printf '%s' "$OUT" | grep -q 'READY'         || fail "G the verdict is still READY" "$OUT"
ok "G base drift + a 30-wide cap + a full pool all warn without changing the verdict"

# ============================ G2: no pool configured is not a fault =======
FLEET_REPO='acme/widgets' FLEET_BASE_BRANCH='master' FLEET_MAX_SESSIONS=5 \
  FLEET_GLOBAL_MAX_SESSIONS=8 CCQUOTA_HUB_URL='' QUOTA_ROWS='' run_pf
[ "$RC" -eq 0 ]                              || fail "G2 no ccquota pool must stay READY (got $RC)" "$OUT"
printf '%s' "$OUT" | grep -qE 'PASS  *quota' || fail "G2 an absent pool is no opinion, not a warn" "$OUT"
ok "G2 a machine with no ccquota pool reading is READY (no opinion, not a fault)"

# ============================ G2b: a CONFIGURED but blind pool warns ======
# Zero rows means two opposite things, and for a batch the difference matters:
# "no pool" is no opinion, "pool configured, cache empty" is "I cannot tell you".
FLEET_REPO='acme/widgets' FLEET_BASE_BRANCH='master' FLEET_MAX_SESSIONS=5 \
  FLEET_GLOBAL_MAX_SESSIONS=8 CCQUOTA_HUB_URL='https://quota.example' QUOTA_ROWS='' run_pf
[ "$RC" -eq 0 ]                              || fail "G2b a blind pool must warn, not block (got $RC)" "$OUT"
printf '%s' "$OUT" | grep -qE 'WARN .*quota' || fail "G2b a configured-but-empty pool must WARN, not PASS" "$OUT"
ok "G2b a configured pool with an empty cache warns (blind ≠ no pool)"

# ============================ G3: deploy knobs are reported, not judged ===
FLEET_REPO='acme/widgets' FLEET_BASE_BRANCH='master' FLEET_MAX_SESSIONS=5 \
  FLEET_GLOBAL_MAX_SESSIONS=8 FLEET_DEPLOY_CHECK=actions CCQUOTA_HUB_URL='' QUOTA_ROWS='' run_pf
[ "$RC" -eq 0 ]                                       || fail "G3 FLEET_DEPLOY_CHECK=actions must stay READY (got $RC)" "$OUT"
printf '%s' "$OUT" | grep -qE 'PASS  *deploy.*actions' || fail "G3 must report the actions deploy gate (#541)" "$OUT"
ok "G3 the fleet's deploy criterion (#541) is reported on the deploy row"

# ============================ H: no repo → exit 2 =========================
FLEET_REPO='' run_pf
[ "$RC" -eq 2 ]                  || fail "H no resolvable repo must exit 2 (got $RC)" "$(cat "$WORK/err")"
grep -qi 'no repo' "$WORK/err"   || fail "H should explain the missing repo" "$(cat "$WORK/err")"
ok "H no resolvable repo is a usage error (exit 2), not a verdict"

# ============================ J: --session targets another fleet ===========
# Half the rows are repo facts and half are conf facts; --session must move BOTH,
# or the screen silently describes two fleets at once. Drive it through a real
# conf dir so fleet_conf_file/fleet_load_conf do the resolving, as they do live.
mkdir -p "$WORK/conf/fleets/fleet-other"
cat > "$WORK/conf/fleets/fleet-other/conf" <<'OTHERCONF'
FLEET_REPO="other/monorepo"
FLEET_BASE_BRANCH="master"
FLEET_MAX_SESSIONS=30
FLEET_DEPLOY_CHECK="actions"
OTHERCONF
FLEET_CONF_DIR="$WORK/conf" FLEET_REPO='acme/widgets' FLEET_BASE_BRANCH='master' \
  FLEET_MAX_SESSIONS=5 CCQUOTA_HUB_URL='' QUOTA_ROWS='' run_pf --session fleet-other
[ "$RC" -eq 0 ] || fail "J --session must resolve the other fleet cleanly (exit 0, got $RC)" "$OUT
$(cat "$WORK/err")"
printf '%s' "$OUT" | grep -q 'other/monorepo' \
  || fail "J --session must switch the REPO to the named fleet's" "$OUT"
printf '%s' "$OUT" | grep -qE 'WARN .*slots.*30' \
  || fail "J --session must also switch the CONF knobs (30 slots, not the caller's 5)" "$OUT"
printf '%s' "$OUT" | grep -qE 'PASS  *deploy.*actions' \
  || fail "J --session must read the named fleet's deploy criterion" "$OUT"
ok "J --session moves the repo AND the conf knobs together (no two-fleet screen)"

# ============================ J2: an unknown fleet is a usage error ========
FLEET_CONF_DIR="$WORK/conf" FLEET_REPO='acme/widgets' run_pf --session fleet-nope
[ "$RC" -eq 2 ] || fail "J2 an unknown --session must exit 2 (got $RC)" "$(cat "$WORK/err")"
grep -qi 'no conf for fleet' "$WORK/err" || fail "J2 should name the fleet it could not find" "$(cat "$WORK/err")"
ok "J2 an unknown --session is a usage error, never a screen about the wrong fleet"

# ============================ J3: --repo alone does NOT move the conf ======
# The honest-mixing rail: a bare --repo re-points only the repo, so the fleet rows
# still describe the CURRENT fleet — and the screen has to say so.
FLEET_REPO='acme/widgets' FLEET_BASE_BRANCH='master' FLEET_MAX_SESSIONS=5 \
  CCQUOTA_HUB_URL='' QUOTA_ROWS='' run_pf --repo other/monorepo
printf '%s' "$OUT" | grep -q 'overrides the repo only' \
  || fail "J3 a --repo that disagrees with the conf must say the fleet rows are still the current fleet's" "$OUT"
ok "J3 a bare --repo announces that the fleet rows still belong to the current fleet"

# ============================ I: the taxonomy actually carries the labels ==
# The preflight checks for three labels; fleet-labels-seed.sh can only create what
# fleet_labels_canonical lists. If those two drift, --fix promises a fix it cannot
# deliver — so pin the join here, against the REAL lib.
allowed=$(. "$WORK/bin/fleet-lib.sh"; fleet_labels_allowed)
for l in epic autofill blocked; do
  printf '%s\n' "$allowed" | grep -qxF -- "$l" \
    || fail "I $l must be in fleet_labels_canonical or --fix can never seed it" "$allowed"
done
# and the epic row must carry a color + a description that reads outside this repo
epicrow=$(. "$WORK/bin/fleet-lib.sh"; fleet_labels_canonical | grep '^epic|')
printf '%s' "$epicrow" | grep -qE '^epic\|[0-9A-Fa-f]{6}\|.{20,}' \
  || fail "I the epic row needs a 6-hex color and a self-explaining description" "$epicrow"
ok "I epic/autofill/blocked are all in the canonical taxonomy --fix seeds from"

printf '\nselftest OK: %s assertions passed (epic preflight: READY · FIXABLE · BLOCKED · warns · taxonomy join)\n' "$pass"
exit 0
