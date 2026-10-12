#!/usr/bin/env bash
# fleet-cred-proxy.sh — this login's credential proxy, started and kept (issue #1970,
# EPIC #1967 C3). The proxy itself is bin/fleet-cred-proxy.py; this reads the
# machine's config and decides whether it runs at all.
#
#   fleet-cred-proxy.sh run       the daemon's entry (com.claude-fleet.cred-proxy,
#                                 KeepAlive / claude-fleet-cred-proxy.service).
#                                 FLEET_CRED_PROXY!=1 → no proxy process: the
#                                 launcher only re-reads the config every
#                                 FLEET_CRED_PROXY_IDLE_SECS (60) and starts one
#                                 when it turns on; turned off → the proxy stops.
#                                 A proxy that dies is restarted within
#                                 FLEET_CRED_PROXY_WATCH_SECS (2) + a 2s breath.
#   fleet-cred-proxy.sh relay-tick  separated / shared only: answer the shared
#                                 proxy's request for a relay pass, then exit — what
#                                 the node daemon runs for a login on the machine's
#                                 shared proxy, only when the proxy asks (issues
#                                 #3524, #3561). Elsewhere a no-op.
#   fleet-cred-proxy.sh ensure    start it detached when it is on and not running
#                                 (a computer with no daemon — a client-only one);
#                                 prints the port. Exit 3 = switched off.
#   fleet-cred-proxy.sh port      the port sessions use (exit 1 = not running)
#   fleet-cred-proxy.sh route|mint|rebind|revoke|attach|quota|account-quota|picks|relay-probe …
#                                 the control socket — see fleet-cred-proxy.py
#                                 (`quota`: each session's last rate-limit reading,
#                                 issue #1978 — bin/fleet-proxy-quota.sh stamps it;
#                                 `account-quota`: the newest one per ACCOUNT;
#                                 `picks`: the account the proxy runs each of a
#                                 separated login's sessions on — issue #2412)
#   fleet-cred-proxy.sh pass         a session's hub pass (fcp-h1., on STDIN) filed
#                                 under this login at the machine's shared proxy
#                                 (issue #2217; fleet-session-cred.sh does it)
#   fleet-cred-proxy.sh enable|disable [--all-logins] · status [--all-logins]
#   fleet-cred-proxy.sh enable|disable|status --machine
#                                 the machine's ONE shared proxy (issue #2217) —
#                                 bin/fleet-cred-rollout.sh
#                                 the switch for this login (and every other login
#                                 on the machine): bin/fleet-cred-rollout.sh, issue
#                                 #2134 — `fleet cred-proxy …`. `status --json` /
#                                 `status --ctl` is the control socket's status.
#   fleet-cred-proxy.sh doctor    fleet-doctor's `cred` row (issue #1975): ONE line
#                                 `<PASS|WARN|FAIL>` TAB `<text>` — trust, the road
#                                 each agent takes and why, the proxy, credsep, renewal.
#                                 Exit 3 = switched off (no row).
#
# Config (fleet.conf [common], or the environment): FLEET_CRED_PROXY (0 = today's
# wiring byte for byte, the default), FLEET_CRED_PROXY_PORT, FLEET_CRED_RELAY_URL,
# FLEET_CRED_RELAY_TOKEN (secrets.env — never fleet.conf; unset = the pass
# fleet-relay-cred.sh mints for this login, kept in the state dir — #1974),
# FLEET_CRED_CENTRAL_URL (default: the hub). State: $FLEET_CONF_DIR/cred-proxy/ (port, ctl.sock 0600,
# key, bind.json, revoked, trust.json). Log: logs/cred-proxy.log (redacted).
#
# Shared (issue #2217 — `fleet-credsep.sh machine install`; credsep.json says
# "shared": true) is the same as separated below, with ONE proxy for the whole
# machine: its run dir is /var/run/fleet-cred/.shared, and the proxy tells this
# login from the others by our uid.
#
# Separated (issue #1971 — bin/fleet-credsep.sh; $FLEET_CONF_DIR/credsep.json
# says so): the proxy is NOT this login's to run — the role account's service
# runs it — so `run` only idles, `ensure` / `port` read its port from the run
# dir, and the control commands talk to its socket there (the proxy checks our
# uid). Plus three that only exist there:
#   fleet-cred-proxy.sh node-token   → `<broker url>\t<fcpn1.…>` (the hub broker)
#   fleet-cred-proxy.sh node-hash    → sha256 of the node token (fleet-mcp)
#   fleet-cred-proxy.sh probe <file> → hand the proxy a fresh node-probe.json
#   fleet-cred-proxy.sh store --kind claude|codex --label L < file
#                                    → put one credential file in the store
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
PY="$BIN/fleet-cred-proxy.py"
CONF="${FLEET_CONF_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/claude-fleet}"
STATE="$CONF/cred-proxy"
IDLE="${FLEET_CRED_PROXY_IDLE_SECS:-60}"

