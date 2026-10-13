#!/bin/bash
# fleet-break-it-cluster-selftest.sh — the docs/dev/BREAK-IT.md rows of the cluster's
# permissions (issue #3558, EPIC #3500 C16 · 共同约定 2): what each pod may do to
# Kubernetes. The machine half runs here, with no cluster: every pod template
# the fleet ships is read for a token it would mount, and bin/fleet-provisioner.py
# is driven against a stand-in API server on 127.0.0.1 with every way to make it
# step off its template. The cluster half — the same two rows on a real API
# server, its RBAC and its admission policy — is deploy/k8s/provisioner/kind-drill.sh
# (.github/workflows/cluster-perms.yml, kind). Runner and timing helpers are
# bin/fleet-break-it-cred-selftest.sh's (BREAK_CRED_LIB=1); bin/fleet-break-it-selftest.sh's
# lockstep lint reads the drill names here too.
#
#   sa-token-in-user-pod     extras/managed-node/render.py + deploy/k8s/fleet-workers
#   provisioner-off-template bin/fleet-provisioner.py + bin/fleet_cluster_ticket.py
#   spare-pod-leaks          bin/fleet-provisioner.py + tokenledger/internal/api/fleet_spare_pods.go
#   root-in-user-pod         extras/managed-node/render.py + bin/fleet-provisioner.py +
#                            bin/fleet-node-linux.py pod-etc (issue #3757)
#   cluster-reading-wrong-pod extras/managed-node/render.py (ops_resources) + deploy/k8s/fleet-workers +
#                            tokenledger/internal/api/fleet_cluster_reading.go +
#                            tokenledger/internal/agent/node_cluster_reading.go (issue #3734)
#   job-sees-keys            extras/managed-node/render.py (job_resources) + bin/fleet-provisioner.py +
#                            bin/fleet-job-runner.sh + deploy/k8s/fleet-workers/networkpolicy.yaml +
#                            tokenledger/internal/api/fleet_jobs.go
#   mirror-private-unlisted  extras/managed-node/render.py (private_mirrors, --mirror-grant) +
#                            bin/fleet-provisioner.py + bin/fleet-node-linux.py devnet (issue #4002)
# shellcheck disable=SC2034  # CAP / SECS / WHY / WHAT are read by the sourced runner
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=fleet-break-it-cred-selftest.sh
BREAK_CRED_LIB=1 . "$BIN/fleet-break-it-cred-selftest.sh"
RENDER="$ROOT/extras/managed-node/render.py"
D64=$(printf 'a%.0s' $(seq 1 64))

# templates <dir> — every pod-carrying object the fleet ships into fleet-workers,
# one JSON List per file: render.py's user pod, door, fleet-ops (#3734), shared node and Job, and
# (with kubectl, and yq or PyYAML) the kustomized fleet-workers layer
templates() {
  local d="$1"
  python3 "$RENDER" --image "x@sha256:$D64" --hub https://hub.example.com --storage-class csi \
    --user-pod u-drill1 --login drill1 --uid 10002 \
    --cred-central http://fleet-credproxy.fleet-workers.svc.cluster.local > "$d/user-pod.json" || return 1
  python3 "$RENDER" --door --image "x@sha256:$D64" --hub https://hub.example.com > "$d/door.json" || return 1
  python3 "$RENDER" --ops drill-cluster --image "x@sha256:$D64" --hub https://hub.example.com > "$d/ops.json" || return 1
  python3 "$RENDER" --image "x@sha256:$D64" --hub https://hub.example.com --storage-class csi > "$d/node.json" || return 1
  python3 "$RENDER" --job u-drill1 --image "x@sha256:$D64" --job-repo o/r \
    --job-ref "$(printf 'b%.0s' $(seq 1 40))" --job-nonce "$(printf 'c%.0s' $(seq 1 32))" > "$d/job.json" || return 1
  command -v kubectl >/dev/null 2>&1 || return 0
  if command -v yq >/dev/null 2>&1; then
    kubectl kustomize "$ROOT/deploy/k8s/fleet-workers" | yq -o=json -I=0 '.' \
      | python3 -c 'import json,sys; print(json.dumps({"kind": "List", "items": [json.loads(l) for l in sys.stdin if l.strip()]}))' \
      > "$d/fleet-workers.json" || return 1
  elif python3 -c 'import yaml' 2>/dev/null; then
    kubectl kustomize "$ROOT/deploy/k8s/fleet-workers" \
      | python3 -c 'import json,sys,yaml; print(json.dumps({"kind": "List", "items": [o for o in yaml.safe_load_all(sys.stdin) if o]}))' \
      > "$d/fleet-workers.json" || return 1
  else
    return 0
  fi
  echo kustomized
}

# sa-token-in-user-pod (#3558): look for a cluster token anywhere a user pod, a
# Job pod or a shared service could find one. Every pod template mounts none
# (automountServiceAccountToken false on the pod) and runs as a named account
# that mounts none either; the two that do — fleet-ops (read) and
# fleet-provisioner (write by template) — are the only ones, and neither is a
# person's. The kind half then looks inside the pods themselves.
drill_sa_token_in_user_pod() {
  CAP=30
  local d="$WORK/sa" t0 kz out
  mkdir -p "$d"; t0=$(now)
  kz=$(templates "$d") || { WHY="render failed"; return 1; }
  out=$(python3 - "$d" <<'PY'
import glob, json, sys
MOUNT_OK = {"fleet-ops", "fleet-provisioner"}
bad, seen, sas = [], 0, {}
for f in sorted(glob.glob(sys.argv[1] + "/*.json")):
    for o in json.load(open(f))["items"]:
        if o.get("kind") == "ServiceAccount":
            sas[o["metadata"]["name"]] = o.get("automountServiceAccountToken")
for f in sorted(glob.glob(sys.argv[1] + "/*.json")):
    for o in json.load(open(f))["items"]:
        spec = (o.get("spec") or {})
        if o.get("kind") in ("Deployment", "StatefulSet", "Job", "DaemonSet"):
            p = spec["template"]["spec"]
        elif o.get("kind") == "Pod":
            p = spec
        else:
            continue
        seen += 1
        name = "%s %s (%s)" % (o["kind"], o["metadata"]["name"], f.rsplit("/", 1)[1])
        sa = p.get("serviceAccountName")
        if not sa or sa == "default":
            bad.append(name + ": runs as the namespace default account")
        elif sa in MOUNT_OK:
            if p.get("automountServiceAccountToken") is not True:
                bad.append(name + ": %s should mount its own token" % sa)
        elif p.get("automountServiceAccountToken") is not False:
            bad.append(name + ": mounts a token")
        if sas and sa not in MOUNT_OK and sa in sas and sas[sa] is not False:
            bad.append(name + ": account %s would mount one by default" % sa)
        for v in p.get("volumes") or []:
            for src in (v.get("projected") or {}).get("sources") or []:
                if "serviceAccountToken" in src:
                    bad.append(name + ": projects a token in volume " + v["name"])
for a, m in sas.items():
    if a not in MOUNT_OK and m is not False:
        bad.append("ServiceAccount %s: automountServiceAccountToken is not false" % a)
print("\n".join(bad) if bad else "ok %d pod templates, %d accounts" % (seen, len(sas)))
sys.exit(1 if bad else 0)
PY
) || { WHY="$out"; return 1; }
  SECS=$(since "$t0")
  WHAT="每个 pod 模板（用户 pod · 门 · fleet-ops · 共享节点 · Job${kz:+ · fleet-workers 共享服务}）都不挂集群令牌、各用自己的服务账号；只有 fleet-ops 与 fleet-provisioner 挂（${out}）"
}

