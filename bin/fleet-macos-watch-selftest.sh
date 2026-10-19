#!/bin/bash
# fleet-macos-watch-selftest.sh — bin/fleet-macos-watch.sh (issue #2286), hermetic.
#
# `gh` is a PATH shim serving the watched workflow's runs, each run's jobs
# (jobs.<run id>) and a job's failed log from files; the alert is a
# FLEET_MACOS_ALERT_CMD stand-in that logs its argv. Nothing touches GitHub, and
# nothing is filed (issue #4898: a red BSD half is said, not filed). Since #3120
# (EPIC #3111 C9) nothing is ever spawned: a stand-in for dash-issue-session.sh
# sits first on PATH and must stay unrun.
#
#   A. green          newest completed run green → `green`, nothing alerted, memo gone
#   B. red            ONE `breakage` alert on --session's fleet names the failed
#                     test, the failed job, the run and the commit the red streak
#                     started at; nobody is spawned; the run id is remembered
#   C. same run       not alerted again
#   D. throttle       inside FLEET_MACOS_WATCH_SECS nothing is read
#   F. alert fails    NOT remembered (retried next tick), exit 1
#   G. noise          a cancelled run and a pull_request run are no verdict; a
#                     train red only on Linux, or one with no macOS job, is not
#                     the BSD half's (issue #3143: the watcher reads the train)
#   H. --dry-run      prints the alert it would raise, raises and remembers nothing
#   I. off            FLEET_MACOS_WATCH=0 reads nothing
#   J. diskguard      fleet-diskguard.sh --watch's macos_watch drives it for a repo
#                     carrying both gate files, alerts, spawns nobody; a repo
#                     without them is never read; the dispatch shell is inert
#   K. held back      (issue #3869) the red streak began > FLEET_MACOS_STALE_SECS
#                     ago ⇒ ONE more alert «every Mac … previous version»; the next
#                     tick in the same streak says nothing; green forgets it. The
#                     default workflow is selftests-macos.yml (#4663: mac-follow holds nothing)
#   M. GitHub down    (issue #4841, fleet_gh_ready in bin/fleet-gh-lib.sh) the gh-down
#                     marker open ⇒ exit 0, nothing read / alerted / stamped; a previous
#                     watch still running (its lock's pid alive) ⇒ this one leaves; a
#                     dead holder's lock is taken over
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
W="$BIN/fleet-macos-watch.sh"
[ -f "$W" ] || { printf 'selftest: %s not found\n' "$W" >&2; exit 2; }
WORK="$(mktemp -d "${TMPDIR:-/tmp}/macos-watch-selftest.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT

CHECKS=0
fail() { printf 'selftest FAIL: %s\n' "$1" >&2; exit 1; }
eq() { CHECKS=$((CHECKS + 1)); [ "$2" = "$3" ] || fail "$1 — expected [$2], got [$3]"; }
contains() { CHECKS=$((CHECKS + 1)); case "$2" in *"$3"*) ;; *) fail "$1 — does not contain [$3]:
$2" ;; esac; }
lacks() { CHECKS=$((CHECKS + 1)); case "$2" in *"$3"*) fail "$1 — contains [$3]:
$2" ;; esac; }

