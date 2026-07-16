#!/bin/bash
# attn-signal-selftest.sh — the split attention signals (issue #166).
#
# One 'needs' state used to feed one badge: bin/tmux-spinner.sh counted EVERY
# needy window into @attn_needs, so a needy steward hub (plan/dash/backlog) lit
# the worker "● N" dot. #166 splits that into two independent signals:
#   @attn_needs    — WORKERS only: needy windows EXCLUDING the hub panels.
#   @steward_needs — the HUB: 1 when a panel window is needy, else 0; the conf's
#                    ⌂ hub icon renders a red block when it's 1, from any window.
#
# This drives the REAL code end-to-end on an isolated -S socket (never the user's
# live server), so it tests the shipped logic, not a copy:
#
#   PART A — run bin/tmux-spinner.sh (PATH-shimmed onto the isolated socket) over
#     a fixture of sessions in known @claude_state values, then read back the
#     @attn_needs / @steward_needs it published. Asserts the tally split and
#     per-fleet isolation (one fleet's needy steward never touches another's).
#
#   PART B — expand the REAL `status-left` string from conf/tmux-attention.conf
#     via display-message and assert the ⌂ icon picks the right background:
#     red block (bg=#f7768e) when @steward_needs, else blue block (bg=#7aa2f7)
#     on the hub / dim (bg=#414868) off it — the three styles, from any window.
#
#   PART C — the CROSS-FLEET flag (issue #236): the spinner also publishes, per
#     fleet, @attn_other_fleets = how many OTHER live fleets currently need
#     attention (a worker badge or a needy steward hub). PART A asserts the count
#     (each of the 3 needy fleets sees 2 others; the 1 calm fleet sees 3); PART C
#     asserts the REAL status-left renders it as an orange "⚑ N" flag on the
#     existing #S chip — shown when > 0, hidden at 0 — reusing that element (no new
#     bar item) so an operator on one fleet sees that a DIFFERENT fleet is waiting.
#
#   PART D — the ACTIVE-WINDOW discount (issue #363): status-left renders in the
#     active window's context, so the ● N badge subtracts the active window when
#     it is itself a needy WORKER (you don't need pulling to a window you're on).
#     Expands the REAL status-left with -t <window> to simulate each active window
#     and asserts: a calm active window shows the full count; an active needy
#     worker is discounted by 1; an active needy PANEL is NOT discounted (it's
#     never in @attn_needs); and a discount to 0 hides the whole chip.
#
# tmux absent → SKIP cleanly (exit 0), per the run-selftests convention.
# Exit 0 = pass. Non-zero = fail (prints which assertion diverged).
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
SPINNER="$BIN/tmux-spinner.sh"
CONF="$BIN/../conf/tmux-attention.conf"
[ -f "$SPINNER" ] || { printf 'selftest: %s not found\n' "$SPINNER" >&2; exit 2; }
[ -f "$CONF" ]    || { printf 'selftest: %s not found\n' "$CONF" >&2; exit 2; }

