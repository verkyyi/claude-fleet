#!/bin/bash
# fleet-break-it-revoke-selftest.sh — docs/BREAK-IT.md rows `cred-revoked-still-works`
# and `relay-revocations-hub-down` (issue #3560, EPIC #3500 C18): the hub's
# revocation list, followed by the relay and the door, refuses a revoked pass and
# certificate within 10 seconds — and keeps refusing with the hub away. Split from
# bin/fleet-break-it-cred-selftest.sh (whose helpers it sources, BREAK_CRED_LIB=1)
# because that run sits at the macOS per-test cap; bin/fleet-break-it-selftest.sh's
# lockstep lint reads the drill names here too.
#
#   cred-revoked-still-works    extras/cred-relay/fleet-relay-check.py (the list follower,
#                               the local refusal before the cache), bin/fleet-node-supervisor.py
#                               (entry revocations follow: the list → revoked.krl, RevokedKeys)
#   relay-revocations-hub-down  extras/cred-relay/fleet-relay-check.py (the kept list, version
#                               resume, list-stale), the hub half: go test -run Revocations
#
# ONE fake hub plays /v1/relay/check (an allow list) and the list
# (/v1/relay/revocations + /v1/node/revocations, held while ?since is current);
# a revocation is a new version of <dir>/list.json. The hub's own list — what
# writes it, the long poll waking, off adds nothing — is pinned by
# tokenledger/internal/api/fleet_revocations_test.go, run here when a Go
# toolchain is. The door: a sandbox sshd on 127.0.0.1 trusting a throwaway CA
# with RevokedKeys = the KRL the supervisor writes; no sshd that starts here ⇒
# the KRL is asked with `ssh-keygen -Q` instead (said in the PASS line).
# shellcheck disable=SC2034  # CAP / SECS / WHY / WHAT are read by the sourced runner
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=fleet-break-it-cred-selftest.sh
BREAK_CRED_LIB=1 . "$BIN/fleet-break-it-cred-selftest.sh"
command -v ssh-keygen >/dev/null 2>&1 || { printf 'fleet-break-it-revoke: ssh-keygen absent — SKIP\n'; exit 0; }
CHK="$ROOT/extras/cred-relay/fleet-relay-check.py"
SUP="$BIN/fleet-node-supervisor.py"

# rev_hub <dir> <port|0> — the fake hub; RH its pid, <dir>/hub.port its port
rev_hub() {
  cat > "$1/revhub.py" <<'PY'
import json, os, signal, sys, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit, parse_qs
signal.alarm(150)
D = sys.argv[1]
def lst():
    try:
        return json.load(open(os.path.join(D, "list.json")))
    except (OSError, ValueError):
        return {"v": 0, "entries": []}
class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, *a): pass
    def out(self, code, b=b""):
        self.send_response(code); self.send_header("content-length", str(len(b))); self.end_headers(); self.wfile.write(b)
    def do_GET(self):
        u = urlsplit(self.path)
        if u.path == "/v1/relay/check":
            allow = open(os.path.join(D, "allow")).read().split() if os.path.exists(os.path.join(D, "allow")) else []
            return self.out(200 if self.headers.get("X-Fleet-Relay", "") in allow else 403)
        if u.path not in ("/v1/relay/revocations", "/v1/node/revocations"):
            return self.out(404)
        want = "Bearer " + ("revtok" if u.path.startswith("/v1/relay/") else "nodetok")
        if self.headers.get("Authorization", "") != want:
            return self.out(401)
        q = parse_qs(u.query)
        since = int(q["since"][0]) if "since" in q else None
        end = time.time() + float(q.get("wait", ["0"])[0])
        while since is not None and lst()["v"] == since:
            if time.time() >= end:
                return self.out(304)
            time.sleep(0.1)
        with open(os.path.join(D, "hub-hits"), "a") as f:
            f.write("list %s\n" % u.path)
        self.out(200, json.dumps(lst()).encode())
