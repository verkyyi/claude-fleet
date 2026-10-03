#!/bin/bash
# fleet-crash-harvest-selftest.sh — the crash record (issue #1294):
#   bin/fleet-crash-harvest.py           the panic / Jetsam summary
#   bin/fleet-diskguard.sh --harvest-crash  on demand, and on a boot change (--watch)
#   fleet_metrics_append (fleet-lib.sh)  the per-minute machine-metrics rows
#
# The fixtures in bin/fixtures/crash/ are the two REAL reports of the 2026-10-03
# freeze, trimmed (device keys dropped, the panic's 898 processes cut to the
# largest few, the Jetsam's 1012 to 8): the answer this has to keep giving is
# "largest = git, 336.0 GB", and "watchdog timeout … compressor 100% (BAD)".
#
# Pinned:
#   1. the summary names the panic's first line, its Compressor Info line, the
#      Jetsam's largest process with its size, and the largest at panic;
#   2. a report is recorded ONCE — a rerun writes no second incident, and a
#      report older than --since is never read;
#   3. the boot-change tick harvests only never-seen reports and notifies once;
#      the same boot, or a new boot with nothing new, stays silent;
#   4. metrics: header names the columns, a row has every column, files past the
#      retention go, FLEET_METRICS=0 writes nothing;
#   5. the summary measures the fleet's own metrics before the panic;
#   6. no report dir (Linux) → the previous boot's kernel OOM lines.
# Hermetic: scratch conf dir + report dir; the notifier is a stub. Exit 0 = pass.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
FIX="$BIN/fixtures/crash"
for f in fleet-diskguard.sh fleet-crash-harvest.py fleet-lib.sh; do
  [ -f "$BIN/$f" ] || { printf 'selftest: %s not found\n' "$BIN/$f" >&2; exit 2; }
done
[ -d "$FIX" ] || { printf 'selftest: %s not found\n' "$FIX" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "selftest: SKIP (no python3)"; exit 0; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/crash-harvest-selftest.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT
CHECKS=0
fail() { printf 'selftest FAIL: %s\n' "$1" >&2; [ -n "${2:-}" ] && printf -- '--- output ---\n%s\n' "$2" >&2; exit 1; }
has() { CHECKS=$((CHECKS + 1)); case "$2" in *"$1"*) ;; *) fail "$3" "$2" ;; esac; }
hasnt() { CHECKS=$((CHECKS + 1)); case "$2" in *"$1"*) fail "$3" "$2" ;; esac; }
eq() { CHECKS=$((CHECKS + 1)); [ "$1" = "$2" ] || fail "$3 (got '$1', want '$2')"; }