# stub_api <dir> — a stand-in Kubernetes API on 127.0.0.1 (prints its URL):
# the nonce book ConfigMap with resourceVersion, objects created / read /
# patched / deleted by path, every write logged to <dir>/writes. A Deployment
# u-door1 labelled fleet/role door is there from the start — somebody else's.
stub_api() {
  local d="$1"
  cat > "$d/api.py" <<'PY'
import http.server, json, sys, threading
d = sys.argv[1]
objs = {"/apis/apps/v1/namespaces/fleet-workers/deployments/u-door1": {
    "kind": "Deployment", "metadata": {"name": "u-door1", "uid": "u0", "labels": {"fleet/role": "door"}}}}
book = {"metadata": {"name": "fleet-provisioner-nonces", "resourceVersion": "1"}, "data": {}}
BOOK = "/api/v1/namespaces/fleet-workers/configmaps/fleet-provisioner-nonces"
class H(http.server.BaseHTTPRequestHandler):
    def out(self, st, o):
        b = json.dumps(o).encode()
        self.send_response(st); self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
    def body(self):
        n = int(self.headers.get("Content-Length") or 0)
        return json.loads(self.rfile.read(n) or b"{}")
    def log(self, what):
        with open(d + "/writes", "a") as f:
            f.write(what + "\n")
    def do_GET(self):
        if self.headers.get("Authorization") != "Bearer drill-token":
            return self.out(401, {"message": "no token"})
        if self.path == BOOK:
            return self.out(200, book)
        o = objs.get(self.path)
        self.out(200, o) if o else self.out(404, {"message": "not found"})
    def do_PUT(self):
        b = self.body()
        if self.path != BOOK or b["metadata"]["resourceVersion"] != book["metadata"]["resourceVersion"]:
            return self.out(409, {"message": "conflict"})
        book["data"] = b["data"]; book["metadata"]["resourceVersion"] = str(int(book["metadata"]["resourceVersion"]) + 1)
        self.out(200, book)
    def do_POST(self):
        o = self.body(); p = self.path + "/" + o["metadata"]["name"]
        if p in objs:
            return self.out(409, {"message": "exists"})
        o["metadata"]["uid"] = "uid-" + o["metadata"]["name"]; objs[p] = o
        self.log("POST %s" % p); self.out(201, o)
    def do_PATCH(self):
        self.body(); self.log("PATCH %s" % self.path)
        self.out(200, objs.get(self.path, {})) if self.path in objs else self.out(404, {"message": "not found"})
    def do_DELETE(self):
        self.body(); self.log("DELETE %s" % self.path); objs.pop(self.path, None); self.out(200, {})
    def log_message(self, *a): pass
s = http.server.HTTPServer(("127.0.0.1", 0), H)
open(d + "/url", "w").write("http://127.0.0.1:%d" % s.server_address[1])
s.serve_forever()
PY
  python3 "$d/api.py" "$d" >"$d/api.log" 2>&1 & echo $! >> "$WORK/cred-pids"
  until_ok 5 test -s "$d/url" || return 1
  cat "$d/url"
}

