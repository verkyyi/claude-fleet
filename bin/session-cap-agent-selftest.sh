#!/bin/bash
# session-cap-agent-selftest.sh — a window with no agent in it holds no session
# slot (issue #2404, EPIC #2463 C1).
#
# On 2026-10-07 a login at FLEET_MAX_SESSIONS=4 was refused 「4/4」 while three of
# the four windows were shells a refused launch had left behind. On a REAL
# isolated tmux server (-S socket, a PATH shim that drops the fleet's `-L`):
#
#   A  fleet_window_has_agent: the wrapper gone (@wrap_gone, pane option), the
#      session on its recovery page (@claude_state exited) and a dead pane read
#      rc 1; a live window rc 0; a preparing one rc 0; no such window rc 2
#   B  fleet_session_count_for / fleet_session_count (fleet_session_tally): three
#      such shells + one agent count 1, and fleet_session_cap_ok admits a fifth
#      at FLEET_MAX_SESSIONS=4
#   C  four live agents: refused, and the refusal names the windows holding the
#      slots and one command that closes one (fleet-worker-stop.sh … fid:<id>)
#
# tmux absent → SKIP (exit 0).
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
REAL_TMUX="$(command -v tmux 2>/dev/null)"
[ -n "$REAL_TMUX" ] || { printf 'session-cap-agent: tmux absent — SKIP\n'; exit 0; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/scap.XXXXXX")" || exit 2
WORK="$(cd "$WORK" && pwd -P)"
SOCK="$WORK/s"
cleanup() { "$REAL_TMUX" -S "$SOCK" kill-server 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT
trap 'exit 130' INT TERM HUP
CHECKS=0
fail() { printf 'session-cap-agent FAIL: %s\n' "$1" >&2; [ $# -gt 1 ] && printf '%s\n' "$2" >&2; exit 1; }
eq() { CHECKS=$((CHECKS + 1)); [ "$2" = "$3" ] || fail "$1 — expected [$2], got [$3]"; }

# Every `tmux -L <label> …` the lib runs lands on the isolated server.
mkdir -p "$WORK/shim" "$WORK/conf"
cat > "$WORK/shim/tmux" <<EOF
#!/bin/bash
a=()
while [ \$# -gt 0 ]; do
  case "\$1" in -L) shift 2 ;; -S) shift 2 ;; *) a+=("\$1"); shift ;; esac
done
exec "$REAL_TMUX" -S "$SOCK" \${a[@]+"\${a[@]}"}
EOF
chmod +x "$WORK/shim/tmux"
export PATH="$WORK/shim:$PATH" FLEET_CONF_DIR="$WORK/conf"
unset TMUX TMUX_PANE

tf() { "$REAL_TMUX" -S "$SOCK" "$@"; }
tf -f /dev/null new-session -d -s capf -n home -x 100 -y 30 'sleep 600' || fail "cannot start the isolated tmux server"
tf set-option -g remain-on-exit on
tf set-option -w -t capf:home @fleet_role home
w() {  # <name> <command> — a worker window; prints its id
  local id; id=$(tf new-window -d -P -F '#{window_id}' -t capf: -n "$1" "$2")
  tf set-option -w -t "$id" @fleet_role worker
  tf set-option -w -t "$id" @fleet_id "fid-$1"
  printf '%s\n' "$id"
}
gone=$(w gone 'sleep 600');   tf set-option -p -t "$gone" @wrap_gone 1     # the caller's bare shell
exd=$(w exd 'sleep 600');     tf set-option -w -t "$exd" @claude_state exited
dead=$(w dead 'true')
live=$(w live 'sleep 600')
prep=$(w prep 'sleep 600');   tf set-option -p -t "$prep" @wrap_gone 1; tf set-option -w -t "$prep" @worker_lifecycle preparing
for _ in $(seq 1 50); do [ "$(tf display-message -p -t "$dead" '#{pane_dead}')" = 1 ] && break; sleep 0.1; done

# shellcheck source=fleet-lib.sh
. "$BIN/fleet-lib.sh"
fleet_sockets() { printf 'capf\n'; }      # the one fleet on the isolated server

# ----------------------------------------------- A: fleet_window_has_agent ----
for c in "gone:$gone:1" "exd:$exd:1" "dead:$dead:1" "live:$live:0" "prep:$prep:0"; do
  n=${c%%:*}; rest=${c#*:}; id=${rest%%:*}; want=${rest#*:}
  fleet_window_has_agent "$id"; eq "A/$n: fleet_window_has_agent rc" "$want" "$?"
done
fleet_window_has_agent '@999'; eq "A: no such window → rc 2" 2 "$?"

# ------------------------------------- B: three shells + one agent hold 1 ----
tf kill-window -t "$prep"
eq "B: per-fleet count — only the live agent" 1 "$(fleet_session_count_for capf)"
eq "B: global count — the same rule" 1 "$(fleet_session_count)"
msg=$(FLEET_MAX_SESSIONS=4 FLEET_ADMIT=0 fleet_session_cap_ok capf); rc=$?
eq "B: FLEET_MAX_SESSIONS=4 still admits a new session" 0 "$rc"
eq "B: and says nothing" "" "$msg"

# ------------------------------------ C: four live agents — named refusal ----
w live2 'sleep 600' >/dev/null; w live3 'sleep 600' >/dev/null; w live4 'sleep 600' >/dev/null
eq "C: four live agents count 4" 4 "$(fleet_session_count_for capf)"
msg=$(FLEET_MAX_SESSIONS=4 FLEET_ADMIT=0 fleet_session_cap_ok capf); rc=$?
eq "C: the fifth is refused" 1 "$rc"
CHECKS=$((CHECKS + 1)); case "$msg" in *"4/4"*"占着名额："*"$live live"*"live4"*) ;; *) fail "C: the refusal names the slot holders" "$msg" ;; esac
CHECKS=$((CHECKS + 1)); case "$msg" in *"fleet-worker-stop.sh capf fid:fid-live"*) ;; *) fail "C: the refusal gives a command that closes one" "$msg" ;; esac
CHECKS=$((CHECKS + 1)); case "$msg" in *gone*|*exd*|*dead*) fail "C: an agent-less window is named as a holder" "$msg" ;; esac

printf 'session-cap-agent: OK (%d checks)\n' "$CHECKS"
