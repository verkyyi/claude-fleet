#!/bin/bash
# fleet-break-it-hub-selftest.sh — the BREAK-IT rows whose drill needs none of
# bin/fleet-break-it-selftest.sh's tmux sandbox: a release, the hub's shape and
# its Go-tested halves (placement, leases, invites, trust, the machine agent), a
# refused hub read, admission, and the node's sessions riding a tmux restart / a
# node update (issue #2699). Split out because that script crept past the gate's 240 s
# per-test cap on CI (212–241 s); it sources the cred half's runner
# (BREAK_CRED_LIB=1), and bin/fleet-break-it-selftest.sh's lockstep lint still
# reads the drill_* names here, so a row with no drill (or a drill with no row)
# reds there.
#
#   node-tmux-restart                               bin/fleet-sessions-snapshot.sh → fleet-restore.sh
#   node-update-sessions                            bin/fleet-node-update.py (sessions save / restore)
#   release-unverified                              bin/fleet-release.sh (fleet-release-selftest.sh's sandbox)
#   hub-release-downtime                            .github/actions/hub-release/probe.sh (downtime_seconds),
#                                                   release.sh shape, deploy/k8s/base (2 replicas, rolling,
#                                                   /readyz, preStop, PDB), tokenledger /readyz + /v1/deploy-probe
#                                                   (go test, when a toolchain is here); the kind drill is
#                                                   .github/workflows/hub-rolling.yml
#   hub-disk-attach-stuck                           deploy/k8s/base (no PVC), components/sqlite-single,
#                                                   overlays/prod (only RWX OSS claims: release-volume.yaml)
#   hub-shape-extra-volume                          .github/actions/hub-release/release.sh shape (the data disk is
#                                                   the claim mounted at /data, not any PVC)
#   hub-read-refused-silent                         bin/fleet-account.sh (quota_budget_json), fleet-lib.sh
#                                                   (fleet_hub_auth_note), fleet-doctor.sh (hubauth)
#   node-person-cert-expired                        bin/fleet-hub-write.sh (the node-token door), fleet-lib.sh
#                                                   (fleet_node_pair, fleet_hub_reap), fleet-doctor.sh (personcert);
#                                                   tokenledger/internal/api fleet_write_signed.go (go test)
#   view-node-restart                               bin/fleet-remote-view.sh (run: exit 3 waits)
#   node-paused-still-placed                        bin/fleet-control-read.sh capacity (admit / admit_why / room),
#                                                   fleet_machine_admit, fleet_machine_headroom; the hub half is
#                                                   tokenledger/internal/api judge() (go test, when a toolchain is here)
#   dispatch-wrong-replica                          tokenledger/internal/api node_route.go (fleet_node_conns +
#                                                   /internal/v1/node-write; go test, when a toolchain is here)
#   two-hubs-double-refresh                         tokenledger/internal/leader (Leader / Lock), credvault Lease's
#                                                   CrossLock, the three gated loops (go test, when a toolchain is here)
#   github-signin-unreachable                       tokenledger/internal/api github_auth.go (githubExchange) +
#                                                   fleet_relay_cred.go (the /github-oauth/ gate); go test, when a
#                                                   toolchain is here; extras/cred-relay/Caddyfile, overlays/prod
#   entry-dns-follows                               tokenledger/internal/api fleet_entry_dns.go + internal/dns
#                                                   (DNSPod; go test, when a toolchain is here), deploy/k8s/overlays/prod
#   entry-name-unclaimed                            tokenledger/internal/api fleet_entry.go (entryEnsureName) +
#                                                   fleet_entry_dns.go (the *.cf guard); go test, when a toolchain is here
#   account-gh-only-check                           tokenledger/internal/api person.go (isPerson, personRow,
#                                                   personRole, admitPerson) + internal/store hub_users.go
#                                                   (hub_identities, migration 2); go test, when a toolchain is here
#   wechat-first-scan-autocreate                    tokenledger/internal/api wechat_auth.go (handleWeChatCallback,
#                                                   handleWeChatBind) + signin_ways.go; go test, when a toolchain is here
#   email-link-replay                               tokenledger/internal/api email_auth.go (handleEmailLink /
#                                                   handleEmailCode) + internal/store hub_signin.go; go test, when here
#   invite-expired                                  tokenledger/internal/api fleet_invites.go + github_auth.go
#                                                   (admitInvite, denyText; go test, when a toolchain is here)
#   drill-person-no-machine                         tokenledger/internal/api fleet_opening.go + fleet_drill.go
#                                                   (accountStateOf, closeDrillLogins; go test, when a toolchain is here)
#   spare-login-empty                               tokenledger/internal/api fleet_spare.go + fleet_accounts.go
#                                                   (claimSpare, replenishSpares; go test, when a toolchain is here)
#   lease-unseparated-user                          tokenledger/internal/api fleet_creds.go (credsepGated) + fleet_join.go
#                                                   (/v1/node/self credsep_gate), internal/agent node_credsep.go,
#                                                   bin/fleet-cred-proxy.py (Router.refresh); go test, when a toolchain is here
#   trust-name-borrowed                             tokenledger/internal/api fleet_trust.go (nodeTrust) + fleet_node_desired.go
#                                                   (go test, when a toolchain is here)
#   release-tampered                                tokenledger/internal/api fleet_release.go (ReleaseStore) +
#                                                   internal/release (Build, Fetch, Unpack; go test, when a toolchain is here)
#   machine-agent-wrong-login                       tokenledger/internal/api node_machine.go (loginEndpoint, serveMachine)
#                                                   + internal/agent node_machine.go / runas.go (go test, when a toolchain is here)
#   usage-unattributed                              tokenledger/internal/agent (the claude:local pool) + internal/api
#                                                   fleet_usage_silent.go (usage_silent; go test, when a toolchain is here)
#   pool-usage-unattributed                         tokenledger/internal/api fleet_person_budget.go (handleCredProxyUsage,
#                                                   poolUsagePass) + internal/store pool_usage.go + internal/credproxy
#                                                   usage.go (go test, when a toolchain is here)
#   pool-usage-node-dropped                         tokenledger/internal/api fleet_person_budget.go (handleNodeUsage,
#                                                   recordUsage, unownedUsage) + bin/fleet-cred-proxy.py (Budget,
#                                                   Meter.split) + bin/fleet-session-cred.sh (--worker; go test, when a toolchain is here)
#   place-server-down                               fleet_server_down (fleet-lib.sh), fleet-control-read.sh start
#                                                   (exit 8), fleet_control.py (UNAVAILABLE); the hub half is
#                                                   tokenledger/internal/api pickNodeAfter (go test, when here)
#   pool-admit-phantoms                             fleet_session_cap_ok / fleet_admit_reserve / fleet_admit_confirm /
#                                                   fleet_admit_release / fleet_admit_holders (fleet-lib.sh), scratch-pool.sh
#   guide-admission-room                            fleet_machine_admit / _fleet_admit_guide_pass / fleet_guide_tick
#                                                   (fleet-lib.sh), dash-raw-session.sh, fleet-alerts.sh event
#   admit-room-advice                               fleet_machine_admit / _fleet_admit_room_advice /
#                                                   fleet_admit_room_advised (fleet-lib.sh), fleet-control-read.sh
#                                                   capacity; the hub half is fleet_client_place.go pinnedFull (go test)
#   admit-open-window-twice                         fleet_machine_admit / fleet_admit_pending / _fleet_admit_advice_left
#                                                   (fleet-lib.sh), dash-raw-session.sh (the hub's worker_start)
#   hubsess-daemon-nohup                            bin/fleet-hub-sessions.sh (ensure: no nohup; the lock)
#   followup-stable-storm                           bin/fleet_followup.py (merge, execute, holding) on the
#                                                   steward's beat (bin/fleet_steward.py)
#   park-lost-progress / park-restored-by-restore   bin/fleet_park.py, fleet-restore.sh (fleet_parked) — through
#                                                   bin/fleet-park-selftest.sh's sandbox (its own isolated tmux socket)
#   dist-no-github                                  bin/dist-no-github-selftest.sh (GitHub a black hole: install-sync,
#                                                   client stage, login bootstrap, the updater's follow → the new version)
#   dist-bad-signature                              bin/dist-no-github-selftest.sh bad-signature (the hub's release
#                                                   refused by ccquota → fetch-failed, still the old version, no GitHub)
#   bootstrap-reaches-github                        bin/dist-no-github-selftest.sh --strict bootstrap bootstrap-hub
#                                                   (a new login on a managed machine / with only a hub: no GitHub, #2775)
#   health-silent-pass                              bin/fleet_steward_health.py (the steward's beat), fleet-doctor.sh --json
#   hub-stream-silent                               tokenledger/web/dist/lib/stream.js (watchdog, backoff, poll fallback;
#                                                   node --test stream.test.mjs, when node is here) + internal/api
#                                                   fleet_stream.go (ping, scope; go test, when a toolchain is here)
#   feedback-secret-in-text                         bin/fleet-feedback.sh (fleet_redact.py over the words, the
#                                                   whole-set recheck; a fake hub records the bytes)
#   feedback-secret-in-attach                       bin/fleet-feedback.sh --attach (conf/debug-collect.list's fresh
#                                                   rows + the screen, each through conf/secret-shapes.list)
#   service-log-cross-login                         tokenledger/internal/api fleet_service_log.go (FleetScope before any
#                                                   node read, one follow per service, masking; go test, when a toolchain
#                                                   is here) + internal/agent node_service_log.go (the register's path only)
#                                                   + web/dist/lib/svc-log.js (403 is a word; node --test, when node is here)
#   debug-ticket-replayed                           tokenledger/internal/api fleet_debug_ticket.go (debugTicketAuth: the
#                                                   fingerprint, the HMAC, expiry, the superseded row; go test, when a
#                                                   toolchain is here) + bin/fleet-install.sh (debug_fp: only the hash sent)
#   debug-page-stuck                                tokenledger/internal/api fleet_debug.go (debugTick: no page in 15
#                                                   minutes ⇒ unfinished, to the admin; seven days ⇒ gone; the upload
#                                                   re-checked against the shape table; go test, when a toolchain is
#                                                   here) + bin/fleet_steward.py debug_step (the orchestrator's line)
#   feedback-identity-public                        tokenledger/internal/api fleet_feedback_github.go (feedbackIssueBody:
#                                                   the ONE public template; App token never logged; go test, when a
#                                                   toolchain is here)
#   feedback-github-down                            tokenledger/internal/api fleet_feedback_github.go (feedbackFile: 待转,
#                                                   1 min doubling to 1 h, the marker adopts the issue a 500 created;
#                                                   go test, when a toolchain is here)
#   feedback-reply-lost                             tokenledger/internal/api fleet_feedback_reply.go (a close read
#                                                   once, sent until a node says succeeded, the next session when
#                                                   the first is gone, 30 days; go test, when a toolchain is here)
#                                                   + bin/fleet_control.py (the prefix to any session's inbox)
#   dist-publish-tampered                           tokenledger/internal/api fleet_publish.go (POST …/publish: the archive
#                                                   hashed into the commit's tree, OIDC, forward only; go test, when a
#                                                   toolchain is here) + bin/fleet-release-publish.sh (what CI sends)
#
# Each prints `PASS <id> <secs>s ≤<cap>s <what came back>` like its parent.
# BREAK_KEEP=1 keeps the work dir; BREAK_ONLY narrows to those ids.
# shellcheck disable=SC2034  # CAP / SECS / WHY / WHAT are read by the sourced runner
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=fleet-break-it-cred-selftest.sh
BREAK_CRED_LIB=1 . "$BIN/fleet-break-it-cred-selftest.sh"

# ---- release-unverified (#2483, EPIC #2482 C3): `fleet release` runs the whole
# road — CI, the move, the hub, every machine, this machine — and stops at the
# first step that fails. The sandbox is bin/fleet-release-selftest.sh's (a real
# bare repo + the real fleet-stable.sh; fake gh, hub, roster, machines, local
# install-sync and doctor): a red check refuses and is named, a release logs every
# machine's arrival, a machine that never follows is named, this machine's
# rejection moves stable back by itself.
drill_release_unverified() {
  CAP=60; local t0 out
  t0=$(now)
  out=$(bash "$BIN/fleet-release-selftest.sh" 2>&1) || { WHY="$(printf '%s\n' "$out" | grep -m 3 '^FAIL' | tr '\n' '|')"; return 1; }
  SECS=$(since "$t0")
  WHAT="fleet release：CI 红拒发并点名；发布逐台记到位时间；没跟上的机器点名；本机体检拒了自动退回 stable"
}

# ---- hub-release-downtime (#2125, EPIC #2119 C6): a hub release used to be
# 30–60 s of the whole site down (Recreate on one SQLite disk), and nobody
# measured it. Now every release is measured — probe.sh, once a second, /healthz
# + a write; a fake hub that goes down for ~3 s must read downtime_seconds ≥ 2,
# one that stays up must read 0 — and the base is the rolling shape that makes
# it 0 (two replicas, maxUnavailable 0, /readyz, preStop, a PDB), whose hub half
# is go-tested here when a toolchain is. The real thing (kind, two replicas +
# Postgres, three releases, a deleted pod, a broken release + rollback) is CI's
# hub-rolling.yml; this checks it is there and runs drill.sh.
drill_hub_release_downtime() {
  CAP=60; local t0 sc="$WORK/hrd" probe="$ROOT/.github/actions/hub-release/probe.sh" port='' hpid out out2 down1 rc f
  f="$ROOT/deploy/k8s/base/deployment.yaml"
  [ -f "$probe" ] || { WHY="no availability probe (${probe#$ROOT/})"; return 1; }
  grep -q '^  replicas: 2$' "$f" || { WHY="the base is not two replicas"; return 1; }
  grep -q '^    type: RollingUpdate$' "$f" && grep -q '^      maxUnavailable: 0$' "$f" || { WHY="the base does not roll with maxUnavailable 0"; return 1; }
  grep -q 'path: /readyz' "$f" || { WHY="the base's readiness is not /readyz"; return 1; }
  grep -q 'preStop:' "$f" || { WHY="the base has no preStop"; return 1; }
  grep -q 'minAvailable: 1' "$ROOT/deploy/k8s/base/pdb.yaml" 2>/dev/null || { WHY="the base has no PodDisruptionBudget"; return 1; }
  grep -q 'downtime_seconds' "$ROOT/.github/workflows/hub-deploy.yml" || { WHY="hub-deploy's summary has no downtime_seconds"; return 1; }
  grep -q 'overlays/kind/drill.sh' "$ROOT/.github/workflows/hub-rolling.yml" 2>/dev/null || { WHY="no kind drill in CI (hub-rolling.yml → drill.sh)"; return 1; }
  mkdir -p "$sc"
  cat > "$sc/hub.py" <<'PY2'
import os, signal, sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
signal.alarm(int(sys.argv[2]))
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def reply(self):
        up = open(sys.argv[3]).read().strip() == "up"
        self.send_response(200 if up else 503); self.send_header("Content-Length", "0"); self.end_headers()
    def do_GET(self): self.reply()
    def do_POST(self): self.reply()
srv = ThreadingHTTPServer(("127.0.0.1", 0), H)
open(sys.argv[1] + ".tmp", "w").write(str(srv.server_address[1])); os.replace(sys.argv[1] + ".tmp", sys.argv[1])
srv.serve_forever()
PY2
  echo up > "$sc/mode"
  python3 "$sc/hub.py" "$sc/port" "$((CAP + 30))" "$sc/mode" 2>"$sc/hub.err" & hpid=$!
  for _ in $(seq 1 300); do [ -s "$sc/port" ] && break; sleep 0.1; done
  { read -r port < "$sc/port"; } 2>/dev/null
  [ -n "$port" ] || { kill "$hpid" 2>/dev/null; WHY="the fake hub did not start: $(tail -2 "$sc/hub.err" | tr '\n' ' ')"; return 1; }
  t0=$(now)
  # a Recreate release: up, ~3 s of 503, up again
  sh "$probe" "http://127.0.0.1:$port" "$sc/stop1" 30 > "$sc/p1.log" 2>&1 &
  sleep 2; echo down > "$sc/mode"; sleep 3; echo up > "$sc/mode"; sleep 2; touch "$sc/stop1"
  for _ in $(seq 1 50); do tail -1 "$sc/p1.log" | grep -q '^probes=' && break; sleep 0.1; done
  out=$(tail -1 "$sc/p1.log")
  case "$out" in "probes="*" downtime_seconds="[2-6]" write_unsupported=0") ;; *)
    kill "$hpid" 2>/dev/null; WHY="~3 s of 503 read as [$out], want downtime_seconds 2–6"; return 1 ;; esac
  down1=${out#*downtime_seconds=}; down1=${down1%% *}
  grep -q '^DOWN .* healthz=503 write=503' "$sc/p1.log" || { kill "$hpid" 2>/dev/null; WHY="the probe named no DOWN second"; return 1; }
  # a rolling release: up throughout
  sh "$probe" "http://127.0.0.1:$port" "$sc/stop2" 30 > "$sc/p2.log" 2>&1 &
  sleep 3; touch "$sc/stop2"
  for _ in $(seq 1 50); do tail -1 "$sc/p2.log" | grep -q '^probes=' && break; sleep 0.1; done
  kill "$hpid" 2>/dev/null; wait "$hpid" 2>/dev/null
  out2=$(tail -1 "$sc/p2.log")
  case "$out2" in "probes="[1-9]*" downtime_seconds=0 write_unsupported=0") ;; *) WHY="a hub up throughout read as [$out2]"; return 1 ;; esac
  if [ "${BREAK_GO:-1}" != 0 ] && command -v go >/dev/null 2>&1; then
    out=$(cd "$ROOT/tokenledger" && GOFLAGS=-mod=mod GOPROXY=off GOTOOLCHAIN=local \
          go test -count=1 -run '^(TestReadyzAndDeployProbe|TestReadyFollowsTheMigrations|TestShutdownGrace)$' ./internal/api ./internal/store ./cmd/ccquota 2>&1); rc=$?
    case "$rc:$out" in
      0:*'no tests to run'*) WHY="the hub half's Go tests are not there (go test ran none)"; return 1 ;;
      0:*) WHAT="停 ~3 秒的发布读出 downtime_seconds=${down1}；一直在的读 0；base 两份滚动 + /readyz + preStop + PDB；/readyz 与写探测、关停宽限 go test 绿；真两份 + Postgres 的三次发布 / 删 pod / 回退在 CI hub-rolling" ;;
      *GOPROXY=off*|*'module lookup disabled'*|*'cannot find module'*|*'missing go.sum entry'*|*'requires go >= '*)
        WHAT='探测读数对（停 ~3 秒 ≥2、一直在 0）；base 是滚动形态；入口的 Go 测试在这台没有模块缓存——Go 门跑它们' ;;
      *) WHY="the hub half (go test) is red: $(printf '%s' "$out" | grep -v '^ok' | head -6 | tr '\n' ' ')"; return 1 ;;
    esac
  else
    WHAT='探测读数对（停 ~3 秒 ≥2、一直在 0）；base 是滚动形态；没有 go：Go 门跑 /readyz 测试'
  fi
  SECS=$(since "$t0")
}

