#!/bin/bash
# fleet-pr-verdict-selftest.sh — hermetic tests for the issue #441 merge gate: the
# deterministic "may I merge this yet?" read a SELF-LANDING worker runs before it
# squash-merges its own PR.
#
# Two layers, tested where each lives:
#   FOLD — land_verdict (bin/fleet-land-lease.sh): (state, mergeable,
#          mergeStateStatus, draft, checks) → ONE verdict token. Pure function,
#          table-driven, no fakes. The strictness that separates a GATE from the
#          dash's glance lives here: a RED or still-RUNNING check outranks a CLEAN
#          mergeStateStatus (a repo whose CI is not a REQUIRED check reports CLEAN
#          while it is red), and MERGED/CLOSED report as themselves, not GONE.
#   CLI  — bin/fleet-pr-verdict.sh: the one `gh` read + exit-code contract
#          (0 READY · 1 any other verdict · 2 error), driven with `gh` faked on
#          PATH. No network, no git, no tmux.
#
# Exit 0 = pass; non-zero = fail (prints the failing assertion + detail).
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
CLI="$BIN/fleet-pr-verdict.sh"
[ -x "$CLI" ] || { echo "selftest: $CLI missing/not executable" >&2; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/prverdict-selftest.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT

pass=0
ok()   { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1" >&2; [ -n "${2:-}" ] && printf -- '--- detail ---\n%s\n' "$2" >&2; exit 1; }

# ===== FOLD: land_verdict ======================================================
# shellcheck source=/dev/null
. "$BIN/fleet-land-lease.sh"

v() { land_verdict "$1" "$2" "$3" "$4" "$5"; }
expect() {  # expect <want> <state> <mergeable> <mss> <draft> <checks>
  local want="$1"; shift
  local got; got=$(v "$@")
  [ "$got" = "$want" ] || fail "land_verdict($*) = $got, want $want"
}

# green + mergeable + up to date, with checks actually passing → the merge case.
expect READY   OPEN MERGEABLE CLEAN     '' pass
expect READY   OPEN MERGEABLE HAS_HOOKS '' pass
# No checks configured at all: nothing to wait for.
expect READY   OPEN MERGEABLE CLEAN     '' none
ok "READY only when the PR is mergeable AND its checks aren't red/running"

# THE #441 STRICTNESS: CLEAN means "nothing REQUIRED blocks the merge" — it does
# NOT mean CI is green. A non-required check that is red/running must still stop
# the gate, or a self-landing worker ships red.
expect FAILING OPEN MERGEABLE CLEAN     '' fail
expect PENDING OPEN MERGEABLE CLEAN     '' pending
expect FAILING OPEN MERGEABLE HAS_HOOKS '' fail
expect FAILING OPEN MERGEABLE UNSTABLE  '' fail
ok "a red/running check outranks a CLEAN mergeStateStatus (never ship red)"

# The rest of the taxonomy passes straight through land_classify.
expect BEHIND   OPEN MERGEABLE   BEHIND  '' pass
expect CONFLICT OPEN CONFLICTING BLOCKED '' pass
expect CONFLICT OPEN MERGEABLE   DIRTY   '' pass
expect BLOCKED  OPEN MERGEABLE   BLOCKED '' pass
expect FAILING  OPEN MERGEABLE   BLOCKED '' fail
expect PENDING  OPEN MERGEABLE   BLOCKED '' pending
expect DRAFT    OPEN MERGEABLE   CLEAN   DRAFT pass
ok "behind / conflict / blocked / draft fold through the shared taxonomy"

# Non-OPEN reports as ITSELF — the confirm-after-merge read must be able to tell
# "already landed" from "closed unmerged" (land_classify folds both to GONE).
expect MERGED MERGED '' '' '' pass
expect CLOSED CLOSED '' '' '' pass
[ "$(land_classify MERGED '' '' '' pass)" = GONE ] \
  || fail "land_classify should still fold non-OPEN to GONE (unchanged)"
ok "MERGED/CLOSED report as themselves; land_classify keeps its GONE fold"

# ===== CLI: bin/fleet-pr-verdict.sh ============================================
mkdir -p "$WORK/fakebin"
# fake gh: emits the 5-field TSV the real `gh pr view --jq` produces. GH_ROW is
# the canned row; GH_RC forces a non-zero exit (unknown PR / auth failure).
cat > "$WORK/fakebin/gh" <<'GHFAKE'
#!/bin/bash
[ "${GH_RC:-0}" != 0 ] && exit "${GH_RC}"
printf '%s\n' "${GH_ROW-}"
exit 0
GHFAKE
chmod +x "$WORK/fakebin/gh"

# Hermetic env: a private TMPDIR (the fleet runtime cache lives under it) and no
# global conf leaking in, so repo resolution is decided by --repo alone.
run_cli() {  # run_cli <args…> → sets OUT/ERR/RC
  OUT=$(env PATH="$WORK/fakebin:$PATH" TMPDIR="$WORK" FLEET_SKIP_GLOBAL_CONF=1 \
            GH_ROW="${GH_ROW-}" GH_RC="${GH_RC:-0}" \
            bash "$CLI" "$@" 2>"$WORK/err"); RC=$?
  ERR=$(cat "$WORK/err")
}

# The five fields exactly as the real `gh … --jq` emits them: ONE PER LINE, so an
# empty mergeable/mss/draft stays its own field (a tab-separated row would collapse
# adjacent empties — tab is IFS whitespace — and shift `checks` onto `draft`).
row() { printf '%s\n%s\n%s\n%s\n%s' "$1" "$2" "$3" "$4" "$5"; }

GH_ROW=$(row OPEN MERGEABLE CLEAN '' pass); run_cli 77 --repo acme/widgets
[ "$OUT" = READY ] || fail "CLI should print READY for a green PR" "$OUT / $ERR"
[ "$RC" = 0 ]      || fail "CLI should exit 0 on READY (got $RC)" "$ERR"
ok "CLI prints READY and exits 0 for a green, mergeable PR"

GH_ROW=$(row OPEN MERGEABLE CLEAN '' fail); run_cli 77 --repo acme/widgets
[ "$OUT" = FAILING ] || fail "CLI should print FAILING for a red check" "$OUT / $ERR"
[ "$RC" = 1 ]        || fail "CLI should exit 1 on a non-READY verdict (got $RC)" "$ERR"
GH_ROW=$(row OPEN MERGEABLE BEHIND '' pass); run_cli 77 --repo acme/widgets
[ "$OUT" = BEHIND ] && [ "$RC" = 1 ] \
  || fail "CLI should print BEHIND / exit 1 for an out-of-date PR" "$OUT rc=$RC"
GH_ROW=$(row MERGED '' '' '' pass); run_cli 77 --repo acme/widgets
[ "$OUT" = MERGED ] && [ "$RC" = 1 ] \
  || fail "CLI should print MERGED / exit 1 once the PR has landed" "$OUT rc=$RC"
ok "CLI exit code is the gate: 0 only for READY, 1 for every other verdict"

# stdout stays ONE bare token even with -q; diagnostics are stderr-only.
GH_ROW=$(row OPEN MERGEABLE CLEAN '' pending); run_cli 77 --repo acme/widgets -q
[ "$OUT" = PENDING ] || fail "-q must still print the verdict token" "$OUT"
[ -z "$ERR" ]        || fail "-q must suppress the stderr note" "$ERR"
GH_ROW=$(row OPEN MERGEABLE CLEAN '' pending); run_cli 77 --repo acme/widgets
[ -n "$ERR" ] || fail "without -q the CLI should explain the verdict on stderr"
ok "stdout is the bare token; the human note is stderr-only (-q silences it)"

# Error contract: exit 2, and NOTHING on stdout that could read as a verdict.
GH_RC=1 GH_ROW='' run_cli 77 --repo acme/widgets
[ "$RC" = 2 ] || fail "a failed gh read must exit 2 (got $RC)" "$ERR"
[ -z "$OUT" ] || fail "a failed gh read must print no verdict" "$OUT"
GH_RC=0 GH_ROW='' run_cli 77 --repo acme/widgets
[ "$RC" = 2 ] || fail "an empty gh read (no such PR) must exit 2 (got $RC)" "$ERR"
GH_ROW=$(row OPEN MERGEABLE CLEAN '' pass); run_cli --repo acme/widgets
[ "$RC" = 2 ] || fail "a missing PR number must exit 2 (got $RC)" "$ERR"
GH_ROW=$(row OPEN MERGEABLE CLEAN '' pass); run_cli 77 --repo acme/widgets --bogus
[ "$RC" = 2 ] || fail "an unknown flag must exit 2 (got $RC)" "$ERR"
ok "errors (bad args, unreadable PR) exit 2 with an empty stdout"

# gh absent → exit 2, never a verdict guess. A PATH with no `gh` on it at all: the
# only external the CLI needs before that check is `dirname` (it resolves its own
# bin dir), so link just that in and invoke bash by absolute path — PATH is empty
# of everything else on purpose.
mkdir -p "$WORK/nogh"
ln -sf "$(command -v dirname)" "$WORK/nogh/dirname"
OUT=$(env PATH="$WORK/nogh" TMPDIR="$WORK" FLEET_SKIP_GLOBAL_CONF=1 \
          "$(command -v bash)" "$CLI" 77 --repo acme/widgets 2>"$WORK/err"); RC=$?
[ "$RC" = 2 ] || fail "no gh on PATH must exit 2 (got $RC)" "$(cat "$WORK/err")"
[ -z "$OUT" ] || fail "no gh on PATH must print no verdict" "$OUT"
ok "gh missing → exit 2, no verdict invented"

printf '\nfleet-pr-verdict-selftest: %d checks passed\n' "$pass"
exit 0
