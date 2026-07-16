#!/bin/bash
# attn-signal-selftest.sh — the unified attention signal (issues #166, #368).
#
# History: #166 split one 'needs' state into two signals — @attn_needs (workers,
# hub panels excluded) drove a "● N" badge, @steward_needs drove a red ⌂ beacon.
# #368 UNIFIES them back into ONE number and adds cross-fleet reach:
#   @attn_needs         — count of needy windows, now counting the plan (steward)
#                         window as a normal session and excluding ONLY the
#                         non-claude panels dash/backlog. A needy steward lands in
#                         this one badge; @steward_needs is RETIRED (the ⌂ is
#                         nav-only). status-left renders it as a red "● N" with a
#                         render-time ACTIVE-WINDOW DISCOUNT (you don't count the
#                         needy window you're already on — plan included).
#   @attn_other_windows — how many needy WINDOWS wait across OTHER live fleets
#                         (same unit as the local badge; replaces the old
#                         @attn_other_fleets fleet-count). status-left renders it as
#                         a second, ORANGE "● N" dot; clicking it one-tap jumps to
#                         the waiting fleet (fleet-xfleet-jump.sh).
#
# This drives the REAL code end-to-end on isolated -L sockets (never the user's live
# server), so it tests the shipped logic, not a copy:
#
#   PART A — run bin/tmux-spinner.sh (each fleet on its own -L socket, discovered via
#     an isolated FLEET_CONF_DIR) over a fixture of sessions in known @claude_state
#     values, then read back the @attn_needs / @attn_other_windows it published.
#     Asserts: plan counts, dash/backlog excluded, stateless windows named like state
#     keywords never miscount, @steward_needs is gone, and the cross-fleet WINDOW
#     aggregation ("total minus own").
#
#   PART B — the ⌂ hub icon is NAV-ONLY: expand the REAL status-left and assert the
#     ⌂ background is blue (bg=#7aa2f7) on the hub / dim (bg=#414868) off it, and
#     NEVER a red block (bg=#f7768e) — even when the hub itself is needy.
#
#   PART C — the LOCAL ● badge's active-window discount: a non-needy active window
#     shows the full count; an active needy WORKER discounts by 1; an active needy
#     PLAN also discounts (issue #368); an active needy dash/backlog does NOT (it is
#     not in the badge); and a discount that reaches 0 hides the whole chip.
#
#   PART D — the ORANGE cross-fleet ● dot: renders @attn_other_windows as a "● N" in
#     fg=#ff9e64 (distinct from the red local ●), from ANY window, hidden at 0.
#
#   PART E — jump-target resolution: fleet-xfleet-jump.sh --list resolves the OTHER
#     fleets with @attn_needs > 0 — exactly one (single jump) vs several (picker).
#
# tmux absent → SKIP cleanly (exit 0), per the run-selftests convention.
# Exit 0 = pass. Non-zero = fail (prints which assertion diverged).
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
SPINNER="$BIN/tmux-spinner.sh"
CONF="$BIN/../conf/tmux-attention.conf"
XJUMP="$BIN/fleet-xfleet-jump.sh"
[ -f "$SPINNER" ] || { printf 'selftest: %s not found\n' "$SPINNER" >&2; exit 2; }
[ -f "$CONF" ]    || { printf 'selftest: %s not found\n' "$CONF" >&2; exit 2; }
[ -f "$XJUMP" ]   || { printf 'selftest: %s not found\n' "$XJUMP" >&2; exit 2; }

