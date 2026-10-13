#!/bin/bash
# fleet-move-to-pod-selftest.sh — bin/fleet-move-to-pod.sh against a fake
# cluster and hub (issue #3554, EPIC #3500 C10). No cluster, no hub: the
# seams FLEET_MOVE_KUBECTL / FLEET_MOVE_HUB_ADMIN / FLEET_HUB_CURL point at
# scripts in a sandbox that answer like kubectl and the hub and log every call.
#
#   A. the order holds: copy before stop, start before copy, retire before
#      verify, stop with nobody's seeder — each refused (3), nothing done
#   B. somebody attached: stop refuses (3) and `login stop` never runs
#   C. all: check → verify in order; the pod is rendered with the login's OWN
#      uid from the source's declaration; the source runs `login stop` (never
#      fleet-down); the join code reaches its Secret on stdin only (not in any
#      argv, not in the state dir); the shared-node files are cleared on the
#      copy; the hub gets assign --own-name, the allow-list copy, the home PUT;
#      the timeline has every phase
#   F. the source machine has no subscription allow-list: open refuses (3)
#      before the login exists; --allow-list-none moves anyway. In C the list
#      is set AND read back before the assign
#      The pinned list is read AFTER stop: check sees 0, the stop's snapshot save 2.
#   G. the copy is pod to pod (the real python halves, run here): a half that
#      sends the wrong token gets nothing and the phase exits 1
#   D. a pinned session missing on the pod: verify exits 1 naming it
#   E. retire after verify closes the SOURCE login with --delete
set -uo pipefail

BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECKS=0
fail() { printf 'fleet-move-to-pod selftest FAIL: %s\n' "$1" >&2; exit 1; }
ok() { CHECKS=$((CHECKS + 1)); }

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
LOG=$T/calls.log
: > "$LOG"
CODE=fj_abcdefghijklmnopqrstuvwxyz

