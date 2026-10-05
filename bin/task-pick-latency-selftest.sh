#!/bin/bash
# task-pick-latency-selftest.sh — ☰ (the ⌂ before issue #1616) on a NARROW client: how long until the task
# list is on screen, and where the time went (issue #1611).
#
# The iPad operator (Termius, 54x50 portrait, no task bar) taps the ⌂ and waits.
# This drives the REAL chain — the shipped conf's MouseDown1Status bind →
# hub-zoom.sh --bar → fleet-sidebar.sh home … bar → fleet-task-pick.sh --popup →
# dash-popup.sh → the picker — on an ISOLATED tmux server, from a replay CLIENT
# the test owns: a 54x50 pty (python's pty module), an SGR mouse press on the
# ⌂'s cell of the status row, and the ms until fzf's prompt reaches that pty —
# the operator's "list visible", with no Termius and no ssh in between. The
# server side of the same press is the hub-visits line's 4th column, written by
# bin/fleet-trace-lib.sh's marks; the gap between the two is the client's.
#
#   A. TRACE   every tap ends on ONE `bar-pick` hub-visits line whose 4th column
#              is `ms=<N> conf:… side:… sync:… pick:… popup:… open:… keys:… rows:…
#              fzf:… close:… done:…` — every stage, `ms=` = the fzf mark, done
#              last; no trace file is left behind; FLEET_HOME_TRACE=0 ⇒ the
#              three columns of before
#   B. NARROW  no list pane is drawn on the 54-column window (fleet-sidebar.sh
#              home skips the python sync it used to run only to be told "no"),
#              and the picker's pre-read files / FIFOs are gone after the tap
#   C. BUDGET  the taps' median ≤ FLEET_TASK_PICK_BUDGET_MS (500; the issue's
#              bar) — JUDGED only on a box under 1 load per core: a loaded runner
#              prints the number and skips the verdict, never fails on it
#   D. LAYERS  hub-zoom.sh's cheap FLEET_DASH_WINDOW read honours the same three
#              layers in the same order as the full load it replaced — the
#              install's fleet.conf < the login's fleet.settings < the fleet's
#              conf, else the environment; quotes and `export` as a source would
#
# fzf absent → a shim that draws the prompt and waits for Esc stands in (the
# chain is the thing under test; the shim only makes the budget optimistic).
# tmux or python3 absent → SKIP (exit 0). Exit 0 = pass.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
ROOT="$BIN/.."
CONF="$ROOT/conf/tmux-attention.conf"
for f in hub-zoom.sh fleet-sidebar.sh fleet-task-pick.sh dash-popup.sh fleet-trace-lib.sh fleet-hub-visits.sh; do
  [ -f "$BIN/$f" ] || { printf 'selftest: %s not found\n' "$BIN/$f" >&2; exit 2; }
done
[ -f "$CONF" ] || { printf 'selftest: %s not found\n' "$CONF" >&2; exit 2; }
REAL_TMUX="$(command -v tmux 2>/dev/null)"
[ -n "$REAL_TMUX" ] || { printf 'selftest: tmux not installed — SKIP\n' >&2; exit 0; }
command -v python3 >/dev/null 2>&1 || { printf 'selftest: python3 not installed — SKIP\n' >&2; exit 0; }
case "$(uname -s)" in Darwin|Linux) ;; *) printf 'selftest: no pty on %s — SKIP\n' "$(uname -s)" >&2; exit 0 ;; esac

TAPS="${FLEET_TASK_PICK_TAPS:-10}"; BUDGET="${FLEET_TASK_PICK_BUDGET_MS:-500}"
case "$TAPS" in ''|*[!0-9]*|0) TAPS=10 ;; esac
case "$BUDGET" in ''|*[!0-9]*|0) BUDGET=500 ;; esac