REAL_TMUX="$(command -v tmux 2>/dev/null)"
[ -n "$REAL_TMUX" ] || { printf 'selftest: tmux not installed — SKIP\n' >&2; exit 0; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/attn-selftest.XXXXXX")" || exit 2

# Each fleet is its OWN tmux server on a named socket (issue #159): drive the real
# spinner exactly as production does. An isolated TMUX_TMPDIR keeps every `-L
# <fleet>` socket in this test's scratch dir (never the user's live servers), and a
# per-fleet conf is what fleet_sockets (spinner AND fleet-xfleet-jump.sh) enumerates.
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
# fleetA: needy hub(plan) + 2 needy workers + 1 working  → @attn_needs=3 (plan counts)
# fleetB: calm hub + 1 needy worker + 2 STATELESS windows → @attn_needs=1
#         (windows named exactly 'needs'/'done' must NOT be miscounted)
# fleetC: needy 'backlog' + needy 'dash' panels, calm plan → @attn_needs=0
#         (dash/backlog are excluded from the badge — the ONLY exclusions now)
# fleetD: calm hub + 1 working worker                     → @attn_needs=0
# Cross-fleet WINDOW total = 3+1+0+0 = 4, so each fleet's @attn_other_windows is
# 4 minus its own: A=1, B=3, C=4, D=4 (a fleet never counts its own windows).
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
tf fleetC new-window -t fleetC: -n dash
tf fleetD new-session -d -s fleetD -n plan
tf fleetD new-window -t fleetD: -n issue-5

setst() { local f="${1%%:*}"; tf "$f" set-window-option -t "$1" @claude_state "$2"; }
setst fleetA:plan   needs      # hub/steward now counts INTO the badge (issue #368)
setst fleetA:issue-1 needs      # worker → badge
setst fleetA:issue-2 needs      # worker → badge
setst fleetA:issue-3 working    # not needy
setst fleetB:plan   'done'     # quoted: 'done' is a shell keyword (SC1010)
setst fleetB:issue-9 needs      # worker → badge
setst fleetC:plan   idle
setst fleetC:backlog needs      # panel → excluded, NOT the badge
setst fleetC:dash   needs      # panel → excluded, NOT the badge
setst fleetD:plan   idle        # calm hub    → no need
setst fleetD:issue-5 working    # calm worker → no badge; fleetD needs NOTHING
# fleetB:needs and fleetB:done get NO @claude_state — an empty state field must not
# collapse and let the window NAME be read as the state (issue #166 review).

# --- PART A: run the real spinner, read back what it published ----------------
# Isolate its temp (CMDF lives at $TMPDIR/.claude-spin.cmds) so it never touches a
# live spinner's file; disable the stuck-working sweep (irrelevant here).
TMPDIR="$WORK" SPIN_INTERVAL=0.02 FLEET_STUCK_WORKING_SECS=0 \
  "$SPINNER" >/dev/null 2>&1 &
SPIN_PID=$!

# Poll until the spinner has published (first frame writes everything), up to ~10s.
# @attn_other_windows is published in the cross-fleet pass that runs AFTER the whole
# per-socket loop, so waiting on it guarantees @attn_needs is set too.
got=''
n=0
while [ "$n" -lt 200 ]; do
  got="$(tf fleetA show-options -t fleetA 2>/dev/null | grep -c '@attn_other_windows')"
  [ "$got" = 1 ] && break
  n=$((n + 1)); sleep 0.05
done
[ "$got" = 1 ] || fail "spinner never published @attn_other_windows within timeout"

opt() { tf "$1" show-options -t "$1" 2>/dev/null | awk -v k="$2" '$1==k{gsub(/"/,"",$2); print $2}'; }

a_badge="$(opt fleetA @attn_needs)"
b_badge="$(opt fleetB @attn_needs)"
c_badge="$(opt fleetC @attn_needs)"
d_badge="$(opt fleetD @attn_needs)"

[ "$a_badge" = 3 ] || fail "fleetA badge: expected 3 (needy plan + 2 workers), got '${a_badge}'"
[ "$b_badge" = 1 ] || fail "fleetB badge: expected 1 worker, got '${b_badge}' (a stateless window named 'needs' must NOT collapse into the tally)"
[ "$c_badge" = 0 ] || fail "fleetC badge: expected 0 (needy dash+backlog panels are excluded), got '${c_badge}'"
[ "$d_badge" = 0 ] || fail "fleetD badge: expected 0, got '${d_badge}'"

# @steward_needs is RETIRED (issue #368) — the spinner must no longer publish it.
[ -z "$(opt fleetA @steward_needs)" ] || fail "fleetA: @steward_needs must be retired (unset), got '$(opt fleetA @steward_needs)'"
[ -z "$(opt fleetC @steward_needs)" ] || fail "fleetC: @steward_needs must be retired (unset), got '$(opt fleetC @steward_needs)'"

# Cross-fleet WINDOW count (issue #368): total needy windows = 4 (A:3 + B:1); each
# fleet sees that total minus its own count — proving the aggregation is over WINDOWS
# (the old @attn_other_fleets counted FLEETS: A/B/C would each have seen 2, D 3).
a_other="$(opt fleetA @attn_other_windows)"
b_other="$(opt fleetB @attn_other_windows)"
c_other="$(opt fleetC @attn_other_windows)"
d_other="$(opt fleetD @attn_other_windows)"
[ "$a_other" = 1 ] || fail "fleetA cross-fleet: expected 1 other needy window (B's 1), got '${a_other}'"
[ "$b_other" = 3 ] || fail "fleetB cross-fleet: expected 3 other needy windows (A's 3), got '${b_other}'"
[ "$c_other" = 4 ] || fail "fleetC cross-fleet: expected 4 other needy windows (A+B), got '${c_other}'"
[ "$d_other" = 4 ] || fail "fleetD cross-fleet: expected 4 other needy windows (A+B), got '${d_other}'"
# And the retired option must be gone.
[ -z "$(opt fleetA @attn_other_fleets)" ] || fail "fleetA: @attn_other_fleets must be retired (unset)"

kill "$SPIN_PID" 2>/dev/null; SPIN_PID=''
printf 'PART A ok: unified badge — A●3(plan+2), B●1, C●0(dash/backlog excl), D●0; @steward_needs retired\n'
printf 'PART A ok: cross-fleet WINDOW count — A1 B3 C4 D4 (total 4 minus own), @attn_other_fleets retired (#368)\n'

# --- shared render helper: expand the REAL status-left as seen FROM a window ---
# Pull the shipped `set -g status-left "..."` value and expand it in a chosen
# window's context (display-message leaves #[...] literal when not writing to a tty,
# so we can grep the chosen styles/counts). status-left renders in the ACTIVE
# window's context, and `-t <sess>:<window>` pins that context to <window>.
SL="$(grep -m1 '^set -g status-left ' "$CONF" | sed -e 's/^set -g status-left "//' -e 's/"$//')"
[ -n "$SL" ] || fail "could not extract status-left from $CONF"
sl_at() { tf "$1" display-message -p -t "$1:$2" "$SL"; }

# --- PART B: the ⌂ hub icon is NAV-ONLY (issue #368) --------------------------
# Even with the hub itself needy, the ⌂ must be blue (on hub) / dim (off hub) and
# NEVER a red block (bg=#f7768e) — the red steward beacon is retired. (The red local
# ● uses fg=#f7768e, so we grep the bg= form to isolate the icon block.)
tf fleetB set-option -t fleetB @attn_needs 1
tf fleetB set-option -t fleetB @attn_other_windows 0
tf fleetB set-window-option -t fleetB:plan @claude_state needs   # needy hub
out="$(sl_at fleetB plan)"
case "$out" in *"bg=#7aa2f7"*) : ;; *) fail "⌂ nav-only: on the hub expected blue block bg=#7aa2f7" ;; esac
case "$out" in *"bg=#f7768e"*) fail "⌂ nav-only: needy hub must NOT show a red ⌂ block (beacon retired)" ;; esac
out="$(sl_at fleetB issue-9)"
case "$out" in *"bg=#414868"*) : ;; *) fail "⌂ nav-only: off the hub expected dim block bg=#414868" ;; esac
case "$out" in *"bg=#f7768e"*) fail "⌂ nav-only: off-hub must NOT show a red ⌂ block" ;; esac
tf fleetB set-window-option -t fleetB:plan @claude_state 'done'  # restore
printf 'PART B ok: ⌂ nav-only — blue(on-hub)/dim(off-hub), never a red block, even on a needy hub (#368)\n'

