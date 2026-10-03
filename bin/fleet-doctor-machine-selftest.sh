#!/bin/bash
# fleet-doctor-machine-selftest.sh — the `machine` verdict in bin/fleet-doctor.sh
# (issue #697): load average, cores, and orphaned runaways.
#
# Why it needs its own test: on 2026-09-15 this screen printed a steady "1 warn"
# while the machine underneath it sat at load 108 with eight leaked PPID=1 CPU
# burners on it — `ps` and `uptime` were themselves timing out and both fleet
# daemons were wedged. Every other doctor check asks "is the fleet installed
# correctly"; none of them could say "the machine is unusable", so nothing did.
# A blind spot that wide is only closed once there is a test that fails when it
# reopens.
#
# Three things are pinned, and the third is the one that bit during development:
#   1. the verdict itself — PASS quiet, WARN on an orphan, WARN on real load;
#   2. that a WARN NAMES the offender and the command that ends it, because a
#      warning you cannot act on is the blind spot with extra steps;
#   3. that the section RENDERS AT ALL. The first cut of this line interpolated
#      `$mcmd…` — and bash read the multibyte ellipsis as part of the identifier,
#      so under `set -u` the doctor died right there with "unbound variable".
#      Every check after it silently vanished and the machine line never printed.
#      So each case also asserts a LATER check still appears in the same run.
#
# Hermetic: fake ps/sysctl/nproc on PATH, scratch HOME/TMPDIR/conf. Exit 0 = pass.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
for f in fleet-doctor.sh fleet-diskguard.sh fleet-lib.sh fleet-daemon-lib.sh; do
  [ -f "$BIN/$f" ] || { printf 'selftest: %s not found\n' "$BIN/$f" >&2; exit 2; }
done

WORK="$(mktemp -d "${TMPDIR:-/tmp}/doctor-machine-selftest.XXXXXX")" || exit 2
WORK="$(cd "$WORK" && pwd -P)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin" "$WORK/fakepath" "$WORK/conf"
for f in fleet-doctor.sh fleet-diskguard.sh fleet-lib.sh fleet-daemon-lib.sh fleet-daemon-loaded.sh; do cp "$BIN/$f" "$WORK/bin/"; done
chmod +x "$WORK/bin/"*.sh

ME="$(id -un)"
CHECKS=0
fail() { printf 'selftest FAIL: %s\n' "$1" >&2; printf -- '--- machine line ---\n%s\n' "${2:-(none)}" >&2; exit 1; }
ok() { CHECKS=$((CHECKS + 1)); }
has() { CHECKS=$((CHECKS + 1)); case "$2" in *"$1"*) ;; *) fail "$3" "$2";; esac; }

# --- fake sysctl: the load average and core count are switchable per case.
cat > "$WORK/fakepath/sysctl" <<EOF
#!/bin/sh
case "\$*" in
  *hw.ncpu*)    cat "$WORK/cores" ;;
  *vm.loadavg*) [ -s "$WORK/load" ] && printf '{ %s 1.00 1.00 }\n' "\$(cat "$WORK/load")"
                # an empty load file = the machine would not answer (the #697 symptom)
                exit 0 ;;
  *) exit 1 ;;
esac
EOF
# nproc/getconf must not rescue a deliberately unreadable core count, and on
# Linux /proc/loadavg must not rescue an unreadable load average — the fakes
# stand in for a box too busy to answer either.
cat > "$WORK/fakepath/nproc" <<EOF
#!/bin/sh
cat "$WORK/cores"
EOF
cat > "$WORK/fakepath/getconf" <<EOF
#!/bin/sh
case "\$1" in _NPROCESSORS_ONLN) cat "$WORK/cores" ;; *) exec /usr/bin/getconf "\$@" ;; esac
EOF
# --- fake ps: answers the orphan scan's exact query from a fixture, the etime
# lookup with a constant, and defers everything else to the real ps so the rest
# of the doctor is unaffected.
cat > "$WORK/fakepath/ps" <<EOF
#!/bin/sh
case "\$*" in
  *rss=,pcpu=,etime=,comm=*)    cat "$WORK/fsev"; exit 0 ;;
  *ppid=,user=,pcpu=,command=*) cat "$WORK/pstable"; exit 0 ;;
  *etime=*-p*)                  echo "  03:20:15  524288"; exit 0 ;;
