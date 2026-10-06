#!/bin/bash
# fleet-client-update.sh — the client keeps up with its hub by itself
# (claude-fleet#1722, EPIC #1718 C4).
#
#   fleet-client-update.sh start    what `fleet` runs before it opens the client
#   fleet-client-update.sh stage    fetch the hub's client into a version dir (background)
#   fleet-client-update.sh tick <sess>   the running client's keeper, every
#                                   FLEET_CLIENT_LEASE_EVERY: check (hourly), stage,
#                                   and apply a staged client once you are idle
#   fleet-client-update.sh apply <sess>  switch the RUNNING client to the staged one now
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
# VERSIONS (issue #1781, EPIC #1776 C5): every client the hub hands over is
# staged whole into <home>.versions/<version>/ and <home> becomes a SYMLINK to
# the one in use, so a switch is one rename(2) of that link — new and old swap
# as a whole, never file by file. A home that is still a plain directory is
# adopted on its first switch (moved to <home>.versions/<its version>/).
# <home>.versions/.next names the staged one, .prev the one before the last
# switch (kept, with the current one; older ones are pruned). Roll back by hand:
# `ln -sfn <home>.versions/<prev> <home>`.
#
# `start`, at most once per FLEET_CLIENT_CHECK_SECS (3600; the stamp is in
# ~/.cache/claude-fleet/client/), asks the hub two things, each with a short
# timeout — a hub out of reach never holds the start up:
#
#   GET /version  client_version / client_compat / min_client_compat:
#     same version          → nothing
#     behind, compat ok     → `stage` in the background; the running client
#                             takes it in place once you are idle (`tick`), or
#                             the NEXT start switches to it and the client's bar
#                             says 已更新到 <commit> for an hour
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
# IN USE (issue #1781): the client's keeper runs `tick` while its server lives.
# Once a staged client is there and nobody has pressed a key for
# FLEET_CLIENT_IDLE_SECS (30 — every client of the shell's server, tmux's
# #{client_activity}), `apply`:
#   1. migrations — each bin/client-migrations/*.sh the NEW client has and the
#      old one does not, in name order, run as `bash <m> <from> <to>` with
#      FLEET_SHELL_SESSION set. Idempotent; they touch only the client's own two
#      tmux servers. Exit 0 = done · 3 = this change needs a restart (nothing is
#      switched: the bar says 新版已就绪 · 下次打开生效, and the next `fleet` that
#      finds the server with no client attached closes it and opens the new one)
#      · anything else = failed (rolled back, below). A migration ships by
#      adding its path to the fleetclient manifest.
#   2. the link is switched, then the NEW client's `fleet-shell.sh reload`
#      rewrites the mirror and both confs and sources them into the RUNNING
#      servers (fleet-shell + its stage — same pids), redraws the list where its
#      VIEW_VERSION moved, and respawns a proxy pane only when
#      fleet-remote-view.sh itself changed (the right pane's session is kept).
#   3. any failure: the link back, the confs as they were sourced again, and
#      one line on why. The tmux server itself is never replaced.
# What happened is ~/.cache/claude-fleet/shell/update.state —
# {phase: applying|done|later|failed, from, to, commit, why, at} — which the
# client's ⌂ badge (fleet-client-badge.sh) shows: ✓ 已更新到 … / the failure for
# FLEET_CLIENT_UPDATE_SHOW seconds (4), 新版已就绪 · 下次打开生效 until then.
#
# FLEET_CLIENT_AUTO_UPDATE=0 (fleet.conf, or a team default) turns the version
# half off; the settings half still runs.
#
# Exit (start): 0 open as is · 3 the files were switched — run `fleet` again.
# Exit (tick / apply): 0 nothing to do · 4 applied · 3 later · 1 failed.
# Env: FLEET_CLIENT_ROOT (the home; default this script's ../, or the home a
# <home>.versions/<v>/ belongs to) · FLEET_CLIENT_CHECK_SECS ·
# FLEET_CLIENT_TIMEOUT (seconds per request, 3) · FLEET_CLIENT_STATE (the stamp
# / log / note dir) · FLEET_CLIENT_IDLE_SECS · FLEET_CLIENT_UPDATE_STATE (the
# state file).
set -uo pipefail

