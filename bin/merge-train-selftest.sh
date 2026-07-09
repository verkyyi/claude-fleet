#!/bin/bash
# merge-train-selftest.sh — hermetic smoke test for bin/merge-train.sh.
#
# Regression guard for issue #68: merge-train captured process_pr's stdout as
# its per-PR result token (`result=$(process_pr …)`), but note() also wrote to
# stdout, so the progress lines polluted $result → every `case "$result"` missed
# → the merged/ejected/skipped counters never incremented → the summary printed
# "0 merged" even after real merges. The bug shipped precisely because nothing
# asserted "summary counts == what actually happened". This is that assertion.
#
# It runs merge-train against a FAKE `gh` (no network, no real repo): the fake
# scripts a mixed batch — two mergeable PRs, one conflicting, one already-closed
# — and records every `gh pr merge` it is asked to perform. The test then checks
# the printed summary against BOTH the scripted expectation AND the fake's own
# merge log, so a recurrence of the capture-pollution bug (counts drift from the
# real merges) fails loudly.
#
# Exit 0 = pass. Non-zero = fail (and prints the captured output for triage).
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
MT="$BIN/merge-train.sh"
[ -x "$MT" ] || { printf 'selftest: %s not found/executable\n' "$MT" >&2; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/mt-selftest.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT
MERGE_LOG="$WORK/merged"
: > "$MERGE_LOG"

# --- fake gh -----------------------------------------------------------------
# Emulates only the calls merge-train makes in the batch path, keyed on PR number:
#   #1,#2 → OPEN + CLEAN + pass  → classify READY → `gh pr merge` succeeds (logged)
#   #3    → OPEN + DIRTY         → classify CONFLICT → ejected (never merged)
#   #4    → CLOSED               → classify GONE     → skipped  (never merged)
# `pr view` prints the exact TSV pr_fields expects (jq is emulated away); every
# `pr merge` appends its PR number to $MERGE_LOG so the test can compare the
# summary's merged count against the merges that actually occurred.
mkdir -p "$WORK/bin"
cat > "$WORK/bin/gh" <<GHFAKE
#!/bin/bash
# args: pr <action> <num> --repo <r> [flags...]
sub="\${1:-}"; action="\${2:-}"; num="\${3:-}"
[ "\$sub" = pr ] || exit 0
case "\$action" in
  view)
    case "\$num" in
      1|2) printf 'OPEN\tMERGEABLE\tCLEAN\t-\tpass\tsha-%s\n' "\$num" ;;
      3)   printf 'OPEN\tCONFLICTING\tDIRTY\t-\tpass\tsha-%s\n' "\$num" ;;
      4)   printf 'CLOSED\tMERGEABLE\tCLEAN\t-\tpass\tsha-%s\n' "\$num" ;;
      5)   printf 'OPEN\tMERGEABLE\tCLEAN\t-\tpass\tsha-%s\n' "\$num" ;;
      *)   printf 'OPEN\tMERGEABLE\tCLEAN\t-\tpass\tsha-%s\n' "\$num" ;;
    esac ;;
  merge)         printf '%s\n' "\$num" >> "$MERGE_LOG" ;;   # record the real merge
  update-branch) : ;;
  # No-arg discovery path (issue #73): merge-train reads "number<TAB>verdict"
  # lines from \`gh pr list --jq ...\`. Real gh evaluates the --jq server-side, so
  # the fake emits the post-jq TSV directly: #5 is a GREEN, un-armed, non-draft
  # PR that MUST be queued (proving discovery no longer requires auto-merge
  # arming); #3 is DIRTY and must be pre-filtered out.
  list)          printf '5\tqueue\n3\tdirty\n' ;;
esac
exit 0
GHFAKE
chmod +x "$WORK/bin/gh"

# --- run merge-train against the fake ----------------------------------------
# FLEET_REPO drives repo resolution (no tmux/cache needed); lease + poll knobs
# keep it hermetic and instant. merge-train sends progress+summary to stderr, so
# capture both streams.
out="$(
  PATH="$WORK/bin:$PATH" \
  FLEET_REPO="acme/widgets" \
  MERGE_TRAIN_LEASE_DIR="$WORK/leases" \
  MERGE_TRAIN_POLL=0 \
  MERGE_TRAIN_PR_TIMEOUT=30 \
  "$MT" 1 2 3 4 2>&1
)"

# --- assertions --------------------------------------------------------------
fail() { printf 'selftest FAIL: %s\n\n--- captured output ---\n%s\n' "$1" "$out" >&2; exit 1; }

actual_merges="$(grep -c . "$MERGE_LOG" 2>/dev/null || echo 0)"
[ "$actual_merges" -eq 2 ] || fail "fake performed $actual_merges merges, expected 2 (#1,#2)"

# The heart of #68: the summary must report what actually happened, not 0.
printf '%s\n' "$out" | grep -Eq '^  merged:  2( |$)'  || fail "summary 'merged' count != 2 (the #68 regression: counts stuck at 0)"
printf '%s\n' "$out" | grep -Eq '^  ejected: 1( |$)'  || fail "summary 'ejected' count != 1"
printf '%s\n' "$out" | grep -Eq '^  skipped: 1( |$)'  || fail "summary 'skipped' count != 1"

# Cross-check: the summary's merged count equals the merges the fake truly did.
summary_merged="$(printf '%s\n' "$out" | sed -n 's/^  merged:  \([0-9]*\).*/\1/p' | head -n1)"
[ "${summary_merged:-x}" = "$actual_merges" ] \
  || fail "summary merged=$summary_merged disagrees with actual merges=$actual_merges"

printf 'selftest OK: summary counts match reality (merged=2 ejected=1 skipped=1, %s real merges)\n' "$actual_merges"

# --- discovery path (issue #73): no-arg drains the ready queue -----------------
# Run merge-train with NO PR args so it auto-discovers via \`gh pr list\`. The fake
# returns "5\tqueue" (green, un-armed) + "3\tdirty". Correct behaviour: #5 is
# queued and merged (armed-status irrelevant now), #3 is pre-filtered out and
# never merged. This guards the #73 realignment: armed-only would have queued
# nothing here.
: > "$MERGE_LOG"
out2="$(
  PATH="$WORK/bin:$PATH" \
  FLEET_REPO="acme/widgets" \
  MERGE_TRAIN_LEASE_DIR="$WORK/leases2" \
  MERGE_TRAIN_POLL=0 \
  MERGE_TRAIN_PR_TIMEOUT=30 \
  "$MT" 2>&1
)"
fail2() { printf 'selftest FAIL: %s\n\n--- captured output ---\n%s\n' "$1" "$out2" >&2; exit 1; }

disc_merges="$(grep -c . "$MERGE_LOG" 2>/dev/null || echo 0)"
[ "$disc_merges" -eq 1 ] || fail2 "no-arg discovery performed $disc_merges merges, expected 1 (#5)"
grep -qx 5 "$MERGE_LOG" || fail2 "no-arg discovery did not merge the green un-armed PR #5"
printf '%s\n' "$out2" | grep -Eq '^  merged:  1( |$)' || fail2 "discovery summary 'merged' count != 1"
printf '%s\n' "$out2" | grep -q 'pre-filtered' || fail2 "discovery did not report the pre-filtered #3"

printf 'selftest OK: no-arg discovery drains the ready queue (queued+merged #5 regardless of auto-merge arming)\n'
