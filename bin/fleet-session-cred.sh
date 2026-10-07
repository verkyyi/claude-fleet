#!/usr/bin/env bash
# fleet-session-cred.sh — a session's credential, through this login's proxy
# (issue #1972, EPIC #1967 C5). A session never holds a subscription credential:
# it holds a SESSION credential and talks to bin/fleet-cred-proxy.py on loopback,
# which puts the real one in on the way out — so an account change is the proxy's
# `rebind`, never a closed window.
#
#   fleet-session-cred.sh on                  exit 0 ⇔ FLEET_CRED_PROXY=1 (fleet.conf / env)
#   fleet-session-cred.sh mint --provider claude|codex --sid SID
#                              [--account LABEL] [--codex-home DIR]
#        → one line on stdout: <route> TAB <port> TAB <session credential>
#          route direct|relay  the proxy signs an fcp1. bound to LABEL (or, for
#                              Codex, the account DIR is: ~/.codex = default,
#                              <FLEET_CRED_CODEX_HOMES>/<L> = L)
#          route central       an untrusted machine: an fcp-h1. pass borrowed from
#                              the hub (POST /v1/fleet/session-cred, the node token
#                              + this session's own worker assertion) — no account
#          exit 3 switched off · 4 nothing to bind (no account on a trusted route:
#          the ambient login, which holds nothing to protect) · 1 failed
#   fleet-session-cred.sh revoke --sid SID    at the session's exit: the proxy's
#                              revoke (or the revoked list when it is down), the
#                              hub pass's DELETE, the Codex home marked dead
#   fleet-session-cred.sh rebind --sid SID --account LABEL
#                              the next request of that session runs on LABEL
#   fleet-session-cred.sh codex-home --sid SID --real DIR
#        → a credential-free CODEX_HOME for this session: every entry of DIR
#          linked except auth.json (threads, history, skills, trust stay DIR's),
#          `.fleet-real-home` naming DIR. bin/fleet-codex.sh maps it back.
#
# State: $FLEET_CONF_DIR/cred-proxy/sessions/<sid> (route, provider, hub pass id,
# the wrapper's pid — never a credential) and …/codex-homes/<sid>/. A credential
# goes to stdout only, never argv, a file, a log or a tmux option (共同约定 4).
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
CONF="${FLEET_CONF_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/claude-fleet}"
STATE="$CONF/cred-proxy"
PROXY="$BIN/fleet-cred-proxy.sh"

die() { printf 'fleet-session-cred: %s\n' "$1" >&2; exit "${2:-1}"; }

switch() { # 1 / 0 — an explicit environment value outranks the conf (fleet-cred-proxy.sh's rule)
  [ -n "${FLEET_CRED_PROXY:-}" ] && { printf '%s' "$FLEET_CRED_PROXY"; return; }
  ( set -a
    for f in "$BIN/../fleet.conf" "$CONF/fleet.settings" "$CONF/fleet.conf"; do
      # shellcheck source=/dev/null
      [ -f "$f" ] && . "$f" >/dev/null 2>&1
    done
    printf '%s' "${FLEET_CRED_PROXY:-0}" )
}

sid_ok() { case "${1:-}" in ''|*[!A-Za-z0-9._-]*|.*) return 1 ;; esac; }

rec_set() { # <sid> <key> <value>
  local f="$STATE/sessions/$1"
  mkdir -p "$STATE/sessions" && chmod 700 "$STATE" "$STATE/sessions" 2>/dev/null
  { grep -v "^$2=" "$f" 2>/dev/null; printf '%s=%s\n' "$2" "$3"; } > "$f.tmp.$$" && mv "$f.tmp.$$" "$f"
}
rec_get() { sed -n "s/^$2=//p" "$STATE/sessions/$1" 2>/dev/null | tail -n 1; }

codex_label() { # <home> → the proxy's label for it (default | <name>), exit 1 = not one the proxy reads
  local h homes
  h=$(cd "$1" 2>/dev/null && pwd -P) || return 1
  [ "$h" = "$(cd "$HOME/.codex" 2>/dev/null && pwd -P)" ] && { printf default; return 0; }
  homes=$(cd "${FLEET_CRED_CODEX_HOMES:-$HOME/.codex-accounts}" 2>/dev/null && pwd -P) || return 1
  case "$h" in "$homes"/*/*|"$homes"/) return 1 ;; "$homes"/*) printf '%s' "${h##*/}"; return 0 ;; esac
  return 1
}

