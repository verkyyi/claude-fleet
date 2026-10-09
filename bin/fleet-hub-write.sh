#!/bin/bash
# fleet-hub-write.sh — the ONE client that WRITES to the cross-machine hub
# (issue #1487, EPIC #1479 C8; the C5 shell uses it too).
#
# A row in the sidebar that lives on another machine (`wid:<worker_id>`, #1423)
# cannot be acted on by any script here: the window is not on this tmux server.
# Every action on it is a hub WRITE — `/v1/fleet/<tool>`, journalled on the hub
# and on the node (docs/FLEET-HUB.md «Writes, concurrency and disconnected
# machines») — and this script is where every such write leaves this machine
# (EPIC #1479 convention 6: 远程的东西本机不回收). Reads stay with
# fleet-hub-sessions.sh; the render path never runs this.
#
#   fleet-hub-write.sh <tool> <json-args> [--idem <key>] [--wait [<secs>]] [--quiet]
#   fleet-hub-write.sh operation_get <operation_id>
#   fleet-hub-write.sh --identity                 who this login writes as (no network)
#
#   <tool>       worker_message · worker_stop · worker_resume · worker_answer ·
#                worker_reap · worker_switch · worker_rename · worker_reap_policy ·
#                worker_start · gh_comment · config_set · service_control ·
#                orch_ensure (issue #2616: open the orchestrating session) — the hub's
#                write tools; anything else is refused here before a byte goes out.
#   <json-args>  ONE JSON object: the tool's arguments as docs/FLEET-HUB.md lists
#                them. `idempotency_key` is added when absent (`--idem`, else a
#                fresh `w-<epoch>-<random>`), so a plain call is one operation and
#                a retry with the same key is the SAME operation, never a second.
#   --wait [S]   poll operation_get until the operation is terminal (succeeded /
#                failed / unknown), S seconds at most (default 20); the final
#                record is what is printed.
#   --quiet      no summary on stderr.
#
# Output: the operation record (operation_get's shape) as one JSON line on stdout;
# one summary line on stderr — `<tool> → <status>`, plus the error code and the
# node's reason verbatim when it failed (the refusal is never swallowed).
# Exit: 0 the operation is accepted / running / succeeded · 1 failed, unknown, or
# nothing was sent (no hub, no identity, HTTP error) · 2 usage.
#
# WHO WRITES — the first that exists:
#   1. FLEET_HUB_WRITE_CMD   a seam for tests: `bash -c "$FLEET_HUB_WRITE_CMD" fleet-hub-write
#                            <tool> <json>` prints the operation record itself.
#   2. the viewer token      CCQUOTA_VIEWER_TOKEN, else ~/.ccquota/viewer-token — on a
#                            NODE this is the operator's door: POST /v1/fleet/<tool>
#                            with the bearer, journalled as `operator`.
#   3. this device's certificate  ~/.ssh/fleet-cert + -cert.pub (`fleet login`,
#                            FLEET_CERT to name another) while valid — the shell's
#                            door (C5), and a colleague's on a node: POST
#                            /v1/fleet/write {cert, sig, ts, tool, args_json} with
#                            `ssh-keygen -Y sign -n fleet-write@claude-fleet` over
#                            "fleet-write <ts> <tool> <sha256 of args_json>", so the
#                            signature binds THIS write, not just a timestamp. The hub
#                            then acts as the certificate's person: only THEIR workers
#                            (FleetScope), journalled under their principal.
#   4. neither               nothing is sent; one line on stderr says what to do.
# The hub's URL: CCQUOTA_HUB_URL, else FLEET_HUB_URL, else hub.json's `url`.
#
# OFF unless the hub is configured: with no URL this is a one-line refusal, and
# nothing in a one-machine fleet ever calls it (the menu offers these actions on
# remote rows only — bin/fleet-sidebar-menu.sh).
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
[ -f "$BIN/../fleet.conf" ] && . "$BIN/../fleet.conf"
# the machine's one config file (issue #1623): FLEET_HUB_URL is written there
_fcd="${FLEET_CONF_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/claude-fleet}"
# shellcheck source=/dev/null
[ -f "$_fcd/fleet.conf" ] && . "$_fcd/fleet.conf"
unset _fcd

