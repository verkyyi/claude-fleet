#!/bin/bash
# fleet-diskguard-selftest.sh — hermetic tests for the two issue-#151 guards:
#
#   A. fleet_reap_worktree_procs() (bin/fleet-lib.sh) — reap the process tree of a
#      worktree before it is removed. A detached orphan (relative argv, cwd inside
#      the worktree) must be caught by BOTH discovery paths (pgrep argv + lsof/proc
#      cwd), and the dry/refuse/no-op branches must behave. Drives REAL throwaway
#      background processes anchored to a temp dir, then asserts they are gone.
#
#   B. the runaway-CPU watchdog (bin/fleet-diskguard.sh) — the sustain bookkeeping
#      (cpu_sustain) and the candidate filter (cpu_candidates) are the logic worth
#      pinning. Real CPU load isn't hermetic, so cpu_sustain is driven with an
#      injected clock + pre-seeded state, and cpu_candidates against a fake `ps`.
#
# Fully hermetic: no network, no live tmux, no launchd. Every process it spawns is
# a plain `sleep`/`tail` under a temp dir it owns and reaps on EXIT. Exit 0 = pass.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
LIB="$BIN/fleet-lib.sh"
DG="$BIN/fleet-diskguard.sh"
[ -f "$LIB" ] || { echo "selftest: $LIB not found" >&2; exit 2; }
[ -f "$DG" ]  || { echo "selftest: $DG not found"  >&2; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/fleet-diskguard-selftest.XXXXXX")" || exit 2
# The reap function refuses a path that IS a broad root; keep the temp tree well
# clear of those. If the ambient TMPDIR is itself under an issue worktree it does
# not matter here (we pass explicit temp dirs), so no relocation needed.
SPAWNED=""
cleanup() {
  for p in $SPAWNED; do kill -KILL "$p" 2>/dev/null; done
  rm -rf "$WORK"
}
trap cleanup EXIT

CHECKS=0
fail() { printf 'selftest FAIL: %s\n' "$1" >&2; exit 1; }
eq() { CHECKS=$((CHECKS + 1)); [ "$2" = "$3" ] || fail "$1 — expected [$2], got [$3]"; }
alive() { kill -0 "$1" 2>/dev/null; }

# shellcheck source=/dev/null
. "$LIB"

# ============================================================================
# A. fleet_reap_worktree_procs
# ============================================================================
WT="$WORK/claude-fleet-issue-999"   # a plausible worktree path
mkdir -p "$WT"

# A1. broad-root refusal — never sweep / or $HOME even if asked.
case "$(fleet_reap_worktree_procs / )"     in refused*) ;; *) fail "A1 '/' not refused";; esac
case "$(fleet_reap_worktree_procs "$HOME")" in refused*) ;; *) fail "A1 \$HOME not refused";; esac
CHECKS=$((CHECKS + 2))

# A2. nothing anchored → clean no-op report.
eq "reap: empty worktree → no orphans" "no orphan procs" "$(fleet_reap_worktree_procs "$WT")"

# A3. dry mode REPORTS but does not kill. Anchor a process by argv (path in args).
touch "$WT/marker"
tail -f "$WT/marker" >/dev/null 2>&1 & tpid=$!; SPAWNED="$SPAWNED $tpid"
disown "$tpid" 2>/dev/null || true        # silence bash job-control "Terminated" chatter
sleep 1                                   # let it settle so pgrep/lsof see it
dry="$(fleet_reap_worktree_procs "$WT" dry)"
case "$dry" in would\ reap:*) ;; *) fail "A3 dry did not report a would-reap (got [$dry])";; esac
alive "$tpid" || fail "A3 dry mode KILLED the process (must only report)"
CHECKS=$((CHECKS + 2))

# A4. kill mode reaps BOTH discovery paths at once:
#   - argv match: the tail above (path is in its command line)
#   - cwd  match: a sleep whose cwd is inside the worktree (relative argv, like the
#     crash-#3 orphan) — only the lsof/proc cwd scan can find it.
( cd "$WT" && exec sleep 300 ) & spid=$!; SPAWNED="$SPAWNED $spid"
disown "$spid" 2>/dev/null || true
sleep 1
rep="$(fleet_reap_worktree_procs "$WT" kill 1)"
case "$rep" in reaped:*) ;; *) fail "A4 unexpected reap report: [$rep]";; esac
sleep 1
alive "$tpid" && fail "A4 argv-anchored process survived reap (pid $tpid)"
alive "$spid" && fail "A4 cwd-anchored process survived reap (pid $spid)"
CHECKS=$((CHECKS + 2))
eq "reap: worktree empty again after reap" "no orphan procs" "$(fleet_reap_worktree_procs "$WT")"