# A unix socket path is capped at 104 bytes: the socket lives under a SHORT dir,
# everything else under the work dir.
WORK="$(mktemp -d "${TMPDIR:-/tmp}/tpl-selftest.XXXXXX")" || exit 2
SDIR="$(mktemp -d /tmp/tpl.XXXXXX)" || { rm -rf "$WORK"; exit 2; }
SOCK="$SDIR/t"
fails=0
fail() { printf 'FAIL: %s\n' "$*" >&2; fails=$((fails + 1)); }
cleanup() {
  [ -n "${CPID:-}" ] && kill "$CPID" 2>/dev/null
  tmux kill-server 2>/dev/null
  rm -rf "$WORK" "$SDIR"
}
trap cleanup EXIT
trap 'exit 130' INT TERM HUP

# Every tmux call onto the isolated socket, the lib's `tmux -L <label>` included.
mkdir -p "$WORK/bin"
cat > "$WORK/bin/tmux" <<EOF
#!/bin/sh
case "\$1" in -L|-S) shift 2 ;; esac
exec "$REAL_TMUX" -S "$SOCK" "\$@"
EOF
chmod +x "$WORK/bin/tmux"
# No fzf (or TPL_FZF=shim) → the stand-in, shaped like fzf where it matters:
# it DRAWS on the terminal (the picker captures stdout for the pick), reads the
# key from the terminal, and aborts with 130 printing nothing.
if [ "${TPL_FZF:-}" = shim ] || ! command -v fzf >/dev/null 2>&1; then
  cat > "$WORK/bin/fzf" <<'EOF'
#!/bin/sh
cat >/dev/null &
# literal UTF-8 and %s, no \xHH: dash's printf (a Linux runner's sh) has no hex escapes
{ printf '\033[2J\033[H'; printf '%s\n' ' task ▸ ' '[＋ new] [⌂ hub] [✕ close]'; } > /dev/tty
stty -icanon -echo min 1 time 0 < /dev/tty 2>/dev/null   # one key, not one line: Esc alone must end it
dd if=/dev/tty bs=1 count=1 2>/dev/null >/dev/null
exit 130
EOF
  chmod +x "$WORK/bin/fzf"
  FZF_NOTE='(fzf shim)'
else
  FZF_NOTE="(fzf $(fzf --version 2>/dev/null | cut -d' ' -f1))"
fi
export PATH="$WORK/bin:$PATH"
export FLEET_CONF_DIR="$WORK/conf" FLEET_HUB_VISITS_LOGDIR="$WORK/logs" TMPDIR="$WORK"
# A UTF-8 locale for the server, and -u on the client: in the C locale (a CI
# runner with no LANG) tmux draws every non-ASCII cell — the prompt's ▸, the
# ⌂ — as `_`, and the pattern below never arrives.
case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in
  *UTF-8*|*utf8*|*UTF8*) ;;
  *) locale -a > "$WORK/locales" 2>/dev/null   # (not `locale -a | grep -q`: pipefail + grep's early exit = SIGPIPE = no match)
     for loc in C.UTF-8 en_US.UTF-8; do grep -qix "$loc" "$WORK/locales" && { export LC_ALL="$loc"; break; }; done ;;
esac
export FLEET_UI_LANG=en
mkdir -p "$FLEET_CONF_DIR/fleets/t" "$WORK/logs"
printf 'FLEET_SIDEBAR=1\n' > "$FLEET_CONF_DIR/fleets/t/conf"
LOG="$WORK/logs/hub-visits-t.log"

# The fleet: five task windows, the first current, 54x50 — the iPad in portrait.
tmux -f /dev/null new-session -d -s t -n issue-1 -x 54 -y 50 'sleep 600' 2>/dev/null \
  || { printf 'selftest: could not start the isolated tmux server — SKIP\n' >&2; exit 0; }
