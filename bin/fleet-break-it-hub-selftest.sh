#!/bin/bash
# selftest-parts: 3 BREAK_PART
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
#   release-key-outside-train                       bin/fleet-release-key.sh scan (fleet-release-sign.py scan),
#                                                   fleet-doctor.sh (releasekey), release-train.yml; the hub
#                                                   half is fleet_release_sign.go (go test, when a toolchain is)
#   release-key-revoked                             bin/fleet-release-verify.py (trust), fleet-release-fetch.py;
#                                                   tokenledger/shared/release trust.go (go test, when a toolchain is)
#   node-tmux-restart                               bin/fleet-sessions-snapshot.sh → fleet-restore.sh
#   empty-fleet-not-restored                        bin/fleet-sessions-snapshot.sh, fleet-restore.sh --auto
#   empty-fleet-disk-floor                          bin/fleet-restore.sh home_floor_gb, fleet-sessions-snapshot-selftest.sh H2
#   switch-no-session-save                          bin/fleet-node-update.py (one switch, no login entered), conf/home-inputs.list
#   release-unverified                              bin/fleet-release.sh (fleet-release-selftest.sh's sandbox)
#   hub-release-downtime                            .github/actions/hub-release/probe.sh (downtime_seconds),
#                                                   release.sh shape, deploy/k8s/base (2 replicas, rolling,
#                                                   /readyz, preStop, PDB), tokenledger /readyz + /v1/deploy-probe
#                                                   (go test, when a toolchain is here); the kind drill is
#                                                   .github/workflows/hub-rolling.yml
#   hub-disk-attach-stuck                           deploy/k8s/base (no PVC), components/sqlite-single,
#                                                   overlays/prod (only RWX OSS claims) when FLEET_DEPLOY_K8S lays it here
#   hub-shape-extra-volume                          .github/actions/hub-release/release.sh shape (the data disk is
#                                                   the claim mounted at /data, not any PVC)
#   hub-read-refused-silent                         bin/fleet-account.sh (quota_budget_json), fleet-lib.sh
#                                                   (fleet_hub_auth_note), fleet-doctor.sh (hubauth)
#   node-person-cert-expired                        bin/fleet-hub-write.sh (the node-token door), fleet-lib.sh
#                                                   (fleet_node_pair, fleet_hub_reap), fleet-doctor.sh (personcert);
#                                                   tokenledger/hub/api fleet_write_signed.go (go test)
#   node-paused-still-placed                        bin/fleet-control-read.sh capacity (admit / admit_why / room),
#                                                   fleet_machine_admit, fleet_machine_headroom; the hub half is
#                                                   tokenledger/hub/api judge() (go test, when a toolchain is here)
#   dispatch-wrong-replica                          tokenledger/hub/api node_route.go (fleet_node_conns +
#                                                   /internal/v1/node-write; go test, when a toolchain is here)
#   cred-user-pod-unlisted                          tokenledger/hub/api fleet_cred_policy.go
#                                                   (userPodNodeAllow; go test, when a toolchain is here)
#   two-hubs-double-refresh                         tokenledger/hub/leader (Leader / Lock), credvault Lease's
#                                                   CrossLock, the three gated loops (go test, when a toolchain is here)
#   github-signin-unreachable                       tokenledger/hub/api github_auth.go (githubExchange) +
#                                                   fleet_relay_cred.go (the /github-oauth/ gate); go test, when a
#                                                   toolchain is here; extras/cred-relay/Caddyfile, overlays/prod
#   entry-dns-follows                               tokenledger/hub/api fleet_entry_dns.go + hub/dns
#                                                   (DNSPod; go test, when a toolchain is here), deploy/k8s/overlays/prod
#   entry-name-unclaimed                            tokenledger/hub/api fleet_entry.go (entryEnsureName) +
#                                                   fleet_entry_dns.go (the *.cf guard); go test, when a toolchain is here
#   account-gh-only-check                           tokenledger/hub/api person.go (isPerson, personRow,
#                                                   personRole, admitPerson) + hub/store hub_users.go
#                                                   (hub_identities, migration 2); go test, when a toolchain is here
#   wechat-first-scan-autocreate                    tokenledger/hub/api wechat_auth.go (handleWeChatCallback,
#                                                   handleWeChatBind) + signin_ways.go; go test, when a toolchain is here
#   fleet-scene-cross                               tokenledger/hub/api wx_scan.go (wxScene, wxScenePoll,
#                                                   wxFinishLogin) + wxgw.go (wxSceneInRange) + hub/store
#                                                   hub_wx_scenes.go; go test, when a toolchain is here
#   wx-relay-forged                                 tokenledger/hub/api wx_relay.go (wxRelayStart,
#                                                   handleWxRelayCB, wxRelaySig) + wx_scan.go (wxLand); go test,
#                                                   when a toolchain is here
#   email-link-replay                               tokenledger/hub/api email_auth.go (handleEmailLink /
#                                                   handleEmailCode) + hub/store hub_signin.go; go test, when here
#   node-token-replayed                             tokenledger/hub/api node_sig.go (nodeAuth) + store,
#                                                   shared/nodesig (Ensure), every door's nodeAuth (#3710)
#                                                   fleet_node_keys.go; bin/fleet_node_sig.py; go test, when here
#   invite-expired                                  tokenledger/hub/api fleet_invites.go + github_auth.go
#                                                   (admitInvite, denyText; go test, when a toolchain is here)
#   remove-pending-machine-gone                     tokenledger/hub/api fleet_account_gone.go (forget
#                                                   machine_gone) + hub/store fleet_accounts.go
#                                                   (CloseAccountMachineGone); bin/fleet-hub-admin.py --machine-gone;
#                                                   go test, when a toolchain is here
#   spare-login-empty                               tokenledger/hub/api fleet_spare.go + fleet_accounts.go
#   spare-stall-silent                              tokenledger/hub/api fleet_spare_alerts.go (SpareAlertTick)
#   spare-refill-session-gate                       tokenledger/hub/api fleet_spare.go (spareMachines; go test, when here)
#                                                   (claimSpare, replenishSpares; go test, when a toolchain is here)
#   lease-unseparated-user                          tokenledger/hub/api fleet_creds.go (credsepGated) + fleet_join.go
#                                                   (/v1/node/self credsep_gate), tokenledger/agent node_credsep.go,
#                                                   bin/fleet-cred-proxy.py (Router.refresh); go test, when a toolchain is here
#   trust-name-borrowed                             tokenledger/hub/api fleet_trust.go (nodeTrust) + fleet_node_desired.go
#                                                   (go test, when a toolchain is here)
#   release-tampered                                tokenledger/hub/api fleet_release.go (ReleaseStore) +
#                                                   shared/release (Build, Fetch, Unpack; go test, when a toolchain is here)
#   machine-agent-wrong-login                       tokenledger/hub/api node_machine.go (loginEndpoint, serveMachine)
#                                                   + tokenledger/agent node_machine.go / runas.go (go test, when a toolchain is here)
#   usage-unattributed                              tokenledger/agent (the claude:local pool) + hub/api
#                                                   fleet_usage_silent.go (usage_silent; go test, when a toolchain is here)
#   pool-usage-unattributed                         tokenledger/hub/api fleet_person_budget.go (handleCredProxyUsage,
#                                                   poolUsagePass) + hub/store pool_usage.go + shared/credproxy
#                                                   usage.go (go test, when a toolchain is here)
#   pool-usage-silent                               tokenledger/hub/api fleet_pool_usage_silent.go (notePoolResolve,
#                                                   PoolUsageSilentTick) + fleet_credproxy.go (resolve) + hub/store
#                                                   pool_usage.go (PoolUsageLastAt; go test, when a toolchain is here)
#   pool-usage-node-dropped                         tokenledger/hub/api fleet_person_budget.go (handleNodeUsage,
#                                                   recordUsage, unownedUsage) + bin/fleet-cred-proxy.py (Budget,
#                                                   Meter.split) + bin/fleet-session-cred.sh (--worker; go test, when a toolchain is here)
#   place-server-down                               fleet_server_down (fleet-lib.sh), fleet-control-read.sh start
#                                                   (exit 8), fleet_control.py (UNAVAILABLE); the hub half is
#                                                   tokenledger/hub/api pickNodeAfter (go test, when here)
#   pool-admit-phantoms                             fleet_session_cap_ok / fleet_admit_reserve / fleet_admit_confirm /
#                                                   fleet_admit_release / fleet_admit_holders (fleet-lib.sh)
#   guide-admission-room                            fleet_machine_admit / _fleet_admit_guide_pass / fleet_guide_tick
#                                                   (fleet-lib.sh), dash-raw-session.sh, fleet-alerts.sh event
#   admit-room-advice                               fleet_machine_admit / _fleet_admit_room_advice /
#                                                   fleet_admit_room_advised (fleet-lib.sh), fleet-control-read.sh
#                                                   capacity; the hub half is fleet_client_place.go pinnedFull (go test)
#   admit-open-window-twice                         fleet_machine_admit / fleet_admit_pending / _fleet_admit_advice_left
#                                                   (fleet-lib.sh), dash-raw-session.sh (the hub's worker_start)
#   linux-admit-host-load                           fleet_machine_admit / _fleet_admit_cpu / _fleet_cgroup_cpu
#                                                   (fleet-lib.sh) on a sandbox cgroup + machine reading
#   linux-admit-burst                               fleet_machine_admit / _fleet_admit_cpu / _fleet_cgroup_cpu_window
#   linux-admit-pod-start                           fleet_machine_admit / fleet_session_cap_ok / _fleet_admit_cpu_advice_note
#                                                   (fleet-lib.sh) on a sandbox cgroup whose counters move
#   mac-admit-load-not-busy                         fleet_machine_admit / _fleet_cpu_busy (fleet-lib.sh),
#                                                   fleet-machine-tasks.py probe (cpu_busy), fleet-control-read.sh capacity
#   pod-disk-node-tmp                               fleet_disk_target (fleet-lib.sh), fleet-diskguard.sh --free /
#                                                   --gate, fleet-alerts.sh (a df shim)
#   hubsess-daemon-nohup                            bin/fleet-hub-sessions.sh (ensure: no nohup; the lock)
#   dist-no-github                                  bin/dist-no-github-selftest.sh (GitHub a black hole: install-sync,
#                                                   client stage, login bootstrap, the updater's follow → the new version)
#   dist-bad-signature                              bin/dist-no-github-selftest.sh bad-signature (the hub's release
#                                                   refused by ccquota → fetch-failed, still the old version, no GitHub)
#   bootstrap-reaches-github                        bin/dist-no-github-selftest.sh --strict bootstrap bootstrap-hub
#                                                   (a new login on a managed machine / with only a hub: no GitHub, #2775)
#   hub-stream-silent                               extras/web-console/src/shared/sessions.ts (watchdog, backoff, poll
#                                                   fallback, by name) + hub/api fleet_stream.go (ping, scope;
#                                                   go test, when a toolchain is here)
#   service-log-cross-login                         tokenledger/hub/api fleet_service_log.go (FleetScope before any
#                                                   node read, one follow per service, masking; go test, when a toolchain
#                                                   is here) + tokenledger/agent node_service_log.go (the register's path only)
#                                                   + the console's ServiceSheet.tsx (403 is a word, by name)
#   dist-publish-tampered                           tokenledger/hub/api fleet_publish.go (POST …/publish: the archive
#                                                   hashed into the commit's tree, OIDC, forward only; go test, when a
#                                                   toolchain is here) + bin/fleet-release-publish.sh (what CI sends)
#   cred-policy-empties-machine                     tokenledger/hub/api fleet_cred_policy.go (credPolicyEmptied,
#                                                   force) + fleet_credproxy.go (noBindWhy); go test, when a toolchain
#                                                   is here; bin/fleet-cred-policy.sh (exit 5, --force), the web editor
#   machine-policy-bypass                           tokenledger/hub/api fleet_machine_policy.go (machineDenied at
#                                                   every door: certs/routes/relay/home, entry keys, placement, lease,
#                                                   session pass, relay cred, fleet_sessions; go test, when a toolchain
#                                                   is here); bin/fleet-machine-policy.sh, fleet-hub-sessions.sh (the
#                                                   disabled row), fleet-connect.py (disabled_die)
#   svc-token-escalate                              tokenledger/hub/api svc.go (svcGate / svcOnly on /v1/svc/,
#                                                   fcs_ tokens hash-only, revoke 401 at the next call; go test, when a
#                                                   toolchain is here), cmd/ccquota/svc.go
#   apply-flood                                     tokenledger/hub/store access_requests.go (the one-pending
#                                                   partial unique index) + hub/api access_requests.go (409, the
#                                                   per-address limit); go test, when a toolchain is here
#   apply-reaches-app                               tokenledger/hub/api not_listed.go + applicant.go (the not-listed
#                                                   sign-ins mint ccq_applicant, Path /apply, read only by
#                                                   applicantFrom); go test, when a toolchain is here
#   notify-leaks-secret                             tokenledger/hub/api wxgw.go (the gate read in one place, errcode
#                                                   only) + notify.go (the one way out: audit / outbox / mail / template
#                                                   carry no secret); go test, when a toolchain is here
#   svc-usage-crosses-tenant                        tokenledger/hub/api svc_usage.go (tenant on the run's pass and
#                                                   pool_usage, fleet.svc_budget / svc_tenant_budget, svcYield,
#                                                   GET /v1/svc/usage; go test, when a toolchain is here)
#   trial-transcript-cross                          tokenledger/hub/api fleet_try_slot.go (trialKeepConvo /
#                                                   trialSeed: sealed per principal, opened only as the session's own)
#                                                   + credvault SealPerson + extras/web-chat server.mjs (/api/export,
#                                                   /api/import); go test when a toolchain is here, node for the webchat
#   trial-dirty-handout                             tokenledger/hub/api fleet_try_budget.go (endTrial → remove →
#                                                   #3504's reset, trialGiveBack → store.HandOffWash) + fleet_recycle.go
#                                                   applyReset; go test
#   trial-pause-not-recycled                        tokenledger/hub/api fleet_try_budget.go (trialWashable: a failed
#                                                   / unknown seat goes back too; SweepTrialStragglers off the patrol)
#                                                   + hub/store fleet_trials.go (ReclaimedTrialsHolding); go test
#   trial-slot-held                                 tokenledger/hub/api fleet_try_slot.go (SweepTrialSlots on the
#                                                   15 s alerts tick: hidden 120 · idle 240, + #4059's budget); go test
#   trial-idle-while-opening                        tokenledger/hub/api fleet_try_slot.go (trialSlotVerdict: idle
#                                                   from ready_at, open_slow 300 → store.RequeueTrial); go test
#   spare-ready-unverified                          bin/fleet-login-ready.sh (cred · home · reply, as the login) ←
#                                                   fleet-login-new.sh 8c / fleet-login-reset.sh → the agent's readyResult →
#                                                   tokenledger fleet_spare.go (recordAccountCheck / spareChecked) + store
#                                                   ClaimSpare's spareCheckedSQL; the script for real, go test
#   spare-ready-lease-inflight                      tokenledger/hub/api fleet_login_node.go (principalForLease /
#                                                   leaseInFlight on the lease · session-pass · relay roads) + store
#                                                   AccountOpInFlight; go test
#   trial-no-subscription                           tokenledger/hub/api fleet_trial_cred.go (trialUserAllow in
#                                                   credPolicyFor: fleet.trial.cred_allow; [] ⇒ trialHold nosub;
#                                                   convertTrial writes the member's own list); go test
#   cluster-pod-claude-leak                         tokenledger/hub/api fleet_cred_pod.go (podProvidersOf in
#                                                   credPolicyOf: fleet.cred_pod_providers, default codex, on u-* /
#                                                   fleet-linux-*); go test, when a toolchain is here
#   trial-host-no-spare                             tokenledger/hub/api fleet_accounts.go (trialMachine: only
#                                                   machines with a ready spare) + fleet_try.go (no_spare,
#                                                   trial_no_spare); go test, when a toolchain is here
#
# Each prints `PASS <id> <secs>s ≤<cap>s <what came back>` like its parent.
# BREAK_KEEP=1 keeps the work dir; BREAK_ONLY narrows to those ids.
# shellcheck disable=SC2034  # CAP / SECS / WHY / WHAT are read by the sourced runner
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=fleet-break-it-cred-selftest.sh
BREAK_CRED_LIB=1 . "$BIN/fleet-break-it-cred-selftest.sh"
# The deployment's own prod overlay (claude-fleet#3630): ours lives in a private
# deploy repo that hub-deploy lays over deploy/k8s. FLEET_DEPLOY_K8S names such a
# laid-over k8s/ tree; with none here the drills' prod clauses are skipped
# (hub-deploy's render-check.sh --need-prod renders it on every release).
PROD_K8S=${FLEET_DEPLOY_K8S:-$ROOT/deploy/k8s}
PROD_OVL="$PROD_K8S/overlays/prod"
PROD_GONE='生产覆盖层在私有部署仓库（#3630），这台没有：那一半由 hub-deploy 叠上后核对'

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
  go_half '^(TestReadyzAndDeployProbe|TestReadyFollowsTheMigrations|TestShutdownGrace)$' ./hub/api ./hub/store ./hub/cmd/ccquota; case $? in
    0) WHAT="停 ~3 秒的发布读出 downtime_seconds=${down1}；一直在的读 0；base 两份滚动 + /readyz + preStop + PDB；/readyz 与写探测、关停宽限 go test 绿；真两份 + Postgres 的三次发布 / 删 pod / 回退在 CI hub-rolling" ;;
    1) return 1 ;;
    2) WHAT='探测读数对（停 ~3 秒 ≥2、一直在 0）；base 是滚动形态；入口的 Go 测试在这台没有模块缓存——Go 门跑它们' ;;
    3) WHAT='探测读数对（停 ~3 秒 ≥2、一直在 0）；base 是滚动形态；没有 go：Go 门跑 /readyz 测试' ;;
  esac
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
    if [ ! -f "$PROD_OVL/kustomization.yaml" ]; then
      WHAT="base 的渲染没有盘（库在 Postgres），盘只在单份形态的组件里（回滚用）；$PROD_GONE"; SECS=$(since "$t0"); return 0
    fi
    r=$(kubectl kustomize "$PROD_OVL" 2>/dev/null) || { WHY="the prod overlay does not render"; return 1; }
    case "$r" in *"kind: PersistentVolumeClaim"*) WHY="prod still mounts a disk after the switch (the render creates a claim)"; return 1 ;; esac
    # A claim prod mounts is no cloud disk only when the overlay declares it as
    # an RWX OSS volume (ossfs: a network mount, nothing to detach/attach) — the
    # /releases volume of #2366; any other claim is a disk that can stick.
    local cl pv nr=0
    for cl in $(printf '%s\n' "$r" | sed -n 's/^[[:space:]]*claimName:[[:space:]]*//p'); do
      pv=$(grep -l "^  name: $cl\$" "$PROD_OVL"/*.yaml 2>/dev/null | head -1)
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
  CAP=90; local t0
  t0=$(now)
  suite_holds fleet-sessions-snapshot-selftest.sh 'kill-server' || return 1
  SECS=$(since "$t0")
  WHAT="save → kill-server → restore：同名同目录同对话回来，已关单 / 已删目录 / fleet-down 的不开（fleet-sessions-snapshot-selftest.sh 真跑，这里按名守住）"
}

# A login with no session open (a China pod can run none, issue #4199): its fleet —
# the home the person views — comes back after a tmux restart all the same.
drill_empty_fleet_not_restored() {
  CAP=60; local t0 out
  sed -n '/^auto_restore()/,/^}/p' "$BIN/fleet-restore.sh" | grep -qF "grep -q '^WIN' \"\$mf\" || continue" \
    && { WHY="fleet-restore.sh --auto still skips a map with no WIN row"; return 1; }
  t0=$(now)
  out=$(FSS_ONLY=H bash "$BIN/fleet-sessions-snapshot-selftest.sh" 2>&1) \
    || { WHY="fleet-sessions-snapshot-selftest H: $(printf '%s' "$out" | grep -m1 FAIL)"; return 1; }
  SECS=$(since "$t0")
  WHAT="没会话的 fleet：save 留下 FLEET 行，kill-server → restore 拉回 home；fleet-down 的不拉；--auto 不跳过无 WIN 的图"
}

# A pod roll dips free disk under the load floor for minutes (issue #4266): an empty
# fleet's home — no load — passes only the ENOSPC floor on its way back.
drill_empty_fleet_disk_floor() {
  CAP=60; local t0 out
  grep -q '^home_floor_gb()' "$BIN/fleet-restore.sh" \
    || { WHY="fleet-restore.sh has no home_floor_gb — an empty fleet's home waits on the load floor"; return 1; }
  t0=$(now)
  out=$(FSS_ONLY=H bash "$BIN/fleet-sessions-snapshot-selftest.sh" 2>&1) \
    || { WHY="fleet-sessions-snapshot-selftest H2: $(printf '%s' "$out" | grep -m1 FAIL)"; return 1; }
  SECS=$(since "$t0")
  WHAT="空闲盘低于负载线（5 GB < 12）：没会话的 fleet 照样拉回 home，restore 和 --auto 都是；0 GB 不拉；有会话的仍挡"
}

drill_switch_no_session_save() {
  CAP=90; local t0 out
  t0=$(now)
  out=$(python3 -W ignore::ResourceWarning "$BIN/fleet-node-update-selftest.py" --drill-one-switch 2>&1) \
    || { WHY="fleet-node-update J_OneSwitch: $(printf '%s' "$out" | grep -m1 -E 'Error|FAIL')"; return 1; }
  SECS=$(since "$t0")
  WHAT="换版只切 current：会话不存不开，只改 bin/ 的一版不进任何登录，登录的 ~/.claude/fleet 已是新版"
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
  hrr bash "$BIN/fleet-account.sh" quota-verdict a --refresh >/dev/null 2>&1
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
# the steward on mac-c could not reap three finished workers on mac-d — the
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
  ln -s "$BIN/fleet-lib.sh" "$d/sb/fleet-lib.sh"; ln -s "$BIN/fleet-client-core.sh" "$d/sb/fleet-client-core.sh"; ln -s "$BIN/fleet-hub-write.sh" "$d/sb/fleet-hub-write.sh"
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
  go_half "^($tests)\$" ./hub/api; case $? in
    0) WHAT="${WHAT}；入口只认同一主人的会话、别人的 404、只放 worker 工具（go test）" ;;
    1) return 1 ;;
    3) grep -q "^func $tests(" "$ROOT/tokenledger/hub/api/fleet_write_tools_test.go" 2>/dev/null \
       || { WHY="the hub half's test $tests is not in fleet_write_tools_test.go"; return 1; } ;;
  esac
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
  case "$out" in *'"admit":false'*'"admit_why":"负载过高（负载 1.9/核）"'*'"room":'[1-9]*) ;; *)
    WHY="capacity under load 1.9/core does not say admit:false, admit_why 负载过高（负载 1.9/核） with its room: $out"; return 1 ;; esac
  out=$(cap 'echo 1 66 5 6' 'echo 0.5')
  case "$out" in *'"max_sessions":0'*'"admit":true'*'"room":'[1-9]*) ;; *)
    WHY="a healthy machine's capacity does not say admit:true with room ≥ 1: $out"; return 1 ;; esac
  case "$out" in *admit_why*) WHY="a healthy machine carries an admit_why: $out"; return 1 ;; esac
  out=$(cap 'echo 4 5 97 0' 'echo 9' FLEET_ADMIT=0)
  case "$out" in *'"admit":true'*) ;; *) WHY="FLEET_ADMIT=0 (the gate off) must say admit:true: $out"; return 1 ;; esac
  case "$out" in *'"room"'*) WHY="with FLEET_ADMIT=0 the beat still carries room — the hub would hold on it: $out"; return 1 ;; esac
  gohalf='hub half: the Go gate (tokenledger.yml) runs judge()'"'"'s tests'
  go_half 'TestNodePlace(SkipsPausedNode|AllPausedRefuses|WithoutCapFieldsFiltersNothing)$' ./hub/api; case $? in
    0) gohalf='hub half: go test TestNodePlace{SkipsPausedNode,AllPausedRefuses,WithoutCapFieldsFiltersNothing} ok' ;;
    1) return 1 ;;
    2) gohalf='hub half: no go module cache / toolchain here — the Go gate (tokenledger.yml) runs judge()'"'"'s tests' ;;
  esac
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
  f="$ROOT/tokenledger/hub/api/fleet_recent_test.go"
  t0=$(now)
  for out in $tests; do
    grep -q "^func $out(" "$f" 2>/dev/null || { WHY="the hub half's test $out is not in ${f#$ROOT/}"; return 1; }
  done
  grep -q 'recent' "$ROOT/tokenledger/hub/api/fleet_write.go" || { WHY="judge() does not read the recent table"; return 1; }
  go_half "^($(printf '%s' "$tests" | tr ' ' '|'))\$" ./hub/api; case $? in
    0) WHAT='入口连续派 4 个 → 两台各 2（go test 七条：分摊、90 秒过期、心跳抵消一次、room 先扣、拒掉即忘）' ;;
    1) return 1 ;;
    2) WHAT='入口的 Go 测试在这台没有模块缓存 / 工具链——Go 门（tokenledger.yml）跑它们；五条测试按名核对在' ;;
    3) WHAT='没有 go：五条测试按名核对在，Go 门（tokenledger.yml）跑它们' ;;
  esac
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
  f="$ROOT/tokenledger/hub/api/node_route_test.go"
  t0=$(now)
  for out in $tests; do
    grep -q "^func $out(" "$f" 2>/dev/null || { WHY="the hub half's test $out is not in ${f#$ROOT/}"; return 1; }
  done
  grep -q 'peerOf' "$ROOT/tokenledger/hub/api/fleet_write.go" || { WHY="the write path does not look for the replica holding the link"; return 1; }
  go_half "^($(printf '%s' "$tests" | tr ' ' '|'))\$" ./hub/api; case $? in
    0) WHAT='两份入口 × 两台机器 × 100 次派活全送达，重连到另一份照样送达（go test 五条：转发、持有方不在、令牌、单份不转发、配置）' ;;
    1) return 1 ;;
    2) WHAT='入口的 Go 测试在这台没有模块缓存 / 工具链——Go 门（tokenledger.yml）跑它们；六条测试按名核对在' ;;
    3) WHAT='没有 go：六条测试按名核对在，Go 门（tokenledger.yml）跑它们' ;;
  esac
  SECS=$(since "$t0")
}

# ---- cred-user-pod-unlisted (#4290): in strict mode a person's pod (u-<nonce>) the
# hub made or rebuilt had no machine allowlist, so every subscription was denied —
# every Codex turn 403 until someone listed the pod by hand. The fix is the hub's:
# with no list of its own the pod takes its owner's person list (a drill owner,
# its creator's). The drill is its Go test where a toolchain is, else by name.
drill_cred_user_pod_unlisted() {
  CAP=120; local t0 out rc f=$ROOT/tokenledger/hub/api/fleet_cred_policy_test.go
  t0=$(now)
  grep -q '^func TestCredPolicyStrictUserPodUsesOwnersList(' "$f" 2>/dev/null \
    || { WHY="the hub half's test TestCredPolicyStrictUserPodUsesOwnersList is not in ${f#$ROOT/}"; return 1; }
  grep -q 'userPodNodeAllow(settings' "$ROOT/tokenledger/hub/api/fleet_cred_policy.go" \
    || { WHY="credPolicyFor does not give a person's pod its owner's list"; return 1; }
  go_half '^(TestCredPolicyStrictUserPodUsesOwnersList)$' ./hub/api; case $? in
    0) WHAT='严格模式下没单独列的个人 pod 用主人的个人白名单，pod 自己的列表优先，普通机器不变（go test）' ;;
    1) return 1 ;;
    2) WHAT='入口的 Go 测试在这台没有模块缓存 / 工具链——Go 门（tokenledger.yml）跑它；测试按名核对在' ;;
    3) WHAT='没有 go：测试按名核对在，Go 门（tokenledger.yml）跑它' ;;
  esac
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
  f="$ROOT/tokenledger/hub/leader/leader_test.go"
  for tl in TestSingleHubAlwaysLeads TestTwoReplicasOneRunner TestCloseHandsOver TestLockAcrossReplicas; do
    grep -q "^func $tl(" "$f" 2>/dev/null || { WHY="the leader test $tl is not in ${f#$ROOT/}"; return 1; }
  done
  grep -q '^func TestTwoReplicasRefreshOnce(' "$ROOT/tokenledger/hub/credvault/credvault_test.go" 2>/dev/null \
    || { WHY="credvault has no TestTwoReplicasRefreshOnce"; return 1; }
  grep -q 'v.CrossLock(' "$ROOT/tokenledger/hub/credvault/credvault.go" || { WHY="Lease takes no cross-replica lock"; return 1; }
  grep -q 'Leader(ctx, "alerts")' "$ROOT/tokenledger/hub/api/fleet_alerts.go" || { WHY="node alerts are not gated on the leader"; return 1; }
  grep -q 'Leader(ctx, "prune")' "$ROOT/tokenledger/hub/cmd/ccquota/hub.go" || { WHY="the daily prune is not gated on the leader"; return 1; }
  go_half '^(TestTwoReplicasRefreshOnce|TestSingleHubAlwaysLeads)$' ./hub/credvault ./hub/leader; case $? in
    0) WHAT='两份保险箱同时租一个账号 → 只刷新一次（无跨副本锁时两次）；单份恒为 leader（go test）；两进程 Postgres 一小时只一份在干、交接 ≤15 s 在 Go 门 tokenledger-pg' ;;
    1) return 1 ;;
    2) WHAT='入口的 Go 测试在这台没有模块缓存 / 工具链——Go 门（tokenledger.yml）跑它们；测试与三处 Leader 门按名核对在' ;;
    3) WHAT='没有 go：测试与三处 Leader 门按名核对在，Go 门（tokenledger.yml）跑它们' ;;
  esac
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
  f="$ROOT/tokenledger/hub/api/github_oauth_relay_test.go"
  for tl in $tests; do
    grep -q "^func $tl(" "$f" 2>/dev/null || { WHY="the hub test $tl is not in ${f#$ROOT/}"; return 1; }
  done
  grep -q '^	handle /github-oauth/login/oauth/access_token {' "$ROOT/extras/cred-relay/Caddyfile" \
    || { WHY="the relay's Caddyfile has no /github-oauth/login/oauth/access_token route"; return 1; }
  grep -q '"/github-oauth/"' "$ROOT/extras/cred-relay/fleet-relay-check.py" \
    || { WHY="the relay's checker does not know the /github-oauth/ prefix"; return 1; }
  WHAT='github.com 不通 ⇒ 换令牌经转发机成功、日志写经中转；转发机连不上 / 拒通行证 / 不答 ⇒ 直连再试一次；两条都不通 ⇒ 原来那句提示、有上限；/github-oauth/ 只开那一条路径、只认 frh1.'
  if [ -f "$PROD_OVL/deployment-env.yaml" ]; then
    grep -A1 'name: CCQUOTA_GITHUB_OAUTH_VIA' "$PROD_OVL/deployment-env.yaml" | grep -q 'value: "relay"' \
      || { WHY="the prod overlay does not set CCQUOTA_GITHUB_OAUTH_VIA=relay"; return 1; }
  else
    WHAT="${WHAT}；$PROD_GONE"
  fi
  go_half "^($(printf '%s' "$tests" | tr ' ' '|'))\$" ./hub/api; case $? in
    0) WHAT="${WHAT}（go test 四条）" ;;
    1) return 1 ;;
    2) WHAT="${WHAT}；Go 测试这台没有模块缓存 / 工具链——Go 门（tokenledger.yml）跑它们" ;;
    3) WHAT="${WHAT}；没有 go：四条测试按名核对在，Go 门（tokenledger.yml）跑它们" ;;
  esac
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
    f="$ROOT/tokenledger/hub/api/fleet_entry_dns_test.go"
    grep -q "^func $tl(" "$f" 2>/dev/null || { WHY="the hub test $tl is not in ${f#$ROOT/}"; return 1; }
  done
  f="$ROOT/tokenledger/hub/dns/dnspod_test.go"
  grep -q '^func TestDNSPodProvider(' "$f" 2>/dev/null || { WHY="the provider test is not in ${f#$ROOT/}"; return 1; }
  grep -q 'Leader(ctx, "entry-dns")' "$ROOT/tokenledger/hub/api/fleet_entry_dns.go" \
    || { WHY="the address-record loop is not gated on the leader"; return 1; }
  if [ -f "$PROD_OVL/deployment-env.yaml" ]; then
    grep -q 'acme-dnspod' "$PROD_OVL/deployment-env.yaml" \
      || { WHY="the hub's deployment no longer reads the DNSPod token from new-deploy/acme-dnspod"; return 1; }
  fi
  WHAT='地址变 ⇒ 下一拍改（同一条记录）；家连不上 ⇒ 一条不改；手动换家 ⇒ 指新家；手改 ⇒ 改回 + 「有人手改」；调用失败 ⇒ 不算写过、下一拍再试；没 token ⇒ 0 次调用；DNSPod 只认带 fleet 备注的 cf 记录，token 不进 URL / 错误；同一路由器后两个家：钥匙页端口 = 家的转发端口，换家说端口要改，别的端口上的 IPv6 不写 AAAA'
  go_half "^($(printf '%s' "$tests" | tr ' ' '|'))\$" ./hub/api ./hub/dns; case $? in
    0) WHAT="${WHAT}（go test 五条）" ;;
    1) return 1 ;;
    2) WHAT="${WHAT}；Go 测试这台没有模块缓存 / 工具链——Go 门（tokenledger.yml）跑它们" ;;
    3) WHAT="${WHAT}；没有 go：五条测试按名核对在，Go 门（tokenledger.yml）跑它们" ;;
  esac
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
  local f="$ROOT/tokenledger/hub/api/fleet_entry_autoname_test.go" tl
  t0=$(now)
  for tl in $tests; do
    grep -q "^func $tl(" "$f" 2>/dev/null || { WHY="the hub test $tl is not in ${f#$ROOT/}"; return 1; }
  done
  grep -q 's.entryEnsureNames(now)' "$ROOT/tokenledger/hub/api/fleet_entry_dns.go" \
    || { WHY="the address-record loop no longer claims the names of people homed before #3337"; return 1; }
  grep -q 'entryDNSGuard(sub)' "$ROOT/tokenledger/hub/api/fleet_entry_dns.go" \
    || { WHY="the address-record loop no longer keeps the *.cf guard"; return 1; }
  WHAT='有家没名 ⇒ 设家（自动或手动）时领下建议名、审计一行，老的下一拍补上；名已在不动、建议名被占不强领；运维仍不能替人起任意名；没领的名不在计划里，*.cf 只有一条 TXT、没有 A/AAAA，被手删下一拍补回'
  go_half "^($(printf '%s' "$tests" | tr ' ' '|'))\$" ./hub/api; case $? in
    0) WHAT="${WHAT}（go test 两条）" ;;
    1) return 1 ;;
    2) WHAT="${WHAT}；Go 测试这台没有模块缓存 / 工具链——Go 门（tokenledger.yml）跑它们" ;;
    3) WHAT="${WHAT}；没有 go：两条测试按名核对在，Go 门（tokenledger.yml）跑它们" ;;
  esac
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
  f="$ROOT/tokenledger/hub/api/fleet_invites_test.go"
  t0=$(now)
  for out in $tests; do
    grep -q "^func $out(" "$f" 2>/dev/null || { WHY="the hub half's test $out is not in ${f#$ROOT/}"; return 1; }
  done
  grep -q 'denyInvitePrefix + reason' "$ROOT/tokenledger/hub/api/fleet_invites.go" \
    || { WHY="admitInvite no longer refuses a bad invite with its reason"; return 1; }
  go_half "^($(printf '%s' "$tests" | tr ' ' '|'))\$" ./hub/api; case $? in
    0) WHAT='过期 / 已用 / 撤销 / 别人的 / 没发过的码各被拒且说清原因、名单不变；好码进名单一次、审计「邀请已使用」；终端立刻听到拒绝（go test 五条）' ;;
    1) return 1 ;;
    2) WHAT='入口的 Go 测试在这台没有模块缓存 / 工具链——Go 门（tokenledger.yml）跑它们；六条测试按名核对在' ;;
    3) WHAT='没有 go：六条测试按名核对在，Go 门（tokenledger.yml）跑它们' ;;
  esac
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
  local agent='TestAdminAgentHandsJoinCodeInEnv|TestAdminAgentDropHomeDeletesHome'
  t0=$(now)
  grep -q 'op.JoinCode = s.loginJoinCode(a' "$ROOT/tokenledger/hub/api/fleet_accounts.go" \
    || { WHY="the hub's create op no longer carries the login's join code"; return 1; }
  grep -q '"FLEET_LOGIN_JOIN_CODE="' "$ROOT/tokenledger/agent/node_accounts.go" \
    || { WHY="the admin agent no longer hands the join code to fleet-login-new.sh in its environment"; return 1; }
  grep -q '^  node_join_step$' "$s" && grep -q 'fleet_up_step$' "$s" \
    || { WHY="fleet-login-new.sh no longer joins an opened login / brings its fleet up"; return 1; }
  go_half "^($agent)\$" github.com/verkyyi/claude-fleet/tokenledger/agent; case $? in
    0) WHAT='入口开号带一次性加入码、管理节点只经环境交给 fleet-login-new.sh；收号带 --delete-home 时删家目录（go test 两条；脚本一半是 fleet-login-new-selftest O）' ;;
    1) return 1 ;;
    2) WHAT='Go 测试在这台没有模块缓存 / 工具链——Go 门（tokenledger.yml）跑它们；脚本一半是 fleet-login-new-selftest O' ;;
    3) WHAT='没有 go：标记按名核对在，Go 门（tokenledger.yml）跑两条测试；脚本一半是 fleet-login-new-selftest O' ;;
  esac
  SECS=$(since "$t0")
}

# ---- remove-pending-machine-gone (#3957): a remove queued for a machine that is
# scaled away before the hub sends it. The row stays remove_pending (only a
# connected admin is sent a remove) and a plain forget refuses it; the operator's
# forget --machine-gone closes it as removed — refused while any link of that
# machine is open, for a pod the hub made, and for a row whose op landed or is
# running — the row and the audit saying the home was NOT archived there.
drill_remove_pending_machine_gone() {
  CAP=120; local t0 out rc tests f g="$ROOT/tokenledger/hub/api/fleet_account_gone.go"
  tests='TestForgetMachineGoneClosesRemovePending TestForgetMachineGoneUnknownRemove'
  f="$ROOT/tokenledger/hub/api/fleet_account_gone_test.go"
  t0=$(now)
  for out in $tests; do
    grep -q "^func $out(" "$f" 2>/dev/null || { WHY="the hub half's test $out is not in ${f#$ROOT/}"; return 1; }
  done
  grep -q 'if live := s.liveLinksOn(req.Hostname); len(live) > 0 {' "$g" 2>/dev/null \
    || { WHY="forget --machine-gone no longer refuses a machine that is still connected"; return 1; }
  grep -q '家目录未在源机归档' "$g" \
    || { WHY="a row closed by hand no longer says the home was not archived on the source machine"; return 1; }
  grep -q 'case AccountPending, AccountFailed, AccountRemoved:' "$ROOT/tokenledger/hub/store/fleet_accounts.go" \
    || { WHY="a plain forget no longer keeps to rows that never reached a machine"; return 1; }
  grep -q 'body\["machine_gone"\] = True' "$BIN/fleet-hub-admin.py" \
    || { WHY="fleet hub accounts forget has no --machine-gone"; return 1; }
  go_half "^($(printf '%s' "$tests" | tr ' ' '|'))\$" ./hub/api; case $? in
    0) WHAT='删除没下发、机器没了：普通 forget 照旧拒；--machine-gone 在机器还连着时拒，回不来时标 removed、行里和审计写「家目录未在源机归档」，之后 forget 删得掉（go test 两条）' ;;
    1) return 1 ;;
    2) WHAT='入口的 Go 测试在这台没有模块缓存 / 工具链——Go 门（tokenledger.yml）跑它们；两条测试按名核对在' ;;
    3) WHAT='没有 go：两条测试与 --machine-gone 的拒 / 记按名核对在，Go 门（tokenledger.yml）跑它们' ;;
  esac
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
  f="$ROOT/tokenledger/hub/api/fleet_spare_test.go"
  t0=$(now)
  for out in $tests; do
    grep -q "^func $out(" "$f" 2>/dev/null || { WHY="the hub half's test $out is not in ${f#$ROOT/}"; return 1; }
  done
  grep -q 'state = ? AND op = .create.' "$ROOT/tokenledger/hub/store/fleet_spare.go" \
    || { WHY="ClaimSpare no longer takes only a ready (active) spare"; return 1; }
  go_half "^($(printf '%s' "$tests" | tr ' ' '|'))\$" ./hub/api; case $? in
    0) WHAT='没有现成备用时照旧现开、入口说「正在开」带 ETA；有隔离好的备用时 3 秒内拿到、用掉即补；没隔离的不发不补；按上限−已用备足、多了就缩；备用不进人员视图；关着时一字不变（go test 六条）' ;;
    1) return 1 ;;
    2) WHAT='入口的 Go 测试在这台没有模块缓存 / 工具链——Go 门（tokenledger.yml）跑它们；六条测试按名核对在' ;;
    3) WHAT='没有 go：六条测试按名核对在，Go 门（tokenledger.yml）跑它们' ;;
  esac
  SECS=$(since "$t0")
}

# ---- spare-stall-silent (#3509, EPIC #3500 R3): a place's spare failed (its
# refill stops) or none has been ready for half an hour, and nobody is told.
# The alert sweep raises spare_empty / spare_failed (fleet_alerts) with one
# hub_audit spare.alert line, once a day per place and reason.
drill_spare_stall_silent() {
  CAP=120; local t0 out rc tests f
  tests='TestSpareEmptyAlertsOnceAfterThirtyMinutes TestSpareFailedAlertsAtOnceAndOncePerDay TestSpareFailedWashIsAlerted TestSpareFailedPodAlertsTheCluster TestSpareAlertsOffAddsNothing'
  f="$ROOT/tokenledger/hub/api/fleet_spare_alerts_test.go"
  t0=$(now)
  for out in $tests; do
    grep -q "^func $out(" "$f" 2>/dev/null || { WHY="the hub half's test $out is not in ${f#$ROOT/}"; return 1; }
  done
  grep -q 's.SpareAlertTick(since, now)' "$ROOT/tokenledger/hub/api/fleet_alerts.go" \
    || { WHY="the alert sweep no longer looks at the spares (SpareAlertTick)"; return 1; }
  go_half "^($(printf '%s' "$tests" | tr ' ' '|'))\$" ./hub/api; case $? in
    0) WHAT='备用 0 就绪满 30 分钟记一次 spare_empty、有就绪就清；建坏的备用、洗坏的登录、集群里坏的预备 pod 立刻记 spare_failed、forget 完就清；一天内同地同因不再记；每次一行 spare.alert 审计；备用关着什么都不记（go test 五条）' ;;
    1) return 1 ;;
    2) WHAT='入口的 Go 测试在这台没有模块缓存 / 工具链——Go 门（tokenledger.yml）跑它们；五条测试按名核对在' ;;
    3) WHAT='没有 go：五条测试按名核对在，Go 门（tokenledger.yml）跑它们' ;;
  esac
  SECS=$(since "$t0")
}

# ---- spare-refill-session-gate (#4076): a busy machine whose logins say
# admit=false / room=0 (the session gate), or a lost login whose last beat said
# so, must still get its spares — a spare runs no session. The refill's fit is
# "can a login be opened": CPU via cpuVerdict (cpu_busy first) and memory.
drill_spare_refill_session_gate() {
  CAP=120; local t0 out rc tests f
  tests='TestSpareRefillIgnoresTheSessionGate'
  f="$ROOT/tokenledger/hub/api/fleet_spare_test.go"
  t0=$(now)
  grep -q "^func $tests(" "$f" 2>/dev/null || { WHY="the hub half's test $tests is not in ${f#$ROOT/}"; return 1; }
  if awk '/^func \(s \*Server\) spareMachines\(/,/^}/' "$ROOT/tokenledger/hub/api/fleet_spare.go" | grep -q '\.Admit\|\.Room'; then
    WHY="spareMachines reads a login's admit / room again — the session gate holds the spares"; return 1
  fi
  go_half "^($tests)\$" ./hub/api; case $? in
    0) WHAT='admit=false / room=0、负载均值高但 cpu_busy 低的机器照样补到目标；失联登录的旧 admit=false 不挡；CPU 真忙才停补（go test 一条）' ;;
    1) return 1 ;;
    2) WHAT='入口的 Go 测试在这台没有模块缓存 / 工具链——Go 门（tokenledger.yml）跑它；测试按名核对在、spareMachines 不读 admit / room' ;;
    3) WHAT='没有 go：测试按名核对在、spareMachines 不读 admit / room，Go 门（tokenledger.yml）跑它' ;;
  esac
  SECS=$(since "$t0")
}

# ---- lease-unseparated-user (#2295, EPIC #2293 C2): a user's login whose
# credential separation did not happen (or an agent too old to say) must not be
# leased a real token — the hub refuses 「拒发：未隔离」 and tells the node's
# proxy to route every session central, so they still work. Since #4607 every
# login is held to it — an admin's too — and since #4675 no hub may opt out.
drill_lease_unseparated_user() {
  CAP=120; local t0 out rc api agent fa fg
  api='TestLeaseCredsepGate TestNodeSelfCarriesCredsepGate TestLeaseCredsepMandatory'
  agent='TestCredsepJudge TestCredsepProbeCaches'
  fa="$ROOT/tokenledger/hub/api/fleet_credsep_test.go"
  fg="$ROOT/tokenledger/agent/node_credsep_test.go"
  t0=$(now)
  for out in $api; do
    grep -q "^func $out(" "$fa" 2>/dev/null || { WHY="the hub half's test $out is not in ${fa#$ROOT/}"; return 1; }
  done
  for out in $agent; do
    grep -q "^func $out(" "$fg" 2>/dev/null || { WHY="the node half's test $out is not in ${fg#$ROOT/}"; return 1; }
  done
  grep -q 'credsep_gate' "$BIN/fleet-cred-proxy.py" \
    || { WHY="fleet-cred-proxy.py no longer routes a credsep-gated login central"; return 1; }
  go_half "^($(printf '%s %s' "$api" "$agent" | tr ' ' '|'))\$" ./hub/api github.com/verkyyi/claude-fleet/tokenledger/agent; case $? in
    0) WHAT='未隔离 / 不报字段 → 403「拒发：未隔离」、/self 带 credsep_gate（代理走 central），管理员也一样；隔离后 200；节点按 status+check 判定并 5 分钟缓存（go test 五条）' ;;
    1) return 1 ;;
    2) WHAT='入口的 Go 测试在这台没有模块缓存 / 工具链——Go 门（tokenledger.yml）跑它们；五条测试按名核对在' ;;
    3) WHAT='没有 go：五条测试按名核对在，Go 门（tokenledger.yml）跑它们' ;;
  esac
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
  f="$ROOT/tokenledger/hub/api/fleet_node_identity_test.go"
  t0=$(now)
  for out in $tests; do
    grep -q "^func $out(" "$f" 2>/dev/null || { WHY="the hub half's test $out is not in ${f#$ROOT/}"; return 1; }
  done
  grep -q 'machine := enrolledMachine(et)' "$ROOT/tokenledger/hub/api/fleet_trust.go" \
    || { WHY="nodeTrust no longer judges the machine the endpoint enrolled as"; return 1; }
  go_half "^($(printf '%s' "$tests" | tr ' ' '|'))\$" ./hub/api; case $? in
    0) WHAT='冒名节点领凭据 / 中继凭据被拒、名册读 name_borrowed、hello 记审计；真机照领；信任在机器上：托管加入码一次、一小时、写机器；入口开的登录随机器；旧的按登录信任迁到机器；期望状态只有操作者能写（go test 七条）' ;;
    1) return 1 ;;
    2) WHAT='入口的 Go 测试在这台没有模块缓存 / 工具链——Go 门（tokenledger.yml）跑它们；五条测试按名核对在' ;;
    3) WHAT='没有 go：五条测试按名核对在，Go 门（tokenledger.yml）跑它们' ;;
  esac
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
  f="$ROOT/tokenledger/hub/api/fleet_release_test.go"
  t0=$(now)
  for out in $tests; do
    grep -q "^func $out(" "$f" 2>/dev/null || { WHY="the hub half's test $out is not in ${f#$ROOT/}"; return 1; }
  done
  grep -q 'digest does not match the manifest' "$ROOT/tokenledger/shared/release/release.go" \
    || { WHY="Unpack no longer checks each file against the signed manifest"; return 1; }
  go_half "^($(printf '%s' "$tests" | tr ' ' '|'))\$" ./hub/api; case $? in
    0) WHAT='stable 一动入口就打包签名；机器从入口取到全部文件与二进制；GitHub 断了、入口重启也照样取；树 / 二进制 / 清单 / 签名 / 钥匙任一处被改都整个不换、不留半成品（go test 五条）' ;;
    1) return 1 ;;
    2) WHAT='入口的 Go 测试在这台没有模块缓存 / 工具链——Go 门（tokenledger.yml）跑它们；五条测试按名核对在' ;;
    3) WHAT='没有 go：五条测试按名核对在，Go 门（tokenledger.yml）跑它们' ;;
  esac
  SECS=$(since "$t0")
}

# ---- machine-agent-wrong-login (#2333, EPIC #2329 C5): the machine's one node
# program speaks for every login over one link; a login hello proven with the
# wrong token, or a message for a login the link does not carry, must be
# refused on both halves — never run as the wrong login, never as root.
drill_machine_agent_wrong_login() {
  CAP=180; local t0 out rc api e2e agt f e g
  api='TestMachineLinkRefusesWrongLogin TestMachineLinkCarriesEveryLogin TestMachineLinkSessionLandsOnItsLogin TestMachineLinkAccountCreateGoesToTheAdminLogin TestMachineLinkMoveLandsOnItsLogin'
  e2e='TestMachineLinkAndPlainAgents TestMachineAgentRunsEachLoginAsItself'
  agt='TestMachineLinkDemuxByLogin TestPrepCmdRunsAsTheLogin TestPrepCmdStrictOnlyForARootMachine'
  f="$ROOT/tokenledger/hub/api/node_machine_test.go"
  e="$ROOT/tokenledger/e2e/node_machine_test.go"
  g="$ROOT/tokenledger/agent/node_machine_test.go"
  t0=$(now)
  for out in $api; do
    grep -q "^func $out(" "$f" 2>/dev/null || { WHY="the hub half's test $out is not in ${f#$ROOT/}"; return 1; }
  done
  for out in $e2e; do
    grep -q "^func $out(" "$e" 2>/dev/null || { WHY="the联调 test $out is not in ${e#$ROOT/}"; return 1; }
  done
  for out in $agt; do
    grep -q "^func $out(" "$g" 2>/dev/null || { WHY="the node half's test $out is not in ${g#$ROOT/}"; return 1; }
  done
  grep -q 'ep.OSUser != login' "$ROOT/tokenledger/hub/api/node_machine.go" \
    || { WHY="loginEndpoint no longer holds a login hello to its own token's login"; return 1; }
  grep -q 'CodeWrongLogin' "$ROOT/tokenledger/agent/node_machine.go" \
    || { WHY="the node's demux no longer refuses a login it does not serve"; return 1; }
  go_half "^($(printf '%s %s %s' "$api" "$e2e" "$agt" | tr ' ' '|'))\$" ./hub/api ./e2e github.com/verkyyi/claude-fleet/tokenledger/agent; case $? in
    0) WHAT='整机连接上账号 hello 拿别人的 / 机器的 / 别的机器的令牌都答 WRONG_LOGIN、不上线、记审计；不认识的账号两端都拒；会话、开号、迁移各落在自己的账号；真的 RunMachine 以各账号身份跑控制器（go test 十条）' ;;
    1) return 1 ;;
    2) WHAT='入口的 Go 测试在这台没有模块缓存 / 工具链——Go 门（tokenledger.yml）跑它们；十条测试按名核对在' ;;
    3) WHAT='没有 go：十条测试按名核对在，Go 门（tokenledger.yml）跑它们' ;;
  esac
  SECS=$(since "$t0")
}

# A fleet whose tmux server is gone — an old login's per-repo fleet still
# reported to the hub (2026-10-08 mac-b, fleet-globex-monorepo) — took a home
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
  go_half 'TestPlacement(SkipsDownFleet|SameLoginPrefersLiveFleet)$|TestClientPlaceServerDownTriesNextMachine$' ./hub/api; case $? in
    0) gohalf='hub half: go test 不选 down / 同登录选活的 / 退 8 换下一台 ok' ;;
    1) return 1 ;;
    2) gohalf='hub half: no go module cache / toolchain here — the Go gate (tokenledger.yml) runs the down-fleet tests' ;;
  esac
  SECS=$(since "$t0")
  WHAT="服务不在的 fleet：节点 start 先问、退 8（没试过）；入口不选 down 的 fleet；$gohalf"
}

# A file dropped into the writing area on one computer, the session opened on
# another (2026-10-07 #2392: a MacBook screenshot, the session on mac-d): the
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
  go_half 'TestClientPlace(CarriesAttachments|AttachmentsToAnOlderNode)$|TestFetchAttachments$' ./hub/api github.com/verkyyi/claude-fleet/tokenledger/agent; case $? in
    0) gohalf='hub half: go test 入口转交 / 旧节点照说 / 节点下载校验 ok' ;;
    1) return 1 ;;
    2) gohalf='hub half: no go module cache / toolchain here — the Go gate (tokenledger.yml) runs the attachment tests' ;;
  esac
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
# guide — refused three times by the room estimate on mac-d (pressure normal, 28 %
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
  printf 'drill\n' > "$d/conf/global/onboard.person"   # a person is here (issue #4852)
  printf '引导窗口没能打开：dash-raw-session: machine memory tight · x\n' > "$d/conf/global/onboard.openfail"
  adm "fleet_guide_tick gar-nosuch-$$" >/dev/null
  [ -s "$d/conf/global/onboard.stuck" ] || { WHY="three tries did not write onboard.stuck"; return 1; }
  ev=$(find "$d" -name alerts.events -type f 2>/dev/null | head -n 1)
  grep -q 'onboard-stuck.*新手引导没开：引导窗口没能打开' "${ev:-/nonexistent}" 2>/dev/null \
    || { WHY="the stop was filed but not said (no onboard-stuck event in ${ev:-alerts.events}): $(cat "$d/conf/global/onboard.stuck")"; return 1; }
  SECS=$(since "$t0")
  WHAT="room 0、压力正常、在保底线之上：普通会话照拦，新手引导放行，压力 warn 仍拦；三次没开口写 onboard.stuck 并发出 onboard-stuck 事件"
}

# admit-room-advice (issue #3479): the newcomer's SECOND ordinary session on mac-d
# (drill 35) — pressure normal, 25 % free, floor 15 %, «room for 0 more at ~882 MB
# each»: the hysteresis an earlier hold left and a just-opened window's reservation
# took the one-more estimate to 0 while 757 MB sat above the floor. For real, on a
# sandbox state dir with mac-d's numbers (16384 MB, agents of 294 MB × 3 = 882,
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
  case "$out" in *'pressure normal'*'room for 0 more at ~882 MB'*'|rc=1') ;; *) WHY="the strict rule does not reproduce mac-d's refusal: $out"; return 1 ;; esac
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
  case "$out" in *'"admit":true'*'"room":2}'*) ;; *) WHY="the capacity beat under mac-d's reading must say admit:true room 2 (the hub reads room < 1 as full): $out"; return 1 ;; esac
  grep -q '^func TestClientPlaceNamedFullSaysPinned(' "$ROOT/tokenledger/hub/api/fleet_place_fallback_test.go" 2>/dev/null \
    || { WHY="the hub half's test TestClientPlaceNamedFullSaysPinned is not in fleet_place_fallback_test.go"; return 1; }
  SECS=$(since "$t0")
  WHAT="mac-d 的数（25% 空闲、保底 15%、约 882 MB/会话、残留 hold + 1 个刚开的窗口）：普通第二个会话放行并记下；容量拍子报 room 2；两个还在开的 spawn、压力 warn、低于保底线仍拦；FLEET_ADMIT_ROOM=hold 复现原拒绝"
}

# admit-open-window-twice (issue #3487): after #3480 mac-d still refused a
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

# linux-admit-host-load (issue #3308): in an ACK pod /proc/loadavg is the whole ECS
# node's — 6.29/core on 2026-10-11 while the pod used a sliver of its 2-core
# cpu.max — so fleet_machine_admit held every new session there. For real: the
# host reading 6.29/core through the machine reading (no load stub), a sandbox
# cgroup (cpu.max 200000/100000, an idle cpu.stat): no cgroup holds as before; the
# idle pod admits however busy the host; a pod using 1.95 of 2 cores, or throttled
# 40 %, holds with the container's own numbers; FLEET_ADMIT_LOAD_PER_CORE=0 admits.
drill_linux_admit_host_load() {
  CAP=20; local t0 d="$WORK/lahl" out
  t0=$(now)
  rm -rf "$d"; mkdir -p "$d/conf/cluster" "$d/tmp" "$d/cg"
  printf '{\n"ts": %s,\n"load_per_core": "6.29"\n}\n' "$(date +%s)" > "$d/conf/cluster/machine.json"
  printf '200000 100000\n' > "$d/cg/cpu.max"
  printf 'usage_usec 5000000\nuser_usec 4000000\nsystem_usec 1000000\nnr_periods 900\nnr_throttled 0\nthrottled_usec 0\n' > "$d/cg/cpu.stat"
  adm() { env FLEET_ADMIT=1 TMPDIR="$d/tmp" HOME="$d" FLEET_CONF_DIR="$d/conf" FLEET_MACHINE_TASKS=off \
            FLEET_MEM_TOTAL_MB=16384 FLEET_MEM_PS_CMD="printf '101 1 $(id -u) 102400 01:00 claude\n'" \
            FLEET_MEM_PROBE_CMD='echo 1 66 0 0' FLEET_CPU_STAT_FILE="$d/cg/cpu.stat" \
            FLEET_ADMIT_CPU_SAMPLE_SECS=0.1 "$@" \
            bash -c "source '$BIN/fleet-lib.sh'; fleet_machine_admit; echo \"|rc=\$?\"" 2>&1; }
  out=$(adm FLEET_CPU_MAX_FILE="$d/cg/none")
  case "$out" in *'6.29/core'*'|rc=1') ;; *) WHY="with no cgroup limit the host's 6.29/core must still hold (the old rule): $out"; return 1 ;; esac
  out=$(adm FLEET_CPU_MAX_FILE="$d/cg/cpu.max")
  [ "$out" = '|rc=0' ] || { WHY="an idle pod (0 of 2 cores) was held by the host's 6.29/core: $out"; return 1; }
  out=$(adm FLEET_CPU_MAX_FILE="$d/cg/cpu.max" FLEET_ADMIT_CPU_READING='0 1.95 2.00')
  case "$out" in *'container cpu busy'*'1.95 of 2.00 cores'*'|rc=1') ;; *) WHY="a pod using 1.95 of 2 cores must hold with its own numbers: $out"; return 1 ;; esac
  out=$(adm FLEET_ADMIT_CPU_READING='40 1.00 2.00')
  case "$out" in *'40% throttled'*'|rc=1') ;; *) WHY="a pod throttled 40 % must hold: $out"; return 1 ;; esac
  out=$(adm FLEET_ADMIT_CPU_READING='40 1.95 2.00' FLEET_ADMIT_LOAD_PER_CORE=0)
  [ "$out" = '|rc=0' ] || { WHY="FLEET_ADMIT_LOAD_PER_CORE=0 must turn the cgroup reading off too: $out"; return 1; }
  SECS=$(since "$t0")
  WHAT="宿主 6.29/core（ACK 节点）、pod cpu.max 2 核：没有 cgroup 照旧拦；pod 闲时放行；pod 用 1.95/2 核或被限流 40% 时按容器自己的数拦；FLEET_ADMIT_LOAD_PER_CORE=0 一并关掉"
}

# linux-admit-burst (issue #4287): the gate read a 1-core pod's cgroup over 0.5 s,
# and on the domestic path's test pod (2026-10-15) that swung 0 → 50 % throttled
# within seconds while the pod averaged 0.25 cores — the probe's view step had
# just started two Claude sessions, so its `fleet codex --new` was refused
# 负载过高. For real: a sandbox cgroup (cpu.max 1 core) whose cpu.stat a writer
# moves at a full, throttled core while the gate samples, over a minute that
# averaged 0.2 cores / 5 % throttled: with the minute's note the gate admits; the
# old instant sample (FLEET_ADMIT_CPU_WINDOW_SECS=0) holds on the burst; with no
# note yet it samples (holds) and leaves one; a minute that really averaged 0.95
# cores holds, naming the window.
drill_linux_admit_burst() {
  CAP=20; local t0 d="$WORK/lab" out n wp
  t0=$(now)
  rm -rf "$d"; mkdir -p "$d/conf/global" "$d/tmp" "$d/cg"
  printf '100000 100000\n' > "$d/cg/cpu.max"
  n=$(date +%s)
  printf '%s 1000000000 10000 1000\n' "$((n - 60))" > "$d/conf/global/admit-cpu.window"
  # 0.2 cores and 5 % throttled since the note, then a full throttled core from now on
  # stopped by a flag, never a bare kill: a killed loop's in-flight `mv` lands after
  # the static reading written below and the last leg read 0.2 cores (#4380)
  ( u=1012000000 p=10600 t=1030
    while [ ! -e "$d/cg/stop" ]; do
      printf 'usage_usec %s\nnr_periods %s\nnr_throttled %s\n' "$u" "$p" "$t" > "$d/cg/cpu.stat.w"
      mv -f "$d/cg/cpu.stat.w" "$d/cg/cpu.stat"
      u=$((u + 100000)); p=$((p + 1)); t=$((t + 1)); sleep 0.1
    done ) &
  wp=$!
  sleep 0.3
  adm() { env FLEET_ADMIT=1 TMPDIR="$d/tmp" HOME="$d" FLEET_CONF_DIR="$d/conf" FLEET_MACHINE_TASKS=off \
            FLEET_MEM_TOTAL_MB=16384 FLEET_MEM_PS_CMD="printf '101 1 $(id -u) 102400 01:00 claude\n'" \
            FLEET_MEM_PROBE_CMD='echo 1 66 0 0' FLEET_CPU_STAT_FILE="$d/cg/cpu.stat" FLEET_CPU_MAX_FILE="$d/cg/cpu.max" \
            FLEET_ADMIT_CPU_SAMPLE_SECS=0.5 "$@" \
            bash -c "source '$BIN/fleet-lib.sh'; fleet_machine_admit; echo \"|rc=\$?\"" 2>&1; }
  out=$(adm)
  [ "$out" = '|rc=0' ] || { kill "$wp" 2>/dev/null; wait "$wp" 2>/dev/null; WHY="a pod that averaged 0.2 cores over the minute was held by its last half second: $out"; return 1; }
  out=$(adm FLEET_ADMIT_CPU_WINDOW_SECS=0)
  case "$out" in *'container cpu busy'*'|rc=1') ;; *) kill "$wp" 2>/dev/null; wait "$wp" 2>/dev/null; WHY="the old 0.5 s sample should still see the burst (FLEET_ADMIT_CPU_WINDOW_SECS=0): $out"; return 1 ;; esac
  rm -f "$d/conf/global/admit-cpu.window"
  out=$(adm)
  : > "$d/cg/stop"; wait "$wp" 2>/dev/null
  case "$out" in *'container cpu busy'*'|rc=1') ;; *) WHY="with no note yet the gate must sample and hold on a busy core: $out"; return 1 ;; esac
  [ -s "$d/conf/global/admit-cpu.window" ] || { WHY="the first reading left no note for the next one"; return 1; }
  # its own counters file: nothing the writer above ever wrote can land on it (#4520:
  # this leg once read the writer's 0.25 cores against the note — rc 0, no words)
  mkdir -p "$d/cg2"
  n=$(date +%s)
  printf 'usage_usec 1057000000\nnr_periods 10600\nnr_throttled 1300\n' > "$d/cg2/cpu.stat"
  printf '%s 1000000000 10000 1000\n' "$((n - 60))" > "$d/conf/global/admit-cpu.window"
  out=$(adm FLEET_CPU_STAT_FILE="$d/cg2/cpu.stat")
  case "$out" in *'0.9'?' of 1.00 cores used'*'over the last 6'?'s'*'|rc=1') ;; *) WHY="a minute at 0.95 of 1 core must hold, naming the window: $out"; return 1 ;; esac
  SECS=$(since "$t0")
  WHAT="1 核 pod，最近一分钟均 0.2 核 / 限流 5%，采样那半秒满核被限流：放行；旧的 0.5 秒采样（WINDOW_SECS=0）照旧拦；还没有记录时照采样拦并留下记录；一分钟真用 0.95 核时拦，写明「over the last 60s」"
}

# linux-admit-pod-start (issue #4290): a person's pod (FLEET_USER_POD=1) runs its
# fleet container at a 1-core limit and rolls to a new image on every release; in
# the minutes after a roll the gate read 1.51 of 1.00 cores / 59 % throttled over
# the minute and refused the person's own new session (and the guide). For real,
# through fleet_session_cap_ok on a sandbox cgroup reading: on a shared machine
# that reading holds; on a person's pod it admits and the admission notes it in
# admit-advice.log; the capacity beat says admit:true there; memory pressure still
# holds on the pod; FLEET_ADMIT_POD_CPU=hold restores the hold.
drill_linux_admit_pod_start() {
  CAP=20; local t0 d="$WORK/laps" out lg
  t0=$(now)
  rm -rf "$d"; mkdir -p "$d/conf/global" "$d/tmp"
  run() { env FLEET_ADMIT=1 TMPDIR="$d/tmp" HOME="$d" FLEET_CONF_DIR="$d/conf" FLEET_MACHINE_TASKS=off \
            FLEET_MEM_TOTAL_MB=16384 FLEET_MEM_PS_CMD="printf '101 1 $(id -u) 102400 01:00 claude\n'" \
            FLEET_MEM_PROBE_CMD='echo 1 66 0 0' FLEET_ADMIT_CPU_READING='59 1.51 1.00 51' "$@"; }
  cap() { run "$@" bash -c "source '$BIN/fleet-lib.sh'; fleet_session_cap_ok laps >/dev/null 2>&1; echo \"rc=\$?\"; fleet_machine_admit; echo \"|rc=\$?\"" 2>&1; }
  out=$(cap)
  case "$out" in *'rc=1'*'1.51 of 1.00 cores used'*'over the last 51s'*'|rc=1') ;; *) WHY="on a shared machine 1.51 of 1 core must still hold: $out"; return 1 ;; esac
  out=$(cap FLEET_USER_POD=1)
  case "$out" in 'rc=0'*'|rc=0') ;; *) WHY="a person's own pod was refused their own session over its CPU: $out"; return 1 ;; esac
  lg=$(find "$d/tmp" -name admit-advice.log 2>/dev/null | head -1)
  grep -q "1.51 of 1.00 cores used.*person's own pod (advice)" "${lg:-/nonexistent}" 2>/dev/null \
    || { WHY="the pod's admission over a busy CPU left no line in admit-advice.log: ${lg:-none} $(cat "${lg:-/nonexistent}" 2>&1)"; return 1; }
  out=$(run FLEET_USER_POD=1 bash "$BIN/fleet-control-read.sh" capacity 2>&1)
  case "$out" in *'"admit":true'*) ;; *) WHY="the pod's heartbeat must say admit:true over a busy CPU: $out"; return 1 ;; esac
  out=$(cap FLEET_USER_POD=1 FLEET_MEM_PROBE_CMD='echo 4 5 0 0')
  case "$out" in *'rc=1'*'内存紧张'*'|rc=1') ;; *) WHY="memory pressure must still hold on a person's pod: $out"; return 1 ;; esac
  out=$(cap FLEET_USER_POD=1 FLEET_ADMIT_POD_CPU=hold)
  case "$out" in *'rc=1'*'container cpu busy'*'|rc=1') ;; *) WHY="FLEET_ADMIT_POD_CPU=hold must restore the hold: $out"; return 1 ;; esac
  SECS=$(since "$t0")
  WHAT="1 核 pod 一分钟读 1.51 核 / 限流 59%：共享机器照拦；个人 pod 放行并在 admit-advice.log 记一行，心跳 admit:true；个人 pod 内存紧张照拦；FLEET_ADMIT_POD_CPU=hold 回到拦"
}

# mac-admit-load-not-busy (issue #4077): macOS counts waiting processes in its
# load average — a 15-core Mac read load 47.2 on 15 cores (3.1/core) with the CPU
# 40 % busy, and every login's gate answered admit=false 负载过高, so no new
# session and no pool refill anywhere. For real, through the daemon's machine
# reading (no load stub): that reading at 40 % busy admits and the heartbeat says
# admit:true; 92 % busy holds and admit_why names the CPU; past the 5/core hard
# cap it holds naming the load; a reading with no cpu_busy (an older daemon) and
# no live probe falls back to the old load rule; the task's own probe publishes
# a cpu_busy share.
drill_mac_admit_load_not_busy() {
  CAP=20; local t0 d="$WORK/malnb" out
  t0=$(now)
  rm -rf "$d"; mkdir -p "$d/conf/cluster" "$d/tmp"
  mr() { printf '{\n"ts": %s,\n"load_per_core": "%s"%s\n}\n' "$(date +%s)" "$1" "${2:+,
\"cpu_busy\": \"$2\"}" > "$d/conf/cluster/machine.json"; }
  run() { env FLEET_ADMIT=1 TMPDIR="$d/tmp" HOME="$d" FLEET_CONF_DIR="$d/conf" FLEET_MACHINE_TASKS=off \
            FLEET_MEM_TOTAL_MB=16384 FLEET_MEM_PS_CMD="printf '101 1 $(id -u) 102400 01:00 claude\n'" \
            FLEET_MEM_PROBE_CMD='echo 1 66 0 0' FLEET_CPU_MAX_FILE="$d/none" "$@"; }
  adm() { run "$@" bash -c "source '$BIN/fleet-lib.sh'; fleet_machine_admit; echo \"|rc=\$?\"" 2>&1; }
  mr 3.15 0.400
  out=$(adm)
  [ "$out" = '|rc=0' ] || { WHY="load 3.15/core at 40 % CPU must admit: $out"; return 1; }
  out=$(run bash "$BIN/fleet-control-read.sh" capacity 2>&1)
  case "$out" in *'"admit":true'*) ;; *) WHY="the heartbeat at 40 % CPU must say admit:true: $out"; return 1 ;; esac
  mr 3.15 0.920
  out=$(run bash "$BIN/fleet-control-read.sh" capacity 2>&1)
  case "$out" in *'"admit":false'*'"admit_why":"负载过高（CPU 92%）"'*) ;; *) WHY="92 % busy must hold and admit_why name the CPU: $out"; return 1 ;; esac
  mr 6.40 0.400
  out=$(adm)
  case "$out" in *'machine load extreme'*'6.40/core'*'|rc=1') ;; *) WHY="6.4/core is past the 5/core hard cap and must hold: $out"; return 1 ;; esac
  mr 3.15
  out=$(adm FLEET_CPU_BUSY_PROBE_CMD=true)
  case "$out" in *'machine load high'*'3.15/core'*'no CPU-busy reading'*'|rc=1') ;; *) WHY="with no busy reading the old load rule must hold: $out"; return 1 ;; esac
  out=$(env -u FLEET_MACHINE_TASKS python3 "$BIN/fleet-machine-tasks.py" probe 2>&1)
  case "$out" in *'"cpu_busy": "'[01].[0-9][0-9][0-9]'"'*) ;; *) WHY="the machine-reading task must publish a cpu_busy share: $out"; return 1 ;; esac
  SECS=$(since "$t0")
  WHAT="15 核 Mac 3.1/核、CPU 40%：经机器读数放行、心跳 admit:true；CPU 92% 挡且 admit_why 写「负载过高（CPU 92%）」；过 5/核硬上限仍挡；没有 cpu_busy 读数回到老负载规则；守护的读数任务发布 cpu_busy"
}

# pod-disk-node-tmp (issue #3974): a Linux pod has no TMPDIR, and its /tmp is the
# NODE's shared root disk — 13 GB free of 61 on 2026-10-13 because of the other
# tenants, while the login's own home volume had 46 GB. Every disk rail measured
# /tmp: the warm pool held at `disk 13GB < 15GB` (every ⌘N cold-started Codex,
# 4.8 s to a prompt), diskguard wrote an incident every 5 minutes, and its gate
# was 1 GB from refusing every spawn. For real: a `df` shim answering per path
# (/tmp 13 GB, the sandbox home 46 GB) under diskguard's --free / --gate 15 with
# TMPDIR unset; TMPDIR set (a Mac) still measures TMPDIR; FLEET_DISK_TARGET wins;
# the pool and the bar's alert read the same target.
drill_pod_disk_node_tmp() {
  CAP=15; local t0 d="$WORK/pdnt" out
  t0=$(now)
  rm -rf "$d"; mkdir -p "$d/home" "$d/mac-tmp" "$d/shim"
  cat > "$d/shim/df" <<SH
#!/bin/sh
for a; do p=\$a; done
case "\$p" in
  $d/home*) k=48234496 ;;
  $d/mac-tmp*) k=104857600 ;;
  *) k=13631488 ;;
esac
printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n'
printf 'fake 1 1 %s 1%% /x\n' "\$k"
SH
  # A Linux pod: fleet-lib.sh gives a Mac with no TMPDIR launchd's per-user one.
  printf '#!/bin/sh\necho Linux\n' > "$d/shim/uname"
  chmod +x "$d/shim/df" "$d/shim/uname"
  dg() { env -u TMPDIR -u FLEET_DISK_TARGET PATH="$d/shim:$PATH" HOME="$d/home" FLEET_CONF_DIR="$d/conf" "$@"; }
  out=$(dg bash "$BIN/fleet-diskguard.sh" --free 2>&1)
  [ "$out" = 46 ] || { WHY="a pod with no TMPDIR must measure its home (46 GB), not the node's /tmp (13): got $out"; return 1; }
  out=$(dg bash "$BIN/fleet-diskguard.sh" --gate 15 2>&1; echo "|rc=$?")
  [ "$out" = '|rc=0' ] || { WHY="the spawn gate refused on the node's /tmp: $out"; return 1; }
  out=$(dg TMPDIR="$d/mac-tmp" bash "$BIN/fleet-diskguard.sh" --free 2>&1)
  [ "$out" = 100 ] || { WHY="with TMPDIR set (a Mac) the TMPDIR volume must still be measured: got $out"; return 1; }
  out=$(dg TMPDIR="$d/mac-tmp" FLEET_DISK_TARGET=/tmp bash "$BIN/fleet-diskguard.sh" --free 2>&1)
  [ "$out" = 13 ] || { WHY="FLEET_DISK_TARGET must win: got $out"; return 1; }
  out=$(dg bash -c "source '$BIN/fleet-lib.sh'; fleet_disk_target")
  [ "$out" = "$d/home" ] || { WHY="fleet_disk_target with no TMPDIR: $out"; return 1; }
  grep -qF 'target="${FLEET_DISK_TARGET:-${TMPDIR:-${HOME:-/tmp}}}"' "$BIN/fleet-alerts.sh" \
    || { WHY="fleet-alerts.sh's inline copy of fleet_disk_target drifted"; return 1; }
  SECS=$(since "$t0")
  WHAT="pod 无 TMPDIR：/tmp（节点共享盘）13 GB、家 46 GB——diskguard --free 读 46、--gate 15 放行；有 TMPDIR（Mac）照读 TMPDIR；FLEET_DISK_TARGET 优先；侧栏告警读同一个目标"
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
  f="$ROOT/tokenledger/hub/api/fleet_publish_test.go"
  for out in $tests; do
    grep -q "^func $out(" "$f" 2>/dev/null || { WHY="the hub half's test $out is not in ${f#$ROOT/}"; return 1; }
  done
  t0=$(now)
  out=$(bash "$BIN/fleet-release-publish-selftest.sh" 2>&1) \
    || { WHY="the CI half: $(printf '%s' "$out" | grep -m 3 FAIL | cut -c1-200 | tr '\n' '|')"; return 1; }
  WHAT='CI 送的是整个提交 + 从入口 stable 起的提交链，令牌不上命令行'
  go_half "^($(printf '%s' "$tests" | tr ' ' '|'))\$" ./hub/api; case $? in
    0) WHAT="${WHAT}；入口：改一个字节 400、别的仓 / 分支 / 流程 401、回退 / 横跳 409、GitHub 黑洞零命中（go test 四条）" ;;
    1) return 1 ;;
    2) WHAT="${WHAT}；入口的 Go 测试这台没有模块缓存 / 工具链——Go 门（tokenledger.yml）跑它们" ;;
    3) WHAT="${WHAT}；没有 go：五条测试按名核对在，Go 门（tokenledger.yml）跑它们" ;;
  esac
  SECS=$(since "$t0")
}

# ---- hub-stream-silent (#2794, EPIC #2792 C2): the push channel held open by a
# proxy that neither sends nor closes — the page must not believe it is live.
# The page half by name (the console's sessions.ts, since the old console's
# lib/stream.js went with claude-fleet#3939: a silent stream is dropped at 30 s
# and opened again with a backoff, the reconnect is the catch-up, twice silent
# or one that cannot be built polls every 10 s); the hub half's ping and scope
# by name (and go test with a toolchain).
drill_hub_stream_silent() {
  CAP=120; local t0 out rc js="$ROOT/extras/web-console/src/shared/sessions.ts" tests f
  tests='TestFleetStreamPing TestFleetStreamScoped TestFleetStreamOnlyOnChange'
  f="$ROOT/tokenledger/hub/api/fleet_stream_test.go"
  t0=$(now)
  grep -q 'export const WATCHDOG_MS = 30_000;' "$js" || { WHY="sessions.ts no longer gives up on a silent stream at 30 s"; return 1; }
  grep -q 'es.addEventListener("ping", alive);' "$js" || { WHY="sessions.ts no longer takes the hub's ping as a sign of life"; return 1; }
  grep -q 'if (++silent >= 2) { startPoll(); later(60_000); return; }' "$js" \
    || { WHY="sessions.ts no longer falls back to the 10 s poll on a stream silent twice"; return 1; }
  grep -q 'var fleetStreamPing = 20 \* time.Second' "$ROOT/tokenledger/hub/api/fleet_stream.go" \
    || { WHY="the hub no longer pings an idle stream every 20 s"; return 1; }
  for out in $tests; do
    grep -q "^func $out(" "$f" 2>/dev/null || { WHY="the hub half's test $out is not in ${f#$ROOT/}"; return 1; }
  done
  WHAT='页面：代理挂住的推送 30 s 断开重连（1→2→4→8→15 s）、重连即补一份；连着两次没声音或建不起来退回 10 s 轮询（按名核对）'
  go_half "^($(printf '%s' "$tests" | tr ' ' '|'))\$" ./hub/api; case $? in 0) WHAT="${WHAT}；入口每 20 s ping、只发本人的、没变不发（go test）" ;; 1) return 1 ;; esac
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
# toolchain), the page's 403-is-a-word by name (the console's ServiceSheet).
drill_service_log_cross_login() {
  CAP=180; local t0 out rc api agt fa fg
  api='TestServiceLogCrossLoginIs403 TestServiceLogOneFollowForManyViewers TestRedactLogLine'
  agt='TestServiceLogOnlyTheRegisteredFile'
  fa="$ROOT/tokenledger/hub/api/fleet_service_log_test.go"
  fg="$ROOT/tokenledger/agent/node_service_log_test.go"
  t0=$(now)
  grep -q 'if visible != nil && !visible(host, login) {' "$ROOT/tokenledger/hub/api/fleet_service_log.go" \
    || { WHY="handleServiceLog no longer asks FleetScope before anything else"; return 1; }
  grep -q 'serviceLogPath(a.cfg.ServicesFile, login, req.Name)' "$ROOT/tokenledger/agent/node_service_log.go" \
    || { WHY="the node no longer takes the log path from the register for the lane's own login"; return 1; }
  for out in $api; do
    grep -q "^func $out(" "$fa" 2>/dev/null || { WHY="the hub half's test $out is not in ${fa#$ROOT/}"; return 1; }
  done
  grep -q "^func $agt(" "$fg" 2>/dev/null || { WHY="the node half's test $agt is not in ${fg#$ROOT/}"; return 1; }
  WHAT='别人的登录名拼进地址 → 403、节点一次都没被问；只读登记表里本登录的那个文件（测试按名核对在，Go 门跑它们）'
  grep -q 'if (s === 403) return setMode("denied");' "$ROOT/extras/web-console/src/admin/pages/ServiceSheet.tsx" \
    || { WHY="the console's ServiceSheet no longer takes a 403 as a word (it would retry)"; return 1; }
  WHAT="${WHAT}；页面：403 是一句话、不重试（按名核对）"
  go_half "^($(printf '%s %s' "$api" "$agt" | tr ' ' '|'))\$" ./hub/api github.com/verkyyi/claude-fleet/tokenledger/agent; case $? in
    0) WHAT="${WHAT}；go test：403、一份节点流、打码、只读登记的文件" ;;
    1) return 1 ;;
  esac
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
  grep -q 'id, err = identity.ClaudePool(a.cfg.Home), nil' "$ROOT/tokenledger/agent/agent.go" 2>/dev/null \
    || { WHY="the agent no longer files a login with no oauthAccount under the claude:local pool"; return 1; }
  grep -q 's.UsageSilentTick(now, false)' "$ROOT/tokenledger/hub/api/fleet_alerts.go" \
    || { WHY="the alerts sweep no longer runs the usage_silent check"; return 1; }
  for t in $agent_tests; do
    grep -q "^func $t(" "$ROOT/tokenledger/agent/claude_pool_test.go" 2>/dev/null \
      || { WHY="the agent half's test $t is not in tokenledger/agent/claude_pool_test.go"; return 1; }
  done
  for t in $hub_tests; do
    grep -q "^func $t(" "$ROOT/tokenledger/hub/api/fleet_usage_silent_test.go" 2>/dev/null \
      || { WHY="the hub half's test $t is not in tokenledger/hub/api/fleet_usage_silent_test.go"; return 1; }
  done
  WHAT='没 /login 的登录：Claude 用量记进 claude:local 池、照常归到人；会话 working 超 30 分钟没用量 → usage_silent，用量一到就清（测试按名核对在，Go 门跑它们）'
  go_half "^($(printf '%s %s' "$agent_tests" "$hub_tests" | tr ' ' '|'))\$" github.com/verkyyi/claude-fleet/tokenledger/agent ./hub/api; case $? in
    0) WHAT='没 /login 的登录的 Claude 用量进 claude:local 池（来源 session、不动登录账号）；没对话目录不造池；working 超阈值没用量 → usage_silent，用量到 / 不工作即清（go test）' ;;
    1) return 1 ;;
  esac
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
  local tl="$ROOT/tokenledger/hub"
  t0=$(now)
  grep -q 'c, why := s.poolUsagePass(rep.Cred, rep.Provider' "$tl/api/fleet_person_budget.go" 2>/dev/null \
    || { WHY="the hub no longer takes a usage report's person from the pass it rode on"; return 1; }
  grep -q 'u := store.PoolUsage{Principal: c.Principal, WorkerID: c.WorkerID' "$tl/api/fleet_person_budget.go" \
    || { WHY="the hub files a cluster report under something other than the pass's principal / session"; return 1; }
  grep -q 'return ErrPoolUsageNoPrincipal' "$tl/store/pool_usage.go" 2>/dev/null \
    || { WHY="the store no longer refuses an ownerless pool_usage row"; return 1; }
  grep -q 'u.Cred, u.Principal, u.WorkerID' "$ROOT/tokenledger/shared/credproxy/credproxy.go" \
    || { WHY="the cluster proxy no longer reports each request with its pass"; return 1; }
  for t in $api_tests; do
    grep -q "^func $t(" "$tl/api/pool_usage_test.go" 2>/dev/null \
      || { WHY="the hub half's test $t is not in tokenledger/hub/api/pool_usage_test.go"; return 1; }
  done
  for t in $store_tests; do
    grep -q "^func $t(" "$tl/store/pool_usage_test.go" 2>/dev/null \
      || { WHY="the store half's test $t is not in tokenledger/hub/store/pool_usage_test.go"; return 1; }
  done
  WHAT='池子用量一笔一行记在通行证的人名下：无通行证 / 伪造 / 自报别人的上报被拒且不写；repo/issue 取自租约；无主行存不进去（测试按名核对在，Go 门跑它们）'
  go_half "^($(printf '%s %s' "$api_tests" "$store_tests" | tr ' ' '|'))\$" ./hub/api ./hub/store; case $? in
    0) WHAT='池子用量一笔一行：只认通行证的人与会话（无 / 伪造 / 自报不符 → 403 不写），repo/issue 取自租约，编排记给登录主人，个人上限读同一张表且与旧桶口径相等（go test）' ;;
    1) return 1 ;;
  esac
  SECS=$(since "$t0")
}

# ---- pool-usage-silent (#3233, EPIC #3225): requests keep going out on the
# subscription pool and their usage stops landing — the proxy's report broke,
# or the hub refuses it. Nothing said so: a person's usage stood still for
# three days until someone looked. The hub sees both halves — every resolve the
# proxy asks before it forwards, every pool_usage row — and raises
# pool_usage_silent on a person whose passes kept resolving past
# FLEET_POOL_USAGE_SILENT_ALERT_SECS with no row in that time; a row, or the
# proxy going quiet, clears it. Go tests by name (run with a toolchain).
drill_pool_usage_silent() {
  CAP=120; local t0 out rc t
  local tests='TestPoolUsageSilentRaisedWhenResolvesGoUnbilled TestPoolUsageSilentQuietWhenBilledOrIdle TestPoolUsageSilentFromResolves TestPoolUsageSilentAfterFromEnv'
  local tl="$ROOT/tokenledger/hub"
  t0=$(now)
  grep -q 's.notePoolResolve(c.Principal, now)' "$tl/api/fleet_credproxy.go" 2>/dev/null \
    || { WHY="the hub no longer counts a resolve the credential proxy was answered"; return 1; }
  grep -q 's.PoolUsageSilentTick(now, false)' "$tl/api/fleet_alerts.go" \
    || { WHY="the alerts sweep no longer runs the pool_usage_silent check"; return 1; }
  grep -q 'srv.PoolUsageSilentAfter = api.PoolUsageSilentAfterFromEnv()' "$ROOT/tokenledger/hub/cmd/ccquota/hub.go" \
    || { WHY="the hub no longer reads FLEET_POOL_USAGE_SILENT_ALERT_SECS"; return 1; }
  for t in $tests; do
    grep -q "^func $t(" "$tl/api/fleet_pool_usage_silent_test.go" 2>/dev/null \
      || { WHY="the hub half's test $t is not in tokenledger/hub/api/fleet_pool_usage_silent_test.go"; return 1; }
  done
  WHAT='代理一直在为某人放行、池子用量却没进账超 30 分钟 → pool_usage_silent；记账一到 / 代理不再放行即清（测试按名核对在，Go 门跑它们）'
  go_half "^($(printf '%s' "$tests" | tr ' ' '|'))\$" ./hub/api; case $? in
    0) WHAT='某人的通行证在代理处连续解析超阈值、pool_usage 一行没有 → pool_usage_silent；伪造通行证不算；一笔记账 / 代理停问即清；正常记账、零散使用、关掉时不报（go test）' ;;
    1) return 1 ;;
  esac
  SECS=$(since "$t0")
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
  local tl="$ROOT/tokenledger/hub"
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
      || { WHY="the hub half's test $t is not in tokenledger/hub/api"; return 1; }
  done
  WHAT='节点代理的用量：登录没对应到人 → 不写无主行、记 pool_usage_unowned 告警；按会话（worker_id · 订阅 · 模型 · 分项）上报，repo/issue 取自租约；旧代理的汇总照记（测试按名核对在，Go 门跑它们）'
  go_half "^($(printf '%s' "$api_tests" | tr ' ' '|'))\$" ./hub/api; case $? in
    0) WHAT='节点代理的用量：无主登录告警不丢、按会话分行且 repo/issue 取自租约、个人上限累计与旧汇总相等（go test）' ;;
    1) return 1 ;;
  esac
  SECS=$(since "$t0")
}

# ---- account-gh-only-check (#3603, EPIC #3570 C10): a person was a GitHub
# account — every "is this a person" asked `gh:`, so someone with only an
# address was nobody: no invite, no machine, no certificate. Now one isPerson,
# a principal any way of signing in leads to, and the old gh: people kept.
drill_account_gh_only_check() {
  CAP=120; local t0 out rc tests tl="$ROOT/tokenledger/hub"
  tests='TestNoGHPrefixOutsideIdentity TestPAccountInviteMachineCert TestMigrationKeepsGitHubPerson TestMeIdentities TestAdminsByPrincipalOrAddress'
  t0=$(now)
  for out in $tests; do
    grep -q "^func $out(" "$tl/api/person_test.go" 2>/dev/null || { WHY="the hub half's test $out is not in hub/api/person_test.go"; return 1; }
  done
  grep -q '^func isPerson(principal string) bool' "$tl/api/person.go" 2>/dev/null \
    || { WHY="there is no one isPerson any more"; return 1; }
  # "gh:" outside tests and comments
  out=$(grep -n '"gh:"' "$tl"/api/*.go | grep -v '_test.go:' | grep -v '^[^:]*:[0-9]*:[[:space:]]*//')
  [ -z "$out" ] || { WHY="a principal is judged by its gh: spelling again: $(printf '%s' "$out" | head -2 | sed "s|$tl/||" | tr '\n' ' ')"; return 1; }
  WHAT='没有 GitHub 的人：邀请（绑邮箱）→ 登录 → 绑机器 → 发证书 → 自己的 /v1/me；老 GitHub 人迁移前后快照一致；「是不是一个人」只问 isPerson（测试按名核对在，Go 门跑它们）'
  go_half "^($(printf '%s' "$tests" | tr ' ' '|'))\$" ./hub/api; case $? in
    0) WHAT='没有 GitHub 的人走完邀请 → 绑机器 → 发证书；老 GitHub 人迁移前后会话 / 机器 / 证书 / 单子快照一致；全仓 "gh:" 只剩 GitHub 身份一处（go test 五条）' ;;
    1) return 1 ;;
  esac
  SECS=$(since "$t0")
}

