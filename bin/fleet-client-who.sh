#!/usr/bin/env bash
# fleet-client-who.sh — `fleet status`'s who line (issue #2577): which person is
# signed in, from which computer and login here, and which machine logins the
# certificate opens. Plain text, one line. (It was the old client's bar badge's
# `--who`, fleet-client-badge.sh — the bar went with that client, issue #3008.)
#
# The person is the GitHub login `fleet login` keeps in ${FLEET_CERT:-~/.ssh/fleet-cert}-who
# (<key id>\t<login>), read only while its key id is the certificate's own
# (`ssh-keygen -L`); `?` when none is known. The machine logins are the
# certificate's principals.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
. "$BIN/fleet-ui-lang.sh"

CRT=${FLEET_CERT:-$HOME/.ssh/fleet-cert}
# the GitHub login recorded beside the certificate — nothing when none is known
gh_login() {
  local kid
  kid=$(ssh-keygen -L -f "$CRT-cert.pub" 2>/dev/null \
    | sed -n 's/^[[:space:]]*Key ID: "\(.*\)"[[:space:]]*$/\1/p' | head -n 1)
  [ -n "$kid" ] && [ -r "$CRT-who" ] || return 0
  awk -F '\t' -v k="$kid" '$1 == k && $2 != "" { print $2; exit }' "$CRT-who" 2>/dev/null
}
# the certificate's principals, one a line (`Principals:` then one indented line each)
cert_principals() {
  ssh-keygen -L -f "$CRT-cert.pub" 2>/dev/null \
    | awk '/^[[:space:]]*Principals:/ { p = 1; next } p && /^[[:space:]]+[^[:space:]]/ && !/:/ { gsub(/^[[:space:]]+|[[:space:]]+$/, ""); print; next } p { exit }'
}

gh=$(gh_login)
ml=$(cert_principals | paste -sd ',' - | sed 's/,/, /g')
fleet_ui_t client_who_fmt "${gh:-?}" "$(hostname -s 2>/dev/null || hostname)" "$(id -un 2>/dev/null)" "${ml:--}"
echo
