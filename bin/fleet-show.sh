#!/bin/bash
# fleet-show.sh <file>... [--inline] [--client <tty>] — show a file to the operator
# on THEIR terminal (the iTerm2 they SSH in from), not on this machine (issue #1367).
#
# An agent that wants the operator to look at an image / PDF / QR code used to run
# `open <file>` — which opens it on the Mac mini's own screen, where nobody is
# sitting. iTerm2 has a private escape for exactly this, and it rides the SSH
# connection that is already there (no port, no scp, no tailnet):
#
#   OSC 1337 ; MultipartFile=name=<b64>;size=<n>;inline=0|1 BEL
#   OSC 1337 ; FilePart=<b64 chunk> BEL            (repeated)
#   OSC 1337 ; FileEnd BEL
#
#   inline=0  → iTerm2 DOWNLOADS it to the client's ~/Downloads — after the
#               operator accepts its download prompt (3.6.10 asks every time). The DEFAULT: Claude Code / Codex
#               repaint their TUI constantly, and an inline image is gone on the
#               next frame.
#   inline=1  → drawn in the terminal (what `imgcat` does). `--inline`.
#
# WHERE it is written — and why through `tmux lock-client`. The Bash tool captures
# an agent's stdout, so the escapes must go to the tmux CLIENT's tty
# (`#{client_tty}`). Writing that tty directly is NOT safe: tmux keeps painting it
# (the TUI spinner) and a tty write(2) is not atomic — the kernel copies it in
# chunks and yields when the output queue fills, so a tmux frame lands INSIDE a
# FilePart and iTerm2 drops the file ("aborted for exceeding its declared size").
# Measured on a local pty with a busy second writer: 3 MB in 768-byte parts had
# 509 of 5209 parts corrupted; 128-byte parts + tcdrain still 1. Live, anything
# past ~300 KB failed while the operator watched the pane.
#   So tmux is told to step aside: the session's `lock-command` is pointed at
# bin/fleet-show-send.py for one `lock-client`. The CLIENT process (on this
# machine, attached to the operator's tty) leaves tmux mode, runs it on its own
# tty as the ONLY writer, and tmux redraws when it exits — a sub-second flash for
# a few MB. The previous lock-command is restored right after the lock is issued
# (the server hands the string over at lock time). One send per session at a time.
#
# WHICH client: the one the operator is USING — the most recent `#{client_activity}`
# of this pane's session. Its `#{client_termtype}` (tmux's XTVERSION read of the
# real terminal, e.g. `iTerm2 3.6.10`) must match FLEET_SHOW_TERM_RE, else it
# degrades (issue #1371): the old rule — newest client that IS iTerm2 — sent the
# file to a stale iTerm2 still attached at home while the operator read the fleet
# from a phone over SSH. An empty termtype (tmux < 3.4, or a terminal that never
# answered XTVERSION) degrades too. `--client <tty>` names one outright and skips
# the match.
#
# `--inline` (issue #1371) clears the screen and lays it out: a title row
# (name · size · pixels), the image scaled to fit and centered — from the client's
# `#{client_width}x#{client_height}` cells and `#{client_cell_width}x
# #{client_cell_height}` pixels; top-left at its own size when either is unknown —
# and a footer counting down FLEET_SHOW_HOLD_SECS (default 30): any key returns to
# tmux, `d` also sends it as a download. A non-image (PDF, text…) is sent as a
# download instead — iTerm2 cannot draw it — and its SENT line says so. The screen
# text is fixed Chinese. See bin/fleet-show-send.py.
#
# DEGRADE, never fail silently: the active client is not iTerm2, no tmux,
# FLEET_SHOW=0, a file over FLEET_SHOW_MAX_BYTES, a client that never finished →
# print the path and the reason, and exit 2, so the agent tells the operator where
# the file is instead.
#
# Exit: 0 sent to a client (one `SENT` line per file) · 2 degraded (one `PATH`
# line per file + why) · 1 usage / missing file.
#
# Knobs (fleet.conf or the fleet's conf; env wins):
#   FLEET_SHOW=0                  never write to a client; always degrade to the path
#   FLEET_SHOW_MAX_BYTES=20971520 the cap per file (20 MB)
#   FLEET_SHOW_TERM_RE='^iTerm2'  ERE a client's #{client_termtype} must match
#   FLEET_SHOW_PART_BYTES=768     base64 bytes per FilePart
#   FLEET_SHOW_HOLD_SECS=30       --inline: how long each drawn screen waits for a key
#   FLEET_SHOW_OUT                (selftests) where the sender writes instead of /dev/tty
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"

usage() {
  sed -n '2,3p' "$0" | sed 's/^# \{0,1\}//'
  printf '  --inline       draw it in the terminal instead of downloading it\n'
  printf '  --client <tty> send to this tmux client (skips the iTerm2 match)\n'
  printf '  --single       one-shot File= escape (iTerm2 < 3.5)\n'
}