# c11_go_tests <file> <tests…> — the shared half of the C11 drills: every
# named test is in <file>, and (with a toolchain) go test runs them green.
c11_go_tests() {
  local file="$1" t out rc tl="$ROOT/tokenledger/hub"; shift
  for t in "$@"; do
    grep -q "^func $t(" "$tl/api/$file" 2>/dev/null || { WHY="the hub half's test $t is not in hub/api/$file"; return 1; }
  done
  go_half "^($(printf '%s' "$*" | tr ' ' '|'))\$" ./hub/api; case $? in 0) GO_RAN=1 ;; 1) return 1 ;; esac
}

drill_wechat_first_scan_autocreate() {
  CAP=120; local t0 tl="$ROOT/tokenledger/hub"; GO_RAN=0
  t0=$(now)
  # The first scan's branch hands off to the binding page and nothing else.
  grep -q 'http.Redirect(w, r, "/auth/wechat/bind", http.StatusFound)' "$tl/api/wechat_auth.go" 2>/dev/null \
    || { WHY="the first scan no longer goes to the binding page (wechat_auth.go)"; return 1; }
  c11_go_tests signin_ways_test.go TestWeChatFirstScanOpensNoAccount TestWeChatTwoRoadsOnePerson TestWeChatStateReplayRefused || return 1
  WHAT='第一次扫码进绑定页：不登录、不开号；按「挂上」或「按邀请进入」才动（测试按名核对在，Go 门跑它们）'
  [ "$GO_RAN" = 1 ] && WHAT='第一次扫码不开号、只在按下时绑到已登录的人或邀请；两条路同一 unionid 同一人；state 重放被拒（go test 三条）'
  SECS=$(since "$t0")
}

