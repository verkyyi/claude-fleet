#!/bin/bash
# session-slots-sleep-selftest.sh — sleeping sessions stop using session slots
# (issue #1058).
#
#   A. fleet_session_count / fleet_session_count_for leave out a window whose
#      @worker_lifecycle is `sleeping` or `failed`, and still count an awake,
#      `preparing` or `waking` one; fleet_session_sleepers(_for) tally the rest.
#   B. DEGENERATE CASE: a fleet with no sleepers counts byte for byte what the
#      pre-#1058 bodies (copied verbatim below) count — including a window whose
#      NAME holds spaces and ends in the word `sleeping`.
#   C. The slots chip reads `slots 2/3 · z2`; a fleet with no sleepers renders
#      the old chip unchanged. fleet_session_cap_ok's refusal names the sleepers.
#   D. fleet_cap_full: exit 1 with a free slot, exit 0 + "<n> <max>" at a cap —
#      global, then per-fleet (FLEET_MAX_SESSIONS).
#   E. Rows: a sleeper whose automatic wake waits for a slot
#      (@sleep_wake_deferred=cap) reads `waiting for a slot` in the sidebar label
#      and `z · waiting for a slot` in the dash row; a plain sleeper does not.
#
# Real tmux on an ISOLATED socket via the PATH shim (never the live server — see
# dash-marker-selftest.sh). tmux absent → SKIP. Exit 0 = pass.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
CHECKS=0
fail() { printf 'selftest FAIL: %s\n' "$1" >&2; [ $# -gt 1 ] && printf '%s\n' "$2" >&2; exit 1; }
eq() { CHECKS=$((CHECKS + 1)); [ "$2" = "$3" ] || fail "$1 — expected [$2], got [$3]"; }
contains() { CHECKS=$((CHECKS + 1)); case "$2" in *"$3"*) ;; *) fail "$1 — output does not contain [$3]" "$2";; esac; }
not_contains() { CHECKS=$((CHECKS + 1)); case "$2" in *"$3"*) fail "$1 — output unexpectedly contains [$3]" "$2";; esac; }