inline=0; client=""; single=0; files=()
while [ $# -gt 0 ]; do
  case "$1" in
    --inline) inline=1 ;;
    --client) client="${2:-}"; shift ;;
    --client=*) client="${1#--client=}" ;;
    --single) single=1 ;;
    -h|--help) usage; exit 0 ;;
    --) shift; while [ $# -gt 0 ]; do files+=("$1"); shift; done; break ;;
    -*) printf 'fleet-show: unknown option %s\n' "$1" >&2; usage >&2; exit 1 ;;
    *) files+=("$1") ;;
  esac
  shift
done
[ "${#files[@]}" -gt 0 ] || { usage >&2; exit 1; }

# The fleet's knobs: global fleet.conf + this pane's fleet conf, under the env.
_env_show="${FLEET_SHOW-__unset}"; _env_max="${FLEET_SHOW_MAX_BYTES-__unset}"
_env_re="${FLEET_SHOW_TERM_RE-__unset}"; _env_part="${FLEET_SHOW_PART_BYTES-__unset}"
if [ -f "$BIN/fleet-lib.sh" ] && [ -n "${TMUX:-}" ]; then
  # shellcheck source=/dev/null
  . "$BIN/fleet-lib.sh" 2>/dev/null && fleet_load_conf "$(fleet_current_session)" 2>/dev/null
fi
[ "$_env_show" = __unset ] || FLEET_SHOW="$_env_show"
[ "$_env_max" = __unset ]  || FLEET_SHOW_MAX_BYTES="$_env_max"
[ "$_env_re" = __unset ]   || FLEET_SHOW_TERM_RE="$_env_re"
[ "$_env_part" = __unset ] || FLEET_SHOW_PART_BYTES="$_env_part"
SHOW="${FLEET_SHOW:-1}"
MAX="${FLEET_SHOW_MAX_BYTES:-20971520}"
TERM_RE="${FLEET_SHOW_TERM_RE:-^iTerm2}"
PART="${FLEET_SHOW_PART_BYTES:-768}"
case "$MAX" in ''|*[!0-9]*) MAX=20971520 ;; esac
case "$PART" in ''|*[!0-9]*|0) PART=768 ;; esac
PART=$(( PART / 4 * 4 )); [ "$PART" -ge 4 ] || PART=768   # whole base64 quanta

for f in ${files[@]+"${files[@]}"}; do
  [ -f "$f" ] && [ -r "$f" ] || { printf 'fleet-show: no such readable file: %s\n' "$f" >&2; exit 1; }
done

# Absolute path for the degrade line, so the operator can scp / find it as-is.
abspath() { (cd "$(dirname "$1")" && printf '%s/%s' "$(pwd -P)" "$(basename "$1")"); }

degrade() {  # <why> — every file as a PATH line, exit 2
  local f
  printf 'fleet-show: not sent to the operator'"'"'s terminal — %s\n' "$1" >&2
  for f in ${files[@]+"${files[@]}"}; do printf 'PATH %s\n' "$(abspath "$f")"; done
  exit 2
}

[ "$SHOW" = 0 ] && degrade 'FLEET_SHOW=0'

# ---- pick the client ------------------------------------------------------------
[ -n "${TMUX:-}" ] || degrade 'not inside tmux'
command -v python3 >/dev/null 2>&1 || degrade 'python3 not found'
PY="$(command -v python3)"
sess=$(tmux display-message -p -t "${TMUX_PANE:-}" '#{session_name}' 2>/dev/null)
[ -n "$sess" ] || degrade 'cannot resolve this pane'"'"'s tmux session'
termtype=""
# activity <TAB> tty <TAB> termtype <TAB> cols,rows,cell-w,cell-h
rows=$(tmux list-clients -t "$sess" -F '#{client_activity}	#{client_tty}	#{client_termtype}	#{client_width},#{client_height},#{client_cell_width},#{client_cell_height}' 2>/dev/null)
if [ -n "$client" ]; then
  pick=$(printf '%s\n' "$rows" | awk -F '\t' -v c="$client" '$2 == c { print $2 "\t" $3 "\t" $4; exit }')
  [ -n "$pick" ] || degrade "$client is not a client of session '$sess'"
else
  # The newest client is the one the operator is at — it must BE iTerm2 (#1371).
  pick=$(printf '%s\n' "$rows" | awk -F '\t' 'NF >= 2' | sort -t '	' -k1,1nr | head -n 1 \
    | awk -F '\t' '{ print $2 "\t" $3 "\t" $4 }')
  [ -n "$pick" ] || degrade "no client is attached to session '$sess'"
  _tty="${pick%%	*}"; _tt="${pick#*	}"; _tt="${_tt%%	*}"
  [ -n "$_tt" ] || degrade "当前活跃 client ${_tty} 的终端类型未知（tmux < 3.4，或终端没回应 XTVERSION），不是 iTerm2"
  printf '%s\n' "$_tt" | grep -Eq -- "$TERM_RE" \
    || degrade "当前活跃 client ${_tty} 是 ${_tt}，不是 iTerm2（/${TERM_RE}/）"
