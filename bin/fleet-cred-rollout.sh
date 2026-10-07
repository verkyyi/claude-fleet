#!/usr/bin/env bash
# fleet-cred-rollout.sh — the credential proxy's ONE switch for a login, and for
# every login on the machine (issue #2134, EPIC #2133 C4). `fleet cred-proxy …`
# reaches it through bin/fleet-cred-proxy.sh.
#
#   fleet cred-proxy enable  [--relay-url <url>] [--all-logins [--logins a,b]]
#   fleet cred-proxy disable [--all-logins [--logins a,b]]
#   fleet cred-proxy status  [--all-logins [--logins a,b]]
#   fleet cred-proxy enable|disable|status --machine [--logins a,b]
#
# --machine  the machine's ONE shared credential proxy (issue #2217) — a managed
#          node, not a laptop: the role account (_fleetcred / fleetcred) runs it,
#          every login is a tenant of it, the credentials live where no login's
#          session can read them. enable = `fleet-credsep.sh machine install`
#          (every login with ~/.claude/fleet, or --logins): ONE sudo for the
#          machine — run with password-less sudo, else the line to type is
#          printed (exit 4). disable = `machine uninstall`: every login back on
#          its own proxy, each fleet.conf line and credential file where it was.
#          status = ONE line `shared · <user> · on k/N logins · sessions a/b`
#          (N logins with a fleet install, k of them on it; b live claude /
#          codex processes on the machine, a of them on the shared proxy) —
#          `per-login · …` when there is none.
#
# enable   writes `export FLEET_CRED_PROXY=1` (and, with --relay-url, the relay
#          route's FLEET_CRED_RELAY_URL) into fleet.conf [common] — remembering
#          the line each key had before (cred-proxy/rollout.prior.<KEY>, or
#          .absent) — makes sure the proxy's daemon is installed and running
#          (com.claude-fleet.cred-proxy / claude-fleet-cred-proxy.service; a
#          running launcher is nudged with USR1 so it re-reads the switch now),
#          refreshes this login's relay pass (fleet-relay-cred.sh fetch, when a
#          relay is configured and the hub module is on), waits for the proxy's
#          port, then prints the doctor's `cred` row and the status line.
# disable  puts every remembered line back where it was — a key that was absent
#          is deleted — so enable → disable leaves fleet.conf byte for byte as it
#          was (共同约定 1); with nothing remembered (switched on by hand) it
#          writes FLEET_CRED_PROXY=0. The launcher is nudged and the proxy stops.
#          The daemon stays installed: switched off it runs no proxy.
# status   ONE line: `on|off · <route> · sessions n/m` — the switch as a new
#          session reads it, the proxy's route (`down` = on but no proxy, `-` =
#          off), and of this login's live claude / codex sessions, how many talk
#          to the proxy (Claude: ANTHROPIC_BASE_URL=http://127.0.0.1:<port>;
#          Codex: the `fleet` model provider). Only counts are printed — a
#          process's environment is read in memory, never echoed.
#
# Sessions already running keep their wiring (共同约定 1): a new session takes the
# proxy, an old one leaves on its own or moves over with fleet-account.sh migrate.
#
# --all-logins  this login first, then every other login's install on the machine
#               through bin/fleet-sync-logins.sh --cred-proxy <verb> (as that
#               login, `sudo -n -u`; no passwordless sudo → the command to run is
#               printed). status ends with `all: on k/N logins · sessions a/b`.
#
# Exit: 0 done (status: always, when it could read); 1 enable/disable did not
# take (the proxy did not come up / go down — the conf change stays; `disable`
# is the way back); 2 usage; 3 no fleet.conf here (fleet-conf.sh migrate);
# --all-logins: the worst of this login's and fleet-sync-logins.sh's.
#
# Seams (selftest — bin/fleet-cred-rollout-selftest.sh): FLEET_CRED_ROLLOUT_DAEMON
# (a command run instead of the daemon step), FLEET_CRED_ROLLOUT_WAIT (seconds to
# wait for the proxy, default 75), FLEET_CRED_ROLLOUT_PROCS (a file of
# `<argv0>\t<argv + environment>` rows instead of the process table),
# FLEET_CRED_ROLLOUT_SYNC (the fleet-sync-logins.sh to run).
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
CONF="${FLEET_CONF_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/claude-fleet}"
export FLEET_CONF_DIR="$CONF"
STATE="$CONF/cred-proxy"
MC="$CONF/fleet.conf"
WAIT="${FLEET_CRED_ROLLOUT_WAIT:-75}"
KEYS="FLEET_CRED_PROXY FLEET_CRED_RELAY_URL"
ME="$(id -un)"

