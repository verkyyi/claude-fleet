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
for f in fleet-doctor.sh fleet-diskguard.sh fleet-lib.sh fleet-daemon-lib.sh; do cp "$BIN/$f" "$WORK/bin/"; done
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
  *ppid=,user=,pcpu=,command=*) cat "$WORK/pstable"; exit 0 ;;
  *etime=*-p*)                  echo "  03:20:15"; exit 0 ;;
esac
exec /bin/ps "\$@"
EOF
chmod +x "$WORK/fakepath/sysctl" "$WORK/fakepath/nproc" "$WORK/fakepath/getconf" "$WORK/fakepath/ps"

# The doctor's `machine` line, plus a marker proving the run got PAST it.
run_doctor() {
  PATH="$WORK/fakepath:$PATH" TMPDIR="$WORK" HOME="$WORK" FLEET_SKIP_GLOBAL_CONF=1 \
  FLEET_CONF_DIR="$WORK/conf" \
    sh "$WORK/bin/fleet-doctor.sh" 2>/dev/null
}
machine_line() { printf '%s\n' "$1" | grep -aE '^[[:space:]]+(PASS|WARN|FAIL)[[:space:]]+machine([[:space:]]|$)' | head -1; }
# `perl` is the doctor's LAST check — if it is present, nothing aborted the run.
survived()     { printf '%s\n' "$1" | grep -qaE '^[[:space:]]+(PASS|WARN)[[:space:]]+perl'; }

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
has "PPID=1"  "$l" "2: the WARN must say WHY nothing else reaped it"
has "fleet-loadgen.sh --stop" "$l" "2: the WARN must name the command that ends a leaked experiment"
has "--orphans" "$l" "2: the WARN must point at the full list"
survived "$out" || fail "2: the doctor died rendering the orphan WARN (the \$mcmd… regression)" "$l"
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

printf 'selftest OK: fleet-doctor machine line (%s assertions — load, cores, orphan naming, render-survival)\n' "$CHECKS"