esac
exec /bin/ps "\$@"
EOF
# --- fake uname: the fseventsd section is macOS-only, so the OS is switchable too.
cat > "$WORK/fakepath/uname" <<EOF
#!/bin/sh
[ "\$1" = -s ] && { cat "$WORK/os"; exit 0; }
exec /usr/bin/uname "\$@"
EOF
echo Darwin > "$WORK/os"
printf '  9120  0.2 01:14:57 /System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/FSEvents.framework/Versions/A/Support/fseventsd\n' > "$WORK/fsev"
chmod +x "$WORK/fakepath/sysctl" "$WORK/fakepath/nproc" "$WORK/fakepath/getconf" "$WORK/fakepath/ps" "$WORK/fakepath/uname"

# The doctor's `machine` line, plus a marker proving the run got PAST it.
run_doctor() {
  : > "$WORK/stderr"
  PATH="$WORK/fakepath:$PATH" TMPDIR="$WORK" HOME="$WORK" FLEET_SKIP_GLOBAL_CONF=1 \
  FLEET_CONF_DIR="$WORK/conf" FLEET_GLOBAL_MAX_SESSIONS="${GMAX:-8}" \
    sh "$WORK/bin/fleet-doctor.sh" 2>"$WORK/stderr"
}
machine_line() { printf '%s\n' "$1" | grep -aE '^[[:space:]]+(PASS|WARN|FAIL)[[:space:]]+machine([[:space:]]|$)' | head -1; }
# `perl` is the doctor's LAST check — if it is present, nothing aborted the run.
survived()     { printf '%s\n' "$1" | grep -qaE '^[[:space:]]+(PASS|WARN)[[:space:]]+perl'; }
# 4. A verdict is not the whole output (issue #709). The first 20 assertions here
#    all read stdout, and all 20 stayed green while every healthy run also wrote
#    `[: 0\n0: integer expression expected` to stderr — because `grep -c` prints
#    `0` AND exits 1 on no match, so the `|| echo 0` written under it appended a
#    SECOND 0. The verdict was still correct, by accident: `[ -gt ]` errored,
#    returned 2, the `elif` read false, and the load branch below it was the right
#    answer anyway. Nothing that looks at the decision can catch that class. So
#    every case asserts the run was QUIET too — a tool whose job is to say whether
#    a machine is healthy cannot print shell errors while saying "all good", or
#    the operator learns to scroll past the real one.
quiet()        { CHECKS=$((CHECKS + 1)); [ -s "$WORK/stderr" ] && fail "$1" "$(cat "$WORK/stderr")"; return 0; }

# ============================================================================
# 1. Quiet machine, no orphans → PASS naming load + cores.
# ============================================================================
echo 8 > "$WORK/cores"; echo "1.20" > "$WORK/load"; : > "$WORK/pstable"
out="$(run_doctor)"; l="$(machine_line "$out")"
has "PASS" "$l" "1: a quiet box with no orphans must PASS"
has "1.20" "$l" "1: the PASS line must state the load it read"
has "8 cores" "$l" "1: the PASS line must state the core count it divided by"
has "0.15/core" "$l" "1: the PASS line must state load-per-core, which is the comparable number"
survived "$out" || fail "1: the doctor did not reach its last check — the machine section aborted the run" "$l"
quiet "1: a healthy box must print NOTHING on stderr — this is the assertion #709 was filed for"
ok

# ============================================================================
# 2. An orphaned runaway → WARN that NAMES it and says how to end it.
#    The fixture is the 2026-09-15 shape: PPID=1, a Claude shell-snapshot in
#    argv, pegging a core.
# ============================================================================
cat > "$WORK/pstable" <<EOF
4242 1 $ME 98.5 /bin/zsh -c source /home/t/.claude/shell-snapshots/snapshot-zsh-9.sh; while :; do :; done
EOF
out="$(run_doctor)"; l="$(machine_line "$out")"
has "WARN"    "$l" "2: an orphaned runaway must WARN"
has "4242"    "$l" "2: the WARN must name the offending pid"
has "98.5"    "$l" "2: the WARN must say how hot it is"
has "03:20"   "$l" "2: the WARN must say how long it has been running — 3h20m is the whole story of #697"
has "512 MB"  "$l" "2: the WARN must say how much memory it holds — the RSS column diskguard --orphans gained in #1292"
has "PPID=1"  "$l" "2: the WARN must say WHY nothing else reaped it"
has "fleet-loadgen.sh --stop" "$l" "2: the WARN must name the command that ends a leaked experiment"
has "--orphans" "$l" "2: the WARN must point at the full list"
survived "$out" || fail "2: the doctor died rendering the orphan WARN (the \$mcmd… regression)" "$l"
quiet "2: the orphan WARN must print NOTHING on stderr"
ok