REAL_TMUX="$(command -v tmux 2>/dev/null)"
[ -n "$REAL_TMUX" ] || { printf 'selftest: tmux not installed — SKIP\n' >&2; exit 0; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/attn-selftest.XXXXXX")" || exit 2

# Each fleet is its OWN tmux server on a named socket (issue #159): drive the real
# spinner exactly as production does. An isolated TMUX_TMPDIR keeps every `-L
# <fleet>` socket in this test's scratch dir (never the user's live servers), and
# a per-fleet conf is what fleet_sockets enumerates. No PATH shim needed — the
# spinner already names `-L "$sock"` on every call, resolved via TMUX_TMPDIR.
export TMUX_TMPDIR="$WORK/tmt"; mkdir -p "$TMUX_TMPDIR"
export FLEET_CONF_DIR="$WORK/conf"; mkdir -p "$FLEET_CONF_DIR"
for f in fleetA fleetB fleetC fleetD; do printf 'FLEET_REPO="acme/%s"\n' "$f" > "$FLEET_CONF_DIR/$f.conf"; done

# tf <fleet> <tmux-args…> — run tmux against THAT fleet's own server (socket ==
# session name). The socket resolves inside the isolated TMUX_TMPDIR set above.
tf() { local f="$1"; shift; "$REAL_TMUX" -L "$f" "$@"; }

SPIN_PID=''
cleanup() {
  [ -n "$SPIN_PID" ] && kill "$SPIN_PID" 2>/dev/null
  for f in fleetA fleetB fleetC fleetD; do "$REAL_TMUX" -L "$f" kill-server 2>/dev/null; done
  rm -rf "$WORK"
}
trap cleanup EXIT
# A bare EXIT trap does not fire on a signal — turn INT/TERM/HUP into a normal
# exit so cleanup still reaps the isolated servers (issue #152).
trap 'exit 130' INT TERM HUP

fail() { printf 'selftest FAIL: %s\n' "$1" >&2; exit 1; }

# --- fixture: four fleets, EACH ON ITS OWN SOCKET, hubs + workers in states ---
# fleetA: needy hub + 2 needy workers + 1 working  → @attn_needs=2 @steward_needs=1
# fleetB: calm hub + 1 needy worker + 2 STATELESS  → @attn_needs=1 @steward_needs=0
#         windows named like state keywords (must NOT be miscounted)
# fleetC: needy 'backlog' panel only               → @attn_needs=0 @steward_needs=1
# fleetD: calm hub + 1 working worker              → @attn_needs=0 @steward_needs=0
#         needs NOTHING — the cross-fleet control (issue #236): A/B/C all need, so D
#         must see 3 other needy fleets while each of A/B/C sees 2 (excludes itself)
tf fleetA new-session -d -s fleetA -n plan -x 200 -y 50 2>/dev/null || fail "could not start isolated tmux server"
tf fleetA new-window -t fleetA: -n issue-1
tf fleetA new-window -t fleetA: -n issue-2
tf fleetA new-window -t fleetA: -n issue-3
tf fleetB new-session -d -s fleetB -n plan
tf fleetB new-window -t fleetB: -n issue-9
tf fleetB new-window -t fleetB: -n needs       # STATELESS window named exactly 'needs'
tf fleetB new-window -t fleetB: -n 'done'      # STATELESS window named 'done' (quoted: SC1010)
tf fleetC new-session -d -s fleetC -n plan
tf fleetC new-window -t fleetC: -n backlog
tf fleetD new-session -d -s fleetD -n plan
tf fleetD new-window -t fleetD: -n issue-5

setst() { local f="${1%%:*}"; tf "$f" set-window-option -t "$1" @claude_state "$2"; }
setst fleetA:plan   needs      # hub → steward, NOT the badge
setst fleetA:issue-1 needs      # worker → badge
setst fleetA:issue-2 needs      # worker → badge
setst fleetA:issue-3 working    # not needy
setst fleetB:plan   'done'     # quoted: 'done' is a shell keyword (SC1010)
setst fleetB:issue-9 needs      # worker → badge
setst fleetC:plan   idle
setst fleetC:backlog needs      # panel → steward, NOT the badge
setst fleetD:plan   idle        # calm hub    → no steward need
setst fleetD:issue-5 working    # calm worker → no badge; fleetD needs NOTHING
# fleetB:needs and fleetB:done get NO @claude_state — an empty state field must
# not collapse and let the window NAME be read as the state (issue #166 review).

# --- PART A: run the real spinner, read back what it published ----------------
# Isolate its temp (CMDF lives at $TMPDIR/.claude-spin.cmds) so it never touches
# a live spinner's file; disable the stuck-working sweep (irrelevant here). The
# exported TMUX_TMPDIR + FLEET_CONF_DIR are what let the spinner's fleet_sockets
# discover our three fleets and drive each on its own -L socket.
TMPDIR="$WORK" SPIN_INTERVAL=0.02 FLEET_STUCK_WORKING_SECS=0 \
  "$SPINNER" >/dev/null 2>&1 &
SPIN_PID=$!

# Poll until the spinner has published (first frame writes everything), up to ~10s.
# Budget is generous (was ~3s) because the per-fleet-socket spinner (issue #159)
# forks a `tmux -L <label> has-session` per fleet on its FIRST frame to discover
# the live sockets, which under full-suite load can push first-publish past 3s —
# a race that flaked this test even though the steady-state behaviour is correct.
# @attn_other_fleets is published in the cross-fleet pass that runs AFTER the whole
# per-socket loop, so waiting on it guarantees @attn_needs/@steward_needs are set too.
got=''
n=0
while [ "$n" -lt 200 ]; do
  got="$(tf fleetA show-options -t fleetA 2>/dev/null | grep -c '@attn_other_fleets')"
  [ "$got" = 1 ] && break
  n=$((n + 1)); sleep 0.05
done
[ "$got" = 1 ] || fail "spinner never published @attn_other_fleets within timeout"

opt() { tf "$1" show-options -t "$1" 2>/dev/null | awk -v k="$2" '$1==k{gsub(/"/,"",$2); print $2}'; }

a_badge="$(opt fleetA @attn_needs)";   a_stew="$(opt fleetA @steward_needs)"
b_badge="$(opt fleetB @attn_needs)";   b_stew="$(opt fleetB @steward_needs)"
c_badge="$(opt fleetC @attn_needs)";   c_stew="$(opt fleetC @steward_needs)"

[ "$a_badge" = 2 ] || fail "fleetA badge: expected 2 workers, got '${a_badge}' (hub must be excluded)"
[ "$a_stew"  = 1 ] || fail "fleetA steward: expected 1 (needy hub), got '${a_stew}'"
[ "$b_badge" = 1 ] || fail "fleetB badge: expected 1 worker, got '${b_badge}' (a stateless window named 'needs' must NOT collapse into the tally)"
[ "$b_stew"  = 0 ] || fail "fleetB steward: expected 0 (calm hub), got '${b_stew}'"
[ "$c_badge" = 0 ] || fail "fleetC badge: expected 0 workers, got '${c_badge}'"
[ "$c_stew"  = 1 ] || fail "fleetC steward: expected 1 (needy 'backlog' panel), got '${c_stew}'"

# Cross-fleet count (issue #236): A/B/C each need attention, D does not. So each of
# A/B/C sees the OTHER two needy fleets (2), and calm D sees all three (3) — proving
# the per-fleet "minus its own need" subtraction and the estate-wide aggregation.
a_other="$(opt fleetA @attn_other_fleets)"
b_other="$(opt fleetB @attn_other_fleets)"
c_other="$(opt fleetC @attn_other_fleets)"
d_other="$(opt fleetD @attn_other_fleets)"
[ "$a_other" = 2 ] || fail "fleetA cross-fleet: expected 2 other needy fleets (B,C), got '${a_other}'"
[ "$b_other" = 2 ] || fail "fleetB cross-fleet: expected 2 other needy fleets (A,C), got '${b_other}'"
[ "$c_other" = 2 ] || fail "fleetC cross-fleet: expected 2 other needy fleets (A,B), got '${c_other}'"
[ "$d_other" = 3 ] || fail "fleetD cross-fleet: expected 3 other needy fleets (A,B,C — D itself calm), got '${d_other}'"

kill "$SPIN_PID" 2>/dev/null; SPIN_PID=''
printf 'PART A ok: tally split — A(●2,⌂) B(●1) C(⌂), hub excluded from the dot, per-fleet\n'
printf 'PART A ok: cross-fleet — A/B/C see 2 other needy fleets, calm D sees 3 (#236)\n'

# --- PART B: the three ⌂ styles from the REAL conf status-left ----------------
# Pull the shipped `set -g status-left "..."` value and expand it per state;
# display-message leaves #[...] literal when not writing to a tty, so we can grep
# the chosen background. The three bg hexes are each unique to one icon branch.
SL="$(grep -m1 '^set -g status-left ' "$CONF" | sed -e 's/^set -g status-left "//' -e 's/"$//')"
[ -n "$SL" ] || fail "could not extract status-left from $CONF"

render() { tf "$1" set-option -t "$1" @steward_needs "$2"; tf "$1" display-message -p -t "$1:$3" "$SL"; }

# on the hub (plan), calm steward → blue block, no red
out="$(render fleetB 0 plan)"
case "$out" in *"bg=#7aa2f7"*) : ;; *) fail "on-hub calm: expected blue block bg=#7aa2f7" ;; esac
case "$out" in *"bg=#f7768e"*) fail "on-hub calm: must NOT show the red beacon" ;; esac

