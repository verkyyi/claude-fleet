#!/bin/bash
# Delegated reports use the existing peer queue and hub outbox. No timer,
# parent mutation, successor lookup, user fallback or task acceptance here.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
. "$BIN/fleet-lib.sh"
act=${1:-} file=${2:-}
[ -f "$file" ] || exit 2
fields=$(python3 - "$file" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
# drain receives a peer queue item; receiver gets the sealed report itself.
p = d.get('delegation') or d
r = p['report_delegation']
for value in (r['reporter'], r['target'], p['rid']):
    print(value)
PY
) || exit 1
{ read -r reporter; read -r recipient; read -r rid; } <<< "$fields"

if [ "$act" = _local ]; then
  home=$(fleet_wid_home "wid:$recipient") || exit 75
  sock=$(fleet_socket "$home")
  win=$(fleet_win_for_fid "${recipient#*/}" "$sock" 2>/dev/null) || exit 75
  [ -n "$win" ] || exit 75
  # Resolve by the exact identity again immediately before invoking the adapter.
  [ "$(tmux -L "$sock" display-message -p -t "$win" '#{@fleet_id}' 2>/dev/null)" = "${recipient#*/}" ] || exit 75
  msg=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["msg"])' "$file") || exit 1
  fleet_agent_deliver "$win" "$sock" "$msg" fleet-report
  rc=$?; [ "$rc" = 0 ] && exit 0
  exit 75
fi
[ "$act" = drain ] || exit 2
sess=${3:-}
[ -n "$sess" ] || exit 2
fleet_load_conf "$sess"
payload=$(python3 -c 'import json,sys; print(json.dumps(json.load(open(sys.argv[1]))["delegation"]))' "$file") || exit 1
if fleet_wid_home "wid:$recipient" >/dev/null 2>&1; then
  tmp=$(mktemp "${TMPDIR:-/tmp}/fleet-report-delivery.XXXXXX") || exit 1
  trap 'rm -f "$tmp"' EXIT
  printf '%s' "$payload" > "$tmp"
  python3 "$BIN/fleet_report_delegation.py" deliver "$tmp"
  exit $?
fi
# A receipt is the only completion authority. A refused/expired relay stays in
# the peer queue for operator repair; it never becomes a reminder for the person.
if bash "$BIN/fleet-peer-queue.sh" wait -L "$sess" --rid "$rid" --secs 0 >/dev/null 2>&1; then exit 0; fi
# One outbox filename per report: a disconnected hub does not accumulate copies.
outbox=$(fleet_hub_outbox)
name="delegated-${rid##*#}.json"
if [ ! -f "$outbox/$name" ]; then
  # A durable drain acts as the authenticated node, not as whichever worker
  # happened to trigger this pass; its assertion may belong to a different item.
  queued=$(FLEET_WORKER_ASSERT='' fleet_hub_put child_report "$reporter" "$recipient" "${rid##*#}" "$payload") || exit 75
  mv -f "$queued" "$outbox/$name" || exit 75
fi
exit 75
