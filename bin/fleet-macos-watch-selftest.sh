#!/bin/bash
# fleet-macos-watch-selftest.sh — bin/fleet-macos-watch.sh (issue #2286), hermetic.
#
# `gh` is a PATH shim serving the watched workflow's runs, each run's jobs
# (jobs.<run id>) and a job's failed log from files; the filer and the alert are FLEET_MACOS_FILE_CMD /
# FLEET_MACOS_ALERT_CMD stand-ins that log their argv. Nothing touches GitHub.
# Since #3120 (EPIC #3111 C9) nothing is ever spawned: a stand-in for
# dash-issue-session.sh sits first on PATH and must stay unrun.
#
#   A. green          newest completed run green → `green`, nothing filed, memo gone
#   B. red            files through the filer with --breakage; the title names the
#                     failed test, the failed job and the commit the red streak
#                     started at; ONE `breakage` alert names the issue on
#                     --session's fleet; nobody is spawned; the run id is remembered
#   C. same run       not re-filed (no 「同一故障」 comment spam every tick)
#   D. throttle       inside FLEET_MACOS_WATCH_SECS nothing is read
#   E. rc 5           the breakage is already open: remembered, NOT alerted (the open
#                     issue is the reminder, issue #4271), no spawn; reopened
#                     (the filer says `: reopened `) ⇒ alerted once
#   F. rc 1           a failed filing is NOT remembered (retried next tick), exit 1
#   G. noise          a cancelled run and a pull_request run are no verdict; a
#                     train red only on Linux, or one with no macOS job, is not
#                     the BSD half's (issue #3143: the watcher reads the train)
#   H. --dry-run      prints the filing, files and remembers nothing
#   I. off            FLEET_MACOS_WATCH=0 reads nothing
#   J. diskguard      fleet-diskguard.sh --watch's macos_watch drives it for a repo
#                     carrying both gate files, files + alerts, spawns nobody; a
#                     repo without them is never read; the dispatch shell is inert
#   L. one key    (issue #4232) the same red test on a NEWER stable files under the
#                     same key (the filer comments 「同一故障」 on the open one); a
#                     different red test is another key; no test read ⇒ the shards
#   K. held back      (issue #3869) the red streak began > FLEET_MACOS_STALE_SECS
#                     ago ⇒ ONE more alert «every Mac … previous version»; the next
#                     tick in the same streak says nothing; green forgets it. The
#                     default workflow is selftests-macos.yml (#4663: mac-follow holds nothing)
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
cat > "$WORK/filer" <<SH
#!/bin/bash
printf '%s\n' "\$*" >> "$WORK/filed"
echo https://github.com/o/r/issues/4242
cat "$WORK/filer_err" >&2 2>/dev/null
exit \$(cat "$WORK/filer_rc" 2>/dev/null || echo 0)
SH
cat > "$WORK/alert" <<SH
#!/bin/bash
printf '%s\n' "\$*" >> "$WORK/alerted"
SH
cat > "$WORK/shim/dash-issue-session.sh" <<SH
#!/bin/bash
printf '%s\n' "\$*" >> "$WORK/spawned"
SH
chmod +x "$WORK/shim/gh" "$WORK/filer" "$WORK/alert" "$WORK/shim/dash-issue-session.sh"

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
          FLEET_MACOS_FILE_CMD="$WORK/filer" FLEET_MACOS_ALERT_CMD="$WORK/alert" \
          bash "$W" --repo o/r "$@" 2>&1); RC=$?
}
memo() { cat "$WORK/conf/global/macos-watch/o-r.filed" 2>/dev/null || echo none; }
filed() { cat "$WORK/filed" 2>/dev/null; }
alerted() { cat "$WORK/alerted" 2>/dev/null; }
spawned() { [ -f "$WORK/spawned" ] && echo yes || echo no; }
reset() { rm -f "$WORK/filed" "$WORK/spawned" "$WORK/alerted" "$WORK/filer_rc" "$WORK/filer_err" "$WORK/jobs."* "$WORK/conf/global/macos-watch/"*; }

# --- A. green ------------------------------------------------------------------
reset; echo 9 > "$WORK/conf/stale"; mkdir -p "$WORK/conf/global/macos-watch"; echo 7 > "$WORK/conf/global/macos-watch/o-r.filed"
{ row 31 "$S3" success push; row 30 "$S2" failure push; } > "$WORK/runs"; jobs 31 green; jobs 30 red
run --now
eq "A: green exits 0" 0 "$RC"; contains "A: says green" "$OUT" "green	31"; eq "A: nothing filed" "" "$(filed)"; eq "A: memo forgotten" none "$(memo)"

