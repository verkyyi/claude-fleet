#!/bin/bash
# fleet-ci-say.sh --title T --body B [any filer flag …] — what a CI check that once
# filed an issue does now: it SAYS it (issue #4898, EPIC #4895 — the issue filer
# left with the ticket layer; 红了只报警，不开单).
#
# The default "filer" of the train's quarantine (fleet-train-quarantine.sh) and the
# durations check (fleet-durations-drift.sh; the nightly's miss tracer left with
# #4900) — they take the filer's argv as they always did, so a
# selftest's FLEET_*_FILER seam is unchanged. It writes the title and body to the
# run's summary page ($GITHUB_STEP_SUMMARY) and one `::warning::` line on stderr,
# prints NOTHING on stdout (there is no issue URL) and exits 0. Every other flag
# (--repo, --breakage-key, --label, --fault-sha, …) is accepted and ignored.
set -u
title='' body='' key=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --title)        title=${2:-}; shift 2 ;;
    --body)         body=${2:-}; shift 2 ;;
    --breakage-key) key=${2:-}; shift 2 ;;
    --*)            if [ "$#" -gt 1 ] && [ "${2#--}" = "$2" ]; then shift 2; else shift; fi ;;
    *)              shift ;;
  esac
done
printf '::warning title=%s::%s\n' "${key:-fleet}" "$(printf '%s' "$title" | tr '\n' ' ')" >&2
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  { printf '\n### %s\n\n' "$title"; printf '%s\n' "$body"; } >> "$GITHUB_STEP_SUMMARY" 2>/dev/null || :
fi
exit 0