tmux set -w -t t:issue-1 @issue 1
for w in 2 3 4 5; do tmux new-window -d -t t -n "issue-$w" 'sleep 600'; tmux set -w -t "t:issue-$w" @issue "$w"; done
tmux select-window -t t:issue-1
tmux set -g mouse on \; set -g status on \; set -g status-position bottom \; set -g status-interval 2
tmux set -g status-left "#[range=user|hub]  ⌂  #[norange] t "
# The SHIPPED bind, verbatim but for the install path — and `sh` spelled as the
# production /bin/sh, bash in POSIX mode (hub-zoom-home-selftest.sh's reasoning,
# issue #414): a Linux runner's sh is dash, which the fleet's sh scripts never
# run under.
awk '/^bind -n MouseDown1Status /,/^}$/' "$CONF" | sed "s#~/.claude/fleet#$ROOT#g; s#run-shell \"sh #run-shell \"bash --posix #" > "$WORK/bind.conf"
grep -q 'hub-zoom.sh --bar' "$WORK/bind.conf" || fail "the conf's MouseDown1Status bind no longer runs hub-zoom.sh --bar (the ☰, issue #1616)"
tmux source-file "$WORK/bind.conf" || fail "the conf's MouseDown1Status bind did not load"

# The replay client: a pty of its own, 54x50, that taps the ⌂ and times the
# prompt's arrival. `tap <k> <ms|TIMEOUT>` per tap, `median <ms>` at the end.
cat > "$WORK/client.py" <<'EOF'
import os, pty, sys, time, fcntl, termios, struct, select, subprocess, statistics
tmux, sock, n = sys.argv[1], sys.argv[2], int(sys.argv[3])
cols, rows = 54, 50
pat = 'task ▸'.encode()
pid, fd = pty.fork()
if pid == 0:
    os.environ['TERM'] = 'xterm-256color'
    os.environ.pop('TMUX', None); os.environ.pop('TMUX_PANE', None)
    fcntl.ioctl(0, termios.TIOCSWINSZ, struct.pack('HHHH', rows, cols, 0, 0))
    os.execvp(tmux, [tmux, '-u', '-S', sock, 'attach', '-t', 't'])
buf = bytearray()
def pump(timeout):
    r, _, _ = select.select([fd], [], [], timeout)
    if r:
        try: buf.extend(os.read(fd, 65536))
        except OSError: pass
def opt(name):
    return subprocess.run([tmux, '-S', sock, 'show', '-gqv', name], capture_output=True, text=True).stdout.strip()
t0 = time.monotonic()
while time.monotonic() - t0 < 15:
    pump(0.05)
    if subprocess.run([tmux, '-S', sock, 'list-clients'], capture_output=True, text=True).stdout.strip(): break
else:
    print('noclient'); sys.exit(0)
time.sleep(0.5); pump(0.2)
res = []
for k in range(n):
    start = len(buf)
    os.write(fd, b'\x1b[<0;3;%dM\x1b[<0;3;%dm' % (rows, rows))
    t1 = time.monotonic(); ms = None
    while time.monotonic() - t1 < 10:
        pump(0.005)
        if buf.find(pat, max(0, start - len(pat))) >= 0:
            ms = int((time.monotonic() - t1) * 1000); break
    res.append(ms); print('tap %d %s' % (k + 1, 'TIMEOUT' if ms is None else ms), flush=True)
    if ms is None and k == 0:   # what DID the client get? (a CI runner cannot be watched)
        b = bytes(buf[start:]); i = b.find(b'task'); j = b.find(b'\x1b[3;')
        print('diag %d bytes since the tap; task at %d: %r; row 3 at %d: %r; tail %r' % (
            len(b), i, b[max(0, i - 200):i + 200] if i >= 0 else b'', j, b[j:j + 700] if j >= 0 else b'', b[-300:]), flush=True)
    os.write(fd, b'\x1b')
    t2 = time.monotonic()
    while time.monotonic() - t2 < 10:
        pump(0.05)
        if opt('@popup_open') in ('', '0'): break
    time.sleep(0.4); pump(0.2)
ok = [m for m in res if m is not None]
print('median %s' % (int(statistics.median(ok)) if ok else 'none'), flush=True)
os.kill(pid, 15)
EOF
env -u TMUX -u TMUX_PANE python3 "$WORK/client.py" "$REAL_TMUX" "$SOCK" "$TAPS" > "$WORK/taps" 2>"$WORK/client.err"
grep -q '^noclient' "$WORK/taps" && { printf 'selftest: the pty client never attached — SKIP\n' >&2; cat "$WORK/client.err" >&2; exit 0; }
median=$(awk '$1=="median"{print $2}' "$WORK/taps")
printf 'tmux: %s\n' "$(tmux -V 2>/dev/null)"
grep '^diag' "$WORK/taps" | cut -c1-1600
printf 'taps: %s %s locale=%s\n' "$(awk '$1=="tap"{printf "%s ", $3}' "$WORK/taps")" "$FZF_NOTE" "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}"