# --- B. red --------------------------------------------------------------------
reset; red_runs
run --now --session fleet
eq "B: red exits 0" 0 "$RC"; contains "B: says filed" "$OUT" "filed	30	https://github.com/o/r/issues/4242"
F=$(filed)
contains "B: filed under the red test's key, no commit in it (#4232)" "$F" "--breakage-key macos-dash-marker-selftest --fault-sha"
contains "B: the sighting names the red run's commit + link (#4271)" "$F" "--fault-sha $S3 --fault-link https://github.com/o/r/actions/runs/30 --repo o/r"
contains "B: title names the test" "$F" "macOS 检查红了、Mac 停在上一版：dash-marker-selftest.sh"
lacks "B: a bare 'FAIL: a thing' line is not a test name" "$F" "红了：a,"
contains "B: title names the job" "$F" "（macOS / shard 2）"
contains "B: title names the streak's first red commit" "$F" "自 2222222 起"
contains "B: body links the run" "$F" "https://github.com/o/r/actions/runs/30"
eq "B: nobody spawned" no "$(spawned)"
contains "B: one breakage alert" "$(alerted)" "event -L fleet breakage"
contains "B: the alert names the issue" "$(alerted)" "https://github.com/o/r/issues/4242"
eq "B: exactly one alert" 1 "$(alerted | wc -l | tr -d ' ')"
eq "B: run remembered" 30 "$(memo)"

# --- C. the same red run is not re-filed ----------------------------------------
rm -f "$WORK/filed" "$WORK/spawned" "$WORK/alerted"
run --now --session fleet
eq "C: exits 0" 0 "$RC"; contains "C: says already" "$OUT" "already, for this run"; eq "C: nothing filed" "" "$(filed)"
eq "C: no second alert" "" "$(alerted)"

# --- D. throttle ------------------------------------------------------------------
reset; red_runs
printf '%s\n' "$(date +%s)" > "$WORK/conf/global/macos-watch/o-r.stamp" 2>/dev/null || { mkdir -p "$WORK/conf/global/macos-watch"; date +%s > "$WORK/conf/global/macos-watch/o-r.stamp"; }
run
eq "D: throttled exits 0" 0 "$RC"; eq "D: says nothing" "" "$OUT"; eq "D: nothing filed" "" "$(filed)"

# --- E. already open (rc 5) -------------------------------------------------------
reset; red_runs; echo 5 > "$WORK/filer_rc"
run --now --session fleet
eq "E: exits 0" 0 "$RC"; contains "E: says already open" "$OUT" "(already open)"; eq "E: remembered" 30 "$(memo)"
eq "E: no spawn" no "$(spawned)"; eq "E: an issue already open raises no alert (#4271)" "" "$(alerted)"
reset; red_runs; echo 5 > "$WORK/filer_rc"
echo 'fleet-issue-file: breakage macos-x: reopened https://github.com/o/r/issues/4242 — red again on a version with its fix, not filing (exit 5)' > "$WORK/filer_err"
run --now --session fleet
contains "E2: says reopened" "$OUT" "(reopened)"; contains "E2: a reopened issue is alerted" "$(alerted)" "breakage"

# --- F. a failed filing is retried ---------------------------------------------------
reset; red_runs; echo 1 > "$WORK/filer_rc"
run --now --session fleet
eq "F: exits 1" 1 "$RC"; contains "F: says retried" "$OUT" "retried next tick"; eq "F: not remembered" none "$(memo)"
eq "F: no alert for a failed filing" "" "$(alerted)"

# --- G. cancelled / pull_request runs are no verdict ----------------------------------
reset
{ row 42 "$S3" failure push; row 41 "$S3" cancelled push; row 40 "$S3" cancelled push; row 39 "$S3" success pull_request
  row 38 "$S2" failure push; row 37 "$S1" success push; } > "$WORK/runs"
jobs 42 linux; jobs 41 none; jobs 40 linux; jobs 39 green; jobs 38 red; jobs 37 green
run --now
contains "G: the red macOS run under Linux-red / replaced / PR runs decides" "$OUT" "filed	38"; eq "G: remembered 38" 38 "$(memo)"
contains "G: the streak starts at 38's commit" "$(filed)" "自 2222222 起"
reset; { row 52 "$S3" failure push; row 51 "$S2" success push; } > "$WORK/runs"; jobs 52 linux; jobs 51 green
run --now
contains "G: a train red on Linux only leaves the BSD half green" "$OUT" "green	51"; eq "G: nothing filed" "" "$(filed)"