# 2b. A live worker's busy shell is NOT an orphan: same fingerprint, same %CPU,
#     parent alive. If this ever warns, every build on the box warns.
cat > "$WORK/pstable" <<EOF
4242 999 $ME 98.5 /bin/zsh -c source /home/t/.claude/shell-snapshots/snapshot-zsh-9.sh; make -j8
EOF
out="$(run_doctor)"; l="$(machine_line "$out")"
has "PASS" "$l" "2b: a busy shell with a LIVE parent must not be called a runaway"

# ============================================================================
# 3. Real load, nobody to blame → WARN about the load itself.
# ============================================================================
echo 8 > "$WORK/cores"; echo "108.00" > "$WORK/load"; : > "$WORK/pstable"
out="$(run_doctor)"; l="$(machine_line "$out")"
has "WARN"     "$l" "3: load 108 on 8 cores must WARN"
has "13.50/core" "$l" "3: the WARN must state load-per-core"
survived "$out" || fail "3: the doctor did not survive the high-load WARN" "$l"
quiet "3: the high-load WARN must print NOTHING on stderr"
ok
# The threshold is a knob, and raising it past the reading must silence the line.
out="$(FLEET_LOAD_WARN_PER_CORE=99 run_doctor)"; l="$(machine_line "$out")"
has "PASS" "$l" "3b: FLEET_LOAD_WARN_PER_CORE must be honored"

# ============================================================================
# 4. The load average will not come back. That is not "no data" — it is the
#    machine answering by refusing to, which is exactly what #697 looked like
#    from the inside, so it must WARN rather than quietly PASS on a 0.00.
# ============================================================================
: > "$WORK/load"; : > "$WORK/pstable"
out="$(run_doctor)"; l="$(machine_line "$out")"
has "WARN" "$l" "4: an unreadable load average must WARN, not PASS on a phantom 0"
case "$l" in *0.00*) fail "4: it must not report a made-up 0.00 load" "$l";; esac
ok
survived "$out" || fail "4: the doctor did not survive the unreadable-load WARN" "$l"
quiet "4: the unreadable-load WARN must print NOTHING on stderr"

# ============================================================================
# 5. fseventsd (issue #889). Every `machine` line, not just the first.
# ============================================================================
mlines() { printf '%s\n' "$1" | grep -aE '^[[:space:]]+(PASS|WARN|FAIL)[[:space:]]+machine([[:space:]]|$)'; }
fsline() { mlines "$1" | grep -a fseventsd | head -1; }
capline() { mlines "$1" | grep -a 'sessions:' | head -1; }
echo 8 > "$WORK/cores"; echo "1.20" > "$WORK/load"; : > "$WORK/pstable"
out="$(run_doctor)"; l="$(fsline "$out")"
has "PASS" "$l" "5a: an 8 MB fseventsd must PASS"
has "8 MB" "$l" "5a: the line must state the RSS it read (9120 KB)"
has "01:14:57" "$l" "5a: the line must state how long it has been up"
quiet "5a: the fseventsd PASS must print NOTHING on stderr"
# the 2026-09-22 shape: 2.9 GB
printf '  3040000  12.0 3-02:11:40 /System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/FSEvents.framework/Versions/A/Support/fseventsd\n' > "$WORK/fsev"
out="$(run_doctor)"; l="$(fsline "$out")"
has "WARN" "$l" "5b: a 2.9 GB fseventsd must WARN"
has "2968 MB" "$l" "5b: the WARN must state the RSS"
has "sudo killall fseventsd" "$l" "5b: the WARN must name the fix"
has "launchd" "$l" "5b: the WARN must say launchd brings it back (so the fix is not scary)"
survived "$out" || fail "5b: the doctor did not survive the fseventsd WARN" "$l"
quiet "5b: the fseventsd WARN must print NOTHING on stderr"
out="$(FLEET_FSEVENTSD_WARN_MB=4096 run_doctor)"; l="$(fsline "$out")"
has "PASS" "$l" "5c: FLEET_FSEVENTSD_WARN_MB must be honored"
# small but pegged
printf '  90000  97.5 00:10:00 /usr/sbin/fseventsd\n' > "$WORK/fsev"
out="$(run_doctor)"; l="$(fsline "$out")"
has "WARN" "$l" "5d: a fseventsd at 97.5% CPU must WARN even when small"
# Linux: no fseventsd section at all, and no error
echo Linux > "$WORK/os"
out="$(run_doctor)"
CHECKS=$((CHECKS + 1))
[ -z "$(fsline "$out")" ] || fail "5e: Linux must print no fseventsd line" "$(fsline "$out")"
survived "$out" || fail "5e: the doctor did not survive the Linux branch" ""
quiet "5e: the Linux branch must print NOTHING on stderr"
echo Darwin > "$WORK/os"; : > "$WORK/fsev"
out="$(run_doctor)"
CHECKS=$((CHECKS + 1))
[ -z "$(fsline "$out")" ] || fail "5f: no fseventsd running must print no line" "$(fsline "$out")"