# ClaudeFleet's QR code taken by another product, or another product's by us
# (claude-fleet#4054, EPIC #4048 共同约定 4/12): the company service account is
# shared with space / 拓客 / 灵声, each owning a scene_id range in workbench.
drill_fleet_scene_cross() {
  CAP=120; local t0 tl="$ROOT/tokenledger/hub"; GO_RAN=0
  t0=$(now)
  grep -q 'wxSceneMin = 3000000' "$tl/api/wxgw.go" 2>/dev/null && grep -q 'wxSceneMax = 4000000' "$tl/api/wxgw.go" \
    || { WHY="ClaudeFleet's scene range [3000000, 4000000) is no longer the hub's (wxgw.go)"; return 1; }
  [ "$(grep -c 'if !wxSceneInRange(scene)' "$tl/api/wxgw.go")" -ge 2 ] \
    || { WHY="drawing or reading a code no longer refuses a scene outside the range (wxgw.go)"; return 1; }
  grep -q 'WHERE scene = ? AND browser_hash = ? AND consumed_at = 0' "$tl/store/hub_wx_scenes.go" 2>/dev/null \
    || { WHY="a code is no longer traded once, by the browser that drew it (ConsumeWxScene)"; return 1; }
  c11_go_tests wx_scan_test.go TestWxSceneCross TestWxScanNotListedApplies TestWxGatewayToken || return 1
  WHAT='入口只在 [3000000, 4000000) 出码、只问这一段；码只在出码的浏览器里换一次会话（测试按名核对在，Go 门跑它们）'
  [ "$GO_RAN" = 1 ] && WHAT='40 个浏览器出的码全在本段；别的浏览器拿同一 scene 被拒且不问 workbench；段外 scene 不问；换过的码重放被拒；名单外的不建人（go test 三条）'
  SECS=$(since "$t0")
}