usage() { sed -n '2,/^set -uo pipefail/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; }
say() { printf 'cred-proxy: %s\n' "$*"; }

verb="${1:-}"; [ $# -gt 0 ] && shift
relay='' all=0 logins='' machine=0
while [ $# -gt 0 ]; do
  case "$1" in
    --relay-url)   relay="${2:-}"; shift; [ -n "$relay" ] || { usage >&2; exit 2; } ;;
    --relay-url=*) relay="${1#--relay-url=}" ;;
    --all-logins)  all=1 ;;
    --machine)     machine=1 ;;
    --logins)      logins="${2:-}"; shift ;;
    --logins=*)    logins="${1#--logins=}" ;;
    -h|--help)     usage; exit 0 ;;
    *) printf 'fleet cred-proxy: unknown argument %s\n' "$1" >&2; exit 2 ;;
  esac
  shift
done
case "$verb" in enable|disable|status) ;; -h|--help) usage; exit 0 ;; *) usage >&2; exit 2 ;; esac
[ -z "$relay" ] || [ "$verb" = enable ] || { echo 'fleet cred-proxy: --relay-url goes with enable' >&2; exit 2; }
case "$relay" in
  '') ;;
  http://*|https://*)
    case "$relay" in *@*|*\"*|*\'*|*' '*|*'$'*|*'`'*)
      echo 'fleet cred-proxy: --relay-url must be a plain URL (no credentials, quotes or spaces) — the relay pass is minted, never written here' >&2; exit 2 ;;
    esac ;;
  *) echo "fleet cred-proxy: --relay-url $relay is not an http(s) URL" >&2; exit 2 ;;
esac

# conf_val <KEY> — KEY as a new session reads it: the install's fleet.conf <
# fleet.settings < the machine's fleet.conf (fleet-cred-proxy.sh's load_conf
# order), never the caller's environment
conf_val() {
  ( unset "$1"
    set -a
    for f in "$BIN/../fleet.conf" "$CONF/fleet.settings" "$MC"; do
      # shellcheck source=/dev/null
      [ -f "$f" ] && . "$f" >/dev/null 2>&1
    done
    set +a
    eval "printf '%s' \"\${$1:-}\"" )
}
switch_now() { local v; v=$(conf_val FLEET_CRED_PROXY); [ "$v" = 1 ] && echo on || echo off; }

proxy_up() { env -u FLEET_CRED_PROXY bash "$BIN/fleet-cred-proxy.sh" port >/dev/null 2>&1; }
proxy_port() { env -u FLEET_CRED_PROXY bash "$BIN/fleet-cred-proxy.sh" port 2>/dev/null; }