# ---- hub-disk-attach-stuck (#2125): a release or a rebuilt pod stuck in
# ContainerCreating on the cloud disk's detach/attach (RUNBOOK, 2026-09-13).
# The rolling shape mounts no disk at all; the disk lives only in the single
# SQLite shape's component, which production dropped at the switch (#2215).
drill_hub_disk_attach_stuck() {
  CAP=30; local t0 b="$ROOT/deploy/k8s/base" c="$ROOT/deploy/k8s/components/sqlite-single" r
  t0=$(now)
  if grep -l 'persistentVolumeClaim\|kind: PersistentVolumeClaim' "$b"/*.yaml >/dev/null 2>&1; then
    WHY="the base still has a disk: $(grep -l 'persistentVolumeClaim\|kind: PersistentVolumeClaim' "$b"/*.yaml | tr '\n' ' ')"; return 1
  fi
  grep -q 'kind: PersistentVolumeClaim' "$c/pvc.yaml" 2>/dev/null || { WHY="the single SQLite shape lost its disk (${c#$ROOT/}/pvc.yaml)"; return 1; }
  if command -v kubectl >/dev/null 2>&1 && r=$(kubectl kustomize "$b" 2>/dev/null); then
    case "$r" in *PersistentVolumeClaim*|*claimName*) WHY="the base render mounts a disk"; return 1 ;; esac
    r=$(kubectl kustomize "$ROOT/deploy/k8s/overlays/prod" 2>/dev/null) || { WHY="the prod overlay does not render"; return 1; }
    case "$r" in *"kind: PersistentVolumeClaim"*) WHY="prod still mounts a disk after the switch (the render creates a claim)"; return 1 ;; esac
    # A claim prod mounts is no cloud disk only when the overlay declares it as
    # an RWX OSS volume (ossfs: a network mount, nothing to detach/attach) — the
    # /releases volume of #2366; any other claim is a disk that can stick.
    local cl pv nr=0
    for cl in $(printf '%s\n' "$r" | sed -n 's/^[[:space:]]*claimName:[[:space:]]*//p'); do
      pv=$(grep -l "^  name: $cl\$" "$ROOT/deploy/k8s/overlays/prod"/*.yaml 2>/dev/null | head -1)
      if [ -z "$pv" ] || ! grep -q 'ReadWriteMany' "$pv" || ! grep -q 'driver: ossplugin.csi.alibabacloud.com' "$pv" \
         || grep -q 'diskplugin' "$pv"; then
        WHY="prod still mounts a disk after the switch (claim $cl is not a declared RWX OSS volume)"; return 1
      fi
      nr=$((nr + 1))
    done
    WHAT="base 与生产的渲染都没有盘（库在 Postgres），盘只在单份形态的组件里（回滚用）；生产挂的 $nr 个卷是 OSS（RWX，无挂盘）"
  else
    WHAT='base 没有盘（按文件核对；没有 kubectl 不渲染），盘只在单份形态的组件里'
  fi
  SECS=$(since "$t0")
}

# ---- hub-shape-extra-volume (#2384): the release's shape check counted ANY
# persistentVolumeClaim as the SQLite data disk, so the rolling (Postgres) prod
# with its RWX /releases volume (#2366) read as a broken sqlite shape and every
# hub-deploy went red. The data disk is the claim mounted at /data; another
# claim (an RWX shared volume) is no disk — and every refusal still holds.
drill_hub_shape_extra_volume() {
  CAP=20; local t0 rel="$ROOT/.github/actions/hub-release/release.sh" d="$WORK/hsv" k got want
  t0=$(now); mkdir -p "$d"
  python3 - "$d" <<'PY2' || { WHY="could not write the renders"; return 1; }
import json, os, sys
out = sys.argv[1]
def render(kind, extra=False, replicas=None, strat=None, dburl=None, pdb=None):
    pg = kind == 'postgres'
    c = {'name': 'ccquota', 'env': [], 'volumeMounts': []}
    vols = []
    if pg if dburl is None else dburl: c['env'].append({'name': 'CCQUOTA_DB_URL', 'value': 'x'})
    if pg:
        c['readinessProbe'] = {'httpGet': {'path': '/readyz'}}
        c['lifecycle'] = {'preStop': {'exec': {'command': ['sleep', '5']}}}
    else:
        c['volumeMounts'].append({'name': 'data', 'mountPath': '/data'})
        vols.append({'name': 'data', 'persistentVolumeClaim': {'claimName': 'ccquota-data'}})
    if extra:
        c['volumeMounts'].append({'name': 'releases', 'mountPath': '/releases'})
        vols.append({'name': 'releases', 'persistentVolumeClaim': {'claimName': 'ccquota-releases'}})
    spec = {'replicas': replicas if replicas is not None else (2 if pg else 1),
            'strategy': strat or ({'type': 'RollingUpdate', 'rollingUpdate': {'maxUnavailable': 0}} if pg else {'type': 'Recreate'}),
            'template': {'spec': {'containers': [c], 'volumes': vols}}}
    docs = [{'kind': 'Deployment', 'metadata': {'name': 'ccquota-hub'}, 'spec': spec}]
    if pg if pdb is None else pdb: docs.append({'kind': 'PodDisruptionBudget', 'metadata': {'name': 'ccquota-hub'}})
    return docs
cases = {
    'pg-extra': render('postgres', extra=True),
    'pg': render('postgres'),
    'sqlite': render('sqlite'),
    'sqlite-extra': render('sqlite', extra=True),
    'sqlite-2': render('sqlite', replicas=2),
    'sqlite-roll': render('sqlite', strat={'type': 'RollingUpdate'}),
    'sqlite-dburl': render('sqlite', dburl=True),
    'sqlite-pdb': render('sqlite', pdb=True),
    'pg-1': render('postgres', extra=True, replicas=1),
    'pg-nodb': render('postgres', extra=True, dburl=False),
}
for k, docs in cases.items():
    with open(os.path.join(out, k + '.json'), 'w') as f:
        for x in docs: f.write(json.dumps(x) + '\n')
PY2
  for k in 'pg-extra:mode=postgres' 'pg:mode=postgres' 'sqlite:mode=sqlite' 'sqlite-extra:mode=sqlite' \
           'sqlite-2:replicas 2' 'sqlite-roll:strategy RollingUpdate' 'sqlite-dburl:CCQUOTA_DB_URL (half' \
           'sqlite-pdb:PodDisruptionBudget on one' 'pg-1:replicas 1 (want' 'pg-nodb:no CCQUOTA_DB_URL'; do
    want=${k#*:}; k=${k%%:*}
    got=$(bash "$rel" shape "$d/$k.json" 2>&1)
    case "$want" in
      mode=*) [ "$got" = "$want" ] || { WHY="$k read as [$(printf '%s' "$got" | tr '\n' ' ')], want $want"; return 1; } ;;
      *) case "$got" in *"$want"*) ;; *) WHY="$k was not refused for '$want': [$(printf '%s' "$got" | tr '\n' ' ')]"; return 1 ;; esac ;;
    esac
  done
  WHAT='滚动形态 + 一块 RWX 额外卷读作 mode=postgres；挂 /data 的那块才是数据盘；单份形态的四条拒绝、滚动形态的拒绝照旧'
  SECS=$(since "$t0")
}

# The node's sessions ride through a tmux restart and a node update (issue #2484):
# each drill runs the selftest that does it for real on an isolated socket / a
# sandboxed updater, so the row and the code it names cannot drift apart.
drill_node_tmux_restart() {
  CAP=90; local t0 out
  t0=$(now)
  out=$(bash "$BIN/fleet-sessions-snapshot-selftest.sh" 2>&1) \
    || { WHY="fleet-sessions-snapshot-selftest: $(printf '%s' "$out" | grep -m1 FAIL)"; return 1; }
  SECS=$(since "$t0")
  WHAT="save → kill-server → restore：同名同目录同对话回来，已关单 / 已删目录 / fleet-down 的不开"
}

drill_node_update_sessions() {
  CAP=90; local t0 out
  t0=$(now)
  out=$(python3 -W ignore::ResourceWarning "$BIN/fleet-node-update-selftest.py" --drill-sessions 2>&1) \
    || { WHY="fleet-node-update J_Sessions: $(printf '%s' "$out" | grep -m1 -E 'Error|FAIL')"; return 1; }
  SECS=$(since "$t0")
  WHAT="更新器切换前对每个托管登录 save，提交 / 回退后 restore 并记进 update.log"
}

drill_view_node_restart() {
  CAP=90; local t0 out
  t0=$(now)
  out=$(bash "$BIN/remote-view-run-selftest.sh" 2>&1) \
    || { WHY="remote-view-run-selftest: $(printf '%s' "$out" | grep -m1 FAIL)"; return 1; }
  SECS=$(since "$t0")
  WHAT="会话暂时不在：说「机器在重启，稍等」，每 5s 再连同一地址，2 分钟后才说已不在"
}

# hub-read-refused-silent (issue #2630): a node login with no viewer token read
# "HTTP 401: a viewer token is required" on every quota tick for a day, and
# nothing said so in its own words — the doctor said 「盲」. Now ccquota runs with
# the node token (the summary door), a refused read is recorded once per reader
# in global/hub_auth_fail, and the doctor's hubauth row FAILs with the fix.
drill_hub_read_refused_silent() {
  CAP=30; local t0 d="$WORK/hrr" l
  mkdir -p "$d/fake" "$d/tmp/.claude-dash/global" "$d/conf/fleets/s1" "$d/accounts"
  printf 'tok-a\n' > "$d/accounts/a"; chmod 600 "$d/accounts/a"
  printf 'FLEET_REPO="acme/widgets"\n' > "$d/conf/fleets/s1/conf"
  printf 'CCQUOTA_HUB_URL=http://hub.test:8787\nCCQUOTA_TOKEN=node-tok\n' > "$d/conf/node.env"; chmod 600 "$d/conf/node.env"
  printf '#!/bin/sh\nprintf "%%s\\n" "${CCQUOTA_TOKEN:-none}" > "%s/token"\nprintf %s\n' "$d" \
    "'{\"verdict\":\"unknown\",\"reason\":\"hub unreachable: HTTP 401: {\\\\\"error\\\\\":\\\\\"a viewer token is required\\\\\"}\",\"accounts\":null}\\n'" > "$d/fake/ccquota"
  chmod +x "$d/fake/ccquota"
  hrr() { env HOME="$d" PATH="$d/fake:$PATH" TMPDIR="$d/tmp" FLEET_CONF_DIR="$d/conf" FLEET_SKIP_GLOBAL_CONF=1 \
            FLEET_ACCOUNTS_DIR="$d/accounts" CCQUOTA_HUB_URL=http://hub.test:8787 FLEET_HUB_AUTH_FAIL_SECS=0 "$@"; }
  t0=$(now)
  hrr bash "$BIN/fleet-account.sh" quota --refresh >/dev/null 2>&1
  [ "$(cat "$d/token" 2>/dev/null)" = node-tok ] || { WHY="ccquota did not get the node token: [$(cat "$d/token" 2>/dev/null)]"; return 1; }
  grep -q '^quota	.*HTTP 401' "$d/tmp/.claude-dash/global/hub_auth_fail" 2>/dev/null \
    || { WHY="the refused read left no hub_auth_fail record"; return 1; }
  sleep 1
  l=$(hrr bash "$BIN/fleet-doctor.sh" 2>/dev/null | grep -E '^ *FAIL +hubauth ')
  case "$l" in *"quota refused"*"node token is here"*) ;; *) WHY="the doctor's hubauth row is not a FAIL naming the fix: [$l]"; return 1 ;; esac
  SECS=$(since "$t0"); WHAT="401 的额度读：ccquota 拿到节点 token，hub_auth_fail 记一行，doctor hubauth FAIL 并给出修法"
}

# A separated node's where (issue #2665): node.env is the role account's, the
# credential proxy hands out its broker URL + an fcpn1. token — and the read sent
# that token to FLEET_HUB_URL, the hub itself, which had never seen it: 401
# 「unrecognised enrollment token」, where said nobody is connected while the
# person sat at an iTerm2. The pair goes together now (node_pair), and a node
# token the hub refuses falls back to the other credential.
drill_node_token_wrong_door() {
  CAP=10; local t0 sc="$WORK/ntwd" sb port wj conf
  mkdir -p "$sc/sbin" "$sc/conf"; sb="$sc/sbin"; conf="$sc/conf"
  cat > "$sc/hub.py" <<'PY'
import http.server, json, os, sys
D = sys.argv[1]
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        open(D + "/hub.log", "a").write("%s %s\n" % (self.path, self.headers.get("Authorization")))
        if (self.path, self.headers.get("Authorization")) == ("/hub/v1/node/client", "Bearer fcpn1.BROKER"):
            b = json.dumps({"state": "active", "lease": {"id": "L1", "device": "MacBook", "terminal": "iTerm2 3.7",
                                                         "caps": ["show_file", "iterm2"]}}).encode()
            self.send_response(200)
        else:
            b = json.dumps({"error": "unrecognised enrollment token"}).encode()
            self.send_response(401)
        self.send_header("Content-Type", "application/json"); self.end_headers(); self.wfile.write(b)
s = http.server.HTTPServer(("127.0.0.1", 0), H)
open(D + "/port.tmp", "w").write(str(s.server_address[1])); os.replace(D + "/port.tmp", D + "/port")
s.serve_forever()
PY
  python3 "$sc/hub.py" "$sc" 2>"$sc/hub.err" & local hp=$!
  for _ in $(seq 1 100); do [ -s "$sc/port" ] && break; sleep 0.1; done
  port=$(cat "$sc/port" 2>/dev/null); [ -n "$port" ] || { kill "$hp" 2>/dev/null; WHY="the fake hub did not start: $(tail -2 "$sc/hub.err")"; return 1; }
  cp "$BIN/fleet-client-lease.py" "$BIN/fleet-connect.py" "$BIN/fleet-client-where.sh" "$sb/"
  printf '#!/bin/bash\n[ "$1" = node-token ] && printf "http://127.0.0.1:%s/hub\\tfcpn1.BROKER\\n"\n' "$port" > "$sb/fleet-cred-proxy.sh"
  ln -sf "$sc/role-only/node.env" "$conf/node.env"            # the role account's: unreadable here
  printf 'CCQUOTA_HUB_URL=http://127.0.0.1:%s\n' "$port" > "$conf/node.pub.env"
  printf '{}\n' > "$conf/credsep.json"
  t0=$(now)
  wj=$( unset CCQUOTA_TOKEN CCQUOTA_HUB_URL FLEET_HUB_TOKEN FLEET_CLIENT_WHERE_CMD
        export FLEET_CONF_DIR="$conf" HOME="$sc" FLEET_HUB_URL="http://127.0.0.1:$port" NO_PROXY='*' no_proxy='*' \
               FLEET_SHELL_SESSION=nosuch-ntwd
        bash "$sb/fleet-client-where.sh" --json 2>&1 )
  SECS=$(since "$t0")
  kill "$hp" 2>/dev/null; wait "$hp" 2>/dev/null
  case "$wj" in *'"device": "MacBook"'*) ;; *) WHY="where did not answer the client off the broker: [$wj]"; return 1 ;; esac
  case "$wj" in *'"hub": "up"'*) ;; *) WHY="where does not say hub up: [$wj]"; return 1 ;; esac
  grep -q '^/hub/v1/node/client Bearer fcpn1.BROKER$' "$sc/hub.log" 2>/dev/null \
    || { WHY="the broker was never asked: $(tr '\n' '|' < "$sc/hub.log" 2>/dev/null)"; return 1; }
  ! grep -v '^/hub/' "$sc/hub.log" | grep -q 'fcpn1\.' \
    || { WHY="the broker's token still went to the hub: $(tr '\n' '|' < "$sc/hub.log")"; return 1; }
  WHAT="分离节点的 where 拿 broker 令牌问 broker（不再送去入口被 401）：答出 MacBook · iTerm2，hub up"
}

# A node's own hub writes with the person's certificate lapsed (issue #3106):
# the steward on macmini could not reap three finished workers on mini2 — the
# write door took only a viewer token or the person's 12-hour `fleet login`
# certificate, and nothing on a node renews that. Here a sandbox login holds an
# EXPIRED certificate and no viewer token; fleet_hub_reap must still land, by the
# login's node token — node.env's at its hub, and on a separated login the
# credential proxy's broker pair — and never send the certificate. The hub half
# (the node token acts as the login's owner, another person's worker is 404, the
# worker tools only) is TestFleetWriteByNodeToken, run when a toolchain is here.
drill_node_person_cert_expired() {
  CAP=30; local t0 d="$WORK/npce" port hp out leg sb tests='TestFleetWriteByNodeToken' rc gout
  mkdir -p "$d/.ssh" "$d/conf" "$d/sep/conf" "$d/sb"
  ssh-keygen -q -t ed25519 -N '' -f "$d/ca" >/dev/null 2>&1 && ssh-keygen -q -t ed25519 -N '' -f "$d/.ssh/fleet-cert" >/dev/null 2>&1 \
    && ssh-keygen -q -s "$d/ca" -I npce -n "$(id -un)" -V 20200101:20200102 "$d/.ssh/fleet-cert.pub" >/dev/null 2>&1 \
    || { WHY="ssh-keygen could not make the expired certificate"; return 1; }
  cat > "$d/hub.py" <<'PY2'
import http.server, json, os, sys
D = sys.argv[1]
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length") or 0)).decode()
        auth = self.headers.get("Authorization") or ""
        try:
            req = json.loads(body)
        except ValueError:
            req = {}
        open(D + "/hub.log", "a").write("%s %s %s cert=%s\n" % (self.path, auth, req.get("tool"), bool(req.get("cert"))))
        if (self.path, auth) in (("/v1/fleet/write", "Bearer node-tok"), ("/hub/v1/fleet/write", "Bearer fcpn1.BROKER")) \
                and req.get("tool") == "worker_reap":
            b = {"operation_id": "op1", "status": "succeeded", "result": {"token": "reaped:full"}}
            self.send_response(200)
        else:
            b = {"error": "a session, a viewer token or a connection certificate is required"}
            self.send_response(401)
        b = json.dumps(b).encode()
        self.send_header("Content-Type", "application/json"); self.end_headers(); self.wfile.write(b)
s = http.server.HTTPServer(("127.0.0.1", 0), H)
open(D + "/port.tmp", "w").write(str(s.server_address[1])); os.replace(D + "/port.tmp", D + "/port")
s.serve_forever()
PY2
  python3 "$d/hub.py" "$d" 2>"$d/hub.err" & hp=$!
  for _ in $(seq 1 100); do [ -s "$d/port" ] && break; sleep 0.1; done
  port=$(cat "$d/port" 2>/dev/null); [ -n "$port" ] || { kill "$hp" 2>/dev/null; WHY="the fake hub did not start: $(tail -2 "$d/hub.err")"; return 1; }
  printf 'CCQUOTA_HUB_URL=http://127.0.0.1:%s\nCCQUOTA_TOKEN=node-tok\n' "$port" > "$d/conf/node.env"; chmod 600 "$d/conf/node.env"
  # separated: node.env is the role account's (unreadable), the proxy hands out its broker pair
  ln -s "$BIN/fleet-lib.sh" "$d/sb/fleet-lib.sh"; ln -s "$BIN/fleet-hub-write.sh" "$d/sb/fleet-hub-write.sh"
  printf '#!/bin/bash\n[ "$1" = node-token ] && printf "http://127.0.0.1:%s/hub\\tfcpn1.BROKER\\n"\n' "$port" > "$d/sb/fleet-cred-proxy.sh"
  ln -sf "$d/role-only/node.env" "$d/sep/conf/node.env"
  printf 'CCQUOTA_HUB_URL=http://127.0.0.1:%s\n' "$port" > "$d/sep/conf/node.pub.env"; printf '{}\n' > "$d/sep/conf/credsep.json"
  t0=$(now)
  for leg in "node.env:$d/conf:$BIN" "separated:$d/sep/conf:$d/sb"; do
    IFS=: read -r leg conf sb <<<"$leg"
    out=$( unset CCQUOTA_VIEWER_TOKEN CCQUOTA_TOKEN FLEET_SHELL FLEET_HUB_WRITE_CMD FLEET_HUB_WRITE_NODE_TOKEN FLEET_CERT
           export HOME="$d" XDG_CONFIG_HOME="$d/.config" FLEET_CONF_DIR="$conf" CCQUOTA_HUB_URL="http://127.0.0.1:$port" \
                  NO_PROXY='*' no_proxy='*'
           bash -c '. "$1/fleet-lib.sh" && fleet_hub_reap "U/fleet:issue-3049" 5' npce "$sb" 2>&1 )
    case "$out" in *reaped:full*) ;; *) kill "$hp" 2>/dev/null; WHY="$leg: the reap did not land with the certificate expired: [$(printf '%s' "$out" | tr '\n' ' ')]"; return 1 ;; esac
  done
  SECS=$(since "$t0")
  kill "$hp" 2>/dev/null; wait "$hp" 2>/dev/null
  grep -q '^/v1/fleet/write Bearer node-tok worker_reap cert=False$' "$d/hub.log" \
    || { WHY="node.env's token never reached the write door: $(tr '\n' '|' < "$d/hub.log")"; return 1; }
  grep -q '^/hub/v1/fleet/write Bearer fcpn1.BROKER worker_reap cert=False$' "$d/hub.log" \
    || { WHY="the separated login never asked the broker: $(tr '\n' '|' < "$d/hub.log")"; return 1; }
  ! grep -q 'cert=True' "$d/hub.log" || { WHY="a node still sent the person's certificate: $(tr '\n' '|' < "$d/hub.log")"; return 1; }
  grep -q 'personcert' "$BIN/fleet-doctor.sh" || { WHY="the doctor has no personcert row"; return 1; }
  WHAT='证书过期、没有 viewer 令牌：节点凭自己的节点令牌回收（node.env 直连入口 / 分离登录走凭据代理 broker），证书一次没发'
  if [ "${BREAK_GO:-1}" != 0 ] && command -v go >/dev/null 2>&1; then
    gout=$(cd "$ROOT/tokenledger" && GOFLAGS=-mod=mod GOPROXY=off GOTOOLCHAIN=local \
           go test -count=1 -run "^($tests)\$" ./internal/api 2>&1); rc=$?
    case "$rc:$gout" in
      0:*'no tests to run'*) WHY="the Go test $tests is not there (go test ran none)"; return 1 ;;
      0:*) WHAT="${WHAT}；入口只认同一主人的会话、别人的 404、只放 worker 工具（go test）" ;;
      *GOPROXY=off*|*'module lookup disabled'*|*'cannot find module'*|*'missing go.sum entry'*|*'requires go >= '*) ;;
      *) WHY="the Go half is red: $(printf '%s' "$gout" | grep -v '^ok' | head -6 | tr '\n' ' ')"; return 1 ;;
    esac
  else
    grep -q "^func $tests(" "$ROOT/tokenledger/internal/api/fleet_write_tools_test.go" 2>/dev/null \
      || { WHY="the hub half's test $tests is not in fleet_write_tools_test.go"; return 1; }
  fi
}

# A machine whose own gate is holding new sessions (fleet_machine_admit: memory
# tight / load high) while its heartbeat says nothing of it (issue #1836, EPIC
# #2074 C5). Since #1831 FLEET_GLOBAL_MAX_SESSIONS defaults to 0, so the beat's
# capacity read `max_sessions:0` = never full, and the hub kept placing starts
# on a machine that refused each one on arrival (RC_CAP). Node half, for real:
# `fleet-control-read.sh capacity` under stubbed readings — critical memory
# pressure, then a load over the bound, then a healthy machine, then the gate
# switched off — must say admit:false + the reason + room, admit:true + room,
# and with FLEET_ADMIT=0 admit:true and no room (nothing for the hub to hold
# on). Hub half: the Go tests that pin judge() (`TestNodePlace{SkipsPausedNode,
# AllPausedRefuses,WithoutCapFieldsFiltersNothing}`), run here when a toolchain
# and the module cache are present — GOPROXY=off, a drill never downloads;
# otherwise the Go gate (tokenledger.yml) is where they run and WHAT says so.
drill_node_paused_still_placed() {
  CAP=120; local t0 d="$WORK/np" out gohalf rc
  mkdir -p "$d/conf" "$d/tmp"
  # cap <mem-stub> <load-stub> [VAR=val …] → the capacity object. 16000 MB of RAM,
  # one agent of 400 MB (×3 growth ⇒ 1200 MB a session) — never this box's own ps.
  # The gate is switched ON here explicitly: run-selftests.sh exports FLEET_ADMIT=0
  # for the whole gate (so no selftest's spawn is held by the runner's memory),
  # and with it off capacity says admit:true and no room — the drill's last leg,
  # which passes its own FLEET_ADMIT=0 after the 1.
  cap() {
    local m="$1" l="$2"; shift 2
    env FLEET_ADMIT=1 "$@" FLEET_CONF_DIR="$d/conf" TMPDIR="$d/tmp" HOME="$d" FLEET_MEM_TOTAL_MB=16000 \
      FLEET_MEM_PS_CMD="printf '101 1 $(id -u) 409600 01:00 claude\\n'" \
      FLEET_MEM_PROBE_CMD="$m" FLEET_LOAD_PROBE_CMD="$l" \
      bash "$BIN/fleet-control-read.sh" capacity 2>&1
  }
  t0=$(now)
  out=$(cap 'echo 4 5 97 0' 'echo 0.5')
  case "$out" in *'"admit":false'*'"admit_why":"内存紧张"'*'"room":0'*) ;; *)
    WHY="capacity under critical memory pressure does not say admit:false, admit_why 内存紧张, room 0: $out"; return 1 ;; esac
  out=$(cap 'echo 1 66 5 6' 'echo 1.9')
  case "$out" in *'"admit":false'*'"admit_why":"负载过高"'*'"room":'[1-9]*) ;; *)
    WHY="capacity under load 1.9/core does not say admit:false, admit_why 负载过高 with its room: $out"; return 1 ;; esac
  out=$(cap 'echo 1 66 5 6' 'echo 0.5')
  case "$out" in *'"max_sessions":0'*'"admit":true'*'"room":'[1-9]*) ;; *)
    WHY="a healthy machine's capacity does not say admit:true with room ≥ 1: $out"; return 1 ;; esac
  case "$out" in *admit_why*) WHY="a healthy machine carries an admit_why: $out"; return 1 ;; esac
  out=$(cap 'echo 4 5 97 0' 'echo 9' FLEET_ADMIT=0)
  case "$out" in *'"admit":true'*) ;; *) WHY="FLEET_ADMIT=0 (the gate off) must say admit:true: $out"; return 1 ;; esac
  case "$out" in *'"room"'*) WHY="with FLEET_ADMIT=0 the beat still carries room — the hub would hold on it: $out"; return 1 ;; esac
  gohalf='hub half: the Go gate (tokenledger.yml) runs judge()'"'"'s tests'
  if [ "${BREAK_GO:-1}" != 0 ] && command -v go >/dev/null 2>&1; then
    out=$(cd "$ROOT/tokenledger" && GOFLAGS=-mod=mod GOPROXY=off GOTOOLCHAIN=local \
          go test -count=1 -run 'TestNodePlace(SkipsPausedNode|AllPausedRefuses|WithoutCapFieldsFiltersNothing)$' ./internal/api 2>&1); rc=$?
    case "$rc:$out" in
      0:*'no tests to run'*) WHY="the hub half's Go tests are not there (go test ran none)"; return 1 ;;
      0:*) gohalf='hub half: go test TestNodePlace{SkipsPausedNode,AllPausedRefuses,WithoutCapFieldsFiltersNothing} ok' ;;
      *GOPROXY=off*|*'module lookup disabled'*|*'cannot find module'*|*'missing go.sum entry'*|*'requires go >= '*)
        gohalf='hub half: no go module cache / toolchain here — the Go gate (tokenledger.yml) runs judge()'"'"'s tests' ;;
      *) WHY="the hub half (go test) is red: $(printf '%s' "$out" | grep -v '^ok' | head -6 | tr '\n' ' ')"; return 1 ;;
    esac
  fi
  SECS=$(since "$t0")
  WHAT="机器暂停接新时心跳带 admit:false（内存紧张 / 负载过高）+ room，健康时 admit:true + room，FLEET_ADMIT=0 不带 room；$gohalf"
}

# ---- burst-lands-on-one (#2077, EPIC #2074 C6): the hub counts the starts it just
# sent and spreads a burst. The whole change is the hub's (judge + the journal), so
# the drill is its Go tests, run for real where a toolchain is: four starts at two
# machines reading the same land two and two; a noted start ages out at 90 s; the
# node's beat showing the sessions clears them once; a reported room is theirs
# first; a refused start is forgotten. Without go the tests must at least exist by
# name, so the row cannot stay green on a deleted test.
drill_burst_lands_on_one() {
  CAP=120; local t0 out rc tests f
  tests='TestPlacementBurstSpreads TestPlacementRecentExpires TestPlacementRecentReflectedByBeat TestPlacementRecentScoredUntilTheBeatShowsIt TestPlacementRecentTakesTheRoom TestPlacementRecentForgottenOnRefusal TestRecentScore'
  f="$ROOT/tokenledger/internal/api/fleet_recent_test.go"
  t0=$(now)
  for out in $tests; do
    grep -q "^func $out(" "$f" 2>/dev/null || { WHY="the hub half's test $out is not in ${f#$ROOT/}"; return 1; }
  done
  grep -q 'recent' "$ROOT/tokenledger/internal/api/fleet_write.go" || { WHY="judge() does not read the recent table"; return 1; }
  if [ "${BREAK_GO:-1}" != 0 ] && command -v go >/dev/null 2>&1; then
    out=$(cd "$ROOT/tokenledger" && GOFLAGS=-mod=mod GOPROXY=off GOTOOLCHAIN=local \
          go test -count=1 -run "^($(printf '%s' "$tests" | tr ' ' '|'))\$" ./internal/api 2>&1); rc=$?
    case "$rc:$out" in
      0:*'no tests to run'*) WHY="the hub half's Go tests are not there (go test ran none)"; return 1 ;;
      0:*) WHAT='入口连续派 4 个 → 两台各 2（go test 七条：分摊、90 秒过期、心跳抵消一次、room 先扣、拒掉即忘）' ;;
      *GOPROXY=off*|*'module lookup disabled'*|*'cannot find module'*|*'missing go.sum entry'*|*'requires go >= '*)
        WHAT='入口的 Go 测试在这台没有模块缓存 / 工具链——Go 门（tokenledger.yml）跑它们；七条测试按名核对在' ;;
      *) WHY="the hub half (go test) is red: $(printf '%s' "$out" | grep -v '^ok' | head -6 | tr '\n' ' ')"; return 1 ;;
    esac
  else
    WHAT='没有 go：七条测试按名核对在，Go 门（tokenledger.yml）跑它们'
  fi
  SECS=$(since "$t0")
}

# ---- dispatch-wrong-replica (#2124, EPIC #2119 C5): with two hub replicas a node's
# link ends in one of them; a write that lands on the other is handed across
# (fleet_node_conns + /internal/v1/node-write). The whole change is the hub's, so
# the drill is its Go tests, run for real where a toolchain is: two replicas × two
# nodes × 100 starts all delivered, a reconnect to the other replica keeps them
# coming, a dead holder is failed (not unknown), the route admits only the
# replicas' token, a single hub never forwards. Without go the tests must at
# least exist by name.
drill_dispatch_wrong_replica() {
  CAP=120; local t0 out rc tests f
  tests='TestNodeRouteTwoReplicas TestNodeRouteHolderGone TestNodeRouteNeedsReplicaToken TestNodeRouteSingleNeverForwards TestParseReplica'
  f="$ROOT/tokenledger/internal/api/node_route_test.go"
  t0=$(now)
  for out in $tests; do
    grep -q "^func $out(" "$f" 2>/dev/null || { WHY="the hub half's test $out is not in ${f#$ROOT/}"; return 1; }
  done
  grep -q 'peerOf' "$ROOT/tokenledger/internal/api/fleet_write.go" || { WHY="the write path does not look for the replica holding the link"; return 1; }
  if [ "${BREAK_GO:-1}" != 0 ] && command -v go >/dev/null 2>&1; then
    out=$(cd "$ROOT/tokenledger" && GOFLAGS=-mod=mod GOPROXY=off GOTOOLCHAIN=local \
          go test -count=1 -run "^($(printf '%s' "$tests" | tr ' ' '|'))\$" ./internal/api 2>&1); rc=$?
    case "$rc:$out" in
      0:*'no tests to run'*) WHY="the hub half's Go tests are not there (go test ran none)"; return 1 ;;
      0:*) WHAT='两份入口 × 两台机器 × 100 次派活全送达，重连到另一份照样送达（go test 五条：转发、持有方不在、令牌、单份不转发、配置）' ;;
      *GOPROXY=off*|*'module lookup disabled'*|*'cannot find module'*|*'missing go.sum entry'*|*'requires go >= '*)
        WHAT='入口的 Go 测试在这台没有模块缓存 / 工具链——Go 门（tokenledger.yml）跑它们；六条测试按名核对在' ;;
      *) WHY="the hub half (go test) is red: $(printf '%s' "$out" | grep -v '^ok' | head -6 | tr '\n' ' ')"; return 1 ;;
    esac
  else
    WHAT='没有 go：六条测试按名核对在，Go 门（tokenledger.yml）跑它们'
  fi
  SECS=$(since "$t0")
}

# ---- two-hubs-double-refresh (#2123, EPIC #2119 C4): two hub replicas on one
# Postgres run every background loop once and refresh an account once. The change
# is the hub's, so the drill is its Go tests where a toolchain is: two vaults on one
# database refresh one account once with CrossLock (and twice without — the
# hazard, shown); a single hub leads everything. The two-process Postgres legs
# (one runner per job for an hour of ticks, handover ≤ 15 s) run in the Go gate's
# tokenledger-pg job. Without go the tests and the loop gates must exist by name.
drill_two_hubs_double_refresh() {
  CAP=120; local t0 out rc f tl
  t0=$(now)
  f="$ROOT/tokenledger/internal/leader/leader_test.go"
  for tl in TestSingleHubAlwaysLeads TestTwoReplicasOneRunner TestCloseHandsOver TestLockAcrossReplicas; do
    grep -q "^func $tl(" "$f" 2>/dev/null || { WHY="the leader test $tl is not in ${f#$ROOT/}"; return 1; }
  done
  grep -q '^func TestTwoReplicasRefreshOnce(' "$ROOT/tokenledger/internal/credvault/credvault_test.go" 2>/dev/null \
    || { WHY="credvault has no TestTwoReplicasRefreshOnce"; return 1; }
  grep -q 'v.CrossLock(' "$ROOT/tokenledger/internal/credvault/credvault.go" || { WHY="Lease takes no cross-replica lock"; return 1; }
  grep -q 'Leader(ctx, "alerts")' "$ROOT/tokenledger/internal/api/fleet_alerts.go" || { WHY="node alerts are not gated on the leader"; return 1; }
  grep -q 'Leader(ctx, "spot")' "$ROOT/tokenledger/internal/api/fleet_spot.go" || { WHY="the SPOT controller is not gated on the leader"; return 1; }
  grep -q 'Leader(ctx, "prune")' "$ROOT/tokenledger/cmd/ccquota/hub.go" || { WHY="the daily prune is not gated on the leader"; return 1; }
  if [ "${BREAK_GO:-1}" != 0 ] && command -v go >/dev/null 2>&1; then
    out=$(cd "$ROOT/tokenledger" && GOFLAGS=-mod=mod GOPROXY=off GOTOOLCHAIN=local \
          go test -count=1 -run '^(TestTwoReplicasRefreshOnce|TestSingleHubAlwaysLeads)$' ./internal/credvault ./internal/leader 2>&1); rc=$?
    case "$rc:$out" in
      0:*'no tests to run'*) WHY="the hub half's Go tests are not there (go test ran none)"; return 1 ;;
      0:*) WHAT='两份保险箱同时租一个账号 → 只刷新一次（无跨副本锁时两次）；单份恒为 leader（go test）；两进程 Postgres 一小时只一份在干、交接 ≤15 s 在 Go 门 tokenledger-pg' ;;
      *GOPROXY=off*|*'module lookup disabled'*|*'cannot find module'*|*'missing go.sum entry'*|*'requires go >= '*)
        WHAT='入口的 Go 测试在这台没有模块缓存 / 工具链——Go 门（tokenledger.yml）跑它们；测试与三处 Leader 门按名核对在' ;;
      *) WHY="the hub half (go test) is red: $(printf '%s' "$out" | grep -v '^ok' | head -6 | tr '\n' ' ')"; return 1 ;;
    esac
  else
    WHAT='没有 go：测试与三处 Leader 门按名核对在，Go 门（tokenledger.yml）跑它们'
  fi
  SECS=$(since "$t0")
}

# ---- github-signin-unreachable (#3392): github.com times out from the hub's
# cluster, so the sign-in's token exchange goes through the Singapore relay's
# /github-oauth/ route with the hub's own pass — through the relay with github.com
# dead; relay down / refusing / hanging ⇒ github.com directly once; both dead ⇒
# the usual page, bounded; only frh1. opens the route, and only its one path. The
# relay's Caddyfile carries that one path, the prod overlay switches it on.
# Without go the tests must exist by name.
drill_github_signin_unreachable() {
  CAP=120; local t0 out rc f tl
  local tests='TestGitHubSignIn_ThroughRelay TestGitHubSignIn_RelayDownFallsBackDirect TestGitHubSignIn_RelayAndGitHubDownIsBounded TestGitHubRelayRouteCheck'
  t0=$(now)
  f="$ROOT/tokenledger/internal/api/github_oauth_relay_test.go"
  for tl in $tests; do
    grep -q "^func $tl(" "$f" 2>/dev/null || { WHY="the hub test $tl is not in ${f#$ROOT/}"; return 1; }
  done
  grep -q '^	handle /github-oauth/login/oauth/access_token {' "$ROOT/extras/cred-relay/Caddyfile" \
    || { WHY="the relay's Caddyfile has no /github-oauth/login/oauth/access_token route"; return 1; }
  grep -q '"/github-oauth/"' "$ROOT/extras/cred-relay/fleet-relay-check.py" \
    || { WHY="the relay's checker does not know the /github-oauth/ prefix"; return 1; }
  grep -A1 'name: CCQUOTA_GITHUB_OAUTH_VIA' "$ROOT/deploy/k8s/overlays/prod/deployment-env.yaml" | grep -q 'value: "relay"' \
    || { WHY="the prod overlay does not set CCQUOTA_GITHUB_OAUTH_VIA=relay"; return 1; }
  WHAT='github.com 不通 ⇒ 换令牌经转发机成功、日志写经中转；转发机连不上 / 拒通行证 / 不答 ⇒ 直连再试一次；两条都不通 ⇒ 原来那句提示、有上限；/github-oauth/ 只开那一条路径、只认 frh1.'
  if [ "${BREAK_GO:-1}" != 0 ] && command -v go >/dev/null 2>&1; then
    out=$(cd "$ROOT/tokenledger" && GOFLAGS=-mod=mod GOPROXY=off GOTOOLCHAIN=local \
          go test -count=1 -run "^($(printf '%s' "$tests" | tr ' ' '|'))\$" ./internal/api 2>&1); rc=$?
    case "$rc:$out" in
      0:*'no tests to run'*) WHY="the hub half's Go tests are not there (go test ran none)"; return 1 ;;
      0:*) WHAT="${WHAT}（go test 四条）" ;;
      *GOPROXY=off*|*'module lookup disabled'*|*'cannot find module'*|*'missing go.sum entry'*|*'requires go >= '*)
        WHAT="${WHAT}；Go 测试这台没有模块缓存 / 工具链——Go 门（tokenledger.yml）跑它们" ;;
      *) WHY="the hub half (go test) is red: $(printf '%s' "$out" | grep -v '^ok' | head -6 | tr '\n' ' ')"; return 1 ;;
    esac
  else
    WHAT="${WHAT}；没有 go：四条测试按名核对在，Go 门（tokenledger.yml）跑它们"
  fi
  SECS=$(since "$t0")
}

# ---- entry-dns-follows (#3073, EPIC #3067 C7): the hub's address-record loop on a
# fake zone — the address moves ⇒ the next tick changes it; the home unreachable ⇒
# nothing changes; a hand edit is put back and said so; a failed call writes nothing
# and is retried; no token ⇒ no call — and the DNSPod provider against a fake
# dnsapi.cn (only marked records under cf, an unmarkable record removed again, the
# token never in a URL or an error). Without go the tests must exist by name.
drill_entry_dns_follows() {
  CAP=120; local t0 out rc tests f tl
  tests='TestEntryDNSFollowsTheHome TestEntryDNSRetriesAFailedWrite TestEntryDNSOffMakesNoCall TestEntryDNSPortIsTheHomes TestDNSPodProvider'
  t0=$(now)
  for tl in TestEntryDNSFollowsTheHome TestEntryDNSRetriesAFailedWrite TestEntryDNSOffMakesNoCall TestEntryDNSPortIsTheHomes; do
    f="$ROOT/tokenledger/internal/api/fleet_entry_dns_test.go"
    grep -q "^func $tl(" "$f" 2>/dev/null || { WHY="the hub test $tl is not in ${f#$ROOT/}"; return 1; }
  done
  f="$ROOT/tokenledger/internal/dns/dnspod_test.go"
  grep -q '^func TestDNSPodProvider(' "$f" 2>/dev/null || { WHY="the provider test is not in ${f#$ROOT/}"; return 1; }
  grep -q 'Leader(ctx, "entry-dns")' "$ROOT/tokenledger/internal/api/fleet_entry_dns.go" \
    || { WHY="the address-record loop is not gated on the leader"; return 1; }
  grep -q 'acme-dnspod' "$ROOT/deploy/k8s/overlays/prod/deployment-env.yaml" \
    || { WHY="the hub's deployment no longer reads the DNSPod token from new-deploy/acme-dnspod"; return 1; }
  WHAT='地址变 ⇒ 下一拍改（同一条记录）；家连不上 ⇒ 一条不改；手动换家 ⇒ 指新家；手改 ⇒ 改回 + 「有人手改」；调用失败 ⇒ 不算写过、下一拍再试；没 token ⇒ 0 次调用；DNSPod 只认带 fleet 备注的 cf 记录，token 不进 URL / 错误；同一路由器后两个家：钥匙页端口 = 家的转发端口，换家说端口要改，别的端口上的 IPv6 不写 AAAA'
  if [ "${BREAK_GO:-1}" != 0 ] && command -v go >/dev/null 2>&1; then
    out=$(cd "$ROOT/tokenledger" && GOFLAGS=-mod=mod GOPROXY=off GOTOOLCHAIN=local \
          go test -count=1 -run "^($(printf '%s' "$tests" | tr ' ' '|'))\$" ./internal/api ./internal/dns 2>&1); rc=$?
    case "$rc:$out" in
      0:*'no tests to run'*) WHY="the hub half's Go tests are not there (go test ran none)"; return 1 ;;
      0:*) WHAT="${WHAT}（go test 五条）" ;;
      *GOPROXY=off*|*'module lookup disabled'*|*'cannot find module'*|*'missing go.sum entry'*|*'requires go >= '*)
        WHAT="${WHAT}；Go 测试这台没有模块缓存 / 工具链——Go 门（tokenledger.yml）跑它们" ;;
      *) WHY="the hub half (go test) is red: $(printf '%s' "$out" | grep -v '^ok' | head -6 | tr '\n' ' ')"; return 1 ;;
    esac
  else
    WHAT="${WHAT}；没有 go：五条测试按名核对在，Go 门（tokenledger.yml）跑它们"
  fi
  SECS=$(since "$t0")
}

# ---- entry-name-unclaimed (#3337): a person homed with no address name, and the
# name they were offered resolving through the zone's wildcard to the hub's own
# address — Termius reached the hub's port, EOF. Now the suggested name is claimed
# with the home (and on the next tick for one homed before), and the loop keeps a
# TXT-only *.cf so an unclaimed name has no address at all. Without go the tests
# must exist by name.
drill_entry_name_unclaimed() {
  CAP=120; local t0 out rc tests='TestEntryAutoNameWithHome TestEntryDNSUnclaimedNameResolvesNowhere'
  local f="$ROOT/tokenledger/internal/api/fleet_entry_autoname_test.go" tl
  t0=$(now)
  for tl in $tests; do
    grep -q "^func $tl(" "$f" 2>/dev/null || { WHY="the hub test $tl is not in ${f#$ROOT/}"; return 1; }
  done
  grep -q 's.entryEnsureNames(now)' "$ROOT/tokenledger/internal/api/fleet_entry_dns.go" \
    || { WHY="the address-record loop no longer claims the names of people homed before #3337"; return 1; }
  grep -q 'entryDNSGuard(sub)' "$ROOT/tokenledger/internal/api/fleet_entry_dns.go" \
    || { WHY="the address-record loop no longer keeps the *.cf guard"; return 1; }
  WHAT='有家没名 ⇒ 设家（自动或手动）时领下建议名、审计一行，老的下一拍补上；名已在不动、建议名被占不强领；运维仍不能替人起任意名；没领的名不在计划里，*.cf 只有一条 TXT、没有 A/AAAA，被手删下一拍补回'
  if [ "${BREAK_GO:-1}" != 0 ] && command -v go >/dev/null 2>&1; then
    out=$(cd "$ROOT/tokenledger" && GOFLAGS=-mod=mod GOPROXY=off GOTOOLCHAIN=local \
          go test -count=1 -run "^($(printf '%s' "$tests" | tr ' ' '|'))\$" ./internal/api 2>&1); rc=$?
    case "$rc:$out" in
      0:*'no tests to run'*) WHY="the hub half's Go tests are not there (go test ran none)"; return 1 ;;
      0:*) WHAT="${WHAT}（go test 两条）" ;;
      *GOPROXY=off*|*'module lookup disabled'*|*'cannot find module'*|*'missing go.sum entry'*|*'requires go >= '*)
        WHAT="${WHAT}；Go 测试这台没有模块缓存 / 工具链——Go 门（tokenledger.yml）跑它们" ;;
      *) WHY="the hub half (go test) is red: $(printf '%s' "$out" | grep -v '^ok' | head -6 | tr '\n' ' ')"; return 1 ;;
    esac
  else
    WHAT="${WHAT}；没有 go：两条测试按名核对在，Go 门（tokenledger.yml）跑它们"
  fi
  SECS=$(since "$t0")
}

# ---- invite-expired (#2261, EPIC #2259 C2): a newcomer signs in with an invite
# that cannot be used — expired, used, revoked, someone else's, never minted. The
# whole change is the hub's, so the drill is its Go tests, run for real where a
# toolchain is: each bad code is refused with its own reason and puts nobody on
# the list; a good one lets the person in once and audits 「邀请已使用」; no code
# is the list as before, saying the line to send an admin; the waiting
# `fleet login` hears the refusal instead of waiting ten minutes. Without go the
# tests must at least exist by name.
drill_invite_expired() {
  CAP=120; local t0 out rc tests f
  tests='TestInviteRefusals TestInviteLetsANewcomerIn TestInviteNoCodeIsTheListAsBefore TestInviteRefusalReachesTheTerminal TestInviteOpensTheLoginWithAutoAssignOff'
  f="$ROOT/tokenledger/internal/api/fleet_invites_test.go"
  t0=$(now)
  for out in $tests; do
    grep -q "^func $out(" "$f" 2>/dev/null || { WHY="the hub half's test $out is not in ${f#$ROOT/}"; return 1; }
  done
  grep -q 'denyInvitePrefix + reason' "$ROOT/tokenledger/internal/api/fleet_invites.go" \
    || { WHY="admitInvite no longer refuses a bad invite with its reason"; return 1; }
  if [ "${BREAK_GO:-1}" != 0 ] && command -v go >/dev/null 2>&1; then
    out=$(cd "$ROOT/tokenledger" && GOFLAGS=-mod=mod GOPROXY=off GOTOOLCHAIN=local \
          go test -count=1 -run "^($(printf '%s' "$tests" | tr ' ' '|'))\$" ./internal/api 2>&1); rc=$?
    case "$rc:$out" in
      0:*'no tests to run'*) WHY="the hub half's Go tests are not there (go test ran none)"; return 1 ;;
      0:*) WHAT='过期 / 已用 / 撤销 / 别人的 / 没发过的码各被拒且说清原因、名单不变；好码进名单一次、审计「邀请已使用」；终端立刻听到拒绝（go test 五条）' ;;
      *GOPROXY=off*|*'module lookup disabled'*|*'cannot find module'*|*'missing go.sum entry'*|*'requires go >= '*)
        WHAT='入口的 Go 测试在这台没有模块缓存 / 工具链——Go 门（tokenledger.yml）跑它们；六条测试按名核对在' ;;
      *) WHY="the hub half (go test) is red: $(printf '%s' "$out" | grep -v '^ok' | head -6 | tr '\n' ' ')"; return 1 ;;
    esac
  else
    WHAT='没有 go：六条测试按名核对在，Go 门（tokenledger.yml）跑它们'
  fi
  SECS=$(since "$t0")
}

# ---- drill-person-no-machine (#2549): a drill person (`fleet drill invite
# --host <m>`) confirms its scan — its own computer is a bare client login, so
# before it got 「No fleet on any of your machines」. It must be opened a login
# on another machine (the doors say 「正在开」), and its self-delete / expiry
# must remove that login before the person goes.
drill_drill_person_no_machine() {
  CAP=120; local t0 out rc tests f
  tests='TestDrillFirstSessionGetsAMachine TestDrillGoesOnlyAfterItsLoginIsRemoved TestDrillOnlyItsOwnMachineAnswersAsBefore'
  f="$ROOT/tokenledger/internal/api/fleet_drill_test.go"
  t0=$(now)
  for out in $tests; do
    grep -q "^func $out(" "$f" 2>/dev/null || { WHY="the hub half's test $out is not in ${f#$ROOT/}"; return 1; }
  done
  grep -q 'return drill.OwnComputer(a)' "$ROOT/tokenledger/internal/api/fleet_opening.go" \
    || { WHY="accountStateOf no longer sets a drill's own computer apart"; return 1; }
  grep -q 'closeDrillLogins(d, now)' "$ROOT/tokenledger/internal/api/fleet_drill.go" \
    || { WHY="DELETE /v1/self no longer removes the login opened for the drill first"; return 1; }
  if [ "${BREAK_GO:-1}" != 0 ] && command -v go >/dev/null 2>&1; then
    out=$(cd "$ROOT/tokenledger" && GOFLAGS=-mod=mod GOPROXY=off GOTOOLCHAIN=local \
          go test -count=1 -run "^($(printf '%s' "$tests" | tr ' ' '|'))\$" ./internal/api 2>&1); rc=$?
    case "$rc:$out" in
      0:*'no tests to run'*) WHY="the hub half's Go tests are not there (go test ran none)"; return 1 ;;
      0:*) WHAT='演练身份扫码即在另一台最闲的机器开登录、入口说「正在开」、开好后不再开第二个；删自己 / 到期先收掉那个登录（202 removing），收到已移除才删人；没有别的机器时答案照旧（go test 三条）' ;;
      *GOPROXY=off*|*'module lookup disabled'*|*'cannot find module'*|*'missing go.sum entry'*|*'requires go >= '*)
        WHAT='入口的 Go 测试在这台没有模块缓存 / 工具链——Go 门（tokenledger.yml）跑它们；三条测试按名核对在' ;;
      *) WHY="the hub half (go test) is red: $(printf '%s' "$out" | grep -v '^ok' | head -6 | tr '\n' ' ')"; return 1 ;;
    esac
  else
    WHAT='没有 go：三条测试按名核对在，Go 门（tokenledger.yml）跑它们'
  fi
  SECS=$(since "$t0")
}

# ---- opened-login-no-fleet (#2652): a login the hub opened for a person (a
# drill, an invited newcomer, a spare) went active with no node and no fleet —
# nobody ever logs in to it, and the hub sees a login's fleet only through that
# login's own agent — so the person's first session found 「No fleet on any of
# your machines」; and a drill's teardown archived the whole home first. The
# create now carries a one-time join code (env, never argv) that
# fleet-login-new.sh spends to join the login as its own node and bring its
# fleet up; a drill's remove drops the home.
drill_opened_login_no_fleet() {
  CAP=120; local t0 out rc s="$ROOT/bin/fleet-login-new.sh"
  local api='TestDrillGoesOnlyAfterItsLoginIsRemoved' agent='TestAdminAgentHandsJoinCodeInEnv|TestAdminAgentDropHomeDeletesHome'
  t0=$(now)
  grep -q 'op.JoinCode = s.loginJoinCode(a' "$ROOT/tokenledger/internal/api/fleet_accounts.go" \
    || { WHY="the hub's create op no longer carries the login's join code"; return 1; }
  grep -q 'op.DropHome = true' "$ROOT/tokenledger/internal/api/fleet_accounts.go" \
    || { WHY="a drill's remove no longer drops the home"; return 1; }
  grep -q '"FLEET_LOGIN_JOIN_CODE="' "$ROOT/tokenledger/internal/agent/node_accounts.go" \
    || { WHY="the admin agent no longer hands the join code to fleet-login-new.sh in its environment"; return 1; }
  grep -q '^  node_join_step$' "$s" && grep -q 'fleet_up_step$' "$s" \
    || { WHY="fleet-login-new.sh no longer joins an opened login / brings its fleet up"; return 1; }
  if [ "${BREAK_GO:-1}" != 0 ] && command -v go >/dev/null 2>&1; then
    out=$(cd "$ROOT/tokenledger" && GOFLAGS=-mod=mod GOPROXY=off GOTOOLCHAIN=local \
          go test -count=1 -run "^($api)\$" ./internal/api 2>&1 \
          && GOFLAGS=-mod=mod GOPROXY=off GOTOOLCHAIN=local go test -count=1 -run "^($agent)\$" ./internal/agent 2>&1); rc=$?
    case "$rc:$out" in
      0:*'no tests to run'*) WHY="the Go half's tests are not there (go test ran none)"; return 1 ;;
      0:*) WHAT='入口开号带一次性加入码、管理节点只经环境交给 fleet-login-new.sh；演练身份收号 --delete-home（go test 三条；脚本一半是 fleet-login-new-selftest O）' ;;
      *GOPROXY=off*|*'module lookup disabled'*|*'cannot find module'*|*'missing go.sum entry'*|*'requires go >= '*)
        WHAT='Go 测试在这台没有模块缓存 / 工具链——Go 门（tokenledger.yml）跑它们；脚本一半是 fleet-login-new-selftest O' ;;
      *) WHY="the Go half is red: $(printf '%s' "$out" | grep -v '^ok' | head -6 | tr '\n' ' ')"; return 1 ;;
    esac
  else
    WHAT='没有 go：标记按名核对在，Go 门（tokenledger.yml）跑三条测试；脚本一半是 fleet-login-new-selftest O'
  fi
  SECS=$(since "$t0")
}

# ---- spare-login-empty (#2263, EPIC #2259 C4): a newcomer signs in while no
# spare login is ready (all taken, still being made, or one failed). Only an
# active spare is ever handed over; otherwise the person's own login is opened
# as before and every door says 「正在开」 with its ETA; the taken one is
# refilled, a spare not credential-separated is never handed out, and a
# failed spare is not retried on every beat.
drill_spare_login_empty() {
  CAP=120; local t0 out rc tests f
  tests='TestSpareEmptyFallsBackToOpening TestSpareHandedToANewcomerAndRefilled TestSpareUnseparatedIsNeverHandedOut TestSpareCountFollowsTheMachinesRoom TestSpareIsInNoPeopleView TestSpareOffAddsNothing'
  f="$ROOT/tokenledger/internal/api/fleet_spare_test.go"
  t0=$(now)
  for out in $tests; do
    grep -q "^func $out(" "$f" 2>/dev/null || { WHY="the hub half's test $out is not in ${f#$ROOT/}"; return 1; }
  done
  grep -q 'state = ? AND op = .create.' "$ROOT/tokenledger/internal/store/fleet_spare.go" \
    || { WHY="ClaimSpare no longer takes only a ready (active) spare"; return 1; }
  if [ "${BREAK_GO:-1}" != 0 ] && command -v go >/dev/null 2>&1; then
    out=$(cd "$ROOT/tokenledger" && GOFLAGS=-mod=mod GOPROXY=off GOTOOLCHAIN=local \
          go test -count=1 -run "^($(printf '%s' "$tests" | tr ' ' '|'))\$" ./internal/api 2>&1); rc=$?
    case "$rc:$out" in
      0:*'no tests to run'*) WHY="the hub half's Go tests are not there (go test ran none)"; return 1 ;;
      0:*) WHAT='没有现成备用时照旧现开、入口说「正在开」带 ETA；有隔离好的备用时 3 秒内拿到、用掉即补；没隔离的不发不补；按上限−已用备足、多了就缩；备用不进人员视图；关着时一字不变（go test 六条）' ;;
      *GOPROXY=off*|*'module lookup disabled'*|*'cannot find module'*|*'missing go.sum entry'*|*'requires go >= '*)
        WHAT='入口的 Go 测试在这台没有模块缓存 / 工具链——Go 门（tokenledger.yml）跑它们；六条测试按名核对在' ;;
      *) WHY="the hub half (go test) is red: $(printf '%s' "$out" | grep -v '^ok' | head -6 | tr '\n' ' ')"; return 1 ;;
    esac
  else
    WHAT='没有 go：六条测试按名核对在，Go 门（tokenledger.yml）跑它们'
  fi
  SECS=$(since "$t0")
}

# ---- lease-unseparated-user (#2295, EPIC #2293 C2): a user's login whose
# credential separation did not happen (or an agent too old to say) must not be
# leased a real token — the hub refuses 「拒发：未隔离」 and tells the node's
# proxy to route every session central, so they still work. Admin / operator
# logins lease as before.
drill_lease_unseparated_user() {
  CAP=120; local t0 out rc api agent fa fg
  api='TestLeaseCredsepGate TestLeaseCredsepGateOnlyForUsers TestNodeSelfCarriesCredsepGate'
  agent='TestCredsepJudge TestCredsepProbeCaches'
  fa="$ROOT/tokenledger/internal/api/fleet_credsep_test.go"
  fg="$ROOT/tokenledger/internal/agent/node_credsep_test.go"
  t0=$(now)
  for out in $api; do
    grep -q "^func $out(" "$fa" 2>/dev/null || { WHY="the hub half's test $out is not in ${fa#$ROOT/}"; return 1; }
  done
  for out in $agent; do
    grep -q "^func $out(" "$fg" 2>/dev/null || { WHY="the node half's test $out is not in ${fg#$ROOT/}"; return 1; }
  done
  grep -q 'credsep_gate' "$BIN/fleet-cred-proxy.py" \
    || { WHY="fleet-cred-proxy.py no longer routes a credsep-gated login central"; return 1; }
  if [ "${BREAK_GO:-1}" != 0 ] && command -v go >/dev/null 2>&1; then
    out=$(cd "$ROOT/tokenledger" && GOFLAGS=-mod=mod GOPROXY=off GOTOOLCHAIN=local \
          go test -count=1 -run "^($(printf '%s %s' "$api" "$agent" | tr ' ' '|'))\$" ./internal/api ./internal/agent 2>&1); rc=$?
    case "$rc:$out" in
      0:*'no tests to run'*) WHY="the Go tests are not there (go test ran none)"; return 1 ;;
      0:*) WHAT='普通用户未隔离 / 不报字段 → 403「拒发：未隔离」、/self 带 credsep_gate（代理走 central）；隔离后 200；管理员与非 GitHub 用户不受影响；节点按 status+check 判定并 5 分钟缓存（go test 五条）' ;;
      *GOPROXY=off*|*'module lookup disabled'*|*'cannot find module'*|*'missing go.sum entry'*|*'requires go >= '*)
        WHAT='入口的 Go 测试在这台没有模块缓存 / 工具链——Go 门（tokenledger.yml）跑它们；七条测试按名核对在' ;;
      *) WHY="the Go half is red: $(printf '%s' "$out" | grep -v '^ok' | head -6 | tr '\n' ' ')"; return 1 ;;
    esac
  else
    WHAT='没有 go：七条测试按名核对在，Go 门（tokenledger.yml）跑它们'
  fi
  SECS=$(since "$t0")
}

# ---- trust-name-borrowed (#2214, EPIC #2329 C2; #3300): an untrusted node
# reports a trusted machine's hostname. Trust is the machine's, and the machine
# is the one the endpoint ENROLLED as (a login the hub opened: the code's
# machine), so the impostor's lease and relay credential are refused and its
# hello is audited; a managed join code trusts its machine, once, for an hour;
# a login opened on a trusted machine holds that trust.
drill_trust_name_borrowed() {
  CAP=120; local t0 out rc tests f
  tests='TestTrustBorrowedNameGetsNothing TestTrustIsTheEnrolledMachines TestManagedJoinCodeTrustsTheMachine TestOpenedLoginHoldsItsMachinesTrust TestTrustMigratesOntoMachines TestDesiredStateOperatorWrites TestDesiredAbsentAddsNothing'
  f="$ROOT/tokenledger/internal/api/fleet_node_identity_test.go"
  t0=$(now)
  for out in $tests; do
    grep -q "^func $out(" "$f" 2>/dev/null || { WHY="the hub half's test $out is not in ${f#$ROOT/}"; return 1; }
  done
  grep -q 'machine := enrolledMachine(et)' "$ROOT/tokenledger/internal/api/fleet_trust.go" \
    || { WHY="nodeTrust no longer judges the machine the endpoint enrolled as"; return 1; }
  if [ "${BREAK_GO:-1}" != 0 ] && command -v go >/dev/null 2>&1; then
    out=$(cd "$ROOT/tokenledger" && GOFLAGS=-mod=mod GOPROXY=off GOTOOLCHAIN=local \
          go test -count=1 -run "^($(printf '%s' "$tests" | tr ' ' '|'))\$" ./internal/api 2>&1); rc=$?
    case "$rc:$out" in
      0:*'no tests to run'*) WHY="the hub half's Go tests are not there (go test ran none)"; return 1 ;;
      0:*) WHAT='冒名节点领凭据 / 中继凭据被拒、名册读 name_borrowed、hello 记审计；真机照领；信任在机器上：托管加入码一次、一小时、写机器；入口开的登录随机器；旧的按登录信任迁到机器；期望状态只有操作者能写（go test 七条）' ;;
      *GOPROXY=off*|*'module lookup disabled'*|*'cannot find module'*|*'missing go.sum entry'*|*'requires go >= '*)
        WHAT='入口的 Go 测试在这台没有模块缓存 / 工具链——Go 门（tokenledger.yml）跑它们；七条测试按名核对在' ;;
      *) WHY="the hub half (go test) is red: $(printf '%s' "$out" | grep -v '^ok' | head -6 | tr '\n' ' ')"; return 1 ;;
    esac
  else
    WHAT='没有 go：七条测试按名核对在，Go 门（tokenledger.yml）跑它们'
  fi
  SECS=$(since "$t0")
}

# ---- quota-refused-blind (#2465, EPIC #2463 C8): the hub answers the quota read
# 401 (a certificate / token it no longer takes). Before: every fetch overwrote
# the cache with nothing, the pick had no opinion for six hours and never rotated,
# and every dial stayed green. Now the last reading is carried (≤ FLEET_QUOTA_STALE_OK)
# with the 401 named — done for real against a fake ccquota in a sandbox.
drill_quota_refused_blind() {
  CAP=20; local t0 d s n
  d="$WORK/qrb"; mkdir -p "$d/p" "$d/acc" "$d/conf" "$d/.claude-dash/global"
  printf 't\n' > "$d/acc/a"; chmod 600 "$d/acc/a"
  cat > "$d/p/ccquota" <<'FAKE'
#!/bin/bash
if [ -f "$QRB_DIR/refuse" ]; then
  printf '{"verdict":"unknown","reason":"hub unreachable: HTTP 401: unauthorized","accounts":null}\n'
else
  printf '{"verdict":"go","accounts":[{"account_uuid":"u-a","label":"a","headroom_pct":70,"five_hour":{"utilization":30},"seven_day":{"utilization":10}}]}\n'
fi
FAKE
  chmod +x "$d/p/ccquota"
  qrb() { env PATH="$d/p:$PATH" TMPDIR="$d" HOME="$d" FLEET_SKIP_GLOBAL_CONF=1 FLEET_CONF_DIR="$d/conf" \
            FLEET_ACCOUNTS_DIR="$d/acc" CCQUOTA_HUB_URL=http://hub.test QRB_DIR="$d" "$@"; }
  t0=$(now)
  qrb bash "$BIN/fleet-account.sh" quota --refresh >/dev/null 2>&1
  : > "$d/refuse"
  for n in 1 2 3 4; do qrb bash "$BIN/fleet-account.sh" quota --refresh >/dev/null 2>&1; done
  n=$(qrb bash "$BIN/fleet-account.sh" quota --cached 2>/dev/null | grep -c .)
  [ "$n" = 1 ] || { WHY="four 401 reads wiped the quota cache ($n rows) — the pick is blind"; return 1; }
  s=$(qrb bash "$BIN/fleet-quotawatch.sh" --status 2>/dev/null)
  case "$s" in carry*refused*) ;; *) WHY="--status does not say the reading is carried over a 401: $s"; return 1 ;; esac
  WHAT='入口答 401 四次：额度读数沿用、挑号照常给分；--status 答 carry · refused（30 分钟后才清空并报警）'
  SECS=$(since "$t0")
}

# ---- release-tampered (#2335, EPIC #2329 C7): a machine takes a release from
# the hub only, and a tampered byte anywhere — a tree file, an artifact, the
# manifest, the signature, a different key — installs nothing; GitHub out of
# reach (and a restarted hub) still hands out what it stored. The hub half is
# Go; this drill pins its tests by name and runs them when go is here.
drill_release_tampered() {
  CAP=120; local t0 out rc tests f
  tests='TestReleaseBuiltOnStableAndFetched TestReleaseFetchWithGitHubDown TestReleaseTamperRefused TestReleaseVerifyDirCatchesEdit TestReleaseOffIs404'
  f="$ROOT/tokenledger/internal/api/fleet_release_test.go"
  t0=$(now)
  for out in $tests; do
    grep -q "^func $out(" "$f" 2>/dev/null || { WHY="the hub half's test $out is not in ${f#$ROOT/}"; return 1; }
  done
  grep -q 'digest does not match the manifest' "$ROOT/tokenledger/internal/release/release.go" \
    || { WHY="Unpack no longer checks each file against the signed manifest"; return 1; }
  if [ "${BREAK_GO:-1}" != 0 ] && command -v go >/dev/null 2>&1; then
    out=$(cd "$ROOT/tokenledger" && GOFLAGS=-mod=mod GOPROXY=off GOTOOLCHAIN=local \
          go test -count=1 -run "^($(printf '%s' "$tests" | tr ' ' '|'))\$" ./internal/api 2>&1); rc=$?
    case "$rc:$out" in
      0:*'no tests to run'*) WHY="the hub half's Go tests are not there (go test ran none)"; return 1 ;;
      0:*) WHAT='stable 一动入口就打包签名；机器从入口取到全部文件与二进制；GitHub 断了、入口重启也照样取；树 / 二进制 / 清单 / 签名 / 钥匙任一处被改都整个不换、不留半成品（go test 五条）' ;;
      *GOPROXY=off*|*'module lookup disabled'*|*'cannot find module'*|*'missing go.sum entry'*|*'requires go >= '*)
        WHAT='入口的 Go 测试在这台没有模块缓存 / 工具链——Go 门（tokenledger.yml）跑它们；七条测试按名核对在' ;;
      *) WHY="the hub half (go test) is red: $(printf '%s' "$out" | grep -v '^ok' | head -6 | tr '\n' ' ')"; return 1 ;;
    esac
  else
    WHAT='没有 go：七条测试按名核对在，Go 门（tokenledger.yml）跑它们'
  fi
  SECS=$(since "$t0")
}

# ---- machine-agent-wrong-login (#2333, EPIC #2329 C5): the machine's one node
# program speaks for every login over one link; a login hello proven with the
# wrong token, or a message for a login the link does not carry, must be
# refused on both halves — never run as the wrong login, never as root.
drill_machine_agent_wrong_login() {
  CAP=180; local t0 out rc api agt f g
  api='TestMachineLinkRefusesWrongLogin TestMachineLinkCarriesEveryLogin TestMachineLinkSessionLandsOnItsLogin TestMachineLinkAccountCreateGoesToTheAdminLogin TestMachineLinkMoveLandsOnItsLogin TestMachineLinkAndPlainAgents TestMachineAgentRunsEachLoginAsItself'
  agt='TestMachineLinkDemuxByLogin TestPrepCmdRunsAsTheLogin TestPrepCmdStrictOnlyForARootMachine'
  f="$ROOT/tokenledger/internal/api/node_machine_test.go"
  g="$ROOT/tokenledger/internal/agent/node_machine_test.go"
  t0=$(now)
  for out in $api; do
    grep -q "^func $out(" "$f" 2>/dev/null || { WHY="the hub half's test $out is not in ${f#$ROOT/}"; return 1; }
  done
  for out in $agt; do
    grep -q "^func $out(" "$g" 2>/dev/null || { WHY="the node half's test $out is not in ${g#$ROOT/}"; return 1; }
  done
  grep -q 'ep.OSUser != login' "$ROOT/tokenledger/internal/api/node_machine.go" \
    || { WHY="loginEndpoint no longer holds a login hello to its own token's login"; return 1; }
  grep -q 'CodeWrongLogin' "$ROOT/tokenledger/internal/agent/node_machine.go" \
    || { WHY="the node's demux no longer refuses a login it does not serve"; return 1; }
  if [ "${BREAK_GO:-1}" != 0 ] && command -v go >/dev/null 2>&1; then
    out=$(cd "$ROOT/tokenledger" && GOFLAGS=-mod=mod GOPROXY=off GOTOOLCHAIN=local \
          go test -count=1 -run "^($(printf '%s %s' "$api" "$agt" | tr ' ' '|'))\$" ./internal/api ./internal/agent 2>&1); rc=$?
    case "$rc:$out" in
      0:*'no tests to run'*) WHY="the Go tests are not there (go test ran none)"; return 1 ;;
      0:*) WHAT='整机连接上账号 hello 拿别人的 / 机器的 / 别的机器的令牌都答 WRONG_LOGIN、不上线、记审计；不认识的账号两端都拒；会话、开号、迁移各落在自己的账号；真的 RunMachine 以各账号身份跑控制器（go test 十条）' ;;
      *GOPROXY=off*|*'module lookup disabled'*|*'cannot find module'*|*'missing go.sum entry'*|*'requires go >= '*)
        WHAT='入口的 Go 测试在这台没有模块缓存 / 工具链——Go 门（tokenledger.yml）跑它们；十条测试按名核对在' ;;
      *) WHY="the machine link (go test) is red: $(printf '%s' "$out" | grep -v '^ok' | head -6 | tr '\n' ' ')"; return 1 ;;
    esac
  else
    WHAT='没有 go：十条测试按名核对在，Go 门（tokenledger.yml）跑它们'
  fi
  SECS=$(since "$t0")
}

# A fleet whose tmux server is gone — an old login's per-repo fleet still
# reported to the hub (2026-10-08 m5, fleet-24haowan-monorepo) — took a home
# start, answered UNKNOWN and never tried the next candidate (issue #2477).
drill_place_server_down() {
  CAP=120; local t0 lbl out rc gohalf
  t0=$(now)
  lbl="bk2477-$$"
  # node half: no server on the label ⇒ the helper says so, rc 0; a server
  # without the fleet's session ⇒ says that; the fleet's session there ⇒ rc 1
  out=$(bash -c '. "$1/fleet-lib.sh"; fleet_server_down "$2"' _ "$BIN" "$lbl"); rc=$?
  [ "$rc" = 0 ] && [ "$out" = "fleet $lbl has no running tmux server" ] \
    || { WHY="fleet_server_down missed a fleet with no server (rc=$rc): $out"; return 1; }
  tmux -L "$lbl" -f /dev/null new-session -d -s "$lbl" 2>/dev/null
  out=$(bash -c '. "$1/fleet-lib.sh"; fleet_server_down "$2"' _ "$BIN" "$lbl"); rc=$?
  tmux -L "$lbl" kill-server 2>/dev/null
  [ "$rc" = 1 ] && [ -z "$out" ] || { WHY="fleet_server_down called a live fleet down (rc=$rc): $out"; return 1; }
  # the adapter's start asks before any spawn and exits 8; the controller files 8 as not attempted
  grep -q 'fleet_server_down "$sess"' "$BIN/fleet-control-read.sh" \
    || { WHY="fleet-control-read.sh start no longer asks fleet_server_down before a spawn"; return 1; }
  grep -q '8: "UNAVAILABLE"' "$BIN/fleet_control.py" \
    || { WHY="fleet_control.py no longer files exit 8 as UNAVAILABLE (not attempted)"; return 1; }
  gohalf='hub half: the Go gate (tokenledger.yml) runs the down-fleet tests'
  if [ "${BREAK_GO:-1}" != 0 ] && command -v go >/dev/null 2>&1; then
    out=$(cd "$ROOT/tokenledger" && GOFLAGS=-mod=mod GOPROXY=off GOTOOLCHAIN=local \
          go test -count=1 -run 'TestPlacement(SkipsDownFleet|SameLoginPrefersLiveFleet)$|TestClientPlaceServerDownTriesNextMachine$' ./internal/api 2>&1); rc=$?
    case "$rc:$out" in
      0:*'no tests to run'*) WHY="the hub half's Go tests are not there (go test ran none)"; return 1 ;;
      0:*) gohalf='hub half: go test 不选 down / 同登录选活的 / 退 8 换下一台 ok' ;;
      *GOPROXY=off*|*'module lookup disabled'*|*'cannot find module'*|*'missing go.sum entry'*|*'requires go >= '*)
        gohalf='hub half: no go module cache / toolchain here — the Go gate (tokenledger.yml) runs the down-fleet tests' ;;
      *) WHY="the hub half (go test) is red: $(printf '%s' "$out" | grep -v '^ok' | head -6 | tr '\n' ' ')"; return 1 ;;
    esac
  fi
  SECS=$(since "$t0")
  WHAT="服务不在的 fleet：节点 start 先问、退 8（没试过）；入口不选 down 的 fleet；$gohalf"
}

# A file dropped into the writing area on one computer, the session opened on
# another (2026-10-07 #2392: a MacBook screenshot, the session on mini2): the
# issue named the MacBook's path, the worker could not read it (issue #2393).
drill_attach_cross_machine() {
  CAP=120; local t0 d="$WORK/attach" out rc gohalf
  mkdir -p "$d/conf/attachments/$(printf 'a%.0s' $(seq 32))" "$d/qb"
  t0=$(now)
  # client half: compose hands the file itself to the place script (--attach)
  for f in "$BIN"/*; do ln -sf "$f" "$d/qb/"; done
  rm -f "$d/qb/fleet-client-place.sh"
  printf '#!/bin/sh\nprintf "%%s\\n" "$*"\n' > "$d/qb/fleet-client-place.sh"; chmod +x "$d/qb/fleet-client-place.sh"
  printf 'PNG' > "$d/shot.png"
  printf '{"title":"看图","body":"看图 %s","repo":"acme/web","attachments":["%s"]}\n' "$d/shot.png" "$d/shot.png" > "$d/q.json"
  out=$(FLEET_SWITCH_STATE="$d" FLEET_COMPOSE_LOG="$d/q.ndjson" python3 "$d/qb/fleet-compose.py" --send "$d/q.json" 2>&1)
  case "$out" in *"--attach $d/shot.png"*) ;; *) WHY="compose sends only the path, not the file: $out"; return 1 ;; esac
  grep -q 'req\["attachments"\]' "$BIN/fleet-client-place.sh" \
    || { WHY="fleet-client-place.sh does not send the attachments' bytes to the hub"; return 1; }
  # node half: claude-fleet names where the agent lands them (CapAttach) …
  out=$(FLEET_CONF_DIR="$d/conf" bash "$BIN/fleet-hub-node.sh" paths 2>/dev/null)
  case "$out" in *"attach	$d/conf/attachments"*) ;; *) WHY="fleet-hub-node.sh paths names no attachment directory: $out"; return 1 ;; esac
  # … and the start's text names THIS machine's path where the client's stood
  printf 'PNG' > "$d/conf/attachments/$(printf 'a%.0s' $(seq 32))/shot.png"
  out=$(cd "$BIN" && python3 -c '
import sys, fleet_control
c = fleet_control.Control.__new__(fleet_control.Control); c.conf_dir = __import__("pathlib").Path(sys.argv[1])
print(c.attached_body({"body": "看图 /Users/me/shot.png", "attachments": [{"id": "a" * 32, "name": "shot.png",
      "sha256": "0" * 64, "size": 3, "from": "/Users/me/shot.png"}]}))' "$d/conf" 2>&1)
  [ "$out" = "看图 $d/conf/attachments/$(printf 'a%.0s' $(seq 32))/shot.png" ] \
    || { WHY="the node's start text does not name the landed file: $out"; return 1; }
  gohalf='hub half: the Go gate (tokenledger.yml) runs the attachment tests'
  if [ "${BREAK_GO:-1}" != 0 ] && command -v go >/dev/null 2>&1; then
    out=$(cd "$ROOT/tokenledger" && GOFLAGS=-mod=mod GOPROXY=off GOTOOLCHAIN=local \
          go test -count=1 -run 'TestClientPlace(CarriesAttachments|AttachmentsToAnOlderNode)$|TestFetchAttachments$' ./internal/api ./internal/agent 2>&1); rc=$?
    case "$rc:$out" in
      0:*'no tests to run'*) WHY="the hub half's Go tests are not there (go test ran none)"; return 1 ;;
      0:*) gohalf='hub half: go test 入口转交 / 旧节点照说 / 节点下载校验 ok' ;;
      *GOPROXY=off*|*'module lookup disabled'*|*'cannot find module'*|*'missing go.sum entry'*|*'requires go >= '*)
        gohalf='hub half: no go module cache / toolchain here — the Go gate (tokenledger.yml) runs the attachment tests' ;;
      *) WHY="the hub half (go test) is red: $(printf '%s' "$out" | grep -v '^ok' | head -6 | tr '\n' ' ')"; return 1 ;;
    esac
  fi
  SECS=$(since "$t0")
  WHAT="附件随任务到会话机器：写作区交 --attach，节点名下 attachments/<id>/<名>，正文写那台的路径；$gohalf"
}

# The warm pool locks the machine (issue #2502): every ensure tick was admitted,
# its spawn opened nothing, and its reservation stayed the full settle time — so
# three slots kept "room for 0" on a machine half free. For real, on a sandbox
# state dir with stubbed readings (16000 MB, 50 % free, ~1200 MB a session ⇒ room
# for 4): five failed pool ticks (admitted, then gone without a window) and a
# real spawn must still be admitted with its full room; a spawn that IS running
# counts and the doctor's holders line names it; one that confirmed its window
# keeps its reservation after it exits.
drill_pool_admit_phantoms() {
  CAP=60; local t0 d="$WORK/pa" out sp
  mkdir -p "$d/tmp"
  adm() { env FLEET_ADMIT=1 TMPDIR="$d/tmp" HOME="$d" FLEET_MEM_TOTAL_MB=16000 \
            FLEET_MEM_PS_CMD="printf '101 1 $(id -u) 409600 01:00 claude\n'" \
            FLEET_MEM_PROBE_CMD='echo 1 50 0 0' FLEET_LOAD_PROBE_CMD='echo 0.5' \
            FLEET_GLOBAL_MAX_SESSIONS=0 FLEET_MAX_SESSIONS=0 FLEET_MACHINE_MAX_SESSIONS=0 \
            bash -c "source '$BIN/fleet-lib.sh'; $1" 2>&1; }
  t0=$(now)
  for _ in 1 2 3 4 5; do adm 'fleet_session_cap_ok fleet >/dev/null' >/dev/null; done
  out=$(adm 'fleet_admit_reserved; fleet_machine_headroom')
  case "$out" in 0$'\n'4\ *) ;; *) WHY="five failed pool ticks left phantoms (reserved; headroom): $out"; return 1 ;; esac
  sleep 30 & sp=$!
  : > "$d/tmp/.claude-dash/global/admit-reserve/fleet.$sp.1"
  out=$(adm 'fleet_admit_reserved; fleet_admit_holders')
  kill "$sp" 2>/dev/null; wait "$sp" 2>/dev/null
  case "$out" in 1*"pid $sp sleep 30"*) ;; *) WHY="a running spawn's reservation must count and be named: $out"; return 1 ;; esac
  adm 'fleet_session_cap_ok fleet >/dev/null && fleet_admit_confirm >/dev/null' >/dev/null
  out=$(adm 'fleet_admit_reserved')
  [ "$out" = 1 ] || { WHY="a confirmed window's reservation must outlive its spawner (got $out)"; return 1; }
  SECS=$(since "$t0")
  WHAT="5 拍失败的预热不留预留、真放置照样有 4 个位置；在跑的 spawn 计入并列出 pid+命令；开出窗口的确认后独立计入"
}

# guide-admission-room (issue #3472): a newcomer's FIRST window — the onboarding
# guide — refused three times by the room estimate on mini2 (pressure normal, 28 %
# free, floor 15 %, «room for 0 more at ~960 MB»), and the stop sat in a file.
# For real on a sandbox state dir with stubbed readings (16000 MB, 18 % free,
# ~1200 MB a session ⇒ room 0, above the floor): an ordinary spawn is held, the
# guide's admission (FLEET_ADMIT_GUIDE=1, what dash-raw-session asks for the pinned
# /fleet-onboard window) passes, a warn pressure still holds it; and a guide tick
# that stops writes onboard.stuck AND says it (an onboard-stuck alert event).
drill_guide_admission_room() {
  CAP=30; local t0 d="$WORK/gar" out ev
  mkdir -p "$d/tmp" "$d/conf/global"
  adm() { env FLEET_ADMIT=1 TMPDIR="$d/tmp" HOME="$d" FLEET_CONF_DIR="$d/conf" FLEET_MEM_TOTAL_MB=16000 \
            FLEET_MEM_PS_CMD="printf '101 1 $(id -u) 409600 01:00 claude\n'" \
            FLEET_MEM_PROBE_CMD="echo ${P:-1} 18 0 0" FLEET_LOAD_PROBE_CMD='echo 0.5' \
            FLEET_GLOBAL_MAX_SESSIONS=0 FLEET_MAX_SESSIONS=0 FLEET_MACHINE_MAX_SESSIONS=0 \
            bash -c "source '$BIN/fleet-lib.sh'; $1" 2>&1; }
  t0=$(now)
  out=$(adm 'FLEET_ADMIT_ROOM=hold fleet_session_cap_ok fleet; echo "|rc=$?"')
  case "$out" in *'pressure normal'*'room for 0 more'*'|rc=1') ;; *) WHY="an ordinary spawn at room 0 must be held under the strict rule: $out"; return 1 ;; esac
  out=$(adm 'FLEET_ADMIT_GUIDE=1 fleet_session_cap_ok fleet; echo "|rc=$?"')
  [ "$out" = '|rc=0' ] || { WHY="the onboarding guide was refused at normal pressure above the floor: $out"; return 1; }
  out=$(P=2 adm 'FLEET_ADMIT_GUIDE=1 fleet_session_cap_ok fleet; echo "|rc=$?"')
  case "$out" in *'pressure warn'*'|rc=1') ;; *) WHY="a warn pressure must still hold the guide: $out"; return 1 ;; esac
  grep -q '\[ "\$NAME" = guide \] && \[ "\$PIN" = 1 \] && \[ "\$PROMPT" = /fleet-onboard \] && _admit_guide=1' "$BIN/dash-raw-session.sh" \
    || { WHY="dash-raw-session does not ask the waiver for the pinned /fleet-onboard guide"; return 1; }
  # the third try that never spoke: the stop is written and said
  : > "$d/conf/global/onboard.pending"; printf '3\n' > "$d/conf/global/onboard.tries"; printf '0\n' > "$d/conf/global/onboard.retry"
  printf '引导窗口没能打开：dash-raw-session: machine memory tight · x\n' > "$d/conf/global/onboard.openfail"
  adm "fleet_guide_tick gar-nosuch-$$" >/dev/null
  [ -s "$d/conf/global/onboard.stuck" ] || { WHY="three tries did not write onboard.stuck"; return 1; }
  ev=$(find "$d" -name alerts.events -type f 2>/dev/null | head -n 1)
  grep -q 'onboard-stuck.*新手引导没开：引导窗口没能打开' "${ev:-/nonexistent}" 2>/dev/null \
    || { WHY="the stop was filed but not said (no onboard-stuck event in ${ev:-alerts.events}): $(cat "$d/conf/global/onboard.stuck")"; return 1; }
  SECS=$(since "$t0")
  WHAT="room 0、压力正常、在保底线之上：普通会话照拦，新手引导放行，压力 warn 仍拦；三次没开口写 onboard.stuck 并发出 onboard-stuck 事件"
}

# admit-room-advice (issue #3479): the newcomer's SECOND ordinary session on mini2
# (drill 35) — pressure normal, 25 % free, floor 15 %, «room for 0 more at ~882 MB
# each»: the hysteresis an earlier hold left and a just-opened window's reservation
# took the one-more estimate to 0 while 757 MB sat above the floor. For real, on a
# sandbox state dir with mini2's numbers (16384 MB, agents of 294 MB × 3 = 882,
# admit-held + one confirmed reservation): the spawn gate admits and notes it, the
# capacity beat tells the hub room 1 (not «full»), a second reservation, warn
# pressure and the floor still hold, FLEET_ADMIT_ROOM=hold gives the old refusal.
drill_admit_room_advice() {
  CAP=30; local t0 d="$WORK/ara" out
  t0=$(now)
  local g="$d/tmp/.claude-dash/global"   # FLEET_C: the state dir under TMPDIR
  setup() { rm -rf "$d"; mkdir -p "$g/admit-reserve" "$d/conf"
    : > "$g/admit-held"; : > "$g/admit-reserve/guide.ok.1"; }
  adm() { env FLEET_ADMIT=1 TMPDIR="$d/tmp" HOME="$d" FLEET_CONF_DIR="$d/conf" FLEET_MEM_TOTAL_MB=16384 \
            FLEET_MEM_PS_CMD="printf '101 1 $(id -u) 301056 01:00 claude\n'" \
            FLEET_MEM_PROBE_CMD="echo ${P:-1} ${A:-25} 0 0" FLEET_LOAD_PROBE_CMD='echo 0.5' \
            FLEET_GLOBAL_MAX_SESSIONS=0 FLEET_MAX_SESSIONS=0 FLEET_MACHINE_MAX_SESSIONS=0 "$@" 2>&1; }
  setup
  out=$(adm FLEET_ADMIT_ROOM=hold bash -c "source '$BIN/fleet-lib.sh'; fleet_session_cap_ok fleet; echo \"|rc=\$?\"")
  case "$out" in *'pressure normal'*'room for 0 more at ~882 MB'*'|rc=1') ;; *) WHY="the strict rule does not reproduce mini2's refusal: $out"; return 1 ;; esac
  setup   # admitted, and its window opened (confirmed) — so it stays reserved
  out=$(adm bash -c "source '$BIN/fleet-lib.sh'; fleet_session_cap_ok fleet; rc=\$?; [ \$rc = 0 ] && fleet_admit_confirm >/dev/null; echo \"|rc=\$rc\"")
  [ "$out" = '|rc=0' ] || { WHY="room 0 at normal pressure, 757 MB above the floor + reserved, refused the second session: $out"; return 1; }
  grep -q 'admitted at normal pressure (advice)' "$g/admit-advice.log" 2>/dev/null \
    || { WHY="the advice admission was not noted in global/admit-advice.log"; return 1; }
  # spawns still opening their window bind (an open one is in avail — #3487)
  local sa sb; sleep 30 & sa=$!; sleep 30 & sb=$!
  : > "$g/admit-reserve/x.$sa.1"; : > "$g/admit-reserve/y.$sb.2"
  out=$(adm bash -c "source '$BIN/fleet-lib.sh'; fleet_session_cap_ok fleet; echo \"|rc=\$?\"")
  kill "$sa" "$sb" 2>/dev/null; wait "$sa" "$sb" 2>/dev/null
  case "$out" in *'room for 0 more'*'(2 still opening)'*'|rc=1') ;; *) WHY="a session past the floor + 2 spawns still opening must still be held: $out"; return 1 ;; esac
  setup; out=$(P=2 adm bash -c "source '$BIN/fleet-lib.sh'; fleet_session_cap_ok fleet; echo \"|rc=\$?\"")
  case "$out" in *'pressure warn'*'|rc=1') ;; *) WHY="warn pressure must still hold: $out"; return 1 ;; esac
  setup; out=$(A=14 adm bash -c "source '$BIN/fleet-lib.sh'; fleet_session_cap_ok fleet; echo \"|rc=\$?\"")
  case "$out" in *'内存紧张'*'|rc=1') ;; *) WHY="below the kept-back floor must still hold: $out"; return 1 ;; esac
  setup; out=$(adm bash "$BIN/fleet-control-read.sh" capacity)
  case "$out" in *'"admit":true'*'"room":2}'*) ;; *) WHY="the capacity beat under mini2's reading must say admit:true room 2 (the hub reads room < 1 as full): $out"; return 1 ;; esac
  grep -q '^func TestClientPlaceNamedFullSaysPinned(' "$ROOT/tokenledger/internal/api/fleet_place_fallback_test.go" 2>/dev/null \
    || { WHY="the hub half's test TestClientPlaceNamedFullSaysPinned is not in fleet_place_fallback_test.go"; return 1; }
  SECS=$(since "$t0")
  WHAT="mini2 的数（25% 空闲、保底 15%、约 882 MB/会话、残留 hold + 1 个刚开的窗口）：普通第二个会话放行并记下；容量拍子报 room 2；两个还在开的 spawn、压力 warn、低于保底线仍拦；FLEET_ADMIT_ROOM=hold 复现原拒绝"
}

# admit-open-window-twice (issue #3487): after #3480 mini2 still refused a
# newcomer's FIRST ordinary session (drill 36, 2026-10-12T04:02:09Z): pressure
# normal, 29 % free, «room for 0 more at ~822 MB each: 4751 MB available, 2457 MB
# kept back, 3 admitted not yet counted» — 4751 − 2457 − 3 × 822 = −172. The three
# were the guide's and the warm pool's windows, open and confirmed, their agents
# already in `avail`: charged twice. For real on a sandbox state dir with those
# numbers (16384 MB, 3 agents of 274 MB × 3 = 822, 29 %, three .ok reservations):
# the spawn gate admits and notes «0 still opening»; three spawns still running
# unconfirmed hold, the message giving the sum it weighed; warn pressure holds.
drill_admit_open_window_twice() {
  CAP=30; local t0 d="$WORK/aow" out g sp1 sp2 sp3
  t0=$(now); g="$d/tmp/.claude-dash/global"
  setup() { rm -rf "$d"; mkdir -p "$g/admit-reserve" "$d/conf"
    for k in guide.ok.1 pool-a.ok.2 pool-b.ok.3; do : > "$g/admit-reserve/$k"; done; }
  adm() { env FLEET_ADMIT=1 TMPDIR="$d/tmp" HOME="$d" FLEET_CONF_DIR="$d/conf" FLEET_MEM_TOTAL_MB=16384 \
            FLEET_MEM_PS_CMD="printf '101 1 $(id -u) 280576 01:00 claude\n102 1 $(id -u) 280576 01:00 claude\n103 1 $(id -u) 280576 01:00 claude\n'" \
            FLEET_MEM_PROBE_CMD="echo ${P:-1} 29 0 0" FLEET_LOAD_PROBE_CMD='echo 0.5' \
            FLEET_GLOBAL_MAX_SESSIONS=0 FLEET_MAX_SESSIONS=0 FLEET_MACHINE_MAX_SESSIONS=0 "$@" 2>&1; }
  setup
  out=$(adm FLEET_ADMIT_ROOM=hold bash -c "source '$BIN/fleet-lib.sh'; fleet_session_cap_ok fleet; echo \"|rc=\$?\"")
  case "$out" in *'room for 0 more at ~822 MB each: 4751 MB available, 2457 MB kept back, 3 admitted not yet counted'*'|rc=1') ;;
    *) WHY="the strict rule does not reproduce drill 36's refusal: $out"; return 1 ;; esac
  setup
  out=$(adm bash -c "source '$BIN/fleet-lib.sh'; fleet_session_cap_ok fleet; echo \"|rc=\$?\"")
  [ "$out" = '|rc=0' ] || { WHY="three open windows charged again refused the first session at 29 % free: $out"; return 1; }
  grep -q '3 admitted not yet counted (0 still opening) — admitted at normal pressure (advice)' "$g/admit-advice.log" 2>/dev/null \
    || { WHY="the advice admission was not noted with what it weighed: $(cat "$g/admit-advice.log" 2>/dev/null)"; return 1; }
  rm -rf "$g/admit-reserve"; mkdir -p "$g/admit-reserve"
  sleep 30 & sp1=$!; sleep 30 & sp2=$!; sleep 30 & sp3=$!
  : > "$g/admit-reserve/a.$sp1.1"; : > "$g/admit-reserve/b.$sp2.2"; : > "$g/admit-reserve/c.$sp3.3"
  out=$(adm bash -c "source '$BIN/fleet-lib.sh'; fleet_session_cap_ok fleet; echo \"|rc=\$?\"")
  kill "$sp1" "$sp2" "$sp3" 2>/dev/null; wait "$sp1" "$sp2" "$sp3" 2>/dev/null
  case "$out" in *'(3 still opening)'*'4751 − 2457 − 3 × 822 > 0, and that is -172'*'|rc=1') ;;
    *) WHY="three spawns still opening must hold, naming the sum it weighed: $out"; return 1 ;; esac
  setup; out=$(P=2 adm bash -c "source '$BIN/fleet-lib.sh'; fleet_session_cap_ok fleet; echo \"|rc=\$?\"")
  case "$out" in *'pressure warn'*'|rc=1') ;; *) WHY="warn pressure must still hold: $out"; return 1 ;; esac
  SECS=$(since "$t0")
  WHAT="drill 36 的数（29% 空闲、保底 2457 MB、约 822 MB/会话、3 个已开的窗口）：第一个普通会话放行并记「0 still opening」；3 个还在开的 spawn 仍拦且写出 4751 − 2457 − 3 × 822 = -172；压力 warn 仍拦"
}

# hubsess-daemon-nohup (issue #2630): the collector is a LaunchDaemon now, and
# macOS's nohup detaches from the console through launchd and EXITS when it
# cannot — every time under a daemon — so `--ensure` started no loop and the
# other machines' rows stood still for 5 hours ("loop none"); meanwhile two
# shells' --ensure raced past one pid file and two loops served one cache. The
# drill puts such a nohup first on PATH and fires two --ensure and a --loop at
# once: within 5s exactly ONE loop runs, it holds the lock, --status names it.
drill_hubsess_daemon_nohup() {
  CAP=5; local t0 d="$WORK/hsn" n p f
  mkdir -p "$d/bin" "$d/fake" "$d/tmp" "$d/conf"
  for f in "$BIN"/*; do ln -sf "$f" "$d/bin/"; done
  printf '#!/bin/sh\necho "nohup: can'"'"'t detach from console" >&2\nexit 127\n' > "$d/fake/nohup"
  printf '#!/bin/sh\nexit 1\n' > "$d/fake/tmux"
  chmod +x "$d/fake/nohup" "$d/fake/tmux"
  hsn() { env HOME="$d" PATH="$d/fake:$PATH" TMPDIR="$d/tmp" FLEET_CONF_DIR="$d/conf" FLEET_SKIP_GLOBAL_CONF=1 \
            CCQUOTA_FLEET=1 FLEET_HUB_SESSIONS_CMD='printf "{\"machines\":[],\"sessions\":[],\"nodes\":[]}\n"' \
            FLEET_HUB_SESSIONS_EVERY=1 FLEET_HUB_SESSIONS_LOOP_SECS=20 bash "$d/bin/fleet-hub-sessions.sh" "$@"; }
  t0=$(now)
  hsn --ensure & hsn --ensure & ( hsn --loop >/dev/null 2>&1 & )
  wait
  until_ok "$CAP" sh -c 'pgrep -f "^bash $1 --loop" >/dev/null' _ "$d/bin/fleet-hub-sessions.sh" \
    || { WHY="with a nohup that cannot detach, no loop started — the LaunchDaemon case"; return 1; }
  SECS=$(since "$t0")
  sleep 1
  n=$(pgrep -f "^bash $d/bin/fleet-hub-sessions.sh --loop" | wc -l | tr -d ' ')
  p=$(pgrep -f "^bash $d/bin/fleet-hub-sessions.sh --loop" | head -1)
  [ "$n" = 1 ] || { pkill -f "^bash $d/bin/fleet-hub-sessions.sh --loop"; WHY="$n loops serve one cache after two --ensure + a --loop at once"; return 1; }
  case "$(hsn --status 2>/dev/null)" in "loop $p "*) ;; *) kill "$p" 2>/dev/null; WHY="--status does not name the lock holder $p: [$(hsn --status 2>&1)]"; return 1 ;; esac
  kill "$p" 2>/dev/null
  WHAT="nohup 退出、两次 --ensure 加一个 --loop 同时起：${SECS}s 内恰好一个 loop，持锁，--status 看得见"
}

# followup-stable-storm (issue #2672, EPIC #2668 C4): four batches end the same
# day, each closing comment says 「move stable」, and one batch is still running.
# The drill closes four EPICs with a stable followup while a batch holds the
# install: two beats move nothing; once the hold lifts ONE move runs, the list
# has ONE row, and every batch is written back.
drill_followup_stable_storm() {
  CAP=30; local t0 g="$WORK/fss" n m w
  mkdir -p "$g/conf/fleets/fs/repos" "$g/gh"
  printf 'FLEET_REPO="o/r"\n' > "$g/conf/fleets/fs/repos/o-r.conf"
  printf '#!/bin/sh\nf="%s/gh/$2.json"; [ -f "$f" ] && cat "$f" || printf "{\\"state\\":\\"OPEN\\",\\"comments\\":[]}\\n"\n' "$g" > "$g/issue"
  printf '#!/bin/sh\necho run >> "%s/moves"\n' "$g" > "$g/move"
  printf '#!/bin/sh\n[ -f "%s/held" ]\n' "$g" > "$g/hold"
  printf '#!/bin/sh\ncat >/dev/null; echo "$1#$2" >> "%s/posts"\n' "$g" > "$g/post"
  printf '#!/bin/sh\ncase "$1" in new) printf "gh:o/r#9\\turl\\n" ;; esac\n' > "$g/ticket"
  printf '#!/bin/sh\nprintf "{\\"seq\\": 0, \\"children\\": []}\\n"\n' > "$g/children"
  printf '#!/bin/sh\n:\n' > "$g/none"
  chmod +x "$g/issue" "$g/move" "$g/hold" "$g/post" "$g/ticket" "$g/children" "$g/none"
  fs() { env FLEET_CONF_DIR="$g/conf" FLEET_UI_LANG=zh FLEET_STEWARD_HOLDER_CMD='echo @9' FLEET_STEWARD_FOLLOWUP_SYNC=1 \
           FLEET_STEWARD_ISSUE_CMD="$g/issue" FLEET_STEWARD_STABLE_CMD="$g/move" FLEET_STEWARD_HOLD_CMD="$g/hold" \
           FLEET_STEWARD_TICKET_CMD="$g/ticket" FLEET_DECISION_POST_CMD="$g/post" FLEET_DECISION_COMMENTS_CMD="$g/none" \
           FLEET_STEWARD_WINDOWS_CMD="$g/none" FLEET_STEWARD_CHILDREN_CMD="$g/children" FLEET_STEWARD_SEND_CMD="$g/none" \
           FLEET_STEWARD_STAMP_CMD="$g/none" FLEET_STEWARD_STAMP_TODO_CMD="$g/none" \
           FLEET_STEWARD_DOCTOR_CMD="$g/none" FLEET_STEWARD_IDLE_CMD="$g/none" \
           python3 "$BIN/fleet_steward.py" "$@" --session fs; }
  : > "$g/held"
  for n in 11 12 13 14; do
    m=$(python3 "$BIN/fleet_followup.py" mark --kind stable --what "挪稳定版（#${n}）")
    python3 -c 'import json,sys; json.dump({"state":"CLOSED","comments":[{"body":"后续：move stable\n"+sys.argv[1],"url":"u"}]}, open(sys.argv[2],"w"))' "$m" "$g/gh/$n.json"
    fs followups --watch "o/r#$n" >/dev/null
  done
  t0=$(now)
  fs beat --holder --force >/dev/null 2>&1; fs beat --holder --force >/dev/null 2>&1
  [ ! -s "$g/moves" ] || { WHY="stable moved while a batch holds the install"; return 1; }
  rm -f "$g/held"
  fs beat --holder --force >/dev/null 2>&1; fs beat --holder --force >/dev/null 2>&1
  n=$(grep -c . "$g/moves" 2>/dev/null || echo 0)
  [ "$n" = 1 ] || { WHY="four batches' 「move stable」 ran $n moves (want one)"; return 1; }
  w=$(grep -c . "$g/posts" 2>/dev/null || echo 0)
  [ "$w" = 4 ] || { WHY="the run was written back on $w of four batches"; return 1; }
  SECS=$(since "$t0")
  WHAT="四个批次各留「move stable」、一个批次还在跑：在跑时一次不挪，放开后只挪一次，四个批次都回写"
}

# ---- park-* (#2671, EPIC #2668 C3): parking a stuck session. The sandbox is
# bin/fleet-park-selftest.sh's — its own isolated tmux socket, a real worktree with
# a bare remote, seams for GitHub / the peer channel / the spawn — run once, read
# by both drills.
park_run() {
  [ -f "$WORK/park.out" ] || bash "$BIN/fleet-park-selftest.sh" > "$WORK/park.out" 2>&1
}
park_need() { # park_need <PASS line fragment>…
  local f
  for f in "$@"; do
    grep -q "^PASS  $f" "$WORK/park.out" && continue
    WHY="no PASS for: $f — $(grep -m 3 '^FAIL' "$WORK/park.out" | tr '\n' '|')"
    return 1
  done
}

# park-lost-progress: the session never answers the handoff request. Past the grace
# the fleet keeps the screen, pushes the branch, keeps the worktree (uncommitted
# file included), and the wake comes back on the same conversation.
drill_park_lost_progress() {
  CAP=120; local t0; t0=$(now)
  park_run
  park_need "C no handoff past the grace" "C its comment points at the kept screen" "C its branch is pushed" \
            "B the worktree stays" "B the screen is kept" "D reopened on the SAME conversation" \
            "D its first turn reads the handoff" || return 1
  SECS=$(since "$t0")
  WHAT="不回话的会话过了宽限：屏幕存档、分支推上、工作区连未提交的都在；条件满足同一对话接回、首轮读交接"
}

# park-restored-by-restore: a reboot's restore runs off a map taken while the
# parked session was still open. It must leave that one closed (and say so), and
# still take an ordinary lost window beside it; --auto's pull-back sees it retired.
drill_park_restored_by_restore() {
  CAP=120; local t0; t0=$(now)
  park_run
  park_need "B the window is retired" "B fleet_parked o/r 7" "H restore leaves the parked one closed" \
            "H restore does nothing else with it" "H an ordinary lost window still takes" || return 1
  SECS=$(since "$t0")
  WHAT="拿停放前的地图恢复：停放的不重开（写 parked），旁边普通丢的照走恢复；拉回认 retired 不碰"
}

# health-silent-pass (issue #2674, EPIC #2668 C6): a systemic fault arrives
# quietly — a doctor row goes PASS→FAIL, and every sleep is refused (#2622's
# `wrong fleet`) while sessions sit idle. The steward's beat files ONE issue for
# each, once: the next beat with the fault still there writes nothing more.
drill_health_silent_pass() {
  CAP=30; local t0 g="$WORK/hsp" at old
  mkdir -p "$g/conf/fleets/hp/repos"
  printf 'FLEET_REPO="o/r"\n' > "$g/conf/fleets/hp/repos/o-r.conf"
  printf '#!/bin/sh\n:\n' > "$g/none"
  printf '#!/bin/sh\ncat "%s/doctor.json"\n' "$g" > "$g/doctor"
  printf '#!/bin/sh\ncat "%s/idle.txt"\n' "$g" > "$g/idle"
  printf '#!/bin/sh\nn=$(( $(grep -c . "%s/issues" 2>/dev/null || echo 0) + 1 ))\nprintf "%%s\\t%%s\\n" "$n" "$(tr "\\n" " ")" >> "%s/issues"\necho "https://github.com/$1/issues/$n"\n' "$g" "$g" > "$g/file"
  printf '#!/bin/sh\ngrep -F -- "$2" "%s/issues" 2>/dev/null | head -1 | cut -f1\n' "$g" > "$g/find"
  printf '#!/bin/sh\ncat >/dev/null; echo "$1#$2" >> "%s/posts"\n' "$g" > "$g/post"
  chmod +x "$g/none" "$g/doctor" "$g/idle" "$g/file" "$g/find" "$g/post"
  hp() { env FLEET_CONF_DIR="$g/conf" FLEET_UI_LANG=zh FLEET_STEWARD_HOLDER_CMD='echo @9' FLEET_SLEEP=observe \
           FLEET_DECISION_COMMENTS_CMD="$g/none" FLEET_DECISION_POST_CMD="$g/post" FLEET_STEWARD_WINDOWS_CMD="$g/none" \
           FLEET_STEWARD_CHILDREN_CMD="$g/none" FLEET_STEWARD_SEND_CMD="$g/none" FLEET_STEWARD_STAMP_CMD="$g/none" \
           FLEET_STEWARD_DOCTOR_CMD="$g/doctor" FLEET_STEWARD_IDLE_CMD="$g/idle" FLEET_STEWARD_SLEEP_LOG="$g/sleep.log" \
           FLEET_STEWARD_CLEANUP_LOG="$g/cleanup.log" FLEET_STEWARD_HEALTH_REPO=o/f FLEET_STEWARD_HEALTH_EVERY=0 FLEET_STEWARD_HEALTH_CONFIRM=1 \
           FLEET_STEWARD_HEALTH_FILE_CMD="$g/file" FLEET_STEWARD_HEALTH_FIND_CMD="$g/find" FLEET_STEWARD_IDLE_SECS=60 \
           python3 "$BIN/fleet_steward.py" beat --holder --force --session hp >/dev/null 2>&1; }
  printf '{"rows": [{"level": "PASS", "row": "qwatch", "msg": "quota cache fresh"}]}\n' > "$g/doctor.json"
  : > "$g/idle.txt"
  hp
  [ ! -s "$g/issues" ] || { WHY="a healthy baseline filed: $(cat "$g/issues")"; return 1; }
  t0=$(now)
  printf '{"rows": [{"level": "FAIL", "row": "qwatch", "msg": "quota cache is FRESH BUT EMPTY — the last 1746 reads returned no rows"}]}\n' > "$g/doctor.json"
  old=$(( $(date +%s) - 600 )); at=$(date '+%Y-%m-%dT%H:%M:%S')
  printf '@1\tworker\tdone\t%s\t\t\tissue-1\n@2\tworker\tdone\t%s\t\t\tissue-2\n' "$old" "$old" > "$g/idle.txt"
  printf '{"session": "hp", "window": "@1", "at": "%s", "skip": "wrong fleet"}\n{"session": "hp", "window": "@2", "at": "%s", "skip": "wrong fleet"}\n' \
    "$at" "$at" > "$g/sleep.log"
  hp
  SECS=$(since "$t0")
  [ "$(grep -c . "$g/issues" 2>/dev/null)" = 2 ] && grep -q 'key=qwatch:' "$g/issues" && grep -q 'key=idle-sleep:hp' "$g/issues" \
    || { WHY="one beat after the fault: issues [$(cat "$g/issues" 2>/dev/null)]"; return 1; }
  hp
  [ "$(grep -c . "$g/issues")" = 2 ] && [ ! -s "$g/posts" ] || { WHY="the fault still there next beat wrote again"; return 1; }
  WHAT="体检 PASS→FAIL、休眠全被拒：同一拍各立一张单，下一拍仍在不再写"
}


# ---- dist-no-github (#2776, EPIC #2770 C6): GitHub out of reach and stable moved —
# every install still reaches the new version from the hub alone. The sandbox is
# bin/dist-no-github-selftest.sh's (git insteadOf + a curl proxy into a recorder,
# a fake hub on 127.0.0.1, the real scripts). Every member is merged (EPIC #2770
# wave 4), so the drill runs --strict: DIST_AWAIT cannot hide a red leg again.
drill_dist_no_github() {
  CAP=120; local t0 out
  t0=$(now)
  out=$(bash "$BIN/dist-no-github-selftest.sh" --strict 2>&1) || { WHY="$(printf '%s\n' "$out" | grep -m 3 -E '^(RED|FAIL)' | cut -c1-220 | tr '\n' '|')"; return 1; }
  SECS=$(since "$t0")
  WHAT="GitHub 黑洞下（--strict）：$(printf '%s\n' "$out" | tail -1 | sed 's/^dist-no-github: //') — 每个安装都只从入口到了新版"
}

# ---- dist-publish-tampered (#2772, EPIC #2770 C2): the hub takes stable only from a
# publish, so a publish is the one door a wrong version could come in by — bytes
# changed on the way, a token from another repo / branch / workflow, a stable moved
# backwards. The hub hashes the archive into git's tree and the commit objects into
# their shas and refuses (400 / 401 / 409), leaving its stable where it was; the Go
# tests do it for real against a real `git archive`, GitHub a black hole. The CI
# half — what fleet-release-publish.sh sends, its token never on an argv — is its
# selftest against a loopback hub.
drill_dist_publish_tampered() {
  CAP=120; local t0 out rc tests f
  tests='TestPublishTamperedTreeRefused TestPublishIdentityRefused TestPublishOnlyForward TestPublishStoresAndServesWithGitHubGone'
  f="$ROOT/tokenledger/internal/api/fleet_publish_test.go"
  for out in $tests; do
    grep -q "^func $out(" "$f" 2>/dev/null || { WHY="the hub half's test $out is not in ${f#$ROOT/}"; return 1; }
  done
  t0=$(now)
  out=$(bash "$BIN/fleet-release-publish-selftest.sh" 2>&1) \
    || { WHY="the CI half: $(printf '%s' "$out" | grep -m 3 FAIL | cut -c1-200 | tr '\n' '|')"; return 1; }
  WHAT='CI 送的是整个提交 + 从入口 stable 起的提交链，令牌不上命令行'
  if [ "${BREAK_GO:-1}" != 0 ] && command -v go >/dev/null 2>&1; then
    out=$(cd "$ROOT/tokenledger" && GOFLAGS=-mod=mod GOPROXY=off GOTOOLCHAIN=local \
          go test -count=1 -run "^($(printf '%s' "$tests" | tr ' ' '|'))\$" ./internal/api 2>&1); rc=$?
    case "$rc:$out" in
      0:*'no tests to run'*) WHY="the hub half's Go tests are not there (go test ran none)"; return 1 ;;
      0:*) WHAT="${WHAT}；入口：改一个字节 400、别的仓 / 分支 / 流程 401、回退 / 横跳 409、GitHub 黑洞零命中（go test 四条）" ;;
      *GOPROXY=off*|*'module lookup disabled'*|*'cannot find module'*|*'missing go.sum entry'*|*'requires go >= '*)
        WHAT="${WHAT}；入口的 Go 测试这台没有模块缓存 / 工具链——Go 门（tokenledger.yml）跑它们" ;;
      *) WHY="the hub half (go test) is red: $(printf '%s' "$out" | grep -v '^ok' | head -6 | tr '\n' ' ')"; return 1 ;;
    esac
  else
    WHAT="${WHAT}；没有 go：五条测试按名核对在，Go 门（tokenledger.yml）跑它们"
  fi
  SECS=$(since "$t0")
}

# ---- hub-stream-silent (#2794, EPIC #2792 C2): the push channel held open by a
# proxy that neither sends nor closes — the page must not believe it is live.
# The page half for real (node --test on lib/stream.js under a virtual clock: a
# silent stream is down at 30 s and reconnects, the reconnect is the catch-up, a
# stream that cannot be built polls every 10 s); the hub half's ping and scope by
# name (and go test with a toolchain).
drill_hub_stream_silent() {
  CAP=120; local t0 out rc js="$ROOT/tokenledger/web/dist/lib/stream.js" tests f
  tests='TestFleetStreamPing TestFleetStreamScoped TestFleetStreamOnlyOnChange'
  f="$ROOT/tokenledger/internal/api/fleet_stream_test.go"
  t0=$(now)
  grep -q 'export const WATCHDOG_MS = 30000;' "$js" || { WHY="lib/stream.js no longer gives up on a silent stream at 30 s"; return 1; }
  grep -q 'var fleetStreamPing = 20 \* time.Second' "$ROOT/tokenledger/internal/api/fleet_stream.go" \
    || { WHY="the hub no longer pings an idle stream every 20 s"; return 1; }
  for out in $tests; do
    grep -q "^func $out(" "$f" 2>/dev/null || { WHY="the hub half's test $out is not in ${f#$ROOT/}"; return 1; }
  done
  if command -v node >/dev/null 2>&1; then
    out=$(cd "$ROOT/tokenledger/web" && node --test test/stream.test.mjs 2>&1); rc=$?
    [ "$rc" = 0 ] || { WHY="the page half is red: $(printf '%s\n' "$out" | grep -m 4 -E 'not ok|Error|expected|actual' | tr '\n' ' ')"; return 1; }
    printf '%s\n' "$out" | grep -q 'hub-stream-silent' || { WHY="the hub-stream-silent test did not run"; return 1; }
    WHAT='代理挂住的推送 30 s 标黄并重连、重连即补一份；建不起来退回 10 s 轮询（node --test，虚拟时钟）'
  else
    WHAT='没有 node：页面一半按名核对在，web 门（tokenledger.yml 的 npm test）跑它'
  fi
  if [ "${BREAK_GO:-1}" != 0 ] && command -v go >/dev/null 2>&1; then
    out=$(cd "$ROOT/tokenledger" && GOFLAGS=-mod=mod GOPROXY=off GOTOOLCHAIN=local \
          go test -count=1 -run "^($(printf '%s' "$tests" | tr ' ' '|'))\$" ./internal/api 2>&1); rc=$?
    case "$rc:$out" in
      0:*'no tests to run'*) WHY="the hub half's Go tests are not there (go test ran none)"; return 1 ;;
      0:*) WHAT="${WHAT}；入口每 20 s ping、只发本人的、没变不发（go test）" ;;
      *GOPROXY=off*|*'module lookup disabled'*|*'cannot find module'*|*'missing go.sum entry'*|*'requires go >= '*) ;;
      *) WHY="the hub half (go test) is red: $(printf '%s' "$out" | grep -v '^ok' | head -6 | tr '\n' ' ')"; return 1 ;;
    esac
  fi
  SECS=$(since "$t0")
}

# ---- dist-bad-signature (#2773, EPIC #2770 C3): the hub's release does not
# verify against the key this login pinned — the install-sync tick takes nothing:
# fetch-failed, still the old version, nothing half-made in fleet.versions/, and
# GitHub not asked instead. Same sandbox as dist-no-github, one named leg.
drill_dist_bad_signature() {
  CAP=60; local t0 out
  t0=$(now)
  out=$(bash "$BIN/dist-no-github-selftest.sh" bad-signature 2>&1) || { WHY="$(printf '%s\n' "$out" | grep -m 2 -E '^(RED|FAIL)' | cut -c1-220 | tr '\n' '|')"; return 1; }
  SECS=$(since "$t0")
  WHAT="入口发来的包验不过章：install-sync 记 fetch-failed、不切、不留半成品、不找 GitHub"
}

# ---- bootstrap-reaches-github (#2775, EPIC #2770 C5): a new login's first install
# on a managed machine (FLEET_NODE_ROOT/current = the stable) and on a machine with
# only a hub that keeps releases — GitHub a black hole in both. GREEN = the login
# reads the new version and nothing asked GitHub, the starter repo included.
drill_bootstrap_reaches_github() {
  CAP=120; local t0 out
  t0=$(now)
  out=$(bash "$BIN/dist-no-github-selftest.sh" --strict bootstrap bootstrap-hub 2>&1) || { WHY="$(printf '%s\n' "$out" | grep -m 2 -E '^(RED|FAIL)' | cut -c1-220 | tr '\n' '|')"; return 1; }
  SECS=$(since "$t0")
  WHAT="新登录第一次装：托管机器链接运行时、只有入口时取验过章的 stable，种子仓从装好的那份做——GitHub 黑洞下两条路都没碰 GitHub"
}

# ---- service-log-cross-login (#2797, EPIC #2792 C5): a person spells another
# login (or a made-up one) into …/services/<login>/<name>/log, or the node is
# asked for a file the register does not name. The hub answers 403 before any
# node is asked, masks every credential-shaped line, asks the node once per
# service; the node opens only the register's <log>/logins/<login>/<name>.log,
# the lane's own login, never a link. Go tests by name (and run with a
# toolchain), the page's 403-is-a-word by node --test.
drill_service_log_cross_login() {
  CAP=180; local t0 out rc api agt fa fg
  api='TestServiceLogCrossLoginIs403 TestServiceLogOneFollowForManyViewers TestRedactLogLine'
  agt='TestServiceLogOnlyTheRegisteredFile'
  fa="$ROOT/tokenledger/internal/api/fleet_service_log_test.go"
  fg="$ROOT/tokenledger/internal/agent/node_service_log_test.go"
  t0=$(now)
  grep -q 'if visible != nil && !visible(host, login) {' "$ROOT/tokenledger/internal/api/fleet_service_log.go" \
    || { WHY="handleServiceLog no longer asks FleetScope before anything else"; return 1; }
  grep -q 'serviceLogPath(a.cfg.ServicesFile, login, req.Name)' "$ROOT/tokenledger/internal/agent/node_service_log.go" \
    || { WHY="the node no longer takes the log path from the register for the lane's own login"; return 1; }
  for out in $api; do
    grep -q "^func $out(" "$fa" 2>/dev/null || { WHY="the hub half's test $out is not in ${fa#$ROOT/}"; return 1; }
  done
  grep -q "^func $agt(" "$fg" 2>/dev/null || { WHY="the node half's test $agt is not in ${fg#$ROOT/}"; return 1; }
  WHAT='别人的登录名拼进地址 → 403、节点一次都没被问；只读登记表里本登录的那个文件（测试按名核对在，Go 门跑它们）'
  if command -v node >/dev/null 2>&1; then
    out=$(cd "$ROOT/tokenledger/web" && node --test test/svc-log.test.mjs 2>&1); rc=$?
    [ "$rc" = 0 ] || { WHY="the page half is red: $(printf '%s\n' "$out" | grep -m 4 -E 'not ok|Error|expected|actual' | tr '\n' ' ')"; return 1; }
    WHAT="${WHAT}；页面：403 写「只有管理员看得到」、不重试（node --test）"
  fi
  if [ "${BREAK_GO:-1}" != 0 ] && command -v go >/dev/null 2>&1; then
    out=$(cd "$ROOT/tokenledger" && GOFLAGS=-mod=mod GOPROXY=off GOTOOLCHAIN=local \
          go test -count=1 -run "^($(printf '%s %s' "$api" "$agt" | tr ' ' '|'))\$" ./internal/api ./internal/agent 2>&1); rc=$?
    case "$rc:$out" in
      0:*'no tests to run'*) WHY="the Go tests are not there (go test ran none)"; return 1 ;;
      0:*) WHAT="${WHAT}；go test：403、一份节点流、打码、只读登记的文件" ;;
      *GOPROXY=off*|*'module lookup disabled'*|*'cannot find module'*|*'missing go.sum entry'*|*'requires go >= '*) ;;
      *) WHY="the Go half is red: $(printf '%s' "$out" | grep -v '^ok' | head -6 | tr '\n' ' ')"; return 1 ;;
    esac
  fi
  SECS=$(since "$t0")
}

# ---- debug-ticket-replayed (#2891, EPIC #2889 C2): the ticket a computer took
# at install, copied to another computer, a byte changed, used past its expiry,
# or kept after a re-issue. The hub refuses all four with 401 and one line on
# how to get a new one; a re-issue retires the old ticket; off adds nothing.
# The installer sends the fingerprint's hash, never the hardware id. Go tests by
# name (and run with a toolchain).
drill_debug_ticket_replayed() {
  CAP=120; local t0 out rc t f="$ROOT/tokenledger/internal/api/fleet_debug_ticket.go"
  local tests='TestDebugTicketBindsExpiresAndRefusesTampering TestDebugTicketReissueRetiresTheOld TestDebugTicketUploadQuota TestDebugOffAddsNothing'
  t0=$(now)
  grep -q 'case p.FP != "" && p.FP != fp, p.FP == "" && row.FP != "" && row.FP != fp:' "$f" 2>/dev/null \
    || { WHY="debugTicketAuth no longer refuses a ticket used from another computer's fingerprint"; return 1; }
  grep -q 'if !row.RevokedAt.IsZero() {' "$f" || { WHY="debugTicketAuth no longer refuses a superseded ticket"; return 1; }
  grep -q "printf '%s|%s|%s' \"\$_hw\" \"\$(id -un)\" \"\$ROOT\" | { shasum -a 256" "$ROOT/bin/fleet-install.sh" \
    || { WHY="the installer no longer sends only the hash of hwid|login|root"; return 1; }
  for t in $tests; do
    grep -q "^func $t(" "$ROOT/tokenledger/internal/api/fleet_debug_ticket_test.go" 2>/dev/null \
      || { WHY="the hub half's test $t is not in tokenledger/internal/api/fleet_debug_ticket_test.go"; return 1; }
  done
  WHAT='拷到别的电脑 / 改一字节 / 过期 / 已被补发替换的调试票 → 401 并说怎么补；安装只送指纹哈希（测试按名核对在，Go 门跑它们）'
  if [ "${BREAK_GO:-1}" != 0 ] && command -v go >/dev/null 2>&1; then
    out=$(cd "$ROOT/tokenledger" && GOFLAGS=-mod=mod GOPROXY=off GOTOOLCHAIN=local \
          go test -count=1 -run "^($(printf '%s' "$tests" | tr ' ' '|'))\$" ./internal/api 2>&1); rc=$?
    case "$rc:$out" in
      0:*'no tests to run'*) WHY="the Go tests are not there (go test ran none)"; return 1 ;;
      0:*) WHAT='拷到别的电脑 / 改一字节 / 过期 / 已被补发替换的调试票 → 401 并说怎么补，第 6 次上传 → 429，关掉 ⇒ 路由不存在（go test）；安装只送指纹哈希' ;;
      *GOPROXY=off*|*'module lookup disabled'*|*'cannot find module'*|*'missing go.sum entry'*|*'requires go >= '*) ;;
      *) WHY="the Go half is red: $(printf '%s' "$out" | grep -v '^ok' | head -6 | tr '\n' ' ')"; return 1 ;;
    esac
  fi
  SECS=$(since "$t0")
}

# ---- debug-page-stuck (#2893, EPIC #2889 C4): the debugger session a report
# opened dies, never opens (no login, no machine), or never hands in its page;
# or a bundle arrives still holding a credential. The page would read 「诊断员
# 正在看」 forever and the person would wait. The hub moves a report with no page
# 15 minutes after its debugger was asked (or with none opened) to 没看完 — the
# page says it went to the admin, the orchestrator is told in one line — refuses
# a bundle with anything credential-shaped in any file (400, the file named),
# and deletes everything seven days on. Go tests by name (run with a toolchain).
drill_debug_page_stuck() {
  CAP=120; local t0 out rc t f="$ROOT/tokenledger/internal/api/fleet_debug.go"
  local tests='TestDebugBundleToPage TestDebugBundleRefusals TestDebugTickUnfinishedAndPrune TestDebugSessionsQueueWhenSpent TestDebugReportsOffAddsNothing'
  t0=$(now)
  grep -q 'case r.State == store.DebugDiagnosing && now.Sub(r.DispatchedAt) > debugPageLimit:' "$f" 2>/dev/null \
    || { WHY="debugTick no longer moves a report with no page past its limit to unfinished"; return 1; }
  grep -q 'debugPageLimit = 15 \* time.Minute' "$f" || { WHY="the debugger's page limit is no longer 15 minutes"; return 1; }
  grep -q 'if hit := debugShapeHit(shapes, string(files\[n\])); hit != "" {' "$f" \
    || { WHY="the upload no longer holds every file of the bundle against the shape table"; return 1; }
  grep -q 'send(sess, "orchestrator", ln)' "$ROOT/bin/fleet_steward.py" \
    || { WHY="the steward's beat no longer tells the orchestrator a report's outcome"; return 1; }
  for t in $tests; do
    grep -q "^func $t(" "$ROOT/tokenledger/internal/api/fleet_debug_test.go" 2>/dev/null \
      || { WHY="the hub half's test $t is not in tokenledger/internal/api/fleet_debug_test.go"; return 1; }
  done
  WHAT='诊断员没开成 / 中途死了 / 15 分钟没交页 → 没看完、转给管理员、编排会话一行；包里还有凭据 → 400 说哪个文件；7 天后全删（测试按名核对在，Go 门跑它们）'
  if [ "${BREAK_GO:-1}" != 0 ] && command -v go >/dev/null 2>&1; then
    out=$(cd "$ROOT/tokenledger" && GOFLAGS=-mod=mod GOPROXY=off GOTOOLCHAIN=local \
          go test -count=1 -run "^($(printf '%s' "$tests" | tr ' ' '|'))\$" ./internal/api 2>&1); rc=$?
    case "$rc:$out" in
      0:*'no tests to run'*) WHY="the Go tests are not there (go test ran none)"; return 1 ;;
      0:*) WHAT='诊断员没开成 / 15 分钟没交页 → 没看完、转给管理员；包里还有凭据 → 400 说哪个文件；同包重传同一页；7 天后全删；关掉 ⇒ 路由不存在（go test）' ;;
      *GOPROXY=off*|*'module lookup disabled'*|*'cannot find module'*|*'missing go.sum entry'*|*'requires go >= '*) ;;
      *) WHY="the Go half is red: $(printf '%s' "$out" | grep -v '^ok' | head -6 | tr '\n' ' ')"; return 1 ;;
    esac
  fi
  SECS=$(since "$t0")
}

# ---- usage-unattributed (#3204): a login runs Claude with no /login (its
# sessions on the credential proxy's pool), so ~/.claude.json has no
# oauthAccount. The agent skipped every Claude scan there — silently, Codex
# being on — and the person's usage stopped on the hub. The agent now files
# such a login's turns under the claude:local pool, and the hub raises
# usage_silent on a (machine, login) working past the threshold with no usage.
# Go tests by name (run with a toolchain).
drill_usage_unattributed() {
  CAP=120; local t0 out rc t
  local agent_tests='TestAgent_NoLoginFilesClaudeUsageUnderThePool TestAgent_NoLoginNoTranscriptsFilesNothing'
  local hub_tests='TestUsageSilentRaisedWhenWorkingLoginSendsNothing TestUsageSilentQuietWhenUsageFlowsOrNothingWorks TestUsageSilentAfterFromEnv'
  t0=$(now)
  grep -q 'id, err = identity.ClaudePool(a.cfg.Home), nil' "$ROOT/tokenledger/internal/agent/agent.go" 2>/dev/null \
    || { WHY="the agent no longer files a login with no oauthAccount under the claude:local pool"; return 1; }
  grep -q 's.UsageSilentTick(now, false)' "$ROOT/tokenledger/internal/api/fleet_alerts.go" \
    || { WHY="the alerts sweep no longer runs the usage_silent check"; return 1; }
  for t in $agent_tests; do
    grep -q "^func $t(" "$ROOT/tokenledger/internal/agent/claude_pool_test.go" 2>/dev/null \
      || { WHY="the agent half's test $t is not in tokenledger/internal/agent/claude_pool_test.go"; return 1; }
  done
  for t in $hub_tests; do
    grep -q "^func $t(" "$ROOT/tokenledger/internal/api/fleet_usage_silent_test.go" 2>/dev/null \
      || { WHY="the hub half's test $t is not in tokenledger/internal/api/fleet_usage_silent_test.go"; return 1; }
  done
  WHAT='没 /login 的登录：Claude 用量记进 claude:local 池、照常归到人；会话 working 超 30 分钟没用量 → usage_silent，用量一到就清（测试按名核对在，Go 门跑它们）'
  if [ "${BREAK_GO:-1}" != 0 ] && command -v go >/dev/null 2>&1; then
    out=$(cd "$ROOT/tokenledger" && GOFLAGS=-mod=mod GOPROXY=off GOTOOLCHAIN=local \
          go test -count=1 -run "^($(printf '%s %s' "$agent_tests" "$hub_tests" | tr ' ' '|'))\$" ./internal/agent ./internal/api 2>&1); rc=$?
    case "$rc:$out" in
      0:*'no tests to run'*) WHY="the Go tests are not there (go test ran none)"; return 1 ;;
      0:*) WHAT='没 /login 的登录的 Claude 用量进 claude:local 池（来源 session、不动登录账号）；没对话目录不造池；working 超阈值没用量 → usage_silent，用量到 / 不工作即清（go test）' ;;
      *GOPROXY=off*|*'module lookup disabled'*|*'cannot find module'*|*'missing go.sum entry'*|*'requires go >= '*) ;;
      *) WHY="the Go half is red: $(printf '%s' "$out" | grep -v '^ok' | head -6 | tr '\n' ' ')"; return 1 ;;
    esac
  fi
  SECS=$(since "$t0")
}

# ---- pool-usage-unattributed (#3226, EPIC #3225 C1): a subscription-pool
# request whose usage lands under nobody, or under whoever the report names.
# The cluster proxy reported {principal, tokens} and the hub took the principal
# from the body: a wrong or empty one filed the tokens elsewhere, and nothing
# said which task they were for. Now the proxy reports each request with the
# pass it rode on; the hub files ONE pool_usage row under that pass's person and
# session (a report with no pass / a forged one / another principal is refused
# 403 pool_usage_refused, nothing written), repo / issue frozen from the
# session's lease, and an ownerless row is refused by the store itself.
# Go tests by name (run with a toolchain).
drill_pool_usage_unattributed() {
  CAP=120; local t0 out rc t
  local api_tests='TestPoolUsageRefusedWithoutItsPass TestPoolUsageOneRowPerRequestWithItsLease TestPoolUsageOrchestratorToLoginOwner TestPoolUsageNodeReportAndNoOwnerless'
  local store_tests='TestPersonUsageSinceMatchesTheOldBuckets TestPoolUsageForAndLease'
  local tl="$ROOT/tokenledger/internal"
  t0=$(now)
  grep -q 'c, why := s.poolUsagePass(rep.Cred, rep.Provider' "$tl/api/fleet_person_budget.go" 2>/dev/null \
    || { WHY="the hub no longer takes a usage report's person from the pass it rode on"; return 1; }
  grep -q 'u := store.PoolUsage{Principal: c.Principal, WorkerID: c.WorkerID' "$tl/api/fleet_person_budget.go" \
    || { WHY="the hub files a cluster report under something other than the pass's principal / session"; return 1; }
  grep -q 'return ErrPoolUsageNoPrincipal' "$tl/store/pool_usage.go" 2>/dev/null \
    || { WHY="the store no longer refuses an ownerless pool_usage row"; return 1; }
  grep -q 'u.Cred, u.Principal, u.WorkerID' "$tl/credproxy/credproxy.go" \
    || { WHY="the cluster proxy no longer reports each request with its pass"; return 1; }
  for t in $api_tests; do
    grep -q "^func $t(" "$tl/api/pool_usage_test.go" 2>/dev/null \
      || { WHY="the hub half's test $t is not in tokenledger/internal/api/pool_usage_test.go"; return 1; }
  done
  for t in $store_tests; do
    grep -q "^func $t(" "$tl/store/pool_usage_test.go" 2>/dev/null \
      || { WHY="the store half's test $t is not in tokenledger/internal/store/pool_usage_test.go"; return 1; }
  done
  WHAT='池子用量一笔一行记在通行证的人名下：无通行证 / 伪造 / 自报别人的上报被拒且不写；repo/issue 取自租约；无主行存不进去（测试按名核对在，Go 门跑它们）'
  if [ "${BREAK_GO:-1}" != 0 ] && command -v go >/dev/null 2>&1; then
    out=$(cd "$ROOT/tokenledger" && GOFLAGS=-mod=mod GOPROXY=off GOTOOLCHAIN=local \
          go test -count=1 -run "^($(printf '%s %s' "$api_tests" "$store_tests" | tr ' ' '|'))\$" ./internal/api ./internal/store 2>&1); rc=$?
    case "$rc:$out" in
      0:*'no tests to run'*) WHY="the Go tests are not there (go test ran none)"; return 1 ;;
      0:*) WHAT='池子用量一笔一行：只认通行证的人与会话（无 / 伪造 / 自报不符 → 403 不写），repo/issue 取自租约，编排记给登录主人，个人上限读同一张表且与旧桶口径相等（go test）' ;;
      *GOPROXY=off*|*'module lookup disabled'*|*'cannot find module'*|*'missing go.sum entry'*|*'requires go >= '*) ;;
      *) WHY="the Go half is red: $(printf '%s' "$out" | grep -v '^ok' | head -6 | tr '\n' ' ')"; return 1 ;;
    esac
  fi
  SECS=$(since "$t0")
}

# ---- feedback-identity-public (#3356, EPIC #3354 C2): a feedback filed into
# the PUBLIC repo carries who sent it — a login, a person, a machine's name, a
# session. The hub writes the issue itself, and its body has ONE definition,
# feedbackIssueBody: the words, the version (a sha or 未知), the kind of machine
# (a known word or 未知, never echoed), Claude/Codex, the F number and its
# marker. The App's token and key never reach a log line. Go tests by name.
drill_feedback_identity_public() {
  CAP=120; local t0 out rc t f="$ROOT/tokenledger/internal/api/fleet_feedback_github.go"
  local tests='TestFeedbackFiledPublicFieldsOnly TestFeedbackFilingOffSendsNothing'
  t0=$(now)
  grep -q '"title": feedbackIssueTitle(f.Text), "body": feedbackIssueBody(f), "labels": \[\]string{feedbackGHLabel}}' "$f" 2>/dev/null \
    || { WHY="the filer no longer writes the issue only from feedbackIssueTitle / feedbackIssueBody"; return 1; }
  grep -q 'ver, feedbackPublicKind(ctx\["machine_kind"\]), feedbackPublicAgent(ctx\["agent"\]), num, feedbackMarker(num))' "$f" \
    || { WHY="feedbackIssueBody no longer holds to the four public fields + the F number"; return 1; }
  for t in $tests; do
    grep -q "^func $t(" "$ROOT/tokenledger/internal/api/fleet_feedback_github_test.go" 2>/dev/null \
      || { WHY="the hub half's test $t is not in tokenledger/internal/api/fleet_feedback_github_test.go"; return 1; }
  done
  WHAT='公开单子只有原话 · 版本 · 机器类型 · Claude/Codex · F 号；登录名、人、机器名、会话、窗口不进；令牌不进日志（测试按名核对在，Go 门跑它们）'
  if [ "${BREAK_GO:-1}" != 0 ] && command -v go >/dev/null 2>&1; then
    out=$(cd "$ROOT/tokenledger" && GOFLAGS=-mod=mod GOPROXY=off GOTOOLCHAIN=local \
          go test -count=1 -run "^($(printf '%s' "$tests" | tr ' ' '|'))\$" ./internal/api 2>&1); rc=$?
    case "$rc:$out" in
      0:*'no tests to run'*) WHY="the Go tests are not there (go test ran none)"; return 1 ;;
      0:*) WHAT='假 GitHub 收到的单子正文只有原话 · 版本 · 托管 Linux · Claude · F1 + 标记，登录名 / 机器名 / 会话 / 窗口一个不在；认不出的机器类型写「未知」；令牌、私钥不在任何日志行；没配 App ⇒ 一个请求不发（go test）' ;;
      *GOPROXY=off*|*'module lookup disabled'*|*'cannot find module'*|*'missing go.sum entry'*|*'requires go >= '*) ;;
      *) WHY="the Go half is red: $(printf '%s' "$out" | grep -v '^ok' | grep -v '^20' | head -6 | tr '\n' ' ')"; return 1 ;;
    esac
  fi
  SECS=$(since "$t0")
}

# ---- feedback-github-down (#3356, EPIC #3354 C2): GitHub answers 500 or times
# out while the hub files a feedback — or the 500 came after the issue WAS
# created. The feedback must stay 待转 and be tried again (1 minute, doubling,
# at most an hour), and once GitHub is back it is ONE issue: each pass first
# lists the repo's feedback issues and adopts the one ending in its marker.
drill_feedback_github_down() {
  CAP=120; local t0 out rc f="$ROOT/tokenledger/internal/api/fleet_feedback_github.go"
  local tests='TestFeedbackGitHubDownQueuesThenFilesOnce'
  t0=$(now)
  grep -q 'filed, err := g.feedbackFiled(ctx, auth)' "$f" 2>/dev/null \
    || { WHY="a filing pass no longer looks for the issue a feedback already has before creating one"; return 1; }
  grep -q 'd = min(r.delay\*2, feedbackRetryMax)' "$f" || { WHY="a failed filing no longer backs off doubling"; return 1; }
  grep -q 'feedbackRetryFirst   = time.Minute' "$f" && grep -q 'feedbackRetryMax     = time.Hour' "$f" \
    || { WHY="the filing backoff is no longer 1 minute to 1 hour"; return 1; }
  grep -q "^func $tests(" "$ROOT/tokenledger/internal/api/fleet_feedback_github_test.go" 2>/dev/null \
    || { WHY="the hub half's test $tests is not in tokenledger/internal/api/fleet_feedback_github_test.go"; return 1; }
  WHAT='GitHub 500 / 超时 ⇒ 待转，1 分钟起翻倍到 1 小时再试；恢复后只建一张（测试按名核对在，Go 门跑它们）'
  if [ "${BREAK_GO:-1}" != 0 ] && command -v go >/dev/null 2>&1; then
    out=$(cd "$ROOT/tokenledger" && GOFLAGS=-mod=mod GOPROXY=off GOTOOLCHAIN=local \
          go test -count=1 -run "^($tests)\$" ./internal/api 2>&1); rc=$?
    case "$rc:$out" in
      0:*'no tests to run'*) WHY="the Go tests are not there (go test ran none)"; return 1 ;;
      0:*) WHAT='假 GitHub 先「建成却回 500」、再超时：反馈一直待转，59 秒内不重试、2 分钟内不再试；恢复后认领已建的那张，仓库里只有 1 张；退避封顶 1 小时（go test）' ;;
      *GOPROXY=off*|*'module lookup disabled'*|*'cannot find module'*|*'missing go.sum entry'*|*'requires go >= '*) ;;
      *) WHY="the Go half is red: $(printf '%s' "$out" | grep -v '^ok' | grep -v '^20' | head -6 | tr '\n' ' ')"; return 1 ;;
    esac
  fi
  SECS=$(since "$t0")
}

# ---- feedback-reply-lost (#3359, EPIC #3354 C5): a feedback's issue is closed
# and what the closing said never reaches the person — the session they sent it
# from is gone, their machine is down — or reaches them twice. The hub closes a
# row once, sends until a node says succeeded (then never again), tries the
# person's other live sessions when the first is gone, keeps it 30 days; the
# node delivers the desk's prefix to any session's inbox, never the bridge.
drill_feedback_reply_lost() {
  CAP=120; local t0 out rc f="$ROOT/tokenledger/internal/api/fleet_feedback_reply.go"
  local tests='TestFeedbackReplyClosedSendsOnce|TestFeedbackReplyWaitsForNextSession|TestFeedbackReplyFailedSessionTriesNext|TestFeedbackReplyExpiresAfter30Days|TestFeedbackReplyPrefixIsTheDesks'
  t0=$(now)
  grep -q 'if ok, err := s.Store.SetFeedbackReplied(f.ID, now); err != nil' "$f" 2>/dev/null \
    || { WHY="a reply no longer writes replied_at when its node says succeeded"; return 1; }
  grep -q 'feedbackReplyKeep      = 30 \* 24 \* time.Hour' "$f" || { WHY="a waiting reply is no longer kept 30 days"; return 1; }
  grep -q 'if action == "worker_message" and actor == FEEDBACK_ACTOR and params\["text"\].startswith(FEEDBACK_PREFIX):' \
    "$BIN/fleet_control.py" || { WHY="the node no longer hands the desk's reply to any session's inbox"; return 1; }
  local tn; for tn in $(printf '%s' "$tests" | tr '|' ' '); do
    grep -q "^func $tn(" "$ROOT/tokenledger/internal/api/fleet_feedback_reply_test.go" 2>/dev/null \
      || { WHY="the hub half's test $tn is not in tokenledger/internal/api/fleet_feedback_reply_test.go"; return 1; }
  done
  WHAT='关单 ⇒ 送一次；会话已关 ⇒ 存着，他下一个会话上线时送一次；30 天过期不送；重复关单不重复送（测试按名核对在，Go 门跑它们）'
  if [ "${BREAK_GO:-1}" != 0 ] && command -v go >/dev/null 2>&1; then
    out=$(cd "$ROOT/tokenledger" && GOFLAGS=-mod=mod GOPROXY=off GOTOOLCHAIN=local \
          go test -count=1 -run "^($tests)\$" ./internal/api 2>&1); rc=$?
    case "$rc:$out" in
      0:*'no tests to run'*) WHY="the Go tests are not there (go test ran none)"; return 1 ;;
      0:*) WHAT='假 GitHub 关单、假节点收信：关单送一次、重开再关不再送；原会话不在 ⇒ 存着，他另一台机器上的会话上线后送一次；原会话拒收 ⇒ 换下一个；30 天前关的不送；别人冒用前缀 403（go test）' ;;
      *GOPROXY=off*|*'module lookup disabled'*|*'cannot find module'*|*'missing go.sum entry'*|*'requires go >= '*) ;;
      *) WHY="the Go half is red: $(printf '%s' "$out" | grep -v '^ok' | grep -v '^20' | head -6 | tr '\n' ' ')"; return 1 ;;
    esac
  fi
  SECS=$(since "$t0")
}

# ---- feedback-secret-in-text / feedback-secret-in-attach (#3358, EPIC #3354 C4):
# a person pastes a token into /fleet-feedback, or the log / screen they agree to
# attach holds one. bin/fleet-feedback.sh runs for real against a fake hub (a curl
# that writes down every byte of every part): no sample of the shape table may be
# in what leaves the machine, nor in what the outbox keeps when the hub is away.
_fb_drill() {  # _fb_drill <dir> <words> <log line> <screen line> <attach yes|no>
  local d="$1" a=''
  mkdir -p "$d/home" "$d/conf" "$d/tmp" "$d/cache/claude-fleet/shell/logs"
  printf 'CCQUOTA_HUB_URL=https://hub.example\nCCQUOTA_TOKEN=FAKEnode\n' > "$d/conf/node.env"
  printf '%s\n' "$3" > "$d/cache/claude-fleet/shell/logs/connect.log"
  cat > "$d/curl" <<SH
#!/bin/bash
prev=''
for a in "\$@"; do
  if [ "\$prev" = -F ]; then v=\${a#*=}; v=\${v%%;*}; case "\$v" in '<'*|'@'*) cat "\${v#?}" ;; *) printf '%s' "\$v" ;; esac; fi
  prev=\$a
done >> "$d/sent"
[ -f "$d/away" ] && exit 7
printf '{"id":"F1","state":"received"}\n200'
SH
  chmod +x "$d/curl"
  [ "$5" = yes ] && a=--attach
  for mode in up away; do
    [ "$mode" = away ] && : > "$d/away"
    ( unset CCQUOTA_TOKEN CCQUOTA_HUB_URL FLEET_HUB_URL TMUX TMUX_PANE
      export HOME="$d/home" FLEET_CONF_DIR="$d/conf" XDG_CACHE_HOME="$d/cache" TMPDIR="$d/tmp" \
             FLEET_HUB_CURL="$d/curl" FLEET_FEEDBACK_MACHINE_KIND=managed-linux \
             FLEET_FEEDBACK_SCREEN_CMD="printf '%s\n' '$4'"
      printf '%s\n' "$2" | bash "$BIN/fleet-feedback.sh" send ${a:+"$a"} - >/dev/null 2>&1 ) || :
  done
}
drill_feedback_secret_in_text() {
  CAP=30; local d="$WORK/fbt" t0 v left=''
  set -- ghp_FAKEfbaaaaaaaaaaaaaaa github_pat_11FAKEfbbbbbbbbbbbb sk-ant-api03-FAKEfbcccccc glpat-FAKEfbdddddd \
         xoxb-FAKEfbeeeeee AKIAFAKEFBFFFFFFFFFF eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJmYiJ9.FAKEsig
  t0=$(now)
  _fb_drill "$d" "⌘P 慢，顺手贴了 $* 和 DB_PASSWORD=FAKEfbpass" 'nothing here' 'nothing here' no
  [ -s "$d/sent" ] || { WHY="fleet-feedback.sh sent nothing at all"; return 1; }
  [ -n "$(ls "$d/conf/feedback-outbox" 2>/dev/null)" ] || { WHY="an unreachable hub kept nothing in the outbox"; return 1; }
  for v in "$@" FAKEfbpass; do
    grep -qF -e "$v" "$d/sent" && left="$left sent:$v"
    grep -rqF -e "$v" "$d/conf/feedback-outbox" && left="$left outbox:$v"
  done
  SECS=$(since "$t0")
  [ -z "$left" ] || { WHY="credentials left in the feedback:$left"; return 1; }
  grep -q '<redacted:github>' "$d/sent" || { WHY="the words went out without their mask"; return 1; }
  WHAT='原话里贴了七类假凭据 + 一个密码：发出的字节和入口不在时本机存下的都一处不剩'
}
drill_feedback_secret_in_attach() {
  CAP=30; local d="$WORK/fba" t0 v left='' L=sk-ant-api03-FAKEfblogaaaa S=ghp_FAKEfbscreenbbbbbbbb
  t0=$(now)
  _fb_drill "$d" '附上日志和屏幕' "relay token Authorization: Bearer FAKEfbbearer $L" "prompt> export GH=$S" yes
  grep -q 'prompt> export' "$d/sent" || { WHY="the screen was not attached"; return 1; }
  grep -q 'relay token' "$d/sent" || { WHY="the log was not attached"; return 1; }
  for v in "$L" "$S" FAKEfbbearer; do
    grep -qF -e "$v" "$d/sent" && left="$left sent:$v"
    grep -rqF -e "$v" "$d/conf/feedback-outbox" && left="$left outbox:$v"
  done
  SECS=$(since "$t0")
  [ -z "$left" ] || { WHY="credentials left in the attachments:$left"; return 1; }
  WHAT='附上的日志和屏幕各塞假凭据：发出的附件和本机存下待补发的一处不剩'
}

# ---- pool-usage-node-dropped (#3376, EPIC #3225 C1's patch): a login's local
# proxy's usage. The hub dropped the whole report when no person was mapped to
# the login — nothing written, nothing said — and filed the rest as one row a
# provider: no session, no model, no cache split, all of it 「没挂在任务上」.
# Now the hub resolves the login's owner like every node read (principalOnNode:
# the machine's account, else the login row bound to this endpoint); with none,
# nothing is written (no ownerless rows) but pool_usage_unowned is raised, and
# cleared by the first report that files. The proxy reports one entry per
# (provider, session's worker_id, account, model) with the split, the session
# named by the worker_id its launcher minted it for; the hub freezes repo /
# issue from that session's lease. An old proxy's aggregate is filed as before.
drill_pool_usage_node_dropped() {
  CAP=120; local t0 out rc t
  local api_tests='TestPoolUsageNodeReportAndNoOwnerless TestPoolUsageNodeReportPerSession TestPersonBudgetNode'
  local tl="$ROOT/tokenledger/internal"
  t0=$(now)
  grep -q 's.unownedUsage(ep, host, user, rep, now)' "$tl/api/fleet_person_budget.go" 2>/dev/null \
    || { WHY="the hub drops a node report from a login with no person in silence again"; return 1; }
  grep -q 'principal, err := s.principalOnNode(ep.ID, host, user)' "$tl/api/fleet_person_budget.go" \
    || { WHY="the node usage report no longer finds the login's owner the way every node read does"; return 1; }
  grep -q 's.Store.LeaseForWorker(e.WorkerID, now)' "$tl/api/fleet_person_budget.go" \
    || { WHY="a node report's session row no longer takes its task from the session's lease"; return 1; }
  grep -q 'self.budget.add(provider, extra\["tokens"\], split, self.budget.worker(sid), acct, meter.model)' "$ROOT/bin/fleet-cred-proxy.py" \
    || { WHY="the local proxy no longer meters each answer under its session, account and model"; return 1; }
  grep -q 'wid=$(session_worker)' "$ROOT/bin/fleet-session-cred.sh" \
    || { WHY="the launcher no longer names the session's worker_id when the proxy mints its pass"; return 1; }
  for t in $api_tests; do
    grep -q "^func $t(" "$tl/api/pool_usage_test.go" "$tl/api/fleet_person_budget_test.go" 2>/dev/null \
      || { WHY="the hub half's test $t is not in tokenledger/internal/api"; return 1; }
  done
  WHAT='节点代理的用量：登录没对应到人 → 不写无主行、记 pool_usage_unowned 告警；按会话（worker_id · 订阅 · 模型 · 分项）上报，repo/issue 取自租约；旧代理的汇总照记（测试按名核对在，Go 门跑它们）'
  if [ "${BREAK_GO:-1}" != 0 ] && command -v go >/dev/null 2>&1; then
    out=$(cd "$ROOT/tokenledger" && GOFLAGS=-mod=mod GOPROXY=off GOTOOLCHAIN=local \
          go test -count=1 -run "^($(printf '%s' "$api_tests" | tr ' ' '|'))\$" ./internal/api 2>&1); rc=$?
    case "$rc:$out" in
      0:*'no tests to run'*) WHY="the Go tests are not there (go test ran none)"; return 1 ;;
      0:*) WHAT='节点代理的用量：无主登录告警不丢、按会话分行且 repo/issue 取自租约、个人上限累计与旧汇总相等（go test）' ;;
      *GOPROXY=off*|*'module lookup disabled'*|*'cannot find module'*|*'missing go.sum entry'*|*'requires go >= '*) ;;
      *) WHY="the Go half is red: $(printf '%s' "$out" | grep -v '^ok' | head -6 | tr '\n' ' ')"; return 1 ;;
    esac
  fi
  SECS=$(since "$t0")
}

# ---- account-gh-only-check (#3603, EPIC #3570 C10): a person was a GitHub
# account — every "is this a person" asked `gh:`, so someone with only an
# address was nobody: no invite, no machine, no certificate. Now one isPerson,
# a principal any way of signing in leads to, and the old gh: people kept.
drill_account_gh_only_check() {
  CAP=120; local t0 out rc tests tl="$ROOT/tokenledger/internal"
  tests='TestNoGHPrefixOutsideIdentity TestPAccountInviteMachineCert TestMigrationKeepsGitHubPerson TestMeIdentities TestAdminsByPrincipalOrAddress'
  t0=$(now)
  for out in $tests; do
    grep -q "^func $out(" "$tl/api/person_test.go" 2>/dev/null || { WHY="the hub half's test $out is not in internal/api/person_test.go"; return 1; }
  done
  grep -q '^func isPerson(principal string) bool' "$tl/api/person.go" 2>/dev/null \
    || { WHY="there is no one isPerson any more"; return 1; }
  # "gh:" outside tests, ticket ids (共同约定 1) and comments
  out=$(grep -n '"gh:"' "$tl"/api/*.go | grep -v '_test.go:' | grep -v 'fleet_tickets.go:' | grep -v '^[^:]*:[0-9]*:[[:space:]]*//')
  [ -z "$out" ] || { WHY="a principal is judged by its gh: spelling again: $(printf '%s' "$out" | head -2 | sed "s|$tl/||" | tr '\n' ' ')"; return 1; }
  WHAT='没有 GitHub 的人：邀请（绑邮箱）→ 登录 → 绑机器 → 发证书 → 自己的 /v1/me；老 GitHub 人迁移前后快照一致；「是不是一个人」只问 isPerson（测试按名核对在，Go 门跑它们）'
  if [ "${BREAK_GO:-1}" != 0 ] && command -v go >/dev/null 2>&1; then
    out=$(cd "$ROOT/tokenledger" && GOFLAGS=-mod=mod GOPROXY=off GOTOOLCHAIN=local \
          go test -count=1 -run "^($(printf '%s' "$tests" | tr ' ' '|'))\$" ./internal/api 2>&1); rc=$?
    case "$rc:$out" in
      0:*'no tests to run'*) WHY="the hub half's Go tests are not there (go test ran none)"; return 1 ;;
      0:*) WHAT='没有 GitHub 的人走完邀请 → 绑机器 → 发证书；老 GitHub 人迁移前后会话 / 机器 / 证书 / 单子快照一致；全仓 "gh:" 只剩 GitHub 身份一处（go test 五条）' ;;
      *GOPROXY=off*|*'module lookup disabled'*|*'cannot find module'*|*'missing go.sum entry'*|*'requires go >= '*) ;;
      *) WHY="the hub half (go test) is red: $(printf '%s' "$out" | grep -v '^ok' | head -6 | tr '\n' ' ')"; return 1 ;;
    esac
  fi
  SECS=$(since "$t0")
}