WRITE_NS="fleet-write@claude-fleet"
WRITE_TOOLS=" worker_message worker_stop worker_resume worker_answer worker_reap worker_switch worker_rename worker_reap_policy worker_start gh_comment config_set service_control orch_ensure "

usage() { sed -n '/^#   fleet-hub-write.sh <tool>/,/^# nothing was sent/p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
note() { [ "$QUIET" = 1 ] || printf 'fleet-hub-write: %s\n' "$*" >&2; }

hub_url() {
  local u="${CCQUOTA_HUB_URL:-${FLEET_HUB_URL:-}}"
  if [ -z "$u" ]; then
    u=$(python3 - "${XDG_CONFIG_HOME:-$HOME/.config}/claude-fleet/hub.json" <<'PY' 2>/dev/null
import json, sys
try:
    print(str(json.load(open(sys.argv[1])).get("url") or ""))
except Exception:
    pass
PY
)
  fi
  [ -n "$u" ] || return 1
  printf '%s\n' "${u%/}"
}

cert_paths() { CERT_KEY="${FLEET_CERT:-$HOME/.ssh/fleet-cert}"; CERT_PUB="$CERT_KEY-cert.pub"; }
# set once here: cert_state runs in $(…), so its assignment never reaches the
# caller — post_cert / identity read these in the parent shell (issue #2506)
cert_paths
# cert_state → ok <until> / expired <until> / missing (local: ssh-keygen -L's Valid line)
cert_state() {
  cert_paths
  [ -f "$CERT_KEY" ] && [ -f "$CERT_PUB" ] || { printf 'missing\n'; return 0; }
  command -v ssh-keygen >/dev/null 2>&1 || { printf 'missing\n'; return 0; }
  ssh-keygen -L -f "$CERT_PUB" 2>/dev/null | python3 -c '
import sys, time
state, until = "ok", "forever"
for line in sys.stdin:
    line = line.strip()
    if not line.startswith("Valid:"):
        continue
    w = line.split()
    if "forever" in line or len(w) < 5:
        break
    try:
        start = time.mktime(time.strptime(w[2], "%Y-%m-%dT%H:%M:%S"))
        end = time.mktime(time.strptime(w[4], "%Y-%m-%dT%H:%M:%S"))
    except ValueError:
        break
    until = w[4]
    now = time.time()
    if now < start - 300 or now > end:
        state = "expired"
    break
print(state, until)
' 2>/dev/null || printf 'missing\n'
}
token_source() {
  TOK="${CCQUOTA_VIEWER_TOKEN:-}"
  if [ -n "$TOK" ]; then printf 'env\n'; return 0; fi
  [ -r "$HOME/.ccquota/viewer-token" ] && read -r TOK < "$HOME/.ccquota/viewer-token" || TOK=''
  [ -n "$TOK" ] || return 1
  printf 'file\n'
}
identity() {
  local st src
  if [ -n "${FLEET_HUB_WRITE_CMD:-}" ]; then printf 'cmd FLEET_HUB_WRITE_CMD\n'; return 0; fi
  if src=$(token_source); then
    case "$src" in env) printf 'token CCQUOTA_VIEWER_TOKEN\n' ;; *) printf 'token ~/.ccquota/viewer-token\n' ;; esac
    return 0
  fi
  st=$(cert_state)
  case "$st" in
    ok\ *) printf 'cert %s %s\n' "$CERT_PUB" "${st#ok }"; return 0 ;;
    expired\ *) printf 'none certificate expired %s (run `fleet login` again) and no viewer token\n' "${st#expired }" ;;
    *) printf 'none no connection certificate (%s — run `fleet login`) and no viewer token\n' "${CERT_PUB:-~/.ssh/fleet-cert-cert.pub}" ;;
  esac
  return 1
}

# ---- arguments ---------------------------------------------------------------
QUIET=0; WAIT=''; IDEM=''
TOOL="${1:-}"; [ -n "$TOOL" ] || usage
case "$TOOL" in
  --identity) identity; exit $? ;;
  -h|--help) usage ;;
