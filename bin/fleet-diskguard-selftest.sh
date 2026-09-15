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

# The probes below are DOUBLE-FORKED into real orphans (reparented to init). A plain
# background child inherits this script's ancestry, and when the suite runs from a
# fleet pane that ancestry reaches a tmux server — which the reaper reads (rightly)
# as "a live pane is running this, it is not an orphan" and spares (issue #550). The
# probe would then be spared and these assertions would fail on a worker's machine
# while passing in CI. A real orphan has no such ancestor.
orphan() {   # "<cmd…>" → sets ORPHAN_PID to a pid reparented to init
  local pf="$WORK/.orphan.pid"; rm -f "$pf"
  ( eval "$1" >/dev/null 2>&1 &
    printf '%s' "$!" > "$pf" ) &
  wait $! 2>/dev/null
  ORPHAN_PID="$(cat "$pf" 2>/dev/null)"
  [ -n "$ORPHAN_PID" ] || fail "could not spawn an orphan probe for: $1"
  SPAWNED="$SPAWNED $ORPHAN_PID"
}

# A3. dry mode REPORTS but does not kill. Anchor a process by argv (path in args).
touch "$WT/marker"
orphan "exec tail -f '$WT/marker'"; tpid="$ORPHAN_PID"
sleep 1                                   # let it settle so pgrep/lsof see it
dry="$(fleet_reap_worktree_procs "$WT" dry)"
case "$dry" in would\ reap:*) ;; *) fail "A3 dry did not report a would-reap (got [$dry])";; esac
alive "$tpid" || fail "A3 dry mode KILLED the process (must only report)"
CHECKS=$((CHECKS + 2))

# A4. kill mode reaps BOTH discovery paths at once:
#   - argv match: the tail above (path is in its command line)
#   - cwd  match: a sleep whose cwd is inside the worktree (relative argv, like the
#     crash-#3 orphan) — only the lsof/proc cwd scan can find it.
orphan "cd '$WT' && exec sleep 300"; spid="$ORPHAN_PID"
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

# ============================================================================
# C. orphaned-runaway watchdog (issue #697)
# ============================================================================
# The class cpu_candidates structurally cannot cover. Its discriminator is "no
# controlling terminal", which is also true of every healthy Claude Bash-tool
# shell — so it ships OFF and stayed off, and on 2026-09-15 eight PPID=1 zsh
# burners ran for 3h20m at ~70% CPU each with nothing in the fleet able to see
# them. This filter discriminates on PPID=1 + a fleet argv fingerprint instead,
# which is precise enough to be ON by default. Both halves of that claim are
# asserted here: what it catches, and — more important for a default-on watchdog
# — what it must not.
ORPH="$WORK/orphbin"; mkdir -p "$ORPH"
cat > "$ORPH/id" <<'EOF'
#!/bin/sh
echo tester
EOF
# Columns the real call emits: pid ppid user pcpu command. Row 222 is the load-
# bearing negative: identical fingerprint, identical %CPU, but its parent is
# alive — i.e. a worker's live Bash-tool shell running a legitimate build.
cat > "$ORPH/ps" <<'EOF'
#!/bin/sh
cat <<ROWS
111 1 tester 99 /bin/zsh -c source /home/t/.claude/shell-snapshots/snapshot-zsh-1.sh; while :; do :; done
222 4242 tester 99 /bin/zsh -c source /home/t/.claude/shell-snapshots/snapshot-zsh-2.sh; make -j8
333 1 tester 10 /bin/zsh -c source /home/t/.claude/shell-snapshots/snapshot-zsh-3.sh; sleep 9
444 1 other 99 /bin/zsh -c source /home/t/.claude/shell-snapshots/snapshot-zsh-4.sh; while :; do :; done
555 1 tester 99 /usr/libexec/mdworker_shared -s mdworker -c MDSImporterWorker
666 1 tester 99 tmux -L fleet-claude-fleet new-session -d -s fleet-claude-fleet
777 1 tester 88 bash -c i=0; while [ "\$i" -lt 5000 ]; do i=\$((i+1)); done FLEET_LOADGEN_BURNER#t42
888 1 tester 97 /opt/homebrew/bin/some-unrelated-hog --forever
ROWS
EOF
chmod +x "$ORPH/id" "$ORPH/ps"
ocands="$(PATH="$ORPH:$PATH" orphan_candidates 50)"
eq "orphan: PPID=1 + snapshot fingerprint + hot → flagged" "111" \
   "$(printf '%s\n' "$ocands" | awk -F'|' '$1==111{print $1}')"
eq "orphan: LIVE parent (a worker's own busy shell) NOT flagged" "" \
   "$(printf '%s\n' "$ocands" | awk -F'|' '$1==222{print $1}')"
eq "orphan: below the %CPU floor NOT flagged" "" \
   "$(printf '%s\n' "$ocands" | awk -F'|' '$1==333{print $1}')"
