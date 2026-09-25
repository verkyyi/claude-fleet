#!/bin/bash
# sidebar-sleep-selftest.sh — the session list shows sleep and can wake (issue #1051).
#
#   A. fleet-sleep.py's phase() stamps @sleep_since on entering `sleeping`, keeps
#      it across a re-entry (restore), and clears it on any other phase.
#   B. tmux-dashboard-rows.sh renders a sleeping row with a stamped 42-minute-old
#      @sleep_since as `z 42m` — in the sidebar's glyph field AND the dash's act
#      cell — and h/d past an hour/day; an unstamped sleeper keeps the bare `z`.
#   C. fleet-sidebar-menu.sh --print lists Wake (w) ONLY on a sleeping row, wired
#      to `fleet-sleep.sh wake <sess> <@id>`; the k toggle reads `保持唤醒` →
#      keep-awake, or `允许休眠` → allow-sleep once @sleep_keep_awake=1.
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

# ── A. phase() stamps (no tmux: a stub Worker records its set-options) ─────────
out=$(python3 - "$BIN/fleet-sleep.py" <<'PY' 2>&1
import importlib.util, sys, tempfile, time, json
from pathlib import Path
spec = importlib.util.spec_from_file_location('fs', sys.argv[1])
fs = importlib.util.module_from_spec(spec); spec.loader.exec_module(fs)
class W: pass
w = W(); w.opts = {}
w.stamp = lambda n, v: w.opts.__setitem__(n, str(v))
path = Path(tempfile.mkdtemp()) / 'r.json'
data = {'state': 'preparing'}
fs.Worker.phase(w, path, data, 'sleeping')
since = w.opts['@sleep_since']
assert since.isdigit() and abs(int(since) - time.time()) < 5, w.opts
assert w.opts['@worker_lifecycle'] == 'sleeping'
data['since'] = 1000                     # an older nap re-entering sleeping keeps its start
fs.Worker.phase(w, path, data, 'sleeping')
assert w.opts['@sleep_since'] == '1000', w.opts
assert json.loads(path.read_text())['since'] == 1000
fs.Worker.phase(w, path, data, 'waking')
assert w.opts['@sleep_since'] == '' and 'since' not in data, w.opts
fs.Worker.phase(w, path, data, 'awake')
assert w.opts['@sleep_since'] == '' and w.opts['@worker_lifecycle'] == '', w.opts
print('ok')
PY
)
eq "phase(): @sleep_since stamped, kept on re-entry, cleared otherwise" ok "$out"

REAL_TMUX="$(command -v tmux 2>/dev/null)"
[ -n "$REAL_TMUX" ] || { printf 'sidebar-sleep-selftest: tmux not installed — SKIPPED (A passed)\n'; exit 0; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/sidebar-sleep-selftest.XXXXXX")" || exit 2
export FLEET_SKIP_GLOBAL_CONF=1
export FLEET_CONF_DIR="$WORK/conf"
# The row menu is localized since #1188 (bin/fleet-ui-lang.sh: FLEET_UI_LANG, else
# the login locale) — pin the Chinese the items below assert.
export FLEET_UI_LANG=zh
S=fleetZ
mkdir -p "$WORK/conf/fleets/$S" "$WORK/bin"
: > "$WORK/conf/fleets/$S/conf"
# The socket's basename must be the fleet's own label: fleet-sidebar.sh refuses a
# session served from any other socket (the one-fleet-one-server rail, #159).
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

US=$(printf '\037')
tmux new-session -d -s "$S" -x 220 -y 50 -c "$WORK" 'sleep 300' || fail "could not start the isolated tmux server"
probe=$(tmux list-windows -t "$S" -F "a${US}b" 2>/dev/null | od -An -tx1 | tr -d ' \n')
case "$probe" in *611f62*) : ;; *) printf 'sidebar-sleep-selftest: tmux escapes US in -F — SKIPPED (A passed)\n'; exit 0 ;; esac
export TMUX="$SOCK,1,0"