# The client protocol level this client speaks — fleetclient.Compat in the hub
# (TestClientCompatPromise reads this line). Used when .client-version has none.
FLEET_CLIENT_COMPAT=1

SELF="$0"; [ -L "$SELF" ] && SELF=$(readlink "$SELF")   # run through the shell's mirror: the real file
BIN="$(cd "$(dirname "$SELF")" && pwd -P)"
ROOT="${FLEET_CLIENT_ROOT:-$(cd "$BIN/.." && pwd -P)}"
# run from inside a version dir (bin/fleet resolves its own path physically):
# the home is the one <home>.versions/ belongs to
case "$ROOT" in *.versions/*) [ -n "${FLEET_CLIENT_ROOT:-}" ] || ROOT=${ROOT%.versions/*} ;; esac
VERS="$ROOT.versions"
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
deny = re.compile(r"(TOKEN|SECRET|PASSWORD|_KEY$|^FLEET_HUB_URL$|^FLEET_ROLE$|^FLEET_HOST$|^FLEET_CONF_DIR$|^FLEET_SHELL$)")
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

# vkey <version> — a version as a directory name
vkey() { printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_' | cut -c1-80; }
# cur_key — the version dir <home> points at; empty while <home> is a plain dir
cur_key() { [ -L "$ROOT" ] && basename "$(readlink "$ROOT")"; }
# next_key — the staged client's dir name, when one is complete; empty otherwise
next_key() {
  local k=''
  { read -r k < "$VERS/.next"; } 2>/dev/null
  [ -n "$k" ] && [ -f "$VERS/$k/.staged" ] && [ -f "$VERS/$k/bin/fleet" ] && printf '%s' "$k"
}
# shell_sess — the client's tmux session (= its server's socket label)
shell_sess() {
  local s="${FLEET_SHELL_SESSION:-fleet-shell}"
  case "$s" in ''|*[!A-Za-z0-9._-]*) s=fleet-shell ;; esac
  printf '%s' "$s"
}
# shell_cache — fleet-shell.sh's CACHE
shell_cache() { printf '%s' "${FLEET_SHELL_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/claude-fleet/shell}"; }
# ustate — where update.state lives
ustate() { printf '%s' "${FLEET_CLIENT_UPDATE_STATE:-$(shell_cache)/update.state}"; }
# set_state <phase> <from> <to> [why] — update.state, atomically
set_state() {
  local f c
  f=$(ustate)
  mkdir -p "$(dirname "$f")" 2>/dev/null || return 0
  c=$(mark_get "$VERS/$3/.client-version" commit)
  python3 - "$f" "$1" "$2" "$3" "$c" "${4:-}" <<'PY' 2>/dev/null || :
import json, os, sys, time
f, phase, frm, to, commit, why = sys.argv[1:7]
d = {"phase": phase, "from": frm, "to": to, "commit": commit, "why": why, "at": int(time.time())}
with open(f + ".tmp", "w") as o:
    json.dump(d, o, ensure_ascii=False)
    o.write("\n")
os.replace(f + ".tmp", f)
PY
}
# state_get <field> — one field of update.state
state_get() {
  python3 -c 'import json, sys
try:
    print(json.load(open(sys.argv[1])).get(sys.argv[2]) or "")
except Exception:
    pass' "$(ustate)" "$1" 2>/dev/null
}
ulog() { mkdir -p "$STATE" 2>/dev/null && printf '%s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "$*" >> "$STATE/update.log"; }

# point <key> — <home> → <home>.versions/<key>, in ONE rename(2) of a link made
# beside it (a plain-dir home is adopted first). rc 1: nothing changed.
point() {
  local k="$1" own
  [ -d "$VERS/$k" ] || return 1
  if [ -e "$ROOT" ] && [ ! -L "$ROOT" ]; then
    own=$(vkey "$(mark_get "$ROOT/.client-version" version)")
    [ -n "$own" ] || own=adopted
    { [ "$own" != "$k" ] && [ ! -e "$VERS/$own" ]; } || own="$own-$(date +%s)"
    mkdir -p "$VERS" && mv "$ROOT" "$VERS/$own" || return 1
    if ! ln -s "$VERS/$own" "$ROOT"; then mv "$VERS/$own" "$ROOT"; return 1; fi
    ADOPTED=$own
  fi
  python3 -c 'import os, sys
t, link = sys.argv[1], sys.argv[2]
tmp = link + ".switch.%d" % os.getpid()
try:
    os.unlink(tmp)
except OSError:
    pass
os.symlink(t, tmp)
os.replace(tmp, link)' "$VERS/$k" "$ROOT"
}
# prune — every version dir but the current one, .prev's and .next's
prune() {
  local cur prev='' next='' d n
  cur=$(cur_key)
  { read -r next < "$VERS/.next"; } 2>/dev/null
  { read -r prev < "$VERS/.prev"; } 2>/dev/null
  for d in "$VERS"/*/; do
    [ -d "$d" ] || continue
    n=$(basename "$d")
    case "$n" in "$cur"|"$prev"|"$next") continue ;; esac
    rm -rf "$d"
  done
}