REP="$WORK/reports"; mkdir -p "$REP"
cp "$FIX"/* "$REP/"
# an OLDER report (must stay outside --since) and a report-shaped non-report
cp "$FIX/JetsamEvent-2026-10-03-093255.ips" "$REP/JetsamEvent-2026-09-01-000000.ips"
printf 'not a report\n' > "$REP/node_2026-10-03-111537_macmini.diag"

cat > "$WORK/notify" <<EOF
#!/bin/sh
printf '%s\n===\n' "\$1" >> "$WORK/notified"
EOF
chmod +x "$WORK/notify"

dg() {   # FLEET_CONF_DIR=… dg <args>
  env FLEET_CRASH_REPORT_DIR="$REP" FLEET_NOTIFY_CMD="$WORK/notify" FLEET_DISK_WARN_GB=0 \
    FLEET_ORPHAN_CPU_PCT=0 FLEET_ORPHAN_LISTEN_SECS=0 FLEET_MEM_PROBE_CMD='echo 1 60 5 0' \
    bash "$BIN/fleet-diskguard.sh" "$@"
}

# --- 1+2. manual harvest: the summary, recorded once ----------------------------
export FLEET_CONF_DIR="$WORK/c1"; M="$FLEET_CONF_DIR/machine"
out="$(dg --harvest-crash --since 2026-10-03T00:00)"; rc=$?
eq "$rc" 0 "harvest with reports in range exits 0"
has 'largest process: **git** (336.0 GB)' "$out" "Jetsam: largest = git, 336.0 GB"
has 'watchdog timeout: no checkins from watchdogd in 90 seconds' "$out" "panic first line"
has 'Compressor Info: 100% of compressed pages limit (BAD)' "$out" "panic Compressor Info line"
has 'largest resident at panic: git (pid 65334) 163.5 GB' "$out" "largest at panic"
has 'headline: 2026-10-03 09:32 jetsam largest=git (336.0 GB) · 2026-10-03 09:45 panic: watchdog timeout' "$out" "headline"
has '(new — recorded in' "$out" "first run records the reports"
hasnt '2026-09-01' "$out" "a report older than --since is not read"
hasnt 'node_2026' "$out" "a non-report .diag is not read"
eq "$(ls "$M"/incident-*.md | wc -l | tr -d ' ')" 1 "one incident file"
eq "$(ls "$M"/incident-*.md)" "$M/incident-20261003-0945.md" "incident named by the newest report"
eq "$(wc -l < "$M/crash-harvested" | tr -d ' ')" 2 "two reports in the ledger"
inc1="$(cat "$M/incident-20261003-0945.md")"
has 'top=git 163.5 GB' "$inc1" "incident carries the headline"

out="$(dg --harvest-crash --since 2026-10-03T00:00)"; rc=$?
eq "$rc" 0 "a rerun still prints the summary"
hasnt '(new — recorded' "$out" "a rerun records nothing new"
eq "$(wc -l < "$M/crash-harvested" | tr -d ' ')" 2 "the ledger does not grow on a rerun"
eq "$(ls "$M"/incident-*.md | wc -l | tr -d ' ')" 1 "no second incident on a rerun"

dg --harvest-crash --since 2026-10-04T00:00 >/dev/null 2>&1; rc=$?
eq "$rc" 1 "no report in range exits 1"

# --- 3. the boot-change tick ----------------------------------------------------
export FLEET_CONF_DIR="$WORK/c2"; M="$FLEET_CONF_DIR/machine"
mkdir -p "$M"; printf '2026-10-03T00:00:00\n' > "$M/last-harvest"
rm -f "$WORK/notified"
FLEET_BOOT_ID_CMD='echo boot-A' dg --watch
eq "$(cat "$M/boot-id")" boot-A "the tick records the boot id"
[ -f "$WORK/notified" ] || fail "a boot change with new reports notifies"
n="$(cat "$WORK/notified")"
has 'crashed and rebooted' "$n" "the notice says what happened"
has 'jetsam largest=git (336.0 GB)' "$n" "the notice carries the headline"
has "$M/incident-20261003-0945.md" "$n" "the notice names the summary"

rm -f "$WORK/notified"
FLEET_BOOT_ID_CMD='echo boot-A' dg --watch
CHECKS=$((CHECKS + 1)); [ -f "$WORK/notified" ] && fail "the same boot must not harvest again" "$(cat "$WORK/notified")"
FLEET_BOOT_ID_CMD='echo boot-B' dg --watch
CHECKS=$((CHECKS + 1)); [ -f "$WORK/notified" ] && fail "a new boot with no new report must stay silent" "$(cat "$WORK/notified")"
eq "$(cat "$M/boot-id")" boot-B "the new boot id is recorded"

# a report written since the last harvest (named after it) → the next boot harvests it alone
nxt="$(date -v+1d '+%Y-%m-%d-%H%M%S' 2>/dev/null || date -d '+1 day' '+%Y-%m-%d-%H%M%S')"  # portable-ok: BSD/GNU both-ways
cp "$FIX/JetsamEvent-2026-10-03-093255.ips" "$REP/JetsamEvent-$nxt.ips"
FLEET_BOOT_ID_CMD='echo boot-C' dg --watch
[ -f "$WORK/notified" ] || fail "a new boot with a new report notifies"
n="$(cat "$WORK/notified")"
eq "$(grep -c 'crashed and rebooted' "$WORK/notified")" 1 "exactly one notice"
hasnt '09:45 panic' "$n" "an already-harvested panic is not re-reported"
rm -f "$REP/JetsamEvent-$nxt.ips"

# --- 4. metrics rows: header, columns, retention, off switch --------------------
today="$(date '+%Y%m%d')"; mf="$M/metrics-$today.tsv"
[ -s "$mf" ] || fail "the --watch tick appends a metrics row"
eq "$(sed -n 2p "$mf")" "# ts	load1	cores	pressure	avail_pct	compressor_pct	swap_mb	num_files	ptys	claude_procs	top_rss	src" "header names the columns"
eq "$(grep -v '^#' "$mf" | head -1 | awk -F'\t' '{print NF}')" 12 "a row carries every column"
eq "$(grep -v '^#' "$mf" | head -1 | cut -f4-7 | tr '\t' ' ')" "1 60 5 0" "the pressure columns are fleet_mem_probe's (C1's reading)"
eq "$(grep -v '^#' "$mf" | head -1 | cut -f12)" diskguard "the row names its writer"
rows="$(grep -vc '^#' "$mf")"
eq "$(grep -c '^# fleet machine metrics' "$mf")" 1 "the header is written once"
recent="$(date -v-2d '+%Y%m%d' 2>/dev/null || date -d '-2 days' '+%Y%m%d')"  # portable-ok: BSD/GNU both-ways
: > "$M/metrics-20000101.tsv"; : > "$M/metrics-$recent.tsv"; : > "$M/metrics-notes.tsv"
FLEET_BOOT_ID_CMD='echo boot-C' dg --watch
CHECKS=$((CHECKS + 1)); [ -e "$M/metrics-20000101.tsv" ] && fail "a metrics file past the 7-day retention is removed"
CHECKS=$((CHECKS + 1)); [ -e "$M/metrics-$recent.tsv" ] || fail "a 2-day-old metrics file is kept"
CHECKS=$((CHECKS + 1)); [ -e "$M/metrics-notes.tsv" ] || fail "a non-dated file is never pruned"
eq "$(grep -vc '^#' "$mf")" "$((rows + 1))" "each tick appends one row"
FLEET_METRICS=0 FLEET_BOOT_ID_CMD='echo boot-C' dg --watch
eq "$(grep -vc '^#' "$mf")" "$((rows + 1))" "FLEET_METRICS=0 appends nothing"

# --- 5. coverage: the fleet's own record of the run-up --------------------------
export FLEET_CONF_DIR="$WORK/c3"; M="$FLEET_CONF_DIR/machine"; mkdir -p "$M"
{ printf '# fleet machine metrics\n# cols\n'
  # a stale stretch, a 20-min gap, then a row a minute from 08:40 to 09:45 (-0700)
  printf '2026-10-03T07:00:00-0700\t1\t15\t1\t60\t5\t0\t1\t1\t1\t-\tdiskguard\n'
  for i in $(seq 0 65); do
    h=$(( 8 + (40 + i) / 60 )); m=$(( (40 + i) % 60 ))
    printf '2026-10-03T%02d:%02d:00-0700\t9\t15\t%d\t3\t99\t0\t22000\t40\t24\tgit:%d\tdiskguard\n' "$h" "$m" $(( i > 50 ? 4 : 2 )) $(( i * 1000 ))
  done
  printf '2026-10-03T09:50:00-0700\t1\t15\t1\t60\t5\t0\t1\t1\t1\t-\tdiskguard\n'   # after the panic
} > "$M/metrics-20261003.tsv"
out="$(dg --harvest-crash --since 2026-10-03T09:40)"
has 'fleet metrics before the panic: 65 min contiguous (66 rows), last row 30s before it' "$out" "coverage of the run-up"
has 'git:65000' "$out" "the last rows before the panic are shown"
hasnt '09:50:00' "$out" "a row after the panic is not 'before' it"

# --- 6. no report dir: the previous boot's kernel OOM lines (Linux) -------------
export FLEET_CONF_DIR="$WORK/c4"; M="$FLEET_CONF_DIR/machine"
out="$(FLEET_CRASH_JOURNAL_CMD='printf "kernel: eth0 up\nkernel: Out of memory: Killed process 4242 (git) total-vm:9000000kB\n"' \
  env FLEET_CRASH_REPORT_DIR="$WORK/none" bash "$BIN/fleet-diskguard.sh" --harvest-crash --since 2026-10-03)"
has 'headline: kernel OOM — kernel: Out of memory: Killed process 4242 (git)' "$out" "journal OOM summary"
hasnt 'eth0' "$out" "only the OOM lines are kept"
CHECKS=$((CHECKS + 1)); ls "$M"/incident-*.md >/dev/null 2>&1 || fail "the journal harvest writes an incident"

printf 'fleet-crash-harvest-selftest: PASS (%d checks)\n' "$CHECKS"
