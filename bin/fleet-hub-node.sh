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
#   fleet-hub-node.sh env [--write [--force]] [--plist <file>]
#                                → this login's node token file (issue #1491; the
#                                  one subcommand meant to be run by hand — see below)
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

# --- env: this login's node token file (issue #1491) -----------------------------
# `ccquota lease|place|move` act as this machine's agent and need its token.
# fleet-node-join.sh writes it to $FLEET_CONF_DIR/node.env (0600) at join, and
# fleet_hub_* (bin/fleet-lib.sh) read it per call. A login whose agent predates
# that keeps the token ONLY in its launchd service's EnvironmentVariables
# (docs/SHARED-MACHINE.md step 4), so every hub call from its fleet panes exited 1
# 「no hub configured」 and fell back silently. `env` reports; `env --write` fills
# node.env once from the service definition:
#   ~/Library/LaunchAgents/com.ccquota.agent.plist              (gui LaunchAgent)
#   <daemon dir>/com.ccquota.agent.<login>.plist                (system LaunchDaemon;
#       read through `sudo -n` when this login cannot read it)
#   --plist <file>                                              (anything else)
# Every CCQUOTA_* string in the plist's EnvironmentVariables is copied (hub URL and
# token first), mode 0600, written whole or not at all; a VALUE is never printed.
# Exit: 0 present / written / already there (`--force` rewrites) · 1 missing and no
# service definition found (the line says where it looked) · 3 the definition
# carries no CCQUOTA_TOKEN · 2 usage · 75 python3 missing.
# Seams: FLEET_HUB_NODE_SUDO (default `sudo -n`; empty = none),
# FLEET_HUB_NODE_DAEMON_DIR (default /Library/LaunchDaemons).
node_env() {
  local write=0 force=0 plist='' f mode gr ot sudo ddir me cand src got keys rc
  while [ $# -gt 0 ]; do
    case "$1" in
      --write) write=1 ;;
      --force) force=1 ;;
      --plist) plist="${2:-}"; [ -n "$plist" ] || die 2 "--plist needs a file"; shift ;;
      *) die 2 "usage: fleet-hub-node.sh env [--write [--force]] [--plist <file>]" ;;
    esac
    shift
  done
  f=$(fleet_node_env_file)
  if [ -f "$f" ] && [ -n "$(_fleet_node_env_val CCQUOTA_TOKEN)" ]; then
    # ls -ld perms: char 5 = group-read, char 8 = other-read (fleet-doctor's check)
    mode=$(ls -ld "$f" 2>/dev/null | cut -c1-10); gr=$(printf '%s' "$mode" | cut -c5); ot=$(printf '%s' "$mode" | cut -c8)
    if [ "$gr" = r ] || [ "$ot" = r ]; then
      printf 'node.env: present but group/other-readable (%s) — chmod 600 %s\n' "$mode" "$f"
    elif [ "$write" = 1 ] && [ "$force" = 0 ]; then
      printf 'node.env: already present (%s) — --force rewrites it from the service definition\n' "$f"
    else
      [ "$write" = 1 ] || { printf 'node.env: present (%s, 0600) — ccquota lease / place / move read it per call\n' "$f"; return 0; }
    fi
    [ "$write" = 1 ] && [ "$force" = 1 ] || return 0
  elif [ "$write" = 0 ]; then
    if [ -f "$f" ]; then printf 'node.env: present but has no CCQUOTA_TOKEN= line (%s) — `fleet-hub-node.sh env --write --force` rewrites it from this login'"'"'s agent service\n' "$f"
    else printf 'node.env: missing (%s) — `fleet-hub-node.sh env --write` fills it from this login'"'"'s agent service; fleet_hub_lease / place / move fall back without it\n' "$f"; fi
    return 1
  fi
  command -v python3 >/dev/null 2>&1 || die 75 "python3 is missing"
  sudo="${FLEET_HUB_NODE_SUDO-sudo -n}"
  ddir="${FLEET_HUB_NODE_DAEMON_DIR:-/Library/LaunchDaemons}"
  me=$(id -un)
  # Candidates, in order; the first that exists is the source.
  if [ -n "$plist" ]; then set -- "$plist"
  else set -- "$HOME/Library/LaunchAgents/com.ccquota.agent.plist" "$ddir/com.ccquota.agent.$me.plist"; fi
  src=''
  for cand in "$@"; do
    if [ -r "$cand" ]; then src=$cand; break; fi
    # A file this login cannot even stat (a root-owned daemon dir, a 0600 plist
    # handed over): ask through sudo -n, never a password prompt.
    # shellcheck disable=SC2086
    if [ -n "$sudo" ] && $sudo test -r "$cand" 2>/dev/null; then src=$cand; break; fi
  done
  if [ -z "$src" ]; then
    printf 'node.env: missing (%s) and no agent service definition to fill it from — looked for %s; pass --plist <file>, or re-join with fleet-node-join.sh\n' "$f" "$*"
    return 1
  fi
  mkdir -p "$(dirname "$f")" || die 1 "cannot create $(dirname "$f")"
  # The plist bytes go straight into python on stdin (plistlib reads XML and
  # binary); python writes node.env itself under 0600 and prints only the KEY
  # NAMES it copied.
  prog=$(cat <<'PY'
import os, plistlib, sys
out, src = sys.argv[1], sys.argv[2]
try:
    p = plistlib.loads(sys.stdin.buffer.read())
except Exception as e:  # noqa: BLE001 — one line, no traceback
    sys.exit("not a plist: %s" % e)
env = p.get("EnvironmentVariables") if isinstance(p, dict) else None
if not isinstance(env, dict):
    sys.exit("no EnvironmentVariables dict")
keys = [k for k in env if k.startswith("CCQUOTA_") and isinstance(env[k], str) and env[k] != ""]
if "CCQUOTA_TOKEN" not in keys:
    print("no-token"); sys.exit(3)
order = ["CCQUOTA_HUB_URL", "CCQUOTA_TOKEN"] + sorted(k for k in keys if k not in ("CCQUOTA_HUB_URL", "CCQUOTA_TOKEN"))
order = [k for k in order if k in keys]
tmp = out + ".tmp"
fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, "w", encoding="utf-8") as fh:
    fh.write("# claude-fleet fleet-hub-node env --write (issue #1491) from %s — this login's ccquota agent. Holds a credential: 0600.\n" % src)
    for k in order:
        v = env[k].replace("\n", "")
        fh.write("%s=%s\n" % (k, v))
os.chmod(tmp, 0o600)
os.replace(tmp, out)
print(" ".join(order))
PY
)
  if [ -r "$src" ]; then got=$(python3 -c "$prog" "$f" "$src" < "$src"); rc=$?
  else
    # shellcheck disable=SC2086
    got=$($sudo cat "$src" 2>/dev/null | python3 -c "$prog" "$f" "$src"); rc=$?
  fi
  case "$rc" in
    0) printf 'node.env: written from %s — keys: %s (%s, 0600)\n' "$src" "$got" "$f"; return 0 ;;
    3) printf 'node.env: %s carries no CCQUOTA_TOKEN in EnvironmentVariables — nothing written\n' "$src"; return 3 ;;
    *) die 1 "cannot read $src: ${got:-python3 failed}" ;;
  esac
}

case "${1:-}" in
  paths)
    printf 'outbox\t%s\nworkers\t%s\nmovein\t%s\n' "$(fleet_hub_outbox)" "$(fleet_hub_cache)" "$(fleet_hub_movein)"
    exit 0 ;;
  env) shift; node_env "$@"; exit $? ;;
  deliver) ;;
  *) die 2 "usage: fleet-hub-node.sh paths | deliver < relay.json | env [--write [--force]] [--plist <file>]" ;;
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
