#!/usr/bin/env bash
# fleet-node-probe.sh — can this computer run sessions? (issue #1720, EPIC #1718 C2)
#
#   fleet-node-probe.sh [--quiet] [--json] [--max-age <secs>]
#
# Measures three things and writes the verdict to $FLEET_CONF_DIR/node-probe.json
# (default ~/.config/claude-fleet), which the node agent carries to the hub in
# its hello and every heartbeat:
#
#   loc        the egress region — Cloudflare's /cdn-cgi/trace `loc=`, crossed
#              with ipinfo.io/country; either one in a region Claude / OpenAI
#              do not serve counts;
#   anthropic  api.anthropic.com and api.openai.com, one request each with NO
#   openai     credential: an auth error = reachable; a 403 = the provider
#              refuses this region (unsupported_region); no answer = unreachable;
#   laptop     a battery (pmset -g batt / /sys/class/power_supply/BAT*) — and the
#              sleep setting. A laptop is a NOTE, never a refusal (EPIC #1718
#              decision 3: a lid that closes stops its sessions).
#
#   {"loc","anthropic","openai","laptop","sleep_min","ts","verdict","reason"}
#   verdict: ok | unsupported_region | unreachable
#
# What the verdict does is the hub's (tokenledger/internal/api/fleet_compute.go):
# unsupported_region closes a login that runs sessions and raises an alert;
# ok opens one only when the team policy fleet.compute_auto is on — otherwise
# it is this one line:  可以打开：fleet node compute on
#
# Run at `fleet node join` (so at install) and daily by the node agent; `fleet
# node compute on` runs it first and refuses on anything but ok.
#
#   --quiet          write the file, print nothing
#   --json           print the JSON instead of the sentence
#   --max-age <s>    a node-probe.json younger than this is reused, not re-measured
#
# Env (test seams): FLEET_PROBE_CURL (curl) · FLEET_PROBE_PMSET (pmset) ·
#   FLEET_PROBE_OS (uname -s) · FLEET_PROBE_BATTERY_DIR (/sys/class/power_supply) ·
#   FLEET_PROBE_UNSUPPORTED (the region list, ISO-3166 alpha-2, space separated).
# Exit: 0 ok · 1 not suitable (unsupported_region / unreachable) · 2 usage
set -uo pipefail

CONF="${FLEET_CONF_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/claude-fleet}"
OUT="$CONF/node-probe.json"
ENVF="$CONF/node.env"
CURL="${FLEET_PROBE_CURL:-curl}"
PMSET="${FLEET_PROBE_PMSET:-pmset}"
OS="${FLEET_PROBE_OS:-$(uname -s 2>/dev/null)}"
BATDIR="${FLEET_PROBE_BATTERY_DIR:-/sys/class/power_supply}"
# Regions neither provider serves (Anthropic's and OpenAI's published lists
# both leave these out). The providers' own 403 is the other half of the rule,
# so a region missing here is still caught by its answer.
UNSUPPORTED="${FLEET_PROBE_UNSUPPORTED:-CN HK MO RU BY IR KP SY CU}"

QUIET=0 JSON=0 MAXAGE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --quiet) QUIET=1 ;;
    --json) JSON=1 ;;
    --max-age) MAXAGE="${2:-}"; shift ;;
    -h|--help) sed -n '2,/^set -uo pipefail/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "fleet-node-probe: unknown option $1 (see --help)" >&2; exit 2 ;;
  esac
  shift
done
case "$MAXAGE" in ''|*[!0-9]*) [ -z "$MAXAGE" ] || { echo "fleet-node-probe: --max-age: seconds" >&2; exit 2; } ;; esac

jget() { sed -n "s/.*\"$1\":\"\\{0,1\\}\\([^\",}]*\\)\"\\{0,1\\}.*/\\1/p" "$2" | head -n 1; }

mtime() { stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null; }

# ── measure (or reuse) ──────────────────────────────────────────────────────
reuse=0
if [ -n "$MAXAGE" ] && [ -s "$OUT" ]; then
  m=$(mtime "$OUT")
  [ -n "$m" ] && [ $(( $(date +%s) - m )) -lt "$MAXAGE" ] && reuse=1
fi

