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
# download instead — iTerm2 cannot draw it — and its stderr line says so. The screen
# text is fixed Chinese. See bin/fleet-show-send.py.
#
# THE CLIENT FIRST (issue #1717, EPIC #1710 C7): fleet-client-where.sh says where
# the person is; a client holding the hub's lease gets each file as a show_file
# action (fleet-client-actions.py: it fetches the file from here over its own ssh
# and opens it on the device in their hands) — its result says where.
# No hub and the client runs on this computer's screen → `open` here
# (`saved:<path>` — it is already on that computer). Nobody connected → the
# terminal road below, as before.
# FLEET_SHOW_CLIENT=0 skips it.
#
# DEGRADE, never fail silently: the active client is not iTerm2, no tmux,
# FLEET_SHOW=0, a file over FLEET_SHOW_MAX_BYTES, a client that never finished →
# print the path (a `PATH` line) and `failed:<reason>`, and exit 2, so the agent
# tells the operator where the file is instead.
#
# A RECEIPT, not a send (issue #3541 — #3538's for open): every file carries an id
# and each road whose far side can answer waits FLEET_SHOW_ACK_WAIT seconds (12, plus
# 2 s a MB) for `fleet-open.sh --ack <id> ok <where it was saved> | fail <why>`
# (the same receipt book as fleet-open, $FLEET_CONF_DIR/open-acks):
#   · a thin 看台 on this machine whose loop says it takes `show` (its registry row's
#     `caps=`, fleet-thin.py ≥ this): OSC 7502 `show ; token=… ; j=<{id,name,size,who}>`
#     on its tty — the loop fetches the file over its own line (`fleet-show.sh --fetch
#     <id>` here: the bytes of the file registered under that id, once, within 30 min —
#     the client never names a path) into its ~/Downloads and answers with the path.
#     An older loop has no `caps=`: the terminal road below, as before;
#   · the iTerm2 download: an `OSC 1337 ; Custom=id=<secret>:<{kind:file,id,name,size}>`
#     right before the file's escape (the fleet-open secret; none ⇒ no receipt asked):
#     extras/iterm2/fleet_open.py v3 watches its downloads folder for that file and
#     answers with where it landed — or that it never did (the prompt declined). A v2
#     script refuses the unknown kind: `unconfirmed`, never `failed`;
#   · the client lease: its action's result (a path ⇒ saved); the local opener: the
#     file is already on this computer (saved:<its path>).
# --inline draws on the screen — nothing is saved, nothing can answer: unconfirmed.
#
# Prints ONE result line per file, in order (stderr names the road and the file):
#   saved:<path>     the far side said it saved it there (on THEIR computer)   exit 0
#   unconfirmed      handed over, no receipt within the wait (or a road with none)
#   failed:<why>     the far side said it could not                          exit 4
#   PATH <path> + failed:<why>   not sent at all (degraded, below)           exit 2
# exit 1 = usage / missing file. (Before #3541: `SENT …` lines, which said only that
# the bytes were written.)
#
# Knobs (fleet.conf or the fleet's conf; env wins):
#   FLEET_SHOW=0                  never write to a client; always degrade to the path
#   FLEET_SHOW_MAX_BYTES=20971520 the cap per file (20 MB)
#   FLEET_SHOW_TERM_RE='^iTerm2'  ERE a client's #{client_termtype} must match
#   FLEET_SHOW_PART_BYTES=768     base64 bytes per FilePart
#   FLEET_SHOW_HOLD_SECS=30       --inline: how long each drawn screen waits for a key
#   FLEET_SHOW_ACK_WAIT=12        seconds to wait for a receipt (0 = none: unconfirmed)
#   FLEET_SHOW_OUT                (selftests) where the sender writes instead of /dev/tty
#   FLEET_THIN_SHOW_OUT           (selftests) where the thin 看台's 7502 goes instead of its tty
#   FLEET_OPEN_SECRET_FILE        (selftests) the fleet-open secret (the iTerm2 receipt's key)
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
SHOWS="${FLEET_CONF_DIR:-$HOME/.config/claude-fleet}/show-files"
ACKS="${FLEET_CONF_DIR:-$HOME/.config/claude-fleet}/open-acks"