# provisioner-off-template (#3558): with the provisioner's own account in hand —
# or its door, fleet-ops — make it build something off its template, or act
# without the hub. No ticket, a forged one, another cluster's, an expired one,
# an account ticket offered as a cluster one, a ticket carrying a field the
# template does not take (privileged), an op it has not got, a pod name that is
# not a person's, a destroy aimed at somebody else's object, a replay: each
# refused (3) with nothing written. Its own guard rejects a privileged pod, a
# hostPath, a host network, another namespace, a LoadBalancer and an image by
# tag. The hub's tickets each run once. The kind half sends the same
# off-template objects as the provisioner's account to a real API server.
drill_provisioner_off_template() {
  CAP=40
  local d="$WORK/prov" t0 api exp n tk why t
  mkdir -p "$d/sa"; t0=$(now)
  api=$(stub_api "$d") || { WHY="no stand-in API"; return 1; }
  printf 'drill-token\n' > "$d/sa/token"
  head -c 32 /dev/urandom > "$d/key"; head -c 32 /dev/urandom > "$d/other"
  python3 "$BIN/fleet_cluster_ticket.py" pub "$d/key" > "$d/account.pub"
  cat > "$d/template.json" <<EOF
{"cluster": "drill", "namespace": "fleet-workers",
 "user_pod": {"image": "x@sha256:$D64", "hub": "https://hub.example.com", "storage_class": "csi",
              "cred_central": "http://fleet-credproxy.fleet-workers.svc.cluster.local"},
 "job": {"image": "x@sha256:$D64"}}
EOF
  export FLEET_PROVISIONER_CONF="$d/template.json" FLEET_PROVISIONER_PUB="$d/account.pub" \
    FLEET_PROVISIONER_API="$api" FLEET_PROVISIONER_SA_DIR="$d/sa"
  exp=$(( $(date +%s) + 300 )); n=0123456789abcdef0123456789abcdef
  tk() { # tk <key> <json fields without nonce/exp> [nonce] [exp]
    python3 "$BIN/fleet_cluster_ticket.py" sign "$1" "$(python3 -c 'import json,sys; f=json.loads(sys.argv[1]); f.update(nonce=sys.argv[2], exp=int(sys.argv[3])); print(json.dumps(f))' "$2" "${3:-$n}" "${4:-$exp}")"
  }
  prov() { OUT=$(python3 "$BIN/fleet-provisioner.py" once "$1" 2>&1); RC=$?; }
  local up='{"op":"create-user-pod","cluster":"drill","pod":"u-drill1","limits":"","login":"drill1","uid":10002,"join":"fj_abcdefghijklmnopqrstuvwxyz"}'
  local ref job_none job_good
  ref=$(printf 'b%.0s' $(seq 1 40))
  job_none='{"op":"create-job","cluster":"drill","pod":"u-none1","repo":"o/r","ref":"'"$ref"'","kind":"test","cmd":"make test"}'
  job_good='{"op":"create-job","cluster":"drill","pod":"u-drill1","repo":"o/r","ref":"'"$ref"'","kind":"test","cmd":"make test"}'
  while IFS='|' read -r why t; do
    prov "$t"
    [ "$RC" = 3 ] && [ ! -s "$d/writes" ] || { WHY="$why: rc $RC, wrote: $(cat "$d/writes" 2>/dev/null): $OUT"; return 1; }
  done <<EOF
no ticket|
forged|$(tk "$d/other" "$up")
another cluster|$(tk "$d/key" '{"op":"create-user-pod","cluster":"prod","pod":"u-drill1","limits":"","login":"drill1","uid":10002,"join":"fj_abcdefghijklmnopqrstuvwxyz"}')
expired|$(tk "$d/key" "$up" "$n" "$(( $(date +%s) - 1 ))")
an account ticket|v1.$(tk "$d/key" "$up" | cut -d. -f2-)
a field the template has not got|$(tk "$d/key" '{"op":"create-user-pod","cluster":"drill","pod":"u-drill1","limits":"","login":"drill1","uid":10002,"join":"fj_abcdefghijklmnopqrstuvwxyz","privileged":true}')
a create with no join code|$(tk "$d/key" '{"op":"create-user-pod","cluster":"drill","pod":"u-drill1","limits":"","login":"drill1","uid":10002}' 66666666666666666666666666666666)
a join code off its grammar|$(tk "$d/key" '{"op":"create-user-pod","cluster":"drill","pod":"u-drill1","limits":"","login":"drill1","uid":10002,"join":"x; rm -rf /"}' 77777777777777777777777777777777)
a bind of somebody else's object|$(tk "$d/key" '{"op":"bind-user-pod","cluster":"drill","pod":"u-door1","principal":"gh.1"}' 88888888888888888888888888888888)
an op it has not got|$(tk "$d/key" '{"op":"create-pod","cluster":"drill","pod":"u-drill1"}')
a name that is not a person's pod|$(tk "$d/key" '{"op":"create-user-pod","cluster":"drill","pod":"fleet-door","limits":"","login":"drill1","uid":10002,"join":"fj_abcdefghijklmnopqrstuvwxyz"}')
limits off the grammar|$(tk "$d/key" '{"op":"create-user-pod","cluster":"drill","pod":"u-drill1","limits":"cpu=0","login":"drill1","uid":10002,"join":"fj_abcdefghijklmnopqrstuvwxyz"}' 55555555555555555555555555555555)
no login|$(tk "$d/key" '{"op":"create-user-pod","cluster":"drill","pod":"u-drill1","limits":"","join":"fj_abcdefghijklmnopqrstuvwxyz"}' 99999999999999999999999999999999)
a root login|$(tk "$d/key" '{"op":"create-user-pod","cluster":"drill","pod":"u-drill1","limits":"","login":"root","uid":0,"join":"fj_abcdefghijklmnopqrstuvwxyz"}' abababababababababababababababab)
somebody else's object|$(tk "$d/key" '{"op":"destroy-user-pod","cluster":"drill","pod":"u-door1"}' fedcba9876543210fedcba9876543210)
a Job for no pod|$(tk "$d/key" "$job_none" 11111111111111111111111111111111)
EOF
  # its own guard: what the admission policy refuses, refused before the request
  why=$(python3 - "$BIN" "$D64" <<'PY'
import importlib.util, json, sys, copy
spec = importlib.util.spec_from_file_location("p", sys.argv[1] + "/fleet-provisioner.py")
p = importlib.util.module_from_spec(spec); spec.loader.exec_module(p)
r = p.render()
base = r.user_pod_resources("x@sha256:" + sys.argv[2], "https://hub.example.com", "csi", "u-drill1",
                            login="drill1", uid=10002,
                            cred_central="http://fleet-credproxy.fleet-workers.svc.cluster.local")
dep = [o for o in base if o["kind"] == "Deployment"][0]
svc = [o for o in base if o["kind"] == "Service"][0]
assert all(p.off_template(o, "fleet-workers") is None for o in base), [p.off_template(o, "fleet-workers") for o in base]
def mut(o, f):
    o = copy.deepcopy(o); f(o); return o
c0 = lambda o: [c for c in o["spec"]["template"]["spec"]["containers"] if c["name"] == "sshd"][0]
cases = {
    "privileged": mut(dep, lambda o: c0(o)["securityContext"].update(privileged=True)),
    "escalation": mut(dep, lambda o: c0(o)["securityContext"].update(allowPrivilegeEscalation=True)),
    "SYS_ADMIN": mut(dep, lambda o: c0(o)["securityContext"]["capabilities"]["add"].append("SYS_ADMIN")),
    "hostPath": mut(dep, lambda o: o["spec"]["template"]["spec"]["volumes"].append({"name": "h", "hostPath": {"path": "/"}})),
    "hostNetwork": mut(dep, lambda o: o["spec"]["template"]["spec"].update(hostNetwork=True)),
    "a token": mut(dep, lambda o: o["spec"]["template"]["spec"].update(automountServiceAccountToken=True)),
    "another account": mut(dep, lambda o: o["spec"]["template"]["spec"].update(serviceAccountName="fleet-provisioner")),
    "image by tag": mut(dep, lambda o: c0(o).update(image="debian:latest")),
    "another namespace": mut(dep, lambda o: o["metadata"].update(namespace="kube-system")),
    "no user label": mut(dep, lambda o: o["metadata"]["labels"].update({"fleet/role": "door"})),
    "LoadBalancer": mut(svc, lambda o: o["spec"].update(type="LoadBalancer")),
    "a Secret by another name": mut(p.join_secret("u-drill1", "fleet-workers", "fj_x"), lambda o: o["metadata"].update(name="fleet-door")),
    "a Secret with a second key": mut(p.join_secret("u-drill1", "fleet-workers", "fj_x"), lambda o: o["data"].update(token="eA==")),
    "an unlabelled Secret": mut(p.join_secret("u-drill1", "fleet-workers", "fj_x"), lambda o: o["metadata"].update(labels={})),
}
assert p.off_template(p.join_secret("u-drill1", "fleet-workers", "fj_x"), "fleet-workers") is None
let = [k for k, o in cases.items() if not p.off_template(o, "fleet-workers")]
print("let through: " + ", ".join(let) if let else "")
PY
) || { WHY="guard check crashed: $why"; return 1; }
  [ -z "$why" ] || { WHY="the guard $why"; return 1; }
  # the hub's tickets: each runs once, inside the namespace, by the template
  prov "$(tk "$d/key" "$up")"
  [ "$RC" = 0 ] && [ "$(grep -c '^POST /.*/namespaces/fleet-workers/' "$d/writes")" = 4 ] \
    && grep -q '^POST /api/v1/namespaces/fleet-workers/secrets/u-drill1-join$' "$d/writes" \
    || { WHY="the hub's create: rc $RC, wrote: $(cat "$d/writes" 2>/dev/null): $OUT"; return 1; }
  : > "$d/writes"
  prov "$(tk "$d/key" "$up")"
  [ "$RC" = 3 ] && [ ! -s "$d/writes" ] && printf '%s' "$OUT" | grep -q 'already used' \
    || { WHY="a replay of the create: rc $RC: $OUT"; return 1; }
  prov "$(tk "$d/key" "$job_good" 22222222222222222222222222222222)"
  [ "$RC" = 0 ] && grep -q '^POST /apis/batch/v1/namespaces/fleet-workers/jobs/job-222222222222$' "$d/writes" \
    || { WHY="the hub's Job: rc $RC: $(cat "$d/writes"): $OUT"; return 1; }
  : > "$d/writes"
  prov "$(tk "$d/key" '{"op":"set-limits","cluster":"drill","pod":"u-drill1","limits":"cpu=1,memory=2Gi"}' 33333333333333333333333333333333)"
  [ "$RC" = 0 ] && [ "$(cat "$d/writes")" = 'PATCH /apis/apps/v1/namespaces/fleet-workers/deployments/u-drill1' ] \
    || { WHY="the hub's set-limits: rc $RC: $(cat "$d/writes"): $OUT"; return 1; }
  : > "$d/writes"
  prov "$(tk "$d/key" '{"op":"destroy-user-pod","cluster":"drill","pod":"u-drill1"}' 44444444444444444444444444444444)"
  SECS=$(since "$t0")
  [ "$RC" = 0 ] && [ "$(grep -c '^DELETE .*/u-drill1$' "$d/writes")" = 3 ] && grep -q '^DELETE .*/secrets/u-drill1-join$' "$d/writes" \
    || { WHY="the hub's destroy: rc $RC: $(cat "$d/writes"): $OUT"; return 1; }
  WHAT="以执行器的身份：不带单 / 伪造 / 别的集群 / 过期 / 账号单冒充 / 多一个字段（privileged）/ 表外操作 / 非用户 pod 的名字 / 删别人的对象 / 重放，全部拒绝、一个请求都没发；自己的模板检查拦下特权 · 提权 · SYS_ADMIN · hostPath · hostNetwork · 挂令牌 · 别的账号 · 按标签的镜像 · 别的命名空间 · LoadBalancer；入口签的建（连 join Secret）/ Job / 改上限 / 删（连 join Secret）各只跑一次；不带 join 码、join 码不合语法、给别人的对象打标签也拒；Secret 只能是 <fleet/pod>-join、一个键、带 user 标签"
}