mkdir -p "$WORK/shim" "$WORK/conf"
cat > "$WORK/shim/gh" <<SH
#!/bin/sh
case "\$*" in
  *actions/workflows/*) cat "$WORK/runs" ;;
  *actions/runs/*/jobs*) id=\${2#*actions/runs/}; id=\${id%%/*}; cat "$WORK/jobs.\$id" 2>/dev/null ;;
  *actions/jobs/*/logs*) cat "$WORK/log" 2>/dev/null ;;   # REST: run view --log-failed printed nothing (#4232)
esac
SH
cat > "$WORK/alert" <<SH
#!/bin/bash
printf '%s\n' "\$*" >> "$WORK/alerted"
exit \$(cat "$WORK/alert_rc" 2>/dev/null || echo 0)
SH
cat > "$WORK/shim/dash-issue-session.sh" <<SH
#!/bin/bash
printf '%s\n' "\$*" >> "$WORK/spawned"
SH
chmod +x "$WORK/shim/gh" "$WORK/alert" "$WORK/shim/dash-issue-session.sh"

S1=1111111aaaaaaa S2=2222222bbbbbbb S3=3333333ccccccc
row() { printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "${5:-}"; }
# jobs <run> green|red|linux|none — a train's jobs: macOS green / one macOS shard red /
# red on Linux only / no macOS job ran (a waiting train a newer push replaced)
jobs() {
  case "$2" in
    green) printf '1\tsuccess\tLinux / shard 1\n2\tsuccess\tmacOS / shard 1\n3\tsuccess\tmacOS / shard 2\n' ;;
    red)   printf '1\tsuccess\tLinux / shard 1\n2\tsuccess\tmacOS / shard 1\n901\tfailure\tmacOS / shard 2\n4\tskipped\trelease\n' ;;
    linux) printf '1\tfailure\tLinux / shard 1\n2\tcancelled\tmacOS / shard 1\n3\tcancelled\tmacOS / shard 2\n' ;;
    none)  : ;;
  esac > "$WORK/jobs.$1"
}
red_runs() {
  { row 30 "$S3" failure push; row 29 "$S2" failure push; row 28 "$S1" success schedule; } > "$WORK/runs"
  jobs 30 red; jobs 29 red; jobs 28 green
}
printf '2026-10-07T01:02:03Z FAIL  dash-marker-selftest.sh   12s\n2026-10-07T01:02:04Z selftest FAIL: a thing\n' > "$WORK/log"

run() {
  OUT=$(env PATH="$WORK/shim:$PATH" FLEET_CONF_DIR="$WORK/conf" FLEET_SKIP_GLOBAL_CONF=1 \
          FLEET_MACOS_ALERT_CMD="$WORK/alert" \
          bash "$W" --repo o/r "$@" 2>&1); RC=$?
}
memo() { cat "$WORK/conf/global/macos-watch/o-r.filed" 2>/dev/null || echo none; }
alerted() { cat "$WORK/alerted" 2>/dev/null; }
spawned() { [ -f "$WORK/spawned" ] && echo yes || echo no; }
reset() { rm -f "$WORK/spawned" "$WORK/alerted" "$WORK/alert_rc" "$WORK/jobs."* "$WORK/conf/global/macos-watch/"*; }

# --- A. green ------------------------------------------------------------------
reset; echo 9 > "$WORK/conf/stale"; mkdir -p "$WORK/conf/global/macos-watch"; echo 7 > "$WORK/conf/global/macos-watch/o-r.filed"
{ row 31 "$S3" success push; row 30 "$S2" failure push; } > "$WORK/runs"; jobs 31 green; jobs 30 red
run --now
eq "A: green exits 0" 0 "$RC"; contains "A: says green" "$OUT" "green	31"; eq "A: nothing alerted" "" "$(alerted)"; eq "A: memo forgotten" none "$(memo)"

# --- B. red --------------------------------------------------------------------
reset; red_runs
run --now --session fleet
eq "B: red exits 0" 0 "$RC"; contains "B: says alerted" "$OUT" "alerted	30	macOS 检查红了、Mac 停在上一版：dash-marker-selftest.sh"
A=$(alerted)
contains "B: one breakage alert on the fleet" "$A" "event -L fleet breakage"
contains "B: the alert names the test" "$A" "dash-marker-selftest.sh"
lacks "B: a bare 'FAIL: a thing' line is not a test name" "$OUT" "a thing"
contains "B: the title names the job" "$OUT" "（macOS / shard 2）"
contains "B: the alert names the streak's first red commit" "$A" "since 2222222"
contains "B: the alert links the run" "$A" "https://github.com/o/r/actions/runs/30"
eq "B: nobody spawned" no "$(spawned)"
eq "B: exactly one alert" 1 "$(alerted | wc -l | tr -d ' ')"
eq "B: run remembered" 30 "$(memo)"
lacks "B: nothing filed — no issue filer is named (#4898)" "$(cat "$W")" "issue-file"

# --- C. the same red run is not alerted again -------------------------------------
rm -f "$WORK/spawned" "$WORK/alerted"
run --now --session fleet
eq "C: exits 0" 0 "$RC"; contains "C: says already" "$OUT" "already, for this run"
eq "C: no second alert" "" "$(alerted)"

# --- D. throttle ------------------------------------------------------------------
reset; red_runs
printf '%s\n' "$(date +%s)" > "$WORK/conf/global/macos-watch/o-r.stamp" 2>/dev/null || { mkdir -p "$WORK/conf/global/macos-watch"; date +%s > "$WORK/conf/global/macos-watch/o-r.stamp"; }
run
eq "D: throttled exits 0" 0 "$RC"; eq "D: says nothing" "" "$OUT"; eq "D: nothing alerted" "" "$(alerted)"

# --- F. a failed alert is retried ---------------------------------------------------
reset; red_runs; echo 1 > "$WORK/alert_rc"
run --now --session fleet
eq "F: exits 1" 1 "$RC"; contains "F: says retried" "$OUT" "retried next tick"; eq "F: not remembered" none "$(memo)"

# --- G. cancelled / pull_request runs are no verdict ----------------------------------
reset
{ row 42 "$S3" failure push; row 41 "$S3" cancelled push; row 40 "$S3" cancelled push; row 39 "$S3" success pull_request
  row 38 "$S2" failure push; row 37 "$S1" success push; } > "$WORK/runs"
jobs 42 linux; jobs 41 none; jobs 40 linux; jobs 39 green; jobs 38 red; jobs 37 green
run --now
contains "G: the red macOS run under Linux-red / replaced / PR runs decides" "$OUT" "alerted	38"; eq "G: remembered 38" 38 "$(memo)"
contains "G: the streak starts at 38's commit" "$(alerted)" "since 2222222"
reset; { row 52 "$S3" failure push; row 51 "$S2" success push; } > "$WORK/runs"; jobs 52 linux; jobs 51 green
run --now
contains "G: a train red on Linux only leaves the BSD half green" "$OUT" "green	51"; eq "G: nothing alerted" "" "$(alerted)"

# --- H. --dry-run ------------------------------------------------------------------------
reset; red_runs
run --dry-run
eq "H: exits 0" 0 "$RC"; contains "H: says would-alert" "$OUT" "would-alert	30"; eq "H: nothing alerted" "" "$(alerted)"; eq "H: nothing remembered" none "$(memo)"

# --- I. off ---------------------------------------------------------------------------------
reset; red_runs
OUT=$(env PATH="$WORK/shim:$PATH" FLEET_CONF_DIR="$WORK/conf" FLEET_MACOS_WATCH=0 FLEET_MACOS_ALERT_CMD="$WORK/alert" \
        bash "$W" --repo o/r --now 2>&1); RC=$?
eq "I: off exits 0" 0 "$RC"; eq "I: says nothing" "" "$OUT"; eq "I: nothing alerted" "" "$(alerted)"

# --- J. the diskguard tick drives it, alerts, spawns nobody (#3120) ----------------------
reset; red_runs
mkdir -p "$WORK/mainA/.github/workflows" "$WORK/mainA/bin" "$WORK/mainB"
: > "$WORK/mainA/.github/workflows/selftests-macos.yml"; : > "$WORK/mainA/bin/fleet-stable.sh"
cat > "$WORK/dg.sh" <<SH
FLEET_DISKGUARD_SOURCE=1 . "$BIN/fleet-diskguard.sh"
BIN="$BIN" GDIR="$WORK/dg"
fleet_sockets() { echo fleet; }
fleet_conf_file() { echo "$WORK/fleet.conf"; }
fleet_load_conf() { :; }
fleet_repos() { printf 'o/r\no/biz\n'; }
fleet_load_repo_conf() { case "\$2" in o/r) FLEET_MAIN="$WORK/mainA" ;; *) FLEET_MAIN="$WORK/mainB" ;; esac; }
macos_watch
SH
: > "$WORK/fleet.conf"
env PATH="$WORK/shim:$PATH" FLEET_CONF_DIR="$WORK/conf" FLEET_SKIP_GLOBAL_CONF=1 \
  FLEET_MACOS_ALERT_CMD="$WORK/alert" bash "$WORK/dg.sh" >/dev/null 2>&1
i=0; while [ "$i" -lt 100 ] && ! grep -q 'alerted' "$WORK/dg/macos-watch.log" 2>/dev/null; do sleep 0.1; i=$((i + 1)); done
contains "J: diskguard's tick ran the watcher on the gated repo" "$(cat "$WORK/dg/macos-watch.log" 2>/dev/null)" "fleet o/r alerted	30"
contains "J: alerted on the fleet" "$(alerted)" "event -L fleet breakage"
eq "J: a repo without the gate files is never read" 1 "$(alerted | grep -c 'actions/runs/30')"
eq "J: nobody spawned" no "$(spawned)"
lacks "J: the watcher has no spawner left" "$(cat "$W")" "dash-issue-session"
eq "J: the retired dispatch shell is gone (#3576)" no "$([ -e "$BIN/fleet-dispatch.sh" ] && echo yes || echo no)"
eq "J: no dispatch daemon template left" no "$([ -e "$BIN/../launchd/com.claude-fleet.dispatch.plist.tmpl" ] && echo yes || echo no)"

# --- K. the Mac lane held back past FLEET_MACOS_STALE_SECS (#3869) ----------------------
reset
old=$(date -u -r $(( $(date +%s) - 3 * 3600 )) +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$(( $(date +%s) - 3 * 3600 ))" +%Y-%m-%dT%H:%M:%SZ)  # portable-ok: BSD || GNU
new=$(date -u +%Y-%m-%dT%H:%M:%SZ)
{ row 62 "$S3" failure workflow_run "$new"; row 61 "$S2" failure workflow_run "$old"; row 60 "$S1" success workflow_run "$old"; } > "$WORK/runs"
jobs 62 red; jobs 61 red; jobs 60 green
run --now --session fleet
contains "K: says the lane is held back" "$OUT" "stale	3h	2222222"
contains "K: the held-back alert" "$(alerted)" "macOS has been red for 3h+"
eq "K: two alerts (the red run + held back)" 2 "$(alerted | wc -l | tr -d ' ')"
rm -f "$WORK/alerted"; { row 63 "$S3" failure workflow_run "$new"; cat "$WORK/runs"; } > "$WORK/runs.n"; mv "$WORK/runs.n" "$WORK/runs"; jobs 63 red
run --now --session fleet
lacks "K: the same streak is not alerted twice" "$(alerted)" "has been red for"
FLEET_MACOS_STALE_SECS=99999 run --now
lacks "K: within the window nothing is said" "$OUT" "stale	"
{ row 64 "$S3" success workflow_run "$new"; cat "$WORK/runs"; } > "$WORK/runs.n"; mv "$WORK/runs.n" "$WORK/runs"; jobs 64 green
run --now
eq "K: green forgets the held-back mark" no "$([ -e "$WORK/conf/global/macos-watch/o-r.stale" ] && echo yes || echo no)"
contains "K: the watched workflow is selftests-macos.yml" "$(cat "$W")" 'FLEET_MACOS_WORKFLOW:-selftests-macos.yml'

# --- M. GitHub down / one watch at a time (#4841) ---------------------------------
reset; red_runs
OUT=$(env PATH="$WORK/shim:$PATH" FLEET_CONF_DIR="$WORK/conf" FLEET_SKIP_GLOBAL_CONF=1 FLEET_GH_FAKE_DOWN=1 \
        FLEET_MACOS_ALERT_CMD="$WORK/alert" bash "$W" --repo o/r --now 2>&1); RC=$?
eq "M: GitHub down ⇒ exit 0" 0 "$RC"
contains "M: says GitHub 不通" "$OUT" "GitHub 不通"
eq "M: nothing alerted while down" "" "$(alerted)"
eq "M: no stamp while down (the first tick after it answers reads)" no "$([ -f "$WORK/conf/global/macos-watch/o-r.stamp" ] && echo yes || echo no)"
reset; red_runs; mkdir -p "$WORK/conf/global/macos-watch/o-r.lock"; echo "$$" > "$WORK/conf/global/macos-watch/o-r.lock/pid"
run --now
eq "M: a live previous watch ⇒ exit 0" 0 "$RC"
contains "M: says the previous one still runs" "$OUT" "still running"
eq "M: nothing alerted beside a running watch" "" "$(alerted)"
eq "M: the holder's lock is left alone" "$$" "$(cat "$WORK/conf/global/macos-watch/o-r.lock/pid")"
echo 999999 > "$WORK/conf/global/macos-watch/o-r.lock/pid"
run --now
contains "M: a dead holder's lock is taken over ⇒ the watch runs" "$(alerted)" "breakage"
eq "M: its own lock is gone at exit" no "$([ -d "$WORK/conf/global/macos-watch/o-r.lock" ] && echo yes || echo no)"

printf 'fleet-macos-watch-selftest OK (%d checks)\n' "$CHECKS"
