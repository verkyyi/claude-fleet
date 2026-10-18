#!/bin/bash
# fleet-cn-probe-diag.sh [--run-dir DIR] [--run-id ID] [--sources "here kube client pod"]
#   — ONE read-only, redacted diagnosis of the China probe's road (issue #4303).
#
# The probe once said only `codex` / `cert` / `list`: a Codex turn refused 403
# «no upstream credential» (#4290) and a pod whose account opener was disabled
# (the runtime dir group-writable, #4301 — the agent said only «no logins to
# serve») each took rounds of guessing. This reads, once, what each part says of
# itself — never through a second identity reader, never writing anything:
#
#   here    this computer: the hub's /version (hub · its commit · the client it ships)
#   kube    (only where kubectl reaches the cluster) the test pod: name · UID ·
#           phase · start · restarts · node, the fleet container's image and the
#           digest it RUNS (imageID); then, inside it as the pod's login
#           (kubectl exec, read-only commands only), the pod readings below
#   client  the China client box as the test login: its fleet version,
#           `fleet connect --cert-check` (principal · valid until · the hub's
#           word), `--pick <machine>` (listed or not)
#   pod     the pod's own readings, as its login — through kubectl exec, else
#           through `fleet connect <machine>` from the client: runtime and
#           ccquota versions; the admission gate's own reading (fleet_machine_admit
#           run against COPIES of its state files — nothing written), the CPU /
#           memory / disk numbers and who refused; the credential road (trust,
#           each provider's route, the proxy's last start and last `nocred`);
#           the account opener (node-agent.log: running with N logins, or the
#           reason it is off; the runtime dir's mode)
#
# Writes <run dir>/diag.json (0600, the run dir 0700) through
# bin/fleet-cn-probe-result.py diag: every key present, `unknown` when no source
# reached it, `sources.<name>` saying how each source went; every value redacted
# (a token, a cookie, a code, a key never lands — the credential files are never
# read at all). With no --run-dir, a run dir of its own under
# FLEET_CN_PROBE_RUNS (default $FLEET_CONF_DIR/global/cn-probe/runs) — the
# orchestrator's standalone road. Prints `DIAG <path>` and one line a key.
# Exit 0 written · 2 usage. Same knobs as the probe (FLEET_CN_PROBE_CLIENT · _KEY ·
# _KNOWN_HOSTS · _LOGIN · _MACHINE · _KUBECTL · _POD_NS); FLEET_CN_PROBE_DIAG_TIMEOUT
# bounds each source (30 s); FLEET_CN_PROBE_DIAG_SOURCES = --sources. Selftest
# seams: FLEET_CN_PROBE_NODE_LOG / _NODE_RUNTIME (the pod's node-agent.log and
# runtime dir).
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
RES="$BIN/fleet-cn-probe-result.py"

CLIENT=${FLEET_CN_PROBE_CLIENT:-root@47.119.157.4}
KEY=${FLEET_CN_PROBE_KEY:-$HOME/fleet-secrets/oss-drill/id_oss_drill}
KH=${FLEET_CN_PROBE_KNOWN_HOSTS:-$HOME/fleet-secrets/oss-drill/known_hosts}
AS=${FLEET_CN_PROBE_LOGIN:-drillcn}
MACHINE=${FLEET_CN_PROBE_MACHINE:-u-drillcn4150}
KUBECTL=${FLEET_CN_PROBE_KUBECTL:-kubectl}
NS=${FLEET_CN_PROBE_POD_NS:-fleet-workers}
TMO=${FLEET_CN_PROBE_DIAG_TIMEOUT:-30}

run_dir='' run_id='' sources=${FLEET_CN_PROBE_DIAG_SOURCES:-here kube client pod}
while [ $# -gt 0 ]; do
  case "$1" in
    --run-dir) run_dir=${2:-}; shift 2 ;;
    --run-id) run_id=${2:-}; shift 2 ;;
    --sources) sources=${2:-}; shift 2 ;;
    -h|--help) sed -n '2,/^set -uo/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
    *) echo "fleet-cn-probe-diag: unknown argument '$1'" >&2; exit 2 ;;
  esac