# spare-pod-leaks (#3553): a spare pod the hub hands to 乙 must hold nothing of
# 甲's — not 甲's pod reused, not 甲's disk, not 甲's join code, not 甲's records on
# the hub. The provisioner half: 甲's pod is created (join Secret · PVC · Service ·
# Deployment), bound, and destroyed — all four deleted, the stand-in API holding
# none of them after; a replay of 甲's create is refused; 乙's pod is a NEW name, a
# NEW claim with no data source, its own join Secret; a bind aimed at 甲's gone pod
# is refused. The hub half: TestSparePodClaimDestroyRefill — 甲 handed a ready pod
# by a write (≤ 10 s), 甲's 家 / node tokens / passes / leases / join codes cleared
# before the destroy, spare.claim / spare.destroy audited, 乙 handed a different
# pod — run here with a Go toolchain, else by the Go gate.
drill_spare_pod_leaks() {
  CAP=120
  local d="$WORK/leak" t0 api exp gohalf out rc k jia
  mkdir -p "$d/sa"; t0=$(now)
  api=$(stub_api "$d") || { WHY="no stand-in API"; return 1; }
  printf 'drill-token\n' > "$d/sa/token"
  head -c 32 /dev/urandom > "$d/key"
  python3 "$BIN/fleet_cluster_ticket.py" pub "$d/key" > "$d/account.pub"
  printf '{"cluster": "drill", "namespace": "fleet-workers", "user_pod": {"image": "x@sha256:%s", "hub": "https://hub.example.com", "storage_class": "csi", "cred_central": "http://fleet-credproxy.fleet-workers.svc.cluster.local"}}\n' \
    "$D64" > "$d/template.json"
  export FLEET_PROVISIONER_CONF="$d/template.json" FLEET_PROVISIONER_PUB="$d/account.pub" \
    FLEET_PROVISIONER_API="$api" FLEET_PROVISIONER_SA_DIR="$d/sa"
  exp=$(( $(date +%s) + 300 ))
  tk() { # tk <json fields without exp> — signed with the hub's key
    python3 "$BIN/fleet_cluster_ticket.py" sign "$d/key" "$(python3 -c 'import json,sys; f=json.loads(sys.argv[1]); f.update(exp=int(sys.argv[2])); print(json.dumps(f))' "$1" "$exp")"
  }
  prov() { OUT=$(python3 "$BIN/fleet-provisioner.py" once "$1" 2>&1); RC=$?; }
  jia='{"op":"create-user-pod","cluster":"drill","pod":"u-jia0001","limits":"","login":"jia","uid":10002,"join":"fj_aaaaaaaaaaaaaaaaaaaaaaaaaa","nonce":"a0000000000000000000000000000001"}'
  prov "$(tk "$jia")"
  [ "$RC" = 0 ] && [ "$(grep -c '^POST ' "$d/writes")" = 4 ] || { WHY="甲's create: rc $RC: $(cat "$d/writes"): $OUT"; return 1; }
  prov "$(tk '{"op":"bind-user-pod","cluster":"drill","pod":"u-jia0001","principal":"gh.7001","nonce":"a0000000000000000000000000000002"}')"
  [ "$RC" = 0 ] && grep -q '^PATCH /apis/apps/v1/namespaces/fleet-workers/deployments/u-jia0001$' "$d/writes" \
    || { WHY="甲's bind: rc $RC: $OUT"; return 1; }
  : > "$d/writes"
  prov "$(tk '{"op":"destroy-user-pod","cluster":"drill","pod":"u-jia0001","nonce":"a0000000000000000000000000000003"}')"
  [ "$RC" = 0 ] || { WHY="甲's destroy: rc $RC: $OUT"; return 1; }
  for k in deployments/u-jia0001 services/u-jia0001 persistentvolumeclaims/u-jia0001 secrets/u-jia0001-join; do
    grep -q "^DELETE .*/$k\$" "$d/writes" || { WHY="甲's destroy left $k: $(cat "$d/writes")"; return 1; }
  done
  # nothing of 甲's left on the API: every GET for it is 404
  out=$(python3 - "$api" <<'PY'
import sys, urllib.request, urllib.error
left = []
for p in ("/apis/apps/v1/namespaces/fleet-workers/deployments/u-jia0001",
          "/api/v1/namespaces/fleet-workers/services/u-jia0001",
          "/api/v1/namespaces/fleet-workers/persistentvolumeclaims/u-jia0001",
          "/api/v1/namespaces/fleet-workers/secrets/u-jia0001-join"):
    r = urllib.request.Request(sys.argv[1] + p, headers={"Authorization": "Bearer drill-token"})
    try:
        urllib.request.urlopen(r)
        left.append(p.rsplit("/", 2)[-2] + "/" + p.rsplit("/", 1)[1])
    except urllib.error.HTTPError as e:
        if e.code != 404:
            left.append("%s: HTTP %d" % (p, e.code))
print(" ".join(left))
PY
)
  [ -z "$out" ] || { WHY="甲's objects still there after the destroy: $out"; return 1; }
  # a replay of 甲's create cannot bring 甲's pod (or disk) back
  prov "$(tk "$jia")"
  [ "$RC" = 3 ] || { WHY="a replay of 甲's create: rc $RC: $OUT"; return 1; }
  # 乙's pod: a new name, a new empty claim, its own join code
  : > "$d/writes"
  prov "$(tk '{"op":"create-user-pod","cluster":"drill","pod":"u-yi000002","limits":"","login":"yi","uid":10002,"join":"fj_bbbbbbbbbbbbbbbbbbbbbbbbbb","nonce":"b0000000000000000000000000000001"}')"
  [ "$RC" = 0 ] && grep -q '^POST /api/v1/namespaces/fleet-workers/persistentvolumeclaims/u-yi000002$' "$d/writes" \
    && ! grep -q 'jia' "$d/writes" || { WHY="乙's create: rc $RC: $(cat "$d/writes"): $OUT"; return 1; }
  # a bind aimed at 甲's gone pod is refused
  prov "$(tk '{"op":"bind-user-pod","cluster":"drill","pod":"u-jia0001","principal":"gh.7002","nonce":"b0000000000000000000000000000002"}')"
  [ "$RC" = 3 ] || { WHY="a bind of 甲's gone pod to 乙: rc $RC: $OUT"; return 1; }
  # the hub half
  gohalf="入口一半：此处没有 Go 工具链，由 Go 门（tokenledger.yml）跑 TestSparePodClaimDestroyRefill"
  grep -q '^func TestSparePodClaimDestroyRefill(' "$ROOT/tokenledger/internal/api/fleet_spare_pods_test.go" 2>/dev/null \
    || { WHY="the hub half's test TestSparePodClaimDestroyRefill is gone"; return 1; }
  if [ "${BREAK_GO:-1}" != 0 ] && command -v go >/dev/null 2>&1; then
    out=$(cd "$ROOT/tokenledger" && GOFLAGS=-mod=mod GOPROXY=off GOTOOLCHAIN=local \
          go test -count=1 -run '^TestSparePodClaimDestroyRefill$' ./internal/api 2>&1); rc=$?
    case "$rc:$out" in
      0:*'no tests to run'*) WHY="the hub half's Go test did not run"; return 1 ;;
      0:*) gohalf="入口一半：go test 甲领 · 删 · 乙领 通过" ;;
      *GOPROXY=off*|*'module lookup disabled'*|*'cannot find module'*|*'missing go.sum entry'*|*'requires go >= '*) ;;
      *) WHY="the hub half (go test) is red: $(printf '%s' "$out" | grep -v '^ok' | grep -v '^20' | head -6 | tr '\n' ' ')"
         return 1 ;;
    esac
  fi
  SECS=$(since "$t0")
  WHAT="甲的 pod 建（join Secret · PVC · Service · Deployment）、打标签、删：四样全删、API 上一样不剩；重放甲的建被拒；乙拿到新名字、新的空盘、自己的 join 码；把甲已删的 pod 绑给乙被拒；${gohalf}"
}

