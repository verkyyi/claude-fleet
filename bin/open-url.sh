#!/bin/sh
# open-url.sh <url> — open a URL on the machine you're SSHing FROM (not here).
#
# 1) Tunnel mode (instant, zero clicks): if the reverse-forwarded opener port
#    is live, send the URL through it — a tiny listener on your laptop runs
#    `open <url>` in your local browser. One-time setup on the LAPTOP:
#      ~/.ssh/config →  Host macmini
#                         RemoteForward 2226 127.0.0.1:2226
#      listener      →  run extras/laptop-url-opener.sh from this repo
# 2) Fallback (no tunnel): tmux popup with the URL — cmd-clickable in iTerm —
#    and OSC52-copied to your LOCAL clipboard (needs tmux set-clipboard on).
set -u  # POSIX sh: pipefail is bash-only (dash has none)
url="${1:-}"; [ -z "$url" ] && exit 0
PORT="${URL_OPENER_PORT:-2226}"

# try the tunnel directly — a probe would consume the listener's accept
if printf '%s\n' "$url" | nc 127.0.0.1 "$PORT" 2>/dev/null; then
  exit 0
fi

# fallback: clickable popup + local clipboard via OSC52
f=$(mktemp "${TMPDIR:-/tmp}/openurl.XXXXXX"); printf '%s' "$url" > "$f"
tmux display-popup -w 80% -h 8 -E "
  url=\$(cat '$f'); rm -f '$f'
  b64=\$(printf '%s' \"\$url\" | base64 | tr -d '\n')
  printf '\033]52;c;%s\a' \"\$b64\"
  printf '\n  \033[1;36m%s\033[0m\n\n  cmd-click to open — also copied to your local clipboard.\n  (set up the ssh RemoteForward opener to skip this popup; see open-url.sh)\n\n  Enter to close.' \"\$url\"
  read _dummy" 2>/dev/null || { rm -f "$f"; printf '%s\n' "$url"; }