# ============================================================================
# 6. Session caps vs cores (issue #889) — STATED, never warned (issue #952).
#    The operator owns FLEET_MAX_SESSIONS / FLEET_GLOBAL_MAX_SESSIONS; the line
#    reports the numbers and never counts as a WARN or tells them what to set.
# ============================================================================
# The line may state numbers only: no verdict phrase, no knob to turn.
lacks() { CHECKS=$((CHECKS + 1)); case "$2" in *"$1"*) fail "$3" "$2";; esac; }
stated_only() {
  lacks "lower "  "$1" "$2: the sessions line must not advise lowering a cap"
  lacks "set FLEET_GLOBAL_MAX_SESSIONS" "$1" "$2: the sessions line must not advise setting a cap"
  lacks "over the" "$1" "$2: the sessions line must not draw a line to be over"
  lacks "≤" "$1" "$2: the sessions line must not name a ceiling to aim for"
}
mkdir -p "$WORK/conf/fleets/fa" "$WORK/conf/fleets/fb" "$WORK/conf/fleets/fc"
echo 10 > "$WORK/cores"
printf 'FLEET_REPO=o/a\nFLEET_MAX_SESSIONS=9\n' > "$WORK/conf/fleets/fa/conf"
printf 'FLEET_REPO=o/b\nFLEET_MAX_SESSIONS=20   # a comment\n' > "$WORK/conf/fleets/fb/conf"
printf 'FLEET_REPO=o/c\nFLEET_MAX_SESSIONS="6"\n' > "$WORK/conf/fleets/fc/conf"
out="$(GMAX=30 run_doctor)"; l="$(capline "$out")"
has "PASS" "$l" "6a: global 30 on 10 cores (3.0x) must PASS — the cap is the operator's, not a finding (#952)"
has "global cap 30" "$l" "6a: the line must state the global cap"
has "sum to 35" "$l" "6a: the line must state the per-fleet sum (9+20+6)"
has "10 cores" "$l" "6a: the line must state the core count"
has "3.0x" "$l" "6a: the line must state sessions per core"
stated_only "$l" "6a"
survived "$out" || fail "6a: the doctor did not survive the caps line" "$l"
quiet "6a: the caps line must print NOTHING on stderr"
# ...and it must not be counted: a box whose only 'finding' is its cap is healthy.
CHECKS=$((CHECKS + 1))
printf '%s\n' "$out" | grep -qa 'sessions:' || fail "6a: the sessions line must be printed at all" "$out"
[ "$(mlines "$out" | grep -ac 'WARN.*sessions:')" -eq 0 ] || fail "6a: the sessions line must never be a WARN" "$l"
out="$(GMAX=16 run_doctor)"; l="$(capline "$out")"
has "PASS" "$l" "6b: global 16 on 10 cores must PASS"
has "1.6x" "$l" "6b: the PASS must state sessions per core"
# per-fleet caps below the global one are the real ceiling
printf 'FLEET_REPO=o/b\nFLEET_MAX_SESSIONS=2\n' > "$WORK/conf/fleets/fb/conf"
out="$(GMAX=40 run_doctor)"; l="$(capline "$out")"
has "PASS" "$l" "6c: caps summing to 17 under a global 40 must PASS — the sum is the real ceiling"
has "up to 17" "$l" "6c: the line must name the effective ceiling"
# an uncapped fleet means the global cap is the ceiling again — still stated, not warned
printf 'FLEET_REPO=o/b\n' > "$WORK/conf/fleets/fb/conf"
out="$(GMAX=40 run_doctor)"; l="$(capline "$out")"
has "PASS" "$l" "6d: with an uncapped fleet the global 40 (4.0x) is the ceiling and must still PASS (#952)"
has "1 uncapped" "$l" "6d: the line must say a fleet is uncapped"
has "4.0x" "$l" "6d: the line must state sessions per core"
stated_only "$l" "6d"
# no global cap + an uncapped fleet = unbounded: a fact the line names, not a finding
out="$(GMAX=0 run_doctor)"; l="$(capline "$out")"
has "PASS" "$l" "6e: no global cap + an uncapped fleet = unbounded, must PASS (#952)"
has "no global cap" "$l" "6e: the line must state there is no global cap"
has "unbounded" "$l" "6e: the line must name the box as unbounded"
stated_only "$l" "6e"
quiet "6e: the unbounded line must print NOTHING on stderr"
rm -rf "$WORK/conf/fleets"