esac
shift
ARGS="${1:-}"; [ -n "$ARGS" ] || usage; shift
while [ $# -gt 0 ]; do
  case "$1" in
    --idem) IDEM="${2:-}"; shift 2 ;;
    --wait) WAIT=20; case "${2:-}" in ''|-*) ;; *) WAIT="$2"; shift ;; esac; shift ;;
    --quiet) QUIET=1; shift ;;
    *) usage ;;
  esac
done
case "$WAIT" in ''|*[!0-9]*) [ -z "$WAIT" ] || WAIT=20 ;; esac

if [ "$TOOL" = operation_get ]; then
  # `operation_get <id>` — the bare id, or a JSON object naming it.
  case "$ARGS" in \{*) ;; *) ARGS=$(printf '{"operation_id":"%s"}' "$ARGS") ;; esac
else
  case "$WRITE_TOOLS" in *" $TOOL "*) ;; *) note "'$TOOL' is not a hub write tool (see docs/FLEET-HUB.md «Tools»)"; exit 2 ;; esac
fi
# A client in standby sends nothing (issue #1715; #1932): its lease is no longer
# held (asked to leave past the limit, or disconnected) — Enter takes one first.
if [ "${FLEET_SHELL:-}" = 1 ] && [ -f "${TMPDIR:-/tmp}/client.standby" ]; then
  note "客户端在待机：这台已被请下线或断开，按回车重新连上后再操作 — nothing was sent"
  exit 1
fi
command -v python3 >/dev/null 2>&1 || { note "needs python3"; exit 1; }

# One JSON object, the idempotency key filled in. `--idem` wins over a key inside
# the object only when the object has none: the caller's explicit key is its retry.
ARGS=$(python3 - "$ARGS" "$TOOL" "$IDEM" <<'PY'
import json, os, sys, time
try:
    a = json.loads(sys.argv[1])
except ValueError:
    sys.exit(2)
if not isinstance(a, dict):
    sys.exit(2)
if sys.argv[2] != "operation_get" and not a.get("idempotency_key"):
    a["idempotency_key"] = sys.argv[3] or "w-%d-%s" % (int(time.time()), os.urandom(6).hex())
print(json.dumps(a, ensure_ascii=False, sort_keys=True, separators=(",", ":")))
PY
) || { note "<json-args> must be one JSON object"; exit 2; }

# ---- the doors ----------------------------------------------------------------
# post_token <url> <tool> <args> → the hub's answer on stdout; rc 1 = not sent / HTTP error
post_token() {
  local url="$1" tool="$2" body="$3" out code
  out=$(mktemp "${TMPDIR:-/tmp}/fhw.XXXXXX") || return 1
  if [ "$tool" = operation_get ]; then
    local id; id=$(printf '%s' "$body" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("operation_id",""))')
    code=$(curl -sS -m 25 -o "$out" -w '%{http_code}' -H "Authorization: Bearer $TOK" \
           "$url/v1/fleet/operation_get?operation_id=$id" 2>/dev/null)
  else
    code=$(curl -sS -m 40 -o "$out" -w '%{http_code}' -X POST -H "Authorization: Bearer $TOK" \
           -H 'Content-Type: application/json' --data-binary "$body" "$url/v1/fleet/$tool" 2>/dev/null)
  fi
  cat "$out"; rm -f "$out"
  case "$code" in 2??) return 0 ;; '') note "the hub did not answer ($url)"; return 1 ;; *) HTTP="$code"; return 1 ;; esac
}
# post_cert <url> <tool> <args> → signed by this device's certificate (door 3)
post_cert() {
  local url="$1" tool="$2" body="$3" ts sig cert digest req out code
  cert_paths
  [ -f "$CERT_KEY" ] && [ -f "$CERT_PUB" ] \
    || { note "no connection certificate at $CERT_KEY (run \`fleet login\`) — nothing sent"; return 1; }
  ts=$(date +%s)
  digest=$(printf '%s' "$body" | python3 -c 'import hashlib,sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())')
  sig=$(printf 'fleet-write %s %s %s' "$ts" "$tool" "$digest" | ssh-keygen -Y sign -f "$CERT_KEY" -n "$WRITE_NS" 2>/dev/null) \
    || { note "ssh-keygen -Y sign failed with $CERT_KEY"; return 1; }
  cert=$(head -n1 "$CERT_PUB" 2>/dev/null) || return 1
  req=$(python3 -c 'import json, sys; print(json.dumps({"cert": sys.argv[1], "sig": sys.argv[2], "ts": int(sys.argv[3]), "tool": sys.argv[4], "args_json": sys.argv[5]}))' \
        "$cert" "$sig" "$ts" "$tool" "$body") || return 1
  out=$(mktemp "${TMPDIR:-/tmp}/fhw.XXXXXX") || return 1
  code=$(curl -sS -m 40 -o "$out" -w '%{http_code}' -X POST -H 'Content-Type: application/json' \
         --data-binary "$req" "$url/v1/fleet/write" 2>/dev/null)
  cat "$out"; rm -f "$out"
  case "$code" in 2??) return 0 ;; '') note "the hub did not answer ($url)"; return 1 ;; *) HTTP="$code"; return 1 ;; esac
}
# send <tool> <args> → the record on stdout, rc 0/1
send() {
  local tool="$1" body="$2" url
  HTTP=''
  if [ -n "${FLEET_HUB_WRITE_CMD:-}" ]; then
    bash -c "$FLEET_HUB_WRITE_CMD" fleet-hub-write "$tool" "$body" </dev/null; return
  fi
  url=$(hub_url) || { note "no hub URL (CCQUOTA_HUB_URL / FLEET_HUB_URL / hub.json) — nothing sent"; return 1; }
  command -v curl >/dev/null 2>&1 || { note "needs curl"; return 1; }
  if token_source >/dev/null; then post_token "$url" "$tool" "$body"; return; fi
  case "$(cert_state)" in ok\ *) post_cert "$url" "$tool" "$body"; return ;; esac
  note "$(identity | sed 's/^none //') — nothing sent"
  return 1
}