# on the hub (plan), steward needs → red block wins over the on-hub blue
out="$(render fleetB 1 plan)"
case "$out" in *"bg=#f7768e"*) : ;; *) fail "on-hub needy: expected red block bg=#f7768e" ;; esac

# off the hub (a worker window), calm steward → dim block, no red
out="$(render fleetB 0 issue-9)"
case "$out" in *"bg=#414868"*) : ;; *) fail "off-hub calm: expected dim block bg=#414868" ;; esac
case "$out" in *"bg=#f7768e"*) fail "off-hub calm: must NOT show the red beacon" ;; esac

# off the hub, steward needs → red beacon visible from ANY window
out="$(render fleetB 1 issue-9)"
case "$out" in *"bg=#f7768e"*) : ;; *) fail "off-hub needy: red beacon must show from a worker window" ;; esac

printf 'PART B ok: ⌂ icon — red(bg=#f7768e) beacon over blue(on-hub)/dim(off-hub), from any window\n'

# --- PART C: the cross-fleet ⚑ flag on the #S chip (issue #236) ----------------
# The same shipped status-left, expanded with @attn_other_fleets set: > 0 shows an
# orange "⚑ N" flag right after the fleet name; 0 (like @attn_needs) hides it. This
# is the REUSE-an-existing-element requirement — the flag lives inside the #S chip,
# no new bar item — so it must render from ANY window, hub or worker.
tf fleetB set-option -t fleetB @attn_other_fleets 2
out="$(tf fleetB display-message -p -t fleetB:plan "$SL")"
case "$out" in *"⚑2"*)          : ;; *) fail "cross-fleet flag: expected ⚑2 on the #S chip when @attn_other_fleets=2" ;; esac
case "$out" in *"fg=#ff9e64"*)  : ;; *) fail "cross-fleet flag: expected the orange fg=#ff9e64 (distinct from the red local ● badge)" ;; esac
out="$(tf fleetB display-message -p -t fleetB:issue-9 "$SL")"
case "$out" in *"⚑2"*)          : ;; *) fail "cross-fleet flag: must render from a worker window too, got no ⚑2" ;; esac
tf fleetB set-option -t fleetB @attn_other_fleets 0
out="$(tf fleetB display-message -p -t fleetB:plan "$SL")"
case "$out" in *"⚑"*) fail "cross-fleet flag: must be HIDDEN when @attn_other_fleets=0" ;; *) : ;; esac