mk_win() { # <name> <issue> → window id
  local wid
  wid=$(tmux new-window -d -P -F '#{window_id}' -t "$S:" -n "$1" -c "$WORK" 'sleep 300')
  tmux set-window-option -t "$wid" @issue "$2"
  printf '%s' "$wid"
}
now=$(date +%s)
W_m=$(mk_win napm 201); tmux set-window-option -t "$W_m" @worker_lifecycle sleeping
tmux set-window-option -t "$W_m" @sleep_since $(( now - 42 * 60 - 5 ))
W_h=$(mk_win naph 202); tmux set-window-option -t "$W_h" @worker_lifecycle sleeping
tmux set-window-option -t "$W_h" @sleep_since $(( now - 3 * 3600 - 5 ))
W_d=$(mk_win napd 203); tmux set-window-option -t "$W_d" @worker_lifecycle sleeping
tmux set-window-option -t "$W_d" @sleep_since $(( now - 2 * 86400 - 5 ))
W_u=$(mk_win napu 204); tmux set-window-option -t "$W_u" @worker_lifecycle sleeping
W_a=$(mk_win busy 205); tmux set-window-option -t "$W_a" @claude_state working

# ── B. rows ────────────────────────────────────────────────────────────────────
strip() { LC_ALL=C sed -e $'s/\x1b\\[[0-9;]*m//g'; }
side=$(FLEET_SESSION=$S bash "$BIN/tmux-dashboard-rows.sh" --sidebar 2>/dev/null | strip)
glyph_of() { printf '%s\n' "$side" | awk -F"$US" -v w="$1" '$1 == w { print $3; exit }'; }
eq "sidebar: 42-minute sleeper reads z 42m" "z 42m" "$(glyph_of "$W_m")"
eq "sidebar: 3-hour sleeper reads z 3h"     "z 3h"  "$(glyph_of "$W_h")"
eq "sidebar: 2-day sleeper reads z 2d"      "z 2d"  "$(glyph_of "$W_d")"
eq "sidebar: an unstamped sleeper keeps the bare z" "z" "$(glyph_of "$W_u")"
not_contains "sidebar: an awake row carries no sleep age" "$(glyph_of "$W_a")" "z "
dash=$(FLEET_SESSION=$S FZF_COLUMNS=180 bash "$BIN/tmux-dashboard-rows.sh" 2>/dev/null | strip)
contains "dash: the sleeper's act cell reads z 42m" "$(printf '%s\n' "$dash" | grep ' napm ')" " z 42m "

# ── C. menu ────────────────────────────────────────────────────────────────────
menu() { bash "$BIN/fleet-sidebar.sh" menu "$S" "$1" --print 2>/dev/null; }
item() { printf '%s\n' "$1" | awk -F'\t' -v k="$2" '$1 == k { print $2 "\t" $3; exit }'; }
m=$(menu "$W_m")
wk=$(item "$m" w)
eq "menu: a sleeping row lists Wake" "唤醒" "${wk%%	*}"
contains "menu: Wake runs fleet-sleep.sh wake on this row" "$wk" "fleet-sleep.sh'\\'' wake '\\''$S'\\'' $W_m "
contains "menu: Wake runs detached" "$wk" "run-shell -b"
kk=$(item "$m" k)
eq "menu: the toggle offers keep-awake by default" "保持唤醒" "${kk%%	*}"
contains "menu: keep-awake runs the controller's own action" "$kk" "keep-awake '\\''$S'\\'' $W_m "
m=$(menu "$W_a")
[ -n "$m" ] || fail "menu --print printed nothing for an awake row"
eq "menu: an awake row has no Wake" "" "$(item "$m" w)"
tmux set-window-option -t "$W_a" @sleep_keep_awake 1
kk=$(item "$(menu "$W_a")" k)
eq "menu: a kept-awake row offers Allow sleep" "允许休眠" "${kk%%	*}"
contains "menu: allow-sleep runs the controller's own action" "$kk" "allow-sleep '\\''$S'\\'' $W_a "

printf 'sidebar-sleep-selftest: all %d checks passed\n' "$CHECKS"
