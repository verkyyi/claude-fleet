#!/bin/bash
# fleet-hub-node.sh — this machine's half of cross-machine relays (issue #1421,
# EPIC #1419 C2). Driven by the ccquota agent (tokenledger/internal/agent/
# relay.go); not meant to be run by hand.
#
#   fleet-hub-node.sh paths      → `outbox\t<dir>`, `workers\t<file>` and
#                                  `movein\t<dir>`: where the agent picks up relays,
#                                  writes the worker map, and downloads a session
#                                  moved here through the hub (issue #1426)
#   fleet-hub-node.sh deliver    (a relay the hub pushed, JSON on stdin) → apply it
#
# A worker's parent, or the worker a message is for, may live on another machine.
# The sending side drops a relay in the outbox (fleet_hub_put, bin/fleet-lib.sh);
# the agent hands it to the hub, which stores it and pushes it down the TARGET
# machine's control channel; that machine's agent runs `deliver` with it:
#
#   child_report  {child, state, pr, verdict, summary, title, tier, msg}
#                 → appended to the PARENT's ledger here (children_append's file,
#                   plus `node` = the child's machine and `rid` = the relay id, so a
#                   redelivery is a no-op), then delivered to the parent exactly as a
#                   local report would be: tier silent = ledger only; batch mode =
#                   the digest's (a loud one flushes now); else `msg` — the envelope
#                   the child built — into the parent's pane (children_send).
#   message       {text} → fleet-peer-send.sh to the target worker, with one
#                 `[from <key> on <node>]` line in front so it knows who to answer.
#
# Exit: 0 applied (or already applied) · 75 not now, push it again later · anything
# else refused for good (the reason on stderr's last line). Never touches a window
# that is not the relay's target: the target is a worker_id of a fleet on THIS
# machine (fleet_wid_home), or the relay is refused.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
. "$BIN/fleet-lib.sh"

die() { printf 'fleet-hub-node: %s\n' "$2" >&2; exit "$1"; }

case "${1:-}" in
  paths)
    printf 'outbox\t%s\nworkers\t%s\nmovein\t%s\n' "$(fleet_hub_outbox)" "$(fleet_hub_cache)" "$(fleet_hub_movein)"
    exit 0 ;;
  deliver) ;;
  *) die 2 "usage: fleet-hub-node.sh paths | deliver < relay.json" ;;
esac

command -v python3 >/dev/null 2>&1 || die 75 "python3 is missing"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/fleet-hub-node.XXXXXX") || die 75 "no temp dir"
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/in"
# One parse: the scalar fields as lines (each checked against its charset), the
# free-text parts into files — never through the shell's word splitting.
fields=$(python3 - "$WORK" 2>&1 <<'PY'
import json, os, re, sys
work = sys.argv[1]
try:
    r = json.load(open(os.path.join(work, "in"), encoding="utf-8"))
except ValueError:
    sys.exit("relay is not JSON")
if not isinstance(r, dict) or not isinstance(r.get("payload"), dict):
    sys.exit("relay has no payload object")
wid = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/"
                 r"([A-Za-z0-9][A-Za-z0-9._-]{0,127}:)?(issue|scratch)-[1-9][0-9]{0,9}$")
rid, kind, frm, to = (str(r.get(k) or "") for k in ("id", "kind", "from", "to"))
node = re.sub(r"[^A-Za-z0-9._-]", "", str(r.get("from_node") or ""))[:64]
if kind not in ("child_report", "message"):
    sys.exit("unknown relay kind %r" % kind)
if not wid.match(frm) or not wid.match(to):
    sys.exit("from/to is not a worker_id")
if not rid.startswith(frm + "#") or not re.match(r"^[A-Za-z0-9._-]{1,64}$", rid[len(frm) + 1:]):
    sys.exit("bad relay id")
p = r["payload"]
if kind == "child_report":
    row = {k: p.get(k, "") for k in ("child", "state", "pr", "verdict", "summary", "title", "tier")}
    row.update(node=node or "?", rid=rid)
    open(os.path.join(work, "row"), "w").write(json.dumps(row, ensure_ascii=False))
    open(os.path.join(work, "msg"), "w").write(str(p.get("msg") or ""))
    tier = str(p.get("tier") or "")
else:
    text = str(p.get("text") or "")
    if not text.strip():
        sys.exit("empty message")
    open(os.path.join(work, "msg"), "w").write(text)
    tier = ""
for v in (kind, frm, to, node, tier):
    print(v)
PY
) || die 1 "${fields##*$'\n'}"
{ read -r KIND; read -r FROM; read -r TO; read -r NODE; read -r TIER; } <<EOF
$fields
EOF

home=$(fleet_wid_home "wid:$TO") || die 1 "target $TO is not a fleet on this machine"
sock=$(fleet_socket "$home")
pkey=${TO#*/}
fkey=${FROM#*/}

if [ "$KIND" = message ]; then
  text="[from $fkey on ${NODE:-another machine}]"$'\n'"$(cat "$WORK/msg")"
  out=$(env -u TMUX bash "$BIN/fleet-peer-send.sh" -L "$sock" "wid:$TO" "$text" 2>&1); rc=$?
  case "$rc" in
    0) printf '%s\n' "$out" >&2; exit 0 ;;
    1) die 1 "${out##*$'\n'}" ;;           # no such live worker here: for good
    *) die 75 "${out##*$'\n'}" ;;
  esac
fi

# --- child_report ----------------------------------------------------------------
fleet_load_conf "$home"
# shellcheck source=/dev/null
. "$BIN/fleet-children-lib.sh"
lf=$(children_file "$pkey" "$home") || die 1 "no ledger for parent $pkey"
res=$(python3 "$BIN/fleet-children.py" append --file "$lf" < "$WORK/row" 2>&1) || die 1 "ledger refused it: ${res##*$'\n'}"
case "$res" in dup*) printf 'fleet-hub-node: %s already in %s ledger\n' "$fkey" "$pkey" >&2; exit 0 ;; esac

[ "$TIER" = silent ] && exit 0
MODE=$(children_report_mode)
[ "$MODE" = 0 ] && exit 0
if [ "$MODE" = batch ]; then
  [ "$TIER" = loud ] && [ -f "$BIN/fleet-children-flush.sh" ] \
    && bash "$BIN/fleet-children-flush.sh" -L "$sock" --parent "$pkey" >/dev/null 2>&1
  exit 0
fi
pwin=$(fleet_win_for_key "$pkey" "$sock") || pwin=''
[ -n "$pwin" ] || { printf 'fleet-hub-node: parent %s has no window here — ledgered only\n' "$pkey" >&2; exit 0; }
[ -s "$WORK/msg" ] || exit 0
if children_send "$home" "$sock" "$pwin" "$(cat "$WORK/msg")"; then
  children_cursor_set "$pkey" "$home"
  printf 'reported → %s (%s) from %s on %s\n' "$pkey" "$pwin" "$fkey" "${NODE:-?}" >&2
else
  printf 'fleet-hub-node: parent %s (%s) has no reachable inbox — ledgered only\n' "$pkey" "$pwin" >&2
fi
exit 0
