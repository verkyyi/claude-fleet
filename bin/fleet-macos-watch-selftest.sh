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
#   A. green          newest completed run green → nothing said when no red streak
#                     was seen; after one, ONE message «✓ macOS 夜检恢复全绿（红了 N 晚）»
#                     (zh + en) — never pushed — and the memos are gone
#   B. red            ONE `breakage` alert on --session's fleet names the failed
#                     test, the failed job, the run and the commit the red streak
#                     started at, and says Macs still update (never «Mac 停在上一版»);
#                     nobody is spawned; the run id is remembered
#   C. same run       not alerted again, and the tick prints nothing (the log
#                     grows by changes only, T889)
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
#   K. two nights     (T889) one red night pushes nothing; the second pushes ONE
#                     message over FLEET_NOTIFY_CMD — the design copy, zh + en, the
#                     tests counted across every failed shard — and the third night
#                     of the same streak pushes nothing; no notifier ⇒ said once in
#                     the log; green ⇒ the message, no push
#   M. one at a time  (issue #4841) a previous watch still running (its lock's pid
#                     alive) ⇒ this one leaves; a dead holder's lock is taken over
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
. "$BIN/selftest-lib.sh"
W="$BIN/fleet-macos-watch.sh"
[ -f "$W" ] || { printf 'selftest: %s not found\n' "$W" >&2; exit 2; }
st_sandbox "${TMPDIR:-/tmp}/macos-watch-selftest.XXXXXX"

st_tally count
contains() { CHECKS=$((CHECKS + 1)); case "$2" in *"$3"*) ;; *) st_fail "$1 — does not contain [$3]:
$2" ;; esac; }
lacks() { CHECKS=$((CHECKS + 1)); case "$2" in *"$3"*) st_fail "$1 — contains [$3]:
$2" ;; esac; }

