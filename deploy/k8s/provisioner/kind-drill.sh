#!/usr/bin/env bash
# The cluster half of the two BREAK-IT rows of #3558 (EPIC #3500 C16), on a
# throwaway kind cluster with a local registry (.github/workflows/cluster-perms.yml):
# fleet-workers' accounts, fleet-ops' Role, the provisioner, its Role and its
# admission policy, applied as the README says; then
#
#   can-i                     `kubectl auth can-i --list` for every account —
#                             only fleet-provisioner may write
#   provisioner-off-template  as the provisioner's own account, every way off
#                             the template is denied by RBAC or the policy, the
#                             template itself is admitted; over its HTTP door an
#                             unsigned / replayed ticket is refused, the hub's runs
#   sa-token-in-user-pod      the user pod the provisioner made, a pod naming
#                             fleet-user with no automount line, and a Job: no
#                             token in any, the API server out of reach / 401
#
#   kind-drill.sh <registry host:port>      (kind-action's LOCAL_REGISTRY)
#
# The user pod and the Job run stand-in images (alpine): the managed-node image
# needs a signed hub release. Needs kubectl on the kind context, docker, python3.
set -euo pipefail
[ $# = 1 ] || { sed -n '2,20p' "$0" >&2; exit 2; }
REG=$1
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../../.." && pwd)
NS=fleet-workers
PROV=system:serviceaccount:$NS:fleet-provisioner
K() { kubectl -n "$NS" "$@"; }
step() { echo; echo "== $*"; }
fail() { echo "FAIL $*" >&2; exit 1; }
tmp=$(mktemp -d)
pf=
trap '[ -n "$pf" ] && kill "$pf" 2>/dev/null; rm -rf "$tmp"' EXIT
summary() { [ -n "${GITHUB_STEP_SUMMARY:-}" ] && cat >> "$GITHUB_STEP_SUMMARY" || cat >/dev/null; }

step "stand-in images, pushed to $REG and pinned by digest"
push() { # push <name> <context dir> → prints the image@digest
  docker build -q -t "$REG/$1:drill" "$2" >/dev/null
  docker push -q "$REG/$1:drill" >/dev/null
  docker inspect --format '{{index .RepoDigests 0}}' "$REG/$1:drill"
}
mkdir -p "$tmp/prov/t/bin" "$tmp/prov/t/extras/managed-node" "$tmp/user" "$tmp/job"
cp "$ROOT"/bin/{fleet-provisioner.py,fleet_cluster_ticket.py,fleet_admin_ticket.py,fleet_ed25519.py} "$tmp/prov/t/bin/"
cp "$ROOT/extras/managed-node/render.py" "$tmp/prov/t/extras/managed-node/"
# the managed-node image's layout: python3 at /usr/bin, the tree at the seed's current
printf 'FROM python:3.12-slim\nRUN ln -sf /usr/local/bin/python3 /usr/bin/python3\nCOPY t/ /opt/claude-fleet/seed/current/\n' \
  > "$tmp/prov/Dockerfile"
printf 'FROM alpine:3.20\nRUN apk add --no-cache iptables ip6tables curl\nCMD ["sleep", "infinity"]\n' > "$tmp/user/Dockerfile"
cat > "$tmp/job/probe.sh" <<'EOF'
#!/bin/sh
t=absent; [ -e /var/run/secrets/kubernetes.io/serviceaccount/token ] && t=present
code=$(curl -sk -o /dev/null -w '%{http_code}' -m 5 "https://kubernetes.default.svc/api/v1/namespaces/fleet-workers/pods" || echo none)
echo "PROBE token=$t uid=$(id -u) api=$code"
EOF
printf 'FROM alpine:3.20\nRUN apk add --no-cache curl\nCOPY probe.sh /probe.sh\nRUN chmod 755 /probe.sh\nCMD ["/probe.sh"]\n' > "$tmp/job/Dockerfile"
PROV_IMG=$(push fleet-provisioner "$tmp/prov")
USER_IMG=$(push fleet-user-standin "$tmp/user")
JOB_IMG=$(push fleet-job-standin "$tmp/job")
echo "provisioner $PROV_IMG"; echo "user pod    $USER_IMG"; echo "job         $JOB_IMG"

step "fleet-workers: accounts, fleet-ops' Role, network rules, the provisioner and its policy"
kubectl create namespace "$NS"
kubectl apply -f "$ROOT/deploy/k8s/fleet-workers/serviceaccounts.yaml"
kubectl apply -f "$ROOT/deploy/k8s/fleet-workers/networkpolicy.yaml"
kubectl kustomize "$HERE" | sed "s#image: fleet-provisioner-image\$#image: $PROV_IMG#" \
  | kubectl apply -f -
head -c 32 /dev/urandom > "$tmp/key"
python3 "$ROOT/bin/fleet_cluster_ticket.py" pub "$tmp/key" > "$tmp/account.pub"
DNS=$(kubectl -n kube-system get svc kube-dns -o jsonpath='{.spec.clusterIP}')
SVC_CIDR=$(kubectl cluster-info dump 2>/dev/null | grep -m1 -o 'service-cluster-ip-range=[0-9./]*' | cut -d= -f2 || true)
python3 - "$USER_IMG" "$JOB_IMG" "$DNS" "${SVC_CIDR:-10.96.0.0/12}" > "$tmp/template.json" <<'EOF'  # oss-ok: kind's own default service range
import json, sys
user, job, dns, svc = sys.argv[1:]
print(json.dumps({"cluster": "kind", "namespace": "fleet-workers",
    "user_pod": {"image": user, "hub": "https://hub.example.com", "storage_class": "standard",
                 "egress": {"dns": dns, "service_cidr": svc, "pod_cidr": "10.244.0.0/16"}},  # oss-ok: kind's own default pod range
    "job": {"image": job}}))
EOF
K create configmap fleet-provisioner --from-file=template.json="$tmp/template.json" --from-file=account.pub="$tmp/account.pub"
K rollout status deploy/fleet-provisioner --timeout=180s

step "can-i: every account's permissions in $NS"
WRITE='create|delete|patch|update|[*]'
{
  echo "### kubectl auth can-i --list (namespace $NS)"
  for sa in $(K get sa -o jsonpath='{.items[*].metadata.name}'); do
    [ "$sa" = default ] && continue
    echo; echo "#### $sa"; echo '```'
    K auth can-i --list --as "system:serviceaccount:$NS:$sa"
    echo '```'
  done
} | tee "$tmp/can-i.md" | summary
cat "$tmp/can-i.md"
writers=$(for sa in $(K get sa -o jsonpath='{.items[*].metadata.name}'); do
  # the last [...] of a row is its verbs; every account may create a self-review
  K auth can-i --list --as "system:serviceaccount:$NS:$sa" | awk -v sa="$sa" -v w="$WRITE" '
    NR > 1 && $1 !~ /^selfsubject/ { v = $0; sub(/.*\[/, "[", v); if (v ~ w) { print sa; exit } }'
done | sort -u | tr '\n' ' ')
[ "$writers" = "fleet-provisioner " ] || fail "can-i: accounts that may write: '$writers' (want fleet-provisioner alone)"
echo "only fleet-provisioner may write"

step "render the template the provisioner uses, and the ways off it"
python3 - "$ROOT" "$tmp" "$USER_IMG" "$JOB_IMG" "$DNS" <<'EOF'
import copy, json, sys
root, tmp, user, job, dns = sys.argv[1:]
sys.path.insert(0, root + "/extras/managed-node")
import render as r
objs = r.user_pod_resources(user, "https://hub.example.com", "standard", "u-dryrun1", egress={"dns": dns})
dep = [o for o in objs if o["kind"] == "Deployment"][0]
svc = [o for o in objs if o["kind"] == "Service"][0]
jb = r.job_resources(job, "u-dryrun1", "o/r", "b" * 40, "d" * 32)[0]
def w(name, o): json.dump(o, open("%s/%s.json" % (tmp, name), "w"))
def mut(o, f):
    o = copy.deepcopy(o); f(o); return o
c0 = lambda o: o["spec"]["template"]["spec"]["containers"][0]
ps = lambda o: o["spec"]["template"]["spec"]
w("good-dep", dep); w("good-svc", svc); w("good-job", jb)
w("bad-privileged", mut(dep, lambda o: c0(o)["securityContext"].update(privileged=True)))
w("bad-escalation", mut(dep, lambda o: c0(o)["securityContext"].update(allowPrivilegeEscalation=True)))
w("bad-sysadmin", mut(dep, lambda o: c0(o)["securityContext"]["capabilities"]["add"].append("SYS_ADMIN")))
w("bad-hostpath", mut(dep, lambda o: ps(o)["volumes"].append({"name": "h", "hostPath": {"path": "/"}})))
w("bad-hostnetwork", mut(dep, lambda o: ps(o).update(hostNetwork=True)))
w("bad-token", mut(dep, lambda o: ps(o).update(automountServiceAccountToken=True)))
w("bad-account", mut(dep, lambda o: ps(o).update(serviceAccountName="fleet-provisioner")))
w("bad-tag", mut(dep, lambda o: c0(o).update(image="alpine:3.20")))
w("bad-label", mut(dep, lambda o: o["metadata"]["labels"].update({"fleet/role": "door"})))
w("bad-lb", mut(svc, lambda o: o["spec"].update(type="LoadBalancer")))
w("bad-job-root", mut(jb, lambda o: (ps(o)["securityContext"].update(runAsNonRoot=False, runAsUser=0),
                                       c0(o)["securityContext"].update(runAsNonRoot=False, runAsUser=0))))
w("bad-job-caps", mut(jb, lambda o: c0(o)["securityContext"]["capabilities"].update(add=["NET_RAW"])))
w("bad-ns", mut(dep, lambda o: o["metadata"].update(namespace="default")))
w("bad-pod", {"apiVersion": "v1", "kind": "Pod", "metadata": {"name": "p", "namespace": "fleet-workers",
    "labels": {"fleet/role": "user"}}, "spec": ps(dep)})
w("bad-secret", {"apiVersion": "v1", "kind": "Secret", "metadata": {"name": "s", "namespace": "fleet-workers",
    "labels": {"fleet/role": "user"}}, "stringData": {"k": "v"}})
EOF

step "provisioner-off-template: as $PROV"
for f in "$tmp"/good-*.json; do
  kubectl create --dry-run=server --as "$PROV" -f "$f" -o name >/dev/null 2>"$tmp/err" \
    || fail "the template itself was refused ($(basename "$f")): $(cat "$tmp/err")"
  echo "admitted  $(basename "$f" .json)"
done
for f in "$tmp"/bad-*.json; do
  if kubectl create --dry-run=server --as "$PROV" -f "$f" -o name >/dev/null 2>"$tmp/err"; then
    fail "$(basename "$f" .json) was admitted"
  fi
  echo "denied    $(basename "$f" .json): $(head -c 160 "$tmp/err" | tr '\n' ' ')"
done
# somebody else's object: the door's Deployment (made here by the admin)
python3 - "$tmp/good-dep.json" "$USER_IMG" > "$tmp/door.json" <<'EOF'
import json, sys
o = json.load(open(sys.argv[1]))
o["metadata"].update(name="fleet-door", labels={"fleet/role": "door", "app.kubernetes.io/name": "fleet-door"})
o["spec"]["selector"] = {"matchLabels": {"fleet/role": "door"}}
o["spec"]["template"]["metadata"]["labels"] = {"fleet/role": "door"}
o["spec"]["replicas"] = 0
print(json.dumps(o))
EOF
K apply -f "$tmp/door.json" >/dev/null
for verb in "delete deploy/fleet-door" "delete deploy/fleet-provisioner" \
            "patch deploy/fleet-door --type merge -p {\"metadata\":{\"labels\":{\"fleet/role\":\"user\"}}}" \
            "patch deploy/fleet-provisioner --type merge -p {\"spec\":{\"replicas\":3}}"; do
  # shellcheck disable=SC2086  # the verb's words
  if K $verb --dry-run=server --as "$PROV" >/dev/null 2>"$tmp/err"; then fail "$verb was allowed"; fi
  echo "denied    $verb: $(head -c 120 "$tmp/err" | tr '\n' ' ')"
done

step "provisioner-off-template: its HTTP door, the hub's tickets"
K port-forward svc/fleet-provisioner 18790:8790 >/dev/null 2>&1 & pf=$!
for _ in $(seq 1 50); do curl -fsS -m 2 http://127.0.0.1:18790/healthz >/dev/null 2>&1 && break; sleep 0.2; done
tk() { python3 "$ROOT/bin/fleet_cluster_ticket.py" sign "$1" "$2"; }
post() { curl -s -m 30 -o "$tmp/resp" -w '%{http_code}' --data-binary "$1" http://127.0.0.1:18790/v1/op; }
exp=$(( $(date +%s) + 300 ))
good=$(tk "$tmp/key" '{"op":"create-user-pod","cluster":"kind","pod":"u-drill1","limits":"","nonce":"0123456789abcdef0123456789abcdef","exp":'"$exp"'}')
head -c 32 /dev/urandom > "$tmp/other"
[ "$(post 'not a ticket')" = 403 ] || fail "an unsigned body: $(cat "$tmp/resp")"
[ "$(post "$(tk "$tmp/other" '{"op":"create-user-pod","cluster":"kind","pod":"u-drill1","limits":"","nonce":"0123456789abcdef0123456789abcdef","exp":'"$exp"'}')")" = 403 ] \
  || fail "a forged ticket: $(cat "$tmp/resp")"
K get deploy u-drill1 >/dev/null 2>&1 && fail "a refused ticket made a pod"
[ "$(post "$good")" = 200 ] || fail "the hub's ticket: $(cat "$tmp/resp")"
cat "$tmp/resp"
[ "$(post "$good")" = 403 ] && grep -q 'already used' "$tmp/resp" || fail "a replay: $(cat "$tmp/resp")"
echo "refused: unsigned · forged · replay; the hub's create ran once"

step "sa-token-in-user-pod: the user pod, a bare fleet-user pod, a Job"
notoken() { # notoken <pod name>: no token volume in its spec
  K get pod "$1" -o json | python3 -c '
import json, sys
p = json.load(sys.stdin)["spec"]
vols = [v["name"] for v in p.get("volumes", []) for s in (v.get("projected") or {}).get("sources", []) if "serviceAccountToken" in s]
mounts = [m["mountPath"] for c in p["containers"] + p.get("initContainers", []) for m in c.get("volumeMounts", []) if "serviceaccount" in m["mountPath"]]
sys.exit("token volume %s mounted at %s" % (vols, mounts) if vols or mounts else 0)'
}
for _ in $(seq 1 60); do upod=$(K get pod -l fleet/pod=u-drill1 -o jsonpath='{.items[0].metadata.name}' 2>/dev/null) && [ -n "$upod" ] && break; sleep 1; done
[ -n "${upod:-}" ] || fail "the provisioner's user pod never appeared"
notoken "$upod" || fail "user pod $upod"
echo "user pod $upod: no token in its spec"
if K wait --for=jsonpath='{.status.phase}'=Running "pod/$upod" --timeout=120s >/dev/null 2>&1; then
  K exec "$upod" -c fleet -- sh -c 'test ! -e /var/run/secrets/kubernetes.io/serviceaccount/token' \
    || fail "user pod $upod has a token file"
  code=$(K exec "$upod" -c fleet -- sh -c 'curl -sk -o /dev/null -w "%{http_code}" -m 5 https://kubernetes.default.svc/api || true')
  case "$code" in 200) fail "user pod reached the API server with its own credentials" ;; esac
  echo "user pod $upod: no token file; the API server: ${code:-unreachable} (000 = the egress guard cut it)"
else
  K describe pod "$upod" | tail -15
  echo "user pod $upod not Running (its home disk here) — its spec is the proof"
fi
# an account-level default: a pod naming fleet-user that says nothing about tokens
K run bare --image "$JOB_IMG" --restart=Never --overrides '{"spec":{"serviceAccountName":"fleet-user"}}' >/dev/null
notoken bare || fail "a pod naming fleet-user got a token from its account"
echo "a bare fleet-user pod: no token (the account's own automount false)"
jobt=$(tk "$tmp/key" '{"op":"create-job","cluster":"kind","pod":"u-drill1","repo":"o/r","ref":"'"$(printf 'b%.0s' $(seq 1 40))"'","nonce":"11111111111111111111111111111111","exp":'"$exp"'}')
[ "$(post "$jobt")" = 200 ] || fail "the hub's Job: $(cat "$tmp/resp")"
K wait --for=condition=complete job/job-111111111111 --timeout=180s >/dev/null || { K describe job job-111111111111 | tail -20; fail "the Job never completed"; }
out=$(K logs job/job-111111111111)
echo "$out"
printf '%s' "$out" | grep -q 'token=absent' || fail "the Job found a token"
printf '%s' "$out" | grep -q 'uid=0 ' && fail "the Job ran as root"
printf '%s' "$out" | grep -q 'api=200' && fail "the Job used the API server"
{ echo; echo "### sa-token-in-user-pod"; echo '```'; echo "$out"; echo '```'; } | summary
echo; echo "PASS sa-token-in-user-pod · provisioner-off-template (kind)"