# --fetch <id>: a thin loop collecting the file a `show` named (issue #3541) — the
# bytes of the file registered under <id>, once; nothing else is reachable this way.
if [ "${1:-}" = --fetch ]; then
  case "${2:-}" in ''|*[!a-f0-9]*) echo 'fleet-show: --fetch <hex id>' >&2; exit 1 ;; esac
  rec="$SHOWS/$2"
  [ -f "$rec" ] && [ -z "$(find "$rec" -mmin +30 2>/dev/null)" ] \
    || { rm -f "$rec"; echo "fleet-show: no file waiting under $2" >&2; exit 3; }
  IFS= read -r p < "$rec"; rm -f "$rec"
  [ -f "$p" ] && [ -r "$p" ] || { echo "fleet-show: $p is gone" >&2; exit 3; }
  exec cat -- "$p"
fi

usage() {
  sed -n '2,3p' "$0" | sed 's/^# \{0,1\}//'
  printf '  --inline       draw it in the terminal instead of downloading it\n'
  printf '  --client <tty> send to this tmux client (skips the iTerm2 match)\n'
  printf '  --single       one-shot File= escape (iTerm2 < 3.5)\n'
  printf '  --fetch <id>   (a thin loop) the bytes of the file a show registered under <id>\n'
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
# (a pane of a fleet: the machine's library, fleet_host_lib — issue #4825)
if [ -n "${TMUX:-}" ] && [ -f "$BIN/fleet-client-core.sh" ]; then
  # shellcheck source=fleet-client-core.sh
  . "$BIN/fleet-client-core.sh" 2>/dev/null && fleet_host_lib 2>/dev/null \
    && fleet_load_conf "$(fleet_current_session)" 2>/dev/null
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

degrade() {  # <why> — every file left as a PATH line + failed:<why>, exit 2
  local f
  printf 'fleet-show: not sent to the operator'"'"'s terminal — %s\n' "$1" >&2
  for f in ${files[@]+"${files[@]}"}; do printf 'PATH %s\nfailed:%s\n' "$(abspath "$f")" "$1"; done
  exit 2
}

# ---- the receipt (issue #3541) ---------------------------------------------------
RC=0
new_id() {
  local i; i=$(od -An -N8 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')
  [ -n "$i" ] || i=$(printf '%x%x%x' "$(date +%s)" "$$" "$RANDOM")
  printf '%s' "$i"
}
ack_wait_for() {  # <total bytes> — the seconds a receipt may take
  local w="${FLEET_SHOW_ACK_WAIT:-12}"; case "$w" in ''|*[!0-9]*) w=12 ;; esac
  [ "$w" = 0 ] && { echo 0; return; }
  echo $(( w + 2 * ${1:-0} / 1000000 ))
}
# wait_ack <id> <deadline epoch> — ACK_STATE ok|fail, ACK_WHY; rc 1 = none in time
wait_ack() {
  local f="$ACKS/$1"; ACK_STATE=''; ACK_WHY=''
  while :; do
    if [ -s "$f" ]; then IFS='	' read -r ACK_STATE ACK_WHY < "$f"; rm -f "$f"; return 0; fi
    [ "$(date +%s)" -lt "$2" ] || return 1
    sleep 0.1
  done
}
# result <name> <state ok|fail|none> <why or path> <road words> — the ONE line per file
result() {
  case "$2" in
    ok)   printf 'fleet-show: %s → %s：已保存到 %s\n' "$1" "$4" "$3" >&2; printf 'saved:%s\n' "$3" ;;
    fail) printf 'fleet-show: %s → %s：没收到（%s）\n' "$1" "$4" "$3" >&2; printf 'failed:%s\n' "$3"
          [ "$RC" = 2 ] || RC=4 ;;
    *)    printf 'fleet-show: %s → %s — 没有回执，确认不了收到了%s\n' "$1" "$4" "${3:+（${3}）}" >&2
          echo unconfirmed ;;
  esac
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
    # a thin client (issue #3005): its home holds the lease, no action loop — the
    # terminal road below writes to its 看台's terminal
    "hub active thin"|"local active thin") ;;
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
        # its result names where it landed (`saved:<path>`, or a bare path) — else
        # it took the file and said nothing more
        case "$st_state:$st_res" in
          done:saved:*) result "$(basename "$f")" ok "${st_res#saved:}" "客户端 $st_dev" ;;
          done:/*)      result "$(basename "$f")" ok "$st_res" "客户端 $st_dev" ;;
          done:*)       result "$(basename "$f")" none "$st_res" "客户端 $st_dev" ;;
          queued:*)     result "$(basename "$f")" none '已排队' "客户端 $st_dev" ;;
          *) break ;;
        esac
        sent=$(( sent + 1 ))
      done
      [ "$sent" = "${#files[@]}" ] && exit "$RC"
      # the client could not take one: what is left goes the old road
      [ "$sent" -gt 0 ] && files=("${files[@]:$sent}") ;;  # bash32-ok: sent > 0 ⇒ files was non-empty
    "local active local")
      lopen="${FLEET_SHOW_LOCAL_CMD:-}"
      [ -n "$lopen" ] || { [ "$(uname -s)" = Darwin ] && lopen=open || lopen=xdg-open; }
      ok=1
      for f in ${files[@]+"${files[@]}"}; do "$lopen" "$(abspath "$f")" >/dev/null 2>&1 || { ok=0; break; }; done
      if [ "$ok" = 1 ]; then
        # the client is on this very computer: the file already is where they are
        for f in ${files[@]+"${files[@]}"}; do result "$(basename "$f")" ok "$(abspath "$f")" '本机（客户端就在这台电脑上，已打开）'; done
        exit "$RC"
      fi ;;
  esac
fi

# ---- a thin 看台 here whose loop takes `show` (issue #3541) -------------------------
# The person's newest client on this machine is a thin 看台 (not another home's
# `-via-` one) and its registry row says `caps=…show…`: each file is registered under
# an id and named to the loop in OSC 7502 `show` with the connection's token (约定
# 10); the loop fetches it (--fetch above) into its downloads and answers with the
# path. rc 1 = no such 看台: the terminal road below, as before.
RV_DIR="${FLEET_CONF_DIR:-$HOME/.config/claude-fleet}/remote-views"
thin_show() {
  [ -d "$RV_DIR" ] && [ -n "${TMUX:-}" ] || return 1
  command -v python3 >/dev/null 2>&1 || return 1
  # shellcheck source=/dev/null
  . "$BIN/fleet-client-lib.sh" || return 1
  fc_session || return 1
  local rows ttyp row tok caps dev who f id total=0 size deadline ids=() names=() i
  rows=$(awk -F '\t' -v s="$FC_SESS" '$2 == s && $3 == "thin" && FILENAME !~ /-via-[^\/]*$/ { print }' "$RV_DIR"/* 2>/dev/null)
  [ -n "$rows" ] || return 1
  ttyp=$(fc_clients '#{client_activity}	#{client_tty}' | sort -t '	' -k1,1nr | head -n 1 | cut -f2)
  row=$(printf '%s\n' "$rows" | awk -F '\t' -v t="$ttyp" '$1 == t { print; exit }')
  [ -n "$row" ] || return 1
  caps=$(printf '%s\n' "$row" | tr '\t' '\n' | sed -n 's/^caps=//p' | head -n 1)
  case ",$caps," in *,show,*) ;; *) return 1 ;; esac
  tok=$(printf '%s\n' "$row" | tr '\t' '\n' | sed -n 's/^token=//p' | head -n 1)
  case "$tok" in ''|*[!A-Za-z0-9._:-]*) return 1 ;; esac
  case "$ttyp" in /dev/*) ;; *) return 1 ;; esac
  dev=$(printf '%s\n' "$row" | tr '\t' '\n' | sed -n 's/^device=//p' | head -n 1 | python3 -c 'import base64,json,sys
try: print(json.loads(base64.urlsafe_b64decode(sys.stdin.read().strip().replace("+", "-").replace("/", "_") + "==")).get("device") or "")
except Exception: print("")' 2>/dev/null)
  who=''; [ -n "${TMUX_PANE:-}" ] && who=$(tmux display-message -p -t "$TMUX_PANE" '#{window_name}' 2>/dev/null)
  mkdir -p "$SHOWS" 2>/dev/null && chmod 700 "$SHOWS" 2>/dev/null || return 1
  for f in ${files[@]+"${files[@]}"}; do
    size=$(wc -c < "$f" | tr -d ' ')
    id=$(new_id)
    ( umask 077; abspath "$f" > "$SHOWS/.$id" && printf '\n' >> "$SHOWS/.$id" && mv -f "$SHOWS/.$id" "$SHOWS/$id" ) || return 1
    python3 - "${FLEET_THIN_SHOW_OUT:-$ttyp}" "$tok" "$id" "$(basename "$f")" "$size" "${who:-?}" <<'PY2' || { rm -f "$SHOWS/$id"; return 1; }
import base64, json, os, sys
out, tok, oid, name, size, who = sys.argv[1:7]
d = {"v": 1, "id": oid, "name": name, "size": int(size), "who": who[:80]}
b = base64.b64encode(json.dumps(d, separators=(",", ":"), ensure_ascii=False).encode()).decode()
fd = os.open(out, os.O_WRONLY | os.O_NOCTTY | os.O_APPEND | (os.O_CREAT if not out.startswith("/dev/") else 0), 0o600)
try:
    os.write(fd, ("\x1b]7502;show;token=%s;j=%s\x07" % (tok, b)).encode())
finally:
    os.close(fd)
PY2
    ids+=("$id"); names+=("$(basename "$f")"); total=$(( total + size ))
  done
  deadline=$(( $(date +%s) + $(ack_wait_for "$total") ))
  i=0
  for id in ${ids[@]+"${ids[@]}"}; do
    if wait_ack "$id" "$deadline"; then
      result "${names[$i]}" "$ACK_STATE" "${ACK_WHY:-?}" "客户端 ${dev:-?}（瘦客户端）"
    else
      rm -f "$SHOWS/$id"
      result "${names[$i]}" none "${FLEET_SHOW_ACK_WAIT:-12} 秒内没等到它的回执" "客户端 ${dev:-?}（瘦客户端）"
    fi
    i=$(( i + 1 ))
  done
  exit "$RC"
}
case "${cw_src:-}" in "hub active thin"|"local active thin") thin_show ;; esac

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
send=(); total=0
for f in ${files[@]+"${files[@]}"}; do
  size=$(wc -c < "$f" | tr -d ' ')
  if [ "$size" -gt "$MAX" ]; then
    printf 'fleet-show: %s is %s bytes, over FLEET_SHOW_MAX_BYTES=%s\n' "$f" "$size" "$MAX" >&2
    printf 'PATH %s\nfailed:%s bytes, over FLEET_SHOW_MAX_BYTES=%s\n' "$(abspath "$f")" "$size" "$MAX"; RC=2; continue
  fi
  send+=("$(abspath "$f")"); total=$(( total + size ))
done
[ "${#send[@]}" -gt 0 ] || exit "$RC"

# ---- one send per session at a time ---------------------------------------------
sq() { fc_sq "$1"; }
fc_lock || degrade "$FC_WHY"
job=$(mktemp -d "${TMPDIR:-/tmp}/fleet-show.XXXXXX") || { fc_unlock; degrade 'mktemp failed'; }
trap 'rm -rf "$job"; fc_unlock' EXIT
status="$job/status"; : > "$status"

# The receipt request (issue #3541): one Custom= escape per download, keyed with the
# fleet-open secret, built into a 0600 file so the secret never reaches an argv or
# the lock-command string. No secret (fleet_open.py was never installed against this
# machine) or --inline: nothing asked, nothing answers.
SECRET="${FLEET_OPEN_SECRET_FILE:-$HOME/.config/claude-fleet/open.secret}"
pres=(); ids=()
if [ "$inline" = 0 ] && [ -s "$SECRET" ]; then
  n=0
  for f in ${send[@]+"${send[@]}"}; do
    id=$(new_id); n=$(( n + 1 ))
    ( umask 077
      "$PY" - "$SECRET" "$job/pre.$n" "$id" "$(basename "$f")" "$(wc -c < "$f" | tr -d ' ')" "${FLEET_OPEN_SSH_HOST:-}" <<'PY2'
import base64, json, re, sys, time
secret = open(sys.argv[1]).read().strip()
host = sys.argv[6] if re.match(r"^[A-Za-z0-9][A-Za-z0-9._@-]*$", sys.argv[6]) else ""
d = {"v": 1, "kind": "file", "id": sys.argv[3], "name": sys.argv[4], "size": int(sys.argv[5]),
     "host": host, "ts": int(time.time())}
b = base64.b64encode(json.dumps(d, separators=(",", ":"), ensure_ascii=False).encode()).decode()
open(sys.argv[2], "wb").write(("\033]1337;Custom=id=%s:%s\a" % (secret, b)).encode())
PY2
    ) && { pres+=(--pre "$job/pre.$n"); ids+=("$id"); continue; }
    pres=(); ids=(); break
  done
fi

cmd="exec $(sq "$PY") $(sq "$BIN/fleet-show-send.py") --out $(sq "${FLEET_SHOW_OUT:-/dev/tty}") --status $(sq "$status") --part $PART"
HOLD="${FLEET_SHOW_HOLD_SECS:-30}"; case "$HOLD" in ''|*[!0-9]*) HOLD=30 ;; esac
[ "$inline" = 1 ] && cmd="$cmd --inline --wait-key $HOLD --geom $geom"
[ "$single" = 1 ] && cmd="$cmd --single"
for f in ${pres[@]+"${pres[@]}"}; do cmd="$cmd $(sq "$f")"; done
for f in ${send[@]+"${send[@]}"}; do cmd="$cmd $(sq "$f")"; done
fc_run "$cmd" || degrade "$FC_WHY"

# Wait for the sender's `done` — generous for the size (a slow SSH link drains it).
limit=$(( 20 + total / 100000 ))
# --inline with several images: every screen but the last is held before `done`.
[ "$inline" = 1 ] && limit=$(( limit + HOLD * (${#send[@]} - 1) ))
fc_wait "$status" "$limit" || degrade "the client did not finish sending within ${limit}s (status: $(tr '\n' ' ' < "$status"))"

# The bytes are out: free the client for the next fleet-show / fleet-open first.
st=$(cat "$status"); rm -rf "$job"; fc_unlock; trap - EXIT
road="iTerm2（${client}${termtype:+ $termtype}）"
deadline=$(( $(date +%s) + $(ack_wait_for "$total") ))
k=0
while IFS='	' read -r verdict detail name; do
  case "$verdict" in
    ok)
      if [ "$inline" = 1 ]; then
        result "$name" none "画在了屏幕上，不存文件" "$road"
        continue
      fi
      id="${ids[$k]:-}"; k=$(( k + 1 ))
      if [ -z "$id" ]; then
        result "$name" none "作为下载发出，没有 fleet-open 密钥，请不了那边回报" "$road"
      elif wait_ack "$id" "$deadline"; then
        case "$ACK_STATE:$ACK_WHY" in
          ok:?*) result "$name" ok "$ACK_WHY" "$road" ;;
          fail:*"unknown kind"*) result "$name" none "那边的 fleet_open.py 是旧版，不回报下载 — 重装 extras/iterm2/install.sh" "$road" ;;
          *) result "$name" fail "${ACK_WHY:-the laptop could not save it}" "$road" ;;
        esac
      else
        result "$name" none "作为下载发出，$(ack_wait_for "$total") 秒内没等到那边的回执（fleet_open.py 没装，或下载提示还在等你点）" "$road"
      fi ;;
    dl)  result "$name" none "不是 iTerm2 能画的图，作为下载发出" "$road" ;;
    dl+) printf 'fleet-show: %s → 你按了 d：也作为下载发出\n' "$name" >&2 ;;
    err) [ "$inline" = 1 ] || k=$(( k + 1 ))
         printf 'fleet-show: %s: %s\n' "$name" "$detail" >&2
         for f in ${send[@]+"${send[@]}"}; do [ "$(basename "$f")" = "$name" ] && printf 'PATH %s\nfailed:%s\n' "$f" "$detail"; done
         RC=2 ;;
  esac
done <<EOF
$st
EOF
exit "$RC"
