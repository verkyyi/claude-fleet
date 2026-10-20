#!/bin/bash
# hub-session-selftest.sh — a fleet's resting window is `home`, never a dash and
# never a Claude.
#
# hub-session.sh builds `home`, a plain shell the task list draws beside, at
# index 1 (issue #1533); the old `plan` dash hub (FLEET_DASH_WINDOW=1) went with
# the dash (issue #4902), and its legs with it. The print seam (HUB_PRINT_CMD)
# and a real isolated tmux pin:
#   • it opens `home` in $HOME (a fleet has no main repo, #1941), HUB_CWD pins it;
#   • FLEET_DASH_WINDOW=1, HUB_RESUME_ID or FLEET_HUB_CMD bring no dash and no
#     claude back — they are read by nothing;
#   • a real build puts `home` at index 1, no `plan`, no @dash pane, and a second
#     run builds nothing more.
#
# Hermetic: its own temp FLEET_CONF_DIR and tmux socket, no network.
# Exit 0 = pass. Non-zero = fail (prints which assertion diverged).
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
. "$BIN/selftest-lib.sh"
SCRIPT="$BIN/hub-session.sh"
[ -f "$SCRIPT" ] || { printf 'selftest: %s not found\n' "$SCRIPT" >&2; exit 2; }

st_sandbox "${TMPDIR:-/tmp}/hubsess-selftest.XXXXXX"
trap 'exit 1' INT TERM HUP

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

SESS=tf
CONF="$WORK/conf"
MAIN="$WORK/projects/widget"
mkdir -p "$CONF/fleets/$SESS" "$MAIN"
cat > "$CONF/fleets/$SESS/conf" <<EOF
FLEET_REPO="acme/widget"
FLEET_MAIN="$MAIN"
FLEET_BASE_BRANCH="main"
EOF

# --- the print seam: `home`, where -------------------------------------------
d=$(env -u FLEET_DASH_WINDOW FLEET_CONF_DIR="$CONF" HUB_SESSION="$SESS" HUB_PRINT_CMD=1 bash "$SCRIPT")
[ "$d" = home ] || fail "default: hub-session must build the 'home' window, not the dash: $d"
d=$(env -u FLEET_DASH_WINDOW FLEET_CONF_DIR="$CONF" HUB_SESSION="$SESS" HUB_PRINT_CMD=cwd bash "$SCRIPT")
[ "$d" = "$HOME" ] || fail "default: home must open in \$HOME (a fleet has no main repo, #1941), got: $d"
d=$(env -u FLEET_DASH_WINDOW FLEET_CONF_DIR="$CONF" HUB_SESSION="$SESS" HUB_CWD="$MAIN" HUB_PRINT_CMD=cwd bash "$SCRIPT")
[ "$d" = "$MAIN" ] || fail "HUB_CWD must still pin the hub's cwd, got: $d"
# The retired knobs bring nothing back (issue #4902): the dash and a hub claude.
printf 'FLEET_DASH_WINDOW=1\n' > "$CONF/fleet.settings"
d=$(FLEET_DASH_WINDOW=1 HUB_RESUME_ID=abc FLEET_HUB_CMD=claude FLEET_CONF_DIR="$CONF" HUB_SESSION="$SESS" HUB_PRINT_CMD=1 bash "$SCRIPT")
[ "$d" = home ] || fail "FLEET_DASH_WINDOW=1 / HUB_RESUME_ID / FLEET_HUB_CMD must change nothing, got: $d"
rm -f "$CONF/fleet.settings"

# A real build, on an isolated server (never the live one): fleet-up's throwaway
# first window, then hub-session.sh — `home` at index 1, no `plan`, and a second
# run (the ⌂ fallback) builds nothing more.
REAL_TMUX=$(command -v tmux 2>/dev/null)
if [ -z "$REAL_TMUX" ]; then
  printf 'selftest: tmux missing — the live leg SKIPPED\n' >&2
else
  mkdir -p "$WORK/shim"
  cat > "$WORK/shim/tmux" <<EOF
#!/bin/sh
case "\$1" in -L|-S) shift 2 ;; esac
exec "$REAL_TMUX" -S "$WORK/sock" "\$@"
EOF
  chmod +x "$WORK/shim/tmux"
  trap '"$REAL_TMUX" -S "$WORK/sock" kill-server 2>/dev/null; rm -rf "$WORK"' EXIT
  T() { "$REAL_TMUX" -S "$WORK/sock" "$@"; }
  T -f /dev/null new-session -d -s "$SESS" -n work 'sleep 600' || fail "could not start the isolated tmux server"
  T set-option -g default-shell /bin/sh
  T set-option -g base-index 1
  live() { env -u FLEET_DASH_WINDOW -u TMUX PATH="$WORK/shim:$PATH" FLEET_CONF_DIR="$CONF" HUB_SESSION="$SESS" bash "$SCRIPT"; }
  live || fail "default: hub-session.sh exited non-zero"
  names=$(T list-windows -t "$SESS" -F '#{window_index}:#{window_name}' | tr '\n' ' ')
  case " $names" in *":plan "*) fail "default: a 'plan' window was built: $names" ;; esac
  case " $names" in *" 1:home "*) : ;; *) fail "default: 'home' must sit at index 1: $names" ;; esac
  [ "$(T display-message -p -t "$SESS:" '#{window_name}')" = home ] || fail "default: home must be selected"
  [ -z "$(T list-panes -s -t "$SESS" -F '#{@dash}' | tr -d '\n')" ] || fail "default: no dash pane may exist"
  live || fail "default: a second hub-session.sh exited non-zero"
  [ "$(T list-windows -t "$SESS" -F '#{window_name}' | grep -c '^home$')" = 1 ] \
    || fail "default: a second run must not build a second home: $(T list-windows -t "$SESS" -F '#{window_name}' | tr '\n' ' ')"
fi

printf 'PASS: hub-session builds `home` (no plan window, no dash, no claude by any route)\n'
exit 0