mkdir -p "$WORK/shim" "$WORK/conf"
cat > "$WORK/shim/gh" <<SH
#!/bin/sh
case "\$*" in
  *actions/workflows/*) cat "$WORK/runs" ;;
  *actions/runs/*/jobs*) id=\${2#*actions/runs/}; id=\${id%%/*}; cat "$WORK/jobs.\$id" 2>/dev/null ;;
  *actions/jobs/*/logs*) j=\${2#*actions/jobs/}; j=\${j%%/*}; cat "$WORK/log.\$j" 2>/dev/null || cat "$WORK/log" 2>/dev/null ;;   # REST (#4232)
esac
SH
cat > "$WORK/alert" <<SH
#!/bin/bash
printf '%s\n' "\$*" >> "$WORK/alerted"
exit \$(cat "$WORK/alert_rc" 2>/dev/null || echo 0)
SH
cat > "$WORK/push" <<SH
#!/bin/bash
printf '%s\n<<END>>\n' "\$1" >> "$WORK/pushed"
exit \$(cat "$WORK/push_rc" 2>/dev/null || echo 0)
SH
chmod +x "$WORK/push"
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
  { row 30 "$S3" failure schedule; row 29 "$S2" failure push; row 28 "$S1" success schedule; } > "$WORK/runs"
  jobs 30 red; jobs 29 red; jobs 28 green
}
printf '2026-10-07T01:02:03Z FAIL  dash-marker-selftest.sh   12s\n2026-10-07T01:02:04Z selftest FAIL: a thing\n' > "$WORK/log"

run() {
  OUT=$(env PATH="$WORK/shim:$PATH" FLEET_CONF_DIR="$WORK/conf" FLEET_SKIP_GLOBAL_CONF=1 \
          FLEET_MACOS_ALERT_CMD="$WORK/alert" FLEET_MACOS_NOTIFY_CMD="${PUSH-$WORK/push}" \
          bash "$W" --repo o/r "$@" 2>&1); RC=$?
}
memo() { cat "$WORK/conf/global/macos-watch/o-r.filed" 2>/dev/null || echo none; }
alerted() { cat "$WORK/alerted" 2>/dev/null; }
spawned() { [ -f "$WORK/spawned" ] && echo yes || echo no; }
pushed() { cat "$WORK/pushed" 2>/dev/null; }
reset() { rm -f "$WORK/spawned" "$WORK/alerted" "$WORK/alert_rc" "$WORK/pushed" "$WORK/push_rc" "$WORK/log."* "$WORK/jobs."* "$WORK/conf/global/macos-watch/"*; }

# --- A. green ------------------------------------------------------------------
reset; mkdir -p "$WORK/conf/global/macos-watch"; echo 7 > "$WORK/conf/global/macos-watch/o-r.filed"
{ row 31 "$S3" success push; row 30 "$S2" failure push; } > "$WORK/runs"; jobs 31 green; jobs 30 red
run --now
st_eq "A: green exits 0" 0 "$RC"; st_eq "A: no streak seen ⇒ says nothing" "" "$OUT"
st_eq "A: nothing alerted" "" "$(alerted)"; st_eq "A: memo forgotten" none "$(memo)"
reset; mkdir -p "$WORK/conf/global/macos-watch"; printf '%s\t10\n' "$S2" > "$WORK/conf/global/macos-watch/o-r.streak"
echo "$S2" > "$WORK/conf/global/macos-watch/o-r.pushed"
{ row 31 "$S3" success schedule; row 30 "$S2" failure schedule; } > "$WORK/runs"; jobs 31 green; jobs 30 red
run --now --session fleet
contains "A: a streak ends with one line" "$OUT" "green	31	was red 10 nights"
contains "A: the green-again message (zh)" "$(alerted)" "✓ macOS 夜检恢复全绿（红了 10 晚）"
contains "A: the green-again message (en)" "$(alerted)" "✓ macOS nightly green again (was red 10 nights)"
st_eq "A: green is never pushed" "" "$(pushed)"
st_eq "A: the streak is forgotten" no "$([ -e "$WORK/conf/global/macos-watch/o-r.streak" ] && echo yes || echo no)"
st_eq "A: the push mark is forgotten" no "$([ -e "$WORK/conf/global/macos-watch/o-r.pushed" ] && echo yes || echo no)"
rm -f "$WORK/alerted"; run --now
st_eq "A: the next green tick says nothing" "" "$OUT"; st_eq "A: ... and alerts nothing" "" "$(alerted)"

# --- B. red --------------------------------------------------------------------
reset; red_runs
run --now --session fleet
st_eq "B: red exits 0" 0 "$RC"; contains "B: says alerted" "$OUT" "alerted	30	macOS 夜检红了：dash-marker-selftest.sh"
contains "B: the copy says Macs still update" "$OUT" "Mac 照常更新"
lacks "B: never «Mac 停在上一版» (#4671: Macs follow stable)" "$(cat "$W")" "停在上一版"
lacks "B: never «every Mac runs it»" "$(cat "$W")" "every Mac runs it"
contains "B: the alert says Macs still update" "$(alerted)" "Macs still update"
A=$(alerted)
contains "B: one breakage alert on the fleet" "$A" "event -L fleet breakage"
contains "B: the alert names the test" "$A" "dash-marker-selftest.sh"
lacks "B: a bare 'FAIL: a thing' line is not a test name" "$OUT" "a thing"
contains "B: the title names the job" "$OUT" "（macOS / shard 2）"
st_eq "B: one red night (a push run is no night) — nothing pushed" "" "$(pushed)"
contains "B: the alert names the streak's first red commit" "$A" "since 2222222"
contains "B: the alert links the run" "$A" "https://github.com/o/r/actions/runs/30"
st_eq "B: nobody spawned" no "$(spawned)"
st_eq "B: exactly one alert" 1 "$(alerted | wc -l | tr -d ' ')"
st_eq "B: run remembered" 30 "$(memo)"
lacks "B: nothing filed — no issue filer is named (#4898)" "$(cat "$W")" "issue-file"

# --- C. the same red run is not alerted again -------------------------------------
rm -f "$WORK/spawned" "$WORK/alerted"
run --now --session fleet
st_eq "C: exits 0" 0 "$RC"; st_eq "C: a quiet tick prints nothing (no «already» line)" "" "$OUT"
st_eq "C: no second alert" "" "$(alerted)"

# --- D. throttle ------------------------------------------------------------------
reset; red_runs
printf '%s\n' "$(date +%s)" > "$WORK/conf/global/macos-watch/o-r.stamp" 2>/dev/null || { mkdir -p "$WORK/conf/global/macos-watch"; date +%s > "$WORK/conf/global/macos-watch/o-r.stamp"; }
run
st_eq "D: throttled exits 0" 0 "$RC"; st_eq "D: says nothing" "" "$OUT"; st_eq "D: nothing alerted" "" "$(alerted)"

# --- F. a failed alert is retried ---------------------------------------------------
reset; red_runs; echo 1 > "$WORK/alert_rc"
run --now --session fleet
st_eq "F: exits 1" 1 "$RC"; contains "F: says retried" "$OUT" "retried next tick"; st_eq "F: not remembered" none "$(memo)"

# --- G. cancelled / pull_request runs are no verdict ----------------------------------
reset
{ row 42 "$S3" failure push; row 41 "$S3" cancelled push; row 40 "$S3" cancelled push; row 39 "$S3" success pull_request
  row 38 "$S2" failure push; row 37 "$S1" success push; } > "$WORK/runs"
jobs 42 linux; jobs 41 none; jobs 40 linux; jobs 39 green; jobs 38 red; jobs 37 green
run --now
contains "G: the red macOS run under Linux-red / replaced / PR runs decides" "$OUT" "alerted	38"; st_eq "G: remembered 38" 38 "$(memo)"
contains "G: the streak starts at 38's commit" "$(alerted)" "since 2222222"
reset; { row 52 "$S3" failure push; row 51 "$S2" success push; } > "$WORK/runs"; jobs 52 linux; jobs 51 green
mkdir -p "$WORK/conf/global/macos-watch"; printf '%s\t1\n' "$S1" > "$WORK/conf/global/macos-watch/o-r.streak"
run --now
contains "G: a train red on Linux only leaves the BSD half green" "$OUT" "green	51"; lacks "G: no red alert" "$(alerted)" "breakage"

# --- H. --dry-run ------------------------------------------------------------------------
reset; red_runs
run --dry-run
st_eq "H: exits 0" 0 "$RC"; contains "H: says would-alert" "$OUT" "would-alert	30"; st_eq "H: nothing alerted" "" "$(alerted)"; st_eq "H: nothing remembered" none "$(memo)"

# --- I. off ---------------------------------------------------------------------------------
reset; red_runs
OUT=$(env PATH="$WORK/shim:$PATH" FLEET_CONF_DIR="$WORK/conf" FLEET_MACOS_WATCH=0 FLEET_MACOS_ALERT_CMD="$WORK/alert" \
        bash "$W" --repo o/r --now 2>&1); RC=$?
st_eq "I: off exits 0" 0 "$RC"; st_eq "I: says nothing" "" "$OUT"; st_eq "I: nothing alerted" "" "$(alerted)"

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
st_eq "J: a repo without the gate files is never read" 1 "$(alerted | grep -c 'actions/runs/30')"
st_eq "J: nobody spawned" no "$(spawned)"
# (no spawner, no dispatch shell or daemon template left, #3576: conf/gone.list)

# --- K. red two nights ⇒ ONE push (T889) --------------------------------------
reset
jobs2() { printf '1\tsuccess\tLinux / shard 1\n901\tfailure\tmacOS / shard 4\n902\tfailure\tmacOS / shard 8\n' > "$WORK/jobs.$1"; }
printf 'x Z FAIL  fleet-credsep-selftest.sh  3s\n' > "$WORK/log.901"
printf 'x Z TIMEOUT fleet-break-it-cred-selftest.sh  600s\n' > "$WORK/log.902"
{ row 61 "$S2" failure schedule; row 60 "$S1" success schedule; } > "$WORK/runs"; jobs2 61; jobs 60 green
run --now --session fleet
contains "K: night 1 is said" "$OUT" "alerted	61"; st_eq "K: night 1 pushes nothing" "" "$(pushed)"
{ row 63 "$S3" failure workflow_dispatch; row 62 "$S3" failure schedule; cat "$WORK/runs"; } > "$WORK/runs.n"; mv "$WORK/runs.n" "$WORK/runs"; jobs2 62; jobs2 63
run --now --session fleet
contains "K: night 2 says pushed" "$OUT" "pushed	2 nights	2222222"
P=$(pushed)
st_eq "K: exactly one push" 1 "$(printf '%s\n' "$P" | grep -c '<<END>>')"
contains "K: zh title" "$P" "【fleet】macOS 夜检连红 2 晚 · 2 个测试"
contains "K: zh line" "$P" "fleet-credsep-selftest.sh 等，自 2222222 起；Mac 照常更新"
contains "K: en title" "$P" "[fleet] macOS nightly red 2 nights · 2 tests"
contains "K: en line" "$P" "fleet-credsep-selftest.sh and 1 more, since 2222222; Macs still update"
contains "K: the run" "$P" "https://github.com/o/r/actions/runs/63"
lacks "K: a dispatch is not a night" "$P" "3 晚"
contains "K: the push is in 消息 too" "$(alerted)" "【fleet】macOS 夜检连红 2 晚"
{ row 64 "$S3" failure schedule; cat "$WORK/runs"; } > "$WORK/runs.n"; mv "$WORK/runs.n" "$WORK/runs"; jobs2 64
rm -f "$WORK/pushed"; run --now --session fleet
st_eq "K: night 3 of the same streak pushes nothing" "" "$(pushed)"
rm -f "$WORK/pushed"; run --now --session fleet
st_eq "K: a quiet tick prints nothing" "" "$OUT"
rm -f "$WORK/conf/global/macos-watch/o-r.pushed"; echo 1 > "$WORK/push_rc"; run --now --session fleet
st_eq "K: a failed push exits 1" 1 "$RC"; contains "K: ... retried" "$OUT" "retried next tick"
st_eq "K: ... not marked pushed" no "$([ -e "$WORK/conf/global/macos-watch/o-r.pushed" ] && echo yes || echo no)"
rm -f "$WORK/push_rc" "$WORK/pushed"
PUSH='' FLEET_NOTIFY_CMD='' run --now --session fleet
contains "K: no notifier ⇒ the log says nobody to push to" "$OUT" "no FLEET_NOTIFY_CMD"
PUSH='' FLEET_NOTIFY_CMD='' run --now --session fleet
st_eq "K: ... once" "" "$OUT"
rm -f "$WORK/alerted"; { row 65 "$S3" success schedule; cat "$WORK/runs"; } > "$WORK/runs.n"; mv "$WORK/runs.n" "$WORK/runs"; jobs 65 green
run --now --session fleet
contains "K: green after 3 nights" "$(alerted)" "✓ macOS 夜检恢复全绿（红了 3 晚）"; st_eq "K: green pushes nothing" "" "$(pushed)"
contains "K: the watched workflow is selftests-macos.yml" "$(cat "$W")" 'FLEET_MACOS_WORKFLOW:-selftests-macos.yml'

# --- M. one watch at a time (#4841) ---------------------------------------------
reset; red_runs; mkdir -p "$WORK/conf/global/macos-watch/o-r.lock"; echo "$$" > "$WORK/conf/global/macos-watch/o-r.lock/pid"
run --now
st_eq "M: a live previous watch ⇒ exit 0" 0 "$RC"
contains "M: says the previous one still runs" "$OUT" "still running"
st_eq "M: nothing alerted beside a running watch" "" "$(alerted)"
st_eq "M: the holder's lock is left alone" "$$" "$(cat "$WORK/conf/global/macos-watch/o-r.lock/pid")"
echo 999999 > "$WORK/conf/global/macos-watch/o-r.lock/pid"
run --now
contains "M: a dead holder's lock is taken over ⇒ the watch runs" "$(alerted)" "breakage"
st_eq "M: its own lock is gone at exit" no "$([ -d "$WORK/conf/global/macos-watch/o-r.lock" ] && echo yes || echo no)"

printf 'fleet-macos-watch-selftest OK (%d checks)\n' "$CHECKS"