# A forged or replayed return from workbench's web-authorisation relay signs
# someone in inside WeChat (claude-fleet#4055, EPIC #4048 C7): the relay sends
# the openid back on the browser's URL, so a callback is only as good as its
# signature, its time, its nonce's binding to this browser and its one use.
drill_wx_relay_forged() {
  CAP=120; local t0 tl="$ROOT/tokenledger/hub"; GO_RAN=0
  t0=$(now)
  grep -q 'hmac.Equal(\[\]byte(sig), \[\]byte(wxRelaySig(s.WxGW.Token' "$tl/api/wx_relay.go" 2>/dev/null \
    || { WHY="the relay callback no longer checks the signature with the gate token (wx_relay.go)"; return 1; }
  grep -q '!constantTimeEqual(nonce, flow.State)' "$tl/api/wx_relay.go" \
    || { WHY="the relay callback no longer ties the nonce to the browser that started the hop (wx_relay.go)"; return 1; }
  grep -q 'SpendSigninValue(spentHash("wx-relay", nonce)' "$tl/api/wx_relay.go" \
    || { WHY="a relay callback is no longer one use (wx_relay.go)"; return 1; }
  c11_go_tests wx_relay_test.go TestWxRelayRefused TestWxRelaySignsInListed TestWxRelayNotListedApplies || return 1
  WHAT='中转回跳只认：入口那把密钥的签名 · 5 分钟内的时间 · 本浏览器发起的 nonce · 只用一次（测试按名核对在，Go 门跑它们）'
  [ "$GO_RAN" = 1 ] && WHAT='签名错 / 过期 / 来自未来 / 别的浏览器 / 没有发起 / 中转报错 / 重放全被拒且不发会话、不再自动跳；名单内的进、名单外的到 /apply（go test 三条）'
  SECS=$(since "$t0")
}