# --- A. the trace column ------------------------------------------------------
n=$(grep -c "	bar-pick" "$LOG" 2>/dev/null || echo 0)
[ "$n" = "$TAPS" ] || fail "A: expected $TAPS bar-pick lines, got $n: $(cat "$LOG" 2>/dev/null)"
while IFS='	' read -r ts from cause extra; do
  [ "$cause" = bar-pick ] || continue
  case "$extra" in ms=[0-9]*) ;; *) fail "A: no ms= column on: $ts $from $cause [$extra]"; continue ;; esac
  for m in conf side sync pick popup open keys rows fzf close 'done'; do
    case " $extra " in *" $m:"[0-9]*) ;; *) fail "A: mark '$m' missing: $extra" ;; esac
  done
  fz=$(printf '%s\n' "$extra" | tr ' ' '\n' | awk -F: '$1=="fzf"{print $2}')
  [ "${extra#ms=}" != "$extra" ] && [ "${extra#ms=}" = "$fz ${extra#*ms=$fz }" ] || fail "A: ms= is not the fzf mark: $extra"
  [ "$(printf '%s\n' "$extra" | awk '{print $NF}' | cut -d: -f1)" = 'done' ] || fail "A: done is not last: $extra"
  dn=$(printf '%s\n' "$extra" | tr ' ' '\n' | awk -F: '$1=="done"{print $2}')
  [ "${dn:-0}" -ge "${fz:-0}" ] || fail "A: done ($dn) before fzf ($fz): $extra"
done < "$LOG"
left=$(ls "$WORK/.claude-dash"/home-trace.* 2>/dev/null)
[ -z "$left" ] || fail "A: trace file(s) left behind: $left"
# the knob off: three columns, as before
tmux set-environment -g FLEET_HOME_TRACE 0
before=$(wc -l < "$LOG" | tr -d ' ')
env -u TMUX -u TMUX_PANE FLEET_HOME_TRACE=0 python3 "$WORK/client.py" "$REAL_TMUX" "$SOCK" 1 > "$WORK/taps0" 2>/dev/null
tmux set-environment -gu FLEET_HOME_TRACE
after=$(wc -l < "$LOG" | tr -d ' ')
[ "$after" -eq $((before + 1)) ] || fail "A: FLEET_HOME_TRACE=0 tap did not log one line ($before → $after)"
last=$(tail -n 1 "$LOG")
[ "$(printf '%s\n' "$last" | awk -F'\t' '{print NF}')" = 3 ] || fail "A: FLEET_HOME_TRACE=0 still wrote a 4th column: $last"
[ -z "$(ls "$WORK/.claude-dash"/home-trace.* 2>/dev/null)" ] || fail "A: FLEET_HOME_TRACE=0 left a trace file"

# --- B. narrow: no list drawn, nothing left of the pre-reads ------------------
drawn=$(tmux list-panes -t t:issue-1 -F '#{@sidebar}' 2>/dev/null | grep -c '^1$')
[ "$drawn" = 0 ] || fail "B: a list pane was drawn on the 54-column window"
[ "$(tmux display-message -p -t t:issue-1 '#{window_panes}')" = 1 ] || fail "B: the task window gained a pane"
pre=$(ls "$WORK"/fleet-task-pick.* 2>/dev/null)
[ -z "$pre" ] || fail "B: pre-read files / FIFOs left behind: $pre"
kc=0; for f in "$WORK/.claude-dash"/task-pick-keys.*; do [ -s "$f" ] && kc=1; done
[ "$kc" = 1 ] || fail "B: the keymap cache was not written"