# ============================================================================
# 7. tmux calls/s from the spinner heartbeat (issue #887 field) — shown only
#    when present.
# ============================================================================
mkdir -p "$WORK/logs"
date +%s > "$WORK/logs/spinner.heartbeat"
out="$(run_doctor)"
CHECKS=$((CHECKS + 1))
mlines "$out" | grep -q 'tmux call' && fail "7a: no tmux_calls_per_s field must show no line" "$(mlines "$out")"
printf '%s tmux_calls_per_s=41.5\n' "$(date +%s)" > "$WORK/logs/spinner.heartbeat"
out="$(run_doctor)"; l="$(mlines "$out" | grep -a 'tmux call' | head -1)"
has "41.5" "$l" "7b: the heartbeat's tmux_calls_per_s must be reported"
quiet "7b: the tmux-rate line must print NOTHING on stderr"
rm -rf "$WORK/logs"

# ============================================================================
# 8. The diskguard --watch share: remind ONCE per day, never kill, re-arm on
#    recovery.
# ============================================================================
cat > "$WORK/notify" <<EOF
#!/bin/sh
printf '%s\n---\n' "\$1" >> "$WORK/notified"
EOF
chmod +x "$WORK/notify"; : > "$WORK/notified"
fwatch() {
  PATH="$WORK/fakepath:$PATH" HOME="$WORK" FLEET_SKIP_GLOBAL_CONF=1 FLEET_CONF_DIR="$WORK/conf" \
  FLEET_NOTIFY_CMD="$WORK/notify" FLEET_DISKGUARD_SOURCE=1 \
    bash -c ". '$WORK/bin/fleet-diskguard.sh'; fseventsd_watch" 2>>"$WORK/stderr"
}
: > "$WORK/stderr"
printf '  3040000  12.0 3-02:11:40 /usr/sbin/fseventsd\n' > "$WORK/fsev"
fwatch; fwatch
CHECKS=$((CHECKS + 1))
[ "$(grep -c '^---$' "$WORK/notified")" = 1 ] || fail "8a: two ticks over the line must remind exactly ONCE" "$(cat "$WORK/notified")"
has "sudo killall fseventsd" "$(cat "$WORK/notified")" "8a: the reminder must name the fix"
printf '  9120  0.2 01:00:00 /usr/sbin/fseventsd\n' > "$WORK/fsev"; fwatch
printf '  3040000  12.0 00:05:00 /usr/sbin/fseventsd\n' > "$WORK/fsev"; fwatch
CHECKS=$((CHECKS + 1))
[ "$(grep -c '^---$' "$WORK/notified")" = 2 ] || fail "8b: a recovery must re-arm the reminder for the next episode" "$(cat "$WORK/notified")"
echo Linux > "$WORK/os"; : > "$WORK/notified"; fwatch
CHECKS=$((CHECKS + 1))
[ -s "$WORK/notified" ] && fail "8c: Linux must never remind" "$(cat "$WORK/notified")"
quiet "8: the watch share must print NOTHING on stderr"
echo Darwin > "$WORK/os"