fi
client="${pick%%	*}"; termtype="${pick#*	}"; geom="${termtype#*	}"; termtype="${termtype%%	*}"
[ "$geom" != "$termtype" ] || geom=""
case "$geom" in *[!0-9,]*|'') geom="0,0,0,0" ;; esac

# ---- what goes, what is too big ---------------------------------------------------
send=(); total=0; rc=0
for f in ${files[@]+"${files[@]}"}; do
  size=$(wc -c < "$f" | tr -d ' ')
  if [ "$size" -gt "$MAX" ]; then
    printf 'fleet-show: %s is %s bytes, over FLEET_SHOW_MAX_BYTES=%s\n' "$f" "$size" "$MAX" >&2
    printf 'PATH %s\n' "$(abspath "$f")"; rc=2; continue
  fi
  send+=("$(abspath "$f")"); total=$(( total + size ))
done
[ "${#send[@]}" -gt 0 ] || exit "$rc"

# ---- one send per session at a time ---------------------------------------------
sq() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }
lockdir="${TMPDIR:-/tmp}/fleet-show.$(id -u).$(printf '%s' "$sess" | tr -c 'A-Za-z0-9._-' '_').lock"
got=0
for _ in $(seq 1 100); do
  if mkdir "$lockdir" 2>/dev/null; then got=1; break; fi
  # a holder killed mid-send leaves the dir: stale after 5 min
  if [ -n "$(find "$lockdir" -maxdepth 0 -mmin +5 2>/dev/null)" ]; then rmdir "$lockdir" 2>/dev/null; continue; fi
  sleep 0.2
done
[ "$got" = 1 ] || degrade 'another fleet-show is sending in this session'
job=$(mktemp -d "${TMPDIR:-/tmp}/fleet-show.XXXXXX") || { rmdir "$lockdir"; degrade 'mktemp failed'; }
trap 'rm -rf "$job"; rmdir "$lockdir" 2>/dev/null' EXIT
status="$job/status"; : > "$status"

cmd="exec $(sq "$PY") $(sq "$BIN/fleet-show-send.py") --out $(sq "${FLEET_SHOW_OUT:-/dev/tty}") --status $(sq "$status") --part $PART"
HOLD="${FLEET_SHOW_HOLD_SECS:-30}"; case "$HOLD" in ''|*[!0-9]*) HOLD=30 ;; esac
[ "$inline" = 1 ] && cmd="$cmd --inline --wait-key $HOLD --geom $geom"
[ "$single" = 1 ] && cmd="$cmd --single"
for f in ${send[@]+"${send[@]}"}; do cmd="$cmd $(sq "$f")"; done

# Swap the session's lock-command for one lock, then put back exactly what was there
# (a session value, or none — the global default shows through again).
prev_set=$(tmux show-options -q -t "$sess" lock-command 2>/dev/null)
prev_val=$(tmux show-options -qv -t "$sess" lock-command 2>/dev/null)
tmux set-option -t "$sess" lock-command "$cmd" 2>/dev/null || degrade 'cannot set lock-command'
tmux lock-client -t "$client" 2>/dev/null; lrc=$?
if [ -n "$prev_set" ]; then tmux set-option -t "$sess" lock-command "$prev_val" 2>/dev/null
else tmux set-option -u -t "$sess" lock-command 2>/dev/null; fi
[ "$lrc" = 0 ] || degrade "tmux lock-client -t $client failed"

# Wait for the sender's `done` — generous for the size (a slow SSH link drains it).
limit=$(( 20 + total / 100000 ))
# --inline with several images: every screen but the last is held before `done`.
[ "$inline" = 1 ] && limit=$(( limit + HOLD * (${#send[@]} - 1) ))
waited=0
while ! grep -qx 'done' "$status" 2>/dev/null; do
  [ "$waited" -ge $(( limit * 5 )) ] && break
  sleep 0.2; waited=$(( waited + 1 ))
done
grep -qx 'done' "$status" 2>/dev/null || degrade "the client did not finish sending within ${limit}s (status: $(tr '\n' ' ' < "$status"))"

dlwhere="offered as a download — lands in the operator's ~/Downloads once they accept iTerm2's prompt"
if [ "$inline" = 1 ]; then where="drawn centered on the operator's screen (held until a key, ${HOLD}s at most)"
else where="$dlwhere"; fi
while IFS='	' read -r verdict detail name; do
  case "$verdict" in
    ok)  printf 'SENT %s (%s bytes) → %s%s: %s\n' "$name" "$detail" "$client" "${termtype:+ [$termtype]}" "$where" ;;
    dl)  printf 'SENT %s (%s bytes) → %s%s: not an image iTerm2 can draw — %s\n' "$name" "$detail" "$client" "${termtype:+ [$termtype]}" "$dlwhere" ;;
    dl+) printf 'SENT %s → the operator pressed d: also %s\n' "$name" "$dlwhere" ;;
    err) printf 'fleet-show: %s: %s\n' "$name" "$detail" >&2
         for f in ${send[@]+"${send[@]}"}; do [ "$(basename "$f")" = "$name" ] && printf 'PATH %s\n' "$f"; done
         rc=2 ;;
  esac
done < "$status"
exit "$rc"