# --- H. --dry-run ------------------------------------------------------------------------
reset; red_runs
run --dry-run
eq "H: exits 0" 0 "$RC"; contains "H: says would-file" "$OUT" "would-file	30"; eq "H: nothing filed" "" "$(filed)"; eq "H: nothing remembered" none "$(memo)"

# --- I. off ---------------------------------------------------------------------------------
reset; red_runs
OUT=$(env PATH="$WORK/shim:$PATH" FLEET_CONF_DIR="$WORK/conf" FLEET_MACOS_WATCH=0 FLEET_MACOS_FILE_CMD="$WORK/filer" \
        bash "$W" --repo o/r --now 2>&1); RC=$?
eq "I: off exits 0" 0 "$RC"; eq "I: says nothing" "" "$OUT"; eq "I: nothing filed" "" "$(filed)"

# --- J. the diskguard tick drives it, files + alerts, spawns nobody (#3120) --------------
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
  FLEET_MACOS_FILE_CMD="$WORK/filer" FLEET_MACOS_ALERT_CMD="$WORK/alert" bash "$WORK/dg.sh" >/dev/null 2>&1
i=0; while [ "$i" -lt 100 ] && ! grep -q 'filed' "$WORK/dg/macos-watch.log" 2>/dev/null; do sleep 0.1; i=$((i + 1)); done
contains "J: diskguard's tick ran the watcher on the gated repo" "$(cat "$WORK/dg/macos-watch.log" 2>/dev/null)" "fleet o/r filed	30"
contains "J: filed with --breakage-key" "$(filed)" "--breakage-key macos-dash-marker-selftest --fault-sha"
eq "J: a repo without the gate files is never read" 1 "$(filed | grep -c -e '--breakage')"
contains "J: alerted on the fleet" "$(alerted)" "event -L fleet breakage"
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
eq "K: two alerts (the filing + held back)" 2 "$(alerted | wc -l | tr -d ' ')"
rm -f "$WORK/alerted"; { row 63 "$S3" failure workflow_run "$new"; cat "$WORK/runs"; } > "$WORK/runs.n"; mv "$WORK/runs.n" "$WORK/runs"; jobs 63 red
run --now --session fleet
lacks "K: the same streak is not alerted twice" "$(alerted)" "has been red for"
FLEET_MACOS_STALE_SECS=99999 run --now
lacks "K: within the window nothing is said" "$OUT" "stale	"
{ row 64 "$S3" success workflow_run "$new"; cat "$WORK/runs"; } > "$WORK/runs.n"; mv "$WORK/runs.n" "$WORK/runs"; jobs 64 green
run --now
eq "K: green forgets the held-back mark" no "$([ -e "$WORK/conf/global/macos-watch/o-r.stale" ] && echo yes || echo no)"
contains "K: the watched workflow is selftests-macos.yml" "$(cat "$W")" 'FLEET_MACOS_WORKFLOW:-selftests-macos.yml'

# --- L. one issue per red test, whatever the commit (#4232) ------------------------------
key() { sed -n 's/.*--breakage-key \([^ ]*\) .*/\1/p' "$WORK/filed" | tail -1; }
reset; red_runs; run --now; k1=$(key)
reset; { row 71 4444444ddddddd failure push; row 70 5555555eeeeeee success push; } > "$WORK/runs"; jobs 71 red; jobs 70 green
run --now
eq "L: a newer stable, same red test ⇒ the same key" "$k1" "$(key)"
cp "$WORK/log" "$WORK/log.keep"
printf 'x FAIL  fleet-break-it-7-selftest.sh 347.6s (exit 1)\nx TIMEOUT  b-selftest.sh\nx FAIL  fleet-break-it-7-selftest.sh\n' > "$WORK/log"
reset; red_runs; run --now
eq "L: another red test set ⇒ its own key, sorted, deduped" "macos-b-selftest_fleet-break-it-7-selftest" "$(key)"
: > "$WORK/log"; reset; red_runs; run --now
eq "L: no test read ⇒ keyed on the red shards" "macos-macOS-shard-2" "$(key)"
mv "$WORK/log.keep" "$WORK/log"

printf 'fleet-macos-watch-selftest OK (%d checks)\n' "$CHECKS"
