#!/bin/bash
# fleet-labels-seed-selftest.sh — hermetic tests for bin/fleet-labels-seed.sh, the
# canonical-label seeder (issue #333). No network, no real repo: `gh` is faked and
# the script runs from a temp bin so it sources the real fleet-lib.sh copy.
# Asserts the seeder's contract:
#   A. every canonical label (fleet_labels_canonical) is `gh label create --force`d
#      with its name + color + description, into the resolved repo; exit 0.
#   B. --force is ALWAYS passed — the idempotency rail (create-or-update, so a
#      re-run never errors on an existing label).
#   C. the seeded name set is EXACTLY fleet_labels_allowed (seed and the filer's
#      accepted set share one source of truth — they can't drift).
#   D. no repo resolved (no --repo, no FLEET_REPO): exit 1, no gh label create.
#   E. a `gh label create` failure surfaces as a non-zero exit (honest FAIL).
#
# Exit 0 = pass; non-zero = fail (prints the failing assertion + captured output).
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
SRC="$BIN/fleet-labels-seed.sh"
LIB="$BIN/fleet-lib.sh"
[ -f "$SRC" ] || { echo "selftest: $SRC missing" >&2; exit 2; }
[ -f "$LIB" ] || { echo "selftest: $LIB missing" >&2; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/fls-selftest.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT

pass=0
ok()   { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1" >&2; [ -n "${2:-}" ] && printf -- '--- output ---\n%s\n' "$2" >&2; exit 1; }

mkdir -p "$WORK/bin" "$WORK/fakebin"
GH_LOG="$WORK/ghlog"

# real seeder + lib run from $WORK/bin so BIN resolves the copies and ../fleet.conf
# is absent (env FLEET_REPO wins) — fully hermetic.
cp "$SRC" "$WORK/bin/fleet-labels-seed.sh"; cp "$LIB" "$WORK/bin/fleet-lib.sh"
chmod +x "$WORK/bin/fleet-labels-seed.sh"

# --- fake gh: log each `label create` line verbatim; echo nothing. GH_FAIL_ON is
# a label name whose create should fail (to exercise the failure path). ----------
cat > "$WORK/fakebin/gh" <<'GHFAKE'
#!/bin/bash
if [ "$1" = label ] && [ "$2" = create ]; then
  printf '%s\n' "$*" >> "$GH_LOG"
  # $3 is the label name; fail exactly that one when GH_FAIL_ON matches.
  [ -n "${GH_FAIL_ON:-}" ] && [ "$3" = "$GH_FAIL_ON" ] && exit 1
fi
exit 0
GHFAKE

# --- fake tmux: answer session_name via -p; everything else no-ops -------------
cat > "$WORK/fakebin/tmux" <<'TMUXFAKE'
#!/bin/bash
if [ "${1:-}" = -L ] || [ "${1:-}" = -S ]; then shift 2; fi
case "${1:-}" in
  display-message) case "$*" in *-p*) case "$*" in *session_name*) echo flssess ;; *) echo '' ;; esac ;; esac ;;
esac
exit 0
TMUXFAKE
chmod +x "$WORK/fakebin/gh" "$WORK/fakebin/tmux"

# $@ = args to fleet-labels-seed.sh ; env (FLEET_REPO / GH_FAIL_ON) passes through.
# Records exit code in $RC.
run_seed() {
  : > "$GH_LOG"
  PATH="$WORK/fakebin:$PATH" GH_LOG="$GH_LOG" \
    bash "$WORK/bin/fleet-labels-seed.sh" "$@" >"$WORK/out" 2>"$WORK/err"
  RC=$?
}

# expected taxonomy, straight from the real lib (single source of truth)
allowed=$(. "$WORK/bin/fleet-lib.sh"; fleet_labels_allowed)