# stage — the hub's client into <home>.versions/<version>, the way a person
# would get it: the hub's own /install, aimed at a staging dir (no PATH line, no
# tmux step, no run), then renamed into place. Done = <dir>/.staged and .next
# naming it. A lock keeps two stagers from staging twice.
stage() {
  local lock="$VERS/.lock" tmp inst rc k
  [ -n "$HUB" ] || { note "没有入口地址"; return 1; }
  mkdir -p "$VERS" 2>/dev/null || { note "写不了 $VERS"; return 1; }
  if ! mkdir "$lock" 2>/dev/null; then
    # a lock older than 15 minutes is a crashed stage's
    if [ -n "$(find "$lock" -maxdepth 0 -mmin +15 2>/dev/null)" ]; then
      rm -rf "$lock"; mkdir "$lock" 2>/dev/null || return 1
    else
      return 0
    fi
  fi
  inst="$lock/install.sh"; tmp="$VERS/.staging"
  rm -rf "$tmp" "$ROOT.next"
  if ! curl -fsSL --max-time 30 "$HUB/install" -o "$inst" 2>"$lock/err"; then
    note "取不到 $HUB/install（$(tr -d '\n' <"$lock/err" | cut -c1-80)）"; rm -rf "$lock"; return 1
  fi
  [ "$(head -c 2 "$inst")" = '#!' ] || { note "$HUB/install 返回的不是安装脚本"; rm -rf "$lock"; return 1; }
  FLEET_HUB_URL="$HUB" FLEET_INSTALL_HOME="$tmp" FLEET_INSTALL_BIN="$tmp/bin" \
    FLEET_INSTALL_NO_RUN=1 FLEET_INSTALL_NO_DEPS=1 FLEET_INSTALL_RC=/dev/null \
    FLEET_CONF_DIR="$CONF_DIR" sh "$inst" >"$lock/out" 2>&1
  rc=$?
  if [ "$rc" -ne 0 ] || [ ! -f "$tmp/bin/fleet" ] || ! sh -n "$tmp/bin/fleet" 2>/dev/null; then
    note "安装脚本失败（exit ${rc}）：$(grep -v '^ *$' "$lock/out" | tail -n 1 | cut -c1-100)"
    rm -rf "$tmp" "$lock"; return 1
  fi
  k=$(vkey "$(mark_get "$tmp/.client-version" version)")
  [ -n "$k" ] || k="staged-$(date +%s)"
  : > "$tmp/.staged"
  if [ "$k" != "$(cur_key)" ]; then
    rm -rf "${VERS:?}/$k"
    mv "$tmp" "$VERS/$k" || { rm -rf "$tmp" "$lock"; return 1; }
    printf '%s\n' "$k" > "$VERS/.next"
  else
    rm -rf "$tmp"                 # the one in use already
  fi
  rm -rf "$lock"
  return 0
}
# legacy_next — a client an older update script staged at <home>.next becomes
# a staged version
legacy_next() {
  local k
  [ -f "$ROOT.next/.staged" ] && [ -f "$ROOT.next/bin/fleet" ] || return 0
  k=$(vkey "$(mark_get "$ROOT.next/.client-version" version)")
  [ -n "$k" ] || k="staged-$(date +%s)"
  mkdir -p "$VERS" && rm -rf "${VERS:?}/$k" && mv "$ROOT.next" "$VERS/$k" && printf '%s\n' "$k" > "$VERS/.next"
}