if [ "$reuse" = 0 ]; then
  up() { tr '[:lower:]' '[:upper:]' | tr -cd 'A-Z'; }
  loc1=$("$CURL" -fsS --max-time 8 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null | sed -n 's/^loc=//p' | head -n 1 | up)
  loc2=$("$CURL" -fsS --max-time 8 https://ipinfo.io/country 2>/dev/null | head -n 1 | up)
  case "$loc1" in ??) ;; *) loc1="" ;; esac
  case "$loc2" in ??) ;; *) loc2="" ;; esac
  loc="${loc1:-$loc2}"
  bad_loc=""
  for l in $loc1 $loc2; do
    case " $UNSUPPORTED " in *" $l "*) bad_loc="$l" ;; esac
  done
  [ -z "$bad_loc" ] || loc="$bad_loc"

  WORK=$(mktemp -d "${TMPDIR:-/tmp}/fleet-node-probe.XXXXXX") || exit 1
  trap 'rm -rf "$WORK"' EXIT
  # api <name> <args…> — one request with no credential → reachable |
  # unsupported_region | unreachable, and its HTTP code in <name>.code.
  api() {
    local name="$1" code; shift
    code=$("$CURL" -sS -o "$WORK/$name.body" -w '%{http_code}' --max-time 10 "$@" 2>/dev/null) || code=000
    printf '%s' "$code" > "$WORK/$name.code"
    case "$code" in
      000|'') echo unreachable ;;
      403) echo unsupported_region ;;
      *) echo reachable ;;
    esac
  }
  anthropic=$(api anthropic -X POST https://api.anthropic.com/v1/messages \
    -H 'content-type: application/json' -H 'anthropic-version: 2023-06-01' -d '{}')
  openai=$(api openai https://api.openai.com/v1/models)

  laptop=false sleep_min=""
  case "$OS" in
    Darwin)
      if "$PMSET" -g batt 2>/dev/null | grep -q 'InternalBattery'; then laptop=true; fi
      sleep_min=$("$PMSET" -g 2>/dev/null | awk '$1 == "sleep" { print $2; exit }')
      ;;
    *)
      for b in "$BATDIR"/BAT*; do [ -e "$b" ] && laptop=true && break; done
      ;;
  esac
  case "$sleep_min" in ''|*[!0-9]*) sleep_min="" ;; esac

  reason="egress ${loc:-unknown} (cloudflare ${loc1:-?} · ipinfo ${loc2:-?}); anthropic $anthropic ($(cat "$WORK/anthropic.code")); openai $openai ($(cat "$WORK/openai.code"))"
  if [ -n "$bad_loc" ] || [ "$anthropic" = unsupported_region ] || [ "$openai" = unsupported_region ]; then
    verdict=unsupported_region
  elif [ "$anthropic" = unreachable ] || [ "$openai" = unreachable ]; then
    verdict=unreachable
  else
    verdict=ok
  fi
  reason=$(printf '%s' "$reason" | tr -d '"\\')
  mkdir -p "$CONF" || exit 1
  {
    printf '{"loc":"%s","anthropic":"%s","openai":"%s","laptop":%s,' "$loc" "$anthropic" "$openai" "$laptop"
    [ -z "$sleep_min" ] || printf '"sleep_min":%s,' "$sleep_min"
    printf '"ts":"%s","verdict":"%s","reason":"%s"}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$verdict" "$reason"
  } > "$OUT.tmp" && mv "$OUT.tmp" "$OUT" || { echo "fleet-node-probe: cannot write $OUT" >&2; exit 1; }
fi

verdict=$(jget verdict "$OUT")
[ "$verdict" = ok ] && rc=0 || rc=1
[ "$QUIET" = 1 ] && exit "$rc"
if [ "$JSON" = 1 ]; then cat "$OUT"; exit "$rc"; fi

# ── say it ──────────────────────────────────────────────────────────────────
loc=$(jget loc "$OUT") laptop=$(jget laptop "$OUT") sleep_min=$(jget sleep_min "$OUT")
anthropic=$(jget anthropic "$OUT") openai=$(jget openai "$OUT")
word() { case "$1" in reachable) echo 能直连 ;; unsupported_region) echo 拒绝本地区 ;; *) echo 连不上 ;; esac; }
note=""
if [ "$laptop" = true ]; then
  note="；笔记本：合盖或睡眠时会话会停下"
  [ "${sleep_min:-0}" -gt 0 ] 2>/dev/null && note="${note}（睡眠设置 ${sleep_min} 分钟）"
fi
case "$verdict" in
  ok) echo "本机判断：合适 — 出口 ${loc:-未知}，Anthropic / OpenAI 都能直连${note}" ;;
  unsupported_region) echo "本机判断：不合适 — 出口 ${loc:-未知}：Anthropic $(word "$anthropic")，OpenAI $(word "$openai")；不在本机跑会话，账号用本机自己的${note}" ;;
  *) echo "本机判断：暂不合适 — 出口 ${loc:-未知}：Anthropic $(word "$anthropic")，OpenAI $(word "$openai")（网络恢复后再测：fleet-node-probe.sh）${note}" ;;
esac
# The one hint (EPIC #1718 decision 2): suitable, a node, compute off.
if [ "$verdict" = ok ] && [ -f "$ENVF" ] && grep -qx 'CCQUOTA_FLEET_COMPUTE=0' "$ENVF"; then
  echo "可以打开：fleet node compute on"
fi
exit "$rc"