# ============================ A: seeds every canonical label ===============
FLEET_REPO="acme/widgets" run_seed
[ "$RC" -eq 0 ]                                        || fail "A a clean seed should succeed" "$(cat "$WORK/err")"
# spot-check a name/color/description trio reached create in the target repo
grep -q -- 'label create bug --color D73A4A --description A real defect --force --repo acme/widgets' "$GH_LOG" \
  || fail "A bug must be seeded with its color + description into the repo" "$(cat "$GH_LOG")"
grep -q -- 'label create scout --color 0e8a16 ' "$GH_LOG" \
  || fail "A a repo-curated label (scout) must be seeded" "$(cat "$GH_LOG")"
grep -q -- 'label create priority:p0 --color B60205 ' "$GH_LOG" \
  || fail "A a namespaced label (priority:p0) must be seeded" "$(cat "$GH_LOG")"
ok "A every canonical label is created with its color + description in the repo"

# ============================ A2: --repo flag overrides FLEET_REPO =========
FLEET_REPO="other/repo" run_seed --repo acme/widgets
[ "$RC" -eq 0 ]                                        || fail "A2 --repo flag should succeed" "$(cat "$WORK/err")"
grep -q -- '--repo acme/widgets' "$GH_LOG"            || fail "A2 --repo must target the flag's repo" "$(cat "$GH_LOG")"
grep -q -- '--repo other/repo' "$GH_LOG" && fail "A2 --repo must WIN over FLEET_REPO" "$(cat "$GH_LOG")"
ok "A2 an explicit --repo wins over FLEET_REPO"

# ============================ B: --force on every create ===================
n_create=$(grep -c 'label create ' "$GH_LOG")
n_force=$(grep -c -- '--force' "$GH_LOG")
[ "$n_create" -eq "$n_force" ] && [ "$n_create" -gt 0 ] \
  || fail "B --force (idempotency rail) must be on every create ($n_force/$n_create)" "$(cat "$GH_LOG")"
ok "B --force is passed on every create (idempotent create-or-update)"

# ============================ C: seeded set == fleet_labels_allowed =========
# The set of names handed to `gh label create` must be EXACTLY fleet_labels_allowed.
seeded=$(sed -n 's/^label create \([^ ]*\) .*/\1/p' "$GH_LOG" | sort)
want=$(printf '%s\n' "$allowed" | sort)
[ "$seeded" = "$want" ] || fail "C seeded set must equal fleet_labels_allowed" "seeded:
$seeded
want:
$want"
ok "C the seeded name set is exactly fleet_labels_allowed (one source of truth)"

# ============================ D: no repo resolved ==========================
# FLEET_REPO='' overrides any value inherited from the caller's shell → no repo.
FLEET_REPO='' run_seed
[ "$RC" -eq 1 ]                       || fail "D no repo must exit 1 (got $RC)" "$(cat "$WORK/err")"
grep -q 'label create' "$GH_LOG" && fail "D must NOT create labels with no repo" "$(cat "$GH_LOG")"
grep -qi 'no repo' "$WORK/err"        || fail "D should explain the missing repo" "$(cat "$WORK/err")"
ok "D no resolved repo is rejected (exit 1, no create)"

# ============================ E: a create failure surfaces =================
GH_FAIL_ON="bug" FLEET_REPO="acme/widgets" run_seed
[ "$RC" -eq 1 ]                       || fail "E a create failure must exit non-zero (got $RC)" "$(cat "$WORK/err")"
grep -qi 'FAILED to seed bug' "$WORK/err" || fail "E should name the label that failed" "$(cat "$WORK/err")"
# the rest still get seeded (keep-going), so more than one create was attempted
[ "$(grep -c 'label create ' "$GH_LOG")" -gt 1 ] || fail "E must keep going past a single failure" "$(cat "$GH_LOG")"
ok "E a single create failure surfaces as a non-zero exit (keep-going, honest FAIL)"

printf '\nselftest OK: %s assertions passed (seeder: canonical set · --force · one source of truth · repo · failure)\n' "$pass"
exit 0