# switch — the staged client becomes <home> while none of it runs (the start).
# The old one stays as .prev. Prints the new commit (or version).
switch() {
  local k c old
  legacy_next
  k=$(next_key)
  [ -n "$k" ] || return 1
  old=$(cur_key); ADOPTED=''
  point "$k" || return 1
  [ -n "$old" ] || old=$ADOPTED
  [ -n "$old" ] && printf '%s\n' "$old" > "$VERS/.prev"
  rm -f "$VERS/.next"
  prune
  rm -f "$(ustate)"
  c=$(mark_get "$ROOT/.client-version" commit)
  [ -n "$c" ] || c=$(mark_get "$ROOT/.client-version" version)
  mkdir -p "$STATE" 2>/dev/null && printf '已更新到 %s\n' "${c:-新版}" > "$STATE/note"
  printf '%s' "${c:-新版}"
}

# shell_live <sess> — the client's server is running
shell_live() { tmux -L "$1" has-session -t "=$1" 2>/dev/null; }
# idle_secs <sess> — seconds since any client of it last pressed a key (no
# client attached: a large number)
idle_secs() {
  local last now
  last=$(tmux -L "$1" list-clients -F '#{client_activity}' 2>/dev/null | sort -n | tail -n 1)
  now=$(date +%s)
  case "$last" in ''|*[!0-9]*) echo 999999 ;; *) echo $(( now - last )) ;; esac
}

# check — the hourly ask: the team's defaults, then the version. Exit 0
# nothing to do · 10 behind, compatible · 11 below the hub's minimum (HV,
# HCOMMIT, HMIN, LC set for the caller).
check() {
  local mark="$ROOT/.client-version" lv hv='' hmin='' secs f now
  HV=''; HCOMMIT=''; HMIN=0; LC=$FLEET_CLIENT_COMPAT
  secs="${FLEET_CLIENT_CHECK_SECS:-3600}"
  case "$secs" in ''|*[!0-9]*) secs=3600 ;; esac
  now=$(date +%s)
  if [ -f "$STATE/checked" ] && [ $(( now - $(cat "$STATE/checked" 2>/dev/null || echo 0) )) -lt "$secs" ]; then
    return 0
  fi
  printf '%s\n' "$now" > "$STATE/checked"
  # the team's defaults (a hub that does not serve them: the file stays)
  f="$STATE/client-settings.json"
  if curl -fsS --max-time "$TMO" "$HUB/v1/fleet/client-settings" -o "$f" 2>/dev/null; then
    write_defaults "$f" || :
  fi
  [ "${FLEET_CLIENT_AUTO_UPDATE:-1}" = 0 ] && return 0
  # the version
  f="$STATE/version.json"
  curl -fsS --max-time "$TMO" "$HUB/version" -o "$f" 2>/dev/null || return 0   # out of reach: open as is
  IFS=$'\t' read -r hv _ hmin HCOMMIT <<VER
$(ver_fields "$f")
VER
  HV=$hv
  [ -n "$hv" ] || return 0                           # a hub that does not say
  lv=$(mark_get "$mark" version)
  if [ "$lv" = "$hv" ]; then
    rm -rf "$ROOT.next"
    f=$(next_key); [ -n "$f" ] && { rm -rf "${VERS:?}/$f"; rm -f "$VERS/.next"; }
    return 0
  fi
  LC=$(mark_get "$mark" compat); case "$LC" in ''|*[!0-9]*) LC=$FLEET_CLIENT_COMPAT ;; esac
  case "$hmin" in ''|*[!0-9]*) hmin=0 ;; esac
  HMIN=$hmin
  [ "$LC" -lt "$HMIN" ] && return 11
  return 10
}
# stage_bg — `stage` in the background, unless that version is staged already
stage_bg() {
  local k
  k=$(next_key)
  [ -n "$k" ] && [ "$k" = "$(vkey "${HV:-}")" ] && return 0
  ( nohup bash "$SELF" stage </dev/null >"$STATE/stage.log" 2>&1 & )
}

