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
#   root-in-user-pod          a person's pod running: `id` and `ps` in its fleet
#                             container are the login alone, in sshd root alone
#                             until a login, then root + the login; /etc/passwd
#                             read-only; a real ssh login with the door's key
#                             lands as the login, root's is refused (#3757)
#   job-sees-keys             a test and an untrusted Job (#3552): no token, no
#                             credential, nothing mounted, not root; untrusted
#                             never reaches the public internet; both deleted
#                             by their TTL
#   svc-run-sees-keys         two service runs' Jobs one after the other (#4005):
#                             the second finds nothing the first left in /work,
#                             /out or /tmp; neither reaches the metadata
#                             address, the API server, another pod or a private
#                             range (the closed guard); no token, not root; both
#                             Jobs, their pods and their key Secrets gone by
#                             their TTL
#
#   kind-drill.sh <registry host:port>      (kind-action's LOCAL_REGISTRY)
#
# The user pod and the Job run stand-in images: the managed-node image needs a
# signed hub release. The user pod's is debian with python3, openssh-server and
# procps, fleet-node-linux.py at the seed's place (its pod-etc init runs for
# real) and a stand-in node that only writes a fleet-entry.sh on the disk and
# sleeps — as the login. Needs kubectl on the kind context, docker, python3, ssh.
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
mkdir -p "$tmp/user/t/bin"
cp "$ROOT/bin/fleet-node-linux.py" "$tmp/user/t/bin/"
# the stand-in node: as the login, on its own disk, the ForceCommand a login
# lands in (it says who it is and what runs in its container), then sleep
cat > "$tmp/user/standin.sh" <<'SH'
#!/bin/sh
set -e
b=/var/db/fleet-node/runtime/current/bin
mkdir -p "$b" "$HOME"
printf '#!/bin/bash\necho "ENTRY $(id -un) $(id -u) | $(ps -o user= -e | sort -u | tr "\\n" " ")"\n' > "$b/fleet-entry.sh"
exec sleep infinity
SH
cat > "$tmp/user/Dockerfile" <<'DF'
FROM debian:trixie-slim
RUN apt-get update -qq && apt-get install -y --no-install-recommends python3 openssh-server procps iptables zsh \
    && rm -rf /var/lib/apt/lists/* && mkdir -p /run/sshd
COPY t/ /opt/claude-fleet/seed/current/
COPY standin.sh /standin.sh
RUN chmod 755 /standin.sh
CMD ["/standin.sh"]
DF
cat > "$tmp/job/probe.sh" <<'EOF'
#!/bin/sh
t=absent; [ -e /var/run/secrets/kubernetes.io/serviceaccount/token ] && t=present
code=$(curl -sk -o /dev/null -w '%{http_code}' -m 5 "https://kubernetes.default.svc/api/v1/namespaces/fleet-workers/pods" || echo none)
# job-sees-keys (#3552): the public internet, credentials in the environment, a home
net=$(curl -s -o /dev/null -w '%{http_code}' -m 5 https://www.google.com 2>/dev/null); net=${net:-000}
keys=$(env | grep -v '^FLEET_JOB_CMD=' | grep -Eic 'token|secret|password|credential|_key=')
homes=$(ls -A /home 2>/dev/null | wc -l | tr -d ' ')
mounts=$(grep -Ec ' /(home|root|var/run/secrets)' /proc/mounts)
echo "PROBE token=$t uid=$(id -u) api=$code net=$net keys=$keys homes=$homes mounts=$mounts"
EOF
# the Job's runner where the managed-node image keeps it (render.py JOB_RUNNER)
mkdir -p "$tmp/job/seed/bin"
cp "$ROOT/bin/fleet-job-runner.sh" "$tmp/job/seed/bin/"
printf 'FROM alpine:3.20\nRUN apk add --no-cache curl\nCOPY probe.sh /probe.sh\nCOPY seed/ /opt/claude-fleet/seed/current/\nRUN chmod 755 /probe.sh\nCMD ["/probe.sh"]\n' > "$tmp/job/Dockerfile"
# a service run's stand-in (#4005): the Job's real template, a probe at the
# runner's place — fetch lists what an earlier run could have left and marks
# /work /out /tmp; run tries every way out the guard must cut
mkdir -p "$tmp/svc/seed/bin"
cat > "$tmp/svc/seed/bin/fleet-svc-runner.py" <<'EOF'
import os, socket, sys
mode, run = sys.argv[1], os.environ.get("FLEET_SVC_RUN", "?")
dirs = ("/work", "/out", "/tmp")
if mode == "fetch":
    left = sorted(f for d in dirs for f in os.listdir(d) if f.startswith("mark-"))
    for d in dirs:
        open(os.path.join(d, "mark-" + run), "w").write(run)
    print("PROBE-FETCH %s left=%s" % (run, ",".join(left) or "-"), flush=True)
    sys.exit(0)
def reach(host, port):
    if not host:
        return "closed"
    try:
        socket.create_connection((host, port), timeout=4).close()
        return "open"
    except OSError:
        return "closed"
try:
    api = socket.gethostbyname("kubernetes.default.svc.cluster.local"); dns = "ok"
except OSError:
    api, dns = "", "fail"
prov = socket.gethostbyname("fleet-provisioner.fleet-workers.svc.cluster.local") if dns == "ok" else ""
token = "present" if os.path.exists("/var/run/secrets/kubernetes.io/serviceaccount/token") else "absent"
keys = [k for k in os.environ if any(w in k.upper() for w in ("TOKEN", "SECRET", "PASSWORD", "CREDENTIAL"))]
print("PROBE-RUN %s uid=%d token=%s keys=%d dns=%s meta=%s api=%s prov=%s private=%s net=%s" % (
    run, os.getuid(), token, len(keys), dns, reach("100.100.100.200", 80), reach(api, 443), reach(prov, 8790),
    reach("10.0.0.1", 80), reach("1.1.1.1", 443)), flush=True)  # oss-ok: a private address the guard must cut
EOF
printf 'FROM debian:trixie-slim\nRUN apt-get update -qq && apt-get install -y --no-install-recommends python3 iptables && rm -rf /var/lib/apt/lists/*\nCOPY seed/ /opt/claude-fleet/seed/current/\n' > "$tmp/svc/Dockerfile"
PROV_IMG=$(push fleet-provisioner "$tmp/prov")
USER_IMG=$(push fleet-user-standin "$tmp/user")
JOB_IMG=$(push fleet-job-standin "$tmp/job")
SVC_IMG=$(push fleet-svc-standin "$tmp/svc")
echo "provisioner $PROV_IMG"; echo "user pod    $USER_IMG"; echo "job         $JOB_IMG"; echo "svc run     $SVC_IMG"

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
python3 - "$USER_IMG" "$JOB_IMG" "$DNS" "${SVC_CIDR:-10.96.0.0/12}" "$SVC_IMG" > "$tmp/template.json" <<'EOF'  # oss-ok: kind's own default service range
import json, sys
user, job, dns, svc, run = sys.argv[1:]
eg = {"dns": dns, "service_cidr": svc, "pod_cidr": "10.244.0.0/16"}  # oss-ok: kind's own default pod range
print(json.dumps({"cluster": "kind", "namespace": "fleet-workers",
    "user_pod": {"image": user, "hub": "https://hub.example.com", "storage_class": "standard",
                 "cred_central": "http://fleet-credproxy.fleet-workers.svc.cluster.local", "egress": eg},
    "job": {"image": job, "ttl": 30},
    # a service run (#4005): the guard's one allowed road is a TEST-NET address here
    "svc": {"image": run, "hub": "https://hub.example.com",
            "cred_central": "http://fleet-credproxy.fleet-workers.svc.cluster.local",
            "egress_proxy": "http://fleet-egress-run.fleet-workers.svc.cluster.local:3128",
            "egress": dict(eg, allow=["192.0.2.1:3128"]), "ttl": 30}}))
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
python3 - "$ROOT" "$tmp" "$USER_IMG" "$JOB_IMG" "$DNS" "$SVC_IMG" <<'EOF'
import copy, json, sys
root, tmp, user, job, dns, run = sys.argv[1:]
sys.path.insert(0, root + "/extras/managed-node")
import render as r
CENTRAL = "http://fleet-credproxy.fleet-workers.svc.cluster.local"
objs = r.user_pod_resources(user, "https://hub.example.com", "standard", "u-dryrun1", egress={"dns": dns},
                            login="dryrun1", uid=10002, cred_central=CENTRAL)
dep = [o for o in objs if o["kind"] == "Deployment"][0]
svc = [o for o in objs if o["kind"] == "Service"][0]
jb = r.job_resources(job, "u-dryrun1", "o/r", "b" * 40, "d" * 32)[0]
def w(name, o): json.dump(o, open("%s/%s.json" % (tmp, name), "w"))
def mut(o, f):
    o = copy.deepcopy(o); f(o); return o
c0 = lambda o: o["spec"]["template"]["spec"]["containers"][0]
sd = lambda o: [c for c in o["spec"]["template"]["spec"]["containers"] if c["name"] == "sshd"][0]
fl = lambda o: [c for c in o["spec"]["template"]["spec"]["containers"] if c["name"] == "fleet"][0]
ps = lambda o: o["spec"]["template"]["spec"]
w("good-dep", dep); w("good-svc", svc); w("good-job", jb)
# a person's pod on two images (#4174): roll-user-pod moves the four together
w("bad-two-images", mut(dep, lambda o: c0(o).update(image=c0(o)["image"].split("@")[0] + "@sha256:" + "e" * 64)))
# root-in-user-pod (#3757): the way back to root, as the provisioner's account
w("bad-root-fleet", mut(dep, lambda o: fl(o)["securityContext"].update(runAsUser=0, runAsNonRoot=False)))
w("bad-fleet-caps", mut(dep, lambda o: fl(o)["securityContext"]["capabilities"].update(add=["CHOWN"])))
w("bad-sshd-caps", mut(dep, lambda o: sd(o)["securityContext"]["capabilities"]["add"].append("DAC_OVERRIDE")))
# a person's pod that runs (applied by the admin, not the provisioner): kind's
# disks take no ReadWriteOncePod, so its claim says ReadWriteOnce — every other
# byte is the template's
live = r.user_pod_resources(user, "https://hub.example.com", "standard", "u-live1", egress={"dns": dns},
                            login="live1", uid=10002, cred_central=CENTRAL)
for o in live:
    if o["kind"] == "PersistentVolumeClaim":
        o["spec"]["accessModes"] = ["ReadWriteOnce"]
json.dump({"apiVersion": "v1", "kind": "List", "items": live}, open(tmp + "/live.json", "w"))
w("bad-privileged", mut(dep, lambda o: c0(o)["securityContext"].update(privileged=True)))
w("bad-escalation", mut(dep, lambda o: c0(o)["securityContext"].update(allowPrivilegeEscalation=True)))
w("bad-sysadmin", mut(dep, lambda o: sd(o)["securityContext"]["capabilities"]["add"].append("SYS_ADMIN")))
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
# a user pod's join Secret (#3553): <fleet/pod>-join, labelled, one key — and the ways off it
sec = {"apiVersion": "v1", "kind": "Secret", "type": "Opaque", "metadata": {"name": "u-dryrun1-join",
       "namespace": "fleet-workers", "labels": {"fleet/role": "user", "fleet/pod": "u-dryrun1"}},
       "data": {"machine": "ZmpfeA=="}}
w("good-secret", sec)
w("bad-secret-door", mut(sec, lambda o: o["metadata"].update(name="fleet-door")))
w("bad-secret-twokeys", mut(sec, lambda o: o["data"].update(token="eA==")))
w("bad-secret-unlabelled", mut(sec, lambda o: o["metadata"].update(labels={"fleet/pod": "u-dryrun1"})))
# a service run's Job and its key (#4005) — and the ways off them
sj = r.svc_run_resources(run, "R900", 1, "livepage", 900, "https://hub.example.com", CENTRAL,
                         "http://fleet-egress-run.fleet-workers.svc.cluster.local:3128",
                         egress={"dns": dns, "allow": ["192.0.2.1:3128"]})[0]
sk = r.svc_run_key_secret("svc-r900-a1", "fleet-workers", "fsj_" + "a" * 52)
w("good-svc-job", sj); w("good-svc-key", sk)
w("bad-svc-other-secret", mut(sj, lambda o: ps(o)["volumes"].append({"name": "x", "secret": {"secretName": "u-dryrun1-join"}})))
w("bad-svc-run-caps", mut(sj, lambda o: c0(o)["securityContext"]["capabilities"].update(add=["NET_ADMIN"])))
w("bad-svc-run-root", mut(sj, lambda o: c0(o)["securityContext"].update(runAsUser=0, runAsNonRoot=False)))
w("bad-svc-name", mut(sj, lambda o: o["metadata"].update(name="svc-r901-a1")))
w("bad-svc-disk", mut(sj, lambda o: ps(o)["volumes"].append({"name": "d", "persistentVolumeClaim": {"claimName": "u-dryrun1"}})))
w("bad-job-guard", mut(jb, lambda o: ps(o).setdefault("initContainers", []).append(
    [c for c in ps(sj)["initContainers"] if c["name"] == "egress-guard"][0])))
w("bad-svc-key-twokeys", mut(sk, lambda o: o["data"].update(x="eA==")))
w("bad-svc-key-name", mut(sk, lambda o: o["metadata"].update(name="svc-r900-a1-key")))
w("bad-svc-key-owner", mut(sk, lambda o: o["metadata"].update(ownerReferences=[{"apiVersion": "apps/v1",
    "kind": "Deployment", "name": "fleet-door", "uid": "0d6c4b0e-0000-4000-8000-000000000000"}])))
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
good=$(tk "$tmp/key" '{"op":"create-user-pod","cluster":"kind","pod":"u-drill1","limits":"","login":"drill1","uid":10002,"join":"fj_aaaaaaaaaaaaaaaaaaaaaaaaaa","nonce":"0123456789abcdef0123456789abcdef","exp":'"$exp"'}')
head -c 32 /dev/urandom > "$tmp/other"
[ "$(post 'not a ticket')" = 403 ] || fail "an unsigned body: $(cat "$tmp/resp")"
[ "$(post "$(tk "$tmp/other" '{"op":"create-user-pod","cluster":"kind","pod":"u-drill1","limits":"","login":"drill1","uid":10002,"join":"fj_aaaaaaaaaaaaaaaaaaaaaaaaaa","nonce":"0123456789abcdef0123456789abcdef","exp":'"$exp"'}')")" = 403 ] \
  || fail "a forged ticket: $(cat "$tmp/resp")"
K get deploy u-drill1 >/dev/null 2>&1 && fail "a refused ticket made a pod"
[ "$(post "$good")" = 200 ] || fail "the hub's ticket: $(cat "$tmp/resp")"
cat "$tmp/resp"
[ "$(post "$good")" = 403 ] && grep -q 'already used' "$tmp/resp" || fail "a replay: $(cat "$tmp/resp")"
[ "$(K get secret u-drill1-join -o jsonpath='{.data.machine}' | base64 -d)" = fj_aaaaaaaaaaaaaaaaaaaaaaaaaa ] \
  || fail "the create's join Secret is not the ticket's code"
echo "refused: unsigned · forged · replay; the hub's create ran once, its join Secret with it"

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
jobt=$(tk "$tmp/key" '{"op":"create-job","cluster":"kind","pod":"u-drill1","repo":"o/r","ref":"'"$(printf 'b%.0s' $(seq 1 40))"'","kind":"test","cmd":"/probe.sh","nonce":"11111111111111111111111111111111","exp":'"$exp"'}')
[ "$(post "$jobt")" = 200 ] || fail "the hub's Job: $(cat "$tmp/resp")"
K wait --for=condition=complete job/job-111111111111 --timeout=180s >/dev/null || { K describe job job-111111111111 | tail -20; fail "the Job never completed"; }
out=$(K logs job/job-111111111111)
echo "$out"
printf '%s' "$out" | grep -q 'token=absent' || fail "the Job found a token"
printf '%s' "$out" | grep -q 'uid=0 ' && fail "the Job ran as root"
printf '%s' "$out" | grep -q 'api=200' && fail "the Job used the API server"
{ echo; echo "### sa-token-in-user-pod"; echo '```'; echo "$out"; echo '```'; } | summary

step "job-sees-keys: a test Job and an untrusted Job run, find no key, and are deleted (#3552)"
jt=$(tk "$tmp/key" '{"op":"create-job","cluster":"kind","pod":"u-drill1","repo":"o/r","ref":"'"$(printf 'b%.0s' $(seq 1 40))"'","kind":"test","cmd":"/probe.sh; echo built > $FLEET_JOB_OUT/r.txt","nonce":"22222222222222222222222222222222","exp":'"$exp"'}')
ju=$(tk "$tmp/key" '{"op":"create-job","cluster":"kind","pod":"u-drill1","repo":"o/r","ref":"'"$(printf 'b%.0s' $(seq 1 40))"'","kind":"untrusted","cmd":"/probe.sh","nonce":"33333333333333333333333333333333","exp":'"$exp"'}')
[ "$(post "$jt")" = 200 ] || fail "the hub's test Job: $(cat "$tmp/resp")"
[ "$(post "$ju")" = 200 ] || fail "the hub's untrusted Job: $(cat "$tmp/resp")"
[ "$(K get job job-333333333333 -o jsonpath='{.spec.template.metadata.labels.fleet\/job-net}')" = "" ] \
  || fail "the untrusted Job carries an egress label"
for j in job-222222222222 job-333333333333; do
  K wait --for=condition=complete "job/$j" --timeout=180s >/dev/null || { K describe job "$j" | tail -20; K logs "job/$j" || true; fail "$j never completed"; }
done
lt=$(K logs job/job-222222222222); lu=$(K logs job/job-333333333333)
echo "$lt"; echo "$lu"
for l in "$lt" "$lu"; do
  printf '%s' "$l" | grep -q 'token=absent' || fail "a Job found a token"
  printf '%s' "$l" | grep -q 'keys=0 ' || fail "a Job found a credential in its environment"
  printf '%s' "$l" | grep -q 'mounts=0' || fail "a Job has a home or a secret mounted"
  printf '%s' "$l" | grep -q 'uid=0 ' && fail "a Job ran as root"
  printf '%s' "$l" | grep -qx '::fleet-job:: exit 0' || fail "a Job did not say its exit"
done
printf '%s' "$lu" | grep -Eq 'net=(000|none)( |$)' || fail "the untrusted Job reached the public internet: $lu"
printf '%s' "$lt" | grep -q '^::fleet-job:: artifacts [0-9]' || fail "the test Job's outputs never came back in its log"
echo "both Jobs: no token, no credential, nothing mounted, not root; untrusted: no public internet; outputs in the log"
# ttlSecondsAfterFinished (30 s here, 600 s in a cluster): the Jobs and their pods go
for _ in $(seq 1 120); do
  left=$(K get jobs,pods -l fleet/role=job -o name 2>/dev/null | grep -E 'job-(222222222222|333333333333)' || true)
  [ -z "$left" ] && break; sleep 1
done
[ -z "$left" ] || fail "the finished Jobs were never deleted: $left"
gone=$(K get jobs -l fleet/role=job 2>&1)
echo "$gone"
{ echo; echo "### job-sees-keys"; echo '```'; echo "$lt"; echo "$lu"; echo; echo '$ kubectl get jobs -l fleet/role=job'; echo "$gone"; echo '```'; } | summary

step "svc-run-sees-keys: two service runs, one after the other (#4005)"
svckey() { printf 'fsj_%s' "$(head -c 4096 /dev/urandom | LC_ALL=C tr -dc 'a-z2-7' | head -c 52)"; }
for run in R101 R102; do
  j=svc-$(printf '%s' "$run" | tr 'R' 'r')-a1
  [ "$(post "$(tk "$tmp/key" '{"op":"create-svc-run","cluster":"kind","run":"'"$run"'","attempt":1,"svc":"livepage","deadline":120,"token":"'"$(svckey)"'","nonce":"'"$(printf '5%03d%028d' "${run#R}" 0)"'","exp":'"$exp"'}')")" = 200 ] \
    || fail "the hub's create-svc-run $run: $(cat "$tmp/resp")"
  K wait --for=condition=complete "job/$j" --timeout=240s >/dev/null || { K describe job "$j" | tail -20; K logs "job/$j" --all-containers || true; fail "$j never completed"; }
  K get secret "$j-token" -o jsonpath='{.metadata.ownerReferences[0].name}' | grep -qx "$j" || fail "$j's key is not owned by its Job"
done
f1=$(K logs job/svc-r101-a1 -c fetch); r1=$(K logs job/svc-r101-a1 -c run)
f2=$(K logs job/svc-r102-a1 -c fetch); r2=$(K logs job/svc-r102-a1 -c run)
echo "$f1"; echo "$r1"; echo "$f2"; echo "$r2"
printf '%s' "$f1" | grep -q 'left=-$' || fail "the first run found files: $f1"
printf '%s' "$f2" | grep -q 'left=-$' || fail "the second run found what the first left: $f2"
for l in "$r1" "$r2"; do
  printf '%s' "$l" | grep -q 'token=absent' || fail "a run found a token: $l"
  printf '%s' "$l" | grep -q ' keys=0 ' || fail "a run found a credential in its environment: $l"
  printf '%s' "$l" | grep -q 'uid=0 ' && fail "a run ran as root: $l"
  printf '%s' "$l" | grep -q ' dns=ok ' || fail "a run has no DNS: $l"
  for way in meta api prov private net; do
    printf '%s' "$l" | grep -q " $way=closed" || fail "a run reached $way: $l"
  done
done
echo "two runs: the second found nothing of the first; metadata · API server · another Service · private · the open internet (no egress here) all cut; no token, no key, not root"
for _ in $(seq 1 150); do
  left=$(K get jobs,pods,secrets -o name 2>/dev/null | grep -E 'svc-r10[12]-a1' || true)
  [ -z "$left" ] && break; sleep 1
done
[ -z "$left" ] || fail "the finished runs were never deleted: $left"
gone=$(K get jobs,pods -l fleet/svc=livepage 2>&1)
echo "$gone"
{ echo; echo "### svc-run-sees-keys"; echo '```'; echo "$f1"; echo "$r1"; echo "$f2"; echo "$r2"; echo;
  echo '$ kubectl -n fleet-workers get jobs,pods -l fleet/svc=livepage   # after the TTL'; echo "$gone"; echo '```'; } | summary

step "spare-pod-leaks: bind, destroy, a fresh pod"
[ "$(post "$(tk "$tmp/key" '{"op":"bind-user-pod","cluster":"kind","pod":"u-drill1","principal":"gh.7001","nonce":"a1111111111111111111111111111111","exp":'"$exp"'}')")" = 200 ] \
  || fail "the hub's bind: $(cat "$tmp/resp")"
[ "$(K get deploy u-drill1 -o jsonpath='{.metadata.labels.fleet\/principal}')" = gh.7001 ] || fail "the bind wrote no fleet/principal label"
# user-pod-image-stale (#4174): a roll of a pod already on the template's image sends nothing
gen=$(K get deploy u-drill1 -o jsonpath='{.metadata.generation}')
[ "$(post "$(tk "$tmp/key" '{"op":"roll-user-pod","cluster":"kind","pod":"u-drill1","nonce":"a1212121212121212121212121212121","exp":'"$exp"'}')")" = 200 ] \
  && grep -q 'already on' "$tmp/resp" || fail "the hub's roll of a pod on the template's image: $(cat "$tmp/resp")"
[ "$(K get deploy u-drill1 -o jsonpath='{.metadata.generation}')" = "$gen" ] || fail "a roll onto the same image changed the Deployment"
K delete job job-111111111111 --wait=false >/dev/null 2>&1 || true
[ "$(post "$(tk "$tmp/key" '{"op":"destroy-user-pod","cluster":"kind","pod":"u-drill1","nonce":"a2222222222222222222222222222222","exp":'"$exp"'}')")" = 200 ] \
  || fail "the hub's destroy: $(cat "$tmp/resp")"
for _ in $(seq 1 120); do
  left=$(for k in deploy/u-drill1 svc/u-drill1 pvc/u-drill1 secret/u-drill1-join; do K get "$k" -o name 2>/dev/null || true; done)
  [ -z "$left" ] && break; sleep 1
done
[ -z "$left" ] || fail "the destroy left: $left"
[ "$(post "$(tk "$tmp/key" '{"op":"create-user-pod","cluster":"kind","pod":"u-drill2","limits":"","login":"drill2","uid":10002,"join":"fj_bbbbbbbbbbbbbbbbbbbbbbbbbb","nonce":"a3333333333333333333333333333333","exp":'"$exp"'}')")" = 200 ] \
  || fail "the next spare's create: $(cat "$tmp/resp")"
K get pvc u-drill2 -o json | python3 -c 'import json,sys; s=json.load(sys.stdin)["spec"]; sys.exit("the new claim has a data source" if s.get("dataSource") or s.get("dataSourceRef") else 0)' \
  || fail "u-drill2's claim"
[ "$(K get secret u-drill2-join -o jsonpath='{.data.machine}' | base64 -d)" = fj_bbbbbbbbbbbbbbbbbbbbbbbbbb ] || fail "u-drill2's join Secret"
echo "u-drill1 bound, destroyed (Deployment · Service · PVC · join Secret gone); u-drill2: a new empty claim, its own join code"
{ echo; echo "### spare-pod-leaks"; echo "u-drill1: bound → destroyed, nothing left; u-drill2: new claim, new join Secret"; } | summary

step "root-in-user-pod: a person's pod, running"
ssh-keygen -q -t ed25519 -N '' -f "$tmp/door" -C door
K create secret generic fleet-door-pub --from-file=door.pub="$tmp/door.pub" >/dev/null
K apply -f "$tmp/live.json" >/dev/null
for _ in $(seq 1 90); do lpod=$(K get pod -l fleet/pod=u-live1 -o jsonpath='{.items[0].metadata.name}' 2>/dev/null) && [ -n "$lpod" ] && break; sleep 1; done
[ -n "${lpod:-}" ] || fail "the live user pod never appeared"
K wait --for=jsonpath='{.status.containerStatuses[?(@.name=="sshd")].ready}'=true "pod/$lpod" --timeout=300s >/dev/null \
  || { K describe pod "$lpod" | tail -30; K logs "$lpod" -c pod-etc 2>&1 | tail -5; fail "the live user pod's sshd never came up"; }
users() { K exec "$lpod" -c "$1" -- sh -c 'ps -o user= -e | sort -u | tr "\n" " "'; }
fid=$(K exec "$lpod" -c fleet -- id -un):$(K exec "$lpod" -c fleet -- id -u)
[ "$fid" = live1:10002 ] || fail "the fleet container runs as $fid, not live1:10002"
fu=$(users fleet); su=$(users sshd)
[ "$fu" = "live1 " ] || fail "ps in the fleet container: '$fu' (want the login alone)"
[ "$su" = "root " ] || fail "ps in the sshd container before a login: '$su' (want root alone)"
if K exec "$lpod" -c fleet -- sh -c 'echo "x:x:0:0::/:/bin/sh" >> /etc/passwd' 2>/dev/null; then
  fail "the login wrote /etc/passwd"
fi
K exec "$lpod" -c sshd -- /usr/sbin/sshd -t -f /etc/ssh/sshd_config || fail "the pod's sshd config does not check"
K port-forward "pod/$lpod" 12222:2222 >/dev/null 2>&1 & pf2=$!
for _ in $(seq 1 50); do (exec 3<>/dev/tcp/127.0.0.1/12222) 2>/dev/null && break; sleep 0.2; done
sshp() { ssh -i "$tmp/door" -p 12222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  -o LogLevel=ERROR -o BatchMode=yes "$@"; }
landed=$(sshp live1@127.0.0.1 2>&1 || true)
# pod-sshd-tty-audit (#4167): a login that asks for a terminal (the thin client's
# attach) — sshd writes an audit record for the pty; without AUDIT_WRITE it drops it
tty=$(sshp -tt live1@127.0.0.1 2>&1 || true)
asroot=$(sshp root@127.0.0.1 true 2>&1 && echo IN || true)
kill "$pf2" 2>/dev/null || true
echo "$landed"
case "$landed" in "ENTRY live1 10002 | "*) ;; *) fail "an ssh login with the door's key: '$landed'" ;; esac
case "$landed" in *"| live1 root "*|*"| root live1 "*) ;; *) fail "ps in sshd during a login: '$landed' (want root + live1)" ;; esac
case "$asroot" in *IN) fail "root logged in over ssh" ;; esac
case "$tty" in *"ENTRY live1 10002 | "*) ;; *) fail "a terminal login was dropped: '$tty'" ;; esac
out="fleet: $fid · ps fleet: $fu· ps sshd: $su· a login: $landed"
echo "$out"
{ echo; echo "### root-in-user-pod"; echo '```'; echo "$out"; echo '```'; } | summary
echo; echo "PASS sa-token-in-user-pod · provisioner-off-template · job-sees-keys · svc-run-sees-keys · spare-pod-leaks · root-in-user-pod · pod-sshd-tty-audit (kind)"
