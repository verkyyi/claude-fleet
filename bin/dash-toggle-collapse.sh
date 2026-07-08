#!/bin/bash
# dash-toggle-collapse.sh "<milestone>" — toggle a milestone's collapsed state
# in $C/collapsed (one milestone name per line). Used by the backlog roadmap panel.
set -uo pipefail
C="${TMPDIR:-/tmp}/.claude-dash"; f="$C/collapsed"; m="$*"
[ -z "$m" ] && exit 0
touch "$f"
if grep -qxF "$m" "$f"; then grep -vxF "$m" "$f" > "$f.tmp" && mv "$f.tmp" "$f"
else printf '%s\n' "$m" >> "$f"; fi
