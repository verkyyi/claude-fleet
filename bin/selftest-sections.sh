#!/bin/bash
# Shared by the linear shell selftests split in #3884. Each entry point runs
# one section in a fresh sandbox; SELFTEST_PART=all retains the full sequence.
# No background execution: run-selftests.sh schedules the ordinary part files.
selftest_sections() {
  SELFTEST_SECTION=${SELFTEST_PART:-1}
  case "$SELFTEST_SECTION" in
    all) ;;
    ''|0*|*[!0-9]*) echo 'selftest: SELFTEST_PART must be all or a section number' >&2; exit 2 ;;
    *) [ "$SELFTEST_SECTION" -ge 1 ] && [ "$SELFTEST_SECTION" -le "$1" ] || {
         echo "selftest: SELFTEST_PART must be in 1..$1" >&2; exit 2;
       } ;;
  esac
}
selftest_section() {
  [ "$SELFTEST_SECTION" = all ] && return 0
  case " $* " in *" $SELFTEST_SECTION "*) return 0 ;; esac
  return 1
}
