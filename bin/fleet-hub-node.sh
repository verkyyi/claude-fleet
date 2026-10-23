#!/bin/bash
# fleet-hub-node.sh — this machine's half of cross-machine relays (issue #1421,
# EPIC #1419 C2). Driven by the ccquota agent (tokenledger/agent/
# relay.go); not meant to be run by hand.
#
#   fleet-hub-node.sh paths      → `outbox\t<dir>`, `workers\t<file>` and
#                                  `movein\t<dir>`: where the agent picks up relays,
#                                  writes the worker map, and downloads a session
#                                  moved here through the hub (issue #1426)
#   fleet-hub-node.sh deliver    (a relay the hub pushed, JSON on stdin) → apply it
#   fleet-hub-node.sh execution-sync → import this login's authoritative stops
#                                  on reconnect; never grants execution authority
#   fleet-hub-node.sh env [--write [--force]] [--plist <file>]
#                                → this login's node token file (issue #1491; the
#                                  one subcommand meant to be run by hand — see below)
#   fleet-hub-node.sh progress → compatibility no-op (one version)
#
# message relays keep their ordinary routing, recipient checks, and receipts.
# child_report is permanently refused before routing or writing any ledger.
# Exit: 0 applied/queued · 75 ordinary message retry · 1 permanent refusal.
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
# (docs/dev/SHARED-MACHINE.md step 4), so every hub call from its fleet panes exited 1
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
  local write=0 force=0 plist='' f mode gr ot sudo ddir me cand src got rc
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
    # test (issue #2505): this claude-fleet marks the test identity's scratch —
    # the agent lists CapTestIdentity, and only then does the hub send `test`;
    # task (issue #3325): it takes the hub's task record on a start — the agent
    # lists CapTask, and only then does the hub send it
    printf 'outbox\t%s\nworkers\t%s\nmovein\t%s\nattach\t%s\ntest\t1\ntask\t1\nlaunch_v1\t1\nrepo_authority_v1\t1\nrepo_authority_sync\t1\nexecution_sync\t1\nexecution_exit_retry\t1\n' "$(fleet_hub_outbox)" "$(fleet_hub_cache)" "$(fleet_hub_movein)" "$(fleet_hub_attach)"
    exit 0 ;;
  # The task-receipt journal is retired with the launch proof (EPIC T497 C8):
  # nothing to replay, nothing to report. compat-1v: 下一批删 — an older agent
  # that still asks.
  replay|recovery) exit 0 ;;
  # The hub's word that this login's person's authority moved (issues #4730,
  # #4901 — sent once per repo a host hosts): fleet.conf [node] re-reads it,
  # the mode from the hub's gate read; the repo is only the push's label.
  # No repo = a host that hosts none yet (T490): the person's mode all the same.
  authority-sync) if [ -n "${2:-}" ]; then exec python3 "$BIN/fleet_repo_authority.py" "$2" --sync; fi
    exec python3 "$BIN/fleet_repo_authority.py" --sync ;;
  execution-sync) [ "$#" -eq 1 ] || die 2 "execution-sync takes no arguments"
    exec python3 "$BIN/fleet_task_execution.py" sync-stops ;;
  execution-exit-retry) [ "$#" -eq 1 ] || die 2 "execution-exit-retry takes no arguments"
    exec python3 "$BIN/fleet-control.py" retry-native-exits ;;
  env) shift; node_env "$@"; exit $? ;;
  # compat-1v: 下一批删 — progress pulling retired; old ticks do nothing.
  progress) exit 0 ;;
  deliver) ;;
  *) die 2 "usage: fleet-hub-node.sh paths | execution-sync | execution-exit-retry | deliver < relay.json | env [--write [--force]] [--plist <file>] | progress [--max-age S]" ;;
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
uuid = r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"
# `<fleet UUID>/<key>`, or `<fleet UUID>/<fleet_id>` — the lifelong form (#1646).
wid = re.compile(r"^" + uuid + r"/(([A-Za-z0-9][A-Za-z0-9._-]{0,127}:)?(issue|scratch)-[1-9][0-9]{0,9}|" + uuid + r")$")
rid, kind, frm, to = (str(r.get(k) or "") for k in ("id", "kind", "from", "to"))
node = re.sub(r"[^A-Za-z0-9._-]", "", str(r.get("from_node") or ""))[:64]
if kind == "child_report":
    sys.exit("PARENT_REPORT_RETIRED: parent reporting has been retired")
if kind not in ("message", "receipt"):
    sys.exit("unknown relay kind %r" % kind)
# The person at a login (issue #1649): a message's `from`, and so the `to` of its
# receipt — never anything else. The hub checked the login against the fleet's.
op = re.compile(r"^" + uuid + r"/operator@[A-Za-z0-9._-]{1,64}$")
if not (wid.match(frm) or (kind == "message" and op.match(frm))) \
        or not (wid.match(to) or (kind == "receipt" and op.match(to))):
    sys.exit("from/to is not a worker_id")
# A receipt carries the id of the relay it answers for: that relay's sender is
# its `to` (the hub swaps the two), so the id is scoped to `to`, not `from`.
scope = to if kind == "receipt" else frm
if not rid.startswith(scope + "#") or not re.match(r"^[A-Za-z0-9._-]{1,64}$", rid[len(scope) + 1:]):
    sys.exit("bad relay id")