# c11_go_tests <file> <tests…> — the shared half of the C11 drills: every
# named test is in <file>, and (with a toolchain) go test runs them green.
c11_go_tests() {
  local file="$1" t out rc tl="$ROOT/tokenledger/internal"; shift
  for t in "$@"; do
    grep -q "^func $t(" "$tl/api/$file" 2>/dev/null || { WHY="the hub half's test $t is not in internal/api/$file"; return 1; }
  done
  if [ "${BREAK_GO:-1}" != 0 ] && command -v go >/dev/null 2>&1; then
    out=$(cd "$ROOT/tokenledger" && GOFLAGS=-mod=mod GOPROXY=off GOTOOLCHAIN=local \
          go test -count=1 -run "^($(printf '%s' "$*" | tr ' ' '|'))\$" ./internal/api 2>&1); rc=$?
    case "$rc:$out" in
      0:*'no tests to run'*) WHY="the hub half's Go tests are not there (go test ran none)"; return 1 ;;
      0:*) GO_RAN=1 ;;
      *GOPROXY=off*|*'module lookup disabled'*|*'cannot find module'*|*'missing go.sum entry'*|*'requires go >= '*) ;;
      *) WHY="the hub half (go test) is red: $(printf '%s' "$out" | grep -v '^ok' | head -6 | tr '\n' ' ')"; return 1 ;;
    esac
  fi
}