drill_email_link_replay() {
  CAP=120; local t0 tl="$ROOT/tokenledger/hub"; GO_RAN=0
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

# ---- apply-flood (#4051, EPIC #4048 C3): one person refreshing /apply, double
# clicking or racing two replicas must leave ONE pending request — the table holds
# it (a partial unique index on (kind, subject) WHERE state = 'pending'), the page
# answers a second submit 409 with the first, and one address sends at most five
# an hour whoever it claims to be.
drill_apply_flood() {
  CAP=120; local t0 tl="$ROOT/tokenledger/hub" out rc; GO_RAN=0
  t0=$(now)
  grep -q "CREATE UNIQUE INDEX IF NOT EXISTS idx_hub_access_requests_pending ON hub_access_requests(kind, subject) WHERE state = 'pending'" \
    "$tl/store/schema.sql" 2>/dev/null || { WHY="nothing in the table holds one pending request per sign-in (schema.sql)"; return 1; }
  grep -q '^func TestAccessRequestsOnePending(' "$tl/store/access_requests_test.go" 2>/dev/null \
    || { WHY="the store's racing-submit test is gone (access_requests_test.go)"; return 1; }
  c11_go_tests access_requests_test.go TestApplySubmitEditWithdraw TestApplyPerAddressLimit TestApplyCooldown || return 1
  if [ "$GO_RAN" = 1 ]; then
    out=$(cd "$ROOT/tokenledger" && GOFLAGS='' GOPROXY=off GOTOOLCHAIN=local \
          go test -count=1 -run '^TestAccessRequestsOnePending$' ./hub/store 2>&1); rc=$?
    [ "$rc" = 0 ] || { WHY="eight racing submits did not leave one pending (go test): $(printf '%s' "$out" | head -4 | tr '\n' ' ')"; return 1; }
  fi
  WHAT='同一登录一条待审：表上的部分唯一索引兜底，第二次提交 409 并显示原来那条，同一地址一小时 5 条（测试按名核对在，Go 门跑它们）'
  [ "$GO_RAN" = 1 ] && WHAT='8 个并发提交只留 1 条待审；页面第二次提交 409 显示原来那条；冷却期内交不了、撤回后能重交；同一地址第 6 条 429（go test）'
  SECS=$(since "$t0")
}

# ---- apply-reaches-app (#4050, EPIC #4048 C2): a person the list does not name
# signs in (GitHub, WeChat, a proven mail) and gets only the applicant note —
# no principal, no hub_users row, no session — and that note opens nothing but
# /apply: /app, /v1/me, /admin answer it as they answer nobody.
drill_apply_reaches_app() {
  CAP=120; local t0 tl="$ROOT/tokenledger/hub"; GO_RAN=0
  t0=$(now)
  grep -q 'Name: applicantCookie, Value: v, Path: applicantPath,' "$tl/api/applicant.go" 2>/dev/null \
    || { WHY="the applicant note is no longer kept to /apply (applicant.go)"; return 1; }
  [ "$(grep -l 'r.Cookie(applicantCookie)' "$tl"/api/*.go 2>/dev/null | grep -v _test | wc -l | tr -d ' ')" = 1 ] \
    || { WHY="something besides applicantFrom reads ccq_applicant (hub/api)"; return 1; }
  c11_go_tests not_listed_test.go TestApplicantNoteReachesNothingElse TestNotListedEveryWayLandsOnApply TestRealRefusalsKeepTheDenyPage || return 1
  WHAT='申请者 cookie 只给 /apply：Path 限在 /apply，只有 applicantFrom 读它（测试按名核对在，Go 门跑它们）'
  [ "$GO_RAN" = 1 ] && WHAT='名单外的 GitHub / 微信 / 邮箱登录都 302 /apply、不建人不发会话；那张 cookie 打 /app、/v1/me、/admin 和没登录一样；removed、坏邀请仍是拒绝页（go test 三条）'
  SECS=$(since "$t0")
}

# ---- notify-leaks-secret (#4053, EPIC #4048 C5 · 共同约定 9): the gate to
# workbench (CCQUOTA_WX_INTERNAL_TOKEN) mints the whole service account's
# access token, so neither it nor the token it mints may reach a log, an audit
# row, the outbox or a notice — whatever fails on the way.
drill_notify_leaks_secret() {
  CAP=120; local t0 tl="$ROOT/tokenledger/hub" f; GO_RAN=0
  t0=$(now)
  [ -f "$tl/api/notify.go" ] || { WHY="there is no one way out for a notice (hub/api/notify.go)"; return 1; }
  # the gate is read in wxgw.go alone
  for f in $(grep -l 'x-internal-token' "$tl"/api/*.go 2>/dev/null | grep -v '_test\.go$'); do
    [ "${f##*/}" = wxgw.go ] || { WHY="${f##*/} sends the workbench gate itself, not through wxgw.go"; return 1; }
  done
  grep -q 'errcode %d' "$tl/api/wxgw.go" 2>/dev/null \
    || { WHY="a WeChat failure no longer says only its errcode (wxgw.go)"; return 1; }
  c11_go_tests notify_test.go TestNotifyLeaksNoSecret || return 1
  WHAT='口令只在 wxgw.go 读，失败只带 errcode；通知出口不带原文（测试按名核对在，Go 门跑它）'
  [ "$GO_RAN" = 1 ] && WHAT='502/连不上/换 token/取关/回显口令的 errmsg/SMTP 拒收全走一遍，日志、审计、发件箱、信和模板里没有口令也没有 access_token（go test）'
  SECS=$(since "$t0")
}

# A copied node.env / machine.env token used from somewhere else (issue #3699):
# a node that registered its key and said bearer_off is refused its bare token,
# a signature is good once and for two minutes, and the node's signer and the
# hub's verifier agree on a fixed vector.
drill_node_token_replayed() {
  CAP=120; local t0 tl="$ROOT/tokenledger/hub" d out; GO_RAN=0
  t0=$(now)
  grep -q 'func (s \*Server) nodeAuth(' "$tl/api/node_sig.go" 2>/dev/null \
    || { WHY="there is no one nodeAuth that reads a FleetSig signature (node_sig.go)"; return 1; }
  for f in fleet_move.go:nodeEndpoint fleet_session_cred.go:sessionCredNode; do
    sed -n "/^func (s \*Server) ${f#*:}(/,/^}/p" "$tl/api/${f%%:*}" | grep -q 's.nodeAuth(r)' \
      || { WHY="${f#*:} does not authenticate through nodeAuth (${f%%:*})"; return 1; }
  done
  # every other door that reads a node token goes through it too (#3710): only
  # nodeAuth itself, a token just minted (join · login node), the machine link's
  # login hello and the revoke list may look a token hash up by hand
  for f in $(grep -l 'EndpointByTokenHash' "$tl"/api/*.go 2>/dev/null | grep -v '_test\.go$'); do
    case "${f##*/}" in node_sig.go|fleet_join.go|fleet_login_node.go|node_machine.go|fleet_node_revoke.go) ;;
      *) WHY="${f##*/} reads a node token by hand (EndpointByTokenHash), not through nodeAuth"; return 1 ;;
    esac
  done
  grep -q 'CREATE TABLE IF NOT EXISTS fleet_sig_nonces' "$tl/store/fleet_node_keys.go" 2>/dev/null \
    || { WHY="spent nonces are not kept where both replicas see them (fleet_sig_nonces)"; return 1; }
  # the node's half: a key made 600, a header the hub's format, a refused overwrite
  d="$(mktemp -d "${TMPDIR:-/tmp}/brk-sig.XXXXXX")"
  python3 -I "$ROOT/bin/fleet_node_sig.py" keygen "$d/k" >/dev/null 2>&1 \
    || { rm -rf "$d"; WHY="fleet_node_sig.py keygen failed"; return 1; }
  out="$(python3 -I "$ROOT/bin/fleet_node_sig.py" header "$d/k" GET /v1/node/self 2>&1)"
  case "$out" in
    'FleetSig keyid=nk_'*', ts='*', nonce='*', sig='*) ;;
    *) rm -rf "$d"; WHY="fleet_node_sig.py header printed: $out"; return 1 ;;
  esac
  if python3 -I "$ROOT/bin/fleet_node_sig.py" keygen "$d/k" >/dev/null 2>&1; then
    rm -rf "$d"; WHY="fleet_node_sig.py keygen overwrote a key"; return 1
  fi
  [ "$(python3 -c 'import os,sys; print("%o" % (os.stat(sys.argv[1]).st_mode & 0o777))' "$d/k")" = 600 ] \
    || { rm -rf "$d"; WHY="the node key is not 600"; return 1; }
  rm -rf "$d"
  c11_go_tests node_sig_test.go TestNodeSigOffAddsNothing TestNodeSigRegisterSignReplay TestNodeSigSessionCredNode TestNodeSigPythonVector || return 1
  c11_go_tests node_sig_callers_test.go TestNodeSigEnsureAndEveryDoor TestNodeSigEnsureOldHubMakesNothing TestNodeSigOneRequestTwoAsks || return 1
  WHAT='节点钥匙 600、不覆盖，签名头是入口的格式；入口一处 nodeAuth，nonce 两副本共用（测试按名核对在，Go 门跑它们）'
  [ "$GO_RAN" = 1 ] && WHAT='节点自己 Ensure 出钥匙并登记、每扇门（ingest · live · lease · place · quota-lease · credentials）签名都过；bearer_off 之后抄走的令牌在每扇门 401、也登记不了自己的钥匙；同一签名第二次 401；过期 / 未来 / 换路径 / 换方法 / 别的钥匙都拒；没钥匙的节点原样；Python 签的向量 Go 验得过（go test 七条）'
  SECS=$(since "$t0")
}