p = r["payload"]
tier = ""
if kind == "receipt":
    st = str(p.get("status") or "")
    if st not in ("delivered", "failed", "expired") or str(p.get("rid") or "") != rid:
        sys.exit("bad receipt")
    detail = " ".join(str(p.get("detail") or "").split())[:300]
    # Taken by the target's machine but held there for its recipient: the
    # sender's book says QUEUED, with where — never DELIVERED.
    if st == "delivered" and detail.startswith("queued"):
        st = "queued"
    open(os.path.join(work, "row"), "w").write(json.dumps(
        {"state": st.upper(), "kind": str(p.get("kind") or ""), "to": str(p.get("to") or frm), "detail": detail},
        ensure_ascii=False))

else:
    text = str(p.get("text") or "")
    if not text.strip():
        sys.exit("empty message")
    open(os.path.join(work, "msg"), "w").write(text)
    # The repo the sender meant (issue #1649) — a bare issue:<N> matched by number
    # — and an issue comment the sender's bridge forwarded: checked and applied below.
    repo = str(p.get("repo") or "")
    if repo and not re.match(r"^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$", repo):
        sys.exit("bad repo")
    b = p.get("bridge")
    if b is not None:
        if not isinstance(b, dict) or not repo or not re.match(r"^[1-9][0-9]{0,19}$", str(b.get("cid") or "")) \
                or not re.match(r"^[1-9][0-9]{0,9}$", str(b.get("issue") or "")):
            sys.exit("bad bridge forward")
        open(os.path.join(work, "bridge"), "w").write("%s\t%s\t%s" % (repo, b["issue"], b["cid"]))
    open(os.path.join(work, "repo"), "w").write(repo)
for v in (kind, frm, to, node, tier, rid):
    print(v)
PY
) || die 1 "${fields##*$'\n'}"
{ read -r KIND; read -r FROM; read -r TO; read -r NODE; read -r _TIER; read -r RID; } <<EOF
$fields
EOF

# --- receipt (issue #1647): the sender's book learns what became of its relay -----
if [ "$KIND" = receipt ]; then
  if fleet_is_operator_sender "$TO"; then home=$(fleet_uuid_home "${TO%%/*}")
  else home=$(fleet_wid_home "wid:$TO"); fi || die 1 "receipt for $TO, which is not a fleet on this machine"
  { read -r rst; read -r rkind; read -r rto; read -r rdet; } <<EOF
$(python3 -c 'import json, sys; d = json.load(open(sys.argv[1])); print("\n".join((d["state"], d["kind"], d["to"], d["detail"])))' "$WORK/row")
EOF
  bash "$BIN/fleet-peer-queue.sh" note -L "$home" --rid "$RID" --state "$rst" --to "$rto" \
    --kind "$rkind" --via hub --detail "$rdet" || die 75 "could not write the delivery book"
  exit 0
fi

home=$(fleet_wid_home "wid:$TO") || die 1 "target $TO is not a fleet on this machine"
sock=$(fleet_socket "$home")
pkey=${TO#*/}
fkey=${FROM#*/}
# An identity-form recipient resolves through its stable @fleet_id.
pfwin=''
if fleet_is_fid "$pkey"; then
  pfwin=$(fleet_win_for_fid "$pkey" "$sock" 2>/dev/null) || pfwin=''
  # Not live here (yet): the hub holds it and pushes it again the beat this
  # machine's inventory lists that identity (issue #1647).
  [ -n "$pfwin" ] || die 75 "not now: recipient $pkey has no live window here"
  # No-repo sessions may have no key; their stable identity remains usable.
  _pk=$(fleet_window_okey "$home" "$pfwin" 2>/dev/null)
  [ -n "$_pk" ] && pkey=$_pk
fi

if [ "$KIND" = message ]; then
  loc=$(fleet_worker_locate "wid:$TO" "$home" 2>/dev/null)
  case "$loc" in
    local\ *) ;;
    *) die 75 "not now: $TO has no live window here" ;;
  esac
  # The repo rail (issue #1649): a sender that matched a bare issue:<N> by number
  # names the repo it meant; a window here working ANOTHER repo's #N never gets it.
  want=$(cat "$WORK/repo" 2>/dev/null)
  if [ -n "$want" ]; then
    loc=${loc#local }; twin=${loc%% *}
    have=$(fleet_window_repo "$home" "$twin" 2>/dev/null)
    [ -n "$have" ] || have=$(fleet_repos "$home" | head -n1)
    [ "$(fleet_norm_repo "$have")" = "$(fleet_norm_repo "$want")" ] \
      || die 1 "$TO works ${have:-an unknown repo}, not $want — refused"
  fi
  # An issue comment an older machine's bridge forwarded (issue #1649): the issue
  # bridge is gone (issue #4899) — refused for good, never re-sent.
  [ -s "$WORK/bridge" ] && die 1 "no issue bridge here (removed, claude-fleet#4899) — the comment was not delivered"
  text="[from $fkey on ${NODE:-another machine}]"$'\n'"$(cat "$WORK/msg")"
  out=$(env -u TMUX FLEET_PEER_DELIVERY_ID="$RID" bash "$BIN/fleet-peer-send.sh" -L "$sock" "wid:$TO" "$text" 2>&1); rc=$?
  case "$rc" in
    0) printf '%s\n' "$out" >&2; exit 0 ;;
    3) printf 'queued at %s: %s\n' "$(hostname -s 2>/dev/null)" "${out##*$'\n'}" >&2; exit 0 ;;
    1|2) die 1 "${out##*$'\n'}" ;;         # refused (ambiguous, bad target) or ended: for good
    *) die 75 "${out##*$'\n'}" ;;
  esac
fi

