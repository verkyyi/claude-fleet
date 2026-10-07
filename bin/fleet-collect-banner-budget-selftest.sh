#!/bin/bash
# fleet-collect-banner-budget-selftest.sh — the banner phase scans EVERY window each
# tick, and a tick cut short costs a window one tick, never a starve (issue #1588).
#
# Background (#1588): the collector's banner phase (tmux-dash-collect.sh ph_banner —
# capture each verified window, look for the "hit your limit" wall) ran under a fixed
# 30s budget. On a 20-plus-window machine 10 of 29 ticks were killed part-way, so a
# window late in the list could sit behind a wall for several minutes unseen. Fixed
# two ways, both pinned here:
#
#   A. BUDGET    — banner_budget = max(FLEET_COLLECT_BANNER_BUDGET,
#                  windows × FLEET_COLLECT_BANNER_PER_WINDOW_MS). The knob keeps its
#                  meaning as the floor; 0 stays unbudgeted; no accounts dir = floor.
#   B. ROTATION  — `working` windows first, every tick; the rest resume after
#                  global/banner.cursor (claimed BEFORE each scan), so a killed tick's
#                  unreached windows are the next tick's first — every window is
#                  scanned within two ticks even when one wedges.
#   C. HEARTBEAT — a real collector tick over a 24-window fixture: the banner phase is
#                  NOT killed, and global/collect.heartbeat carries
#                  banner_scanned=24 / banner_total=24. With the per-window term off
#                  (the pre-#1588 fixed budget) the same fixture IS killed, and the
#                  stderr line says how far the rotation got.
#
# Drives the real tmux-dash-collect.sh / ph_banner against a FAKE tmux and a stub
# fleet-account-truth.sh (no tmux server, no accounts, no network). Needs python3
# (collector hard dep) — SKIPs if absent. Exit 0 = pass.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
for f in tmux-dash-collect.sh fleet-quotawatch.sh fleet-account.sh fleet_iso.py fleet-lib.sh usage-lib.sh fleet-restore.sh; do
  [ -f "$BIN/$f" ] || { printf 'selftest: %s not found\n' "$BIN/$f" >&2; exit 2; }
done
command -v python3 >/dev/null 2>&1 || { printf 'selftest: python3 not installed — SKIP\n' >&2; exit 0; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/collect-banner-budget.XXXXXX")" || exit 2
WORK="$(cd "$WORK" && pwd -P)"
HANGMARK="collect-banner-budget-hang-$$"
trap 'pkill -9 -f "$HANGMARK" >/dev/null 2>&1; rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin" "$WORK/fake" "$WORK/accounts" "$WORK/conf/fleets/fixture" "$WORK/.claude-dash/global"
for f in tmux-dash-collect.sh fleet-quotawatch.sh fleet-account.sh fleet_iso.py fleet-lib.sh usage-lib.sh fleet-restore.sh; do
  cp "$BIN/$f" "$WORK/bin/"
done
printf 'tok-a\n' > "$WORK/accounts/acctA"
printf 'FLEET_REPO="acme/widgets"\n' > "$WORK/conf/fleets/fixture/conf"
G="$WORK/.claude-dash/global"
NWIN=24

# The account truth, stubbed: 24 verified windows on one fleet socket, all acctA.
cat > "$WORK/bin/fleet-account-truth.sh" <<'STUB'
#!/bin/bash
[ "${1:-}" = --socket ] || exit 2
i=1; while [ "$i" -le "${FAKE_NWIN:-24}" ]; do printf '@%s\t%%%s\tacctA\t0\n' "$i" "$i"; i=$((i+1)); done
STUB

# fake tmux: @1-@3 are `working`; capture-pane logs its target, costs FAKE_CAP_SLEEP,
# and wedges ONCE on FAKE_CAP_HANG (a marker file makes the second visit fast).
cat > "$WORK/fake/tmux" <<'FAKE'
#!/bin/bash
label=''
if [ "${1:-}" = -L ] || [ "${1:-}" = -S ]; then label="$2"; shift 2; fi
case "${1:-}" in
  has-session) exit 0 ;;
  list-sessions) [ -n "$label" ] && printf '%s\n' "$label"; exit 0 ;;
  list-windows)
    for a in "$@"; do
      case "$a" in
        *'#{?@remote,,x}'*) i=1; while [ "$i" -le "${FAKE_NWIN:-24}" ]; do echo x; i=$((i+1)); done; exit 0 ;;
        *'@claude_state},working'*) printf '@1\n@2\n@3\n'; exit 0 ;;
      esac
    done
    exit 0 ;;
  capture-pane)
    t=''; prev=''
    for a in "$@"; do [ "$prev" = -t ] && t="$a"; prev="$a"; done
    printf '%s\n' "$t" >> "$FAKE_CAPLOG"
    if [ "$t" = "${FAKE_CAP_HANG:-__none__}" ] && [ ! -e "$FAKE_CAPLOG.hung" ]; then
      : > "$FAKE_CAPLOG.hung"; exec -a "$FAKE_HANG_MARK" sleep 120
    fi
    [ -n "${FAKE_CAP_SLEEP:-}" ] && sleep "$FAKE_CAP_SLEEP"
    exit 0 ;;
  *) exit 0 ;;
