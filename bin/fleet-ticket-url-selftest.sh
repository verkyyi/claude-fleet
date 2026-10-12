#!/bin/bash
# fleet-ticket-url-selftest.sh — where a ticket number opens (issue #3596, EPIC #3570
# C3): fleet_ticket_url (bin/fleet-lib.sh), the ONE reader, and its python front
# bin/fleet_ticket_url.py (the sidebar's ⌘P list, the top bar, `fleet ls`), in a
# sandbox FLEET_CONF_DIR:
#   A. a repo whose tickets are on GitHub (no FLEET_TICKETS, or =github) → its GitHub
#      page, byte for byte the link the callers spelled before — shell and python.
#   B. a repo with FLEET_TICKETS=hub → <hub>/fleet/tickets/<repo>/<N>; the hub
#      address from the environment, else fleet.conf's FLEET_HUB_URL.
#   C. a hub repo on a computer with no hub address → nothing, rc 1 (never a GitHub
#      page that is not there); python "".
#   D. no fleet at all (a client-only computer) → the GitHub page, python with no
#      shell started.
#   E. putting one repo's tickets on the hub changes nothing for another repo of
#      the same fleet (CLAUDE.md's rule (n)).
#   F. a bad repo / number → rc 2, nothing printed.
#   G. the callers ask it: no `github.com/%s/issues/%s` left in quickopen, the top
#      bar, session-cli or the pane menu.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/fleet-ticket-url-selftest.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT
fails=0
ok()   { printf 'ok   %s\n' "$1"; }
bad()  { printf 'FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '     %s\n' "$2"; fails=$((fails + 1)); }
same() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "want [$3] got [$2]"; fi; }

export FLEET_CONF_DIR="$WORK/conf" HOME="$WORK/home"
unset FLEET_HUB_URL CCQUOTA_HUB_URL FLEET_SESSION FLEET_TICKETS TMUX TMUX_PANE
mkdir -p "$HOME" "$FLEET_CONF_DIR"

url()  { ( . "$BIN/fleet-lib.sh" >/dev/null 2>&1; fleet_ticket_url "$@" ); }
pyurl() { python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import fleet_ticket_url as F; print(F.ticket_url(*sys.argv[2:]))' "$BIN" "$@"; }

# D — nothing here at all
same 'D shell: no fleet → GitHub' "$(url o/a 7)" 'https://github.com/o/a/issues/7'
same 'D python: no fleet → GitHub' "$(pyurl o/a 7)" 'https://github.com/o/a/issues/7'

# a fleet `f` hosting o/a and o/b, every repo as today
mkdir -p "$FLEET_CONF_DIR/fleets/f/repos"
: > "$FLEET_CONF_DIR/fleets/f/conf"
printf 'FLEET_REPO="o/a"\nFLEET_MAIN="%s/a"\n' "$WORK" > "$FLEET_CONF_DIR/fleets/f/repos/o-a.conf"
printf 'FLEET_REPO="o/b"\nFLEET_MAIN="%s/b"\nFLEET_TICKETS=github\n' "$WORK" > "$FLEET_CONF_DIR/fleets/f/repos/o-b.conf"
printf 'o/a\no/b\n' > "$FLEET_CONF_DIR/fleets/f/repos/.order"
before_a=$(url o/a 12 f); before_b=$(url o/b 3)

# A
same 'A shell: no FLEET_TICKETS → GitHub' "$before_a" 'https://github.com/o/a/issues/12'
same 'A shell: FLEET_TICKETS=github → GitHub' "$before_b" 'https://github.com/o/b/issues/3'
same 'A python: GitHub repo' "$(pyurl o/a 12 f)" 'https://github.com/o/a/issues/12'

# B / C — o/a's tickets move to the hub
printf 'FLEET_TICKETS=hub\n' >> "$FLEET_CONF_DIR/fleets/f/repos/o-a.conf"
out=$(url o/a 12 f); rc=$?
[ -z "$out" ] && [ "$rc" = 1 ] && ok 'C shell: hub repo, no hub address → nothing, rc 1' || bad 'C shell: no hub address' "rc=$rc out=[$out]"
same 'C python: no hub address → ""' "$(pyurl o/a 12 f)" ''
printf '[common]\nFLEET_HUB_URL="https://hub.example/"\n' > "$FLEET_CONF_DIR/fleet.conf"
same 'B shell: fleet.conf hub address' "$(url o/a 12 f)" 'https://hub.example/fleet/tickets/o/a/12'
same 'B shell: the fleet found without a session' "$(url o/a 12)" 'https://hub.example/fleet/tickets/o/a/12'
same 'B shell: environment wins' "$(FLEET_HUB_URL=http://127.0.0.1:8080 url o/a 1 f)" 'http://127.0.0.1:8080/fleet/tickets/o/a/1'
same 'B python: hub repo' "$(pyurl o/a 12)" 'https://hub.example/fleet/tickets/o/a/12'

# E
same 'E shell: o/b untouched by o/a moving' "$(url o/b 3)" "$before_b"
same 'E python: o/b untouched' "$(pyurl o/b 3)" "$before_b"

# F
for a in 'o 7' 'o/a 0' 'o/a 07' 'o/a x' 'o/a '; do
  # shellcheck disable=SC2086
  out=$(url $a); rc=$?
  [ -z "$out" ] && [ "$rc" = 2 ] && ok "F shell: bad args [$a] → rc 2" || bad "F shell: bad args [$a]" "rc=$rc out=[$out]"
done
same 'F python: bad number → ""' "$(pyurl o/a 0)" ''

# G
left=$(grep -n 'github\.com/%s/issues/%s\|github\.com/\$repo/issues/' "$BIN/fleet-quickopen.py" "$BIN/fleet-topbar.py" \
         "$BIN/fleet-session-cli.py" "$BIN/fleet-human-menu.sh" 2>/dev/null)
[ -z "$left" ] && ok 'G every caller asks the reader' || bad 'G a caller still spells the GitHub link' "$left"

[ "$fails" = 0 ] && { printf 'fleet-ticket-url-selftest: PASS\n'; exit 0; }
printf 'fleet-ticket-url-selftest: %s FAILED\n' "$fails"; exit 1