cmd_start() {
  local mark="$ROOT/.client-version" new sess rc
  [ -f "$mark" ] || return 0                          # not an installed client
  load_conf
  HUB=$(hub_url)
  [ -n "$HUB" ] || return 0                           # no hub: nothing to follow
  mkdir -p "$STATE" 2>/dev/null || return 0
  sess=$(shell_sess)
  # 1. a client staged earlier: switch to it now — unless the client is
  #    running, whose keeper takes it in place (issue #1781). One a migration
  #    said needs a restart (later): a server nobody is attached to is closed,
  #    and this start opens the new client.
  legacy_next
  if [ "${FLEET_CLIENT_AUTO_UPDATE:-1}" != 0 ] && [ -n "$(next_key)" ]; then
    if shell_live "$sess" && [ "$(state_get phase)" = later ] \
       && [ -z "$(tmux -L "$sess" list-clients -F x 2>/dev/null)" ]; then
      tmux -L "$sess" kill-server 2>/dev/null
      tmux -L "$sess-stage" kill-server 2>/dev/null
    fi
    if ! shell_live "$sess"; then
      if new=$(switch); then
        note "已更新到 ${new}（上次启动时在后台取好，这次生效）"
        return 3
      fi
      note "切换到新版客户端失败，照常打开（旧版在 ${ROOT}）"
    fi
  fi
  # 2. at most once per FLEET_CLIENT_CHECK_SECS
  check; rc=$?
  case "$rc" in
    11)
      note "这个客户端（协议 ${LC}）入口已不再支持（最低 ${HMIN}），先更新…"
      if shell_live "$sess"; then
        stage_bg
        note "客户端正在运行：新版取好后，等你空闲时原地换上"
        return 0
      fi
      if stage && new=$(switch); then
        note "已更新到 $new"
        return 3
      fi
      note "更新失败（见上一行），照常打开 — 可再跑一次安装行：curl -fsSL $HUB/install | sh"
      return 0 ;;
    10)
      if shell_live "$sess"; then
        note "入口有新版客户端（${HCOMMIT:-$HV}），后台取，等你空闲时原地换上"
      else
        note "入口有新版客户端（${HCOMMIT:-$HV}），后台取，下次启动生效"
      fi
      stage_bg
      return 0 ;;
  esac
  return 0
}

# resource <sess> <saved-dir> — the confs as they were, back in place and read
# again by both servers; the list redrawn (its VIEW_VERSION may have moved back)
resource() {
  local s="$1" d="$2" c
  c=$(shell_cache)
  [ -f "$d/tmux.conf" ] && cp -p "$d/tmux.conf" "$c/tmux.conf"
  [ -f "$d/tmux-stage.conf" ] && cp -p "$d/tmux-stage.conf" "$c/tmux-stage.conf"
  [ -f "$c/tmux.conf" ] && tmux -L "$s" source-file "$c/tmux.conf" >/dev/null 2>&1
  [ -f "$c/tmux-stage.conf" ] && tmux -L "$s-stage" has-session 2>/dev/null \
    && tmux -L "$s-stage" source-file "$c/tmux-stage.conf" >/dev/null 2>&1
  tmux -L "$s" run-shell -b -t "=$s:" "bash '$c/bin/fleet-sidebar.sh' sync '#{session_id}' >/dev/null 2>&1 || :" 2>/dev/null
  return 0
}