load_conf() { # the machine's one file (#1623) + the install's; the env wins over neither — same order as every daemon
  local f
  set -a
  for f in "$BIN/../fleet.conf" "$CONF/fleet.settings" "$CONF/fleet.conf"; do
    # shellcheck source=/dev/null
    [ -f "$f" ] && . "$f" >/dev/null 2>&1
  done
  set +a
}

on() { [ "${FLEET_CRED_PROXY:-0}" = 1 ]; }

SEP_RUN=''   # separated: the role account's run dir (ctl.sock, port, pid)
if [ -f "$CONF/credsep.json" ]; then
  SEP_RUN=$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1])).get("run",""))' "$CONF/credsep.json" 2>/dev/null)
fi
# The relay pass (#1974) is renewed on REQUEST, never on a clock (issue #3561,
# EPIC #3500 C19). The proxy holds it and knows its age: it writes
# relay-want[.<login>] in its run directory — missing (none held, asked on a
# doubling 60 → 120 s clock: a login opened while its account is still
# `creating` gets 403 until it turns active, #3213/#3423), used (carried with
# < 20 % of its four hours left), 80% (that far into its life), refused (the
# relay's gate said no). A request newer than the last one answered is answered
# here: fleet-relay-cred.sh fetch (--force for a renewal), handed to the proxy
# over `relay`. A NEW pass re-probes at once (FLEET_CRED_REPROBE_CMD, default
# fleet-node-probe.sh --quiet): the probe taken before it said `direct` from a
# CN egress, and that verdict is what closes compute. The launcher also asks
# once at boot (`fetch` keeps a pass the hub still takes).
RELAY_SEEN='' RELAY_WHY='' RELAY_BOOT=1
RELAY_RUN=${SEP_RUN:-$STATE}
# relay_configured → rc 0 when this login's proxy has a relay road. Separated
# (credsep), the URL is root's <LIB>/<login>.conf, which only the proxy reads —
# a Linux tenant's own fleet.conf never names it (#3423) — so ask the proxy.
# rc 2 = the proxy did not answer (not up yet).
relay_configured() {
  local st
  [ -n "${FLEET_CRED_RELAY_URL:-}" ] && return 0
  [ -n "$SEP_RUN" ] || return 1
  st=$(python3 -I "$PY" --state "$STATE" status --json 2>/dev/null) || return 2
  printf '%s' "$st" | python3 -I -c 'import json,sys
try: sys.exit(0 if json.load(sys.stdin).get("relay") else 1)
except Exception: sys.exit(2)'
}
# relay_due → rc 0 when the proxy asked for a pass since the last answer
# (RELAY_WHY = its reason; the launcher's first look = boot)
relay_due() {
  local w='' f st
  if [ "$RELAY_BOOT" = 1 ]; then RELAY_BOOT=0 RELAY_WHY=boot; return 0; fi
  for f in "$RELAY_RUN/relay-want.$(id -un)" "$RELAY_RUN/relay-want"; do
    [ -f "$f" ] && { w=$f; break; }
  done
  [ -n "$w" ] || return 1
  st=$(stat -c %Y "$w" 2>/dev/null || stat -f %m "$w" 2>/dev/null) || return 1   # GNU first: its -f is the filesystem
  [ "$st" != "$RELAY_SEEN" ] || return 1
  RELAY_SEEN=$st
  RELAY_WHY=$(awk '{print $1; exit}' "$w" 2>/dev/null)
  return 0
}
relay_fetch() {
  local out rc force=''
  [ -z "${FLEET_CRED_RELAY_TOKEN:-}" ] || return 0
  relay_configured || return 0
  case "${RELAY_WHY:-}" in used|80%|refused) force=--force ;; esac
  out=$("$BIN/fleet-relay-cred.sh" fetch ${force:+"$force"} 2>/dev/null)
  printf 'relay (%s): %s\n' "${RELAY_WHY:-?}" "${out:-no pass (refused or the hub away)}"
  case "$out" in
    'relay: ISSUED'*)
      # in the background: a probe measures for up to minutes, the launcher's watch is seconds
      if [ -n "${FLEET_CRED_REPROBE_CMD:-}" ]; then
        ( eval "$FLEET_CRED_REPROBE_CMD" </dev/null >/dev/null 2>&1 & )
      else
        ( "$BIN/fleet-node-probe.sh" --quiet </dev/null >/dev/null 2>&1 & )
      fi ;;
  esac
  return 0
}

