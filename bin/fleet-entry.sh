#!/bin/bash
# fleet-entry.sh — the entry port's ForceCommand (issue #3071, EPIC #3067 C5,
# 共同约定 4): what a connection to `<name>.cf.24haowan.com:22022` runs. It is a
# DISPATCH, not a limit — sshd runs it as the person's own login, with their
# shell, and a command goes on exactly as it would on port 22:
#
#   a command (SSH_ORIGINAL_COMMAND: `ssh … ls`, scp / rsync, a subsystem — sftp
#     arrives as the configured sftp-server's path, the thin client's attach and
#     uploads)                     ⇒ exec "$SHELL" -c "$SSH_ORIGINAL_COMMAND"
#   no command, a terminal (SSH_TTY: a phone in Termius, plain `ssh -p 22022 …`)
#                                  ⇒ the 看台: `fleet-remote-view.sh attach --thin
#     --view <key>-<fp6> --resume [--want <last>] --device <b64> --route entry` —
#     the first screen is #3060's: the session you looked at last, else the
#     orchestrator; ⌃\ in the 看台 is the shell as always. A 看台 that cannot come
#     up (no fleet live here) says so and leaves you at the login shell.
#   no command, no terminal (`ssh -T`)
#                                  ⇒ the login shell
#
# The view id is the KEY's, not the connection's: `<its name>-<6 hex of its
# fingerprint>`, so the same phone comes back to the same 看台 (`--resume`), and
# the last session it showed is kept in $FLEET_CONF_DIR/entry/<view>.cur for when
# that 看台 has gone (FLEET_VIEW_KEEP_SECS). Which key it was comes from
# ExposeAuthInfo ($SSH_USER_AUTH); its name from the entry's book
# ($FLEET_ENTRY_BOOK, root's 0644 state.json — the hub's label for it).
#
# Each arrival is ONE line in $FLEET_CONF_DIR/logs/entry.ndjson — time, login,
# key fp, source, where it went (view · exec · sftp · shell), never the command's
# text. The door's own record (accepted / refused, by the listener's log) is the
# machine daemon's `<log>/entry.ndjson`, which also goes to the hub.
set -u
ENTRY_BIN="$(cd "$(dirname "$0")" && pwd)"
SH="${SHELL:-/bin/sh}"
[ -x "$SH" ] || SH=/bin/sh
CMD="${SSH_ORIGINAL_COMMAND-}"
C="${FLEET_CONF_DIR:-$HOME/.config/claude-fleet}"
SRC="${SSH_CONNECTION%% *}"

# the key this connection logged in with: ExposeAuthInfo's file, `publickey <type> <b64>`
entry_fp() {
  local line
  [ -n "${SSH_USER_AUTH:-}" ] && [ -r "$SSH_USER_AUTH" ] || return 0
  line=$(awk '$1 == "publickey" { print $2 " " $3; exit }' "$SSH_USER_AUTH" 2>/dev/null)
  [ -n "$line" ] || return 0
  printf '%s\n' "$line" | ssh-keygen -l -f /dev/stdin 2>/dev/null | awk '{ print $2; exit }'
}
FP="$(entry_fp)"

entry_log() {   # <how>
  mkdir -p "$C/logs" 2>/dev/null || return 0
  printf '{"ts":%s,"login":"%s","fp":"%s","src":"%s","how":"%s"}\n' \
    "$(date +%s)" "$(id -un 2>/dev/null)" "$FP" "$SRC" "$1" >> "$C/logs/entry.ndjson" 2>/dev/null || :
}

login_shell() {
  entry_log "${1:-shell}"
  cd "$HOME" 2>/dev/null || :
  exec -a "-${SH##*/}" "$SH"
}

# --- a command: exactly what port 22 does --------------------------------------
if [ -n "$CMD" ]; then
  case "$CMD" in
    */sftp-server|*/sftp-server\ *|internal-sftp|internal-sftp\ *)
      entry_log sftp
      # internal-sftp is sshd's own and cannot run under a ForceCommand: the real server
      case "$CMD" in internal-sftp*)
        for s in /usr/libexec/sftp-server /usr/lib/openssh/sftp-server /usr/libexec/openssh/sftp-server \
                 /usr/lib/ssh/sftp-server; do
          [ -x "$s" ] && exec "$s"
        done
        echo "fleet-entry: no sftp-server on this machine" >&2; exit 1 ;;
      esac ;;
    *) entry_log exec ;;
  esac
  exec "$SH" -c "$CMD"
