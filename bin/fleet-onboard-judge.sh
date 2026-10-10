#!/bin/bash
# fleet-onboard-judge.sh — what a newcomer's screen says, judged the same way on
# every platform (issue #2888). SOURCED, never run: bin/fleet-onboard-drill.sh
# (macOS, a real login over ssh) and bin/newcomer-cn.sh (Linux, a useradd login
# on the 国内 runner) read their captured panes through these functions, so a
# screen that passes one passes the other. Each takes the screen (or JSON) on
# stdin and prints one word or row; none touches a login, a tmux or the hub.
#
#   list_row_named <name>   the list row carrying <name>, never the input line
#   qr_state <login>        qr · none · wait — where the installer's scan stands
#   attach_state            lost · answered · path · wait (the attachment step)
#   ls_row <name>           <node> TAB <key> TAB <fleet_id> from `fleet ls --json`
#   drill_png <file>        the attach step's solid red PNG
#   agent_state <word>      exited · answered · up · wait — a `fleet claude` view
#   curl_noise              how many `curl: (` lines the screen carries

# list_row_named <name> (a screen on stdin): a list ROW carrying the name — the left column before 「│」,
# never the input line 「› <name>」 (the typed name is not a session; matching
# it passed the #1901 final run while the list said 「No sessions」). Only a
# line of the split counts (one with 「│」: the shell prompt 「drill1007b@mini2 %」
# above it passed #2221's run), and the name is a whole word — no letter,
# digit, @, _ or - against either side.
list_row_named() {
  grep -F '│' | sed 's/│.*//' | grep -Ev '^[[:space:]]*›' \
    | grep -E -- "(^|[^[:alnum:]@_-])$1(\$|[^[:alnum:]@_-])" | head -n 1 | sed 's/ *$//'
}

# qr_state <login> (a screen on stdin): qr — a 验证码 is up; none — the
# installer is past its end (「能力:」, or 「用时 N 秒」 — the newcomer's install
# prints no 能力 line, issue #2347) AND finished with no code (the client is up, it
# could not open, or the person is back at a prompt); wait — anything else.
# The installer prints 「能力:」 BEFORE its QR (#2255): 能力: alone is no proof
# that this computer was already known, so it never reads none by itself.
CLIENT_UP='新任务|[Nn]ew task|⌘N|⌘P'   # the list's portal row, else its bar's keys (run 2: 「⌘N 编排」, no 新任务)
INSTALL_END='^(能力:|用时 [0-9]+ 秒)'
qr_state() {
  local p
  p=$(cat)
  if printf '%s\n' "$p" | grep -Eq '验证码 [A-Z]{4}-[A-Z]{4}'; then echo qr
  elif printf '%s\n' "$p" | grep -Eq "$INSTALL_END" \
       && printf '%s\n' "$p" | grep -Eq -- "$CLIENT_UP|open terminal failed|not a terminal|$1@[^ ]+ [^ ]* ?[%\$#] *\$"; then echo none
  else echo wait; fi
}

# drill_png <file>: the attach step's screenshot — a 64×64 solid red PNG
# (python3 alone: no Pillow, no screen to capture on a bare login)
drill_png() {
  python3 - "$1" <<'PY'
import struct, sys, zlib
def chunk(t, d):
    return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xffffffff)
w = h = 64
raw = b"".join(b"\x00" + b"\xd0\x10\x10" * w for _ in range(h))
open(sys.argv[1], "wb").write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
                              + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b""))
PY
}
# attach_state (a screen on stdin): lost — the client said the file did not go;
# answered — the session's text names the file on ITS machine
# (…/attachments/<id>/…) and an answer says the colour; path — the path only;
# wait — neither yet. The colour is in nothing the drill types.
ATTACH_LOST='附件没带过去|did not go'
ATTACH_RED='红|(^|[^[:alpha:]])[Rr]ed([^[:alpha:]]|$)'
attach_state() {
  local p
  p=$(cat)
  if printf '%s\n' "$p" | grep -Eq -- "$ATTACH_LOST"; then echo lost
  elif ! printf '%s\n' "$p" | grep -qF '/attachments/'; then echo wait
  elif printf '%s\n' "$p" | sed -n '/\/attachments\//,$p' | grep -Eq -- "$ATTACH_RED"; then echo answered
  else echo path; fi
}
attach_answer() { sed -n '/\/attachments\//,$p' | grep -Eo -- "$ATTACH_RED" | head -n 1 | tr -d ' '; }
# ls_row <name> (`fleet ls --json` on stdin): <node> TAB <key> TAB <fleet_id> of
# the first session whose name starts with <name>. A hub row's key is
# wid:<fleet UUID>/<fleet_id> — the window's lifelong @fleet_id is what finds it
# on its machine; a row of this computer's own has none (-).
ls_row() {
  python3 -c '
import json, sys
try:
    rows = json.load(sys.stdin)
except ValueError:
    sys.exit(1)
for r in rows:
    if str(r.get("name", "")).startswith(sys.argv[1]):
        k = str(r.get("key", ""))
        fid = k.split("/", 1)[1] if k.startswith("wid:") and "/" in k else "-"
        print("%s\t%s\t%s" % (r.get("node", "") or "-", k, fid or "-"))
        sys.exit(0)
sys.exit(1)' "$1"
}

# agent_state <word> (a screen on stdin): the one-session view `fleet claude
# --new <first sentence>` draws (issue #2888). exited — the command came back
# (the run's own sentinel 「__NCCN_EXIT=<rc>」, printed after it: a placement the
# hub refused, a view that closed); answered — a reply of the agent's (Claude
# Code's 「⏺」 line) carries <word>, and the sentence that asked for it is not
# that line; up — the agent's screen is drawn (its prompt 「❯」 / 「> 」 inside the
# box, or its banner); wait — anything else (正在为你开机器, the placement).
AGENT_UP='Claude Code|^[[:space:]]*│?[[:space:]]*(❯|>)[[:space:]]|^╭─'
agent_state() {
  local p
  p=$(cat)
  if printf '%s\n' "$p" | grep -Eq '__NCCN_EXIT=[0-9]+'; then echo exited
  elif printf '%s\n' "$p" | grep -E '^[[:space:]]*⏺' | grep -qF -- "$1"; then echo answered
  elif printf '%s\n' "$p" | grep -Eq -- "$AGENT_UP"; then echo up
  else echo wait; fi
}
# curl_noise (a screen on stdin): the count of 「curl: (」 lines — each one is
# noise on a newcomer's screen (a retried download, a blocked mirror).
curl_noise() { grep -c 'curl: (' || :; }
