#!/bin/sh
# open-url.sh <url> — open a URL on the machine you're SSHing FROM (not here).
#
# 1) Tunnel mode (instant, zero clicks): if the reverse-forwarded opener port
#    is live, send the URL through it — a tiny listener on your laptop runs
#    `open <url>` in your local browser. One-time setup on the LAPTOP:
#      ~/.ssh/config →  Host macmini
#                         RemoteForward 2226 127.0.0.1:2226
#      listener      →  run extras/laptop-url-opener.sh from this repo
# 2) Fallback (no tunnel): the URL copied to your LOCAL clipboard (OSC 52, needs
#    tmux set-clipboard on) and shown on one line — never a popup (issue #1620).
# OPEN_URL_REPORT=1 prints which one happened as the last stdout line —
# `sent:tunnel` or `fallback:copied` (bin/fleet-open.sh's fallback, issue #1379).
set -u  # POSIX sh: pipefail is bash-only (dash has none)
url="${1:-}"; [ -z "$url" ] && exit 0
BIN="$(cd "$(dirname "$0")" && pwd)"
PORT="${URL_OPENER_PORT:-2226}"

# try the tunnel directly — a probe would consume the listener's accept
if printf '%s\n' "$url" | nc 127.0.0.1 "$PORT" 2>/dev/null; then
  [ "${OPEN_URL_REPORT:-0}" = 1 ] && echo 'sent:tunnel'
  exit 0
fi

# fallback: the URL on their LOCAL clipboard (tmux set-buffer -w → OSC 52, needs
# tmux set-clipboard on) and one line saying so — no popup (issue #1620: a box to
# read a link off was one more thing over the session). Outside tmux, the
# terminal it runs in gets the OSC 52 and the URL itself, cmd-clickable in iTerm.
# The URL is only ever an argument, never shell code.
if [ -n "${TMUX:-}" ] && tmux set-buffer -w -- "$url" 2>/dev/null; then
  tmux display-message "$(sh "$BIN/fleet-ui-lang.sh" t toast_url_copied_fmt "$url" | sed 's/#/##/g')" 2>/dev/null || :
else
  b64=$(printf '%s' "$url" | base64 | tr -d '\n')
  printf '\033]52;c;%s\a%s\n' "$b64" "$url"
fi
[ "${OPEN_URL_REPORT:-0}" = 1 ] && echo 'fallback:copied'
exit 0