# --- PART C: the local ● badge's active-window discount (#368, supersedes #363) --
# Zero the orange cross-fleet dot on the fleets we render so the ONLY ● is the local
# badge under test.
for f in fleetA fleetB fleetC; do tf "$f" set-option -t "$f" @attn_other_windows 0; done
tf fleetA set-option -t fleetA @attn_needs 3
# (a) non-needy active window (issue-3=working) → full count, no discount
case "$(sl_at fleetA issue-3)" in *"● 3"*) : ;; *) fail "discount(a): non-needy active window must show the full ● 3" ;; esac
# (b) active needy WORKER (issue-1=needs) → discount by 1
case "$(sl_at fleetA issue-1)" in *"● 2"*) : ;; *) fail "discount(b): active needy worker must discount to ● 2" ;; esac
# (c) active needy PLAN/steward (plan=needs) → ALSO discounts (issue #368)
case "$(sl_at fleetA plan)" in *"● 2"*) : ;; *) fail "discount(c): active needy plan/steward must discount to ● 2 (#368)" ;; esac
# (d) active needy dash/backlog PANEL → NOT discounted (never in the badge)
tf fleetC set-option -t fleetC @attn_needs 3
case "$(sl_at fleetC backlog)" in *"● 3"*) : ;; *) fail "discount(d): active needy backlog must NOT discount (● 3)" ;; esac
case "$(sl_at fleetC dash)"    in *"● 3"*) : ;; *) fail "discount(d): active needy dash must NOT discount (● 3)" ;; esac
# (e) discount → 0 → the whole chip hides (issue-9 is the sole needy worker, badge=1)
tf fleetB set-option -t fleetB @attn_needs 1
case "$(sl_at fleetB issue-9)" in *"●"*) fail "discount(e): the sole needy active worker must HIDE the badge" ;; *) : ;; esac
printf 'PART C ok: ● discount — full off-target, -1 on a needy worker/plan, none on dash/backlog, hidden at 0\n'