# ---- sessions n/m ---------------------------------------------------------------
# count_sessions <port> → `n m`: m live claude / codex sessions of this login, n of
# them through the proxy. argv0's basename names the agent (the native claude's
# accounting name is its version); the environment is read and matched in memory.
count_sessions() {
  FCR_PORT="${1:-}" FCR_PROCS="${FLEET_CRED_ROLLOUT_PROCS:-}" python3 -I - <<'PY'
import os, re, subprocess, sys
port = os.environ.get("FCR_PORT", "")
lp = re.escape("http://127.0.0.1:" + port) if port else r"http://127\.0\.0\.1:\d+"
claude_re = re.compile(r"(?:^|\s)ANTHROPIC_BASE_URL=" + lp + r"(?:/|\s|$)")
codex_re = re.compile(r"(?:^|\s)FLEET_CODEX_SESSION_CRED=|model_provider=\"?fleet\"?(?:\s|$)")
rows = []
src = os.environ.get("FCR_PROCS")
if src:
    with open(src, encoding="utf-8", errors="replace") as f:
        for ln in f:
            a, _, blob = ln.rstrip("\n").partition("\t")
            rows.append((a, blob))
elif os.path.isdir("/proc/self") and sys.platform.startswith("linux"):
    uid = os.getuid()
    for p in os.listdir("/proc"):
        if not p.isdigit():
            continue
        try:
            if os.stat("/proc/" + p).st_uid != uid:
                continue
            with open("/proc/%s/cmdline" % p, "rb") as f:
                argv = f.read().split(b"\0")
            with open("/proc/%s/environ" % p, "rb") as f:
                env = f.read().replace(b"\0", b" ")
        except OSError:
            continue
        rows.append((argv[0].decode("utf-8", "replace"),
                     b" ".join(argv).decode("utf-8", "replace") + " " + env.decode("utf-8", "replace")))
else:
    try:
        out = subprocess.run(["ps", "-ww", "-U", str(os.getuid()), "-o", "pid=,comm="],
                             capture_output=True, text=True, timeout=20).stdout
    except (OSError, subprocess.SubprocessError):
        out = ""
    pids = {}
    for ln in out.splitlines():
        pid, _, comm = ln.strip().partition(" ")
        comm = comm.strip()
        if os.path.basename(comm) in ("claude", "codex"):
            pids[pid] = comm
    if pids:
        try:
            env = subprocess.run(["ps", "-E", "-ww", "-o", "pid=,command=", "-p", ",".join(pids)],
                                 capture_output=True, text=True, timeout=20).stdout
        except (OSError, subprocess.SubprocessError):
            env = ""
        for ln in env.splitlines():
            pid, _, blob = ln.strip().partition(" ")
            if pid in pids:
                rows.append((pids[pid], blob))
n = m = 0
for argv0, blob in rows:
    name = os.path.basename(argv0)
    if name == "claude":
        m += 1
        n += bool(claude_re.search(blob))
    elif name == "codex":
        m += 1
        n += bool(codex_re.search(blob))
print(n, m)
PY
}

status_line() {
  local sw route='-' port='' nm
  sw=$(switch_now)
  if proxy_up; then
    port=$(proxy_port)
    route=$(env -u FLEET_CRED_PROXY bash "$BIN/fleet-cred-proxy.sh" route --json 2>/dev/null \
      | python3 -I -c 'import json,sys
try: print(json.load(sys.stdin).get("route") or "?")
except ValueError: print("?")' 2>/dev/null)
    [ -n "$route" ] || route='?'
  elif [ "$sw" = on ]; then
    route=down
  fi
  nm=$(count_sessions "$port"); nm=${nm:-0 0}
  printf '%s · %s · sessions %s/%s\n' "$sw" "$route" "${nm% *}" "${nm#* }"
}

# ---- the conf, remembered line by line -------------------------------------------
fconf() { bash "$BIN/fleet-conf.sh" "$@"; }

remember() {   # <KEY> — its line before our first write (once; a second enable keeps the first record)
  local k="$1" cur n
  [ -e "$STATE/rollout.prior.$k" ] || [ -e "$STATE/rollout.prior.$k.absent" ] && return 0
  cur=$(fconf line "$k" 2>/dev/null)
  n=$(printf '%s' "$cur" | grep -c '' 2>/dev/null)
  if [ "${n:-0}" -gt 1 ]; then
    say "fleet.conf sets $k on $n lines — fix that by hand first (nothing changed)" >&2; return 1
  fi
  mkdir -p "$STATE" && chmod 700 "$STATE" || return 1
  if [ -n "$cur" ]; then printf '%s' "$cur" > "$STATE/rollout.prior.$k"
  else : > "$STATE/rollout.prior.$k.absent"; fi
}

restore() {    # <KEY> → 0 restored · 1 nothing remembered · 2 write failed
  local k="$1"
  if [ -e "$STATE/rollout.prior.$k" ]; then
    fconf set-line "$k" "$(cat "$STATE/rollout.prior.$k")" || return 2
    rm -f "$STATE/rollout.prior.$k"
  elif [ -e "$STATE/rollout.prior.$k.absent" ]; then
    fconf drop-line "$k" || return 2
    rm -f "$STATE/rollout.prior.$k.absent"
  else
    return 1
  fi
}

# ---- the daemon ---------------------------------------------------------------
# nudge — a launcher that writes launcher.pid traps USR1 (re-read the switch now);
# one from before #2134 does not, and is never sent a signal it would die of
nudge() {
  local lp
  lp=$(cat "$STATE/launcher.pid" 2>/dev/null)
  case "$lp" in ''|*[!0-9]*) return 1 ;; esac
  kill -0 "$lp" 2>/dev/null || return 1
  kill -USR1 "$lp" 2>/dev/null
}

