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
# shellcheck disable=SC2034  # CAP / SECS / WHY / WHAT are read by the sourced runner
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=fleet-break-it-cred-selftest.sh
BREAK_CRED_LIB=1 . "$BIN/fleet-break-it-cred-selftest.sh"
RENDER="$ROOT/extras/managed-node/render.py"
D64=$(printf 'a%.0s' $(seq 1 64))

# templates <dir> — every pod-carrying object the fleet ships into fleet-workers,
# one JSON List per file: render.py's user pod, door, shared node and Job, and
# (with kubectl, and yq or PyYAML) the kustomized fleet-workers layer
templates() {
  local d="$1"
  python3 "$RENDER" --image "x@sha256:$D64" --hub https://hub.example.com --storage-class csi \
    --user-pod u-drill1 > "$d/user-pod.json" || return 1
  python3 "$RENDER" --door --image "x@sha256:$D64" --hub https://hub.example.com > "$d/door.json" || return 1
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
  WHAT="每个 pod 模板（用户 pod · 门 · 共享节点 · Job${kz:+ · fleet-workers 共享服务}）都不挂集群令牌、各用自己的服务账号；只有 fleet-ops 与 fleet-provisioner 挂（${out}）"
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
 "user_pod": {"image": "x@sha256:$D64", "hub": "https://hub.example.com", "storage_class": "csi"},
 "job": {"image": "x@sha256:$D64"}}
EOF
  export FLEET_PROVISIONER_CONF="$d/template.json" FLEET_PROVISIONER_PUB="$d/account.pub" \
    FLEET_PROVISIONER_API="$api" FLEET_PROVISIONER_SA_DIR="$d/sa"
  exp=$(( $(date +%s) + 300 )); n=0123456789abcdef0123456789abcdef
  tk() { # tk <key> <json fields without nonce/exp> [nonce] [exp]
    python3 "$BIN/fleet_cluster_ticket.py" sign "$1" "$(python3 -c 'import json,sys; f=json.loads(sys.argv[1]); f.update(nonce=sys.argv[2], exp=int(sys.argv[3])); print(json.dumps(f))' "$2" "${3:-$n}" "${4:-$exp}")"
  }
  prov() { OUT=$(python3 "$BIN/fleet-provisioner.py" once "$1" 2>&1); RC=$?; }
  local up='{"op":"create-user-pod","cluster":"drill","pod":"u-drill1","limits":"","join":"fj_abcdefghijklmnopqrstuvwxyz"}'
  local ref job_none job_good
  ref=$(printf 'b%.0s' $(seq 1 40))
  job_none='{"op":"create-job","cluster":"drill","pod":"u-none1","repo":"o/r","ref":"'"$ref"'"}'
  job_good='{"op":"create-job","cluster":"drill","pod":"u-drill1","repo":"o/r","ref":"'"$ref"'"}'
  while IFS='|' read -r why t; do
    prov "$t"
    [ "$RC" = 3 ] && [ ! -s "$d/writes" ] || { WHY="$why: rc $RC, wrote: $(cat "$d/writes" 2>/dev/null): $OUT"; return 1; }
  done <<EOF
no ticket|
forged|$(tk "$d/other" "$up")
another cluster|$(tk "$d/key" '{"op":"create-user-pod","cluster":"prod","pod":"u-drill1","limits":"","join":"fj_abcdefghijklmnopqrstuvwxyz"}')
expired|$(tk "$d/key" "$up" "$n" "$(( $(date +%s) - 1 ))")
an account ticket|v1.$(tk "$d/key" "$up" | cut -d. -f2-)
a field the template has not got|$(tk "$d/key" '{"op":"create-user-pod","cluster":"drill","pod":"u-drill1","limits":"","join":"fj_abcdefghijklmnopqrstuvwxyz","privileged":true}')
a create with no join code|$(tk "$d/key" '{"op":"create-user-pod","cluster":"drill","pod":"u-drill1","limits":""}' 66666666666666666666666666666666)
a join code off its grammar|$(tk "$d/key" '{"op":"create-user-pod","cluster":"drill","pod":"u-drill1","limits":"","join":"x; rm -rf /"}' 77777777777777777777777777777777)
a bind of somebody else's object|$(tk "$d/key" '{"op":"bind-user-pod","cluster":"drill","pod":"u-door1","principal":"gh.1"}' 88888888888888888888888888888888)
an op it has not got|$(tk "$d/key" '{"op":"create-pod","cluster":"drill","pod":"u-drill1"}')
a name that is not a person's pod|$(tk "$d/key" '{"op":"create-user-pod","cluster":"drill","pod":"fleet-door","limits":"","join":"fj_abcdefghijklmnopqrstuvwxyz"}')
limits off the grammar|$(tk "$d/key" '{"op":"create-user-pod","cluster":"drill","pod":"u-drill1","limits":"cpu=0","join":"fj_abcdefghijklmnopqrstuvwxyz"}' 55555555555555555555555555555555)
somebody else's object|$(tk "$d/key" '{"op":"destroy-user-pod","cluster":"drill","pod":"u-door1"}' fedcba9876543210fedcba9876543210)
a Job for no pod|$(tk "$d/key" "$job_none" 11111111111111111111111111111111)
EOF
  # its own guard: what the admission policy refuses, refused before the request
  why=$(python3 - "$BIN" "$D64" <<'PY'
import importlib.util, json, sys, copy
spec = importlib.util.spec_from_file_location("p", sys.argv[1] + "/fleet-provisioner.py")
p = importlib.util.module_from_spec(spec); spec.loader.exec_module(p)
r = p.render()
base = r.user_pod_resources("x@sha256:" + sys.argv[2], "https://hub.example.com", "csi", "u-drill1")
dep = [o for o in base if o["kind"] == "Deployment"][0]
svc = [o for o in base if o["kind"] == "Service"][0]
assert all(p.off_template(o, "fleet-workers") is None for o in base), [p.off_template(o, "fleet-workers") for o in base]
def mut(o, f):
    o = copy.deepcopy(o); f(o); return o
c0 = lambda o: o["spec"]["template"]["spec"]["containers"][0]
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
  printf '{"cluster": "drill", "namespace": "fleet-workers", "user_pod": {"image": "x@sha256:%s", "hub": "https://hub.example.com", "storage_class": "csi"}}\n' \
    "$D64" > "$d/template.json"
  export FLEET_PROVISIONER_CONF="$d/template.json" FLEET_PROVISIONER_PUB="$d/account.pub" \
    FLEET_PROVISIONER_API="$api" FLEET_PROVISIONER_SA_DIR="$d/sa"
  exp=$(( $(date +%s) + 300 ))
  tk() { # tk <json fields without exp> — signed with the hub's key
    python3 "$BIN/fleet_cluster_ticket.py" sign "$d/key" "$(python3 -c 'import json,sys; f=json.loads(sys.argv[1]); f.update(exp=int(sys.argv[2])); print(json.dumps(f))' "$1" "$exp")"
  }
  prov() { OUT=$(python3 "$BIN/fleet-provisioner.py" once "$1" 2>&1); RC=$?; }
  jia='{"op":"create-user-pod","cluster":"drill","pod":"u-jia0001","limits":"","join":"fj_aaaaaaaaaaaaaaaaaaaaaaaaaa","nonce":"a0000000000000000000000000000001"}'
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
  prov "$(tk '{"op":"create-user-pod","cluster":"drill","pod":"u-yi000002","limits":"","join":"fj_bbbbbbbbbbbbbbbbbbbbbbbbbb","nonce":"b0000000000000000000000000000001"}')"
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

cred_run_drills "$0"