# --- PART D: the ORANGE cross-fleet ● dot (issues #236, #368) ------------------
# @attn_other_windows > 0 → a "● N" in orange (fg=#ff9e64, distinct from the red
# local ●), from ANY window; hidden at 0. Zero the local badge so the only ● is the
# cross-fleet dot.
tf fleetB set-option -t fleetB @attn_needs 0
tf fleetB set-option -t fleetB @attn_other_windows 3
out="$(sl_at fleetB plan)"
case "$out" in *"fg=#ff9e64"*) : ;; *) fail "cross-fleet ●: expected orange fg=#ff9e64 when @attn_other_windows=3" ;; esac
case "$out" in *"● 3"*)        : ;; *) fail "cross-fleet ●: expected the window count ● 3" ;; esac
case "$(sl_at fleetB issue-9)" in *"● 3"*) : ;; *) fail "cross-fleet ●: must render from a worker window too" ;; esac
tf fleetB set-option -t fleetB @attn_other_windows 0
case "$(sl_at fleetB plan)" in *"fg=#ff9e64"*) fail "cross-fleet ●: must be HIDDEN when @attn_other_windows=0" ;; *) : ;; esac
printf 'PART D ok: orange cross-fleet ● — fg=#ff9e64 window count, from any window, hidden at 0 (#368)\n'

# --- PART E: jump-target resolution (fleet-xfleet-jump.sh --list) --------------
# --list resolves the OTHER live fleets with @attn_needs > 0. Set A=3, B=1, C=D=0:
# only A and B wait, so from A's view exactly B waits (single jump), from B's view
# exactly A, and from a calm fleet BOTH wait (→ the scoped picker). XFLEET_CUR names
# the "current" fleet (no attached client to read #S from in this headless test).
tf fleetA set-option -t fleetA @attn_needs 3
tf fleetB set-option -t fleetB @attn_needs 1
tf fleetC set-option -t fleetC @attn_needs 0
tf fleetD set-option -t fleetD @attn_needs 0

list="$(XFLEET_CUR=fleetA "$XJUMP" --list)"
[ "$list" = fleetB ] || fail "jump(single): from fleetA expected exactly 'fleetB', got '${list}'"
list="$(XFLEET_CUR=fleetB "$XJUMP" --list)"
[ "$list" = fleetA ] || fail "jump(single): from fleetB expected exactly 'fleetA', got '${list}'"
list="$(XFLEET_CUR=fleetC "$XJUMP" --list | sort | tr '\n' ' ')"
[ "$list" = "fleetA fleetB " ] || fail "jump(multi): from calm fleetC expected 'fleetA fleetB ', got '${list}'"
list="$(XFLEET_CUR=fleetA "$XJUMP" --list)"   # sanity: A never lists itself
case "$list" in *fleetA*) fail "jump: a fleet must never resolve ITSELF as a target" ;; *) : ;; esac
printf 'PART E ok: jump-target resolution — single (A→B, B→A) vs multiple (calm→A+B), never self (#368)\n'

printf 'selftest PASS: unified ● badge (#368) — plan-in-badge + active-window discount + orange cross-fleet ● + one-tap jump\n'
exit 0