ThreadingHTTPServer.allow_reuse_address = True
ThreadingHTTPServer.daemon_threads = True
s = ThreadingHTTPServer(("127.0.0.1", int(sys.argv[2])), H)
open(os.path.join(D, "hub.port.tmp"), "w").write(str(s.server_address[1])); os.rename(os.path.join(D, "hub.port.tmp"), os.path.join(D, "hub.port"))
s.serve_forever()
PY
  rm -f "$1/hub.port"
  python3 -I "$1/revhub.py" "$1" "$2" 2>>"$1/hub.err" &
  RH=$!; printf '%s\n' "$RH" >> "$WORK/cred-pids"
  until_ok 30 test -s "$1/hub.port"
}
# rev_list <dir> <v> [<entry json>…] — the hub's list moves to version <v>
rev_list() {
  local d="$1" v="$2"; shift 2
  python3 - "$d" "$v" "$@" <<'PY'
import json, os, sys
d, v = sys.argv[1], int(sys.argv[2])
ca = open(os.path.join(d, "ca.pub")).read().strip() if os.path.exists(os.path.join(d, "ca.pub")) else ""
l = {"v": v, "at": 0, "entries": [json.loads(e) for e in sys.argv[3:]], "ssh_ca": ca}
json.dump(l, open(os.path.join(d, "list.tmp"), "w")); os.rename(os.path.join(d, "list.tmp"), os.path.join(d, "list.json"))
PY
}
sha() { python3 -c 'import hashlib, sys; print(hashlib.sha256(sys.argv[1].encode()).hexdigest())' "$1"; }
exp_in() { python3 -c 'import sys, time; print(int(time.time()) + int(sys.argv[1]))' "$1"; }

# rev_checker <dir> [extra env…] — the relay's gate following the list; RCP its port
rev_checker() {
  local d="$1"; shift
  RCP=$(cred_deadport)
  printf 'revtok\n' > "$d/revtok"; chmod 600 "$d/revtok"
  env FLEET_HUB_URL="http://127.0.0.1:$(cat "$d/hub.port")" FLEET_RELAY_CHECK_LISTEN="127.0.0.1:$RCP" \
    RELAY_CHECK_TIMEOUT_S=2 FLEET_RELAY_CHECK_LOG="$d/check.log" FLEET_RELAY_CHECK_MAX_SECONDS=120 \
    FLEET_RELAY_REVOCATIONS_TOKEN_FILE="$d/revtok" FLEET_RELAY_REVOCATIONS_FILE="$d/kept.json" \
    RELAY_REVOCATIONS_WAIT_S=5 RELAY_REVOCATIONS_BACKOFF_S=1 "$@" python3 -I "$CHK" 2>>"$d/check.err" &
  RC=$!; printf '%s\n' "$RC" >> "$WORK/cred-pids"
  until_ok 30 sh -c 'curl -s -m 2 -o /dev/null "http://127.0.0.1:$1/healthz"' _ "$RCP" \
    || { WHY="the checker did not start: $(tail -2 "$d/check.err" | tr '\n' ' ')"; return 1; }
}