switch_now() { # → 1 / 0, read fresh in a subshell (the conf may have changed under us)
  ( unset FLEET_CRED_PROXY; [ -n "${_FCP_ENV_SWITCH:-}" ] && FLEET_CRED_PROXY="$_FCP_ENV_SWITCH"; load_conf; printf '%s' "${FLEET_CRED_PROXY:-0}" )
}

live_pid() { # the serving proxy's pid, if any
  local p
  if [ -n "$SEP_RUN" ]; then   # another uid's process: kill -0 cannot tell; the socket can
    [ -S "$SEP_RUN/ctl.sock" ] && [ -s "$SEP_RUN/port" ] || return 1
    cat "$SEP_RUN/pid" 2>/dev/null || printf 'separated'
    return 0
  fi
  p=$(cat "$STATE/pid" 2>/dev/null) || return 1
  case "$p" in ''|*[!0-9]*) return 1 ;; esac
  kill -0 "$p" 2>/dev/null && printf '%s' "$p"
}

cmd="${1:-}"; [ $# -gt 0 ] && shift
_FCP_ENV_SWITCH="${FLEET_CRED_PROXY:-}"   # an explicit environment value outranks the conf
load_conf
[ -n "$_FCP_ENV_SWITCH" ] && FLEET_CRED_PROXY="$_FCP_ENV_SWITCH"
export FLEET_CONF_DIR="$CONF"

if [ -n "$SEP_RUN" ]; then
  export FLEET_CRED_CTL_DIR="$SEP_RUN"
  case "$cmd" in
    run)   # the role account's service runs the proxy; this one has nothing to start
      trap 'exit 0' TERM INT
      # it still keeps the relay pass (#1974): minted as this login, handed over
      # by fleet-relay-cred.sh's separated push
      while :; do
        [ "$(switch_now)" = 1 ] && relay_due && relay_fetch
        sleep "$IDLE" & wait $! 2>/dev/null
        [ -f "$CONF/credsep.json" ] || exec "$0" run "$@"
      done ;;
    relay-tick)   # ONE answer to the shared proxy's request, then exit (issues
      # #3524, #3561): a login on the machine's shared proxy has no resident
      # launcher — the node daemon runs this as the login when the proxy wrote
      # relay-want.<login>. The last request answered lives in $STATE/relay-keep.
      mkdir -p "$STATE" && chmod 700 "$STATE"
      RELAY_BOOT=0
      read -r RELAY_SEEN 2>/dev/null < "$STATE/relay-keep"
      case "${RELAY_SEEN:-}" in *[!0-9]*) RELAY_SEEN='' ;; esac
      [ "$(switch_now)" = 1 ] && relay_due && relay_fetch
      printf '%s\n' "$RELAY_SEEN" > "$STATE/relay-keep.$$" \
        && mv -f "$STATE/relay-keep.$$" "$STATE/relay-keep"
      exit 0 ;;
    ensure|port)
      live_pid >/dev/null || { echo "fleet-cred-proxy: separated, and its service is not running ($SEP_RUN)" >&2; exit 1; }
      cat "$SEP_RUN/port"; exit 0 ;;
    node-token|node-hash|store|unstore|accounts)
      exec python3 -I "$PY" --state "$STATE" "$cmd" "$@" ;;
    relay)   # the minted relay pass on stdin → the proxy's own state (#1974)
      exec python3 -I "$PY" --state "$STATE" relay ;;
    probe)
      [ -f "${1:-}" ] || { echo "fleet-cred-proxy: probe <node-probe.json>" >&2; exit 2; }
      exec python3 -I "$PY" --state "$STATE" probe < "$1" ;;
  esac
fi

