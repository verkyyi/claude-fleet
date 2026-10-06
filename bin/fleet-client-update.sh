#!/bin/bash
# fleet-client-update.sh — the client keeps up with its hub by itself
# (claude-fleet#1722, EPIC #1718 C4).
#
#   fleet-client-update.sh start    what `fleet` runs before it opens the client
#   fleet-client-update.sh stage    fetch the hub's client into <home>.next (background)
#   fleet-client-update.sh doctor [--root <home>]   the doctor's `client` row:
#                                   `PASS|WARN|INFO<TAB><text>` on stdout
#
# An installed client (the one line, `curl <hub>/install | sh`) lives in one
# directory, ~/.local/share/claude-fleet — the install HOME — and the installer
# records which client it is in <home>/.client-version (version = the hub's
# client digest, compat, the hub commit). A home without that file — a checkout,
# a --no-hub install, an install that predates this — is never touched: `start`
# is a no-op there, byte for byte the old start.
#
# `start`, at most once per FLEET_CLIENT_CHECK_SECS (3600; the stamp is in
# ~/.cache/claude-fleet/client/), asks the hub two things, each with a short
# timeout — a hub out of reach never holds the start up:
#
#   GET /version  client_version / client_compat / min_client_compat:
#     same version          → nothing
#     behind, compat ok     → `stage` in the background into <home>.next; the
#                             NEXT start switches to it (one rename) and the
#                             client's bar says 已更新到 <commit> for an hour
#     compat below the min  → stage + switch NOW, before opening: 已更新到 …;
#                             a failure says why in one line and opens as is
#   GET /v1/fleet/client-settings  the team's client defaults → written to
#     ~/.config/claude-fleet/hub-defaults.conf, which every reader sources
#     FIRST (fleet-shell.sh, fleet-lib.sh): hub-defaults < fleet.conf < … — so a
#     key this computer set always wins, and a line here only fills a gap. Each
#     line is `[ -n "${KEY+x}" ] || KEY='value'`: an exported value wins too.
#     Keys and values are re-checked here (the hub's whitelist is the rule);
#     anything secret-shaped or unquotable is dropped. Never written by hand.
#
# A switch keeps the old home as <home>.prev — `mv` it back to roll back.
# FLEET_CLIENT_AUTO_UPDATE=0 (fleet.conf, or a team default) turns the version
# half off; the settings half still runs.
#
# Exit (start): 0 open as is · 3 the files were switched — run `fleet` again.
# Env: FLEET_CLIENT_ROOT (the home; default this script's ../) ·
# FLEET_CLIENT_CHECK_SECS · FLEET_CLIENT_TIMEOUT (seconds per request, 3) ·
# FLEET_CLIENT_STATE (the stamp / log / note dir).
set -uo pipefail

# The client protocol level this client speaks — fleetclient.Compat in the hub
# (TestClientCompatPromise reads this line). Used when .client-version has none.
FLEET_CLIENT_COMPAT=1

BIN="$(cd "$(dirname "$0")" && pwd -P)"
ROOT="${FLEET_CLIENT_ROOT:-$(cd "$BIN/.." && pwd -P)}"
CONF_DIR="${FLEET_CONF_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/claude-fleet}"
STATE="${FLEET_CLIENT_STATE:-${XDG_CACHE_HOME:-$HOME/.cache}/claude-fleet/client}"
TMO="${FLEET_CLIENT_TIMEOUT:-3}"
case "$TMO" in ''|*[!0-9]*) TMO=3 ;; esac

note() { printf 'fleet: %s\n' "$*" >&2; }

# mark_get <file> <key> — one `key=value` line of a .client-version
mark_get() { sed -n "s/^$2=//p" "$1" 2>/dev/null | head -n 1; }

# load_conf — the client's settings, in the shell's order (fleet-shell.sh):
# the team's defaults, then shell.conf, then fleet.conf's [common] + [client]
load_conf() {
  local _fsv
  # shellcheck source=/dev/null
  [ -f "$CONF_DIR/hub-defaults.conf" ] && . "$CONF_DIR/hub-defaults.conf"
  # shellcheck source=/dev/null
  [ -f "$CONF_DIR/shell.conf" ] && . "$CONF_DIR/shell.conf"
  if [ -f "$CONF_DIR/fleet.conf" ]; then
    _fsv=${FLEET_SHELL-}; FLEET_SHELL=1
    # shellcheck source=/dev/null
    . "$CONF_DIR/fleet.conf"
    FLEET_SHELL=$_fsv
  fi
  return 0
}