# root-in-user-pod (#3757): a person's pod with root anywhere but sshd's login
# step. The template: the fleet container runs as the pod's one login (non-root,
# ALL dropped, nothing added), sshd adds only its five, the pod-etc init is
# neither root nor the login; a user pod with no login is not rendered at all.
# The provisioner's guard refuses each way back to root. pod-etc writes the
# login's passwd line from the image's own (never a second uid 0, never root's
# name or number for the login). The kind half runs the pod and reads `ps`.
drill_root_in_user_pod() {
  CAP=30
  local d="$WORK/root" t0 out why
  mkdir -p "$d/base" "$d/etc"; t0=$(now)
  out=$(python3 "$RENDER" --image "x@sha256:$D64" --hub https://hub.example.com --storage-class csi \
    --user-pod u-drill1 --cred-central http://fleet-credproxy.fleet-workers.svc.cluster.local 2>&1) \
    && { WHY="a user pod with no login rendered: $(printf '%s' "$out" | head -c 200)"; return 1; }
  why=$(python3 - "$BIN" "$D64" <<'PY'
import copy, importlib.util, sys
spec = importlib.util.spec_from_file_location("p", sys.argv[1] + "/fleet-provisioner.py")
p = importlib.util.module_from_spec(spec); spec.loader.exec_module(p)
r = p.render()
objs = r.user_pod_resources("x@sha256:" + sys.argv[2], "https://hub.example.com", "csi", "u-drill1",
                            login="drill1", uid=10002,
                            cred_central="http://fleet-credproxy.fleet-workers.svc.cluster.local")
dep = [o for o in objs if o["kind"] == "Deployment"][0]
ps = dep["spec"]["template"]["spec"]
bad = []
if ps.get("shareProcessNamespace"):
    bad.append("the pod shares its process namespace")
names = sorted(c["name"] for c in ps["containers"])
if names != ["fleet", "sshd"]:
    bad.append("containers %s, not fleet + sshd" % names)
SSHD = {"CHOWN", "SETUID", "SETGID", "SYS_CHROOT", "KILL"}
for c in ps["containers"] + ps.get("initContainers", []):
    sc = c.get("securityContext") or {}
    add = set((sc.get("capabilities") or {}).get("add") or [])
    uid = sc.get("runAsUser", (ps.get("securityContext") or {}).get("runAsUser"))
    if c["name"] == "sshd":
        if add - SSHD:
            bad.append("sshd adds %s" % sorted(add - SSHD))
    elif c["name"] == "egress-guard":
        if add - {"NET_ADMIN", "NET_RAW"}:
            bad.append("egress-guard adds %s" % sorted(add - {"NET_ADMIN", "NET_RAW"}))
    else:
        if not sc.get("runAsNonRoot") or not uid:
            bad.append("%s may run as root (runAsUser %r)" % (c["name"], uid))
        if add:
            bad.append("%s adds %s" % (c["name"], sorted(add)))
        if c["name"] == "fleet" and uid != 10002:
            bad.append("fleet runs as %r, not the login's 10002" % uid)
        if c["name"] == "pod-etc" and uid == 10002:
            bad.append("pod-etc runs as the login: it would write its own passwd")
assert p.off_template(dep, "fleet-workers") is None, p.off_template(dep, "fleet-workers")
def mut(f):
    o = copy.deepcopy(dep); f(o["spec"]["template"]["spec"]); return o
fl = lambda s: [c for c in s["containers"] if c["name"] == "fleet"][0]
sd = lambda s: [c for c in s["containers"] if c["name"] == "sshd"][0]
cases = {
    "fleet as root": mut(lambda s: fl(s)["securityContext"].update(runAsUser=0, runAsNonRoot=False)),
    "fleet runAsNonRoot off": mut(lambda s: fl(s)["securityContext"].pop("runAsNonRoot")),
    "fleet adds CHOWN": mut(lambda s: fl(s)["securityContext"]["capabilities"].update(add=["CHOWN"])),
    "sshd adds DAC_OVERRIDE": mut(lambda s: sd(s)["securityContext"]["capabilities"]["add"].append("DAC_OVERRIDE")),
    "another root container": mut(lambda s: s["containers"].append(dict(copy.deepcopy(sd(s)), name="helper"))),
}
let = [k for k, o in cases.items() if not p.off_template(o, "fleet-workers")]
if let:
    bad.append("the guard lets through: " + ", ".join(let))
print("; ".join(bad))
PY
) || { WHY="template check crashed: $why"; return 1; }
  [ -z "$why" ] || { WHY="$why"; return 1; }
  printf 'root:x:0:0:root:/root:/bin/bash\nsshd:x:100:65534::/run/sshd:/usr/sbin/nologin\nnobody:x:65534:65534:nobody:/nonexistent:/usr/sbin/nologin\n' > "$d/base/passwd"
  printf 'root:x:0:\nnogroup:x:65534:\n' > "$d/base/group"
  FLEET_POD_LOGIN=drill1 FLEET_POD_UID=10002 python3 -I "$BIN/fleet-node-linux.py" pod-etc --base "$d/base" --out "$d/etc" \
    >"$d/pod-etc.log" 2>&1 || { WHY="pod-etc: $(tail -n 3 "$d/pod-etc.log")"; return 1; }
  grep -qx 'drill1:\*:10002:10002::/home/drill1:/bin/zsh' "$d/etc/passwd" && grep -qx 'drill1:x:10002:' "$d/etc/group" \
    || { WHY="pod-etc passwd/group: $(cat "$d/etc/passwd" "$d/etc/group")"; return 1; }
  [ "$(awk -F: '$3 == 0' "$d/etc/passwd" | wc -l | tr -d ' ')" = 1 ] || { WHY="a second uid 0 in pod-etc's passwd"; return 1; }
  local l u
  for l in 'root 10002' 'drill1 0' 'sshd 10002' 'drill1 100' 'drill1 65534'; do
    # shellcheck disable=SC2086  # two words: login uid
    set -- $l
    FLEET_POD_LOGIN=$1 FLEET_POD_UID=$2 python3 -I "$BIN/fleet-node-linux.py" pod-etc --base "$d/base" --out "$d/bad" \
      >/dev/null 2>&1 && { WHY="pod-etc wrote a login $1 uid $2"; return 1; }
  done
  [ ! -e "$d/bad/passwd" ] || { WHY="a refused pod-etc left a passwd behind"; return 1; }
  SECS=$(since "$t0")
  WHAT="用户 pod 模板：fleet 容器以登录的 UID 跑（非 root、drop ALL、不加能力），sshd 只加 CHOWN SETUID SETGID SYS_CHROOT KILL，pod-etc 既不是 root 也不是登录；没给登录不渲染；执行器拒 root 的 fleet · 关掉 runAsNonRoot · fleet 加能力 · sshd 加 DAC_OVERRIDE · 多一个 root 容器；pod-etc 只加该登录一行，拒 root 名 / uid 0 / 系统号"
}

# job-sees-keys (#3552, C7): a throwaway Job — the code it runs may be anyone's —
# looks for a key: a cluster token, a home disk, a Secret, a credential in its
# environment, root, a way out to the public internet (untrusted). The machine
# half: the provisioner, driven by the hub's create-job tickets against the
# stand-in API, makes one Job per kind; each one it sent runs as fleet-job with no
# token, no volume but emptyDirs, non-root on a read-only root, no envFrom, no
# credential-shaped variable; untrusted carries no fleet/job-net label (so only
# job-out's rules — no ipBlock, no egress proxy — apply to it) and no
# HTTPS_PROXY; a kind or a command off the grammar, and a Job for a pod that is
# no user pod, are refused with nothing written. The runner, given exactly a
# rendered untrusted Job's environment, finds nothing either. The hub half:
# TestJobRunsForTheCallersOwnPod (the Job is the CALLER's pod's, read back only
# as that pod's). The kind half runs a test and an untrusted Job for real and
# watches both deleted (deploy/k8s/provisioner/kind-drill.sh).
drill_job_sees_keys() {
  CAP=60
  local d="$WORK/job" t0 api exp out gohalf rc kind
  mkdir -p "$d/sa"; t0=$(now)
  api=$(stub_api "$d") || { WHY="no stand-in API"; return 1; }
  printf 'drill-token\n' > "$d/sa/token"
  head -c 32 /dev/urandom > "$d/key"
  python3 "$BIN/fleet_cluster_ticket.py" pub "$d/key" > "$d/account.pub"
  printf '{"cluster": "drill", "namespace": "fleet-workers", "user_pod": {"image": "x@sha256:%s", "hub": "https://hub.example.com", "storage_class": "csi", "cred_central": "http://fleet-credproxy.fleet-workers.svc.cluster.local"}, "job": {"image": "x@sha256:%s", "git_mirror": "git://git-mirror.arc-runners.svc.cluster.local/{repo}.git", "caches": true, "egress_proxy": "http://fleet-egress.fleet-workers.svc.cluster.local:3128"}}\n' \
    "$D64" "$D64" > "$d/template.json"
  export FLEET_PROVISIONER_CONF="$d/template.json" FLEET_PROVISIONER_PUB="$d/account.pub" \
    FLEET_PROVISIONER_API="$api" FLEET_PROVISIONER_SA_DIR="$d/sa"
  exp=$(( $(date +%s) + 300 ))
  tk() { python3 "$BIN/fleet_cluster_ticket.py" sign "$d/key" "$(python3 -c 'import json,sys; f=json.loads(sys.argv[1]); f.update(exp=int(sys.argv[2])); print(json.dumps(f))' "$1" "$exp")"; }
  prov() { OUT=$(python3 "$BIN/fleet-provisioner.py" once "$1" 2>&1); RC=$?; }
  local ref; ref=$(printf 'b%.0s' $(seq 1 40))
  # off the grammar, or for no user pod: refused, nothing written
  : > "$d/writes"
  prov "$(tk '{"op":"create-job","cluster":"drill","pod":"u-job00001","repo":"o/r","ref":"'"$ref"'","kind":"test","cmd":"true","nonce":"c0000000000000000000000000000001"}')"
  [ "$RC" = 3 ] || { WHY="a Job for no user pod: rc $RC: $OUT"; return 1; }
  prov "$(tk '{"op":"create-user-pod","cluster":"drill","pod":"u-job00001","limits":"","login":"job1","uid":10003,"join":"fj_cccccccccccccccccccccccccc","nonce":"c0000000000000000000000000000002"}')"
  [ "$RC" = 0 ] || { WHY="the owner pod's create: rc $RC: $OUT"; return 1; }
  : > "$d/writes"
  for bad in '"kind":"root","cmd":"true"' '"kind":"test","cmd":"a\nb"' '"kind":"test","cmd":""' '"kind":"test"'; do
    prov "$(tk '{"op":"create-job","cluster":"drill","pod":"u-job00001","repo":"o/r","ref":"'"$ref"'",'"$bad"',"nonce":"c00000000000000000000000000000'"$((RANDOM % 90 + 10))"'"}')"
    [ "$RC" = 3 ] || { WHY="an off-grammar create-job ($bad): rc $RC: $OUT"; return 1; }
  done
  [ ! -s "$d/writes" ] || { WHY="a refused create-job wrote: $(cat "$d/writes")"; return 1; }
  # one Job per kind, as the hub signs it
  local n=3
  for kind in build test browser load untrusted; do
    n=$((n + 1))
    prov "$(tk '{"op":"create-job","cluster":"drill","pod":"u-job00001","repo":"o/r","ref":"'"$ref"'","kind":"'"$kind"'","cmd":"make test","nonce":"'"$n"'d000000000000000000000000000000"}')"
    [ "$RC" = 0 ] || { WHY="the hub's $kind Job: rc $RC: $OUT"; return 1; }
  done
  out=$(python3 - "$api" "$d/untrusted.env" <<'PY'
import json, re, sys, urllib.request
CRED = re.compile(r'TOKEN|SECRET|PASSWORD|PASSWD|CREDENTIAL|_KEY$|^KEY|AUTH|COOKIE|SESSION', re.I)
bad, kinds = [], {}
for n, kind in enumerate(("build", "test", "browser", "load", "untrusted"), 4):
    name = "job-" + ("%dd000000000000000000000000000000" % n)[:12]
    r = urllib.request.Request(sys.argv[1] + "/apis/batch/v1/namespaces/fleet-workers/jobs/" + name,
                               headers={"Authorization": "Bearer drill-token"})
    j = json.load(urllib.request.urlopen(r))
    labels, p = j["spec"]["template"]["metadata"]["labels"], j["spec"]["template"]["spec"]
    c = p["containers"][0]
    env = {e["name"]: e.get("value", "") for e in c.get("env", [])}
    where = "%s (%s)" % (name, kind)
    if labels.get("fleet/job-kind") != kind:
        bad.append(where + ": not labelled its kind")
    if p.get("serviceAccountName") != "fleet-job" or p.get("automountServiceAccountToken") is not False:
        bad.append(where + ": a token, or not fleet-job")
    for v in p.get("volumes") or []:
        if set(v) != {"name", "emptyDir"}:
            bad.append(where + ": volume %s is not an emptyDir" % v["name"])
    sc, psc = c.get("securityContext") or {}, p.get("securityContext") or {}
    if not psc.get("runAsNonRoot") or not psc.get("runAsUser") or not sc.get("readOnlyRootFilesystem") \
       or sc.get("allowPrivilegeEscalation") is not False or "ALL" not in (sc.get("capabilities") or {}).get("drop", []):
        bad.append(where + ": root, a writable root, escalation or a capability")
    if c.get("envFrom") or any("valueFrom" in e for e in c.get("env", [])):
        bad.append(where + ": env from a Secret / ConfigMap / field")
    for k in env:
        if CRED.search(k):
            bad.append(where + ": a credential-shaped variable " + k)
    if kind == "untrusted":
        if "fleet/job-net" in labels or "FLEET_EGRESS_PROXY" in env:
            bad.append(where + ": a way to the egress")
    elif labels.get("fleet/job-net") != "open" or "FLEET_EGRESS_PROXY" not in env:
        bad.append(where + ": an open kind without its egress")
    kinds[kind] = env
print("\n".join(bad) if bad else "ok")
open(sys.argv[2], "w").write(json.dumps(kinds["untrusted"]))
sys.exit(1 if bad else 0)
PY
) || { WHY="$out"; return 1; }
  # job-out: no ipBlock (no public address); only job-out-open reaches 3128, for job-net open
  out=$(awk '/^  name: job-out$/{on=1} on&&/^---/{exit} on' "$ROOT/deploy/k8s/fleet-workers/networkpolicy.yaml")
  case "$out" in *ipBlock*|*3128*) WHY="job-out lets a Job out: $out"; return 1 ;; esac
  awk '/^  name: job-out-open$/{on=1} on&&/^---/{exit} on' "$ROOT/deploy/k8s/fleet-workers/networkpolicy.yaml" \
    | grep -q 'fleet/job-net: open' || { WHY="job-out-open does not select fleet/job-net open"; return 1; }
  # the runner, given exactly the rendered untrusted Job's environment (no mirror
  # here: nothing to fetch) and a command that looks for a key
  out=$(python3 - "$d/untrusted.env" "$d/w" "$BIN/fleet-job-runner.sh" <<'PY' 2>&1
import json, subprocess, sys
env = json.load(open(sys.argv[1]))
env.pop("FLEET_JOB_MIRROR", None)
env.update(PATH="/usr/bin:/bin", HOME=sys.argv[2], FLEET_JOB_WORK=sys.argv[2],
           FLEET_JOB_CMD='env | grep -v ^FLEET_JOB_CMD= | grep -Eic "token|secret|password|credential|_key=" ; '
                         'ls -A "$HOME" | grep -vx out | grep -vx src | wc -l')
p = subprocess.run(["sh", sys.argv[3]], env=env, capture_output=True, text=True)
sys.stdout.write(p.stdout + p.stderr)
PY
)
  printf '%s\n' "$out" | grep -qx '::fleet-job:: exit 0' \
    && [ "$(printf '%s\n' "$out" | grep -Ev '^::fleet-job::' | tr -d ' ' | sort -u | tr '\n' ,)" = '0,' ] \
    || { WHY="the runner in an untrusted Job's environment saw something: $out"; return 1; }
  # the hub half
  gohalf="入口一半：此处没有 Go 工具链，由 Go 门（tokenledger.yml）跑 TestJobRunsForTheCallersOwnPod"
  grep -q '^func TestJobRunsForTheCallersOwnPod(' "$ROOT/tokenledger/internal/api/fleet_jobs_test.go" 2>/dev/null \
    || { WHY="the hub half's test TestJobRunsForTheCallersOwnPod is gone"; return 1; }
  if [ "${BREAK_GO:-1}" != 0 ] && command -v go >/dev/null 2>&1; then
    out=$(cd "$ROOT/tokenledger" && GOFLAGS=-mod=mod GOPROXY=off GOTOOLCHAIN=local \
          go test -count=1 -run '^TestJob' ./internal/api 2>&1); rc=$?
    case "$rc:$out" in
      0:*'no tests to run'*) WHY="the hub half's Go test did not run"; return 1 ;;
      0:*) gohalf="入口一半：go test 只为调用者自己的 pod 建 Job、只按它读回" ;;
      *GOPROXY=off*|*'module lookup disabled'*|*'cannot find module'*|*'missing go.sum entry'*|*'requires go >= '*) ;;
      *) WHY="the hub half (go test) is red: $(printf '%s' "$out" | grep -v '^ok' | grep -v '^20' | head -6 | tr '\n' ' ')"
         return 1 ;;
    esac
  fi
  SECS=$(since "$t0")
  WHAT="入口签的单为五种 kind 各建一个 Job：都以 fleet-job 跑、不挂令牌、只有 emptyDir、非 root 只读根、不从 Secret 取环境、没有像凭据的变量；untrusted 不带出口标签也没有 HTTPS_PROXY（job-out 没有任何公网地址）；kind / 命令不合语法、给不是用户 pod 的建 Job 一律拒、一个请求都没发；runner 照 untrusted 的环境跑，什么钥匙都找不到；${gohalf}"
}

