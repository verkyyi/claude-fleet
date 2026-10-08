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
#   fleet-hub-node.sh progress [--max-age S]
#                                → pull the hub's progress streams of this login's
#                                  fleets into their children ledgers (issue #1648;
#                                  the cleanup tick and fleet-children.sh run it)
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
#   message       {text[, repo][, bridge]} → fleet-peer-send.sh to the target worker,
#                 with one `[from <key> on <node>]` line in front so it knows who to
#                 answer — `<key>` is `operator@<login>` for the person at a login
#                 (issue #1649). `repo` (a bare issue:<N> the sender matched by
#                 number): refused unless the target window works it. `bridge`
#                 {issue, cid}: an issue comment the sender's bridge forwarded —
#                 applied by this machine's bridge (`--apply-forward`), deduped
#                 against its own relays, so the comment lands once.
#   receipt       {rid, kind, to, status, detail} — the hub telling the SENDER what
#                 became of a relay it sent (issue #1647): one row in the sending
#                 fleet's delivery book (fleet-peer-queue.sh note), DELIVERED /
#                 FAILED / EXPIRED — or QUEUED when the target's machine took it
#                 but holds it for a recipient that cannot take it yet.
#
# A recipient that is not live here — no window answers to its identity or key —
# is «not now» (75), never «done»: the hub keeps the relay and pushes it again the
# beat this machine's inventory lists that worker (issue #1647). A child report is
# still ledgered on the first push (the parent's book is the record); a recipient
# whose window is here but cannot take it yet (no live Claude, an inbox that will
# not answer) gets it through this machine's peer queue (fleet-peer-queue.sh), and
# the last stderr line — the hub's detail — starts `queued`.
#
# Exit: 0 applied (or already applied, or queued here) · 75 not now, push it again
# later · anything else refused for good (the reason on stderr's last line). Never
# touches a window that is not the relay's target: the target is a worker_id of a
# fleet on THIS machine (fleet_wid_home), or the relay is refused.
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

# --- progress: one stream per parent (issue #1648, EPIC #1645 C5) -----------------
# The hub appends, under the PARENT's worker_id, every state of a placement it made
# for that parent (accepted → running → done | refused | failed) and every report a
# child on another machine relayed to it. This pulls the streams of this login's
# fleets (GET /v1/node/progress, the node token — never in a pane's env) and merges
# them into the ledger here, deduped on the event's rid: a report the relay push
# already delivered is one row, a placement's later state is a new `.dispatch` row
# (so a child never stays «accepted»), and a report the push never got here lands
# anyway. The placements a book still holds open ride along as `ops=`: the hub asks
# their machine once more, so an --async start reaches its final state too.
#
#   --max-age S   skip when the last pull is younger than S seconds (fleet-children.sh)
#
# Cursor + stamp: $FLEET_CONF_DIR/hub-progress/{seq,pulled}. A parent with no fleet
# here, or whose window (identity form) is not live, is skipped — the push path holds
# its reports. Merging only APPENDS: a pulled report goes through the same
# `fleet-children.py append` as every other (rid dedup), never a delivery into a
# pane — that stays the push path's. Exit: 0 pulled (or fresh enough) · 1 the hub
# refused / did not answer · 3 not applicable: no fleet here has the hub on, no node
# token, FLEET_HUB_PROGRESS=0, a hub that predates #1648 — nothing written, a
# one-machine fleet reads what it always read.
# Seams: FLEET_HUB_CURL (default curl), FLEET_HUB_TIMEOUT (default 10 s).
progress_pull() {
  local maxage='' pd seqf stamp since now last on s _c f ops resp rc code n=0 skip=0
  local parent home pkey pwin book got
  while [ $# -gt 0 ]; do
    case "$1" in
      --max-age) maxage="${2:-}"; maxage="${maxage//[^0-9]/}"; shift ;;
      *) die 2 "usage: fleet-hub-node.sh progress [--max-age S]" ;;
    esac
    shift
  done
  [ "${FLEET_HUB_PROGRESS:-1}" != 0 ] || return 3
  on=0
  while IFS=$'\t' read -r s _c; do
    [ -n "$s" ] && fleet_hub_on "$s" && { on=1; break; }
  done <<EOF