cat > "$T/kubectl" <<'SH'
#!/bin/bash
# a fake kubectl: -n <ns> <verb> …
printf 'kubectl %s\n' "$*" >> "$FAKE/calls.log"
[ "$1" = -n ] && shift 2
verb=$1; shift
case "$verb" in
  exec)
    stdin=0; [ "$1" = -i ] && { stdin=1; shift; }
    target=$1; shift
    while [ "$1" != -- ]; do shift; done; shift
    all="$*"
    case "$target:$all" in
      *:*linux-tenants/*) echo '{"gid": 10006, "home": "/home/24acme", "login": "24acme", "op": "fda2", "since": 1, "uid": 10006}' ;;
      *:du\ *) printf '3.8G\t/home/24acme\n' ;;
      *:find\ /home/*) : ;;
      *:*sessions.snapshot*) [ -f "$FAKE/stopped" ] && printf 'fid-1 probe\nfid-2 work\n' ;;
      *:*list-clients*) echo "${FAKE_ATTACHED:-0}" ;;
      *:*"login stop"*) touch "$FAKE/stopped"; echo "stopped 24acme (UID 10006); home /home/24acme kept" ;;
      *-seed:mkdir*|*-seed:rm\ *) : ;;
      # the copy's two halves: the REAL python, run here, its paths in the sandbox
      *:"python3 -")
        side=recv; case "$target" in *-seed) ;; *) side=send ;; esac
        python3 -c '
import sys
s = sys.stdin.read()
for a, b in (("\"/home\"", "\"%s/src\"" % sys.argv[1]), ("\"/data/homes\"", "\"%s/dst\"" % sys.argv[1]),
             ("/tmp/.fleet-move-send.rc", sys.argv[1] + "/send.rc"), ("/data/.fleet-move-recv.rc", sys.argv[1] + "/recv.rc")):
    s = s.replace(a, b)
if sys.argv[2] == "recv" and sys.argv[3]:
    s = s.replace("TOKEN=b\"", "TOKEN=b\"x", 1)
open(sys.argv[1] + "/" + sys.argv[2] + ".py", "w").write(s)' "$FAKE" "$side" "${FAKE_BADTOKEN:-}"
        python3 "$FAKE/$side.py" ;;
      *:cat\ /tmp/.fleet-move-send.rc) cat "$FAKE/send.rc" ;;
      *:cat\ /data/.fleet-move-recv.rc) cat "$FAKE/recv.rc" ;;
      *-seed:*"find \"\$1\""*) echo 7 ;;
      node-a-0:*find*) echo 10 ;;
      deploy/*:*list-windows*) printf '%s\n' ${FAKE_BACK:-fid-1 fid-2} ;;
      *) echo "unexpected exec $target: $all" >&2; exit 9 ;;
    esac ;;
  apply) python3 -c 'import json,sys; [print("apply", i["kind"], i["metadata"]["name"], json.dumps(i)) for i in (lambda d: d.get("items",[d]))(json.load(sys.stdin))]' >> "$FAKE/calls.log" ;;
  get)
    case "$1" in
      secret) exit 1 ;;
      deploy) case "$*" in *readyReplicas*) echo 1 ;; *) exit 1 ;; esac ;;
      pod/*) [ -f "$FAKE/seeder" ] ;;
      pod) echo 127.0.0.1 ;;   # -o jsonpath={.status.podIP}
    esac ;;
  create) cat > "$FAKE/secret.stdin"; touch "$FAKE/seeder" ;;
  wait|delete) : ;;
  *) echo "unexpected kubectl $verb" >&2; exit 9 ;;
esac
SH
cat > "$T/hubadm" <<'SH'
#!/bin/bash
printf 'hubadm %s\n' "$*" >> "$FAKE/calls.log"
case "$*" in
  *"accounts list --json"*)
    if [ -f "$FAKE/assigned" ]; then echo '{"accounts":[{"principal_id":"gh:7","hostname":"'"$(cat "$FAKE/assigned")"'","state":"active"}]}'
    else echo '{"accounts":[]}'; fi ;;
  *"accounts assign"*) set -- $*; while [ "$1" != --host ]; do shift; done; echo "$2" > "$FAKE/assigned" ;;
esac
SH
# the hub's cred-policy: node-a-0 has a Codex-only list; a set lands in allow.set
cat > "$T/credpol" <<'SH'
#!/bin/bash
printf 'credpol %s\n' "$*" >> "$FAKE/calls.log"
case "$1" in
  show)
    src='{"id":"node-a-0","allow":["codex:account:0123"]}'
    [ -n "${FAKE_NO_ALLOW:-}" ] && src='{"id":"node-b-0","allow":["x"]}'
    printf '{"mode":"strict","nodes":[%s%s]}\n' "$src" "$(cat "$FAKE/allow.set" 2>/dev/null)" ;;
  set) [ "$2" = --force ] || { echo 'would empty claude' >&2; exit 5; }
       pod=$4; shift 4; ids=$(printf '"%s",' "$@"); printf ',{"id":"%s","allow":[%s]}' "$pod" "${ids%,}" > "$FAKE/allow.set" ;;
  *) exit 9 ;;
esac
SH
cat > "$T/curl" <<'SH'
#!/bin/bash
printf 'curl %s\n' "$*" >> "$FAKE/calls.log"
cat > "$FAKE/curl.stdin"
out=''; while [ $# -gt 0 ]; do [ "$1" = -o ] && out=$2; shift; done
printf '{"code":"%s"}' "$FAKE_CODE" > "$out"
printf 200
SH
chmod +x "$T/kubectl" "$T/hubadm" "$T/curl" "$T/credpol"
export FAKE=$T FAKE_CODE=$CODE FLEET_MOVE_KUBECTL="$T/kubectl" FLEET_MOVE_HUB_ADMIN="$T/hubadm" FLEET_MOVE_CRED_POLICY="$T/credpol" \
  FLEET_HUB_CURL="$T/curl" FLEET_MOVE_STATE="$T/state" FLEET_MOVE_WAIT=5 CCQUOTA_VIEWER_TOKEN=tok-xyz
RARGS=(-- --image reg.example/fleet-managed-node@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa --hub https://hub.example
       --storage-class essd --cred-central http://fleet-credproxy.fleet-workers.svc.cluster.local)
mv() { "$BIN/fleet-move-to-pod.sh" "$@" --principal gh:7 --source node-a-0 --hub https://hub.example "${RARGS[@]}"; }

# ── A. the order
for args in "copy 24acme --pod u-test1" "start 24acme --pod u-test1" "retire 24acme --pod u-test1" "stop 24acme --pod u-test1"; do
  # shellcheck disable=SC2086
  mv $args >/dev/null 2>"$T/err"; rc=$?
  [ "$rc" = 3 ] || fail "A: '$args' out of order exited $rc, want 3 ($(cat "$T/err"))"
done
grep -q 'login stop\|apply ' "$LOG" && fail "A: a refused phase did something: $(grep -E 'login stop|apply ' "$LOG")"
ok
"$BIN/fleet-move-to-pod.sh" check 24acme >/dev/null 2>&1; [ $? = 2 ] || fail 'A: no --principal is not usage'
ok

# ── B. attached
rm -rf "$T/state"; : > "$LOG"
mv check 24acme >/dev/null || fail 'B: check failed'
mv prepare 24acme >/dev/null || fail 'B: prepare failed'
FAKE_ATTACHED=1 mv stop 24acme >/dev/null 2>"$T/err"; rc=$?
[ "$rc" = 3 ] && grep -q 'attached' "$T/err" || fail "B: stop with a client attached exited $rc ($(cat "$T/err"))"
grep -q 'login stop' "$LOG" && fail 'B: login stop ran while someone was attached'
ok

# ── C. all
rm -rf "$T/state" "$T/assigned" "$T/seeder" "$T/stopped" "$T/src" "$T/dst"; : > "$LOG"
mkdir -p "$T/src/24acme/.codex/tmp" "$T/src/24acme/.config/claude-fleet/cred-proxy/codex-homes/w1" "$T/dst"
echo 'moves with the home' > "$T/src/24acme/work.txt"
echo tmp > "$T/src/24acme/.codex/tmp/x"; echo tmp > "$T/src/24acme/.config/claude-fleet/cred-proxy/codex-homes/w1/y"
mv all 24acme > "$T/out" 2>&1 || fail "C: all failed: $(tail -5 "$T/out")"
POD=$(cat "$T/state/24acme/pod")
[[ "$POD" =~ ^u-[a-z0-9]{10}$ ]] || fail "C: picked pod name '$POD'"
dep=$(grep "^apply Deployment $POD " "$LOG") || fail 'C: the Deployment was never applied'
printf '%s' "$dep" | grep -q '"name": "FLEET_POD_UID", "value": "10006"' || fail 'C: the pod is not built with the source uid 10006'
printf '%s' "$dep" | grep -q '"runAsUser": 10006' || fail 'C: the pod does not run as 10006'
grep -q "^apply Pod $POD-seed .*\"runAsUser\": 10006" "$LOG" || fail 'C: the seeder does not run as the login'
grep -q 'fleet-node-linux.py login stop 24acme' "$LOG" || fail 'C: the source never ran login stop'
grep -q 'fleet-down' "$LOG" && fail 'C: fleet-down ran — the pod restore would skip a down fleet'
[ "$(cat "$T/secret.stdin")" = "$CODE" ] || fail 'C: the join code did not reach its Secret on stdin'
grep -q "$CODE" "$LOG" && fail 'C: the join code is in an argv'
grep -rq "$CODE" "$T/state" && fail 'C: the join code was written to the state dir'
grep -q 'tok-xyz' "$LOG" && fail 'C: the operator token is in an argv'
grep -q 'tok-xyz' "$T/curl.stdin" || fail 'C: the token did not go to curl on stdin'
grep -q "rm -f /data/homes/24acme/.config/claude-fleet/node.env .*node.pub.env .*credsep.json" "$LOG" ||
  fail 'C: the shared-node files were not cleared on the copy'
[ "$(cat "$T/dst/24acme/work.txt" 2>/dev/null)" = 'moves with the home' ] || fail 'C: the home did not arrive on the pod disk'
[ ! -e "$T/dst/24acme/.codex/tmp/x" ] && [ ! -e "$T/dst/24acme/.config/claude-fleet/cred-proxy/codex-homes/w1/y" ] ||
  fail 'C: the copy took the throwaway trees'
grep -q 'kubectl .* -- tar ' "$LOG" && fail 'C: a tar ran through kubectl exec — the home went through this machine'
tokline=$(grep -h '^TOKEN=' "$T/send.py") && tok=${tokline#TOKEN=b\"} && tok=${tok%\"}
[ "${#tok}" = 32 ] || fail "C: no one-time token in the source half ($tokline)"
grep -q "$tok" "$LOG" && fail 'C: the copy token is in an argv'
grep -rq "$tok" "$T/state" && fail 'C: the copy token was written to the state dir'
grep -q "hubadm .*accounts assign gh:7 --host $POD --login 24acme --own-name" "$LOG" || fail 'C: no assign --own-name on the pod'
grep -q "credpol set --force node $POD codex:account:0123\$" "$LOG" || fail 'C: the allow-list was not copied'
grep -q "fleet.cred_allow" "$LOG" && fail 'C: the allow-list went through the settings road (the hub refuses it: 400)'
a_set=$(grep -n "credpol set " "$LOG" | head -1 | cut -d: -f1)
a_get=$(awk -v s="$a_set" '/credpol show/ && NR > s {print NR; exit}' "$LOG")
a_asg=$(grep -n "hubadm .*accounts assign" "$LOG" | head -1 | cut -d: -f1)
[ -n "$a_get" ] && [ "$a_set" -lt "$a_asg" ] && [ "$a_get" -lt "$a_asg" ] ||
  fail "C: the allow-list must be set and read back before the login opens (set $a_set · get $a_get · assign $a_asg)"
grep -q "curl .*-X PUT .*/v1/fleet/entry/home?principal=gh:7" "$LOG" || fail 'C: the home was not moved'
order=$(awk '{print $2}' "$T/state/24acme/timeline" | uniq | tr '\n' ' ')
[ "$order" = "check prepare stop copy start open home verify " ] || fail "C: timeline order '$order'"
grep -q ' check uid=10006 sessions=0' "$T/state/24acme/timeline" || fail 'C: the fake snapshot leaked into check'
grep -q ' verify sessions=2/2' "$T/state/24acme/timeline" ||
  fail 'C: verify did not count the 2 sessions the stop pinned (the pinned list was read before the snapshot save)'
