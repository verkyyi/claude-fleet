#!/usr/bin/env bash
# fleet-cred-rollout.sh — the credential proxy's status for a login, and the
# machine's ONE shared proxy's switch (issues #2134, #2217). `fleet cred-proxy …`
# reaches it through bin/fleet-cred-proxy.sh.
#
#   fleet cred-proxy status  [--all-logins [--logins a,b]]
#   fleet cred-proxy enable|status --machine [--logins a,b]
#
# --machine  the machine's ONE shared credential proxy (issue #2217) — the role
#          account (_fleetcred / fleetcred) runs it, every login is a tenant of
#          it, the credentials live where no login's session can read them.
#          enable = `fleet-credsep.sh machine install` (every login with
#          ~/.claude/fleet, or --logins): ONE sudo for the machine — run with
#          password-less sudo, else the line to type is printed (exit 4).
#          disable is gone (issue #4675: no way back to credentials in a
#          home — exit 2). status = ONE line `shared · <user> · on
#          k/N logins · sessions a/b` (N logins with a fleet install, k of them on
#          it; b live claude / codex processes on the machine, a of them on the
#          shared proxy) — `per-login · …` when there is none.
#
# A login's own `enable` / `disable` left with the per-login proxy (issue #4674):
# a machine runs ONE proxy, so the only switch is --machine (exit 2 otherwise).
#
# status   ONE line: `on|off · <route> · sessions n/m` — the switch as a new
#          session reads it, the proxy's route (`down` = on but no proxy, `-` =
#          off), and of this login's live claude / codex sessions, how many talk
#          to the proxy (Claude: ANTHROPIC_BASE_URL=http://127.0.0.1:<port>;
#          Codex: the `fleet` model provider). Only counts are printed — a
#          process's environment is read in memory, never echoed.
#
# --all-logins  this login first, then every other login's install on the machine
#               through bin/fleet-sync-logins.sh --cred-proxy status (as that
#               login, `sudo -n -u`; no passwordless sudo → the command to run is
#               printed); ends with `all: on k/N logins · sessions a/b`.
#
# Exit: 0 done (status: always, when it could read); 2 usage; --machine: the
# credsep script's; --all-logins: the worst of this login's and fleet-sync-logins.sh's.
#
# Seams (selftest — bin/fleet-cred-rollout-selftest.sh): FLEET_CRED_ROLLOUT_WAIT
# (seconds to wait for the shared proxy, default 75), FLEET_CRED_ROLLOUT_PROCS (a
# file of `<argv0>\t<argv + environment>` rows instead of the process table),
# FLEET_CRED_ROLLOUT_SYNC (the fleet-sync-logins.sh to run).
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
CONF="${FLEET_CONF_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/claude-fleet}"
export FLEET_CONF_DIR="$CONF"
MC="$CONF/fleet.conf"
WAIT="${FLEET_CRED_ROLLOUT_WAIT:-75}"
ME="$(id -un)"

usage() { sed -n '2,/^set -uo pipefail/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; }
say() { printf 'cred-proxy: %s\n' "$*"; }

verb="${1:-}"; [ $# -gt 0 ] && shift
all=0 logins='' machine=0
while [ $# -gt 0 ]; do
  case "$1" in
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
if [ "$machine" = 0 ] && [ "$verb" != status ]; then
  echo "fleet cred-proxy: a login has no proxy of its own to $verb any more (#4674) — the machine's one: fleet cred-proxy $verb --machine" >&2
  exit 2
fi

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
# count_sessions "<port> [<port>…]" → `n m`: m live claude / codex sessions of this
# login, n of them through the proxy — on any port it serves this login on: the
# shared proxy also answers the login's OLD port, which its sessions from before
# the join still carry (issue #2324). argv0's basename names the agent (the native
# claude's accounting name is its version); the environment is read in memory.
count_sessions() {
  FCR_PORT="${1:-}" FCR_PROCS="${FLEET_CRED_ROLLOUT_PROCS:-}" python3 -I - <<'PY'
import os, re, subprocess, sys
ports = os.environ.get("FCR_PORT", "").split()
lp = r"http://127\.0\.0\.1:(?:%s)" % "|".join(re.escape(p) for p in ports) if ports else r"http://127\.0\.0\.1:\d+"
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
    # and the old port the shared proxy answers for this login (issue #2324)
    port="$port $(env -u FLEET_CRED_PROXY bash "$BIN/fleet-cred-proxy.sh" status --json 2>/dev/null \
      | python3 -I -c 'import json,sys
try: print(json.load(sys.stdin).get("legacy_port") or "")
except ValueError: pass' 2>/dev/null)"
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
    disable) echo "fleet cred-proxy: disable --machine is gone (issue #4675) — credentials never go back into a home" >&2
             return 2 ;;
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
  [ "$all" = 0 ] || { echo 'fleet cred-proxy: --machine goes alone (with --logins)' >&2; exit 2; }
  do_machine; exit $?
fi

# ---- one login, or all of them ------------------------------------------------------
[ "$all" = 0 ] && { status_line; exit 0; }

SYNC="${FLEET_CRED_ROLLOUT_SYNC:-$BIN/fleet-sync-logins.sh}"
own=$(status_line); orc=$?
printf '%s\n' "$own" | sed "s|^|$ME: |"
others=$(bash "$SYNC" --cred-proxy status ${logins:+--logins "$logins"} 2>&1); src=$?
[ -n "$others" ] && printf '%s\n' "$others"
{ printf '%s: %s\n' "$ME" "$(printf '%s\n' "$own" | tail -n 1)"; printf '%s\n' "$others"; } | awk '
    /^[^ :]+: (on|off) · .* · sessions [0-9]+\/[0-9]+$/ {
      N++; if ($2 == "on") k++
      split($NF, s, "/"); a += s[1]; b += s[2]
    }
    END { printf "all: on %d/%d logins · sessions %d/%d\n", k, N, a, b }'
[ "$orc" -ge "$src" ] && exit "$orc"
exit "$src"