$(fleet_each_conf)
EOF
  [ "$on" = 1 ] || return 3
  _fleet_hub_creds_missing >/dev/null && return 3
  command -v python3 >/dev/null 2>&1 || return 3
  pd="$FLEET_CONF_DIR/hub-progress"; seqf="$pd/seq"; stamp="$pd/pulled"
  mkdir -p "$pd" 2>/dev/null || return 1
  now=$(date +%s)
  if [ -n "$maxage" ]; then
    last=$(cat "$stamp" 2>/dev/null); case "$last" in ''|*[!0-9]*) last=0 ;; esac
    [ $((now - last)) -lt "$maxage" ] && return 0
  fi
  printf '%s\n' "$now" > "$stamp"
  since=$(cat "$seqf" 2>/dev/null); case "$since" in ''|*[!0-9]*) since=0 ;; esac
  # The placements still open in any book here (each child's last row), ≤50.
  : > "$pd/books"
  while IFS=$'\t' read -r s _c; do
    [ -n "$s" ] || continue
    for f in "$(fleet_state_dir "$s")"/children/*.dispatch; do
      [ -f "$f" ] && printf '%s\n' "$f" >> "$pd/books"
    done
  done <<EOF
$(fleet_each_conf)
EOF
  ops=$(python3 "$BIN/fleet-children.py" open-ops < "$pd/books" 2>/dev/null)
  resp=$(_fleet_hub_env
    "${FLEET_HUB_CURL:-curl}" -sS --max-time "${FLEET_HUB_TIMEOUT:-10}" -o - -w '\n%{http_code}' \
      -H "Authorization: Bearer $CCQUOTA_TOKEN" -G --data-urlencode "since=$since" \
      ${ops:+--data-urlencode "ops=$ops"} "${CCQUOTA_HUB_URL%/}/v1/node/progress" 2>/dev/null); rc=$?
  if [ "$rc" -ne 0 ] || [ -z "$resp" ]; then
    printf 'fleet-hub-node: progress: hub unreachable (curl exit %s)\n' "$rc" >&2; return 1
  fi
  code=$(printf '%s\n' "$resp" | tail -n 1)
  case "$code" in
    200) ;;
    404|405) return 3 ;;
    *) printf 'fleet-hub-node: progress: the hub refused (HTTP %s)\n' "$code" >&2; return 1 ;;
  esac
  printf '%s\n' "$resp" | sed '$d' > "$pd/last.json"
  # Each parent the answer names, resolved ONCE to its fleet here and the key its
  # book is filed under — an identity-form parent through its live window.
  while IFS= read -r parent; do
    [ -n "$parent" ] || continue
    home=$(fleet_wid_home "wid:$parent" 2>/dev/null) || { skip=$((skip + 1)); continue; }
    fleet_hub_on "$home" || { skip=$((skip + 1)); continue; }
    pkey=${parent#*/}
    if fleet_is_fid "$pkey"; then
      pwin=$(fleet_win_for_fid "$pkey" "$(fleet_socket "$home")" 2>/dev/null) || pwin=''
      pkey=''; [ -n "$pwin" ] && pkey=$(fleet_window_okey "$home" "$pwin" 2>/dev/null)
      [ -n "$pkey" ] || { skip=$((skip + 1)); continue; }
    fi
    pkey=$(fleet_key_qualify "$home" "$pkey")   # a bare parent key is the one repo's (#1939)
    book=$(fleet_load_conf "$home" >/dev/null 2>&1; . "$BIN/fleet-children-lib.sh"; children_file "$pkey" "$home") \
      || { skip=$((skip + 1)); continue; }
    got=$(python3 "$BIN/fleet-children.py" merge --file "$book" --parent "$parent" \
      < "$pd/last.json" 2>/dev/null) || got=0
    case "$got" in ''|*[!0-9]*) got=0 ;; esac
    n=$((n + got))
  done <<EOF
$(python3 "$BIN/fleet-children.py" merge --parents < "$pd/last.json" 2>/dev/null)
EOF
  python3 -c 'import json, sys; print(int(json.load(open(sys.argv[1])).get("seq") or 0))' "$pd/last.json" \
    > "$seqf.tmp" 2>/dev/null && mv -f "$seqf.tmp" "$seqf"
  if [ "$n" -gt 0 ] || [ "$skip" -gt 0 ]; then
    printf 'progress: %s new row(s), %s parent(s) not here\n' "$n" "$skip"
  fi
  return 0
}