fi

# --- no command, no terminal: the login shell ------------------------------------
[ -n "${SSH_TTY:-}" ] && [ -t 0 ] && [ -t 1 ] || login_shell shell

# --- no command, a terminal: the 看台 --------------------------------------------
VIEWER="${FLEET_ENTRY_VIEW:-$HOME/.claude/fleet/bin/fleet-remote-view.sh}"
[ -f "$VIEWER" ] || { echo "fleet-entry: 这台机器上没有你的 fleet（${VIEWER}）— 留在命令行" >&2; login_shell shell-nofleet; }
command -v tmux >/dev/null 2>&1 || PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
export PATH

# view id · device: one python3, no key text anywhere but the fingerprint
ENTRY_PY='
import base64, hashlib, json, re, sys
fp, book, login, src, host = sys.argv[1:6]
name = ""
try:
    ent = (json.load(open(book)).get("logins") or {}).get(login) or {}
    name = str((ent.get("names") or {}).get(fp) or "")
except Exception:
    pass
slug = re.sub(r"[^A-Za-z0-9]+", "-", name).strip("-")[:16].strip("-") or "key"
tail = hashlib.sha256(fp.encode()).hexdigest()[:6] if fp else "000000"
dev = {"device": name or ("key " + fp[7:15] if fp.startswith("SHA256:") else "entry"), "os": "",
       "terminal": "ssh", "via": "entry", "host": host, "caps": ["link"], "src": src}
print("e-%s-%s %s" % (slug, tail, base64.b64encode(json.dumps(dev, ensure_ascii=False, sort_keys=True).encode()).decode()))
'
OUT=$(python3 -c "$ENTRY_PY" "$FP" "${FLEET_ENTRY_BOOK:-}" "$(id -un 2>/dev/null)" "$SRC" "$(hostname -s 2>/dev/null)" 2>/dev/null)
VIEW=${OUT%% *}; DEV=${OUT#* }
case "${VIEW:-}" in ''|*[!A-Za-z0-9-]*) VIEW=e-key-000000 ;; esac
case "${DEV:-}" in ''|*[!A-Za-z0-9+/=]*) DEV=$(printf '{"via":"entry"}' | base64 | tr -d '\n') ;; esac

ROW="$C/remote-views/$VIEW"
LAST="$C/entry/$VIEW.cur"
cur_of_row() { awk -F '\t' 'NR == 1 { for (i = 6; i <= NF; i++) if (index($i, "cur=") == 1) { print substr($i, 5); exit } }' "$ROW" 2>/dev/null; }
remember() {
  local c
  c=$(cur_of_row)
  case "$c" in ''|*[!A-Za-z0-9@/:._-]*) return 0 ;; esac
  mkdir -p "$C/entry" 2>/dev/null && printf '%s\n' "$c" > "$LAST.$$" && mv -f "$LAST.$$" "$LAST" 2>/dev/null || :
}
remember                               # the row still kept from last time
WANT=$(head -n 1 "$LAST" 2>/dev/null)
case "$WANT" in *[!A-Za-z0-9@/:._-]*) WANT='' ;; esac
TOKEN=$(od -An -N8 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')

entry_log view
trap ':' HUP                           # the attach's own HUP rule runs; we still remember
cd "$HOME" 2>/dev/null || :
bash "$VIEWER" attach --thin --view "$VIEW" --resume ${WANT:+--want "$WANT"} \
  --device "$DEV" --route entry --token "${TOKEN:-0}"
rc=$?
remember
case "$rc" in
  0|129) exit 0 ;;
  1|2|3) echo "fleet-entry: 看台没起来（${rc}）— 留在命令行" >&2; login_shell shell-noview ;;
  *) exit "$rc" ;;
esac