esac
FAKE
chmod +x "$WORK/fake/"* "$WORK/bin/"*.sh

fail() { printf 'selftest FAIL: %s\n' "$1" >&2
         [ -f "$WORK/stderr" ] && { printf -- '--- stderr ---\n' >&2; cat "$WORK/stderr" >&2; }
         [ -f "$G/collect.heartbeat" ] && { printf -- '--- heartbeat ---\n' >&2; cat "$G/collect.heartbeat" >&2; }
         exit 1; }
ok() { printf '  ok — %s\n' "$1"; }
export PATH="$WORK/fake:$PATH" FAKE_CAPLOG="$WORK/cap.log" FAKE_HANG_MARK="$HANGMARK" FAKE_NWIN="$NWIN"

# Extract the banner phase's functions, so A/B run them without a whole tick.
python3 - "$BIN/tmux-dash-collect.sh" "$WORK/phase.sh" <<'PY'
import re, sys
s = open(sys.argv[1]).read()
out = []
for name in ('atomic_write', 'banner_budget', 'ph_banner', 'banner_scan_one', 'ph_banner_over'):
    f = re.search(r'^' + name + r'\(\) \{\n.*?^\}', s, re.M | re.S)
    assert f, name
    out.append(f.group(0))
open(sys.argv[2], 'w').write('\n'.join(out) + '\n')
PY
[ $? = 0 ] || fail 'could not extract the banner phase functions'
# in_phase CMD… — run CMD with the collector's environment for the banner phase.
# shellcheck disable=SC2034  # read by the sourced phase functions, not here
in_phase() {
  ( BIN="$WORK/bin"; . "$BIN/fleet-lib.sh"; . "$BIN/usage-lib.sh"; . "$WORK/phase.sh"
    SOCKETS=fixture; US=$'\037'; C="$WORK/.claude-dash"; FLEET_CONF_DIR="$WORK/conf"
    FLEET_ACCOUNTS_DIR="$WORK/accounts"; FLEET_NOTIFY_CMD=''
    "$@" )
}

# A. BUDGET ------------------------------------------------------------------------
b=$(in_phase banner_budget)
[ "$b" = 36 ] || fail "A: 24 windows × 1.5s must budget 36s, over the 30s floor (got: $b)"
b=$(FAKE_NWIN=4 in_phase banner_budget)
[ "$b" = 30 ] || fail "A: 4 windows must keep the 30s floor (got: $b)"
b=$(FLEET_COLLECT_BANNER_BUDGET=60 in_phase banner_budget)
[ "$b" = 60 ] || fail "A: a floor above the window term wins (got: $b)"
b=$(FLEET_COLLECT_BANNER_BUDGET=0 in_phase banner_budget)
[ "$b" = 0 ] || fail "A: 0 must stay unbudgeted (got: $b)"
b=$(FLEET_COLLECT_BANNER_PER_WINDOW_MS=0 in_phase banner_budget)
[ "$b" = 30 ] || fail "A: per-window 0 is the old fixed budget (got: $b)"
# shellcheck disable=SC2034  # read by the sourced banner_budget
b=$( BIN="$WORK/bin"; . "$BIN/fleet-lib.sh"; . "$WORK/phase.sh"; SOCKETS=fixture; FLEET_ACCOUNTS_DIR="$WORK/none"; banner_budget )
[ "$b" = 30 ] || fail "A: no accounts dir (phase is a no-op) must be just the floor (got: $b)"
ok "budget = max(floor, windows × 1.5s): 24 → 36s, 4 → 30s; floor/0/no-accounts honoured"

# B. ROTATION ----------------------------------------------------------------------
# Tick 1 wedges on the cold window %10: the box kills it there. Tick 2 must scan the
# working windows first, then resume AFTER the claimed %10 — so the 14 cold windows
# tick 1 never reached are covered, and every window was scanned within two ticks.
: > "$FAKE_CAPLOG"; rm -f "$FAKE_CAPLOG.hung" "$G/banner.cursor"
FAKE_CAP_HANG=%10 in_phase fleet_timebox 3 ph_banner; rc=$?
[ "$rc" = 124 ] || fail "B: the wedged tick must be killed by its box (rc=$rc)"
t1=$(tr '\n' ' ' < "$FAKE_CAPLOG")
[ "$t1" = '%1 %2 %3 %4 %5 %6 %7 %8 %9 %10 ' ] \
  || fail "B: tick 1 must scan working windows first, then cold in order up to the wedge (got: $t1)"
[ "$(tr '\t' ' ' < "$G/banner.cursor")" = 'fixture @10' ] \
  || fail "B: the wedged cold window must be CLAIMED before its scan (cursor: $(cat "$G/banner.cursor"))"
