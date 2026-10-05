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
# The client pick + the lock-client write live in bin/fleet-client-lib.sh, shared
# with bin/fleet-open.sh (issue #1379).
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
# THE CLIENT FIRST (issue #1717, EPIC #1710 C7): fleet-client-where.sh says where
# the person is; a client holding the hub's lease gets each file as a show_file
# action (fleet-client-actions.py: it fetches the file from here over its own ssh
# and opens it on the device in their hands) — `SENT <name> → 客户端 <device>`.
# No hub and the client runs on this computer's screen → `open` here
# (`SENT <name> → 本机`). Nobody connected → the terminal road below, as before.
# FLEET_SHOW_CLIENT=0 skips it.
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

# ---- the person's client first (issue #1717) -----------------------------------------
# fleet-client-where.sh says where the person is (EPIC #1710 rule 7). Their client
# holds the hub's lease → each file goes to it as a show_file action: it fetches the
# file from this machine over its own ssh and opens it (a computer), sends it on as
# iTerm2's escape (an iTerm2 at the far end of an ssh — --inline kept), or says
# 「回到电脑上再看」 (a phone). No hub and the client here is on this computer's own
# screen → `open` it here. Anything else → the terminal road below, as before.
if [ "${FLEET_SHOW_CLIENT:-1}" != 0 ] && command -v python3 >/dev/null 2>&1; then
  if [ -n "${FLEET_OPEN_WHERE_CMD:-}" ]; then cw=$($FLEET_OPEN_WHERE_CMD --json 2>/dev/null) || :
  else cw=$(bash "$BIN/fleet-client-where.sh" --json 2>/dev/null) || :; fi
  cw_src=$(printf '%s' "$cw" | python3 -c 'import json,sys
try: d = json.load(sys.stdin)
except Exception: d = {}
print("%s %s %s" % (d.get("source") or "-", d.get("state") or "-", d.get("via") or "-"))' 2>/dev/null)
  case "$cw_src" in
    "hub active "*)
      sent=0
      for f in ${files[@]+"${files[@]}"}; do
        inl=''; [ "$inline" = 1 ] && inl=--inline
        res=$(python3 "${FLEET_SHOW_ACTIONS_BIN:-$BIN/fleet-client-actions.py}" send --kind show_file \
                --file "$(abspath "$f")" ${inl:+"$inl"} --wait "${FLEET_SHOW_CLIENT_WAIT:-10}" 2>/dev/null) || res=''
        st=$(printf '%s' "$res" | python3 -c 'import json,sys
try: d = json.load(sys.stdin)
except Exception: d = {}
c = d.get("client") or {}
print("%s\t%s\t%s" % (d.get("state") or "", c.get("device") or "", d.get("result") or ""))' 2>/dev/null)
        st_state=${st%%	*}; st_dev=$(printf '%s' "$st" | cut -f2); st_res=$(printf '%s' "$st" | cut -f3)
        case "$st_state" in
          done|queued)
            [ "$st_state" = queued ] && st_res='已排队'
            printf 'SENT %s → 客户端 %s: %s\n' "$(basename "$f")" "$st_dev" "$st_res"
            sent=$(( sent + 1 )) ;;
          *) break ;;
        esac
      done
      [ "$sent" = "${#files[@]}" ] && exit 0
      # the client could not take one: what is left goes the old road
      [ "$sent" -gt 0 ] && files=("${files[@]:$sent}") ;;  # bash32-ok: sent > 0 ⇒ files was non-empty
    "local active local")
      lopen="${FLEET_SHOW_LOCAL_CMD:-}"
      [ -n "$lopen" ] || { [ "$(uname -s)" = Darwin ] && lopen=open || lopen=xdg-open; }
      ok=1
      for f in ${files[@]+"${files[@]}"}; do "$lopen" "$(abspath "$f")" >/dev/null 2>&1 || { ok=0; break; }; done
      if [ "$ok" = 1 ]; then
        for f in ${files[@]+"${files[@]}"}; do printf 'SENT %s → 本机：客户端就在这台电脑上，已打开\n' "$(basename "$f")"; done
        exit 0
      fi ;;
  esac
fi

# ---- pick the client (bin/fleet-client-lib.sh — shared with fleet-open) -----------
[ -n "${TMUX:-}" ] || degrade 'not inside tmux'
command -v python3 >/dev/null 2>&1 || degrade 'python3 not found'
PY="$(command -v python3)"
# shellcheck source=/dev/null
. "$BIN/fleet-client-lib.sh"
fc_session || degrade "$FC_WHY"
fc_pick "$client" "$TERM_RE" || degrade "$FC_WHY"
client="$FC_CLIENT"; termtype="$FC_TERMTYPE"; geom="$FC_GEOM"

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
sq() { fc_sq "$1"; }
fc_lock || degrade "$FC_WHY"
job=$(mktemp -d "${TMPDIR:-/tmp}/fleet-show.XXXXXX") || { fc_unlock; degrade 'mktemp failed'; }
trap 'rm -rf "$job"; fc_unlock' EXIT
status="$job/status"; : > "$status"

cmd="exec $(sq "$PY") $(sq "$BIN/fleet-show-send.py") --out $(sq "${FLEET_SHOW_OUT:-/dev/tty}") --status $(sq "$status") --part $PART"
HOLD="${FLEET_SHOW_HOLD_SECS:-30}"; case "$HOLD" in ''|*[!0-9]*) HOLD=30 ;; esac
[ "$inline" = 1 ] && cmd="$cmd --inline --wait-key $HOLD --geom $geom"
[ "$single" = 1 ] && cmd="$cmd --single"
for f in ${send[@]+"${send[@]}"}; do cmd="$cmd $(sq "$f")"; done
fc_run "$cmd" || degrade "$FC_WHY"

# Wait for the sender's `done` — generous for the size (a slow SSH link drains it).
limit=$(( 20 + total / 100000 ))
# --inline with several images: every screen but the last is held before `done`.
[ "$inline" = 1 ] && limit=$(( limit + HOLD * (${#send[@]} - 1) ))
fc_wait "$status" "$limit" || degrade "the client did not finish sending within ${limit}s (status: $(tr '\n' ' ' < "$status"))"

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