# apply <sess> — the staged client into the RUNNING one (IN USE above).
# Exit 0 nothing staged · 4 applied · 3 later · 1 failed (rolled back).
apply() {
  local s="$1" to from fromv tov old_root old saved m b rc why c
  legacy_next
  to=$(next_key)
  [ -n "$to" ] || return 0
  old=$(cur_key)
  if [ "$to" = "$old" ]; then rm -f "$VERS/.next"; return 0; fi
  old_root=$(cd "$ROOT" && pwd -P) || return 1
  fromv=$(mark_get "$ROOT/.client-version" version); from=$(vkey "$fromv")
  tov=$(mark_get "$VERS/$to/.client-version" version)
  set_state applying "$from" "$to"
  ulog "apply $from → $to ($s)"
  # the confs as the servers read them now: what a rollback sources again
  c=$(shell_cache); saved="$STATE/conf.saved"
  rm -rf "$saved"; mkdir -p "$saved"
  for m in "$c/tmux.conf" "$c/tmux-stage.conf"; do [ -f "$m" ] && cp -p "$m" "$saved/"; done
  # 1. the migrations the new client brings (the old one had none of them)
  for m in "$VERS/$to/bin/client-migrations/"*.sh; do
    [ -f "$m" ] || continue
    b=${m##*/}
    [ -f "$old_root/bin/client-migrations/$b" ] && continue
    FLEET_SHELL_SESSION="$s" bash "$m" "$fromv" "$tov" >>"$STATE/update.log" 2>&1
    rc=$?
    case "$rc" in
      0) ulog "migration $b: done" ;;
      3) ulog "migration $b: needs a restart"
         set_state later "$from" "$to" "$b"
         return 3 ;;
      *) why="迁移 $b 失败（exit $rc），已退回旧版"
         ulog "$why"
         resource "$s" "$saved"
         set_state failed "$from" "$to" "$why"
         return 1 ;;
    esac
  done
  # 2. the link, then the NEW client reloads itself into the running servers
  ADOPTED=''
  if ! point "$to"; then
    set_state failed "$from" "$to" "切不过去（$ROOT）"
    return 1
  fi
  # a plain-dir home was just adopted: the old client now lives in its version dir
  [ -n "$ADOPTED" ] && old_root=$(cd "$VERS/$ADOPTED" && pwd -P)
  [ -n "$old" ] || old=$ADOPTED
  if ! FLEET_SHELL_SESSION="$s" bash "$ROOT/bin/fleet-shell.sh" reload "$s" --from "$old_root" >>"$STATE/update.log" 2>&1; then
    why="新版载入失败，已退回旧版"
    ulog "$why"
    point "$old" || ulog "rollback: the link could not be put back ($old)"
    resource "$s" "$saved"
    set_state failed "$from" "$to" "$why"
    return 1
  fi
  printf '%s\n' "$old" > "$VERS/.prev"
  rm -f "$VERS/.next"
  prune
  set_state "done" "$from" "$to"
  ulog "applied $to"
  return 4
}

# tick <sess> — the keeper's beat: the hourly check (stage what is newer, in
# the background), then apply a staged client once nobody is typing
cmd_tick() {
  local s="$1" k idle rc
  [ -f "$ROOT/.client-version" ] || return 0
  load_conf
  HUB=$(hub_url)
  [ -n "$HUB" ] || return 0
  mkdir -p "$STATE" 2>/dev/null || return 0
  check 2>/dev/null; rc=$?
  [ "${FLEET_CLIENT_AUTO_UPDATE:-1}" != 0 ] || return 0
  case "$rc" in 10|11) stage_bg ;; esac
  legacy_next
  k=$(next_key)
  [ -n "$k" ] || return 0
  # a migration said restart, or this version failed once: wait — never retry
  # it every tick; a newer staged version is tried afresh
  case "$(state_get phase)" in
    later)  [ "$(state_get to)" = "$k" ] && return 3 ;;
    failed) [ "$(state_get to)" = "$k" ] && return 1 ;;
  esac
  idle=$(idle_secs "$s")
  [ "$idle" -ge "${FLEET_CLIENT_IDLE_SECS:-30}" ] || return 0
  apply "$s"
}

cmd_doctor() {
  local mark lv lc commit hv hmin tv maj min cert lvl=PASS parts='' f
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
      IFS=$'\t' read -r hv _ hmin _ <<EOF
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
        parts="$parts · 入口 $HUB 有新版 ${hv}（取好后空闲时原地换上）"; [ "$lvl" = PASS ] && lvl=INFO
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
  tick)   shift; HUB=''; cmd_tick "${1:-fleet-shell}"; exit $? ;;
  apply)  shift; load_conf; HUB=$(hub_url); mkdir -p "$STATE" 2>/dev/null; apply "${1:-$(shell_sess)}"; exit $? ;;
  doctor) shift; HUB=''; cmd_doctor "$@"; exit 0 ;;
  *) sed -n '4,12p' "$SELF" | sed 's/^# //' >&2; exit 2 ;;
esac