# hub_url — the address `fleet connect` would use: FLEET_HUB_URL /
# CCQUOTA_HUB_URL, else hub.json's old "url"; empty = no hub
hub_url() {
  local u="${FLEET_HUB_URL:-${CCQUOTA_HUB_URL:-}}"
  if [ -z "$u" ] && [ -f "$CONF_DIR/hub.json" ]; then
    u=$(python3 -c 'import json, sys
try:
    print(str(json.load(open(sys.argv[1])).get("url") or "").strip())
except Exception:
    pass' "$CONF_DIR/hub.json" 2>/dev/null)
  fi
  printf '%s' "${u%/}"
}

# ver_fields <json-file> — `client_version<TAB>client_compat<TAB>min_client_compat<TAB>commit`
ver_fields() {
  python3 -c 'import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(1)
def s(k):
    v = d.get(k)
    return "" if v is None else str(v)
print("\t".join([s("client_version"), s("client_compat"), s("min_client_compat"), s("commit")]))' "$1" 2>/dev/null
}

# write_defaults <json-file> — the team's defaults → hub-defaults.conf (atomic).
# Re-checks every key and value; a dropped one is named on stderr.
write_defaults() {
  mkdir -p "$CONF_DIR" 2>/dev/null || return 1
  python3 - "$1" "$CONF_DIR/hub-defaults.conf" "$HUB" <<'PY'
import json, os, re, sys
src, dst, hub = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    d = json.load(open(src))
    settings = d.get("settings") or {}
    if not isinstance(settings, dict):
        raise ValueError
except Exception:
    sys.exit(1)
key_ok = re.compile(r"^FLEET_[A-Z0-9_]{1,64}$")
deny = re.compile(r"(TOKEN|SECRET|PASSWORD|_KEY$|^FLEET_HUB_URL$|^FLEET_ROLE$|^FLEET_CONF_DIR$|^FLEET_SHELL$)")
val_ok = re.compile(r"^[A-Za-z0-9 ._:=,@/+%-]{0,200}$")
secret = re.compile(r"(?:^|[^A-Za-z0-9])(?:sk-|ghp_|gho_|ghs_|ghu_|github_pat_|xox[abprs]-|glpat-)|AKIA[0-9A-Z]{16}|[A-Za-z0-9+/_=-]{32,}")
lines = []
for k in sorted(settings):
    v = settings[k]
    if not isinstance(v, str) or not key_ok.match(k) or deny.search(k) or not val_ok.match(v) or secret.search(v):
        sys.stderr.write("fleet: 入口下发的 %s 不合规，没写\n" % k)
        continue
    lines.append("[ -n \"${%s+x}\" ] || %s='%s'\n" % (k, k, v))
body = ("# hub-defaults.conf — the team's client defaults from %s (claude-fleet#1722).\n"
        "# Written by fleet-client-update.sh on a start's check; never edit it. Read\n"
        "# FIRST, so a key this computer sets (fleet.conf, the environment) wins.\n" % hub) + "".join(lines)
try:
    if open(dst).read() == body:
        sys.exit(0)
except OSError:
    pass
tmp = dst + ".tmp"
with open(tmp, "w") as f:
    f.write(body)
os.chmod(tmp, 0o644)
os.replace(tmp, dst)
PY
}

# stage — the hub's client into $ROOT.next, the way a person would get it: the
# hub's own /install, aimed at the staging home (no PATH line, no tmux step, no
# run). Done = $ROOT.next/.staged. A lock keeps two starts from staging twice.
stage() {
  local next="$ROOT.next" lock="$ROOT.next.lock" inst rc
  [ -n "$HUB" ] || { note "没有入口地址"; return 1; }
  if ! mkdir "$lock" 2>/dev/null; then
    # a lock older than 15 minutes is a crashed stage's
    if [ -n "$(find "$lock" -maxdepth 0 -mmin +15 2>/dev/null)" ]; then
      rm -rf "$lock"; mkdir "$lock" 2>/dev/null || return 1
    else
      return 0
    fi
  fi
  inst="$lock/install.sh"
  rm -rf "$next"
  if ! curl -fsSL --max-time 30 "$HUB/install" -o "$inst" 2>"$lock/err"; then
    note "取不到 $HUB/install（$(tr -d '\n' <"$lock/err" | cut -c1-80)）"; rm -rf "$lock"; return 1
  fi
  [ "$(head -c 2 "$inst")" = '#!' ] || { note "$HUB/install 返回的不是安装脚本"; rm -rf "$lock"; return 1; }
  FLEET_HUB_URL="$HUB" FLEET_INSTALL_HOME="$next" FLEET_INSTALL_BIN="$next/bin" \
    FLEET_INSTALL_NO_RUN=1 FLEET_INSTALL_NO_DEPS=1 FLEET_INSTALL_RC=/dev/null \
    FLEET_CONF_DIR="$CONF_DIR" sh "$inst" >"$lock/out" 2>&1
  rc=$?
  if [ "$rc" -ne 0 ] || [ ! -f "$next/bin/fleet" ] || ! sh -n "$next/bin/fleet" 2>/dev/null; then
    note "安装脚本失败（exit ${rc}）：$(grep -v '^ *$' "$lock/out" | tail -n 1 | cut -c1-100)"
    rm -rf "$next" "$lock"; return 1
  fi
  : > "$next/.staged"
  rm -rf "$lock"
  return 0
}

# switch — $ROOT.next becomes $ROOT, the old one $ROOT.prev; any failure puts
# the old one back. Prints the new commit (or version).
switch() {
  local next="$ROOT.next" prev="$ROOT.prev" c
  [ -f "$next/.staged" ] && [ -f "$next/bin/fleet" ] || return 1
  rm -rf "$prev"
  mv "$ROOT" "$prev" || return 1
  if ! mv "$next" "$ROOT"; then
    mv "$prev" "$ROOT"; return 1
  fi
  rm -f "$ROOT/.staged"
  c=$(mark_get "$ROOT/.client-version" commit)
  [ -n "$c" ] || c=$(mark_get "$ROOT/.client-version" version)
  mkdir -p "$STATE" 2>/dev/null && printf '已更新到 %s\n' "${c:-新版}" > "$STATE/note"
  printf '%s' "${c:-新版}"
}

cmd_start() {
  local mark="$ROOT/.client-version" lv lc hv hc hmin hcommit secs f now new
  [ -f "$mark" ] || return 0                          # not an installed client
  load_conf
  HUB=$(hub_url)
  [ -n "$HUB" ] || return 0                           # no hub: nothing to follow
  mkdir -p "$STATE" 2>/dev/null || return 0
  # 1. a client staged by an earlier start: switch to it now
  if [ "${FLEET_CLIENT_AUTO_UPDATE:-1}" != 0 ] && [ -f "$ROOT.next/.staged" ]; then
    if new=$(switch); then
      note "已更新到 ${new}（上次启动时在后台取好，这次生效）"
      return 3
    fi
    note "切换到新版客户端失败，照常打开（旧版在 ${ROOT}）"
  fi
  # 2. at most once per FLEET_CLIENT_CHECK_SECS
  secs="${FLEET_CLIENT_CHECK_SECS:-3600}"
  case "$secs" in ''|*[!0-9]*) secs=3600 ;; esac
  now=$(date +%s)
  if [ -f "$STATE/checked" ] && [ $(( now - $(cat "$STATE/checked" 2>/dev/null || echo 0) )) -lt "$secs" ]; then
    return 0
  fi
  printf '%s\n' "$now" > "$STATE/checked"
  # 3. the team's defaults (a hub that does not serve them: the file stays)
  f="$STATE/client-settings.json"
  if curl -fsS --max-time "$TMO" "$HUB/v1/fleet/client-settings" -o "$f" 2>/dev/null; then
    write_defaults "$f" || :
  fi
  [ "${FLEET_CLIENT_AUTO_UPDATE:-1}" = 0 ] && return 0
  # 4. the version
  f="$STATE/version.json"
  curl -fsS --max-time "$TMO" "$HUB/version" -o "$f" 2>/dev/null || return 0   # out of reach: open as is
  IFS=$'\t' read -r hv hc hmin hcommit <<EOF
$(ver_fields "$f")
EOF
  [ -n "${hv:-}" ] || return 0                        # a hub that does not say
  lv=$(mark_get "$mark" version)
  [ "$lv" = "$hv" ] && { rm -rf "$ROOT.next"; return 0; }
  lc=$(mark_get "$mark" compat); case "$lc" in ''|*[!0-9]*) lc=$FLEET_CLIENT_COMPAT ;; esac
  case "${hmin:-}" in ''|*[!0-9]*) hmin=0 ;; esac
  if [ "$lc" -lt "$hmin" ]; then
    note "这个客户端（协议 ${lc}）入口已不再支持（最低 ${hmin}），先更新…"
    if stage && new=$(switch); then
      note "已更新到 $new"
      return 3
    fi
    note "更新失败（见上一行），照常打开 — 可再跑一次安装行：curl -fsSL $HUB/install | sh"
    return 0
  fi
  note "入口有新版客户端（${hcommit:-$hv}），后台取，下次启动生效"
  ( nohup bash "$0" stage </dev/null >"$STATE/stage.log" 2>&1 & )
  return 0
}