done
case "$AS" in ''|*[!a-z0-9_.-]*) echo "fleet-cn-probe-diag: the login is a login name" >&2; exit 2 ;; esac
case "$MACHINE" in ''|*[!A-Za-z0-9_.-]*) echo "fleet-cn-probe-diag: the machine is a machine name" >&2; exit 2 ;; esac
case "$TMO" in ''|*[!0-9]*) TMO=30 ;; esac
umask 077
if [ -z "$run_dir" ]; then
  [ -n "$run_id" ] || run_id=$(date -u +%Y%m%dT%H%M%SZ)-diag$(od -An -N2 -tx1 /dev/urandom 2>/dev/null | tr -dc 0-9a-f)
  case "$run_id" in *[!A-Za-z0-9_.-]*) echo "fleet-cn-probe-diag: --run-id is [A-Za-z0-9_.-]" >&2; exit 2 ;; esac
  run_dir=${FLEET_CN_PROBE_RUNS:-${FLEET_CONF_DIR:-$HOME/.config/claude-fleet}/global/cn-probe/runs}/$run_id
fi
[ -n "$run_id" ] || run_id=$(basename "$run_dir")
mkdir -p "$run_dir" && chmod 700 "$run_dir" 2>/dev/null || { echo "fleet-cn-probe-diag: cannot make $run_dir" >&2; exit 2; }
on() { case " $sources " in *" $1 "*) return 0 ;; esac; return 1; }
d() { printf 'DIAG %s\t%s\n' "$1" "$(printf '%s' "${2:-}" | tr '\t\n' '  ' | cut -c1-600)"; }
# bounded — a source that hangs is cut, never waited on (perl's alarm: macOS has no timeout(1))
bounded() { perl -e 'alarm shift; exec @ARGV or exit 127' "$TMO" "$@"; }

SSHO=(-o BatchMode=yes -o ConnectTimeout=15 -o ServerAliveInterval=10)
[ -n "$KEY" ] && SSHO+=(-i "$KEY")
[ -n "$KH" ] && SSHO+=(-o "UserKnownHostsFile=$KH")
on_client() { bounded ssh "${SSHO[@]}" "$CLIENT" "su - $AS -s /bin/bash" 2>&1; }

# pod_script — the pod's readings, run AS its login (kubectl exec or fleet
# connect). Read-only: the admission gate runs against copies of its two state
# files; no credential file is opened.
pod_script() {
  printf 'A=%s M=%s NL=%s RTD=%s\n' "$AS" "$MACHINE" "${FLEET_CN_PROBE_NODE_LOG:-/var/log/fleet-node/node-agent.log}" \
    "${FLEET_CN_PROBE_NODE_RUNTIME:-/var/db/fleet-node/runtime}"
  cat <<'EOS'
H=${HOME:-/home/$A}; [ -d "$H/.claude/fleet" ] || H=/home/$A
F=$H/.claude/fleet C=$H/.config/claude-fleet
d() { printf 'DIAG %s\t%s\n' "$1" "$(printf '%s' "${2:-}" | tr '\t\n' '  ' | cut -c1-600)"; }
rt=$(readlink "$RTD/current" 2>/dev/null)
lt=$(readlink "$F" 2>/dev/null); lt=${lt##*/}
d version.node_runtime "${rt:-unknown}${lt:+ (login link tree: $lt)}"
cq=$RTD/current/bin/ccquota; [ -x "$cq" ] || cq=$(command -v ccquota 2>/dev/null)
[ -z "$cq" ] || d version.ccquota "$("$cq" version 2>/dev/null | head -n 2 | tr '\n' ' ')"
# the admission gate's own reading, against copies of its state (nothing written)
if [ -f "$F/bin/fleet-lib.sh" ]; then
  t=$(mktemp -d)
  cp "$C/global/admit-cpu.window" "$t/w" 2>/dev/null
  out=$( (export FLEET_CONF_DIR="$C"; . "$F/bin/fleet-lib.sh" >/dev/null 2>&1
          FLEET_ADMIT_HELD_FILE=$t/held FLEET_ADMIT_CPU_WINDOW_FILE=$t/w; export FLEET_ADMIT_HELD_FILE FLEET_ADMIT_CPU_WINDOW_FILE
          why=$(fleet_machine_admit 2>/dev/null); rc=$?
          printf 'RC %s\nWHY %s\nCPU %s\nMEM %s\nADV %s\n' "$rc" "$why" "$(_fleet_admit_cpu 2>/dev/null)" \
            "$(fleet_mem_probe 2>/dev/null | head -n 1)" "${_fleet_admit_cpu_advised:-}") 2>/dev/null)
  rm -rf "$t"
  rc=$(printf '%s\n' "$out" | sed -n 's/^RC //p'); why=$(printf '%s\n' "$out" | sed -n 's/^WHY //p')
  adv=$(printf '%s\n' "$out" | sed -n 's/^ADV //p')
  cpu=$(printf '%s\n' "$out" | sed -n 's/^CPU //p'); mem=$(printf '%s\n' "$out" | sed -n 's/^MEM //p')
  [ -z "$cpu" ] || d admit.cpu "$(printf '%s' "$cpu" | awk '{printf "%s of %s cores used, %s%% throttled over %ss (cgroup)", $2, $3, $1, $4}')"
  [ -z "$mem" ] || d admit.mem "$(printf '%s' "$mem" | awk '{printf "pressure level %s, %s%% free", $1, $2}')"
  case "$rc" in
    0) d admit.verdict admit
       if [ -n "$adv" ]; then d admit.denier "none — CPU over its line is advice only on a person's pod"; d admit.why "$adv"
       else d admit.denier none; d admit.why "admitted — no reading over its line"; fi ;;
    1) d admit.verdict hold
       case "$why" in *memory*) d admit.denier "pod: fleet_machine_admit (memory)" ;; *cpu*|*load*) d admit.denier "pod: fleet_machine_admit (cpu)" ;; *) d admit.denier "pod: fleet_machine_admit" ;; esac
       d admit.why "$why" ;;
  esac