# a fresh quota reading is pushed onto its window by the proxy itself (issue
# #1978); FLEET_CRED_QUOTA_PUSH= (empty) turns that off — the quota watch's
# tick still pulls
export FLEET_CRED_QUOTA_PUSH="${FLEET_CRED_QUOTA_PUSH-$BIN/fleet-proxy-quota.sh}"
case "$cmd" in
  relay-tick)   # not separated: the resident launcher keeps the pass itself
    exit 0 ;;
  node-token|node-hash|probe|store|unstore|relay)
    echo "fleet-cred-proxy: $cmd: not separated (bin/fleet-credsep.sh)" >&2; exit 3 ;;
  run)
    child=''; on_now=0; seen=-1; nap=''
    stop_child() { [ -n "$child" ] && kill "$child" 2>/dev/null; wait "$child" 2>/dev/null; child=''; }
    trap 'stop_child; rm -f "$STATE/launcher.pid"; exit 0' TERM INT
    # USR1 = re-read the switch NOW (issue #2134): `fleet cred-proxy enable|disable`
    # (bin/fleet-cred-rollout.sh) nudges the launcher it finds in launcher.pid, so a
    # flip takes effect in seconds, not on the next $IDLE re-read
    trap 'seen=-1' USR1
    mkdir -p "$STATE" && chmod 700 "$STATE" && printf '%s\n' "$$" > "$STATE/launcher.pid"
    # Two clocks (issue #1975): the config is re-read every $IDLE seconds, the
    # proxy is looked at every $WATCH — a dead proxy is every session's next
    # request on this login, so it comes back within seconds, not a minute.
    WATCH="${FLEET_CRED_PROXY_WATCH_SECS:-2}"
    while :; do
      # this login just joined the machine's shared proxy (issue #2217): let go
      # of the port now — the shared one takes it over for our sessions
      [ -f "$CONF/credsep.json" ] && { stop_child; rm -f "$STATE/launcher.pid"; exec "$0" run "$@"; }
      if [ "$seen" -lt 0 ] || [ $(( $(date +%s) - seen )) -ge "$IDLE" ]; then
        on_now=$(switch_now); seen=$(date +%s)
        [ "$on_now" = 1 ] && relay_due && relay_fetch
      fi
      if [ "$on_now" = 1 ]; then
        if [ -z "$child" ] || ! kill -0 "$child" 2>/dev/null; then
          [ -n "$child" ] && { wait "$child" 2>/dev/null; sleep 2; }   # crashed: a short breath, then again
          python3 -I "$PY" serve --parent-watch "$@" &
          child=$!
        fi
        sleep "$WATCH" &
      else
        stop_child
        sleep "$IDLE" &
      fi
      nap=$!
      wait "$nap" 2>/dev/null
      kill "$nap" 2>/dev/null   # a USR1 cut the nap short: no stray sleep left behind
    done
    ;;
  ensure)
    on || { echo "fleet-cred-proxy: off (FLEET_CRED_PROXY=${FLEET_CRED_PROXY:-0})" >&2; exit 3; }
    if ! live_pid >/dev/null; then
      mkdir -p "$STATE" && chmod 700 "$STATE"
      relay_fetch >&2
      nohup python3 -I "$PY" serve "$@" </dev/null >/dev/null 2>&1 &
      i=0
      while [ "$i" -lt "$((${FLEET_CRED_PROXY_START_SECS:-30} * 10))" ] && ! { live_pid >/dev/null && [ -S "$STATE/ctl.sock" ]; }; do sleep 0.1; i=$((i + 1)); done
      live_pid >/dev/null || { echo "fleet-cred-proxy: did not start (see logs/cred-proxy.log)" >&2; exit 1; }
    fi
    cat "$STATE/port"
    ;;
  port)
    live_pid >/dev/null || { echo "fleet-cred-proxy: not running" >&2; exit 1; }
    cat "$STATE/port"
    ;;
  enable|disable)
    exec bash "$BIN/fleet-cred-rollout.sh" "$cmd" "$@"
    ;;
  status)   # the person's one line (issue #2134); --json / --ctl = the control socket's
    case "${1:-}" in
      --machine) exec bash "$BIN/fleet-cred-rollout.sh" status "$@" ;;
      --json) exec python3 -I "$PY" --state "$STATE" status "$@" ;;
      --ctl)  shift; exec python3 -I "$PY" --state "$STATE" status "$@" ;;
    esac
    exec bash "$BIN/fleet-cred-rollout.sh" status "$@"
    ;;
  route|mint|rebind|revoke|attach|quota|account-quota|picks|pass|machine|relay-probe)
    exec python3 -I "$PY" --state "$STATE" "$cmd" "$@"
    ;;
  doctor)
    on || exit 3
    if ! live_pid >/dev/null; then
      if [ "$(uname -s)" = Darwin ]; then kick="launchctl kickstart -k gui/$(id -u)/com.claude-fleet.cred-proxy"
      else kick="systemctl --user restart claude-fleet-cred-proxy"; fi
      printf 'FAIL\t代理没在跑：这台登录上的会话用不了订阅（启动器 2 秒内会拉起；没起来看 logs/cred-proxy.log，%s）\n' "$kick"
      exit 0
    fi
    st=$(python3 -I "$PY" --state "$STATE" status --json 2>&1) || { printf 'FAIL\t代理不回话：%s\n' "$st"; exit 0; }
    rc=$(python3 -I "$PY" --state "$STATE" route --provider claude --json 2>/dev/null)
    rx=$(python3 -I "$PY" --state "$STATE" route --provider codex --json 2>/dev/null)
    FCD_MS=$(python3 -I "$BIN/fleet-credsep.py" machine status --json 2>/dev/null) \
    FCD_ST="$st" FCD_RC="$rc" FCD_RX="$rx" FCD_SEP="${FLEET_CRED_SEPARATE:-0}" python3 -I - <<'DOC'
