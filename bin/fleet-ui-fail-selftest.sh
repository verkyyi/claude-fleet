#!/bin/bash
# fleet-ui-fail-selftest.sh — your own action says nothing when it works, one line
# when it does not, and the sidebar's how-to flashes once a day (issue #1618,
# EPIC #1615 C3). Drives fleet-ui-lang.sh's two new exits on an ISOLATED tmux
# server with a 54x50 pty client attached (the iPad in portrait), and reads the
# server's message log (`show-messages`) before and after:
#
#   A. FAIL     fleet_ui_fail REASON NEXT → EXACTLY one new message line, carrying
#               the reason and the next step, in the palette's red; FLEET_UI_QUIET=1
#               → none; FLEET_UI_SOCK aims it at a named socket.
#   B. HINT     `fleet-ui-lang.sh hint <client> KEY` twice the same day → ONE line;
#               a stamp from an older day is swept and the hint shows again; an
#               unwritable stamp dir fails OPEN (it shows).
#   C. 54 COLS  every fixed failure line (reason — next) fits 54 display columns,
#               zh (wide = 2) and en.
#   D. LINT     the spawn / reap / file / sidebar scripts draw no success toast
#               ("✓", "spawned", "reaped", "closed scratch", "filed", the old
#               "checking #N…" / "spawning #N…" acks), and the sidebar's key help
#               reaches the screen only through the once-a-day gate.
#
# The real spawn / reap paths are pinned by their own selftests (success → no
# display-message, refusal → exactly one): dash-issue-async-spawn-selftest.sh,
# dash-raw-session-selftest.sh, dash-reap-selftest.sh,
# dash-issue-new-spawn-selftest.sh. tmux or python3 absent → A/B SKIP.
set -uo pipefail
# The list is drawn on a fleet socket here: on a real node it is the client's
# only (issue #1713), so the drawer's tests take the seam fleet-sidebar.sh offers.
export FLEET_SIDEBAR_NODE=1
BIN="$(cd "$(dirname "$0")" && pwd)"
ROOT="$BIN/.."
LANGSH="$BIN/fleet-ui-lang.sh"
[ -f "$LANGSH" ] || { printf 'selftest: %s not found\n' "$LANGSH" >&2; exit 2; }
pass=0; fails=0
ok()   { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
fail() { fails=$((fails + 1)); printf 'FAIL %s\n' "$1" >&2; [ -n "${2:-}" ] && printf '%s\n' "$2" >&2; return 0; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/uifail-selftest.XXXXXX")" || exit 2
SDIR="$(mktemp -d /tmp/uif.XXXXXX)" || { rm -rf "$WORK"; exit 2; }   # a socket path is capped at 104 bytes
SOCK="$SDIR/t"
REAL_TMUX="$(command -v tmux 2>/dev/null || :)"
cleanup() {
  [ -n "${CPID:-}" ] && kill "$CPID" 2>/dev/null
  [ -n "$REAL_TMUX" ] && "$REAL_TMUX" -S "$SOCK" kill-server 2>/dev/null
  rm -rf "$WORK" "$SDIR"
}
trap cleanup EXIT
trap 'exit 130' INT TERM HUP

# --- C. 54 columns ---------------------------------------------------------------
width() { python3 -c 'import sys,unicodedata as u; s=sys.argv[1]; print(sum(2 if u.east_asian_width(c) in "WF" else 1 for c in s))' "$1"; }
if command -v python3 >/dev/null 2>&1; then
  for lang in zh en; do
    for pair in 'sidebar_narrow_why sidebar_narrow_next' 'sidebar_save_failed sidebar_save_next' \
                'ui_already_open_fmt:1618 ui_already_open_next'; do
      set -- $pair; k1=${1%%:*}; a1=''; case "$1" in *:*) a1=${1#*:} ;; esac
      line=$(FLEET_UI_LANG=$lang sh "$LANGSH" t ui_fail_next_fmt \
        "$(FLEET_UI_LANG=$lang sh "$LANGSH" t "$k1" $a1)" "$(FLEET_UI_LANG=$lang sh "$LANGSH" t "$2")")
      w=$(width "$line")
      [ "$w" -le 54 ] || fail "C $lang '$line' is $w columns — a failure line must fit the 54-column iPad"
    done
  done
  ok "C every fixed failure line fits 54 columns (zh + en)"
fi

# --- D. lint ---------------------------------------------------------------------
SCRIPTS="dash-issue-session.sh dash-raw-session.sh dash-reap.sh dash-issue-new.sh dash-new-session.sh fleet-sidebar.sh hub-zoom.sh"
hits=''
for f in $SCRIPTS; do
  h=$(grep -nE 'display-message[^|]*(✓|spawned|reaped|closed scratch|filed|checking #|spawning #)' "$BIN/$f" \
        | grep -v ' -p ' | grep -Ev ':[0-9]+:[[:space:]]*#' | sed "s|^|$f:|")
  [ -n "$h" ] && hits="$hits$h"$'\n'
done
[ -z "$hits" ] || fail "D a success toast is back — a working spawn / reap says nothing (issue #1618)" "$hits"
for f in $SCRIPTS; do
  grep -q 'fleet-ui-lang.sh"' "$BIN/$f" || grep -q 'fleet_ui_fail' "$BIN/$f" \
    || fail "D $f no longer reaches fleet_ui_fail — its failures need the one exit"
done
# The sidebar's how-to keys never reach a display-message without the once-a-day gate.
raw=$(grep -nE 'toast_(sidebar_focus|sidebar_home|shell_sidebar)' "$BIN"/*.sh "$ROOT"/conf/*.conf \
        | grep -v -- '-selftest\.sh:' | grep -v '/fleet-ui-lang\.sh:' \
        | grep -Ev 'fleet_ui_hint_once|fleet-ui-lang\.sh"? hint ' | grep -Ev ':[0-9]+:[[:space:]]*#')
# fleet-sidebar.sh's display line sits right under its gate: allow exactly that shape
raw=$(printf '%s\n' "$raw" | grep -v 'fleet-sidebar\.sh:.*tmux display-message .*fleet_ui_t toast_sidebar_focus' | grep . || :)
[ -z "$raw" ] || fail "D a sidebar how-to toast bypasses the once-a-day gate" "$raw"
grep -B1 'fleet_ui_t toast_sidebar_focus' "$BIN/fleet-sidebar.sh" | grep -q 'fleet_ui_hint_once toast_sidebar_focus' \
  || fail "D fleet-sidebar.sh's focus help must sit behind fleet_ui_hint_once"
[ "$fails" = 0 ] && ok "D no success toast in the spawn / reap / file / sidebar scripts; how-to help is once a day"

# --- A / B on a live isolated server -------------------------------------------------
if [ -z "$REAL_TMUX" ] || ! command -v python3 >/dev/null 2>&1; then
  printf 'selftest: tmux or python3 missing — A/B SKIP\n' >&2
else
  # Every tmux call onto the isolated socket, a `tmux -L <label>` included.
  mkdir -p "$WORK/bin"
  cat > "$WORK/bin/tmux" <<EOF
#!/bin/sh
case "\$1" in -L) printf '%s\n' "\$2" >> "$WORK/labels"; shift 2 ;; -S) shift 2 ;; esac
exec "$REAL_TMUX" -S "$SOCK" "\$@"
EOF
  chmod +x "$WORK/bin/tmux"
  export PATH="$WORK/bin:$PATH" TMPDIR="$WORK" FLEET_UI_LANG=en
  unset FLEET_C TMUX TMUX_PANE
  case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in
    *UTF-8*|*utf8*|*UTF8*) ;;
    *) locale -a > "$WORK/locales" 2>/dev/null
       for loc in C.UTF-8 en_US.UTF-8; do grep -qix "$loc" "$WORK/locales" && { export LC_ALL="$loc"; break; }; done ;;
  esac
  if ! tmux -f /dev/null new-session -d -s t -x 54 -y 50 'sleep 600' 2>/dev/null; then
    printf 'selftest: could not start the isolated tmux server — A/B SKIP\n' >&2
  else
    tmux set -g message-limit 200
    # a 54x50 client on a pty of its own; it holds on until killed
    cat > "$WORK/client.py" <<'EOF'
import os, pty, sys, time, fcntl, termios, struct, select
tmux, sock = sys.argv[1], sys.argv[2]
pid, fd = pty.fork()
if pid == 0:
    os.environ['TERM'] = 'xterm-256color'
    fcntl.ioctl(0, termios.TIOCSWINSZ, struct.pack('HHHH', 50, 54, 0, 0))
    os.execvp(tmux, [tmux, '-u', '-S', sock, 'attach', '-t', 't'])
end = time.time() + 120
while time.time() < end:
    r, _, _ = select.select([fd], [], [], 0.2)
    if r:
        try: os.read(fd, 65536)
        except OSError: break
EOF
    env -u TMUX -u TMUX_PANE python3 "$WORK/client.py" "$REAL_TMUX" "$SOCK" >/dev/null 2>&1 &
    CPID=$!
    i=0; while [ "$i" -lt 100 ] && [ -z "$(tmux list-clients 2>/dev/null)" ]; do sleep 0.1; i=$((i + 1)); done
    CLIENT=$(tmux list-clients -F '#{client_name}' 2>/dev/null | head -n1)
    if [ -z "$CLIENT" ]; then
      printf 'selftest: the pty client never attached — A/B SKIP\n' >&2
    else
      msgs() { tmux show-messages 2>/dev/null | grep -c ' message: ' || :; }
      lastmsg() { tmux show-messages 2>/dev/null | grep " message: " | head -n1; }
      # shellcheck disable=SC1090
      . "$LANGSH"
      PAL=$(sed -n "s/^%hidden PAL_RED='\(#[0-9A-Fa-f]*\)'.*/\1/p" "$ROOT/conf/fleet-palette.conf")

      # A. one failure = one line, reason + next step, the palette's red
      n0=$(msgs)
      FLEET_UI_CLIENT=$CLIENT fleet_ui_fail 'at capacity (8/8)' 'close a session first'
      n1=$(msgs)
      [ "$((n1 - n0))" = 1 ] || fail "A a failure must add EXACTLY one message line (got $((n1 - n0)))" "$(tmux show-messages)"
      lastmsg | grep -qF '✗ at capacity (8/8) — close a session first' || fail "A the line must carry the reason and the next step" "$(lastmsg)"
      lastmsg | grep -qF "fg=$PAL" || fail "A the line's red is the palette's PAL_RED ($PAL)" "$(lastmsg)"
      FLEET_UI_QUIET=1 fleet_ui_fail 'muted'
      [ "$(msgs)" = "$n1" ] || fail "A FLEET_UI_QUIET=1 must draw nothing"
      : > "$WORK/labels"
      FLEET_UI_SOCK=myfleet fleet_ui_fail 'aimed'
      grep -qx myfleet "$WORK/labels" || fail "A FLEET_UI_SOCK must aim the line at tmux -L <label>"
      [ "$fails" = 0 ] && ok "A fleet_ui_fail: one line, reason — next, palette red; QUIET draws none; SOCK aims it"

      # B. the sidebar how-to: once a day per login
      n0=$(msgs)
      sh "$LANGSH" hint "$CLIENT" toast_sidebar_focus
      sh "$LANGSH" hint "$CLIENT" toast_sidebar_focus
      n1=$(msgs)
      [ "$((n1 - n0))" = 1 ] || fail "B the same hint twice in a day must show ONCE (got $((n1 - n0)))" "$(tmux show-messages)"
      lastmsg | grep -qF 'Tasks:' || fail "B the hint shown must be the key's text" "$(tmux show-messages)"
      stamp="$WORK/.claude-dash/global/hint.toast_sidebar_focus.$(date +%Y%m%d)"
      [ -e "$stamp" ] || fail "B the stamp is \$FLEET_C/global/hint.<key>.<date>" "$(ls -R "$WORK/.claude-dash" 2>&1)"
      # a new day: yesterday's stamp is swept, the hint shows again
      mv "$stamp" "$WORK/.claude-dash/global/hint.toast_sidebar_focus.20000101"
      sh "$LANGSH" hint "$CLIENT" toast_sidebar_focus
      [ "$(msgs)" = "$((n1 + 1))" ] || fail "B a new day must show the hint again"
      [ -e "$WORK/.claude-dash/global/hint.toast_sidebar_focus.20000101" ] && fail "B an older day's stamp must be swept"
      # another key is its own budget
      sh "$LANGSH" hint "$CLIENT" toast_sidebar_home
      [ "$(msgs)" = "$((n1 + 2))" ] || fail "B each key has its own once-a-day budget"
      # an unwritable stamp dir fails OPEN — the help shows, never silent forever
      : > "$WORK/no"   # a FILE where the stamp dir's parent should be
      n2=$(msgs)
      FLEET_C="$WORK/no/sub" sh "$LANGSH" hint "$CLIENT" toast_shell_sidebar
      FLEET_C="$WORK/no/sub" sh "$LANGSH" hint "$CLIENT" toast_shell_sidebar
      [ "$(msgs)" = "$((n2 + 2))" ] || fail "B an unwritable stamp must fail OPEN (shown both times)"
      [ "$fails" = 0 ] && ok "B the sidebar how-to shows once a day per key; a new day shows it again; no stamp fails open"
    fi
  fi
fi

[ "$fails" = 0 ] || { printf 'selftest FAIL: %s failure(s)\n' "$fails" >&2; exit 1; }
printf 'selftest PASS: %s legs — a failure is one line with the reason and next step, a success none, the sidebar how-to once a day (#1618)\n' "$pass"