# door_rig <dir> — a CA, a person's certificate (serial 4242, this login), the
# supervisor's follower writing <dir>/st/entry/revoked.krl, and a sandbox sshd
# loading it; DOOR=sshd|keygen says which asks the KRL
door_rig() {
  local d="$1" me; me=$(id -un)
  ssh-keygen -q -t ed25519 -N '' -C ca -f "$d/ca" && ssh-keygen -q -t ed25519 -N '' -C u -f "$d/u" \
    && ssh-keygen -q -s "$d/ca" -I "person:gh:7" -n "$me" -z 4242 -V -5m:+1h "$d/u.pub" \
    && ssh-keygen -q -t ed25519 -N '' -C hk -f "$d/hk" || { WHY="ssh-keygen could not make the test CA"; return 1; }
  rev_list "$d" 1
  mkdir -p "$d/st"
  printf 'CCQUOTA_HUB_URL=http://127.0.0.1:%s\nCCQUOTA_TOKEN=nodetok\nFLEET_ENTRY=1\n' "$(cat "$d/hub.port")" > "$d/st/machine.env"
  FLEET_NODE_TEST=1 FLEET_NODE_STATE="$d/st" FLEET_NODE_LOG="$d/st" FLEET_ENTRY_REV_WAIT=5 FLEET_ENTRY_REV_BACKOFF=1 \
    python3 -I "$SUP" entry revocations follow --max-seconds 120 2>>"$d/follow.log" &
  printf '%s\n' "$!" >> "$WORK/cred-pids"
  KRL="$d/st/entry/revoked.krl"
  until_ok 10 test -s "$KRL" || { WHY="the door wrote no KRL: $(tail -2 "$d/follow.log" | tr '\n' ' ')"; return 1; }
  DOOR=keygen
  local sshd="${FLEET_ENTRY_SSHD:-/usr/sbin/sshd}"
  command -v ssh >/dev/null 2>&1 && [ -x "$sshd" ] || return 0
  SP=$(cred_deadport)
  cat > "$d/sshd_config" <<EOF
Port $SP
ListenAddress 127.0.0.1
HostKey $d/hk
PidFile $d/sshd.pid
AuthenticationMethods publickey
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
UsePAM no
StrictModes no
AuthorizedKeysFile none
TrustedUserCAKeys $d/ca.pub
RevokedKeys $KRL
AllowUsers $me
LogLevel VERBOSE
EOF
  "$sshd" -D -e -f "$d/sshd_config" 2>>"$d/sshd.log" &
  printf '%s\n' "$!" >> "$WORK/cred-pids"
  if until_ok 5 sh -c 'nc -z 127.0.0.1 "$1" 2>/dev/null || (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null' _ "$SP"; then
    door_in || { WHY="the sandbox sshd refused a live certificate: $(tail -3 "$d/sshd.log" | tr '\n' ' ')"; return 1; }
    DOOR=sshd
  fi
}
door_in() {   # the certificate gets in through the door
  if [ "${DOOR:-sshd}" = keygen ]; then ssh-keygen -Q -f "$KRL" "$RD/u-cert.pub" >/dev/null 2>&1; return; fi
  ssh -F /dev/null -o BatchMode=yes -o IdentitiesOnly=yes -o IdentityAgent=none -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -o LogLevel=ERROR -i "$RD/u" \
    -o CertificateFile="$RD/u-cert.pub" -p "$SP" "$(id -un)@127.0.0.1" true </dev/null >/dev/null 2>&1
}
door_out() { ! door_in; }
both_refused() { relay_is 403 "$1" && door_out; }

drill_cred_revoked_still_works() {
  CAP=10   # revoked on the hub → the relay and the door both refuse
  local d="$WORK/revoke" code t0 e1 e2 tok
  RD="$d"; mkdir -p "$d"; printf 'frl1.A\nfrl1.R\n' > "$d/allow"
  : > "$d/list.json"
  rev_hub "$d" 0 || { WHY="the fake hub did not start: $(tail -2 "$d/hub.err" | tr '\n' ' ')"; return 1; }
  door_rig "$d" || return 1
  rev_checker "$d" RELAY_CHECK_CACHE_S=30 RELAY_CHECK_GRACE_S=600 || return 1
  until_ok 10 grep -q ' list v=1 ' "$d/check.log" || { WHY="the checker never read the list: $(tail -2 "$d/check.log" | tr '\n' ' ')"; return 1; }
  for tok in frl1.A frl1.R; do
    code=$(relay_ask "$tok"); [ "$code" = 200 ] || { WHY="before: $tok → $code"; return 1; }
  done
  door_in || { WHY="before: the certificate did not get in"; return 1; }
  # revoke R and the certificate on the hub. The hub's check still says yes for
  # R (its own 30 s cache — the old road), and the relay has R cached for 30 s:
  # only the list can refuse it now.
  e1="{\"jti\":\"frl1:$(sha frl1.R)\",\"exp\":$(exp_in 86400)}"
  e2="{\"jti\":\"ssh:4242\",\"principal\":\"gh:7\",\"exp\":$(exp_in 3600)}"
  t0=$(now); rev_list "$d" 2 "$e1" "$e2"
  until_ok 10 both_refused frl1.R || { WHY="10s after the revocation: relay R → $(relay_ask frl1.R), door $(door_in && echo in || echo out)"; return 1; }
  SECS=$(since "$t0")
  code=$(relay_ask frl1.A); [ "$code" = 200 ] || { WHY="a pass not on the list → $code"; return 1; }
  grep -q ' revoked prefix=/anthropic/ by=frl1 ' "$d/check.log" || { WHY="no revoked line in the checker's log"; return 1; }
  ! grep -q 'frl1\.' "$d/check.log" || { WHY="the checker's log carries a pass"; return 1; }
  [ -s "$d/kept.json" ] || { WHY="the checker did not keep the list on disk"; return 1; }
  local how="门（沙箱 sshd + RevokedKeys）拒"
  [ "$DOOR" = sshd ] || how="门的 KRL 判 REVOKED（这里起不了 sshd，按 ssh-keygen -Q 查）"
  WHAT="吊销一张缓存里还放行着的中转通行证和一张没过期的连接证书：${SECS}s 内中转 403（日志 revoked，不含通行证），${how}；别的通行证照常"
}