else
  d admit.verdict unknown; d admit.why "no $F/bin/fleet-lib.sh to ask"
fi
d admit.user_pod "FLEET_USER_POD=${FLEET_USER_POD:-unset here}"
d admit.disk "$(df -Pk "$H" 2>/dev/null | awk 'NR == 2 {printf "%s %d MB free of %d MB (%s used)", $6, $4 / 1024, $2 / 1024, $5}')"
lo=$(grep -v '^[[:space:]]*$' "$C/global/onboard.open.log" 2>/dev/null | tail -n 1)
d admit.last_open "${lo:-none (no onboard.open.log line)}"
# the credential road: what the proxy decided, never what it holds
d cred.trust "$(cat "$C/cred-proxy/trust.json" 2>/dev/null)"
if [ -f "$F/bin/fleet-cred-proxy.sh" ]; then
  for p in claude codex; do
    r=$(bash "$F/bin/fleet-cred-proxy.sh" route --provider "$p" --json 2>/dev/null)
    [ -z "$r" ] || d "cred.route_$p" "$r"
  done
fi
L=$C/logs/cred-proxy.log; [ -r "$L" ] || L=$F/logs/cred-proxy.log   # compat-1v: 下一批删 (the install's logs/, before #4668)
if [ -r "$L" ]; then
  st=$(grep '"ev": "start"' "$L" | tail -n 1); nc=$(grep '"ev": "nocred"' "$L" | tail -n 1)
  d cred.proxy_start "$st"; d cred.last_nocred "${nc:-none}"
  ts=$(printf '%s' "$st" | sed -n 's/.*"t": \([0-9]*\).*/\1/p'); tn=$(printf '%s' "$nc" | sed -n 's/.*"t": \([0-9]*\).*/\1/p')
  # the upstream's own answer to the newest forwarded turn (the central proxy's
  # 401 / 403 — «no subscription account» — is logged as a fwd with its status)
  fw=$(grep '"ev": "fwd"' "$L" | tail -n 1)
  tf=$(printf '%s' "$fw" | sed -n 's/.*"t": \([0-9]*\).*/\1/p'); sf=$(printf '%s' "$fw" | sed -n 's/.*"status": \([0-9]*\).*/\1/p')
  [ -z "$fw" ] || d cred.last_forward "$(printf '%s' "$fw" | python3 -c 'import json, sys
