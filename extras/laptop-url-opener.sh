#!/bin/sh
# laptop-url-opener.sh — run this on your LAPTOP (the machine you ssh FROM).
# Listens on localhost:2226; every line it receives is opened in your default
# browser. Pair with this in your laptop's ~/.ssh/config:
#
#   Host macmini            # or whatever host you ssh to
#     RemoteForward 2226 127.0.0.1:2226
#
# Then anything on the remote host can `printf '%s\n' "$url" | nc 127.0.0.1 2226`
# (that's what open-url.sh does) and it opens HERE. Localhost-only on both ends.
#
# Run ad hoc:      sh laptop-url-opener.sh
# Or keep-alive:   put it in a launchd agent / login item.
set -u  # POSIX sh: pipefail is bash-only (dash has none)
PORT="${URL_OPENER_PORT:-2226}"
echo "url-opener: listening on 127.0.0.1:$PORT (ctrl-c to stop)"
while :; do
  nc -l 127.0.0.1 "$PORT" 2>/dev/null | while IFS= read -r url; do
    case "$url" in
      http://*|https://*) echo "open: $url"; open "$url" 2>/dev/null || xdg-open "$url" 2>/dev/null ;;
      *) echo "ignored (not a URL): $url" ;;
    esac
  done
  sleep 0.1
done