over=$(in_phase ph_banner_over 2>&1)
case "$over" in *'banner covered '*'next tick resumes after fixture @10'*) : ;;
  *) fail "B: ph_banner_over must say how far the rotation got (got: $over)" ;; esac
: > "$FAKE_CAPLOG"
in_phase fleet_timebox 30 ph_banner || fail 'B: tick 2 must complete'
t2=$(tr '\n' ' ' < "$FAKE_CAPLOG")
[ "$t2" = '%1 %2 %3 %11 %12 %13 %14 %15 %16 %17 %18 %19 %20 %21 %22 %23 %24 %4 %5 %6 %7 %8 %9 %10 ' ] \
  || fail "B: tick 2 must run working first, then resume after %10 and wrap (got: $t2)"
miss=''; i=1
while [ "$i" -le "$NWIN" ]; do
  case " $t1 $t2 " in *" %$i "*) : ;; *) miss="$miss %$i" ;; esac; i=$((i+1))
done
[ -z "$miss" ] || fail "B: windows not scanned within two ticks:$miss"
[ "$(pgrep -f "$HANGMARK" 2>/dev/null | wc -l | tr -d ' ')" = 0 ] || fail 'B: the wedged capture outlived its box'
ok "working windows first every tick; a killed tick resumes after the claimed window — all $NWIN within two ticks"

# C. HEARTBEAT — a real tick over the 24-window fixture --------------------------
# Each capture costs 0.2s (≈5s for 24) against a 2s floor. The window term
# (24 × 500ms = 12s) carries it; with that term off the same tick is killed.
run_tick() {
  env TMPDIR="$WORK" HOME="$WORK" FLEET_SKIP_GLOBAL_CONF=1 GH_TTL=0 \
    FLEET_REPO='' FLEET_REPOS='' FLEET_NOTIFY_CMD='' FLEET_CONF_DIR="$WORK/conf" \
    FLEET_ACCOUNTS_DIR="$WORK/accounts" FLEET_COLLECT_QUOTAWATCH=never \
    FLEET_COLLECT_TICK_BUDGET=120 FLEET_COLLECT_BANNER_BUDGET=2 FAKE_CAP_SLEEP=0.2 "$@" \
    bash "$WORK/bin/tmux-dash-collect.sh" >/dev/null 2>"$WORK/stderr"
}
hbget() { sed -n "s/^$1=//p" "$G/collect.heartbeat" | head -1; }
# B ran the phase in THIS shell, so its progress file carries our $$ — not a tick's.
rm -f "$G/banner.cursor" "$G/collect.phase.cursor" "$G"/collect.banner.prog.*
run_tick FLEET_COLLECT_BANNER_PER_WINDOW_MS=500 || fail 'C: the tick must exit 0'
[ "$(hbget phase)" = 'done' ] || fail 'C: the tick must reach phase=done'
case " $(hbget over) " in *' banner '*) fail "C: the banner phase was killed with a window-scaled budget (over=$(hbget over))" ;; esac
grep -q 'phase banner hit' "$WORK/stderr" && fail 'C: stderr says the banner phase hit its budget'
[ "$(hbget banner_scanned)" = 24 ] && [ "$(hbget banner_total)" = 24 ] \
  || fail "C: heartbeat must read banner_scanned=24 banner_total=24 (got: $(hbget banner_scanned)/$(hbget banner_total))"
ls "$G"/collect.banner.prog.* >/dev/null 2>&1 && fail 'C: the progress file outlived the tick'
ok "a real 24-window tick: banner not killed, heartbeat banner_scanned=24 banner_total=24"

rm -f "$G/banner.cursor" "$G/collect.phase.cursor"
run_tick FLEET_COLLECT_BANNER_PER_WINDOW_MS=0 || fail 'C: the fixed-budget tick must still exit 0'
case " $(hbget over) " in *' banner '*) : ;; *) fail "C: the fixed 2s budget must kill the banner phase here (over=$(hbget over))" ;; esac
grep -q 'phase banner hit the 2s budget (FLEET_COLLECT_BANNER_BUDGET)' "$WORK/stderr" \
  || fail 'C: stderr must name the banner budget and its knob'
grep -q 'fleet-collect: banner covered [0-9]*/24 window(s)' "$WORK/stderr" \
  || fail 'C: stderr must say how far the killed banner rotation got'
s=$(hbget banner_scanned)
[ "$(hbget banner_total)" = 24 ] && [ -n "$s" ] && [ "$s" -lt 24 ] \
  || fail "C: a killed tick's heartbeat must show the partial count (got: $s/$(hbget banner_total))"
ok "control: the pre-#1588 fixed budget IS killed on the same fixture (heartbeat $s/24, stderr names the cursor)"

printf 'selftest PASS: banner phase — window-scaled budget · working-first rotation · heartbeat (#1588)\n'