try: e = json.loads(sys.stdin.read())
except ValueError: sys.exit(0)
print("%s %s via %s (%s) → %s at %s" % (e.get("provider", "?"), e.get("path", "?"), e.get("route", "?"), e.get("up", "?"), e.get("status", "?"), e.get("t", "?")))' 2>/dev/null)"
  if [ -n "$tn" ] && [ "${tn:-0}" -ge "${ts:-0}" ] && [ "${tn:-0}" -ge "${tf:-0}" ]; then d cred.upstream "missing — the proxy refused a turn (no upstream credential) after its last start"
  elif [ -n "$sf" ] && [ "${tf:-0}" -ge "${ts:-0}" ] && [ "$sf" -ge 400 ] && [ "$sf" != 429 ]; then
    d cred.upstream "refused — the newest forwarded turn got $sf from upstream (see cred.last_forward; the turn's own words are in the probe's codex stage)"
  elif [ -n "$sf" ] && [ "${tf:-0}" -ge "${ts:-0}" ]; then d cred.upstream "answered — the newest forwarded turn got $sf"
  elif [ -n "$st" ]; then d cred.upstream "no refusal since the proxy's last start (nothing forwarded since)"
  fi
fi
# the account opener: the node program's own words, newest last
if [ -r "$NL" ]; then
  # the newest start line, and whatever said «off» after it: the reason said
  # once at start (no opener: …, #4302), else the bare loop line
  run=$(grep -nE 'agent --machine .*logins\)' "$NL" | tail -n 1); rn=${run%%:*}
  no=$(grep -n 'no opener:' "$NL" | tail -n 1); nn=${no%%:*}
  nl=$(grep -n 'no logins to serve' "$NL" | tail -n 1); ln=${nl%%:*}
  if [ "${nn:-0}" -gt "${rn:-0}" ]; then d opener.state disabled; d opener.reason "${no#*no opener: }"
  elif [ "${ln:-0}" -gt "${rn:-0}" ]; then d opener.state disabled
    d opener.reason "the node program serves no login and opens none (it says only «no logins to serve»; a ccquota before #4302 never names why)"
  elif [ -n "$run" ]; then d opener.state running; d opener.reason "${run#*:}"
  fi
else
  d opener.state unknown; d opener.reason "$NL not readable as $A"
fi
m=$(ls -ld "$RTD" 2>/dev/null | awk '{print $1, $3 ":" $4}')
if [ -n "$m" ]; then
  case "$m" in ?????w*) d opener.runtime_mode "$m — group-writable: the node program refuses an opener under it" ;;
    *) d opener.runtime_mode "$m" ;; esac
fi
EOS
}