eq "orphan: another user's process NOT flagged" "" \
   "$(printf '%s\n' "$ocands" | awk -F'|' '$1==444{print $1}')"
# 555/888 are the reason the fingerprint exists at all: plenty of legitimate
# PPID=1 processes burn CPU (Spotlight's importer was measured at 63% during the
# #697 incident) and none of them are the fleet's business.
eq "orphan: a hot system daemon (no fingerprint) NOT flagged" "" \
   "$(printf '%s\n' "$ocands" | awk -F'|' '$1==555{print $1}')"
eq "orphan: an unrelated hot process NOT flagged" "" \
   "$(printf '%s\n' "$ocands" | awk -F'|' '$1==888{print $1}')"
# The tmux server matches `claude-fleet` in the fingerprint AND is legitimately
# PPID=1. Killing it takes every window of that fleet down at once, so the infra
# exclusion is load-bearing, not decorative.
eq "orphan: the fleet's own tmux server NOT flagged" "" \
   "$(printf '%s\n' "$ocands" | awk -F'|' '$1==666{print $1}')"
eq "orphan: a leaked fleet-loadgen burner IS flagged" "777" \
   "$(printf '%s\n' "$ocands" | awk -F'|' '$1==777{print $1}')"

# C2. FLEET_ORPHAN_EXTRA_RE widens the fingerprint without replacing it.
ORPHAN_RE="$ORPHAN_RE_DEFAULT|some-unrelated-hog"
ocands="$(PATH="$ORPH:$PATH" orphan_candidates 50)"
eq "orphan: EXTRA_RE adds a shape"      "888" "$(printf '%s\n' "$ocands" | awk -F'|' '$1==888{print $1}')"
eq "orphan: EXTRA_RE keeps the defaults" "111" "$(printf '%s\n' "$ocands" | awk -F'|' '$1==111{print $1}')"
# shellcheck disable=SC2034  # read by orphan_candidates(), sourced from the guard
ORPHAN_RE="$ORPHAN_RE_DEFAULT"

# C3. Unlike cpu_watch, this one is ON with no configuration — that is the whole
#     point (the #151 watchdog was correct and had been off for months). Drive a
#     full tick with a pre-seeded clock so the sustain filter fires immediately.
ODIR="$FLEET_CONF_DIR/diskguard"
printf '111\t1\t99\tseeded\n' > "$ODIR/orphan-seen"
cat > "$WORK/notify.sh" <<EOF
#!/bin/sh
printf '%s' "\$1" > "$WORK/notified"
EOF
chmod +x "$WORK/notify.sh"
rm -f "$WORK/notified" "$ODIR/orphan-current" "$ODIR"/incident-orphan-*.log
# ACTION is pinned explicitly: the fake pids above are real pids on this host, so
# a test must never take the kill branch.
ORPHAN_ACTION=notify FLEET_NOTIFY_CMD="$WORK/notify.sh" \
  PATH="$ORPH:$PATH" orphan_watch
eq "orphan_watch: default knobs flag (watchdog is ON out of the box)" "111" \
   "$(awk -F'\t' 'NR==1{print $1}' "$ODIR/orphan-current" 2>/dev/null)"
oinc=0; for f in "$ODIR"/incident-orphan-*.log; do [ -f "$f" ] && oinc=$((oinc + 1)); done
eq "orphan_watch: an incident was captured" "1" "$oinc"
eq "orphan_watch: the operator was notified" "1" \
   "$([ -s "$WORK/notified" ] && echo 1 || echo 0)"
case "$(cat "$WORK/notified" 2>/dev/null)" in
  *PPID=1*) CHECKS=$((CHECKS + 1)) ;;
  *) fail "orphan_watch: the notification must say WHY it fired (PPID=1)" ;;
esac
eq "orphan_watch: default action is report-only" "notify" "$ORPHAN_ACTION"

# C4. The marker the doctor reads is refreshed every tick, so a cleared runaway
#     clears the warning too — a stale "runaway!" outlives the runaway and trains
#     the operator to ignore the line.
cat > "$ORPH/ps" <<'EOF'
#!/bin/sh
echo "222 4242 tester 99 /bin/zsh -c source /home/t/.claude/shell-snapshots/snapshot-zsh-2.sh; make -j8"
EOF
chmod +x "$ORPH/ps"
ORPHAN_ACTION=notify PATH="$ORPH:$PATH" orphan_watch
eq "orphan_watch: marker cleared once the orphan is gone" "absent" \
   "$([ -e "$ODIR/orphan-current" ] && echo present || echo absent)"

# C5. Explicitly OFF stays off — the knob has to be able to silence it.
rm -f "$ODIR/orphan-seen"
ORPHAN_PCT=0 orphan_watch
eq "orphan_watch: PCT=0 disables it entirely" "absent" \
  "$([ -e "$ODIR/orphan-seen" ] && echo present || echo absent)"

printf 'selftest OK: fleet-diskguard (%s assertions — worktree proc-reap + CPU watchdog + orphan watchdog)\n' "$CHECKS"