# cluster-reading-wrong-pod (#3734, EPIC #3500 C1's cloud half): fleet-ops feeds
# each user pod its own reading. Here: the one fleet-ops template is the read-only
# account's, fleet/role control, not root, its token down a pipe; that account's
# Role reads and never writes; control-out exists. The hub half (go test): a
# reading reaches only its own pod, from its own cluster's ops link, never a
# malformed value, never from a link without cluster_ops.
drill_cluster_reading_wrong_pod() {
  CAP=120
  local d="$WORK/cr" t0 out gohalf
  mkdir -p "$d"; t0=$(now)
  python3 "$RENDER" --ops drill-cluster --image "x@sha256:$D64" --hub https://hub.example.com > "$d/ops.json" \
    || { WHY="render --ops failed"; return 1; }
  out=$(python3 - "$d/ops.json" "$ROOT/deploy/k8s/fleet-workers/serviceaccounts.yaml" "$ROOT/deploy/k8s/fleet-workers/networkpolicy.yaml" <<'PY'
import json, re, sys
bad = []
items = json.load(open(sys.argv[1]))["items"]
deps = [o for o in items if o["kind"] == "Deployment"]
if len(deps) != 1 or deps[0]["spec"]["replicas"] != 1:
    bad.append("not ONE fleet-ops of one replica")
p = deps[0]["spec"]["template"]["spec"]
c = p["containers"][0]
if (p["serviceAccountName"], p["hostname"], deps[0]["spec"]["template"]["metadata"]["labels"].get("fleet/role")) != ("fleet-ops", "drill-cluster", "control"):
    bad.append("account / hostname / role: %s %s" % (p["serviceAccountName"], p["hostname"]))
if not c["securityContext"].get("runAsNonRoot") or c["securityContext"].get("runAsUser") in (None, 0):
    bad.append("fleet-ops runs as root")
if any(e["name"] == "CCQUOTA_TOKEN" for e in c["env"]) or "CCQUOTA_TOKEN_FD=3" not in c["command"][-1]:
    bad.append("the node token is not down a pipe")
sa = open(sys.argv[2]).read()
m = re.search(r"kind: Role\nmetadata: \{name: fleet-ops,.*?\n---", sa, re.S)
if not m:
    bad.append("no fleet-ops Role")
else:
    verbs = set(re.findall(r"verbs: \[([^\]]*)\]", m.group(0)))
    for v in verbs:
        if set(x.strip() for x in v.split(",")) - {"get", "list", "watch"}:
            bad.append("fleet-ops' Role writes: " + v)
    if "metrics.k8s.io" not in m.group(0):
        bad.append("fleet-ops' Role cannot read pod metrics")
if "name: control-out" not in open(sys.argv[3]).read():
    bad.append("no control-out network rule")
print("\n".join(bad) if bad else "ok")
sys.exit(1 if bad else 0)
PY
) || { WHY="$out"; return 1; }
  gohalf="入口一半：此处没有 Go 工具链，由 Go 门（tokenledger.yml）跑 TestClusterReadingReachesItsPod"
  grep -q '^func TestClusterReadingReachesItsPod(' "$ROOT/tokenledger/internal/api/fleet_cluster_reading_test.go" 2>/dev/null \
    || { WHY="the hub half's test TestClusterReadingReachesItsPod is gone"; return 1; }
  if [ "${BREAK_GO:-1}" != 0 ] && command -v go >/dev/null 2>&1; then
    out=$(cd "$ROOT/tokenledger" && GOFLAGS=-mod=mod GOPROXY=off GOTOOLCHAIN=local \
          go test -count=1 -run '^TestClusterReading' ./internal/api 2>&1); rc=$?
    case "$rc:$out" in
      0:*'no tests to run'*) WHY="the hub half's Go test did not run"; return 1 ;;
      0:*) gohalf="入口一半：go test 读数只到自己集群的自己的 pod、坏值和冒充的链路一律丢" ;;
      *GOPROXY=off*|*'module lookup disabled'*|*'cannot find module'*|*'missing go.sum entry'*|*'requires go >= '*) ;;
      *) WHY="the hub half (go test) is red: $(printf '%s' "$out" | grep -v '^ok' | grep -v '^20' | head -6 | tr '\n' ' ')"
         return 1 ;;
    esac
  fi
  SECS=$(since "$t0")
  WHAT="集群只有一个 fleet-ops：只读账号（Role 只有 get/list/watch，能读 pod 指标）、fleet/role control、非 root、令牌走管道、出站只有 control-out；${gohalf}"
}

