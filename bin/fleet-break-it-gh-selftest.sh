#!/bin/bash
# fleet-break-it-gh-selftest.sh — the docs/dev/BREAK-IT.md row of GitHub that takes
# the connection and never answers (issue #4840, EPIC #4839 C1). The drill runs
# the black-hole drill's sandbox (bin/gh-blackhole-selftest.sh, its proxy that
# never answers) on two rows that still hang today — the read before a dispatch
# (fleet-gh.sh issue view) and the merge gate (fleet-pr-verdict.sh) — cut at a
# short cap, and passes when every cell still reads what conf/gh-blackhole.rows
# records: the hang is REGISTERED, and the day a member bounds it (EPIC #4839 C2
# #4841) the row's 期望 flips to ok / fail in the same PR, never silently.
# Runner and timing helpers are bin/fleet-break-it-cred-selftest.sh's
# (BREAK_CRED_LIB=1); bin/fleet-break-it-selftest.sh's lockstep lint reads the
# drill names here too.
#
#   gh-blackhole-hang   bin/gh-blackhole-selftest.sh, conf/gh-blackhole.rows,
#                       bin/gh_blackhole.py, bin/fleet-gh.sh, bin/fleet-pr-verdict.sh
# shellcheck disable=SC2034  # CAP / SECS / WHY / WHAT are read by the sourced runner
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=fleet-break-it-cred-selftest.sh
BREAK_CRED_LIB=1 . "$BIN/fleet-break-it-cred-selftest.sh"

drill_gh_blackhole_hang() {
  CAP=60
  local d="$WORK/ghbh" t0 rc n
  mkdir -p "$d"
  t0=$(now)
  bash "$BIN/gh-blackhole-selftest.sh" --mode hang --rows 5,G2 --cap 3 --tsv "$d/table.tsv" > "$d/out" 2>&1
  rc=$?
  SECS=$(since "$t0")
  [ "$rc" = 0 ] || { WHY="the drill's cells differ from conf/gh-blackhole.rows (exit $rc): $(tail -n 12 "$d/out")"; return 1; }
  n=$(awk -F'\t' 'NR > 1 && $3 == "hang"' "$d/table.tsv" | wc -l | tr -d ' ')
  [ "$(awk -F'\t' 'NR > 1' "$d/table.tsv" | wc -l | tr -d ' ')" = 2 ] || { WHY="want 2 cells, got: $(cat "$d/table.tsv")"; return 1; }
  WHAT="GitHub 连上不回：$n/2 格仍卡到截断（期望登记为 hang，C2 #4841 起逐行翻成 ok）"
}

cred_run_drills "$0"