# ============================================================================
# 9. memory / files / pty (issue #1293) — each reading walks PASS and WARN, and a
#    reading the machine will not give is INFO (a Linux CI box), never WARN.
# ============================================================================
rline() { printf '%s\n' "$2" | grep -aE "^[[:space:]]+(PASS|WARN|INFO|FAIL)[[:space:]]+$1([[:space:]]|\$)" | head -1; }
uid_me="$(id -u)"
printf '%s\n' \
  "  500     1 $uid_me 3145728 01:00:00 /usr/local/bin/claude --resume x" \
  "  501   500 $uid_me 9437184 00:10:00 /usr/bin/git gc --aggressive" \
  "  502   500 $uid_me 1048576 00:10:00 /usr/bin/node /opt/vite/bin/vite.js" \
  "  503   500 $uid_me 1024 00:10:00 /bin/sleep 9" \
  "  600     1 $uid_me 20971520 05:00:00 /Applications/Safari.app/Contents/MacOS/Safari" > "$WORK/memps"
res_doctor() {
  FLEET_MEM_PS_CMD="cat $WORK/memps" FLEET_MEM_PROBE_CMD="$1" FLEET_FILES_PROBE_CMD="$2" \
  FLEET_PTY_PROBE_CMD="$3" run_doctor
}
out="$(res_doctor 'echo 1 63 5 6' 'echo 22000 491520' 'echo 38 511')"
l="$(rline memory "$out")"
has "PASS" "$l" "9a: normal pressure must PASS"
has "63% available" "$l" "9a: the memory line must state available %"
has "compressor 5%" "$l" "9a: the memory line must state the compressor %"
has "swap 6 MB" "$l" "9a: the memory line must state swap"
has "git 9216 MB (pid 501)" "$l" "9a: the memory line must name the fleet's largest process first"
has "claude 3072 MB (pid 500)" "$l" "9a: an agent counts as a fleet process"
has "node vite.js" "$l" "9a: an interpreter is named by its script"
CHECKS=$((CHECKS + 1)); case "$l" in *Safari*|*sleep*) fail "9a: only the top three FLEET processes are named (not the operator's apps)" "$l";; esac
l="$(rline files "$out")"; has "PASS" "$l" "9a: a 4% file table must PASS"; has "22000 / 491520" "$l" "9a: files must state used / max"
l="$(rline pty "$out")";   has "PASS" "$l" "9a: a 7% pty table must PASS"; has "38 / 511" "$l" "9a: pty must state used / max"
survived "$out" || fail "9a: the doctor did not survive the resource lines" "$(rline memory "$out")"
quiet "9a: the resource lines must print NOTHING on stderr"
out="$(res_doctor 'echo 2 9 41 8000' 'echo 400000 491520' 'echo 450 511')"
l="$(rline memory "$out")";  has "WARN" "$l" "9b: pressure warn must WARN"; has "pressure warn" "$l" "9b: the WARN must name the level"
has "fleet-memguard.sh --once --dry-run" "$l" "9b: the WARN must name the next command"
l="$(rline files "$out")";   has "WARN" "$l" "9b: an 81% file table must WARN"; has "81%" "$l" "9b: the WARN must state the %"
l="$(rline pty "$out")";     has "WARN" "$l" "9b: an 88% pty table must WARN"
out="$(res_doctor 'echo 4 3 60 30000' 'echo 400000 491520' 'echo 450 511')"
l="$(rline memory "$out")";  has "WARN" "$l" "9c: critical pressure must WARN"; has "critical" "$l" "9c: the WARN must say critical"
out="$(FLEET_FILES_WARN_PCT=90 FLEET_PTY_WARN_PCT=95 res_doctor 'echo 1 63 5 6' 'echo 400000 491520' 'echo 450 511')"
l="$(rline files "$out")";   has "PASS" "$l" "9d: FLEET_FILES_WARN_PCT must be honored"
l="$(rline pty "$out")";     has "PASS" "$l" "9d: FLEET_PTY_WARN_PCT must be honored"
out="$(res_doctor 'true' 'echo garbled' 'echo 3 0')"
for k in memory files pty; do
  l="$(rline "$k" "$out")"; has "INFO" "$l" "9e: an unreadable $k must be INFO, never WARN (Linux CI)"