cmd_doctor() {
  local mark lv lc commit hub hv hmin hc tv maj min cert lvl=PASS parts='' f
  while [ $# -gt 0 ]; do
    case "$1" in --root) ROOT="$2"; shift 2 ;; *) shift ;; esac
  done
  mark="$ROOT/.client-version"
  if [ ! -f "$mark" ]; then
    printf 'INFO\t这台电脑没有安装行装的客户端（%s）\n' "$ROOT"
    return 0
  fi
  load_conf
  lv=$(mark_get "$mark" version); lc=$(mark_get "$mark" compat); commit=$(mark_get "$mark" commit)
  parts="版本 ${lv:-?}${commit:+ ($commit)}"
  HUB=$(hub_url)
  if [ -z "$HUB" ]; then
    parts="$parts · 入口 没有"
  else
    f=$(mktemp "${TMPDIR:-/tmp}/fleet-client-doctor.XXXXXX")
    if curl -fsS --max-time "$TMO" "$HUB/version" -o "$f" 2>/dev/null; then
      IFS=$'\t' read -r hv hc hmin _ <<EOF
$(ver_fields "$f")
EOF
      case "${lc:-}" in ''|*[!0-9]*) lc=$FLEET_CLIENT_COMPAT ;; esac
      case "${hmin:-}" in ''|*[!0-9]*) hmin=0 ;; esac
      if [ -z "${hv:-}" ]; then
        parts="$parts · 入口 ${HUB}（不报客户端版本）"
      elif [ "$hv" = "$lv" ]; then
        parts="$parts · 入口 $HUB 同版"
      elif [ "$lc" -lt "$hmin" ]; then
        parts="$parts · 入口 $HUB 要求更新（${hv}）"; lvl=WARN
      else
        parts="$parts · 入口 $HUB 有新版 ${hv}（下次启动更新）"; [ "$lvl" = PASS ] && lvl=INFO
      fi
    else
      parts="$parts · 入口 $HUB 不可达"; lvl=WARN
    fi
    rm -f "$f"
  fi
  if command -v tmux >/dev/null 2>&1; then
    tv=$(tmux -V 2>/dev/null); tv=${tv#tmux }; maj=${tv%%.*}; min=${tv#*.}; min=${min%%[!0-9]*}
    case $maj in ''|*[!0-9]*) maj=0 ;; esac
    case $min in ''|*[!0-9]*) min=0 ;; esac
    if [ "$maj" -lt 3 ] || { [ "$maj" -eq 3 ] && [ "$min" -lt 2 ]; }; then
      parts="$parts · tmux ${tv}（要 ≥ 3.2）"; lvl=WARN
    else
      parts="$parts · tmux $tv"
    fi
  else
    parts="$parts · tmux 没有"; lvl=WARN
  fi
  cert=''
  [ -f "$ROOT/bin/fleet-login.py" ] && cert=$(python3 "$ROOT/bin/fleet-login.py" check 2>/dev/null | head -n 1)
  case "$cert" in
    valid\ *) cert=${cert#valid }; case "$cert" in ''|*[!0-9]*) cert=0 ;; esac
              parts="$parts · 证书 还有 $(( cert / 3600 ))h" ;;
    expired*) parts="$parts · 证书 过期（下次 fleet 自动续）" ;;
    *)        parts="$parts · 证书 没有（fleet login）" ;;
  esac
  printf '%s\t%s\n' "$lvl" "$parts"
}

case "${1:-}" in
  start)  shift; HUB=''; cmd_start "$@"; exit $? ;;
  stage)  shift; load_conf; HUB=$(hub_url); stage; exit $? ;;
  doctor) shift; HUB=''; cmd_doctor "$@"; exit 0 ;;
  *) sed -n '4,8p' "$0" | sed 's/^# //' >&2; exit 2 ;;
esac
