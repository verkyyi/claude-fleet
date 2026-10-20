#!/bin/bash
# fleet-ticket-url-selftest.sh — where an issue number opens (issue #3596):
# fleet_ticket_url (bin/fleet-lib.sh) and its python front bin/fleet_ticket_url.py
# (the sidebar's ⌘P list, the top bar, `fleet ls`) answer the GitHub page — the hub
# ticket pages left with issue #4898 — in a sandbox FLEET_CONF_DIR:
#   A. the GitHub page, byte for byte the link the callers spelled before — shell
#      and python; an old overlay still saying FLEET_TICKETS=hub changes nothing.
#   F. a bad repo / number → rc 2, nothing printed; python "".
#   G. the callers ask it: no `github.com/%s/issues/%s` left in quickopen, the top
#      bar, session-cli or the pane menu.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
. "$BIN/selftest-lib.sh"
st_sandbox "${TMPDIR:-/tmp}/fleet-ticket-url-selftest.XXXXXX"
fails=0
bad()  { printf 'FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '     %s\n' "$2"; fails=$((fails + 1)); }
same() { if [ "$2" = "$3" ]; then st_ok "$1"; else bad "$1" "want [$3] got [$2]"; fi; }

export FLEET_CONF_DIR="$WORK/conf" HOME="$WORK/home"
unset FLEET_HUB_URL CCQUOTA_HUB_URL FLEET_SESSION FLEET_TICKETS TMUX TMUX_PANE
mkdir -p "$HOME" "$FLEET_CONF_DIR"

url()  { ( . "$BIN/fleet-lib.sh" >/dev/null 2>&1; fleet_ticket_url "$@" ); }
pyurl() { python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import fleet_ticket_url as F; print(F.ticket_url(*sys.argv[2:]))' "$BIN" "$@"; }

same 'A shell: GitHub' "$(url o/a 7)" 'https://github.com/o/a/issues/7'
same 'A python: GitHub' "$(pyurl o/a 7)" 'https://github.com/o/a/issues/7'
mkdir -p "$FLEET_CONF_DIR/fleets/f/repos"
: > "$FLEET_CONF_DIR/fleets/f/conf"
printf 'FLEET_REPO="o/a"\nFLEET_MAIN="%s/a"\nFLEET_TICKETS=hub\n' "$WORK" > "$FLEET_CONF_DIR/fleets/f/repos/o-a.conf"
printf 'o/a\n' > "$FLEET_CONF_DIR/fleets/f/repos/.order"
printf '[common]\nFLEET_HUB_URL="https://hub.example/"\n' > "$FLEET_CONF_DIR/fleet.conf"
same 'A shell: an old FLEET_TICKETS=hub overlay is read by nothing' "$(url o/a 12 f)" 'https://github.com/o/a/issues/12'
same 'A python: the same' "$(pyurl o/a 12 f)" 'https://github.com/o/a/issues/12'

for a in 'o 7' 'o/a 0' 'o/a 07' 'o/a x' 'o/a '; do
  # shellcheck disable=SC2086
  out=$(url $a); rc=$?
  [ -z "$out" ] && [ "$rc" = 2 ] && st_ok "F shell: bad args [$a] → rc 2" || bad "F shell: bad args [$a]" "rc=$rc out=[$out]"
done
same 'F python: bad number → ""' "$(pyurl o/a 0)" ''

left=$(grep -n 'github\.com/%s/issues/%s\|github\.com/\$repo/issues/' "$BIN/fleet-quickopen.py" "$BIN/fleet-topbar.py" \
         "$BIN/fleet-session-cli.py" "$BIN/fleet-human-menu.sh" 2>/dev/null)
[ -z "$left" ] && st_ok 'G every caller asks the reader' || bad 'G a caller still spells the GitHub link' "$left"

[ "$fails" = 0 ] || { printf 'fleet-ticket-url-selftest: %d failed\n' "$fails"; exit 1; }
echo 'fleet-ticket-url-selftest: ok'