# ---- cred-policy-empties-machine (#3713): an allowlist write narrowing one
# account took a Linux machine's only Claude subscription with it; its person's
# every session then failed «no claude account … that the allowlists permit»,
# naming no list. The hub now refuses (409) a set that leaves a machine / person
# none of a provider it had, unless forced; the CLI says so (exit 5) and the web
# editor asks first; the session error names the list that refused each account.
drill_cred_policy_empties_machine() {
  CAP=120; local t0 tl="$ROOT/tokenledger/hub"; GO_RAN=0
  t0=$(now)
  grep -q 'func (s \*Server) credPolicyEmptied' "$tl/api/fleet_cred_policy.go" 2>/dev/null \
    || { WHY="the hub no longer judges a list that empties a provider (fleet_cred_policy.go)"; return 1; }
  grep -q '409) die 5' "$BIN/fleet-cred-policy.sh" && grep -q -- '--force' "$BIN/fleet-cred-policy.sh" \
    || { WHY="fleet-cred-policy.sh no longer answers the refusal (exit 5) or offers --force"; return 1; }
  grep -q 'would keep no' "$ROOT/extras/web-console/src/admin/pages/Pool.tsx" 2>/dev/null \
    || { WHY="the web editor no longer asks before forcing (the console's Pool.tsx)"; return 1; }
  c11_go_tests fleet_cred_policy_test.go TestCredPolicyRefusesEmptyingAProvider TestCredPolicyNoBindSaysWhy || return 1
  WHAT='收空一台机器 / 一个人某个 provider 的白名单写入 409、不变；--force 照写；deny / clear 不拦；会话报错点名拒它的那张白名单（测试按名核对在，Go 门跑它们）'
  [ "$GO_RAN" = 1 ] && WHAT='收空 claude / codex 的写入 409 点名、列表不变；force 照写；deny / clear 不拦；会话报错点名「not in machine … allowlist」（go test 两条）'
  SECS=$(since "$t0")
}