grep -q ' accounts remove' "$LOG" && fail 'C: all retired the source'
ok

# ── F. a source with no allow-list: open refuses (3) before any assign
rm -f "$T/assigned" "$T/allow.set"; : > "$LOG"
FAKE_NO_ALLOW=1 mv open 24acme > "$T/out" 2>&1; rc=$?
[ "$rc" = 3 ] && grep -q 'no subscription allow-list' "$T/out" || fail "F: no allow-list: rc $rc, $(cat "$T/out")"
grep -q 'accounts assign' "$LOG" && fail 'F: the login was opened on an open machine'
FAKE_NO_ALLOW=1 mv open 24acme --allow-list-none >/dev/null 2>&1 || fail 'F: --allow-list-none did not open'
grep -q 'accounts assign' "$LOG" || fail 'F: --allow-list-none never assigned'
ok

# ── G. a pod half that does not know the token gets nothing, and copy says so
rm -rf "$T/dst"/* "$T/send.rc" "$T/recv.rc"
FAKE_BADTOKEN=1 mv copy 24acme > "$T/out" 2>&1; rc=$?
[ "$rc" = 1 ] && grep -q 'source tar: badtoken' "$T/out" || fail "G: a wrong token: rc $rc, $(tail -2 "$T/out")"
[ ! -e "$T/dst/24acme/work.txt" ] || fail 'G: a wrong token still got the home'
ok

# ── D. a session missing
FAKE_BACK=fid-1 mv verify 24acme > "$T/out" 2>&1; rc=$?
[ "$rc" = 1 ] && grep -q 'MISSING: work' "$T/out" || fail "D: a missing session: rc $rc, $(cat "$T/out")"
ok

# ── E. retire
mv retire 24acme >/dev/null || fail 'E: retire failed'
grep -q 'hubadm .*accounts remove gh:7 --host node-a-0 --delete' "$LOG" || fail 'E: the source login was not closed'
ok

printf 'fleet-move-to-pod selftest: OK (%d checks)\n' "$CHECKS"