done
survived "$out" || fail "9e: the doctor did not survive unreadable resources" "$(rline memory "$out")"
quiet "9e: unreadable resources must print NOTHING on stderr"

# ============================================================================
# 10. The diskguard --watch share for memory / files / pty: notify on the EDGE
#     only, once, honor the cooldown, re-arm on recovery.
# ============================================================================
: > "$WORK/notified"; rm -f "$WORK/conf/diskguard/res-"*
rwatch() {
  PATH="$WORK/fakepath:$PATH" HOME="$WORK" FLEET_SKIP_GLOBAL_CONF=1 FLEET_CONF_DIR="$WORK/conf" \
  FLEET_NOTIFY_CMD="$WORK/notify" FLEET_DISKGUARD_SOURCE=1 FLEET_MEM_PS_CMD="cat $WORK/memps" \
  FLEET_MEM_PROBE_CMD="cat $WORK/rmem" FLEET_FILES_PROBE_CMD="cat $WORK/rfiles" FLEET_PTY_PROBE_CMD="cat $WORK/rpty" \
    bash -c ". '$WORK/bin/fleet-diskguard.sh'; mem_watch" 2>>"$WORK/stderr"
}
nnot() { grep -c '^---$' "$WORK/notified"; }
: > "$WORK/stderr"
echo '1 63 5 6' > "$WORK/rmem"; echo '22000 491520' > "$WORK/rfiles"; echo '38 511' > "$WORK/rpty"
rwatch; rwatch
CHECKS=$((CHECKS + 1)); [ "$(nnot)" = 0 ] || fail "10a: a healthy machine must never notify" "$(cat "$WORK/notified")"
echo '2 9 41 8000' > "$WORK/rmem"; rwatch; rwatch; rwatch
CHECKS=$((CHECKS + 1)); [ "$(nnot)" = 1 ] || fail "10b: entering warn must notify exactly ONCE over three ticks" "$(cat "$WORK/notified")"
has "memory pressure: warn" "$(cat "$WORK/notified")" "10b: the notice must name the level"
has "git (pid 501, 9216 MB)" "$(cat "$WORK/notified")" "10b: the notice must name the largest fleet process"
echo '4 3 60 30000' > "$WORK/rmem"; rwatch
CHECKS=$((CHECKS + 1)); [ "$(nnot)" = 1 ] || fail "10c: warn → critical inside the cooldown must stay quiet" "$(cat "$WORK/notified")"
echo '1 63 5 6' > "$WORK/rmem"; rwatch
echo '2 9 41 8000' > "$WORK/rmem"; FLEET_MEM_NOTIFY_COOLDOWN=0 rwatch
CHECKS=$((CHECKS + 1)); [ "$(nnot)" = 2 ] || fail "10d: recovery then a new episode past the cooldown must notify again" "$(cat "$WORK/notified")"
echo '4 3 60 30000' > "$WORK/rmem"; FLEET_MEM_NOTIFY_COOLDOWN=0 rwatch
CHECKS=$((CHECKS + 1)); [ "$(nnot)" = 3 ] || fail "10e: warn → critical past the cooldown is a new edge" "$(cat "$WORK/notified")"
echo '400000 491520' > "$WORK/rfiles"; echo '450 511' > "$WORK/rpty"; rwatch; rwatch
CHECKS=$((CHECKS + 1)); [ "$(nnot)" = 5 ] || fail "10f: files and pty crossing the line must notify once EACH" "$(cat "$WORK/notified")"
has "files table at 81%" "$(cat "$WORK/notified")" "10f: the files notice must state the %"
has "pty table at 88%" "$(cat "$WORK/notified")" "10f: the pty notice must state the %"
printf 'garbled\n' > "$WORK/rmem"; : > "$WORK/rfiles"; printf 'n/a 511\n' > "$WORK/rpty"; rwatch
CHECKS=$((CHECKS + 1)); [ "$(nnot)" = 5 ] || fail "10g: unreadable or garbled readings must never notify" "$(cat "$WORK/notified")"
quiet "10: the memory watch must print NOTHING on stderr"

printf 'selftest OK: fleet-doctor machine line (%s assertions — load, cores, orphan naming, fseventsd, session caps, tmux rate, memory/files/pty + edge notices, render-survival, stderr silence)\n' "$CHECKS"