case "${1:-}" in
  paths)
    printf 'outbox\t%s\nworkers\t%s\nmovein\t%s\nattach\t%s\n' "$(fleet_hub_outbox)" "$(fleet_hub_cache)" "$(fleet_hub_movein)" "$(fleet_hub_attach)"
    exit 0 ;;
  env) shift; node_env "$@"; exit $? ;;
  progress) shift; progress_pull "$@"; exit $? ;;
  deliver) ;;
  *) die 2 "usage: fleet-hub-node.sh paths | deliver < relay.json | env [--write [--force]] [--plist <file>] | progress [--max-age S]" ;;
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
if kind not in ("child_report", "message", "receipt"):
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
elif kind == "child_report":
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
{ read -r KIND; read -r FROM; read -r TO; read -r NODE; read -r TIER; read -r RID; } <<EOF
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
# An identity-form target (issue #1646): the parent session by its @fleet_id, booked
# under the key it answers to NOW — a scratch bound to an issue since it spawned
# the child is still that child's parent. Not live here ⇒ refused below as before.
pfwin=''
if fleet_is_fid "$pkey"; then
  pfwin=$(fleet_win_for_fid "$pkey" "$sock" 2>/dev/null) || pfwin=''
  _pk=''; [ -n "$pfwin" ] && _pk=$(fleet_window_okey "$home" "$pfwin" 2>/dev/null)
  # Not live here (yet): the hub holds it and pushes it again the beat this
  # machine's inventory lists that identity (issue #1647).
  [ -n "$_pk" ] || die 75 "not now: parent $pkey has no live window here"
  pkey=$_pk
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
  # An issue comment another machine's bridge forwarded (issue #1649): applied
  # through THIS machine's bridge, under its lease and against its seen-set, so a
  # comment this machine's own bridge already relayed is not delivered twice.
  if [ -s "$WORK/bridge" ]; then
    IFS=$'\t' read -r brepo biss bcid < "$WORK/bridge"
    out=$(env -u TMUX bash "$BIN/fleet-issue-bridge.sh" --apply-forward "$brepo" "$biss" "$bcid" < "$WORK/msg" 2>&1); rc=$?
    case "$rc" in
      0) printf '%s\n' "${out##*$'\n'}" >&2; exit 0 ;;
      1) die 1 "${out##*$'\n'}" ;;
      *) die 75 "${out##*$'\n'}" ;;
    esac
  fi
  text="[from $fkey on ${NODE:-another machine}]"$'\n'"$(cat "$WORK/msg")"
  out=$(env -u TMUX bash "$BIN/fleet-peer-send.sh" -L "$sock" "wid:$TO" "$text" 2>&1); rc=$?
  case "$rc" in
    0) printf '%s\n' "$out" >&2; exit 0 ;;
    3) printf 'queued at %s: %s\n' "$(hostname -s 2>/dev/null)" "${out##*$'\n'}" >&2; exit 0 ;;
    1|2) die 1 "${out##*$'\n'}" ;;         # refused (ambiguous, bad target) or ended: for good
    *) die 75 "${out##*$'\n'}" ;;
  esac
fi

# --- child_report ----------------------------------------------------------------
fleet_load_conf "$home"
# shellcheck source=/dev/null
. "$BIN/fleet-children-lib.sh"
pkey=$(fleet_key_qualify "$home" "$pkey")   # a bare parent key is the one repo's (#1939)
lf=$(children_file "$pkey" "$home") || die 1 "no ledger for parent $pkey"
res=$(python3 "$BIN/fleet-children.py" append --file "$lf" < "$WORK/row" 2>&1) || die 1 "ledger refused it: ${res##*$'\n'}"
# A relay pushed again is ledgered once; it is DELIVERED once too — the rids this
# machine handed to their parent (or its queue) are kept beside the ledger, so a
# push that comes back after «not now» still gets delivered (issue #1647).
sentf="${lf%/*}/.relay-sent"
case "$res" in dup*)
  if grep -qxF "$RID" "$sentf" 2>/dev/null; then
    printf 'fleet-hub-node: %s already in %s ledger\n' "$fkey" "$pkey" >&2; exit 0
  fi ;;
esac

[ "$TIER" = silent ] && exit 0
MODE=$(children_report_mode)
[ "$MODE" = 0 ] && exit 0
if [ "$MODE" = batch ]; then
  [ "$TIER" = loud ] && [ -f "$BIN/fleet-children-flush.sh" ] \
    && bash "$BIN/fleet-children-flush.sh" -L "$sock" --parent "$pkey" >/dev/null 2>&1
  exit 0
fi
pwin=$pfwin
[ -n "$pwin" ] || pwin=$(fleet_win_for_key "$pkey" "$sock") || pwin=''
[ -n "$pwin" ] || die 75 "not now: parent $pkey has no window here — ledgered, delivered when it is back"
[ -s "$WORK/msg" ] || exit 0
children_send "$home" "$sock" "$pwin" "$(cat "$WORK/msg")"; rc=$?
if [ "$rc" -eq 0 ]; then
  children_cursor_set "$pkey" "$home"
  printf '%s\n' "$RID" >> "$sentf"
  printf 'reported → %s (%s) from %s on %s\n' "$pkey" "$pwin" "$fkey" "${NODE:-?}" >&2
  exit 0
fi
if [ "$rc" -eq 3 ]; then
  printf '%s\n' "$RID" >> "$sentf"
  printf 'queued at %s: parent %s is asleep at a full fleet — delivered when a slot frees\n' "$(hostname -s 2>/dev/null)" "$pkey" >&2
  exit 0
fi
# The window is here, its inbox will not answer now: this machine's peer queue
# holds it for the parent's identity (drained every tick and on its wake).
pfid=$(fleet_window_fid "$home" "$pwin" "$sock" 2>/dev/null) || pfid=''
if printf '%s' "$(cat "$WORK/msg")" | bash "$BIN/fleet-peer-queue.sh" put -L "$home" --kind report \
     --rid "$RID" --to "$pkey" ${pfid:+--to-fid "$pfid"} --to-key "$pkey" >/dev/null; then
  printf '%s\n' "$RID" >> "$sentf"
  printf 'queued at %s: parent %s (%s) cannot take it now — delivered when it can\n' "$(hostname -s 2>/dev/null)" "$pkey" "$pwin" >&2
  exit 0
fi
die 75 "not now: parent $pkey ($pwin) has no reachable inbox"