daemon_ensure() {
  if [ -n "${FLEET_CRED_ROLLOUT_DAEMON:-}" ]; then bash -c "$FLEET_CRED_ROLLOUT_DAEMON"; return; fi
  if nudge; then say "daemon: running — told to re-read the switch now"; return 0; fi
  local root tmpl plist label shape dom brew rc
  root="$(cd "$BIN/.." && pwd)"
  if [ "$(uname -s)" = Darwin ]; then
    # shellcheck source=/dev/null
    . "$BIN/fleet-daemon-lib.sh" 2>/dev/null || { say "daemon: fleet-daemon-lib.sh missing beside $BIN"; return 1; }
    shape=$(fleet_daemon_shape); label=$(fleet_daemon_label cred-proxy "$shape"); plist=$(fleet_daemon_plist cred-proxy "$shape")
    dom=$(fleet_daemon_domain "$shape")
    sh "$BIN/fleet-daemon-loaded.sh" "$label" >/dev/null 2>&1; rc=$?
    if [ "$rc" = 0 ] || [ "$rc" = 3 ]; then
      # loaded, launcher from before #2134 (no launcher.pid): restart it, or leave it to its own re-read
      if launchctl kickstart -k "$dom/$label" >/dev/null 2>&1 || { [ "$shape" = system ] && sudo -n launchctl kickstart -k "system/$label" >/dev/null 2>&1; }; then
        say "daemon: $label restarted"
      else
        say "daemon: $label loaded — it re-reads the switch within ${FLEET_CRED_PROXY_IDLE_SECS:-60}s"
      fi
      return 0
    fi
    if [ "$shape" = system ]; then
      say "daemon: $label is not installed, and this login's daemons are system LaunchDaemons — an admin runs:"
      printf '  sudo sh -c %s\n' "'FLEET_INSTALL_LOGIN=$ME FLEET_INSTALL_HOME=$HOME $root/bin/fleet-install-apply.sh --render-system cred-proxy --root $root > $plist && launchctl bootstrap system $plist'"
      return 1
    fi
    tmpl="$root/launchd/com.claude-fleet.cred-proxy.plist.tmpl"
    [ -f "$tmpl" ] || { say "daemon: no template $tmpl"; return 1; }
    brew=$(brew --prefix 2>/dev/null || printf '/opt/homebrew')
    mkdir -p "$(dirname "$plist")" "$root/logs"
    sed -e "s|__HOME__|$HOME|g" -e "s|__BREW_PREFIX__|$brew|g" "$tmpl" > "$plist" || { say "daemon: cannot write $plist"; return 1; }
    launchctl bootstrap "$dom" "$plist" 2>/dev/null || launchctl kickstart -k "$dom/$label" >/dev/null 2>&1 \
      || { say "daemon: launchctl bootstrap $dom $plist failed"; return 1; }
    say "daemon: $label installed and loaded"
    return 0
  fi
  if command -v systemctl >/dev/null 2>&1; then
    local unit="$HOME/.config/systemd/user/claude-fleet-cred-proxy.service"
    if [ ! -f "$unit" ]; then
      mkdir -p "$(dirname "$unit")" "$root/logs"
      sed -e "s|__HOME__|$HOME|g" "$root/systemd/claude-fleet-cred-proxy.service" > "$unit" || { say "daemon: cannot write $unit"; return 1; }
      systemctl --user daemon-reload >/dev/null 2>&1
    fi
    if systemctl --user enable --now claude-fleet-cred-proxy.service >/dev/null 2>&1 \
       && systemctl --user restart claude-fleet-cred-proxy.service >/dev/null 2>&1; then
      say "daemon: claude-fleet-cred-proxy.service running"; return 0
    fi
    say "daemon: systemctl --user enable --now claude-fleet-cred-proxy.service failed"; return 1
  fi
  say "daemon: no launchd or systemd here — fleet-cred-proxy.sh ensure starts one by hand"; return 1
}