collect() {
  local hub out p js
  if on here; then
    hub=$(bash "$BIN/fleet-hub-url.sh" 2>/dev/null)
    if [ -n "$hub" ] && js=$(curl -fsS -m "$TMO" "$hub/version" 2>/dev/null); then
      d source.here "ok $hub"
      printf '%s' "$js" | python3 -c 'import json, sys
d = json.load(sys.stdin)
for k, f in (("version.hub", "version"), ("version.hub_commit", "commit"), ("version.hub_client", "client_version")):
    if d.get(f): print("DIAG %s\t%s" % (k, d[f]))' 2>/dev/null
    else d source.here "no answer from ${hub:-the hub (no address here)}/version"; fi
  fi
  local podok=0
  if on kube; then
    if command -v "$KUBECTL" >/dev/null 2>&1 && js=$(bounded "$KUBECTL" -n "$NS" get pod -l "fleet/pod=$MACHINE" -o json 2>/dev/null); then
      printf '%s' "$js" | python3 -c 'import json, sys
items = json.load(sys.stdin).get("items") or []
items.sort(key=lambda p: p.get("metadata", {}).get("creationTimestamp", ""))
if not items:
    print("DIAG source.kube\tno pod labelled fleet/pod=%s" % sys.argv[1]); sys.exit(0)
p = items[-1]; m, s = p.get("metadata", {}), p.get("status", {})
print("DIAG source.kube\tok (%d pod%s)" % (len(items), "" if len(items) == 1 else "s"))
print("DIAG target.pod_name\t%s" % m.get("name", ""))
print("DIAG target.pod_uid\t%s" % m.get("uid", ""))
print("DIAG target.pod_phase\t%s" % s.get("phase", ""))
print("DIAG target.pod_started\t%s" % s.get("startTime", ""))
print("DIAG target.pod_node\t%s" % p.get("spec", {}).get("nodeName", ""))
cs = s.get("containerStatuses") or []
print("DIAG target.pod_restarts\t%s" % " ".join("%s=%s" % (c.get("name"), c.get("restartCount")) for c in cs))
for c in cs:
    if c.get("name") == "fleet":
        print("DIAG image.ref\t%s" % c.get("image", ""))
        print("DIAG image.digest\t%s" % (c.get("imageID", "").split("@")[-1] or "unknown"))
print("POD %s" % m.get("name", ""))' "$MACHINE" > "$run_dir/.kube.$$" 2>/dev/null
      grep -v '^POD ' "$run_dir/.kube.$$"
      p=$(sed -n 's/^POD //p' "$run_dir/.kube.$$"); rm -f "$run_dir/.kube.$$"
      if [ -n "$p" ] && on pod; then
        out=$(pod_script | bounded "$KUBECTL" -n "$NS" exec -i "$p" -c fleet -- bash -s 2>/dev/null)
        if printf '%s\n' "$out" | grep -q '^DIAG '; then
          d source.pod "ok (kubectl exec $p, as the pod's login)"; printf '%s\n' "$out" | grep '^DIAG '; podok=1
        else d source.pod "kubectl exec $p answered nothing"; fi
      fi
    else
      d source.kube "no $KUBECTL here, or the cluster did not answer"
    fi
  fi
  if on client; then
    out=$(printf '%s\n' 'cat ~/.local/share/claude-fleet/.client-version 2>/dev/null | sed -n "s/^version=/VER /p"; r=$(readlink ~/.claude/fleet 2>/dev/null); [ -z "$r" ] || echo "VER install ${r##*/}"' \
             "timeout $TMO fleet connect --cert-check 2>&1 | sed 's/^/CERT /'" \
             "timeout $TMO fleet connect --pick $MACHINE >/dev/null 2>&1 && echo 'PICK listed' || echo 'PICK not listed'" | on_client)
    if printf '%s\n' "$out" | grep -qE '^(VER|CERT|PICK) '; then
      d source.client "ok ($CLIENT as $AS)"
      d version.client "$(printf '%s\n' "$out" | sed -n 's/^VER //p' | head -n 1)"
      c=$(printf '%s\n' "$out" | sed -n 's/^CERT //p' | head -n 1 | tr '\t' ' ')
      d identity.cert "$c"
      d identity.principal "$(printf '%s' "$c" | sed -n 's/.*principal \([^ ]*\) .*/\1/p')"
      d identity.valid_until "$(printf '%s' "$c" | sed -n 's/.*有效至 \([^ ]*\).*/\1 (the client box'"'"'s local time)/p')"
      d identity.roster "$(printf '%s\n' "$out" | sed -n 's/^PICK //p' | head -n 1) — the hub's list for $AS"
    else
      d source.client "ssh $CLIENT as $AS: $(printf '%s\n' "$out" | tail -n 1)"
    fi
  fi
  if on pod && [ "$podok" = 0 ]; then
    out=$( { printf 'p=$(mktemp); cat > "$p" <<'"'"'POD'"'"'\n'; pod_script; printf 'POD\ntimeout %s fleet connect %s -- bash -l < "$p" 2>&1; rm -f "$p"\n' "$TMO" "$MACHINE"; } | on_client)
    if printf '%s\n' "$out" | grep -q '^DIAG '; then
      d source.pod "ok (fleet connect $MACHINE from the client, as $AS)"; printf '%s\n' "$out" | grep '^DIAG '
    else d source.pod "no reading from the pod: $(printf '%s\n' "$out" | tail -n 1)"; fi
  fi
}

collect | python3 "$RES" diag "$run_dir" "$run_id" "$AS" "$MACHINE"
