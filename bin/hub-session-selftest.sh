#!/bin/bash
# hub-session-selftest.sh — a fleet's resting window is `home`, never a dash and
# never a Claude.
#
# hub-session.sh builds `home`, a plain shell the task list draws beside, at
# index 1 (issue #1533); the old `plan` dash hub went with
# the dash (issue #4902), and its legs with it. The print seam (HUB_PRINT_CMD)
# and a real isolated tmux pin:
#   • it opens `home` in $HOME (a fleet has no main repo, #1941), HUB_CWD pins it;
#   • HUB_RESUME_ID or FLEET_HUB_CMD bring no claude back — they are read by
#     nothing;
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
d=$(env FLEET_CONF_DIR="$CONF" HUB_SESSION="$SESS" HUB_PRINT_CMD=1 bash "$SCRIPT")
[ "$d" = home ] || st_fail "default: hub-session must build the 'home' window, not the dash: $d"
d=$(env FLEET_CONF_DIR="$CONF" HUB_SESSION="$SESS" HUB_PRINT_CMD=cwd bash "$SCRIPT")
[ "$d" = "$HOME" ] || st_fail "default: home must open in \$HOME (a fleet has no main repo, #1941), got: $d"
d=$(env FLEET_CONF_DIR="$CONF" HUB_SESSION="$SESS" HUB_CWD="$MAIN" HUB_PRINT_CMD=cwd bash "$SCRIPT")
[ "$d" = "$MAIN" ] || st_fail "HUB_CWD must still pin the hub's cwd, got: $d"
# The retired knobs bring nothing back (issue #4902): a hub claude.
d=$(HUB_RESUME_ID=abc FLEET_HUB_CMD=claude FLEET_CONF_DIR="$CONF" HUB_SESSION="$SESS" HUB_PRINT_CMD=1 bash "$SCRIPT")
[ "$d" = home ] || st_fail "HUB_RESUME_ID / FLEET_HUB_CMD must change nothing, got: $d"

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
  T -f /dev/null new-session -d -s "$SESS" -n work 'sleep 600' || st_fail "could not start the isolated tmux server"
  T set-option -g default-shell /bin/sh
  T set-option -g base-index 1
  live() { env -u TMUX PATH="$WORK/shim:$PATH" FLEET_CONF_DIR="$CONF" HUB_SESSION="$SESS" bash "$SCRIPT"; }
  live || st_fail "default: hub-session.sh exited non-zero"
  names=$(T list-windows -t "$SESS" -F '#{window_index}:#{window_name}' | tr '\n' ' ')
  case " $names" in *":plan "*) st_fail "default: a 'plan' window was built: $names" ;; esac
  case " $names" in *" 1:home "*) : ;; *) st_fail "default: 'home' must sit at index 1: $names" ;; esac
  [ "$(T display-message -p -t "$SESS:" '#{window_name}')" = home ] || st_fail "default: home must be selected"
  [ -z "$(T list-panes -s -t "$SESS" -F '#{@dash}' | tr -d '\n')" ] || st_fail "default: no dash pane may exist"
  live || st_fail "default: a second hub-session.sh exited non-zero"
  [ "$(T list-windows -t "$SESS" -F '#{window_name}' | grep -c '^home$')" = 1 ] \
    || st_fail "default: a second run must not build a second home: $(T list-windows -t "$SESS" -F '#{window_name}' | tr '\n' ' ')"
fi

printf 'PASS: hub-session builds `home` (no plan window, no dash, no claude by any route)\n'
exit 0