# summarize <record> → one stderr line + the exit status
summarize() {
  local rec="$1" line rc
  line=$(printf '%s' "$rec" | python3 -c '
import json, sys
try:
    o = json.load(sys.stdin)
except ValueError:
    print("1\tunreadable answer"); sys.exit(0)
if "error" in o and not o.get("operation_id"):
    e = o["error"] if isinstance(o["error"], dict) else {"message": str(o["error"])}
    print("1\trefused: %s%s" % (e.get("code", "") + ": " if e.get("code") else "", e.get("message", "")))
    sys.exit(0)
st = o.get("status", "?")
res = o.get("result") or {}
err = res.get("error") if isinstance(res, dict) else None
tail = ""
if isinstance(err, dict):
    tail = " — %s: %s" % (err.get("code", "?"), err.get("message", ""))
elif isinstance(res, dict) and res.get("how"):
    tail = " — " + str(res["how"])
ok = st in ("accepted", "running", "succeeded", "pending")
print("%d\t%s%s  op=%s" % (0 if ok else 1, st, tail, o.get("operation_id", "?")))
')
  rc=${line%%$'\t'*}
  note "$TOOL → ${line#*$'\t'}"
  return "$rc"
}

rec=$(send "$TOOL" "$ARGS") || {
  [ -n "${HTTP:-}" ] && note "HTTP $HTTP from the hub: $(printf '%s' "$rec" | head -c 300)"
  [ -n "$rec" ] && printf '%s\n' "$rec"
  exit 1
}
# --wait: an accepted write is a promise, not an outcome — read it back.
if [ -n "$WAIT" ] && [ "$TOOL" != operation_get ]; then
  opid=$(printf '%s' "$rec" | python3 -c 'import json,sys
o=json.load(sys.stdin); print(o.get("operation_id","") if o.get("status") in ("pending","accepted","running") else "")' 2>/dev/null)
  if [ -n "$opid" ]; then
    end=$(( $(date +%s) + WAIT ))
    while [ "$(date +%s)" -lt "$end" ]; do
      sleep 1
      got=$(send operation_get "$(printf '{"operation_id":"%s"}' "$opid")") || break
      rec="$got"
      case "$(printf '%s' "$rec" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("status",""))' 2>/dev/null)" in
        pending|accepted|running) ;; *) break ;;
      esac
    done
  fi
fi
printf '%s\n' "$rec"
summarize "$rec"