# --- C. the budget --------------------------------------------------------------
cores=$(sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo 1)
load=$(sysctl -n vm.loadavg 2>/dev/null | awk '{print $2}')
[ -n "$load" ] || load=$(cut -d' ' -f1 /proc/loadavg 2>/dev/null || echo 0)
idle=$(awk -v l="$load" -v c="$cores" 'BEGIN{print (l <= c) ? 1 : 0}')
case "$median" in
  none) fail "C: no tap reached the prompt: $(cat "$WORK/taps")" ;;
  *)
    if [ "$idle" = 1 ]; then
      [ "$median" -le "$BUDGET" ] || fail "C: median $median ms > budget $BUDGET ms on an idle box (load $load / $cores cores): $(cat "$WORK/taps")"
      printf 'budget: median %s ms ≤ %s ms over %s taps %s (load %s / %s cores)\n' "$median" "$BUDGET" "$TAPS" "$FZF_NOTE" "$load" "$cores"
    else
      printf 'budget: median %s ms over %s taps %s — NOT judged, load %s on %s cores\n' "$median" "$TAPS" "$FZF_NOTE" "$load" "$cores"
    fi ;;
esac
printf 'trace: %s\n' "$(tail -n 2 "$LOG" | head -n 1 | cut -f4)"

# --- D. FLEET_DASH_WINDOW's three layers -------------------------------------
FN=$(sed -n '/^dash_window() {/,/^}/p' "$BIN/hub-zoom.sh")
[ -n "$FN" ] || fail "D: dash_window() not found in hub-zoom.sh"
D="$WORK/d"; mkdir -p "$D/bin" "$D/conf/fleets/t"
dw() {   # <fleet.conf> <fleet.settings> <fleet conf> [env] → 0 iff the hub window is on
  printf '%s' "$1" > "$D/fleet.conf"; printf '%s' "$2" > "$D/conf/fleet.settings"; printf '%s' "$3" > "$D/conf/fleets/t/conf"
  # shellcheck disable=SC2034  # BIN / SESS are dash_window's globals, read by the eval'd body
  ( BIN="$D/bin"; SESS=t; FLEET_CONF_DIR="$D/conf"
    if [ -n "${4:-}" ]; then export FLEET_DASH_WINDOW="$4"; else unset FLEET_DASH_WINDOW; fi
    eval "$FN"; dash_window )
}
dw '' '' ''                              && fail "D: no layer set, no env → hub window on"
dw '' '' '' 1                            || fail "D: env FLEET_DASH_WINDOW=1 alone → off"
dw 'FLEET_DASH_WINDOW=1' '' ''           || fail "D: fleet.conf=1 → off"
dw 'FLEET_DASH_WINDOW=1' 'FLEET_DASH_WINDOW=0' '' && fail "D: fleet.settings=0 did not beat fleet.conf=1"
dw 'FLEET_DASH_WINDOW=0' 'FLEET_DASH_WINDOW=0' 'FLEET_DASH_WINDOW=1' || fail "D: the fleet conf=1 did not beat fleet.settings=0"
dw '' '' 'FLEET_DASH_WINDOW=0' 1         && fail "D: a conf 0 did not beat env 1"
dw '' '' '  export FLEET_DASH_WINDOW="1"  # on' || fail "D: export + quotes + comment not read as 1"
dw '' '' "FLEET_DASH_WINDOW='1'"         || fail "D: single quotes not read as 1"
dw '' '' 'FLEET_DASH_WINDOWS=1'          && fail "D: FLEET_DASH_WINDOWS (another key) read as the knob"
dw '' '' '# FLEET_DASH_WINDOW=1'         && fail "D: a commented line read as the knob"

[ "$fails" -eq 0 ] || { printf 'selftest FAILED: %d assertion(s)\n' "$fails" >&2; exit 1; }
printf 'selftest PASS: ⌂ on a 54x50 client opens the task list (median %s ms over %s taps %s) with the trace column on every bar-pick line, no list pane drawn, nothing left behind, FLEET_DASH_WINDOW read across its three layers (#1611)\n' "$median" "$TAPS" "$FZF_NOTE"