drill_relay_revocations_hub_down() {
  CAP=10   # the hub back with a revocation → the relay refuses
  local d="$WORK/revoke-down" code hp t0 gohalf=""
  mkdir -p "$d"; printf 'frl1.A\nfrl1.B\n' > "$d/allow"
  rev_list "$d" 1
  rev_hub "$d" 0 || { WHY="the fake hub did not start: $(tail -2 "$d/hub.err" | tr '\n' ' ')"; return 1; }
  hp=$(cat "$d/hub.port")
  rev_checker "$d" RELAY_CHECK_CACHE_S=1 RELAY_CHECK_GRACE_S=60 RELAY_REVOCATIONS_STALE_S=2 || return 1
  until_ok 10 grep -q ' list v=1 ' "$d/check.log" || { WHY="the checker never read the list"; return 1; }
  for tok in frl1.A frl1.B; do
    code=$(relay_ask "$tok"); [ "$code" = 200 ] || { WHY="hub up: $tok → $code"; return 1; }
  done
  # the hub stops: a pass not revoked keeps working; the list only goes stale
  kill "$RH" 2>/dev/null; wait "$RH" 2>/dev/null; sleep 1.2
  code=$(relay_ask frl1.A); [ "$code" = 200 ] || { WHY="hub down: an unrevoked pass → $code"; return 1; }
  until_ok 8 grep -q ' list-stale ' "$d/check.log" || { WHY="a list the hub stopped refreshing was never logged list-stale"; return 1; }
  code=$(relay_ask frl1.B); [ "$code" = 200 ] || { WHY="hub down, list stale: an unrevoked pass → $code (a stale list must not refuse)"; return 1; }
  # the hub comes back (same port) and revokes A: refused at once, whatever the grace says
  rev_list "$d" 2 "{\"jti\":\"frl1:$(sha frl1.A)\",\"exp\":$(exp_in 86400)}"
  t0=$(now); rev_hub "$d" "$hp" || { WHY="the fake hub did not come back"; return 1; }
  until_ok 10 relay_is 403 frl1.A || { WHY="10s after the hub came back with A revoked: A → $(relay_ask frl1.A)"; return 1; }
  SECS=$(since "$t0")
  code=$(relay_ask frl1.B); [ "$code" = 200 ] || { WHY="hub back: B → $code"; return 1; }
  # the hub away again and the checker restarted: the kept list still refuses A
  kill "$RH" 2>/dev/null; wait "$RH" 2>/dev/null
  kill "$RC" 2>/dev/null; wait "$RC" 2>/dev/null
  rev_checker "$d" RELAY_CHECK_CACHE_S=1 RELAY_CHECK_GRACE_S=60 || return 1
  code=$(relay_ask frl1.A); [ "$code" = 403 ] || { WHY="checker restarted, hub away: the revoked A → $code (the kept list was not read)"; return 1; }
  # the hub's own list, for real (when a Go toolchain is here)
  if command -v go >/dev/null 2>&1 && [ -d "$ROOT/tokenledger" ]; then
    local gout
    gout=$(cd "$ROOT/tokenledger" && go test -count=1 -run '^TestRevocations' ./internal/api 2>&1)
    case "$?:$gout" in
      0:*) gohalf="；入口半边 go test -run TestRevocations 通过" ;;
      *) WHY="the hub half: $(printf '%s' "$gout" | grep -E -- '--- FAIL|FAIL|Error' | head -3 | tr '\n' ' ')"; return 1 ;;
    esac
  fi
  WHAT="入口停着：没吊销的通行证照常（名单旧了只记 list-stale）；入口回来带着一条吊销，${SECS}s 内中转 403；再停入口、重启核验进程，存下的名单照样拒${gohalf}"
}

cred_run_drills "$0"