drill_wechat_first_scan_autocreate() {
  CAP=120; local t0 tl="$ROOT/tokenledger/internal"; GO_RAN=0
  t0=$(now)
  # The first scan's branch hands off to the binding page and nothing else.
  grep -q 'http.Redirect(w, r, "/auth/wechat/bind", http.StatusFound)' "$tl/api/wechat_auth.go" 2>/dev/null \
    || { WHY="the first scan no longer goes to the binding page (wechat_auth.go)"; return 1; }
  c11_go_tests signin_ways_test.go TestWeChatFirstScanOpensNoAccount TestWeChatTwoRoadsOnePerson TestWeChatStateReplayRefused || return 1
  WHAT='第一次扫码进绑定页：不登录、不开号；按「挂上」或「按邀请进入」才动（测试按名核对在，Go 门跑它们）'
  [ "$GO_RAN" = 1 ] && WHAT='第一次扫码不开号、只在按下时绑到已登录的人或邀请；两条路同一 unionid 同一人；state 重放被拒（go test 三条）'
  SECS=$(since "$t0")
}

drill_email_link_replay() {
  CAP=120; local t0 tl="$ROOT/tokenledger/internal"; GO_RAN=0
  t0=$(now)
  grep -q 'UseSigninCode(c.ID, now)' "$tl/api/email_auth.go" 2>/dev/null \
    || { WHY="the mail's link / code is no longer spent once (email_auth.go)"; return 1; }
  grep -q 'CREATE TABLE IF NOT EXISTS hub_signin_codes' "$tl/store/schema.sql" 2>/dev/null \
    || { WHY="the mail codes are not kept where both replicas see them (hub_signin_codes)"; return 1; }
  c11_go_tests signin_ways_test.go TestEmailSignIn TestEmailCode TestEmailInviteAndAdd || return 1
  WHAT='登录邮件的链接只在发起的浏览器里用一次；码猜 5 次即废；未知邮箱答复相同（测试按名核对在，Go 门跑它们）'
  [ "$GO_RAN" = 1 ] && WHAT='链接重放被拒、另一台设备打不开、码猜 5 次即废、未知邮箱同答同限流、邀请与加邮箱（go test 三条）'
  SECS=$(since "$t0")
}

cred_run_drills "$0"