printf 'PART C ok: ⚑ N cross-fleet flag on the #S chip — shown >0, hidden at 0, from any window (#236)\n'

# --- PART D: the ● N active-window discount (issue #363) -----------------------
# The ● badge SUBTRACTS the active window when it is itself a needy WORKER — you
# don't need to be pulled to a window you're already on. Two invariants:
#   • a needy PANEL (plan/dash/backlog) is NEVER in @attn_needs (it drives the ⌂
#     beacon via @steward_needs), so it must NOT be discounted — else the real
#     workers undercount;
#   • when the only needy worker is the one you're on, shown → 0 and the whole
#     chip hides (same falsy-"0" path as the count-0 case).
# status-left renders in the ACTIVE window's context, so #{@claude_state}/#W are
# the active window's; we simulate "window X is active" by expanding the SAME
# shipped $SL with -t fleetA:X — exactly how PART B/C simulate the active window.
# @attn_needs is set directly per case: the discount is a render-time subtraction,
# so the spinner's raw count is not what's under test here (PART A already covered
# that). Reuses fleetA's windows: plan (hub panel) + issue-1/2/3 (workers).
attn_badge() { tf fleetA display-message -p -t "fleetA:$1" "$SL" | grep -o '● [0-9]*'; }
tf fleetA set-window-option -t fleetA:issue-1 @claude_state needs    # a needy worker
tf fleetA set-window-option -t fleetA:issue-3 @claude_state working  # a calm worker
tf fleetA set-window-option -t fleetA:plan    @claude_state needs    # a needy PANEL

# (a) needy workers exist but you're NOT on one (on a calm worker) → full count
tf fleetA set-option -t fleetA @attn_needs 3
gotd="$(attn_badge issue-3)"
[ "$gotd" = "● 3" ] || fail "discount (a): on a calm worker, 3 needy elsewhere → expected '● 3', got '${gotd:-<hidden>}'"

# (b) the active window IS itself a needy worker → discounted by exactly 1
gotd="$(attn_badge issue-1)"
[ "$gotd" = "● 2" ] || fail "discount (b): ON a needy worker with 3 needy → expected '● 2', got '${gotd:-<hidden>}'"

# (c) the active window is a needy PANEL → NOT discounted (panel isn't in @attn_needs)
gotd="$(attn_badge plan)"
[ "$gotd" = "● 3" ] || fail "discount (c): on a needy PANEL (plan) → expected '● 3' (no discount), got '${gotd:-<hidden>}'"

# (d) the sole needy worker is the one you're on → shown hits 0 → badge HIDDEN
tf fleetA set-option -t fleetA @attn_needs 1
outd="$(tf fleetA display-message -p -t fleetA:issue-1 "$SL")"
case "$outd" in *"●"*) fail "discount (d): on the sole needy worker (count 1) → badge must be HIDDEN, got a ● dot" ;; *) : ;; esac

printf 'PART D ok: ● N active-window discount — calm=full, active-needy-worker −1, needy-panel NOT discounted, 0→hidden (#363)\n'

printf 'selftest PASS: attention signals — ● N badge + ⌂ beacon (#166) + ⚑ N cross-fleet flag (#236) + ● active-window discount (#363)\n'
exit 0