# hub_pass <provider> → "<id>\t<cred>": the node token is read INSIDE python from
# node.env (never exported, issue #1491); the assertion travels in the environment.
hub_pass() {
  local a="${FLEET_WORKER_ASSERT:-}"   # a caller that already holds this session's own
  [ -n "$a" ] || a=$(python3 "$BIN/fleet-mcp.py" --cred assert 2>/dev/null)
  [ -n "$a" ] || die "central route: this session has no worker assertion (FLEET_WORKER_CRED, a hub) — no pass"
  FLEET_WORKER_ASSERT="$a" FSC_PROVIDER="$1" FSC_CONF="$CONF" python3 -I - <<'PY'
import json, os, sys, urllib.request
ne = {}
try:
    for line in open(os.path.join(os.environ["FSC_CONF"], "node.env")):
        line = line.strip()
        if line.startswith("export "):
            line = line[7:]
        if "=" in line and not line.startswith("#"):
            k, v = line.split("=", 1)
            ne[k.strip()] = v.strip().strip('"').strip("'")
except OSError:
    pass
hub = (ne.get("CCQUOTA_HUB_URL") or os.environ.get("FLEET_HUB_URL", "")).rstrip("/")
tok = ne.get("CCQUOTA_TOKEN", "")
if not hub or not tok:
    sys.exit("fleet-session-cred: central route: no hub / node token (node.env)")
body = json.dumps({"providers": [os.environ["FSC_PROVIDER"]]}).encode()
req = urllib.request.Request(hub + "/v1/fleet/session-cred", data=body, method="POST", headers={
    "Authorization": "Bearer " + tok, "X-Fleet-Worker": os.environ["FLEET_WORKER_ASSERT"],
    "Content-Type": "application/json"})
try:
    with urllib.request.urlopen(req, timeout=15) as r:
        d = json.loads(r.read() or b"{}")
except Exception as e:
    sys.exit("fleet-session-cred: central route: the hub refused a pass (%s)" % getattr(e, "code", type(e).__name__))
cred, pid = d.get("cred", ""), d.get("id", "")
if not cred.startswith("fcp-h1.") or not pid or "\t" in pid:
    sys.exit("fleet-session-cred: central route: the hub's answer carries no pass")
print("%s\t%s" % (pid, cred))
PY
}

hub_drop() { # <pass id> — DELETE it, best effort (it expires on its own)
  FSC_ID="$1" FSC_CONF="$CONF" python3 -I - <<'PY' >/dev/null 2>&1
import os, urllib.parse, urllib.request
ne = {}
try:
    for line in open(os.path.join(os.environ["FSC_CONF"], "node.env")):
        line = line.strip()
        if line.startswith("export "):
            line = line[7:]
        if "=" in line and not line.startswith("#"):
            k, v = line.split("=", 1)
            ne[k.strip()] = v.strip().strip('"').strip("'")
except OSError:
    pass
hub = (ne.get("CCQUOTA_HUB_URL") or os.environ.get("FLEET_HUB_URL", "")).rstrip("/")
tok = ne.get("CCQUOTA_TOKEN", "")
if hub and tok:
    req = urllib.request.Request(hub + "/v1/fleet/session-cred/" + urllib.parse.quote(os.environ["FSC_ID"], safe=""),
                                 method="DELETE", headers={"Authorization": "Bearer " + tok})
    urllib.request.urlopen(req, timeout=10).read()
PY
}

cmd="${1:-}"; [ $# -gt 0 ] && shift
provider=claude; sid=''; account=''; chome=''; real=''
while [ $# -gt 0 ]; do
  case "$1" in
    --provider)   provider="${2:-}"; shift 2 ;;
    --sid)        sid="${2:-}"; shift 2 ;;
    --account)    account="${2:-}"; shift 2 ;;
    --codex-home) chome="${2:-}"; shift 2 ;;
    --real)       real="${2:-}"; shift 2 ;;
    *) die "unknown argument $1" 2 ;;
  esac
done

