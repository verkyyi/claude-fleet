#!/bin/bash
# fleet-macos-watch-selftest.sh — bin/fleet-macos-watch.sh (issue #2286), hermetic.
#
# `gh` is a PATH shim serving the macOS workflow's runs, a run's jobs and a job's
# failed log from files; the filer and the spawner are FLEET_MACOS_FILE_CMD /
# FLEET_MACOS_SPAWN_CMD stand-ins that log their argv. Nothing touches GitHub.
#
#   A. green          newest completed run green → `green`, nothing filed, memo gone
#   B. red            files through the filer with --breakage; the title names the
#                     failed test, the failed job and the commit the red streak
#                     started at; the new issue's worker is spawned into --session
#                     with --origin autofill; the run id is remembered
#   C. same run       not re-filed (no 「同一故障」 comment spam every tick)
#   D. throttle       inside FLEET_MACOS_WATCH_SECS nothing is read
#   E. rc 5           the breakage is already open: remembered, no spawn
#   F. rc 1           a failed filing is NOT remembered (retried next tick), exit 1
#   G. noise          a cancelled run and a pull_request run are no verdict
#   H. --dry-run      prints the filing, files and remembers nothing
#   I. off            FLEET_MACOS_WATCH=0 reads nothing
#   J. dispatch hook  fleet-dispatch.sh names the watcher and its gates
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
  *actions/runs/*/jobs*) cat "$WORK/jobs" 2>/dev/null ;;
  'run view'*) cat "$WORK/log" 2>/dev/null ;;
esac
SH
cat > "$WORK/filer" <<SH
#!/bin/bash
printf '%s\n' "\$*" >> "$WORK/filed"
echo https://github.com/o/r/issues/4242
exit \$(cat "$WORK/filer_rc" 2>/dev/null || echo 0)
SH
cat > "$WORK/spawn" <<SH
#!/bin/bash
printf '%s\n' "\$*" >> "$WORK/spawned"
SH
chmod +x "$WORK/shim/gh" "$WORK/filer" "$WORK/spawn"

S1=1111111aaaaaaa S2=2222222bbbbbbb S3=3333333ccccccc
row() { printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4"; }
red_runs() { { row 30 "$S3" failure push; row 29 "$S2" failure push; row 28 "$S1" success schedule; } > "$WORK/runs"; }
printf '901\tmacOS shard 2\n' > "$WORK/jobs"
printf '2026-10-07T01:02:03Z FAIL  dash-marker-selftest.sh   12s\n2026-10-07T01:02:04Z selftest FAIL: a thing\n' > "$WORK/log"

run() {
  OUT=$(env PATH="$WORK/shim:$PATH" FLEET_CONF_DIR="$WORK/conf" FLEET_SKIP_GLOBAL_CONF=1 \
          FLEET_MACOS_FILE_CMD="$WORK/filer" FLEET_MACOS_SPAWN_CMD="$WORK/spawn" \
          bash "$W" --repo o/r "$@" 2>&1); RC=$?
}
memo() { cat "$WORK/conf/global/macos-watch/o-r.filed" 2>/dev/null || echo none; }
filed() { cat "$WORK/filed" 2>/dev/null; }
reset() { rm -f "$WORK/filed" "$WORK/spawned" "$WORK/filer_rc" "$WORK/conf/global/macos-watch/"*; }

# --- A. green ------------------------------------------------------------------
reset; echo 9 > "$WORK/conf/stale"; mkdir -p "$WORK/conf/global/macos-watch"; echo 7 > "$WORK/conf/global/macos-watch/o-r.filed"
{ row 31 "$S3" success push; row 30 "$S2" failure push; } > "$WORK/runs"
run --now
eq "A: green exits 0" 0 "$RC"; contains "A: says green" "$OUT" "green	31"; eq "A: nothing filed" "" "$(filed)"; eq "A: memo forgotten" none "$(memo)"

# --- B. red --------------------------------------------------------------------
reset; red_runs
run --now --session fleet
eq "B: red exits 0" 0 "$RC"; contains "B: says filed" "$OUT" "filed	30	https://github.com/o/r/issues/4242"
F=$(filed)
contains "B: filed with --breakage" "$F" "--breakage --repo o/r"
contains "B: title names the test" "$F" "macOS 检查红了：dash-marker-selftest.sh"
lacks "B: a bare 'FAIL: a thing' line is not a test name" "$F" "红了：a,"
contains "B: title names the job" "$F" "（macOS shard 2）"
contains "B: title names the streak's first red commit" "$F" "自 2222222 起"
contains "B: body links the run" "$F" "https://github.com/o/r/actions/runs/30"
contains "B: spawned into the fleet" "$(cat "$WORK/spawned" 2>/dev/null)" "4242 fleet --repo o/r"
contains "B: spawned as autofill" "$(cat "$WORK/spawned" 2>/dev/null)" "--origin autofill"
eq "B: run remembered" 30 "$(memo)"

# --- C. the same red run is not re-filed ----------------------------------------
rm -f "$WORK/filed" "$WORK/spawned"
run --now --session fleet
eq "C: exits 0" 0 "$RC"; contains "C: says already" "$OUT" "already, for this run"; eq "C: nothing filed" "" "$(filed)"

# --- D. throttle ------------------------------------------------------------------
reset; red_runs
printf '%s\n' "$(date +%s)" > "$WORK/conf/global/macos-watch/o-r.stamp" 2>/dev/null || { mkdir -p "$WORK/conf/global/macos-watch"; date +%s > "$WORK/conf/global/macos-watch/o-r.stamp"; }
run
eq "D: throttled exits 0" 0 "$RC"; eq "D: says nothing" "" "$OUT"; eq "D: nothing filed" "" "$(filed)"

# --- E. already open (rc 5) -------------------------------------------------------
reset; red_runs; echo 5 > "$WORK/filer_rc"
run --now --session fleet
eq "E: exits 0" 0 "$RC"; contains "E: says already open" "$OUT" "(already open)"; eq "E: remembered" 30 "$(memo)"
eq "E: no spawn" no "$([ -f "$WORK/spawned" ] && echo yes || echo no)"

# --- F. a failed filing is retried ---------------------------------------------------
reset; red_runs; echo 1 > "$WORK/filer_rc"
run --now --session fleet
eq "F: exits 1" 1 "$RC"; contains "F: says retried" "$OUT" "retried next tick"; eq "F: not remembered" none "$(memo)"

# --- G. cancelled / pull_request runs are no verdict ----------------------------------
reset
{ row 40 "$S3" cancelled push; row 39 "$S3" success pull_request; row 38 "$S2" failure push; row 37 "$S1" success push; } > "$WORK/runs"
run --now
contains "G: the red push run under a cancelled one decides" "$OUT" "filed	38"; eq "G: remembered 38" 38 "$(memo)"

# --- H. --dry-run ------------------------------------------------------------------------
reset; red_runs
run --dry-run
eq "H: exits 0" 0 "$RC"; contains "H: says would-file" "$OUT" "would-file	30"; eq "H: nothing filed" "" "$(filed)"; eq "H: nothing remembered" none "$(memo)"

# --- I. off ---------------------------------------------------------------------------------
reset; red_runs
OUT=$(env PATH="$WORK/shim:$PATH" FLEET_CONF_DIR="$WORK/conf" FLEET_MACOS_WATCH=0 FLEET_MACOS_FILE_CMD="$WORK/filer" \
        bash "$W" --repo o/r --now 2>&1); RC=$?
eq "I: off exits 0" 0 "$RC"; eq "I: says nothing" "" "$OUT"; eq "I: nothing filed" "" "$(filed)"

# --- J. the dispatch tick runs it, gated on the repo's own files ------------------------
D="$BIN/fleet-dispatch.sh"
contains "J: dispatch calls the watcher" "$(cat "$D")" 'fleet-macos-watch.sh" --repo "$r" --session "$sess"'
contains "J: only a repo carrying the macOS workflow" "$(cat "$D")" '.github/workflows/selftests-macos.yml'
contains "J: … and bin/fleet-stable.sh" "$(cat "$D")" '"$main/bin/fleet-stable.sh"'

printf 'fleet-macos-watch-selftest OK (%d checks)\n' "$CHECKS"