wait_proxy() {   # up|down
  local i=0
  while [ "$i" -lt "$((WAIT * 2))" ]; do
    if [ "$1" = up ]; then proxy_up && return 0; else proxy_up || return 0; fi
    sleep 0.5; i=$((i + 1))
  done
  if [ "$1" = up ]; then proxy_up; else ! proxy_up; fi
}

# ---- the verbs ------------------------------------------------------------------
do_enable() {
  [ -f "$MC" ] || { say "no $MC — run fleet-conf.sh migrate first (nothing changed)" >&2; return 3; }
  local rc=0 k line
  for k in $KEYS; do
    [ "$k" = FLEET_CRED_RELAY_URL ] && [ -z "$relay" ] && continue
    remember "$k" || return 1
  done
  fconf set-line FLEET_CRED_PROXY 'export FLEET_CRED_PROXY=1' || return 1
  [ -n "$relay" ] && { fconf set-line FLEET_CRED_RELAY_URL "export FLEET_CRED_RELAY_URL=\"$relay\"" || return 1; }
  say "fleet.conf: FLEET_CRED_PROXY=1${relay:+ · FLEET_CRED_RELAY_URL=$relay} (new sessions; \`fleet cred-proxy disable\` puts it back)"
  daemon_ensure || rc=1
  # the relay pass (#1974): only when a relay is configured and the hub module is on
  if [ -n "$(conf_val FLEET_CRED_RELAY_URL)" ] && [ "$(conf_val CCQUOTA_FLEET)" = 1 ]; then
    bash "$BIN/fleet-relay-cred.sh" fetch >/dev/null 2>&1   # its output is never echoed: only the verdict
    case "$?" in
      0)  say "relay pass: ok" ;;
      4)  say "relay pass: the hub refused (untrusted / revoked / no account) — the proxy routes around it" ;;
      *)  say "relay pass: not had now — the launcher keeps trying (fleet-relay-cred.sh check)" ;;
    esac
  fi
  if wait_proxy up; then say "proxy: up on 127.0.0.1:$(proxy_port)"
  else say "proxy: not up after ${WAIT}s — logs/cred-proxy.log"; rc=1; fi
  line=$(env -u FLEET_CRED_PROXY bash "$BIN/fleet-cred-proxy.sh" doctor 2>/dev/null)
  if [ -n "$line" ]; then
    say "doctor cred: ${line%%	*} ${line#*	}"
    case "$line" in FAIL*) rc=1 ;; esac
  fi
  printf '%s\n' "$(status_line)"
  return "$rc"
}

do_disable() {
  local rc=0 k r did=''
  for k in $KEYS; do
    restore "$k"; r=$?
    case "$r" in 0) did="$did $k" ;; 2) say "cannot write $MC" >&2; return 1 ;; esac
  done
  if [ "$(switch_now)" = on ]; then   # switched on by hand: nothing remembered
    fconf set-line FLEET_CRED_PROXY 'export FLEET_CRED_PROXY=0' || return 1
    did="$did FLEET_CRED_PROXY=0"
  fi
  if [ -n "$did" ]; then say "fleet.conf: put back${did} — new sessions take today's wiring"
  else say "fleet.conf: already off — nothing to put back"; fi
  if proxy_up; then
    if [ -n "${FLEET_CRED_ROLLOUT_DAEMON:-}" ]; then bash -c "$FLEET_CRED_ROLLOUT_DAEMON"
    else nudge || say "daemon: the launcher stops the proxy within ${FLEET_CRED_PROXY_IDLE_SECS:-60}s"; fi
    if wait_proxy down; then say "proxy: stopped"
    else say "proxy: still running after ${WAIT}s"; rc=1; fi
  fi
  printf '%s\n' "$(status_line)"
  return "$rc"
}

