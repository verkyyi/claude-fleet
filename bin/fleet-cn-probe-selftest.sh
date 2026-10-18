#!/bin/bash
# fleet-cn-probe-selftest.sh — the China real-user path's patrol and its test road
# (issue #4180), offline: bin/fleet-cn-probe-watch.sh and bin/fleet-cn-probe-env.sh
# against a stub probe, gh, filer, ssh and kubectl. bin/fleet-cn-probe.sh itself
# walks a real machine in China and is run by hand / by the patrol, never here;
# only its syntax (bash 3.2 too) and its usage are checked. Gate 9 (`cn:`) is
# bin/fleet-stable-selftest.sh's section S.
#
#   A  off: no client key here, or FLEET_CN_PROBE=0 → nothing runs
#   B  green: `cn path` success on stable, last.json green, no issue filed
#   C  throttle: a second run inside FLEET_CN_PROBE_SECS walks nothing
#   D  red: one breakage per layer (cn-path-<layer>), failure status naming it,
#      one alert per issue, re-walked after FLEET_CN_PROBE_RED_SECS
#   E  --dry-run: says what it would post / file, changes nothing
#   F  green after red forgets the red; a probe with no verdict is red at `probe`
#   G  env ensure: the test pod rolled onto stable's `node image`; a pod already
#      on it is left; no status → left; client + identity ok read as ok
#
# The probe itself, offline (issue #4303) — the real bin/fleet-cn-probe.sh and the
# real bin/fleet-cn-probe-diag.sh against stub ssh / tmux / fleet / curl in a
# sandbox HOME (the client box, the pod and the person's terminal all local):
#   H  a Codex turn refused 403 «no upstream credential» on the NEW session's own
#      screen ends the wait within 10 s (upstream_no_credential, product); a
#      retried 429 and old errors in logs and other windows do not; a slow answer
#      passes; no answer at all still waits FLEET_CN_PROBE_ANSWER out
#   I  ensure failed (the drill identity could not be re-made): the patrol walks
#      no session, its result is env · ensure:identity, not product
#   J  the read-only diagnosis: the pod's CPU refusal with its real readings and
#      who refused; the account opener off and why; the identity expired (cert
#      stage env · identity_expired); the run dir 0700 / files 0600; nothing
#      credential-shaped in it; the admission's state files untouched
#   K  one result: stages carry start / end / secs / reason_code / evidence, the
#      verdict line and exit come from result.json, a pass is only a run with no
#      failed stage
# Recovery verification (issue #4304):
#   L  the round on a fake clock: a repeated start / begin runs one round, one run;
#      a dead run is abandoned, never counted; red, env, partial, an unread or
#      unexpected version and a clock run backwards never count; a new vector
#      restarts the streak; 3 in a row → done with 3 distinct runs as evidence;
#      the run and time budgets end it (exhausted)
#   M  the patrol for real: every walk (--now too) and each distinct skip is on
#      history.ndjson; a dead holder's lock is taken over; --recover walks at once,
#      the next ticks are recovery runs, done after 3, then the throttle again
#   N  the probe leaves none of its sessions on the pod: the client's `fleet close`
#      failing, the pod stops each by its fleet id; neither working, the key is
#      kept and the next run stops it first
# CNP_LEG=<H|I|J|K|L|M|N|O> runs one of these alone (the BREAK-IT drills do).
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/cnprobe-st.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
CHECKS=0
fail() { printf 'selftest FAIL: %s\n' "$1" >&2; exit 1; }
eq() { CHECKS=$((CHECKS + 1)); [ "$2" = "$3" ] || fail "$1 — expected [$2], got [$3]"; }
contains() { CHECKS=$((CHECKS + 1)); case "$2" in *"$3"*) ;; *) fail "$1 — does not contain [$3]:
$2" ;; esac; }
lacks() { CHECKS=$((CHECKS + 1)); case "$2" in *"$3"*) fail "$1 — contains [$3]:
$2" ;; esac; }

for f in fleet-cn-probe.sh fleet-cn-probe-watch.sh fleet-cn-probe-env.sh fleet-cn-probe-diag.sh; do
  bash -n "$BIN/$f" || fail "syntax: $f"
  [ ! -x /bin/bash ] || /bin/bash -n "$BIN/$f" || fail "syntax (/bin/bash): $f"
done
out=$(bash "$BIN/fleet-cn-probe.sh" --layers 'view' --repo nope 2>&1); eq "probe: --repo is owner/name" 2 "$?"
out=$(bash "$BIN/fleet-cn-probe.sh" --help 2>&1); contains "probe: help names the codex layer" "$out" "codex:<route>"