# ---- machine-policy-bypass (#3824): an operator pausing one person on a few
# machines — logins kept — had only subscription lists; a person's machine list
# that one door honours and another does not is no list. Every door a person
# meets a machine through asks the ONE reader (machineDenied): the connect side
# (managedLoginsOf, the relay), the entry door's keys, placement (auto, named,
# a named fleet, a restore), the node's lease (all withdrawn), the session pass
# (mint refused, a live one refused at its next verify), the relay credential;
# the client dims such a session and titles it 已停用（管理员限制）.
drill_machine_policy_bypass() {
  CAP=120; local t0 tl="$ROOT/tokenledger/hub/api" f n out rc; GO_RAN=0
  t0=$(now)
  grep -q '^func machineDenied(' "$tl/fleet_machine_policy.go" 2>/dev/null     || { WHY="the hub has no machine allowlist reader (fleet_machine_policy.go machineDenied)"; return 1; }
  # every door: <file> <how many readers it must call>
  for f in fleet_certs.go:allow.deny fleet_creds.go:machineDeniedFor fleet_session_cred.go:machineDeniedFor            fleet_relay_cred.go:machineDeniedFor fleet_relay_frl2.go:machineDenied fleet_entry.go:machineDenied            ssh_relay.go:machineDeniedFor fleet_write.go:denyEndpoint fleet_client_place.go:denyEndpoint fleet.go:denyEndpoint            fleet_routes.go:disabledMachinesOf fleet_home.go:disabledMachinesOf; do
    n=${f#*:}; f=${f%%:*}
    grep -q "$n(" "$tl/$f" 2>/dev/null || { WHY="$f no longer asks the machine allowlist ($n) — a door left open"; return 1; }
  done
  [ "$(grep -c 'denyEndpoint(' "$tl/fleet_write.go")" -ge 2 ]     || { WHY="fleet_write.go judges placement but not a start named at a fleet (worker_start fleet_id)"; return 1; }
  grep -q 'OFF_WORD = "已停用（管理员限制）"' "$BIN/fleet-hub-sessions.sh" && grep -q '"disabled" and not here' "$BIN/fleet-hub-sessions.sh" \
    || { WHY="the client's session cache no longer marks a disabled machine's rows (fleet-hub-sessions.sh)"; return 1; }
  grep -q '^def disabled_die' "$BIN/fleet-connect.py" && [ "$(grep -c 'disabled_die(info, want)' "$BIN/fleet-connect.py")" -ge 2 ] \
    || { WHY="fleet <machine> no longer names why a disabled machine is refused (fleet-connect.py)"; return 1; }
  out=$(bash "$BIN/fleet-machine-policy-selftest.sh" 2>&1); rc=$?
  [ "$rc" = 0 ] || { WHY="fleet-machine-policy.sh: $out"; return 1; }
  c11_go_tests fleet_machine_policy_test.go TestMachinePolicyGrammar TestMachinePolicyOffAddsNothing TestMachinePolicyPutGet \
    TestMachinePolicyLeaseWithdraws TestMachinePolicySessionPass TestMachinePolicyPlacement TestMachinePolicyHomeAndRoutes \
    TestMachinePolicyEntryKeys || return 1
  WHAT='每扇门都问同一张机器白名单：连接 / 中转 / 选家 / 入口钥匙 / 选机（自动、点名、指定 fleet、恢复）/ 租约 / 通行证 / 中转凭据；客户端把那台的会话标「已停用（管理员限制）」；CLI 自测过（Go 测试按名核对在，Go 门跑它们）'
  [ "$GO_RAN" = 1 ] && WHAT='名单外的机器：租约全部 withdrawn、另一个人照常；通行证不签、已签的下次校验就拒（不算吊销，解禁照用）；选机自动换一台、点名拒并说原因；连接 / 中转拒、disabled 说原因，全禁时不当成「没登录」；入口钥匙清空、解禁恢复；操作员不受限（go test 八条 + CLI 自测）'
  SECS=$(since "$t0")
}

# ---- svc-token-escalate (#4003, the SPACE EPIC C1): SPACE's back
# end holds a service token (fcs_<prefix8>_<secret>) that may dispatch, read and
# cancel runs on /v1/svc/ and nothing else. The break: that token, with every
# scope, against every /v1/fleet/* and /v1/node/* route the hub spells — and its
# own admin road — must get nothing more than no credential gets; a token
# without a route's scope is 403, a revoked one 401 at its very next call.
drill_svc_token_escalate() {
  CAP=120; local t0 tl="$ROOT/tokenledger/hub/api"; GO_RAN=0
  t0=$(now)
  grep -q '^func (s \*Server) svcGate(' "$tl/svc.go" 2>/dev/null \
    || { WHY="the hub has no service door (svc.go svcGate)"; return 1; }
  grep -q 'mux.Handle(SvcPrefix, s.svcMux())' "$tl/server.go" \
    || { WHY="/v1/svc/ is not mounted behind the service door (server.go)"; return 1; }
  grep -q 'mux.Handle(SvcAdminPath, s.viewerOnly(s.adminOnly(' "$tl/server.go" \
    || { WHY="the service admin road is not admin only (server.go)"; return 1; }
  c11_go_tests svc_test.go TestSvcTokenEscalate TestSvcScopeForbidden TestSvcRevokedIs401 TestSvcRotationTwoLive \
    TestSvcOnlyHashStored TestSvcDisable || return 1
  WHAT='服务令牌只开 /v1/svc/：管理与节点路由、它自己的管理口都拒；缺 scope 403，吊销 / 停用后下一次调用 401（Go 测试按名核对在，Go 门跑它们）'
  [ "$GO_RAN" = 1 ] && WHAT='全 scope 的服务令牌对每条 /v1/fleet/* /v1/node/* 路由拿到的不多于无凭据；/v1/fleet/svc 401；缺 scope 403；吊销 / 停用即 401；轮换两把并存、不许第三把；库里只有哈希（go test 六条）'
  SECS=$(since "$t0")
}

# ---- svc-usage-crosses-tenant (#4006, the SPACE EPIC C4): a service run's
# usage lands on another tenant or a person, or one tenant (or the whole
# service) uses up the pool for everyone. The break: two tenants' runs through
# the real credential proxy, one tenant's ceiling, then the service's, then a
# tight pool — each tenant is filed apart, a ceiling stops only what it names
# and never a person, the service yields a tight pool, and /v1/svc/usage
# agrees with what the callbacks carried.
drill_svc_usage_crosses_tenant() {
  CAP=120; local t0 tl="$ROOT/tokenledger/hub/api"; GO_RAN=0
  t0=$(now)
  grep -q 'u.Tenant = s.svcPassTenant(c)' "$tl/fleet_person_budget.go" 2>/dev/null \
    || { WHY="a proxy's usage row is no longer filed under its pass's tenant (fleet_person_budget.go)"; return 1; }
  grep -q 's.svcBudgetRefusal(c.Principal, s.svcPassTenant(c)' "$tl/fleet_credproxy.go" 2>/dev/null \
    || { WHY="the proxy's resolve no longer holds a service run to its budget (fleet_credproxy.go)"; return 1; }
  c11_go_tests svc_usage_test.go TestSvcProxyFilesByTenantAndStops TestSvcTenantLimitStopsOnlyThatTenant \
    TestSvcWholeBudgetStopsServiceNotPeople TestSvcOverBudgetFailureIsNotRetried TestSvcUsageMatchesCallbacks \
    TestSvcYieldsTightPool || return 1
  WHAT='服务运行的用量按通行证里的 tenant 记、人的行不带 tenant；单 tenant 到顶只挡它、整体到顶挡全部服务不挡人；池子紧时服务让；usage 接口与回调对得上（Go 测试按名核对在，Go 门跑它们）'
  [ "$GO_RAN" = 1 ] && WHAT='经真凭据代理：两 tenant 分开记（不混进人的）；ws:1 到顶 403、ws:2 与人照常；整体到顶两 tenant 都 403、人照常；派单 429 tenant_limit / quota_exceeded 不入队，队列里的派前结束，运行中超了不重试；池子紧时服务不选 ≥80% 的号、全紧就等、人照常；/v1/svc/usage 按 tenant 等于回调 usage 之和（go test 六条）'
  SECS=$(since "$t0")
}

# ---- release-key-outside-train (#3559, EPIC #3500 C17): the release signing
# private key lives only in the release train. A seed of a key the pinned root
# vouches for, planted in a sandbox conf dir (as an env file line) or set in the
# signing variable, must be FOUND by fleet-release-key.sh scan (exit 1) and the
# doctor's releasekey row must FAIL; removed, both are quiet. The hub half — a
# keyless hub builds unsigned, takes only a signature the root's chain vouches
# for, keeps no private key on its volume — is go-tested.
drill_release_key_outside_train() {
  CAP=120; local t0 sc="$WORK/rkot" out rc sign="$BIN/fleet-release-sign.py" tests='TestReleaseTrainSigned'
  command -v python3 >/dev/null 2>&1 || { WHY="no python3"; return 1; }
  t0=$(now)
  mkdir -p "$sc/conf" "$sc/home/.ssh" "$sc/home/.config" "$sc/home/.claude/fleet/.release"
  python3 "$sign" keygen "$sc/root.key" >/dev/null && python3 "$sign" keygen "$sc/train.key" >/dev/null || { WHY="keygen failed"; return 1; }
  python3 "$sign" pub "$sc/root.key" > "$sc/conf/release.pub"
  python3 "$sign" cert --by "$sc/root.key" --key "$(python3 "$sign" pub "$sc/train.key")" --role sign --add "$sc/chain.json" >/dev/null
  printf '{"key_chain": %s}\n' "$(cat "$sc/chain.json")" > "$sc/home/.claude/fleet/.release/manifest.json"
  scan() { env -u CCQUOTA_FLEET_RELEASE_KEY -u CCQUOTA_FLEET_RELEASE_PREV_KEY -u FLEET_RELEASE_SIGN_KEY HOME="$sc/home" FLEET_CONF_DIR="$sc/conf" "$@" bash "$BIN/fleet-release-key.sh" scan "$sc/conf" "$sc/home/.ssh" "$sc/home/.config" 2>&1; }
  out=$(scan); rc=$?
  [ "$rc" = 0 ] || { WHY="a clean sandbox scanned as holding a key: $out"; return 1; }
  # the break: the train's seed copied into this login's secrets
  printf 'SOME_TOKEN=%s\n' "$(cat "$sc/train.key")" > "$sc/conf/secrets.env"
  out=$(scan); rc=$?
  [ "$rc" = 1 ] && case "$out" in *FOUND*secrets.env*) :;; *) false;; esac \
    || { WHY="the train's key in secrets.env was not found (rc $rc): $out"; return 1; }
  out=$(env -u CCQUOTA_FLEET_RELEASE_KEY -u CCQUOTA_FLEET_RELEASE_PREV_KEY -u FLEET_RELEASE_SIGN_KEY HOME="$sc/home" FLEET_CONF_DIR="$sc/conf" bash "$BIN/fleet-doctor.sh" 2>&1 | grep releasekey)
  case "$out" in *FAIL*releasekey*) :;; *) WHY="the doctor's releasekey row did not FAIL: $out"; return 1;; esac
  rm -f "$sc/conf/secrets.env"
  out=$(scan FLEET_RELEASE_SIGN_KEY="$(cat "$sc/train.key")"); rc=$?
  [ "$rc" = 1 ] || { WHY="the signing variable set in a session was not found: $out"; return 1; }
  out=$(scan); rc=$?
  [ "$rc" = 0 ] || { WHY="removed, still found: $out"; return 1; }
  grep -q 'return errTrainSigns' "$ROOT/tokenledger/hub/api/fleet_release.go" \
    || { WHY="a keyless hub builds releases on its own again"; return 1; }
  grep -q 'environment: release-sign' "$ROOT/.github/workflows/release-train.yml" \
    && grep -q 'secrets.RELEASE_SIGN_KEY' "$ROOT/.github/workflows/release-train.yml" \
    || { WHY="the release train no longer holds the key (release-sign / RELEASE_SIGN_KEY)"; return 1; }
  grep -q '^func TestReleaseTrainSigned(' "$ROOT/tokenledger/hub/api/fleet_release_sign_test.go" 2>/dev/null \
    || { WHY="the hub half's test TestReleaseTrainSigned is gone"; return 1; }
  WHAT='签名私钥抄进登录的 secrets.env、或会话里设了签名变量：scan 找到（exit 1）、体检 releasekey FAIL；删掉即干净；入口无私钥只建未签清单、列车握 release-sign（测试按名核对在，Go 门跑它）'
  go_half "^($tests)\$" ./hub/api; case $? in
    0) WHAT='签名私钥抄进登录的 secrets.env、或会话里设了签名变量：scan 找到、体检 releasekey FAIL，删掉即干净；入口无私钥：只建未签清单、只认根钥匙背书的签名、卷上没有私钥，旧钥匙的机器自动改认根钥匙（go test）' ;;
    1) return 1 ;;
  esac
  SECS=$(since "$t0")
}

# ---- release-key-status-chain (#3844): status agrees with the fetcher's trust.
drill_release_key_status_chain() {
  CAP=60; local t0 out
  t0=$(now)
  out=$(python3 "$BIN/fleet-release-key-selftest.py" 2>&1) \
    || { WHY="release-key status: $out"; return 1; }
  WHAT='旧 pin 担保根则 status 成功且只读；未知、伪造、吊销链仍拒；托管与跟随运行时的登录按机器 pin 判断'
  SECS=$(since "$t0")
}

# ---- release-key-revoked (#3559, EPIC #3500 C17): a manifest signed by a key
# the root vouched for, then revoked, must be refused by the Python check
# (fleet-release-verify.py, what fleet-release-fetch.py uses) — from the
# manifest's own list, and from the machine's memory (<pin>.revoked) once the
# list is gone — while a list forged by anyone but the root counts for nothing.
# The Go half (ccquota release fetch / verify, the hub's check) is go-tested.
drill_release_key_revoked() {
  CAP=120; local t0 sc="$WORK/rkr" out rc sign="$BIN/fleet-release-sign.py" ver="$BIN/fleet-release-verify.py"
  local tests='TestTrustRevoked TestTrustChain TestTrustPythonInterop' api='TestReleaseKeyRevoked'
  command -v python3 >/dev/null 2>&1 || { WHY="no python3"; return 1; }
  t0=$(now)
  mkdir -p "$sc"
  for k in root k1 mallory; do python3 "$sign" keygen "$sc/$k.key" >/dev/null || { WHY="keygen failed"; return 1; }; done
  python3 "$sign" pub "$sc/root.key" > "$sc/release.pub"
  python3 "$sign" cert --by "$sc/root.key" --key "$(python3 "$sign" pub "$sc/k1.key")" --role sign --add "$sc/chain.json" >/dev/null
  k1=$(python3 "$sign" show --anchor "$sc/release.pub" "$sc/chain.json" | awk '/^trusts/ { print $2; exit }')
  mk() { python3 - "$sc" "$1" "$k1" <<'PY'
import json, sys
sc, rev, k1 = sys.argv[1:4]
m = {"schema": 1, "sha": "a" * 40, "seq": 7, "key": k1, "key_chain": json.load(open(sc + "/chain.json")), "files": []}
if rev != "-":
    m["revoked"] = json.load(open(rev))
open(sc + "/manifest.json", "w").write(json.dumps(m))
PY
    python3 "$sign" manifest --key "$sc/k1.key" "$sc/manifest.json" | sed -n 1p > "$sc/sig"; }
  mk -
  out=$(python3 "$ver" "$sc/release.pub" "$sc/manifest.json" "@$sc/sig" 2>&1) || { WHY="k1's release refused before any revocation: $out"; return 1; }
  # a forged list — mallory in the root's name — counts for nothing
  python3 "$sign" revoke --by "$sc/mallory.key" --version 9 --out "$sc/forged.json" "$k1" >/dev/null
  mk "$sc/forged.json"
  out=$(python3 "$ver" "$sc/release.pub" "$sc/manifest.json" "@$sc/sig" 2>&1) || { WHY="a forged list revoked k1: $out"; return 1; }
  # the break: k1 leaks; the root signs a list and it rides in the release
  python3 "$sign" revoke --by "$sc/root.key" --version 1 --out "$sc/revoked.json" "$k1" >/dev/null
  mk "$sc/revoked.json"
  out=$(python3 "$ver" "$sc/release.pub" "$sc/manifest.json" "@$sc/sig" 2>&1); rc=$?
  [ "$rc" = 1 ] && case "$out" in *revoked*) :;; *) false;; esac || { WHY="k1's release taken with the root's list on board (rc $rc): $out"; return 1; }
  # the list gone from the next release: the machine's memory still refuses
  printf '{"version": 1, "keys": ["%s"]}\n' "$k1" > "$sc/release.pub.revoked"
  mk -
  out=$(python3 "$ver" "$sc/release.pub" "$sc/manifest.json" "@$sc/sig" 2>&1); rc=$?
  [ "$rc" = 1 ] || { WHY="the machine forgot k1 was revoked: $out"; return 1; }
  grep -q 'save_revoked(self.pubkey + ".revoked"' "$BIN/fleet-release-fetch.py" \
    || { WHY="fleet-release-fetch.py no longer keeps the revoked ids it saw"; return 1; }
  grep -q 'relverify.signer_of(pub, m' "$BIN/fleet-node-core.py" \
    || { WHY="the root core's switch no longer holds the signer to the chain and the revocations"; return 1; }
  grep -q 'f.Trust.Keep(\*pub)' "$ROOT/tokenledger/agent/cli/release.go" \
    || { WHY="ccquota release fetch no longer keeps the revoked ids it saw"; return 1; }
  WHAT='根钥匙作废 k1：清单带作废单即拒；下一版不带了，机器记下的作废 id 照拒；伪造的作废单（非根钥匙签）不认（Go 半边测试按名核对在，Go 门跑它们）'
  go_half "^($(printf '%s %s' "$tests" "$api" | tr ' ' '|'))\$" github.com/verkyyi/claude-fleet/tokenledger/shared/release ./hub/api; case $? in
    0) WHAT='根钥匙作废 k1：Python 与 Go（ccquota 取包 / 校验目录、入口验签）都拒；下一版不带作废单，机器记下的照拒；伪造的作废单不认；两种语言读同一格式（go test + python）' ;;
    1) return 1 ;;
  esac
  SECS=$(since "$t0")
}