case "$cmd" in
  on) [ "$(switch)" = 1 ] ;;
  mint)
    [ "$(switch)" = 1 ] || exit 3
    sid_ok "$sid" || die "mint: --sid NAME ([A-Za-z0-9._-])" 2
    case "$provider" in claude|codex) ;; *) die "mint: --provider claude|codex" 2 ;; esac
    port=$(FLEET_CRED_PROXY=1 bash "$PROXY" ensure 2>/dev/null) && [ -n "$port" ] \
      || die "the credential proxy is not running and would not start (logs/cred-proxy.log)"
    rt=$(bash "$PROXY" route --provider "$provider" --json 2>/dev/null)
    case "$rt" in *'"trust": "unknown"'*) rt=$(bash "$PROXY" route --provider "$provider" --refresh --json 2>/dev/null) ;; esac
    route=$(printf '%s' "$rt" | python3 -c 'import json,sys; print(json.load(sys.stdin)["route"])' 2>/dev/null) \
      || die "the proxy did not say which route this machine takes"
    if [ "$route" = central ]; then
      row=$(hub_pass "$provider") || exit 1
      rec_set "$sid" hub_id "${row%%	*}"
      cred="${row#*	}"
    else
      if [ -z "$account" ] && [ "$provider" = codex ] && [ -n "$chome" ]; then
        account=$(codex_label "$chome") || account=''
      fi
      [ -n "$account" ] || exit 4
      # --wrap: the session's wrapper — while it lives the proxy keeps this
      # credential good past its stamp (issue #1975: no mid-session expiry)
      cred=$(bash "$PROXY" mint --account "$account" --sid "$sid" --wrap "${FLEET_SESSION_WRAP:-$PPID}" 2>/dev/null) && [ -n "$cred" ] \
        || die "the proxy would not mint a session credential for $account"
      rec_set "$sid" account "$account"
    fi
    rec_set "$sid" route "$route"
    rec_set "$sid" provider "$provider"
    rec_set "$sid" wrap "${FLEET_SESSION_WRAP:-$PPID}"
    printf '%s\t%s\t%s\n' "$route" "$port" "$cred"
    ;;
  revoke)
    sid_ok "$sid" || die "revoke: --sid NAME" 2
    [ -e "$STATE/sessions/$sid" ] || [ -d "$STATE/codex-homes/$sid" ] || exit 0
    if [ -n "$(rec_get "$sid" account)" ]; then
      bash "$PROXY" revoke --sid "$sid" >/dev/null 2>&1 \
        || { mkdir -p "$STATE" && printf '%s\n' "$sid" >> "$STATE/revoked"; }   # down: the list it reads at start
    fi
    hid=$(rec_get "$sid" hub_id); [ -n "$hid" ] && hub_drop "$hid"
    [ -d "$STATE/codex-homes/$sid" ] && : > "$STATE/codex-homes/$sid/.revoked"
    rm -f "$STATE/sessions/$sid"
    ;;
  rebind)
    sid_ok "$sid" && [ -n "$account" ] || die "rebind: --sid NAME --account LABEL" 2
    case "$(rec_get "$sid" route)" in
      direct|relay) ;;
      central) die "rebind: $sid routes central — the cluster picks its account" ;;
      *) die "rebind: no live session $sid" ;;
    esac
    bash "$PROXY" rebind --sid "$sid" --account "$account" >/dev/null || exit 1
    rec_set "$sid" account "$account"
    ;;
  codex-home)
    sid_ok "$sid" && [ -d "$real" ] || die "codex-home: --sid NAME --real DIR" 2
    real=$(cd "$real" && pwd -P)
    d="$STATE/codex-homes/$sid"
    mkdir -p "$d" && chmod 700 "$STATE" "$STATE/codex-homes" 2>/dev/null
    # what Codex writes at the top of its home must land in the REAL one
    mkdir -p "$real/sessions" "$real/archived_sessions" "$real/log" 2>/dev/null
    [ -e "$real/history.jsonl" ] || : > "$real/history.jsonl" 2>/dev/null
    for e in "$real"/* "$real"/.[!.]*; do
      [ -e "$e" ] || [ -L "$e" ] || continue
      n="${e##*/}"
      case "$n" in auth.json|tmp|.fleet-real-home|.revoked) continue ;; esac   # tmp: the session's own (its daemon's socket)
      [ -e "$d/$n" ] || [ -L "$d/$n" ] || ln -s "$e" "$d/$n"
    done
    printf '%s\n' "$real" > "$d/.fleet-real-home"
    # a week-dead session's dir goes (links only: rm never follows them)
    find "$STATE/codex-homes" -mindepth 2 -maxdepth 2 -name .revoked -mtime +7 2>/dev/null \
      | while IFS= read -r f; do rm -rf "${f%/.revoked}"; done
    printf '%s\n' "$d"
    ;;
  -h|--help|'')
    sed -n '2,/^set -uo pipefail/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'
    [ -n "$cmd" ]; exit $?
    ;;
  *) die "unknown command $cmd (see --help)" 2 ;;
esac