REAL_TMUX="$(command -v tmux 2>/dev/null)"
[ -n "$REAL_TMUX" ] || { printf 'session-slots-sleep-selftest: tmux not installed — SKIPPED\n'; exit 0; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/session-slots-sleep-selftest.XXXXXX")" || exit 2
export FLEET_SKIP_GLOBAL_CONF=1
export FLEET_CONF_DIR="$WORK/conf"
S=fleetS
mkdir -p "$WORK/conf/fleets/$S" "$WORK/bin"
: > "$WORK/conf/fleets/$S/conf"
SOCK="$WORK/$(. "$BIN/fleet-lib.sh"; fleet_socket "$S")"
cat > "$WORK/bin/tmux" <<EOF
#!/bin/sh
exec "$REAL_TMUX" -S "$SOCK" "\$@"
EOF
chmod +x "$WORK/bin/tmux"
export PATH="$WORK/bin:$PATH"
export TMPDIR="$WORK"
cleanup() { tmux kill-server 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT
trap 'exit 130' INT TERM HUP

tmux new-session -d -s "$S" -n plan -x 220 -y 50 -c "$WORK" 'sleep 300' || fail "could not start the isolated tmux server"
export TMUX="$SOCK,1,0"
# shellcheck source=/dev/null
. "$BIN/fleet-lib.sh"
unset FLEET_GLOBAL_MAX_SESSIONS FLEET_MAX_SESSIONS

mk_win() { # <name> <issue> → window id
  local wid
  wid=$(tmux new-window -d -P -F '#{window_id}' -t "$S:" -n "$1" -c "$WORK" 'sleep 300')
  tmux set-window-option -t "$wid" @issue "$2"
  printf '%s' "$wid"
}

# The pre-#1058 bodies, verbatim: the degenerate-case oracle.
old_count() {
  fleet_list_windows_all '#{session_name} #{window_name}' | awk '
    { rows[NR]=$0; if ($2=="plan" || $2=="dash") fleet[$1]=1 }
    END {
      for (i=1; i<=NR; i++) {
        split(rows[i], a, " "); s=a[1]; w=a[2]
        if (fleet[s] && w!="dash" && w!="plan" && w!="backlog") c++
      }
      print c+0
    }'
}
old_count_for() {
  tmux -L "$(fleet_socket "$1")" list-windows -t "$1" -F '#{window_name}' 2>/dev/null | awk '
    { name=$0; if (name=="plan" || name=="dash") hub=1; rows[NR]=name }
    END {
      if (!hub) { print 0; exit }
      for (i=1; i<=NR; i++) {
        n=rows[i]
        if (n!="dash" && n!="plan" && n!="backlog") c++
      }
      print c+0
    }'
}

# ── B. no sleepers: identical to the old count ──────────────────────────────────
W1=$(mk_win work1 301)
W2=$(mk_win "spaced name sleeping" 302)
W3=$(mk_win work3 303)
W4=$(mk_win work4 304)
tmux new-window -d -t "$S:" -n backlog 'sleep 300'
eq "degenerate: global count matches the old body"    "$(old_count)"         "$(fleet_session_count)"
eq "degenerate: per-fleet count matches the old body" "$(old_count_for "$S")" "$(fleet_session_count_for "$S")"
eq "degenerate: 4 workers counted (panels excluded)"  4 "$(fleet_session_count)"
eq "degenerate: no sleepers" 0 "$(fleet_session_sleepers)"
chip_old=$(FLEET_GLOBAL_MAX_SESSIONS=8 fleet_slots_chip 4)
eq "degenerate: chip with no sleepers is the old chip" "$chip_old" "$(FLEET_GLOBAL_MAX_SESSIONS=8 fleet_slots_chip)"
not_contains "degenerate: chip carries no z" "$chip_old" "· z"

# ── A. sleeping / failed leave the count; preparing / waking stay ──────────────
tmux set-window-option -t "$W1" @worker_lifecycle sleeping
tmux set-window-option -t "$W3" @worker_lifecycle failed
tmux set-window-option -t "$W4" @worker_lifecycle waking
eq "count: sleeping + failed are left out (global)"    2 "$(fleet_session_count)"
eq "count: sleeping + failed are left out (per-fleet)" 2 "$(fleet_session_count_for "$S")"
eq "sleepers: global tally"    2 "$(fleet_session_sleepers)"
eq "sleepers: per-fleet tally" 2 "$(fleet_session_sleepers_for "$S")"
tmux set-window-option -t "$W4" @worker_lifecycle preparing
eq "count: preparing still holds its slot" 2 "$(fleet_session_count_for "$S")"
eq "count: an awake window NAMED '… sleeping' still counts" 2 "$(fleet_session_count)"

# ── C. chip + refusal ──────────────────────────────────────────────────────────
chip=$(FLEET_GLOBAL_MAX_SESSIONS=3 fleet_slots_chip | LC_ALL=C sed -e $'s/\x1b\\[[0-9;]*m//g')
contains "chip: sleepers shown apart" "$chip" "slots 2/3 · z2"
eq "chip: unlimited cap" "slots 2 · z2" "$(FLEET_GLOBAL_MAX_SESSIONS=0 fleet_slots_chip)"
msg=$(FLEET_GLOBAL_MAX_SESSIONS=2 fleet_session_cap_ok "$S"); rc=$?
eq "cap_ok: refused at 2/2 awake" 1 "$rc"
contains "cap_ok: refusal counts awake only and names the sleepers" "$msg" "2/2 Claude sessions running (global) · z2 sleeping"
FLEET_GLOBAL_MAX_SESSIONS=3 fleet_session_cap_ok "$S" >/dev/null; eq "cap_ok: sleepers leave room at 2/3" 0 "$?"

# ── D. fleet_cap_full ──────────────────────────────────────────────────────────
out=$(FLEET_GLOBAL_MAX_SESSIONS=3 fleet_cap_full "$S"); rc=$?
eq "cap_full: free slot → exit 1" "1:" "$rc:$out"
out=$(FLEET_GLOBAL_MAX_SESSIONS=2 fleet_cap_full "$S"); rc=$?
eq "cap_full: global cap reached → 0 + n max" "0:2 2" "$rc:$out"
out=$(FLEET_GLOBAL_MAX_SESSIONS=0 FLEET_MAX_SESSIONS=2 fleet_cap_full "$S"); rc=$?
eq "cap_full: per-fleet cap reached" "0:2 2" "$rc:$out"
out=$(FLEET_GLOBAL_MAX_SESSIONS=0 FLEET_MAX_SESSIONS=2 fleet_cap_full); rc=$?
eq "cap_full: per-fleet cap needs the session" "1:" "$rc:$out"

# ── E. rows: waiting for a slot ────────────────────────────────────────────────
US=$(printf '\037')
probe=$(tmux list-windows -t "$S" -F "a${US}b" 2>/dev/null | od -An -tx1 | tr -d ' \n')
case "$probe" in *611f62*) : ;; *) printf 'session-slots-sleep-selftest: tmux escapes US in -F — E SKIPPED (%d checks passed)\n' "$CHECKS"; exit 0 ;; esac
W5=$(mk_win napw 305)
tmux set-window-option -t "$W5" @worker_lifecycle sleeping
tmux set-window-option -t "$W5" @sleep_since $(( $(date +%s) - 600 ))
tmux set-window-option -t "$W5" @sleep_wake_deferred cap
strip() { LC_ALL=C sed -e $'s/\x1b\\[[0-9;]*m//g'; }
side=$(FLEET_SESSION=$S bash "$BIN/tmux-dashboard-rows.sh" --sidebar 2>/dev/null | strip)
row_of() { printf '%s\n' "$side" | awk -F"$US" -v w="$1" '$1 == w { print $3 "|" $4; exit }'; }
eq "sidebar: a deferred sleeper keeps its age and says it waits" "z 10m|napw · waiting for a slot" "$(row_of "$W5")"
not_contains "sidebar: a plain sleeper does not wait" "$(row_of "$W1")" "waiting"
dash=$(FLEET_SESSION=$S FZF_COLUMNS=180 bash "$BIN/tmux-dashboard-rows.sh" 2>/dev/null | strip)
contains "dash: the deferred row reads z · waiting for a slot" "$(printf '%s\n' "$dash" | grep ' napw ')" "z · waiting for a slot"
contains "dash: its act cell still reads the age" "$(printf '%s\n' "$dash" | grep ' napw ')" " z 10m "
not_contains "dash: a plain sleeper row does not wait" "$(printf '%s\n' "$dash" | grep ' work1 ')" "waiting"

printf 'session-slots-sleep-selftest: all %d checks passed\n' "$CHECKS"