# ---- the offline probe rig (issue #4303) ------------------------------------
# rig — a sandbox HOME that is the client login AND the pod login, and stubs for
# every road the probe takes: ssh runs the remote script here, tmux runs a pane
# as a process group and captures its output, fleet answers the connect / route /
# ls / close / codex calls from $CNP_SCENARIO.
rig() {
  R="$WORK/rig"; rm -rf "$R"; mkdir -p "$R/shim" "$R/home/.config/claude-fleet/global" "$R/home/.claude" \
    "$R/home/.local/share/claude-fleet" "$R/tmux" "$R/node/runtime/sha-rt/bin" "$R/runs"
  mkdir -p "$R/home/.claude/fleet/logs" "$R/home/.config/claude-fleet/fleets/fleet"; ln -s "$BIN" "$R/home/.claude/fleet/bin"
  # the pod's graceful stop by fleet id: drops the key the stub `fleet ls` lists
  cat > "$R/stop" <<'SH'
#!/bin/bash
[ -z "${CNP_POD_STOP_FAIL:-}" ] || exit 1
echo "$*" >> "$CNP_TMUX_DIR/stops"
f=${2#fid:}; grep -v "/$f\$" "$CNP_TMUX_DIR/keys" > "$CNP_TMUX_DIR/keys.n"; mv -f "$CNP_TMUX_DIR/keys.n" "$CNP_TMUX_DIR/keys"
SH
  chmod +x "$R/stop"
  ln -s sha-rt "$R/node/runtime/current"
  printf 'export FLEET_HUB_URL="https://hub.test"\n' > "$R/home/.config/claude-fleet/fleet.conf"
  printf 'version=0123abc\n' > "$R/home/.local/share/claude-fleet/.client-version"
  cat > "$R/shim/ssh" <<'SH'
#!/bin/bash
[ -z "${CNP_SSH_DOWN:-}" ] || { echo "ssh: connect to host 47.0.0.1 port 22: Connection timed out" >&2; exit 255; }
last=${!#}
case "$last" in
  true) exit 0 ;;
  "su - "*) rest=${last#su - }; rest=${rest#* -s /bin/bash}; eval "exec bash $rest" ;;
  *) exec bash -c "$last" ;;
esac
SH
  printf '#!/bin/sh\nshift\nexec "$@"\n' > "$R/shim/timeout"
  printf '#!/bin/sh\necho "200 0.01s"\n' > "$R/shim/curl"
  cat > "$R/shim/tmux" <<'SH'
#!/bin/bash
d=$CNP_TMUX_DIR; [ "$1" = -L ] && shift 2
sub=$1; shift
case "$sub" in
  kill-server) for f in "$d"/*.pid; do [ -f "$f" ] || continue; kill -- -"$(cat "$f")" 2>/dev/null; rm -f "$f"; done ;;
  new-session) s=x; while [ $# -gt 1 ]; do [ "$1" = -s ] && s=$2; shift; done
    : > "$d/$s.out"; perl -e 'setpgrp(0, 0); exec @ARGV' bash -c "$1" > "$d/$s.out" 2>&1 < /dev/null &
    echo $! > "$d/$s.pid" ;;
  capture-pane) s=x; while [ $# -gt 0 ]; do [ "$1" = -t ] && s=$2; shift; done; cat "$d/$s.out" 2>/dev/null ;;
  list-sessions|has-session|list-clients) exit 1 ;;   # no other server here (fleet-client-retire.sh asks)
esac
exit 0
SH
  cat > "$R/shim/fleet" <<'SH'
#!/bin/bash
# the client's `fleet`, and the pod behind `fleet connect`
M=$CNP_MACHINE K="$CNP_TMUX_DIR/keys"
case "$1 $2" in
  'connect --cert-check')
    case "${CNP_CERT:-ok}" in
      ok) printf 'PASS\tprincipal drillcn · 有效至 2099-01-01T00:00:00 · 剩 9h00m · 入口接受\n' ;;
      expired) printf 'WARN\tprincipal drillcn · 有效至 2026-01-01T00:00:00（已过期）— 下次用时凭设备钥匙续上\n' ;;
    esac; exit 0 ;;
  'connect --pick') printf '{"machine": "%s"}\n' "$M"; exit 0 ;;
  'route '*) exit 0 ;;
  'ls --json') printf '['; sep=''; for k in $(cat "$K" 2>/dev/null); do printf '%s{"key": "%s"}' "$sep" "$k"; sep=,; done; echo ']'; exit 0 ;;
  'close '*) [ -z "${CNP_CLOSE_FAIL:-}" ] || exit 1   # the client's close answered nothing (#4304)
    grep -vx "$2" "$K" > "$K.n" 2>/dev/null; mv -f "$K.n" "$K"; exit 0 ;;
  'codex --new')
    w=${3##*：}
    echo "› $3"
    case "${CNP_SCENARIO:-answer}" in
      refused) echo "fleet: could not open a session: REFUSED AT_CAPACITY all-full: every machine is at its session cap or pausing new sessions — $M: 机器暂停接新：负载过高"; exit 1 ;;
    esac
    echo "${CNP_NEWKEY:-scratch-9}" >> "$K"
    # a line the session's road leaves behind, out of the pane's group (#4283)
    [ -z "${CNP_LEAK:-}" ] || perl -e 'setpgrp(0, 0); sleep 600' -- "$HOME/.claude/fleet/bin/fleet-connect.py" "$M" </dev/null >/dev/null 2>&1 &
    echo "GPT-6.1-Sol high · ~ ? for shortcuts"
    case "${CNP_SCENARIO:-answer}" in
      403) sleep 1; echo "■ unexpected status 403 Forbidden: cred-proxy: no upstream credential for account default, url: http://127.0.0.1:35583/codex/responses" ;;
      quota) sleep 1; echo "■ You've hit your usage limit. Visit https://chatgpt.com/settings/usage to purchase more credits or try again at Oct 23rd, 2026 5:44 PM." ;;
      sub403) sleep 1; echo "■ unexpected status 403 Forbidden: no subscription account for this session: no codex account in the vault for drill-x that this machine's allowlists permit: pool/default" ;;
      slow) sleep 2; echo "⚠ stream error: unexpected status 429 Too Many Requests; retrying 1/5 in 2s"; sleep 3; echo "$w" ;;
      answer) sleep 1; echo "$w" ;;
    esac
    sleep 900; exit 0 ;;
esac
if [ "$1" = connect ]; then
  shift; while [ $# -gt 0 ] && [ "$1" != -- ]; do v=$1; shift
    case "$v" in --verbose) printf 'fleet connect · %s · 每条线 3 次 TCP+SSH 握手\n  线路      地址                 成功  延迟(中位)\n* entry     1.2.3.4:22022        3/3   12ms\n→ 选中 entry\n' "$M" ;; esac
  done
  shift
  [ "$*" = hostname ] && { echo "$M"; exit 0; }
  exec bash -c "$*"
fi
echo "fleet stub: $*" >&2; exit 2
SH
  chmod +x "$R/shim/"*
}
# probe_run [layers] — the real probe in the rig; POUT · PRC · PSECS · PRES (result.json)
probe_run() {
  local t0=$SECONDS
  POUT=$(PATH="$R/shim:$PATH" HOME="$R/home" FLEET_CONF_DIR="$R/home/.config/claude-fleet" CNP_TMUX_DIR="$R/tmux" \
    CNP_MACHINE=u-test1 FLEET_CN_PROBE_MACHINE=u-test1 FLEET_CN_PROBE_KEY='' FLEET_CN_PROBE_KNOWN_HOSTS='' \
    FLEET_CN_PROBE_RUNS="$R/runs" FLEET_CN_PROBE_KUBECTL=/nonexistent/kubectl FLEET_CN_PROBE_DIAG_SOURCES='client pod' \
    FLEET_CN_PROBE_NODE_LOG="$R/node/node-agent.log" FLEET_CN_PROBE_NODE_RUNTIME="$R/node/runtime" \
    FLEET_CN_PROBE_ANSWER=${FLEET_CN_PROBE_ANSWER:-20} FLEET_CN_PROBE_TIMEOUT=10 FLEET_CN_PROBE_POD_STOP="$R/stop" \
    bash "$BIN/fleet-cn-probe.sh" --layers "${1:-codex}" 2>&1); PRC=$?
  PSECS=$((SECONDS - t0))
  PRES=$(printf '%s\n' "$POUT" | sed -n 's/^RESULT //p' | tail -n 1)
}
# rj <python expr over r = result.json> — one value out of the result
rj() { python3 -c 'import json, sys; r = json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$PRES" "$1"; }

leg_H() {   # a session's own terminal error ends the wait; nothing else does
  rig
  # yesterday's errors: a 403 in the proxy's log, a refusal in another window's output
  printf '{"t": 1, "ev": "nocred", "acct": "default", "route": "direct", "err": "FileNotFoundError"}\n' > "$R/home/.config/claude-fleet/old-cred-proxy.log"
  printf 'unexpected status 403 Forbidden: no upstream credential\n' > "$R/tmux/other.out"
  CNP_SCENARIO=403 FLEET_CN_PROBE_ANSWER=300 probe_run
  eq "H: a 403 on the session's screen → 不通 (exit 1)" 1 "$PRC"
  contains "H: …says the session's own error" "$POUT" "FAIL codex:entry the new Codex session ended its turn with an error"
  contains "H: …with its words" "$POUT" "no upstream credential for account default"
  eq "H: reason upstream_no_credential" upstream_no_credential "$(rj 'r["reason_code"]')"
  eq "H: class product" product "$(rj 'r["class"]')"
  cs=$(rj '[s["secs"] for s in r["stages"] if s["layer"] == "codex:entry"][0]')
  CHECKS=$((CHECKS + 1)); [ "$cs" -le 10 ] || fail "H: the codex wait lasted ${cs}s after a definite 403 (> 10 s; FLEET_CN_PROBE_ANSWER was 300)"
  CHECKS=$((CHECKS + 1)); [ "$PSECS" -lt 60 ] || fail "H: the whole probe took ${PSECS}s"
  [ ! -s "$R/tmux/keys" ] || fail "H: the session the step opened was not closed: $(cat "$R/tmux/keys")"
  # another 403 is another reason: never one bucket for every 403
  CNP_SCENARIO=sub403 FLEET_CN_PROBE_ANSWER=300 probe_run
  eq "H: a 403 «no subscription account» → its own reason" upstream_no_subscription "$(rj 'r["reason_code"]')"
  # the account's usage limit: said at once, the account's (env), never the path's (#4596)
  CNP_SCENARIO=quota FLEET_CN_PROBE_ANSWER=300 probe_run
  eq "H: a usage-limit screen → its own reason" codex_quota_exhausted "$(rj 'r["reason_code"]')"
  eq "H: …class env" env "$(rj 'r["class"]')"
  cs=$(rj '[s["secs"] for s in r["stages"] if s["layer"] == "codex:entry"][0]')
  CHECKS=$((CHECKS + 1)); [ "$cs" -le 10 ] || fail "H: the codex wait lasted ${cs}s after a usage-limit screen (> 10 s)"
  CNP_SCENARIO=slow probe_run
  eq "H: a slow answer behind a retried 429 → 通" 0 "$PRC"
  contains "H: …answered" "$POUT" "PASS codex:entry a new Codex session answered"
  eq "H: …reason ok" ok "$(rj 'r["reason_code"]')"
  CNP_SCENARIO=answer probe_run
  eq "H: an answer → 通" 0 "$PRC"
  CNP_SCENARIO=silent FLEET_CN_PROBE_ANSWER=6 probe_run
  eq "H: no answer, no error → still waits the answer time out" 1 "$PRC"
  eq "H: …no_answer_timeout" no_answer_timeout "$(rj 'r["reason_code"]')"
  cs=$(rj '[s["secs"] for s in r["stages"] if s["layer"] == "codex:entry"][0]')
  CHECKS=$((CHECKS + 1)); [ "$cs" -ge 6 ] || fail "H: a silent session was cut after ${cs}s, before FLEET_CN_PROBE_ANSWER=6"
}

leg_I() {   # ensure failed: the patrol walks no session; the result is env
  local d="$WORK/legI"; rm -rf "$d"; mkdir -p "$d/conf" "$d/home"
  printf '#!/bin/sh\necho run >> "%s/probe.runs"\necho "通：x"\n' "$d" > "$d/probe"
  printf '#!/bin/sh\necho "ENSURE pod ok"\necho "ENSURE identity fail fleet drill invite: home must be a machine on the hub'"'"'s roster"\nexit 1\n' > "$d/ensure"
  printf '#!/bin/sh\necho "$*" >> "%s/filer.log"\necho "https://github.com/o/r/issues/92"\n' "$d" > "$d/filer"
  printf '#!/bin/sh\ncase "$*" in *commits/stable*) echo 0123456789abcdef0123456789abcdef01234567 ;; esac\nexit 0\n' > "$d/gh"
  printf '#!/bin/sh\necho diag >> "%s/diag.runs"\n' "$d" > "$d/diag"
  chmod +x "$d/probe" "$d/ensure" "$d/filer" "$d/diag" "$d/gh"
  : > "$d/key"
  mkdir -p "$d/tmp"
  out=$(FLEET_CONF_DIR="$d/conf" HOME="$d/home" TMPDIR="$d/tmp" FLEET_CN_PROBE_GH="$d/gh" FLEET_CN_PROBE_KEY="$d/key" FLEET_CN_PROBE_CMD="$d/probe" \
    FLEET_CN_PROBE_ENV_CMD="$d/ensure" FLEET_CN_PROBE_FILE_CMD="$d/filer" FLEET_CN_PROBE_DIAG_CMD="$d/diag" \
    bash "$W" --repo o/r --now 2>&1)
  [ ! -f "$d/probe.runs" ] || fail "I: the probe walked (opened sessions) on a road ensure could not make"
  [ -f "$d/diag.runs" ] || fail "I: no read-only diagnosis of the failed road"
  j="$d/conf/global/cn-probe/last.json"
  eq "I: red" red "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["verdict"])' "$j")"
  eq "I: stuck at ensure:identity" ensure:identity "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["stuck"])' "$j")"
  eq "I: class env" env "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["class"])' "$j")"
  eq "I: reason ensure_identity_failed" ensure_identity_failed "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["reason_code"])' "$j")"
  contains "I: the ensure error is kept, not masked" "$(cat "$d/conf/global/cn-probe/last.txt")" "home must be a machine on the hub's roster"
  contains "I: the patrol says red at ensure:identity" "$out" "red	0123456	ensure:identity"
  contains "I: filed as 环境无效, not 不通" "$(cat "$d/filer.log")" "国内探针环境无效：卡在 ensure"
  r=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["result"])' "$j")
  [ -f "$r" ] || fail "I: no result.json for the ensure failure ($r)"
  # retention: only the newest FLEET_CN_PROBE_KEEP_RUNS run dirs stay
  for i in 1 2 3; do mkdir -p "$d/conf/global/cn-probe/runs/20200101T00000${i}Z-old"; done
  FLEET_CONF_DIR="$d/conf" HOME="$d/home" TMPDIR="$d/tmp" FLEET_CN_PROBE_GH="$d/gh" FLEET_CN_PROBE_KEY="$d/key" FLEET_CN_PROBE_CMD="$d/probe" \
    FLEET_CN_PROBE_ENV_CMD="$d/ensure" FLEET_CN_PROBE_FILE_CMD="$d/filer" FLEET_CN_PROBE_DIAG_CMD="$d/diag" FLEET_CN_PROBE_KEEP_RUNS=2 \
    bash "$W" --repo o/r --now >/dev/null 2>&1
  eq "I: two run dirs kept" 2 "$(find "$d/conf/global/cn-probe/runs" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')"
  [ ! -d "$d/conf/global/cn-probe/runs/20200101T000001Z-old" ] || fail "I: the oldest run dir was kept"
}

leg_J() {   # the read-only diagnosis: the denier with its readings, the opener, the identity, redaction
  rig
  # a shared-machine admission (FLEET_USER_POD unset) at 1.51 of 1.00 cores: the gate holds
  printf '2026/10/15 03:40:01 ccquota agent --machine prod-x -> https://hub.test (0 logins)\nccquota agent --machine: FLEET_NODE_ACCOUNT_OPS=1 but no opener: fleet-node-linux.py under /var/db/fleet-node/runtime is group-writable\nccquota: machine agent: no logins to serve\n' > "$R/node/node-agent.log"
  chmod 2775 "$R/node/runtime"
  mkdir -p "$R/home/.config/claude-fleet/cred-proxy" "$R/home/.claude-logs"
  printf '{"trust": "trusted", "why": "hub: trusted"}\n' > "$R/home/.config/claude-fleet/cred-proxy/trust.json"
  printf '1 2 3 4\n' > "$R/home/.config/claude-fleet/global/admit-cpu.window"
  # the proxy started on central, then upstream answered the newest turn 403
  printf '{"t": 100.0, "ev": "start", "route": "central"}\n{"t": 50.0, "ev": "nocred", "acct": "default", "route": "direct"}\n{"t": 120.5, "ev": "fwd", "provider": "codex", "path": "/codex/responses", "route": "central", "up": "hub.test", "status": 403, "hdrs_in": ["authorization=<redacted:444>"]}\n' > "$R/home/.claude/fleet/logs/cred-proxy.log"
  cp "$R/home/.config/claude-fleet/global/admit-cpu.window" "$WORK/window.before"
  # credential-shaped things the pod's words might carry — none may land
  printf 'FLEET_HUB_TOKEN=tokxxxxxxxxxxxx Cookie: sid=cookiexxxxxxxx sk-ant-api03-SECRETSECRET fd_approvecode99\n' > "$R/home/.config/claude-fleet/global/onboard.open.log"
  FLEET_ADMIT=1 FLEET_ADMIT_CPU_READING='59 1.51 1.00 51' FLEET_MEM_PROBE_CMD='echo 1 80 0 0' FLEET_USER_POD='' \
    CNP_SCENARIO=refused probe_run
  eq "J: refused → 不通" 1 "$PRC"
  eq "J: reason admit_refused" admit_refused "$(rj 'r["reason_code"]')"
  dj=$(dirname "$PRES")/diag.json
  [ -f "$dj" ] || fail "J: no diag.json beside the result"
  dg() { python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["readings"][sys.argv[2]])' "$dj" "$1"; }
  eq "J: the gate's verdict" hold "$(dg admit.verdict)"
  contains "J: who refused" "$(dg admit.denier)" "pod: fleet_machine_admit (cpu)"
  contains "J: …with the real readings" "$(dg admit.why)" "1.51 of 1.00 cores used, 59% throttled"
  contains "J: the cgroup reading" "$(dg admit.cpu)" "1.51 of 1.00 cores used"
  eq "J: the opener is off" disabled "$(dg opener.state)"
  contains "J: …and why" "$(dg opener.reason)" "group-writable"
  contains "J: the runtime dir's mode" "$(dg opener.runtime_mode)" "group-writable"
  eq "J: runtime read" sha-rt "$(dg version.node_runtime | awk '{print $1}')"
  contains "J: the client version read" "$(dg version.client)" "0123abc"
  eq "J: the roster read" "listed — the hub's list for drillcn" "$(dg identity.roster)"
  eq "J: an unread source says unknown" unknown "$(dg image.digest)"
  contains "J: the upstream refused the newest turn" "$(dg cred.upstream)" "refused — the newest forwarded turn got 403"
  contains "J: …which one" "$(dg cred.last_forward)" "codex /codex/responses via central (hub.test) → 403"
  # 0600 / 0700, nothing credential-shaped, the gate's state untouched
  rd=$(dirname "$PRES")
  eq "J: run dir 0700" 700 "$(python3 -c 'import os,sys; print(oct(os.stat(sys.argv[1]).st_mode & 0o777)[2:])' "$rd")"
  for f in "$rd"/*.json "$rd"/stages.tsv "$rd"/ev/*; do
    eq "J: $(basename "$f") 0600" 600 "$(python3 -c 'import os,sys; print(oct(os.stat(sys.argv[1]).st_mode & 0o777)[2:])' "$f")"
  done
  all=$(cat "$rd"/*.json "$rd"/stages.tsv "$rd"/ev/* 2>/dev/null)
  for sec in tokxxxxxxxxxxxx cookiexxxxxxxx SECRETSECRET fd_approvecode99; do lacks "J: no $sec in the run dir" "$all" "$sec"; done
  contains "J: …the redaction marks it" "$(dg admit.last_open)" "[REDACTED"
  cmp -s "$R/home/.config/claude-fleet/global/admit-cpu.window" "$WORK/window.before" || fail "J: the diagnosis wrote the admission's cpu window"
  [ ! -e "$R/home/.config/claude-fleet/global/admit-held" ] || fail "J: the diagnosis wrote admit-held"
  # the drill identity ran out: the cert stage is env, never a product verdict
  CNP_CERT=expired probe_run
  eq "J: an expired identity → not 通" 1 "$PRC"
  eq "J: …stuck at cert" cert "$(rj 'r["stuck"]')"
  eq "J: …class env" env "$(rj 'r["class"]')"
  eq "J: …identity_expired" identity_expired "$(rj 'r["reason_code"]')"
  contains "J: …the diagnosis has the date" "$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["diag"]["readings"]["identity.valid_until"])' "$PRES")" "2026-01-01T00:00:00"
}

leg_K() {   # one result: the verdict and the exit come from result.json
  rig
  CNP_SCENARIO=answer probe_run
  eq "K: 通 exits 0" 0 "$PRC"
  contains "K: RESULT names the file" "$POUT" "RESULT $R/runs/"
  contains "K: CLASS none ok" "$POUT" "CLASS none ok"
  v=$(printf '%s\n' "$POUT" | grep -E '^(通|不通)：' | tail -n 1)
  eq "K: the verdict line is the JSON's" "通：$(rj 'r["oks"]')" "$v"
  eq "K: verdict pass" pass "$(rj 'r["verdict"]')"
  eq "K: every stage timed" "" "$(rj '",".join(s["layer"] for s in r["stages"] if s["secs"] is None or s["start"] == "unknown")')"
  contains "K: stages in order" "$(rj '" ".join(s["layer"] for s in r["stages"])')" "client install hub cert list auto entry codex:entry"
  eq "K: the codex stage's evidence" "ev/codex_entry.txt" "$(rj '[s["evidence"] for s in r["stages"] if s["layer"] == "codex:entry"][0]')"
  [ -f "$R/runs/$(rj 'r["run_id"]')/ev/codex_entry.txt" ] || fail "K: the evidence file is missing"
  eq "K: the run id is the dir" "$(basename "$(dirname "$PRES")")" "$(rj 'r["run_id"]')"
  # a hand-made stages.tsv: an env failure is never 通, nor is an empty run
  d="$WORK/legK"; mkdir -p "$d"
  printf 'pass\tclient\tproduct\tok\t1\t2\t\tok\nfail\tlist\tenv\tmachine_not_listed\t2\t5\t\tnot listed\n' > "$d/stages.tsv"
  o=$(python3 "$BIN/fleet-cn-probe-result.py" render "$d"); eq "K: env fail → exit 1" 1 "$?"
  contains "K: …CLASS env" "$o" "CLASS env machine_not_listed"
  : > "$d/stages.tsv"; o=$(python3 "$BIN/fleet-cn-probe-result.py" render "$d"); eq "K: no stage → exit 1" 1 "$?"
  contains "K: …CLASS probe" "$o" "CLASS probe no_stages"
}

# ---- recovery verification (issue #4304) ------------------------------------
# mkres <run dir> <verdict pass|fail> <class> <reason> <start epoch> <end epoch> [k=v vector overrides…]
# — a result.json in #4303's shape (stages per route, the diagnosis' vector)
mkres() {
  python3 - "$@" <<'PY'
import json, os, sys, time
d, verdict, cls, reason, t0, t1 = sys.argv[1:7]
iso = lambda t: time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(int(t)))
vec = {"version.hub": "prod-fb6c00f", "version.hub_client": "fb6c00fdbdbf", "version.client": "install 4c32afe",
       "version.node_runtime": "9046bd34", "image.digest": "sha256:9e82", "target.pod_uid": "b3c7"}
skip = set()
for kv in sys.argv[7:]:
    k, _, v = kv.partition("=")
    if k == "skip":
        skip.add(v)
    else:
        vec[k] = v
layers = [l for l in "client cert list entry relay view:entry view:relay codex:entry codex:relay".split() if l not in skip]
st = [{"layer": l, "result": "pass", "class": "none", "reason_code": "ok", "start": iso(t0), "end": iso(t1)} for l in layers]
if verdict == "fail":
    st.append({"layer": "codex:relay", "result": "fail", "class": cls, "reason_code": reason, "start": iso(t0), "end": iso(t1)})
os.makedirs(d, exist_ok=True)
r = {"run_id": os.path.basename(d), "verdict": verdict, "class": "none" if verdict == "pass" else cls,
     "reason_code": "ok" if verdict == "pass" else reason, "stuck": None if verdict == "pass" else "codex:relay",
     "detail": "", "oks": "entry 通；relay 通", "started": iso(t0), "ended": iso(t1), "stages": st,
     "diag": {"readings": vec}}
json.dump(r, open(os.path.join(d, "result.json"), "w"))
PY
}

leg_L() {   # the recovery round's state machine, on a fake clock
  local d="$WORK/legL" R T o rc dead n
  rm -rf "$d"; mkdir -p "$d"
  R="python3 $BIN/fleet-cn-probe-recover.py $d/sd"
  T=1790000000
  rec() { FLEET_CN_RECOVER_NOW=$T $R "$@"; }
  sleep 0 & dead=$!; wait "$dead"
  # one run: begin (alive pid) → result → finish; <verdict…> as mkres; advances the clock past the interval
  walk() { local id="r$1"; shift
    o=$(rec due); eq "L: due before $id ($o)" 0 "$?"
    rec begin "$id" $$ >/dev/null; T=$((T + 300))
    mkres "$d/runs/$id" "$1" "$2" "$3" $((T - 280)) $((T - 5)) "${@:4}"
    o=$(rec finish "$id" "$d/runs/$id/result.json"); T=$((T + 300)); }
  o=$(rec status); eq "L: no round yet" "no round" "$o"
  o=$(rec due); eq "L: nothing due without a round" 1 "$?"
  o=$(rec start --expect stable=fb6c00f --why "fix #4290 deployed"); contains "L: start" "$o" "started"
  o=$(rec start --expect stable=fb6c00f); contains "L: a repeated start is the same round" "$o" "already active"
  eq "L: …one round only" 1 "$(python3 -c 'import json,sys; s=json.load(open(sys.argv[1])); print(len(s.get("past", [])) + 1)' "$d/sd/recover.json")"
  # duplicate trigger: a second begin while the first is live is refused
  rec begin r0 $$ >/dev/null; o=$(rec begin r0b $$); eq "L: a second begin while one runs → 3" 3 "$?"
  o=$(rec due); eq "L: …and nothing is due" 1 "$?"; contains "L: …it is running" "$o" "running r0"
  # crash: the booked pid is gone → abandoned, not counted, a budget run
  python3 - "$d/sd/recover.json" "$dead" <<'PY'
import json, sys
p = sys.argv[1]; s = json.load(open(p)); s["round"]["running"]["pid"] = int(sys.argv[2]); json.dump(s, open(p, "w"))
PY
  o=$(rec due); contains "L: a dead holder is abandoned" "$o" "not counted abandoned r0"
  mkres "$d/runs/r0" pass none ok $((T - 100)) $((T - 5))
  o=$(rec finish r0 "$d/runs/r0/result.json"); contains "L: a crashed run finished late counts nothing" "$o" "already judged"
  T=$((T + 600))
  walk 1 pass none ok;                                  contains "L: pass 1 counted" "$o" "counted r1 — 1 in a row"
  walk 2 fail product upstream_http_403;               contains "L: a red resets" "$o" "not counted product:upstream_http_403 r2 — 0 in a row"
  walk 3 pass none ok;                                  contains "L: pass after red starts at 1" "$o" "counted r3 — 1 in a row"
  walk 4 pass none ok version.hub=prod-aaaaaaa;        contains "L: a new vector restarts the streak" "$o" "counted r4 — 1 in a row"
  # budget: 6 runs (r0 abandoned + r1..r4 = 5); one more that does not count ends it
  walk 5 fail env identity_expired;                    contains "L: env never counts" "$o" "not counted env:identity_expired"
  contains "L: run budget → exhausted" "$o" "exhausted"; contains "L: …says why" "$o" "budget: 6 runs"
  o=$(rec due); eq "L: an exhausted round is not due" 1 "$?"
  ev=$(ls "$d/sd/recover/"*.json | head -n 1); [ -f "$ev" ] || fail "L: no evidence for the exhausted round"
  eq "L: evidence 0600" 600 "$(python3 -c 'import os,sys; print("%o" % (os.stat(sys.argv[1]).st_mode & 0o777))' "$ev")"
  # a fresh round: three passes on one vector, 10 min apart → done, three distinct runs
  o=$(rec start --expect stable=fb6c00f --every 600); contains "L: a new round after the end" "$o" "started"
  walk 11 pass none ok
  T=$((T - 1)); o=$(rec due); eq "L: the next run waits the interval" 1 "$?"; contains "L: …until" "$o" "waiting until"; T=$((T + 1))
  walk 12 pass none ok skip=relay;                      contains "L: a partial walk does not count" "$o" "not counted partial"
  walk 13 pass none ok version.client=unknown;          contains "L: an unread version does not count" "$o" "not counted env:version_unknown"
  walk 14 pass none ok version.hub_client=deadbeef;     contains "L: another stable than expected" "$o" "not counted version_mismatch"
  o=$(rec status); contains "L: status names the round" "$o" "active — 0 in a row of 3"
  rec stop --why test >/dev/null
  o=$(rec start --expect stable=fb6c00f); contains "L: round 3 (back to back by default)" "$o" "every 0s"
  walk 21 pass none ok; walk 22 pass none ok
  # clock run backwards: never a success
  rec due >/dev/null; rec begin r23 $$ >/dev/null; T=$((T - 7200)); mkres "$d/runs/r23" pass none ok $((T - 100)) $((T - 5))
  o=$(rec finish r23 "$d/runs/r23/result.json"); contains "L: a clock run backwards is not a pass" "$o" "not counted clock_skew"
  T=$((T + 7200 + 900))
  walk 24 pass none ok; walk 25 pass none ok; walk 26 pass none ok
  contains "L: three in a row → done" "$o" "done"
  ev=$(sed -n 's/.*evidence \(.*\)$/\1/p' <<<"$o" | tail -n 1)
  n=$(python3 -c 'import json,sys; e=json.load(open(sys.argv[1])); r=[a["run_id"] for a in e["counted_runs"]]; print(len(set(r)), " ".join(r), e["state"])' "$ev")
  eq "L: the evidence names three independent runs" "3 r24 r25 r26 done" "$n"
  o=$(rec finish r26 "$d/runs/r26/result.json"); contains "L: finishing again counts nothing twice" "$o" "already judged"
  o=$(rec due); eq "L: done → nothing more due" 1 "$?"
  # the time budget
  rec start --max-secs 1200 >/dev/null; walk 31 fail product x; T=$((T + 1300))
  o=$(rec due); contains "L: past the time budget → exhausted" "$o" "budget: 20 min"
}

leg_M() {   # the patrol: every walk is on record, recovery ticks are serial and bounded
  local d="$WORK/legM" SDm o h
  rm -rf "$d"; mkdir -p "$d/conf" "$d/home" "$d/tmp"
  SDm="$d/conf/global/cn-probe"
  # a probe that writes #4303's result.json into its run dir (fail while $d/red), as the real one does
  cat > "$d/probe" <<SH
#!/bin/bash
echo run >> "$d/probe.runs"
t=\$(date +%s); rd="\$FLEET_CN_PROBE_RUNS/\$FLEET_CN_PROBE_RUN_ID"
if [ -f "$d/red" ]; then bash "$d/mkres" "\$rd" fail product upstream_http_403 \$((t - 1)) \$t; echo "RESULT \$rd/result.json"; echo "CLASS product upstream_http_403"; echo "不通：卡在 codex:relay — 403"
else bash "$d/mkres" "\$rd" pass none ok \$((t - 1)) \$t; echo "RESULT \$rd/result.json"; echo "CLASS none ok"; echo "通：自动选 entry；entry 通；relay 通"; fi
SH
  { printf '#!/bin/bash\n'; declare -f mkres; printf 'mkres "$@"\n'; } > "$d/mkres"
  printf '#!/bin/sh\necho "ENSURE pod ok"\n' > "$d/ensure"
  printf '#!/bin/sh\necho "https://github.com/o/r/issues/93"\n' > "$d/filer"
  printf '#!/bin/sh\ncase "$*" in *commits/stable*) echo 0123456789abcdef0123456789abcdef01234567 ;; esac\nexit 0\n' > "$d/gh"
  chmod +x "$d/probe" "$d/ensure" "$d/filer" "$d/gh" "$d/mkres"; : > "$d/key"
  pw() { o=$(FLEET_CONF_DIR="$d/conf" HOME="$d/home" TMPDIR="$d/tmp" FLEET_CN_PROBE_GH="$d/gh" FLEET_CN_PROBE_KEY="$d/key" \
    FLEET_CN_PROBE_CMD="$d/probe" FLEET_CN_PROBE_ENV_CMD="$d/ensure" FLEET_CN_PROBE_FILE_CMD="$d/filer" FLEET_CN_PROBE_DIAG=0 \
    FLEET_CN_RECOVER_EVERY=0 bash "$W" --repo o/r "$@" 2>&1); }
  wruns() { if [ -f "$d/probe.runs" ]; then wc -l < "$d/probe.runs" | tr -d ' '; else echo 0; fi; }
  hcount() { grep -c "$1" "$SDm/history.ndjson" 2>/dev/null || echo 0; }
  # a manual green run is on record (the diskguard log never saw these)
  pw --now; contains "M: a --now green walks" "$o" "green	0123456"
  eq "M: …and is on record" 1 "$(hcount '"ev": "run".*"mode": "now".*"verdict": "green"')"
  # throttled ticks: one skip line per throttle period, not one a tick
  pw; pw; pw; eq "M: throttled ticks walk nothing" 1 "$(wruns)"
  eq "M: …recorded once" 1 "$(hcount '"why": "throttle"')"
  # a lock whose holder is gone is taken over at once, and said so
  sleep 0 & local dead=$!; wait "$dead"
  mkdir "$SDm/lock"; echo "$dead 1" > "$SDm/lock/pid"
  pw --now; eq "M: a dead holder's lock does not stall the patrol" 2 "$(wruns)"
  eq "M: …the takeover is recorded" 1 "$(hcount '"ev": "lock_reclaimed".*"why": "holder_gone"')"
  # a live holder's lock: a skip, recorded once
  mkdir "$SDm/lock"; echo "$$ 1" > "$SDm/lock/pid"
  pw --now; pw --now; eq "M: a live holder blocks" 2 "$(wruns)"
  eq "M: …recorded once" 1 "$(hcount '"why": "lock_held"')"; rm -rf "$SDm/lock"
  # recovery: --recover walks at once (inside the green throttle), then each tick is due
  : > "$d/red"; pw --recover --expect stable=fb6c00f; rm -f "$d/red"
  contains "M: a red recovery run does not count" "$o" "not counted product:upstream_http_403"
  pw; contains "M: the next tick is a recovery run" "$o" "counted"; contains "M: …1 in a row" "$o" "1 in a row of 3"
  pw; pw; contains "M: three in a row → done" "$o" "done"
  eq "M: six walks so far" 6 "$(wruns)"
  eq "M: every recovery walk is on record" 4 "$(hcount '"ev": "run".*"mode": "recover"')"
  pw; eq "M: after done the patrol is back on its throttle" 6 "$(wruns)"
  # the three counted runs are three different run dirs with their own result.json
  h=$(python3 -c 'import json,sys; s=json.load(open(sys.argv[1]))["round"]; print(len(set(s["streak"])), all(__import__("os").path.exists(a["result"]) for a in s["attempts"] if a["counted"]))' "$SDm/recover.json")
  eq "M: three independent complete runs" "3 True" "$h"
}

leg_N() {   # the probe closes every session it opened: the client's close, else the pod's stop by fleet id
  rig
  CNP_SCENARIO=answer CNP_CLOSE_FAIL=1 CNP_NEWKEY=wid:f00d/fid-a probe_run
  eq "N: the walk itself passes" 0 "$PRC"
  contains "N: the client's close failing is said" "$POUT" "could not close the session wid:f00d/fid-a"
  contains "N: …and the pod stops it by its fleet id" "$POUT" "stopped the session wid:f00d/fid-a it opened on the pod"
  contains "N: …through fleet-worker-stop.sh fid:" "$(cat "$R/tmux/stops")" "fleet fid:fid-a"
  [ ! -s "$R/tmux/keys" ] || fail "N: a session was left on the pod: $(cat "$R/tmux/keys")"
  [ ! -s "$R/runs/.left-sessions" ] || fail "N: a stopped session stayed on the leftover list"
  # neither road works: kept, and the next run stops it before opening its own
  CNP_SCENARIO=answer CNP_CLOSE_FAIL=1 CNP_POD_STOP_FAIL=1 CNP_NEWKEY=wid:f00d/fid-b probe_run
  contains "N: a session neither road could close is said" "$POUT" "left on the pod (retried next run): wid:f00d/fid-b"
  contains "N: …and kept for the next run" "$(cat "$R/runs/.left-sessions")" "wid:f00d/fid-b "
  CNP_SCENARIO=answer CNP_NEWKEY=wid:f00d/fid-c probe_run
  contains "N: the next run stops the leftover first" "$POUT" "INFO sweep stopped the session wid:f00d/fid-b"
  [ ! -s "$R/tmux/keys" ] || fail "N: sessions still on the pod after the sweep: $(cat "$R/tmux/keys")"
  [ ! -s "$R/runs/.left-sessions" ] || fail "N: the leftover list kept a stopped session"
}

leg_O() {   # a run leaves no line open on the client (#4283): the old client stopped, every line closed
  rig
  local C="$R/home/.cache/claude-fleet/shell" wp sp cp op p
  mkdir -p "$C/bin" "$C/tmp/warm"
  printf '#!/bin/bash\n[ "$1" = quit ] && exit 0\nwhile :; do sleep 1; done\n' > "$C/bin/fleet-shell.sh"
  alive() { local st; st=$(ps -o stat= -p "$1" 2>/dev/null | tr -d ' '); case "$st" in ''|Z*) return 1 ;; esac; return 0; }
  # the old client's warm loop and one of its lines; a relay line; another login's line
  bash "$C/bin/fleet-shell.sh" warm fleet-shell </dev/null >/dev/null 2>&1 & wp=$!
  ( exec -a ssh perl -e 'sleep 600' -- -o "ControlPath=$C/tmp/warm/u-test1.sock" -o HostKeyAlias=fleet-u-test1 u-test1 ) & sp=$!
  ( exec perl -e 'sleep 600' -- "$R/home/.claude/fleet/bin/fleet-connect.py" u-test1 ) & cp=$!
  ( exec -a ssh perl -e 'sleep 600' -- -o HostKeyAlias=fleet-u-test1 -i "$WORK/other/.ssh/fleet-cert" u-test1 ) & op=$!
  disown "$wp" "$sp" "$cp" "$op" 2>/dev/null
  sleep 1
  CNP_SCENARIO=answer CNP_LEAK=1 FLEET_RETIRE_GRACE=1 probe_run
  CHECKS=$((CHECKS + 1)); alive "$op" || fail "O: another login's line was closed"
  kill "$op" 2>/dev/null
  eq "O: the walk itself passes" 0 "$PRC"
  contains "O: the old client is stopped before the steps" "$POUT" "INFO lines:before stopped the old two-pane client"
  contains "O: an earlier line is closed before the steps" "$POUT" "INFO lines:before closed 1 line process(es)"
  contains "O: the line this run left is closed after them" "$POUT" "INFO lines:after closed 1 line process(es)"
  lacks "O: nothing stands after a KILL" "$POUT" "still open on the client after a KILL"
  sleep 1
  for p in $wp $sp $cp; do alive "$p" && fail "O: process $p of the test login still runs: $(ps -o args= -p "$p")"; done
  CHECKS=$((CHECKS + 1))
  [ -z "$(ps -axo args= | grep -F "$R/home/.claude/fleet/bin/fleet-connect.py" | grep -v grep)" ] || fail "O: a fleet-connect line of the test login is left"
  # a clean client: nothing said
  CNP_SCENARIO=answer probe_run
  lacks "O: a clean client → no lines line" "$POUT" "INFO lines:"
}

if [ -n "${CNP_LEG:-}" ]; then
  W="$BIN/fleet-cn-probe-watch.sh"
  "leg_$CNP_LEG"
  printf 'fleet-cn-probe-selftest OK leg %s (%d checks)\n' "$CNP_LEG" "$CHECKS"
  exit 0
fi

export FLEET_CONF_DIR="$WORK/conf" HOME="$WORK/home" TMPDIR="$WORK/tmp"   # alerts.events lives under TMPDIR
mkdir -p "$FLEET_CONF_DIR" "$HOME" "$TMPDIR" "$WORK/shim"
SD="$FLEET_CONF_DIR/global/cn-probe"
SHA=0123456789abcdef0123456789abcdef01234567

# --- stubs ----------------------------------------------------------------------
cat > "$WORK/shim/gh" <<SH
#!/bin/sh
echo "\$*" >> "$WORK/gh.log"
case "\$*" in
  *'commits/stable'*) echo $SHA ;;
  *'-X POST'*statuses*) [ -f "$WORK/gh.postfail" ] && exit 1; exit 0 ;;
  *'commits/$SHA/statuses'*) cat "$WORK/nodeimage" 2>/dev/null ;;
esac
SH
cat > "$WORK/probe" <<SH
#!/bin/sh
echo run >> "$WORK/probe.runs"
cat "$WORK/probe.out"
SH
cat > "$WORK/ensure" <<SH
#!/bin/sh
echo "\$*" >> "$WORK/ensure.log"
echo "pod ok"
SH
cat > "$WORK/filer" <<SH
#!/bin/sh
echo "\$*" >> "$WORK/filer.log"
echo "https://github.com/o/r/issues/91"
SH
chmod +x "$WORK/shim/gh" "$WORK/probe" "$WORK/ensure" "$WORK/filer"
export PATH="$WORK/shim:$PATH"
export FLEET_CN_PROBE_CMD="$WORK/probe" FLEET_CN_PROBE_ENV_CMD="$WORK/ensure" FLEET_CN_PROBE_FILE_CMD="$WORK/filer"
export FLEET_CN_PROBE_KEY="$WORK/key"
W="$BIN/fleet-cn-probe-watch.sh"
runs() { if [ -f "$WORK/probe.runs" ]; then wc -l < "$WORK/probe.runs" | tr -d ' '; else echo 0; fi; }
watch() { OUT=$(bash "$W" --repo o/r "$@" 2>&1); RC=$?; }
json() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get(sys.argv[2]))' "$SD/last.json" "$1"; }
green_out() { printf 'PASS client x\nPASS view:entry y\n通：自动选 entry；entry 通\n' > "$WORK/probe.out"; }
red_out() { printf 'PASS client x\nFAIL codex:entry no answer\n不通：卡在 codex:entry — no answer carrying CNP1 __CNP_EXIT=4\n' > "$WORK/probe.out"; }

# --- A. off -----------------------------------------------------------------------
green_out
watch; eq "A: no client key → exit 0" 0 "$RC"; eq "A: …and no walk" 0 "$(runs)"
: > "$WORK/key"
FLEET_CN_PROBE=0 bash "$W" --repo o/r >/dev/null 2>&1; eq "A: FLEET_CN_PROBE=0 walks nothing" 0 "$(runs)"
watch --repo; eq "A: --repo needs owner/name" 2 "$RC"

# --- B. green ---------------------------------------------------------------------
watch
eq "B: green exits 0" 0 "$RC"; eq "B: walked once" 1 "$(runs)"
contains "B: says green" "$OUT" "green	0123456"
eq "B: last.json green" green "$(json verdict)"; eq "B: last.json names stable" "$SHA" "$(json stable)"
contains "B: success status on stable" "$(cat "$WORK/gh.log")" "-X POST repos/o/r/statuses/$SHA -f state=success -f context=cn path"
contains "B: ensure told the stable" "$(cat "$WORK/ensure.log")" "--repo o/r --stable $SHA"
[ ! -f "$WORK/filer.log" ] || fail "B: a green walk filed something"
contains "B: last.txt keeps the ensure lines" "$(cat "$SD/last.txt")" "ENSURE pod ok"
[ ! -d "$SD/lock" ] || fail "B: the lock was left behind"

# --- C. throttle ------------------------------------------------------------------
watch; eq "C: inside the interval → exit 0" 0 "$RC"; eq "C: …walks nothing" 1 "$(runs)"
FLEET_CN_PROBE_SECS=0 bash "$W" --repo o/r >/dev/null 2>&1; eq "C: interval 0 walks again" 2 "$(runs)"
mkdir "$SD/lock"; watch --now; eq "C: a fresh lock → nothing" 2 "$(runs)"; rmdir "$SD/lock"

# --- D. red -------------------------------------------------------------------------
red_out; : > "$WORK/gh.log"
watch --now
eq "D: red handled → exit 0 ($OUT)" 0 "$RC"; contains "D: says red" "$OUT" "red	0123456	codex:entry	https://github.com/o/r/issues/91"
fl=$(cat "$WORK/filer.log")
contains "D: one breakage per layer" "$fl" "--breakage --breakage-key cn-path-codex --fault-sha $SHA --repo o/r"
contains "D: titled by the layer" "$fl" "国内真实用户路径不通：卡在 codex"
g=$(cat "$WORK/gh.log")
contains "D: failure status" "$g" "-f state=failure -f context=cn path"
contains "D: …targets the issue" "$g" "target_url=https://github.com/o/r/issues/91"
lacks "D: the pty sentinel is not in the status" "$g" "__CNP_EXIT"
eq "D: last.json red" red "$(json verdict)"; eq "D: last.json stuck" codex:entry "$(json stuck)"
eq "D: last.json issue" https://github.com/o/r/issues/91 "$(json issue)"
[ -f "$SD/red" ] || fail "D: no red mark"
eq "D: the alert's memo" https://github.com/o/r/issues/91 "$(cat "$SD/filed")"
events() { find "$WORK" -name alerts.events -exec cat {} + 2>/dev/null; }
ev=$(events)
contains "D: one breakage alert" "$ev" "国内真实用户路径不通"
n=$(runs); watch; eq "D: red re-walks only after FLEET_CN_PROBE_RED_SECS" "$n" "$(runs)"
FLEET_CN_PROBE_RED_SECS=0 bash "$W" --repo o/r >/dev/null 2>&1; eq "D: …then it does" $((n + 1)) "$(runs)"
ev2=$(events)
eq "D: the same issue alerts once" "$(printf '%s\n' "$ev" | grep -c 国内真实用户路径不通)" "$(printf '%s\n' "$ev2" | grep -c 国内真实用户路径不通)"
: > "$WORK/gh.postfail"; watch --now; eq "D: a status that cannot be posted → exit 1" 1 "$RC"; rm -f "$WORK/gh.postfail"

# --- E. --dry-run ---------------------------------------------------------------------
: > "$WORK/gh.log"; rm -f "$WORK/filer.log" "$WORK/ensure.log"; cp "$SD/last.json" "$WORK/last.before"
watch --dry-run
eq "E: dry-run exits 0" 0 "$RC"
contains "E: says what it would file" "$OUT" "would-file	cn-path-codex"
contains "E: says what it would post" "$OUT" "would-post	$SHA	red"
lacks "E: posts nothing" "$(cat "$WORK/gh.log")" "-X POST"
[ ! -f "$WORK/filer.log" ] || fail "E: dry-run filed"
[ ! -f "$WORK/ensure.log" ] || fail "E: dry-run ran ensure"
cmp -s "$SD/last.json" "$WORK/last.before" || fail "E: dry-run rewrote last.json"

# --- F. green after red, no verdict -------------------------------------------------
green_out; watch --now
eq "F: green again" green "$(json verdict)"
[ ! -f "$SD/red" ] && [ ! -f "$SD/filed" ] || fail "F: the red was not forgotten"
printf 'PASS client x\nssh: dead\n' > "$WORK/probe.out"; watch --now
eq "F: no verdict line → red" red "$(json verdict)"; eq "F: …at probe" probe "$(json stuck)"
contains "F: filed under cn-path-probe" "$(cat "$WORK/filer.log")" "--breakage-key cn-path-probe"

# --- G. env ensure: the test pod follows stable's node image -------------------------
IMG=registry.example/fleet-managed-node
cat > "$WORK/shim/kubectl" <<SH
#!/bin/sh
echo "\$*" >> "$WORK/kubectl.log"
case "\$*" in
  *'get deploy'*) cat "$WORK/deploy" 2>/dev/null ;;
  *'set image'*|*'rollout status'*) exit 0 ;;
esac
SH
# ssh to the China client: the login exists with fleet; the hub lists the machine
cat > "$WORK/shim/ssh" <<'SH'
#!/bin/sh
in=$(cat)
case "$in" in
  *'id -u'*) printf 'USER\n/home/x/.local/bin/fleet\n' ;;
  *'cert-check'*) printf 'PASS\tok\n{"machine": "u-test1"}\n' ;;
esac
SH
chmod +x "$WORK/shim/kubectl" "$WORK/shim/ssh"
E="$BIN/fleet-cn-probe-env.sh"
export FLEET_CN_PROBE_MACHINE=u-test1 FLEET_CN_PROBE_KNOWN_HOSTS=''
printf 'fleet=%s@sha256:aaaa\nsshd=%s@sha256:aaaa\ninit:pod-etc=%s@sha256:aaaa\n' "$IMG" "$IMG" "$IMG" | sed 's/^init://' > "$WORK/deploy"
echo "$IMG@sha256:bbbb" > "$WORK/nodeimage"
out=$(bash "$E" status --repo o/r --stable $SHA 2>&1); rc=$?
eq "G: status on an old pod → 1" 1 "$rc"; contains "G: status says it would roll" "$out" "ensure would roll it"
lacks "G: status sets no image" "$(cat "$WORK/kubectl.log")" "set image"
out=$(bash "$E" ensure --repo o/r --stable $SHA 2>&1); rc=$?
eq "G: ensure rolls → 0" 0 "$rc"; contains "G: says rolled" "$out" "ENSURE pod rolled u-test1"
k=$(cat "$WORK/kubectl.log")
contains "G: every container onto stable's image" "$k" "set image deploy/u-test1 fleet=$IMG@sha256:bbbb pod-etc=$IMG@sha256:bbbb sshd=$IMG@sha256:bbbb"
contains "G: waits for the rollout" "$k" "rollout status deploy/u-test1"
contains "G: client ok" "$out" "ENSURE client ok"; contains "G: identity ok" "$out" "ENSURE identity ok"
printf 'fleet=%s@sha256:bbbb\nsshd=%s@sha256:bbbb\n' "$IMG" "$IMG" > "$WORK/deploy"; : > "$WORK/kubectl.log"
out=$(bash "$E" ensure --repo o/r --stable $SHA 2>&1)
contains "G: a pod on stable's image is ok" "$out" "ENSURE pod ok"; lacks "G: …and not touched" "$(cat "$WORK/kubectl.log")" "set image"
: > "$WORK/nodeimage"
out=$(bash "$E" ensure --repo o/r --stable $SHA 2>&1)
contains "G: no node image status → left" "$out" "ENSURE pod skip stable 0123456 carries no node image status"
: > "$WORK/deploy"; echo "$IMG@sha256:bbbb" > "$WORK/nodeimage"
out=$(bash "$E" ensure --repo o/r --stable $SHA 2>&1); rc=$?
eq "G: no Deployment, no manifest → 1" 1 "$rc"; contains "G: says so" "$out" "no FLEET_CN_PROBE_POD_MANIFEST"

# --- H..K: the probe itself, offline (issue #4303) -----------------------------
for leg in H I J K L M N O; do "leg_$leg"; done

# --- L. a drill person made again gets its own allowlist (issue #4290) ---------------
cat > "$WORK/shim/ssh" <<SH
#!/bin/sh
in=\$(cat)
case "\$in" in
  *'id -u'*) printf 'USER\n/home/x/.local/bin/fleet\n' ;;
  *'cert-check'*) if [ -f "$WORK/listed" ]; then printf 'PASS\tok\n{"machine": "u-test1"}\n'; else printf 'FAIL\tno certificate\n'; fi ;;
  *'fleet login'*) printf 'CODE ABCD-EFGH\n' ;;
esac
SH
cat > "$WORK/drill" <<SH
#!/bin/sh
case "\$1" in
  invite) printf '{"person_id":"drill-h1","approve_code":"fd_secret"}\n' ;;
  approve) : > "$WORK/listed" ;;
esac
SH
cat > "$WORK/policy" <<SH
#!/bin/sh
echo "tok=\${CCQUOTA_VIEWER_TOKEN:+set} \$*" >> "$WORK/policy.log"
SH
chmod +x "$WORK/shim/ssh" "$WORK/drill" "$WORK/policy"
rm -f "$WORK/listed" "$WORK/policy.log"
out=$(FLEET_CN_PROBE_DRILL_CMD="$WORK/drill" FLEET_CN_PROBE_POLICY_CMD="$WORK/policy" FLEET_CN_PROBE_ENSURE_WAIT=10 \
  FLEET_CN_PROBE_CRED_ALLOW='codex:account:aa uuid-b' CCQUOTA_VIEWER_TOKEN=t0k bash "$E" ensure --repo o/r --stable $SHA 2>&1)
contains "L: the drill is made again" "$out" "ENSURE identity made a new drill person"
contains "L: its allowlist is written" "$out" "ENSURE allow made drill-h1"
eq "L: one set, the operator token in its environment" "tok=set set --force user drill-h1 codex:account:aa uuid-b" "$(cat "$WORK/policy.log" 2>/dev/null)"
lacks "L: no token on an argv or the output" "$out$(cat "$WORK/policy.log")" "t0k"
rm -f "$WORK/listed" "$WORK/policy.log"
out=$(FLEET_CN_PROBE_DRILL_CMD="$WORK/drill" FLEET_CN_PROBE_POLICY_CMD="$WORK/policy" FLEET_CN_PROBE_ENSURE_WAIT=10 \
  bash "$E" ensure --repo o/r --stable $SHA 2>&1)
lacks "L: no FLEET_CN_PROBE_CRED_ALLOW ⇒ no list written" "$out" "ENSURE allow"
[ ! -f "$WORK/policy.log" ] || fail "L: a list was written with no FLEET_CN_PROBE_CRED_ALLOW"

printf 'fleet-cn-probe-selftest OK (%d checks)\n' "$CHECKS"