# ============================================================================
# B. runaway-CPU watchdog (source the diskguard functions only)
# ============================================================================
export FLEET_CONF_DIR="$WORK/conf"           # GDIR = $FLEET_CONF_DIR/diskguard
mkdir -p "$FLEET_CONF_DIR/diskguard"
# shellcheck source=/dev/null
FLEET_DISKGUARD_SOURCE=1 . "$DG"

STATE="$WORK/cpu-seen"

# B1. A pid hot since long-ago (firstseen far in the past) → flagged as a runaway.
#     A brand-new hot pid (not in prior state) starts its clock NOW → NOT yet a
#     runaway. Inject nowt=100000, secs=300, prior state seeds pid 4242 @ t=1.
printf '4242\t1\t99\told-runaway\n' > "$STATE"
out="$(printf '4242|99|old-runaway\n5555|97|fresh-hot\n' | cpu_sustain 300 100000 "$STATE")"
eq "cpu_sustain: sustained pid flagged"      "4242"  "$(printf '%s\n' "$out" | awk -F'\t' '$1==4242{print $1}')"
eq "cpu_sustain: fresh pid NOT flagged"      ""      "$(printf '%s\n' "$out" | awk -F'\t' '$1==5555{print $1}')"
# state is rewritten to exactly the currently-hot set, carrying 4242's old clock
# and starting 5555's now.
eq "cpu_sustain: state carries old firstseen" "1"     "$(awk -F'\t' '$1==4242{print $2}' "$STATE")"
eq "cpu_sustain: state starts fresh clock"    "100000" "$(awk -F'\t' '$1==5555{print $2}' "$STATE")"

# B2. A pid that COOLED (absent from this tick's candidates) drops out of state —
#     its clock resets so a later re-spike must re-accumulate from scratch.
printf 'x\n' | cpu_sustain 300 100001 "$STATE" >/dev/null   # empty candidate set
eq "cpu_sustain: cooled pid dropped from state" "" "$(awk -F'\t' '$1==4242{print $1}' "$STATE")"

# B3. cpu_candidates filtering, against a fake `ps` + `id`. Columns emitted by the
#     real call are: pid user pcpu tty comm. Assert: keep our-user + hot + no-tty;
#     drop has-tty, below-threshold, other-user, and protected infra (tmux).
FAKEBIN="$WORK/fakebin"; mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/id" <<'EOF'
#!/bin/sh
echo tester
EOF
cat > "$FAKEBIN/ps" <<'EOF'
#!/bin/sh
# ignore args; emit "pid user pcpu tty comm" rows the awk filter parses.
cat <<ROWS
111 tester 99 ?? spinner
222 tester 99 s003 worker-with-tty
333 tester 10 ?? idle-proc
444 other  99 ?? someone-elses
555 tester 99 ?? tmux
ROWS
EOF
chmod +x "$FAKEBIN/id" "$FAKEBIN/ps"
cands="$(PATH="$FAKEBIN:$PATH" cpu_candidates 90)"
eq "cpu_candidates: hot+notty+ouruser kept"   "111|99|spinner" "$(printf '%s\n' "$cands" | grep '^111|')"
eq "cpu_candidates: has-tty dropped"          ""               "$(printf '%s\n' "$cands" | grep '^222|')"
eq "cpu_candidates: below-threshold dropped"  ""               "$(printf '%s\n' "$cands" | grep '^333|')"
eq "cpu_candidates: other-user dropped"       ""               "$(printf '%s\n' "$cands" | grep '^444|')"
eq "cpu_candidates: tmux (infra) dropped"     ""               "$(printf '%s\n' "$cands" | grep '^555|')"

# B4. cpu_watch is OFF by default (CPU_PCT=0 → immediate no-op, no state written).
rm -f "$FLEET_CONF_DIR/diskguard/cpu-seen"
CPU_PCT=0 cpu_watch
eq "cpu_watch: disabled writes no state" "absent" \
  "$([ -e "$FLEET_CONF_DIR/diskguard/cpu-seen" ] && echo present || echo absent)"

printf 'selftest OK: fleet-diskguard (%s assertions — worktree proc-reap + CPU watchdog)\n' "$CHECKS"