# mirror-private-unlisted (#4002): an internal repo's in-cluster mirror speaks
# git:// with no login and flannel enforces no NetworkPolicy, so a user pod
# reaches it exactly when its own egress guard lets the mirror's address through.
# The machine half: a pod rendered for a login on the mirror's list gets the
# guard's allow line, the insteadOf and the fleet/mirror-<repo> label; one for
# any other login gets none of the three (and pod-etc writes it no insteadOf); an
# open --egress-allow / --git-mirror that would hand the mirror to everyone is
# refused; --mirror-grant moves a running pod both ways and touches nothing else;
# the provisioner makes the same pods from its template and refuses a Job of the
# repo for a pod whose login is not listed, writing nothing.
drill_mirror_private_unlisted() {
  CAP=30
  local d="$WORK/pmirror" t0 out api exp
  mkdir -p "$d/sa" "$d/etc-in" "$d/etc-out"; t0=$(now)
  cat > "$d/pm.json" <<'JSON'
[{"mirror": "git://git-mirror.arc-runners:9418/acme-monorepo.git",
  "upstream": "https://github.com/acme-org/acme-monorepo.git",
  "allow": "172.21.9.190:9418", "logins": ["listed1"]}]
JSON
  local base=(--image "x@sha256:$D64" --hub https://hub.example.com --storage-class csi --user-pod u-drill1
              --cred-central http://fleet-credproxy.fleet-workers.svc.cluster.local
              --git-mirror git://fleet-git-mirror.arc-runners:9418/claude-fleet.git=https://github.com/o/claude-fleet.git
              --egress-allow 172.21.6.7:9418 --private-mirrors "$d/pm.json")
  python3 "$RENDER" "${base[@]}" --login listed1 --uid 10002 > "$d/in.json" || { WHY="render (listed) failed"; return 1; }
  python3 "$RENDER" "${base[@]}" --login other1 --uid 10003 > "$d/out.json" || { WHY="render (unlisted) failed"; return 1; }
  for bad in '--egress-allow 172.21.9.0/24:9418' \
             '--git-mirror git://m:9418/x.git=https://github.com/acme-org/acme-monorepo.git'; do
    # shellcheck disable=SC2086  # one flag + its value
    out=$(python3 "$RENDER" "${base[@]}" --login other1 --uid 10003 $bad 2>&1) \
      && { WHY="an open setting that hands the private mirror to everyone rendered: $bad"; return 1; }
  done
  out=$(python3 "$RENDER" --image "x@sha256:$D64" --hub https://hub.example.com --storage-class csi \
        --private-mirrors "$d/pm.json" 2>&1) && { WHY="a shared node took a per-login private mirror"; return 1; }
  out=$(python3 - "$RENDER" "$d" <<'PY'
import copy, importlib.util, json, sys
spec = importlib.util.spec_from_file_location("r", sys.argv[1]); r = importlib.util.module_from_spec(spec)
spec.loader.exec_module(r)
d = sys.argv[2]
RULE = "-A OUTPUT -d 172.21.9.190/32 -p tcp -m tcp --dport 9418 -j ACCEPT"
UP = "https://github.com/acme-org/acme-monorepo.git"
LABEL = "fleet/mirror-acme-monorepo"
def dep(f):
    return [o for o in json.load(open(f))["items"] if o["kind"] == "Deployment"][0]
def access(o):
    t = o["spec"]["template"]; s = t["spec"]
    guard = [c for c in s["initContainers"] if c["name"] == "egress-guard"][0]["command"][-1]
    env = {c["name"]: {e["name"]: e.get("value", "") for e in c.get("env", [])} for c in s["initContainers"] + s["containers"]}
    mir = {n: any(x.endswith("=" + UP) for x in v.get("FLEET_GIT_MIRRORS", "").split()) for n, v in env.items()
           if "FLEET_POD_LOGIN" in v}
    return {"label": t["metadata"]["labels"].get(LABEL) == "1", "guard": RULE in guard.split("\n"),
            "mirror": sorted(n for n, m in mir.items() if m), "open": "172.21.6.7/32" in guard}
bad = []
a_in, a_out = access(dep(d + "/in.json")), access(dep(d + "/out.json"))
if a_in != {"label": True, "guard": True, "mirror": ["fleet", "pod-etc"], "open": True}:
    bad.append("the listed login's pod lacks its access: %s" % a_in)
if a_out != {"label": False, "guard": False, "mirror": [], "open": True}:
    bad.append("the unlisted login's pod reaches the private mirror: %s" % a_out)
def apply(o, ops):
    o = copy.deepcopy(o)
    for op in ops:
        if op["op"] == "test":
            continue
        parts = op["path"].strip("/").split("/"); cur = o
        for k in parts[:-1]:
            cur = cur[int(k)] if isinstance(cur, list) else cur[k]
        cur[int(parts[-1]) if isinstance(cur, list) else parts[-1]] = op["value"]
    return o
pm = json.load(open(d + "/pm.json"))
for name, f, lst, want in (("revoke", "/in.json", [dict(pm[0], logins=[])], False),
                           ("grant", "/out.json", [dict(pm[0], logins=["other1"])], True)):
    o = dep(d + f); o["metadata"]["resourceVersion"] = "7"
    ops = r.mirror_grant_patch(o, lst)
    if ops[0] != {"op": "test", "path": "/metadata/resourceVersion", "value": "7"}:
        bad.append(name + ": the patch does not test the resourceVersion")
    got = access(apply(o, ops))
    exp = {"label": want, "guard": want, "mirror": ["fleet", "pod-etc"] if want else [], "open": True}
    if got != exp:
        bad.append("%s: --mirror-grant left %s" % (name, got))
    again = r.mirror_grant_patch(apply(o, ops), lst)
    if apply(apply(o, ops), again) != apply(o, ops):
        bad.append(name + ": --mirror-grant is not idempotent")
for c in dep(d + "/in.json")["spec"]["template"]["spec"]["containers"]:
    if c["name"] == "fleet":
        open(d + "/in.env", "w").write("".join("%s=%s\n" % (e["name"], e.get("value", "")) for e in c["env"]))
for c in dep(d + "/out.json")["spec"]["template"]["spec"]["containers"]:
    if c["name"] == "fleet":
        open(d + "/out.env", "w").write("".join("%s=%s\n" % (e["name"], e.get("value", "")) for e in c["env"]))
print("\n".join(bad))
PY
) || { WHY="the template check crashed: $out"; return 1; }
  [ -z "$out" ] || { WHY="$out"; return 1; }
  # pod-etc's /etc/gitconfig: the insteadOf only for the listed login
  local io
  for io in in out; do
    python3 -I -c 'import importlib.util,sys
spec = importlib.util.spec_from_file_location("n", sys.argv[1]); n = importlib.util.module_from_spec(spec); spec.loader.exec_module(n)
env = dict(l.rstrip("\n").split("=", 1) for l in open(sys.argv[2]) if "=" in l)
print(n.devnet_settings(env)[0])' "$BIN/fleet-node-linux.py" "$d/$io.env" > "$d/etc-$io/gitconfig" \
      || { WHY="devnet_settings ($io) failed"; return 1; }
  done
  grep -q 'insteadOf = https://github.com/acme-org/acme-monorepo.git' "$d/etc-in/gitconfig" \
    || { WHY="the listed login's gitconfig has no insteadOf: $(cat "$d/etc-in/gitconfig")"; return 1; }
  ! grep -q 'acme-monorepo' "$d/etc-out/gitconfig" \
    || { WHY="the unlisted login's gitconfig names the private mirror: $(cat "$d/etc-out/gitconfig")"; return 1; }
  # the provisioner: the same pods from its template; no Job of the repo for the unlisted
  api=$(stub_api "$d") || { WHY="no stand-in API"; return 1; }
  printf 'drill-token\n' > "$d/sa/token"
  head -c 32 /dev/urandom > "$d/key"
  python3 "$BIN/fleet_cluster_ticket.py" pub "$d/key" > "$d/account.pub"
  python3 - "$d" "$D64" <<'PY' > "$d/template.json"
import json, sys
print(json.dumps({"cluster": "drill", "namespace": "fleet-workers",
                  "user_pod": {"image": "x@sha256:" + sys.argv[2], "hub": "https://hub.example.com", "storage_class": "csi",
                               "cred_central": "http://fleet-credproxy.fleet-workers.svc.cluster.local",
                               "private_mirrors": json.load(open(sys.argv[1] + "/pm.json"))},
                  "job": {"image": "x@sha256:" + sys.argv[2], "git_mirror": "git://fleet-git-mirror.arc-runners:9418/{repo}.git"}}))
PY
  export FLEET_PROVISIONER_CONF="$d/template.json" FLEET_PROVISIONER_PUB="$d/account.pub" \
    FLEET_PROVISIONER_API="$api" FLEET_PROVISIONER_SA_DIR="$d/sa"
  exp=$(( $(date +%s) + 300 ))
  tk() { python3 "$BIN/fleet_cluster_ticket.py" sign "$d/key" "$(python3 -c 'import json,sys; f=json.loads(sys.argv[1]); f.update(exp=int(sys.argv[2])); print(json.dumps(f))' "$1" "$exp")"; }
  prov() { OUT=$(python3 "$BIN/fleet-provisioner.py" once "$1" 2>&1); RC=$?; }
  local ref; ref=$(printf 'b%.0s' $(seq 1 40))
  prov "$(tk '{"op":"create-user-pod","cluster":"drill","pod":"u-pmin0001","limits":"","login":"listed1","uid":10002,"join":"fj_cccccccccccccccccccccccccc","nonce":"e0000000000000000000000000000001"}')"
  [ "$RC" = 0 ] || { WHY="the listed pod's create: rc $RC: $OUT"; return 1; }
  prov "$(tk '{"op":"create-user-pod","cluster":"drill","pod":"u-pmout001","limits":"","login":"other1","uid":10003,"join":"fj_dddddddddddddddddddddddddd","nonce":"e0000000000000000000000000000002"}')"
  [ "$RC" = 0 ] || { WHY="the unlisted pod's create: rc $RC: $OUT"; return 1; }
  out=$(python3 - "$api" <<'PY'
import json, sys, urllib.request
bad = []
for pod, want in (("u-pmin0001", True), ("u-pmout001", False)):
    q = urllib.request.Request(sys.argv[1] + "/apis/apps/v1/namespaces/fleet-workers/deployments/" + pod,
                               headers={"Authorization": "Bearer drill-token"})
    t = json.load(urllib.request.urlopen(q))["spec"]["template"]
    g = [c for c in t["spec"]["initContainers"] if c["name"] == "egress-guard"][0]["command"][-1]
    got = ("172.21.9.190/32" in g, t["metadata"]["labels"].get("fleet/mirror-acme-monorepo") == "1",
           "acme-monorepo" in json.dumps(t["spec"]["containers"]))
    if got != (want,) * 3:
        bad.append("%s from the template: guard/label/insteadOf %s, want all %s" % (pod, got, want))
print("\n".join(bad))
PY
) || { WHY="reading the provisioner's pods crashed: $out"; return 1; }
  [ -z "$out" ] || { WHY="$out"; return 1; }
  : > "$d/writes"
  prov "$(tk '{"op":"create-job","cluster":"drill","pod":"u-pmout001","repo":"acme-org/acme-monorepo","ref":"'"$ref"'","kind":"test","cmd":"true","nonce":"e0000000000000000000000000000003"}')"
  [ "$RC" = 3 ] || { WHY="a Job of the private repo for an unlisted pod: rc $RC: $OUT"; return 1; }
  [ ! -s "$d/writes" ] || { WHY="the refused Job wrote: $(cat "$d/writes")"; return 1; }
  prov "$(tk '{"op":"create-job","cluster":"drill","pod":"u-pmin0001","repo":"acme-org/acme-monorepo","ref":"'"$ref"'","kind":"test","cmd":"true","nonce":"e0000000000000000000000000000004"}')"
  [ "$RC" = 0 ] || { WHY="a Job of the private repo for the listed pod: rc $RC: $OUT"; return 1; }
  unset FLEET_PROVISIONER_CONF FLEET_PROVISIONER_PUB FLEET_PROVISIONER_API FLEET_PROVISIONER_SA_DIR
  SECS=$(since "$t0")
  WHAT="私有镜像（git:// 无认证、flannel 不执行 NetworkPolicy）只对名单内登录的 pod 渲染出 egress-guard 放行行 · insteadOf · fleet/mirror-<仓库> 标签；名单外的 pod 三样都没有、pod-etc 不写 insteadOf；把它开给所有人的 --egress-allow / --git-mirror 被拒；--mirror-grant 两个方向都改得对、幂等、带 resourceVersion 检验；执行器按模板建的 pod 一样，名单外 pod 的该仓库 Job 被拒且什么都没写"
}

cred_run_drills "$0"