import json, os, time
def j(k):
    try:
        return json.loads(os.environ.get(k) or "{}")
    except ValueError:
        return {}
st, rc, rx = j("FCD_ST"), j("FCD_RC"), j("FCD_RX")
NAME = {"direct": "direct 直连", "relay": "relay 经新加坡转发", "central": "central 交给中心代理"}
TRUST = {"trusted": "可信", "untrusted": "不可信", "unknown": "可信与否不知道"}
lv, notes = "PASS", []
trust = st.get("trust") or "unknown"
if trust == "unknown":
    lv = "WARN"
    notes.append("入口问不到、也没有记过：按不可信走 central")
def road(name, r):
    if not r:
        return "%s 问不出路" % name
    return "%s 走 %s（%s）" % (name, NAME.get(r.get("route"), r.get("route")), r.get("reason", ""))
parts = ["%s（%s）" % (TRUST.get(trust, trust), st.get("trust_why", "")), road("Claude", rc)]
if rx and rx.get("route") != rc.get("route"):
    parts.append(road("Codex", rx))
elif rx:
    parts.append("Codex 同路")
if any(r.get("route") == "central" for r in (rc, rx)) and not st.get("central"):
    lv = "WARN"
    notes.append("没有中心代理地址（FLEET_CRED_CENTRAL_URL / 入口）")
parts.append("代理 pid %s 127.0.0.1:%s" % (st.get("pid"), st.get("port")))
ms = j("FCD_MS")
if st.get("shared"):
    # the machine's one proxy (issue #2217): whose it is, how many logins, its version
    v, iv = st.get("version") or "-", ms.get("install_version") or ""
    parts.append("shared 全机共享（%s 跑，%d 个登录，版本 %s%s）"
                 % (st.get("user") or "?", len(st.get("logins") or []), v,
                    "" if not iv or iv == v else "，本机安装 %s" % iv))
    if iv and v != iv:
        lv = "WARN"
        notes.append("共享代理落后本安装：管理员登录 sudo bash ~/.claude/fleet/bin/fleet-credsep.sh machine refresh")
elif st.get("separated"):
    parts.append("per-login 每登录代理")
    parts.append("凭据隔离 开")
elif os.environ.get("FCD_SEP") == "1":
    lv = "WARN"
    parts.append("per-login 每登录代理")
    parts.append("凭据隔离 应开未开（看 credsep 行）")
else:
    parts.append("per-login 每登录代理")
    parts.append("凭据隔离 关")
rn = st.get("renew") or {}
if rn.get("err") and rn.get("last_err", 0) >= rn.get("last_ok", 0):
    lv = "WARN"
    parts.append("通行证续签失败 %d 次，最近 %d 秒前：%s"
                 % (rn["err"], int(time.time() - rn["last_err"]), rn.get("err_why", "")))
else:
    parts.append("续签 正常（入口通行证 %d 次 · 本机会话凭据 %d 个续期 · 持有 %d 张）"
                 % (rn.get("ok", 0), rn.get("local", 0), st.get("hub_passes", 0)))
# the usage report (issue #3407): a login whose usage never reaches the hub
# meters nobody, and used to say so nowhere
bg = st.get("budget") or {}
if bg.get("err"):
    lv = "WARN"
    notes.append("用量没报上入口：%s（待报 %s token）" % (bg["err"], bg.get("pending", 0)))
if bg.get("misses"):
    lv = "WARN"
    notes.append("%d 个成功回答读不出用量（最近：%s）" % (bg["misses"], bg.get("miss_why", "")))
print("%s\t%s%s" % (lv, " · ".join(parts), ("；" + "；".join(notes)) if notes else ""))
DOC
    ;;
  -h|--help|'')
    sed -n '2,/^set -uo pipefail/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'
    [ -n "$cmd" ]; exit $?
    ;;
  *) echo "fleet-cred-proxy: unknown command $cmd (see --help)" >&2; exit 2 ;;
esac