# ---- trial-transcript-cross (#4060, EPIC #4048 C12): a trial's conversation
# outlives its washed machine — kept on the hub, sealed under a key derived for
# that one principal, opened only with the session's own principal and put only
# into that person's next login; the conversation service takes an import only
# on a login with no conversation of its own.
drill_trial_transcript_cross() {
  CAP=120; local t0 tl="$ROOT/tokenledger/hub" out; GO_RAN=0
  t0=$(now)
  grep -q 'func (v \*Vault) OpenPerson(' "$tl/credvault/credvault.go" 2>/dev/null \
    || { WHY="no per-person seal in the vault (credvault SealPerson / OpenPerson)"; return 1; }
  grep -q 'OpenPerson(c.Sealed, &bundle, pid, trialConvoPurpose)' "$tl/api/fleet_try_slot.go" 2>/dev/null \
    || { WHY="the seed no longer opens the conversation as the trial's own principal (fleet_try_slot.go)"; return 1; }
  if grep -q 'TrialConvo(r\.\|TrialConvo(id\|TrialConvo(req' "$tl"/api/*.go 2>/dev/null; then
    WHY="a kept conversation is read by an id the request carries"; return 1
  fi
  c11_go_tests fleet_try_slot_test.go TestTrialConvoNeverCrosses TestTrialPauseAndResumeCarriesTheConversation || return 1
  if command -v node >/dev/null 2>&1; then
    out=$(node "$BIN/fleet-webchat-selftest.mjs" --only=trial 2>&1)
    printf '%s\n' "$out" | grep -q '^PASS fleet-webchat-selftest' \
      || { WHY="the webchat's export / import is red: $(printf '%s\n' "$out" | grep '^FAIL' | head -3 | tr '\n' ' ')"; return 1; }
    printf '%s\n' "$out" | grep -qF 'ok   N an import onto a login that has a conversation of its own is refused 409' \
      || { WHY="the conversation service no longer refuses an import onto a login with its own"; return 1; }
  fi
  WHAT='甲的对话按甲派生的钥匙封存，换成乙打不开、种到乙的号上什么也没有；只认当前会话的 principal；对话服务只往空号里导入（测试按名核对在，Go 门跑它们；node 跑网页对话那半）'
  [ "$GO_RAN" = 1 ] && WHAT='甲的对话封存后乙打不开、贴到乙的行上也只认甲；乙的座位种不进甲的；甲暂停后继续，在一台干净的号上续上自己的对话（go test）；对话服务导出 / 导入、往已有对话的号上导入 409（node）'
  SECS=$(since "$t0")
}

# ---- trial-dirty-handout (#4060): a trial's machine given back goes through
# #3504's wash — reset, bin/fleet-login-reset-check.py, recycleLeftovers — and
# only a clean answer makes it a spare; the washing row is handed to a spare
# holder so the person is free at once, and a dirty wash stays failed
# (spare_failed), never handed to the next person.
drill_trial_dirty_handout() {
  CAP=120; local t0 tl="$ROOT/tokenledger/hub"; GO_RAN=0
  t0=$(now)
  grep -q 'FleetAccountRequest{Action: "remove", PrincipalID: pid' "$tl/api/fleet_try_budget.go" 2>/dev/null \
    || { WHY="a trial's release no longer goes through the operator's remove (the #3504 wash)"; return 1; }
  grep -q 's.trialGiveBack(pid, a, now)' "$tl/api/fleet_try_budget.go" 2>/dev/null \
    || { WHY="a trial's release no longer hands the washing login off the person (trialGiveBack)"; return 1; }
  grep -q 'state IN (?, ?)`,' "$tl/store/fleet_trials.go" 2>/dev/null && grep -q 'AccountResetPending, AccountResetting)' "$tl/store/fleet_trials.go" \
    || { WHY="HandOffWash no longer takes only a login that is being washed"; return 1; }
  c11_go_tests fleet_try_slot_test.go TestTrialReleaseWashesBeforeTheNext || return 1
  c11_go_tests fleet_recycle_test.go TestRecycleNeverHandsOutAnUncleanWash || return 1
  WHAT='试用放回的号走洗号：dirty 的留 failed、不进预备池；洗净的才成备用；人立刻和这台脱钩（测试按名核对在，Go 门跑它们）'
  [ "$GO_RAN" = 1 ] && WHAT='试用被巡检放回 → reset：说 dirty 的那台 failed、永不成备用；clean 的成备用；放回那刻人已不挂这个号、家也清了（go test）'
  SECS=$(since "$t0")
}

# ---- trial-pause-not-recycled (#4262): endTrial took back only an active
# seat — a trial whose login's last op had failed was released 「先暂停」 with
# its login never washed, left failed under the person, and the machine's
# spares ran out. Now every managed row the remove takes goes back (active ·
# failed · unknown), the trial.release audit names each login and what it
# became, and the patrol washes what an ended trial still holds (trial.regive).
drill_trial_pause_not_recycled() {
  CAP=120; local t0 tl="$ROOT/tokenledger/hub"; GO_RAN=0
  t0=$(now)
  grep -q 'case store.AccountActive, store.AccountFailed, store.AccountUnknown:' "$tl/api/fleet_try_budget.go" 2>/dev/null \
    || { WHY="a trial's release no longer takes back a failed / unknown seat (trialWashable)"; return 1; }
  grep -q 'if s.SweepTrialStragglers(now) {' "$tl/api/fleet_try_slot.go" 2>/dev/null \
    || { WHY="the trial patrol no longer washes what an ended trial still holds (SweepTrialStragglers)"; return 1; }
  grep -q '^func (s \*Store) ReclaimedTrialsHolding(' "$tl/store/fleet_trials.go" 2>/dev/null \
    || { WHY="no store read for ended trials still holding a login (ReclaimedTrialsHolding)"; return 1; }
  c11_go_tests fleet_try_slot_test.go TestTrialPauseWashesAFailedSeat || return 1
  WHAT='暂停放回连 failed / unknown 的号一起洗；审计 logins= 写明每个号放回后成了什么；已结束还挂着号的试用由巡检补洗（测试按名核对在，Go 门跑它）'
  [ "$GO_RAN" = 1 ] && WHAT='一个 failed 的试用座位先暂停 → reset 发出、人立刻脱钩、洗净回到备用，trial.release 写 logins=…:failed→；已 reclaimed 还挂着 failed 号的试用 → 巡检发 reset、trial.regive（go test）'
  SECS=$(since "$t0")
}

# ---- spare-ready-unverified (#4673): a spare the hub held 「ready」 could not be
# used — no home, its proxy not serving it, no subscription — because only
# 「separated」 and 「fleet online」 were asked. Now the open / wash ends with
# fleet-login-ready.sh as the login (a session credential from the proxy, its
# home up, a first reply) and the hub hands only a spare whose op passed 3/3.
drill_spare_ready_unverified() {
  CAP=120; local t0 tl="$ROOT/tokenledger/hub" sb sess out f; GO_RAN=0
  t0=$(now)
  sb=$(mktemp -d "${TMPDIR:-/tmp}/spare-ready.XXXXXX"); sess="sparechk$$"
  mkdir -p "$sb/root/bin" "$sb/home/.config/claude-fleet/fleets/$sess"
  for f in "$ROOT"/bin/*; do ln -s "$f" "$sb/root/bin/"; done
  ln -s "$ROOT/conf" "$sb/root/conf"
  rm -f "$sb/root/bin/fleet-session-cred.sh"
  printf '#!/bin/bash\ncase "$1" in mint) printf "direct\\t18923\\tfcp1.test\\n" ;; esac\n' > "$sb/root/bin/fleet-session-cred.sh"
  # shellcheck disable=SC2016 # the stub's own variables
  printf '#!/bin/bash\n[ "${CLAUDE_CODE_OAUTH_TOKEN:-}" = fcp1.test ] && [ "${ANTHROPIC_BASE_URL:-}" = http://127.0.0.1:18923 ] || { echo "no session credential"; exit 1; }\n[ -f "$HOME/reply.fail" ] && { echo "API Error: 403 this login holds no claude account"; exit 1; }\necho ok\n' > "$sb/claude"
  chmod +x "$sb/root/bin/fleet-session-cred.sh" "$sb/claude"
  printf 'FLEET_SESSION=%s\n' "$sess" > "$sb/home/.config/claude-fleet/fleets/$sess/conf"
  chk() { FLEET_CLAUDE_BIN="$sb/claude" bash "$ROOT/bin/fleet-login-ready.sh" "$(id -un)" --home "$sb/home" --root "$sb/root" --wait "$1" 2>&1; }
  sr_down() { tmux -L "$sess" kill-server 2>/dev/null; rm -rf "${sb:?}"; }
  # no home: the credential passed, the home did not
  out=$(chk 0)
  case "$out" in "ready: FAIL home: "*" cred_ok="[0-9]*) ;; *) WHY="no home, check said: $out"; sr_down; return 1 ;; esac
  # the home up, the first reply refused
  tmux -L "$sess" -f /dev/null new-session -d -s "$sess" -n home || { WHY="cannot start a tmux server"; sr_down; return 1; }
  : > "$sb/home/reply.fail"
  out=$(chk 5)
  case "$out" in "ready: FAIL reply: "*"403"*" cred_ok="*" home_ok="[0-9]*) ;; *) WHY="no subscription, check said: $out"; sr_down; return 1 ;; esac
  # all three
  rm -f "$sb/home/reply.fail"
  out=$(chk 5)
  printf '%s' "$out" | grep -Eq '^ready: cred_ok=[0-9]+ home_ok=[0-9]+ first_reply_ok=[0-9]+$' \
    || { WHY="a working login, check said: $out"; sr_down; return 1; }
  sr_down
  grep -q 'bash "$BIN/fleet-login-ready.sh" "$LOGIN"' "$ROOT/bin/fleet-login-new.sh" 2>/dev/null \
    || { WHY="fleet-login-new.sh no longer checks the login it opened (fleet-login-ready.sh)"; return 1; }
  grep -q 'READY_LINE' "$ROOT/bin/fleet-login-reset.sh" 2>/dev/null \
    || { WHY="a wash no longer carries the opener's ready: line to the hub (fleet-login-reset.sh)"; return 1; }
  grep -q 'res.Ready = readyResult(out.String())' "$tl/../agent/node_accounts.go" 2>/dev/null \
    || { WHY="the agent no longer reads the ready: line (readyResult)"; return 1; }
  grep -q 'spareCheckedSQL("a.op_id", checked)' "$tl/store/fleet_spare.go" 2>/dev/null \
    || { WHY="a claim no longer asks for a spare that passed its check (store.ClaimSpare)"; return 1; }
  grep -q 's.recordAccountCheck(m.OpID, epID, res, time.Now())' "$tl/api/fleet_accounts.go" 2>/dev/null \
    || { WHY="the hub no longer keeps a create's check (applyAccountResult → recordAccountCheck)"; return 1; }
  c11_go_tests fleet_spare_test.go TestSpareHandedOnlyAfterThreeChecks TestSpareSettings || return 1
  WHAT='验收脚本当真跑：没家 → FAIL home（cred_ok 在）；家起来、首句 403 → FAIL reply（cred_ok · home_ok 在）；都好 → 三个时间戳；入口只领 3/3 的备用（测试按名核对在，Go 门跑它）'
  [ "$GO_RAN" = 1 ] && WHAT='验收脚本当真跑三种结局；首句失败 / 旧节点没验的备用就绪 0、领号不给、名册没验过 2、审计 spare.unchecked；验过 3/3 才领得到；spare_max 只收 0–2（go test）'
  SECS=$(since "$t0")
}

# ---- trial-no-subscription (#4260): a trial person is a fresh p: principal no
# administrator ever listed, and strict mode denies a person with no
# fleet.cred_allow.user.<pid> every subscription — the trial's first line was
# the proxy's 403 «this login holds no claude account». Now its person
# allowance is fleet.trial.cred_allow ("*" by default); [] makes the trial wait
# 「试用暂时没有可用订阅」 instead of placing it onto a 403.
# ---- spare-ready-lease-inflight (D0JC): the readiness check (#4673) leases
# INSIDE the create / reset that opens the login, while the hub's row is still
# creating / resetting; the lease knew only active rows, so every new login
# failed its own check (403 no_principal). The lease now answers that op's own
# login — fresh, on its machine, inside the op's window; a spare's wash only —
# and still refuses another login, another machine, an old token, the op's
# own node, a dropped op and one past its window.
drill_spare_ready_lease_inflight() {
  CAP=120; local t0 tl="$ROOT/tokenledger/hub"; GO_RAN=0
  t0=$(now)
  grep -q 'principal, err := s.principalForLease(ep.ID, host, osUser, time.Now())' "$tl/api/fleet_creds.go" 2>/dev/null \
    || { WHY="the node lease no longer answers a login inside its own op (fleet_creds.go principalForLease)"; return 1; }
  grep -q 'principal, err := s.principalForLease(ep.ID, host, user, now)' "$tl/api/fleet_session_cred.go" 2>/dev/null \
    || { WHY="a session pass no longer answers a login inside its own op (fleet_session_cred.go)"; return 1; }
  c11_go_tests fleet_lease_inflight_test.go TestLeaseInsideCreateOp TestLeaseInsideCreateOpRefusesStaleOrOld TestLeaseInsideResetOnlyForSpare || return 1
  WHAT='开号 / 洗备用中的就绪检查能租到凭据；别的登录、别的机器、op 之前的令牌、op 自己的节点、断线或超窗的 op 仍拒（测试按名核对在，Go 门跑它）'
  [ "$GO_RAN" = 1 ] && WHAT='creating 中以 op 的 join 新入网的登录租到 200（principal = 该行）；admin 自己 / mac-d 同名 / carol / op 前的令牌 / 超 15 分钟 / unknown / failed 均 403 no_principal；洗备用 200、洗人 403（go test 三条）'
  SECS=$(since "$t0")
}

drill_trial_no_subscription() {
  CAP=120; local t0 tl="$ROOT/tokenledger/hub"; GO_RAN=0
  t0=$(now)
  grep -q 's.trialUserAllow(settings, &pol)' "$tl/api/fleet_cred_policy.go" 2>/dev/null \
    || { WHY="credPolicyFor no longer gives a trial person fleet.trial.cred_allow (trialUserAllow)"; return 1; }
  grep -q 'return trialWaitNoSub' "$tl/api/fleet_try_gate.go" 2>/dev/null \
    || { WHY="admission no longer holds a trial that has no subscription (trialHold nosub)"; return 1; }
  grep -q 's.trialCredOnConvert(pid, by, now)' "$tl/api/fleet_try_budget.go" 2>/dev/null \
    || { WHY="approval no longer writes the trial's allowance as the member's own (convertTrial)"; return 1; }
  c11_go_tests fleet_trial_cred_test.go TestTrialCredAllow TestCheckTrialCredAllow || return 1
  WHAT='试用者没有个人白名单 key 也按 fleet.trial.cred_allow（默认 "*"）拿订阅；[] 时排队说「试用暂时没有可用订阅」；转正写成本人的白名单（测试按名核对在，Go 门跑它们）'
  [ "$GO_RAN" = 1 ] && WHAT='新试用 principal 无 user key ⇒ "*" 放行、列表只放列出的、[] 拒绝且领位回 nosub；本人的列表优先；转正后本人 key 为 "*"、不再是试用者（go test）'
  SECS=$(since "$t0")
}

# ---- cluster-pod-claude-leak (#4601): a person's pod read its owner's own
# allowance as the machine's, so an owner opened to "*" handed every new pod
# Claude too. Now credPolicyOf gates the provider on every cluster pod machine
# (fleet.cred_pod_providers, default codex) before any list is read.
drill_cluster_pod_claude_leak() {
  CAP=120; local t0 tl="$ROOT/tokenledger/hub"; GO_RAN=0
  t0=$(now)
  grep -q 'p.PodProviders = podProvidersOf(settings, machine)' "$tl/api/fleet_cred_policy.go" 2>/dev/null \
    || { WHY="credPolicyOf no longer gates the provider on a cluster pod (podProvidersOf)"; return 1; }
  c11_go_tests fleet_cred_pod_test.go TestClusterPodCodexOnly TestClusterPodOwnListKept TestCheckCredPodProviders || return 1
  WHAT='集群 POD（u-* / fleet-linux-*）只放 fleet.cred_pod_providers（默认 codex）：owner 是 "*" 的新 POD 拿得到 Codex、拿不到 Claude（测试按名核对在，Go 门跑它们）'
  [ "$GO_RAN" = 1 ] && WHAT='owner "*" 的新 POD：Codex 放、Claude 拒（cluster pods are Codex-only）；owner 列表只有 Codex 条目起作用；节点自己的名单照旧；普通机器不受影响；设置 * 关掉（go test）'
  SECS=$(since "$t0")
}

# ---- trial-slot-held (#4060): a trial left open, hidden or idle held its
# machine for 7 days. Now the 15 s patrol gives it back: no heartbeat 120 s,
# no input 240 s (warned at 180), 900 s of machine time across seats.
drill_trial_slot_held() {
  CAP=120; local t0 tl="$ROOT/tokenledger/hub"; GO_RAN=0
  t0=$(now)
  grep -q 'go s.SweepTrialSlots(now)' "$tl/api/fleet_alerts.go" 2>/dev/null \
    || { WHY="nothing runs the trial patrol on the 15 s tick (fleet_alerts.go)"; return 1; }
  c11_go_tests fleet_try_slot_test.go TestTrialSlotReleasesOnTime TestTrialConvosPurgedAfterADay || return 1
  WHAT='关页 2 分钟、没输入 4 分钟（3 分钟先提示）、额度用完各自放回，审计 trial.release reason=…（测试按名核对在，Go 门跑它们）'
  [ "$GO_RAN" = 1 ] && WHAT='119 s 不放、121 s 放（hidden）；182 s 心跳带「1 分钟后暂停」、241 s 放（idle）；用满 900 s 放（time）并指去申请；名额当场空出；对话 24 h 后删（go test）'
  SECS=$(since "$t0")
}

# ---- trial-idle-while-opening (#4235): a seat still opening (no home, nothing
# to type into) was idled out at 252 s and the trial counted as tried. Now the
# idle lines count from ready_at only; a seat not ready in open_slow_secs goes
# back uncharged and the person waits again in their place.
drill_trial_idle_while_opening() {
  CAP=120; local t0 tl="$ROOT/tokenledger/hub"; GO_RAN=0
  t0=$(now)
  grep -q 'if t.ReadyAt.IsZero() {' "$tl/api/fleet_try_slot.go" 2>/dev/null \
    || { WHY="the trial patrol no longer holds the idle clock while a seat opens (fleet_try_slot.go)"; return 1; }
  grep -q 'release = s.Store.RequeueTrial' "$tl/api/fleet_try_budget.go" 2>/dev/null \
    || { WHY="a seat that did not open is no longer requeued uncharged (fleet_try_budget.go)"; return 1; }
  c11_go_tests fleet_try_slot_test.go TestTrialIdleNotWhileOpening TestTrialSlotReleasesOnTime || return 1
  WHAT='开位期间不计 idle；开好后 240 秒没输入才放；300 秒没开好放回重排、不扣用时、不算试过、告警 trial_open_slow（测试按名核对在，Go 门跑它们）'
  [ "$GO_RAN" = 1 ] && WHAT='开位 241 s 不放不提示；开好后 239 s 不放、241 s 放（idle）；没开好 301 s 放回重排、用时 0、原位排队、告警点名 mac-d、再领不是 tried；那台有位开好即清告警（go test）'
  SECS=$(since "$t0")
}

# ---- trial-host-no-spare (#4259): least-busy ranks room before a ready spare,
# so a trial picked a machine with room and no spare (its failed one stopping the
# refill) over one with a busy CPU and two ready, and waited «busy» for good. Now a
# trial's candidates are the machines holding a ready spare; none ⇒ no_spare
# and trial_no_spare.
drill_trial_host_no_spare() {
  CAP=120; local t0 tl="$ROOT/tokenledger/hub"; GO_RAN=0
  t0=$(now)
  grep -q 'if spareOnly && !c.spare {' "$tl/api/fleet_accounts.go" 2>/dev/null \
    || { WHY="a trial's machine pick no longer skips machines without a ready spare (fleet_accounts.go pickMachine)"; return 1; }
  grep -q 's.trialMachine(now)' "$tl/api/fleet_try.go" 2>/dev/null \
    || { WHY="the trial claim no longer picks through trialMachine (fleet_try.go)"; return 1; }
  grep -q 'AlertTrialNoSpare = "trial_no_spare"' "$tl/store/fleet_alerts.go" 2>/dev/null \
    || { WHY="no trial_no_spare alert kind (store/fleet_alerts.go)"; return 1; }
  c11_go_tests fleet_try_spare_test.go TestTrialPicksAMachineWithASpare || return 1
  WHAT='试用只在有就绪备用的机器里挑；都没有 ⇒ reason=no_spare + 告警 trial_no_spare（测试按名核对在，Go 门跑它）'
  [ "$GO_RAN" = 1 ] && WHAT='A 有余量 0 备用、B 过 CPU 线 1 备用 ⇒ 领到 B；再来一人 ⇒ waiting no_spare、审计 trial.queued reason=no_spare、告警 trial_no_spare（go test）'
  SECS=$(since "$t0")
}

drill_credential_quota_unbound() {
  CAP=120; local t0; GO_RAN=0
  t0=$(now)
  c11_go_tests fleet_credential_quota_test.go TestCredentialQuotaUnbound TestCredentialQuotaIsolation || return 1
  WHAT='无 UUID 的 OAuth 凭据独立计量；重复 Token 去重、换 Token 不继承旧读数（Go 门验证）'
  SECS=$(since "$t0")
}

drill_browser_import_access_crossed() {
  CAP=120; local t0 out rc
  t0=$(now)
  grep -q '^func TestBrowserCacheRejectsReplacedSecret(' "$ROOT/tokenledger/hub/credvault/browser_import_test.go" \
    || { WHY="browser import has no credential replacement regression"; return 1; }
  WHAT='导入保存与缓存之间替换 / 刷新同名行，旧 access 被拒且新行不变；正常导入保留 MeterID（Go 门验证）'
  go_half '^TestBrowserCache(RejectsReplacedSecret|PreservesSavedIdentity)$' ./hub/credvault; case $? in
    0) WHAT='实际交错两份 Vault：替换和同身份刷新均拒旧 access；原行逐字节不变，正常导入保留配对与 MeterID（go test）' ;;
    1) return 1 ;;
  esac
  SECS=$(since "$t0")
}

# This file runs part 1/3 using bin/break-it-durations.txt; the rest are its
# part files (issue #2694). A weight change must select the whole family.
: "${BREAK_PART:=1/3}"
cred_run_drills "$0"