# ---- the machine's shared proxy (issue #2217) -----------------------------------------
CREDSEP="${FLEET_CRED_ROLLOUT_CREDSEP:-$BIN/fleet-credsep.sh}"
machine_line() {
  local ms mc
  ms=$(bash "$CREDSEP" machine status --json 2>/dev/null)
  mc=$(env -u FLEET_CRED_PROXY bash "$BIN/fleet-cred-proxy.sh" machine 2>/dev/null)
  FCR_MS="$ms" FCR_MC="$mc" FCR_PROCS="${FLEET_CRED_ROLLOUT_PROCS:-}" python3 -I - <<'PY'
import json, os, subprocess
def j(k):
    try:
        return json.loads(os.environ.get(k) or "{}")
    except ValueError:
        return {}
ms, mc = j("FCR_MS"), j("FCR_MC")
src = os.environ.get("FCR_PROCS")
if src:
    names = [ln.split("\t", 1)[0] for ln in open(src, encoding="utf-8", errors="replace")]
else:
    try:   # every user's — names only: another login's environment is not ours to read
        names = subprocess.run(["ps", "-A", "-o", "comm="], capture_output=True, text=True, timeout=20).stdout.split("\n")
    except (OSError, subprocess.SubprocessError):
        names = []
b = sum(1 for n in names if os.path.basename(n.strip()) in ("claude", "codex"))
every = ms.get("machine_logins") or []
if not ms.get("shared"):
    print("per-login · no shared proxy · %d login(s) with a fleet install" % len(every))
else:
    on = ms.get("logins") or []
    n = len(set(every) | set(on))
    a = sum(v.get("live", 0) for v in (mc.get("logins") or {}).values())
    up = "" if ms.get("live_port") else " · DOWN"
    print("shared · %s · on %d/%d logins · sessions %d/%d%s" % (ms.get("user") or "?", len(on), n, a, max(a, b), up))
PY
}

do_machine() {
  local rc out i
  case "$verb" in
    status) machine_line; return 0 ;;
    enable)  bash "$CREDSEP" machine install --logins "${logins:-all}"; rc=$? ;;
    disable) bash "$CREDSEP" machine uninstall; rc=$? ;;
  esac
  [ "$rc" = 4 ] && return 4    # no password-less sudo: the line to type was printed
  if [ "$verb" = enable ] && [ "$rc" = 0 ]; then
    i=0; while [ "$i" -lt "$((WAIT * 2))" ]; do
      out=$(bash "$CREDSEP" machine status --json 2>/dev/null)
      case "$out" in *'"live_port": null'*|'') ;; *) break ;; esac
      sleep 0.5; i=$((i + 1))
    done
  fi
  machine_line
  return "$rc"
}

if [ "$machine" = 1 ]; then
  [ "$all" = 0 ] && [ -z "$relay" ] || { echo 'fleet cred-proxy: --machine goes alone (with --logins)' >&2; exit 2; }
  do_machine; exit $?
fi

# ---- one login, or all of them ------------------------------------------------------
if [ "$all" = 0 ]; then
  case "$verb" in
    enable)  do_enable;  exit $? ;;
    disable) do_disable; exit $? ;;
    status)  status_line; exit 0 ;;
  esac
fi

SYNC="${FLEET_CRED_ROLLOUT_SYNC:-$BIN/fleet-sync-logins.sh}"
run_verb() {
  case "$verb" in
    enable)  do_enable ;;
    disable) do_disable ;;
    *)       status_line ;;
  esac
}
own=$(run_verb); orc=$?
printf '%s\n' "$own" | sed "s|^|$ME: |"
others=$(bash "$SYNC" --cred-proxy "$verb" ${logins:+--logins "$logins"} 2>&1); src=$?
[ -n "$others" ] && printf '%s\n' "$others"
if [ "$verb" = status ]; then
  { printf '%s: %s\n' "$ME" "$(printf '%s\n' "$own" | tail -n 1)"; printf '%s\n' "$others"; } | awk '
    /^[^ :]+: (on|off) · .* · sessions [0-9]+\/[0-9]+$/ {
      N++; if ($2 == "on") k++
      split($NF, s, "/"); a += s[1]; b += s[2]
    }
    END { printf "all: on %d/%d logins · sessions %d/%d\n", k, N, a, b }'
fi
[ "$orc" -ge "$src" ] && exit "$orc"
exit "$src"
