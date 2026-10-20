#!/bin/sh
# fleet-install.sh — THE install line, the same on every computer (claude-fleet
# #1470, #1486, #1804):
#
#     curl -fsSL https://<入口>/install | sh
#
# The hub serves this file at /install with the placeholder in PRE_HUB= below
# replaced by its own address; GitHub's `stable` serves it as it is (raw
# …/stable/bin/fleet-install.sh), with no address — the only difference.
#
# It asks NOTHING (claude-fleet#2260, EPIC #2259 C1): pasted, it is done in
# seconds, and the next thing on the screen is `fleet`. What it used to ask, it
# now decides:
#
#   承载 (this computer also runs sessions) — off, unless asked for: `--host`
#       (FLEET_INSTALL_HOST=1), or this computer already 承载s. A newcomer never
#       sees the word; `fleet host on` turns it on later.
#   入口 — 接 whenever an address is known: the one the hub filled in below
#       (the line was copied from it), else the one this computer already has;
#       no address (GitHub's own copy of this script) → 不接 (单机). FLEET_HUB_URL
#       names one ahead; FLEET_INSTALL_HUB=0 / --no-hub keeps it 单机.
#
# Running it again changes nothing that was chosen (only what is new gets
# installed; nothing is torn down — 承载 goes off with `fleet host off`).
# FLEET_INSTALL_HOST=0|1 / FLEET_INSTALL_HUB=0|1 still answer ahead for
# automation.
#
# An invitation (EPIC #2259 C2) rides in the line: the hub's /i/<code> serves this
# script with the code in place of __FLEET_INVITE__ (FLEET_INVITE ahead), and it
# is kept, 0600, at $FLEET_CONF_DIR/invite for the first `fleet login` to hand
# in — never printed, never on a command line.
#
# A computer the fleet was never on (no ~/.config/claude-fleet) gets
# FLEET_CLIENT_LAYOUT=solo in fleet.conf's [client] (EPIC #2259 共同约定 1): the
# newcomer's one-session view. One that had it keeps its layout, byte for byte.
#
# ONE directory, ~/.claude/fleet (FLEET_INSTALL_HOME / FLEET_INSTALL_ROOT):
#
#   1. the part everyone has — the client's manifest (fleetclient/manifest in
#      the repo: `fleet` and what it dispatches to; a `served` line is not
#      installed — the client fetches it on first use, issue #4826),
#      with a hub as ONE download — <from>/bundle.tar.gz, the manifest and every
#      file it lists in one SHA-256-checked tar (#2260; ~140 requests took close
#      to two minutes) — and file by file when that fails, each SHA-256-checked, from the hub's /install/<path> (接) or the
#      repo paths on GitHub's stable (不接, FLEET_INSTALL_SRC), in the repo's own
#      layout, no git. A copy the manifest no longer lists goes when it is still
#      as the fleet put it — `installed.list` (path TAB sha256, #4827) records
#      what it put; a file the person added or edited stays, and is carried
#      into the next whole version; `.client-version` records which client it is
#      (#1722, with a hub). Run again on a client it installed (one with a
#      .client-version), the new client goes BESIDE the one in use, whole, into
#      <home>.versions/<version>/ and <home> — a link — is switched in one
#      rename(2), the version before kept as .prev; with an old client (#3008)
#      still running it is only staged, and the next `fleet` switches it
#      (#1900). Already a full install here (a git checkout, or one
#      with bin/fleet-up.sh) → not one file is downloaded or removed: that
#      install follows stable by itself. A ~/.local/bin/fleet of two lines runs
#      the real one. Two trees on one computer (the client's
#      ~/.local/share/claude-fleet beside ~/.claude/fleet, before #1804) → the
#      old one becomes a symlink to ~/.claude/fleet (a thin shell, for one
#      version; a running client keeps working — every path it uses now
#      resolves into the one directory), and what it held goes once no process
#      runs from it;
#   2. 接: the address into fleet.conf (FLEET_HUB_URL — the machine's one config
#      file, #1623); hub.json keeps its token. 不接 writes no address;
#   3. ~/.local/bin on PATH: ONE line in the shell's rc file, once;
#   4. tmux ≥ 3.2 (#1629), the one thing the shell needs that a stock system
#      lacks — first tmux's own static build (#2260: the bundle's vendor/tmux,
#      else the archive conf/vendor-tmux.lock pins, SHA-256 checked) into
#      ~/.local/share/claude-fleet-vendor/bin, no Homebrew needed; a platform
#      with none → Homebrew / apt-get / dnf / yum / apk, never a password
#      prompt; `--no-deps` (FLEET_INSTALL_NO_DEPS=1) skips it;
#   5. 承载 — `fleet host on --yes` (fleet-host.sh): fleet-host-install.sh turns
#      ~/.claude/fleet into a checkout of stable in place (git, tmux, a new
#      login's setup: hooks, commands, daemons, a first fleet), then, with a
#      hub, the join + compute on. 只看只派 + 接 — the computer joins the hub
#      as a node that only coordinates (#1719: one scan; no terminal for the QR
#      → the line to run later; already a node of this hub → left alone).
#      --no-node (FLEET_INSTALL_NO_NODE=1) skips the hub registration;
#   6. the Agent configuration (#1725) — hooks · skills · commands · MCP · the
#      mod — is 承载's (issue #4826, EPIC #4823 decision 1): a full install's
#      own setup / sync applies it; the client package carries none, and what
#      an earlier client wired into this login is taken out
#      (FLEET_INSTALL_NO_AGENTS=1 leaves the login's config alone);
#   7. one line, 能力 基础 · 承载 已开/未开 · 入口 接/不接, and runs `fleet`.
#
# Only what a stock macOS or Linux has: sh, curl, python3 (macOS's own 3.9 is
# enough), and with a hub ssh + ssh-keygen. Windows: inside WSL.
#
# Env: FLEET_INSTALL_BIN (the `fleet` on PATH; ~/.local/bin) · FLEET_INSTALL_NO_RUN=1
# installs without running `fleet` · FLEET_INSTALL_RC (the rc file) ·
# FLEET_INSTALL_SUDO (the sudo prefix; default `sudo -n`, empty = none) ·
# FLEET_INSTALL_BUNDLE=0 skips the one-download bundle (file by file) ·
# FLEET_INSTALL_VENDOR (where the static tmux goes) · FLEET_INSTALL_STATIC_TMUX=0
# skips the static tmux (straight to Homebrew / apt).
# Exit: 0 installed (and `fleet` is running, which replaces this process) ·
# 2 an unsupported system, a missing prerequisite or a bad answer · 1 a download
# failed.
#
# WHICH VERSION (claude-fleet#1805): the part everyone has is stable's — the one
# version every computer follows. 接: the hub's /version names stable's commit
# (client_version) and where its files are through the hub (client_url, which
# reaches where GitHub does not) — only the hub: a file it cannot hand out fails
# the install, never GitHub behind it (issue #2773); a hub that names no
# client_url hands out its image's files, as before. The hub's release key is
# pinned here too ($FLEET_CONF_DIR/release.pub, from /v1/fleet/release/key, once
# — a later key is `fleet host trust-release-key`'s): install-sync checks every
# release it takes against it. 不接: GitHub's API names stable's commit (FLEET_STABLE_API), the files
# come from the raw host AT that commit (FLEET_STABLE_RAW) — one install is one
# version, never a mix of two. Either way .client-version records it, and
# `fleet` follows stable from there (fleet-client-update.sh). FLEET_INSTALL_SRC
# pins a source as it is (FLEET_INSTALL_VERSION names its version; none = no
# .client-version, the selftests' seam).
# fleet-install: stable-aware — the hub serves this installer from stable only
# while it carries this line (tokenledger/hub/api/fleet_stable.go).
set -eu
T0=$(date +%s)

DEPS=1
[ "${FLEET_INSTALL_NO_DEPS:-}" = 1 ] && DEPS=0
HOST_ANS="${FLEET_INSTALL_HOST:-}"
HUB_ANS="${FLEET_INSTALL_HUB:-}"
[ "${FLEET_INSTALL_NO_HUB:-}" = 1 ] && HUB_ANS=0
usage() {
  cat <<'USAGE'
fleet-install.sh — 装 fleet（curl -fsSL <入口>/install | sh；参数跟在 sh -s -- 后面）

参数：
  --host       这台也承载：自己跑会话（之后也能 fleet host on / off）
  --no-hub     本机模式：不连入口，即使知道入口地址
  --no-deps    不顺手装依赖（tmux 等）
  --no-node    接入口时不把这台登记为节点
  -h, --help   打印这段说明

环境变量（自动化预填答案，和参数等价）：
  FLEET_INSTALL_HOST=0|1   承载：1 同 --host；0 不开
  FLEET_INSTALL_HUB=0|1    接入口：0 同 --no-hub；1 要接（须知道地址）
  FLEET_HUB_URL=https://…  入口地址（入口给的那条命令已填好）
  FLEET_INSTALL_NO_DEPS=1  同 --no-deps
  FLEET_INSTALL_NO_RUN=1   装完不打开客户端
  FLEET_INSTALL_HOME=…     装到哪（默认 ~/.claude/fleet）
  FLEET_INSTALL_BIN=…      fleet 命令放哪（默认 ~/.local/bin）

装完在终端里接着打开 fleet；没有终端（管道、CI）时跳过这一步，以 0 退出。
USAGE
}
for a in "$@"; do
  case "$a" in
    -h|--help) usage; exit 0 ;;
    --no-deps) DEPS=0 ;;
    --host) HOST_ANS=1 ;;      # 承载 too: the part that runs sessions
    --no-hub) HUB_ANS=0 ;;     # 单机: no hub even when an address is known
    --no-node) FLEET_INSTALL_NO_NODE=1 ;;
    *) printf 'fleet-install: 不认识的参数 %s（自动化用 FLEET_INSTALL_HOST=0|1、FLEET_INSTALL_HUB=0|1 预填答案）\n' "$a" >&2; exit 2 ;;
  esac
done
case "$HOST_ANS" in ''|0|1) ;; *) echo "fleet-install: FLEET_INSTALL_HOST 只能是 0 或 1" >&2; exit 2 ;; esac
case "$HUB_ANS" in ''|0|1) ;; *) echo "fleet-install: FLEET_INSTALL_HUB 只能是 0 或 1" >&2; exit 2 ;; esac

PRE_HUB="${FLEET_HUB_URL:-__FLEET_HUB_URL__}"
case "$PRE_HUB" in http://*|https://*) PRE_HUB="${PRE_HUB%/}" ;; *) PRE_HUB='' ;; esac
# the invitation the hub's /i/<code> filled in (EPIC #2259 C2), or none
INVITE="${FLEET_INVITE:-__FLEET_INVITE__}"
case "$INVITE" in __FLEET_INV*|''|*[!A-Za-z0-9_-]*) INVITE='' ;; esac
SRC="${FLEET_INSTALL_SRC:-https://raw.githubusercontent.com/verkyyi/claude-fleet/stable}"  # dist-ok: 不接 only (no hub: the developer's road)
SRC="${SRC%/}"
RAW="${FLEET_STABLE_RAW:-https://raw.githubusercontent.com/verkyyi/claude-fleet}"  # dist-ok: 不接 only
RAW="${RAW%/}"
API="${FLEET_STABLE_API:-https://api.github.com/repos/verkyyi/claude-fleet/commits/stable}"  # dist-ok: 不接 only
MANIFEST_PATH=tokenledger/hub/api/fleetclient/manifest

say() { printf '%s\n' "$*" >&2; }
sq() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }

case "$(uname -s 2>/dev/null || echo unknown)" in
  Darwin|Linux) ;;
  MINGW*|MSYS*|CYGWIN*|Windows*)
    say "fleet-install: Windows 请在 WSL 里运行这条命令（wsl --install，然后在 WSL 终端里再执行一次）"; exit 2 ;;
  *) say "fleet-install: 不支持的系统 $(uname -s)（支持 macOS 与 Linux；Windows 用 WSL）"; exit 2 ;;
esac

BIN="${FLEET_INSTALL_BIN:-$HOME/.local/bin}"
ROOT="${FLEET_INSTALL_HOME:-${FLEET_INSTALL_ROOT:-$HOME/.claude/fleet}}"
ROOT="${ROOT%/}"
OLD="${XDG_DATA_HOME:-$HOME/.local/share}/claude-fleet"   # the client's own tree before #1804
CONF_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/claude-fleet"
CONF="${FLEET_CONF_DIR:-$CONF_DIR}"

# full — the directory is already the whole fleet (a checkout following stable,
# or a copy with the part that runs sessions): the base is never laid over it
full() { [ -d "$ROOT/.git" ] || [ -f "$ROOT/bin/fleet-up.sh" ]; }
# fconf <args> — fleet-conf.sh from the one directory, else the old client tree
fconf() {
  for _d in "$ROOT" "$OLD"; do
    [ -f "$_d/bin/fleet-conf.sh" ] && { FLEET_CONF_DIR="$CONF" bash "$_d/bin/fleet-conf.sh" "$@"; return; }
  done
  return 1
}
conf_get() {   # <KEY> — fleet.conf's value, '' when none
  sed -n "s/^[[:space:]]*\(export[[:space:]]\{1,\}\)\{0,1\}$1=//p" "$CONF/fleet.conf" 2>/dev/null \
    | tail -n 1 | sed 's/[[:space:]]#.*$//' | tr -d "\"' "
}
# retire <dir> — an old copy goes once nothing runs from it (a process whose
# command line names it); still in use → kept, and said, for the next run.
retire() {
  [ -e "$1" ] || [ -L "$1" ] || return 0
  if ps -A -ww -o command= 2>/dev/null | grep -F -- "$1/" | grep -vq grep; then
    say "  $1 还有程序在用，先留着（下次运行时删）"
    return 0
  fi
  rm -rf "$1"
}

# ── the two questions ──────────────────────────────────────────────────────
# What this computer answered before: 承载 (fleet-conf.sh host) and an address.
CUR_HOST="$(fconf host 2>/dev/null || true)"
[ "$CUR_HOST" = 1 ] || CUR_HOST=0
CUR_HUB="$(conf_get FLEET_HUB_URL)"
[ -n "$CUR_HUB" ] || CUR_HUB="$(python3 -c 'import json,sys
try: print(json.load(open(sys.argv[1])).get("url") or "")
except Exception: print("")' "$CONF/hub.json" 2>/dev/null || true)"
CUR_HUB="${CUR_HUB%/}"
HUBURL="${PRE_HUB:-$CUR_HUB}"

TTY=0
( : </dev/tty ) 2>/dev/null && TTY=1
# Nothing is asked (#2260): what was given, else what this computer had, else
# the defaults — the part everyone has; 接 whenever an address is known.
HINT_HOST=0
if [ -z "$HOST_ANS" ]; then HOST_ANS=$CUR_HOST; [ "$CUR_HOST" = 0 ] && HINT_HOST=1; fi
if [ -z "$HUB_ANS" ]; then if [ -n "$HUBURL" ]; then HUB_ANS=1; else HUB_ANS=0; fi; fi
if [ "$HUB_ANS" = 1 ] && [ -z "$HUBURL" ]; then
  say "fleet-install: 要接入口，但不知道地址 — 用入口给的那条命令，或 FLEET_HUB_URL=https://… 预填"; exit 2
fi

if [ "$HUB_ANS" = 1 ]; then FROM="$HUBURL/install"; else FROM="$SRC"; fi
TOOLS="curl python3"
[ "$HUB_ANS" = 1 ] && TOOLS="$TOOLS ssh ssh-keygen"
for tool in $TOOLS; do
  command -v "$tool" >/dev/null 2>&1 || {
    case "$tool" in
      python3) say "fleet-install: 需要 python3 —— macOS 执行 xcode-select --install；Linux 用包管理器安装 python3" ;;
      *) say "fleet-install: 需要 $tool" ;;
    esac
    exit 2
  }
done

# a computer the fleet was never on: no config directory, or an empty one
FRESH=0
[ -n "$(ls -A "$CONF" 2>/dev/null)" ] || FRESH=1
# the newcomer's path (EPIC #2259, issue #2347): a fresh computer, sent by a hub, that did not
# ask for 承载 — the closing lines say what to type, not the fleet's words
# (入口 · 承载 · 只协调 · 扫码); a computer the fleet was on reads them as before
NEWBIE=0
[ "$FRESH" = 1 ] && [ "$HOST_ANS" = 0 ] && [ "$HUB_ANS" = 1 ] && NEWBIE=1
mkdir -p "$BIN" "$CONF"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/fleet-install.XXXXXX")"
LOCK='' STG=''
trap 'rm -rf "$tmp"; [ -z "$STG" ] || rm -rf "$STG"; [ -z "$LOCK" ] || rm -rf "$LOCK"' EXIT INT TERM HUP

# fetch <path> [<rel>] → $tmp/<path>, from $FROM/<rel> (default <path>) — one
# source: with a hub, never GitHub behind it (issue #2773; the per-file GitHub
# fallback of #1805 / #1901 is gone). Each file's SHA-256 rides in a header from
# the hub; a download that does not match it (a proxy's error page, a cut
# connection) is refused rather than installed.
fetch() {
  src_url="$FROM/${2:-$1}"
  mkdir -p "$tmp/$(dirname "$1")"
  curl -fsSL -D "$tmp/$1.hdr" "$src_url" -o "$tmp/$1" || { say "fleet-install: 下载 $src_url 失败"; exit 1; }
  want="$(tr -d '\r' <"$tmp/$1.hdr" | awk 'tolower($1)=="x-ccquota-sha256:"{print $2}')"
  if [ -n "$want" ]; then
    got="$(python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$tmp/$1")"
    [ "$got" = "$want" ] || { say "fleet-install: $1 下载不完整（校验不符）"; exit 1; }
  fi
}

# sha256 <file> — its SHA-256 hex
sha256() { python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$1"; }
# platform — this computer as conf/vendor-tmux.lock names it, or ''
platform() {
  case "$(uname -s)" in Darwin) _po=macos ;; Linux) _po=linux ;; *) return 0 ;; esac
  case "$(uname -m)" in arm64|aarch64) _pa=arm64 ;; x86_64|amd64) _pa=x86_64 ;; *) return 0 ;; esac
  printf '%s-%s' "$_po" "$_pa"
}
# download <url> <out> <what> [<curl opts>…] — curl in the background, and a
# line every 15 s on what it still waits for (EPIC #2259 共同约定 5: no silent
# wait); the timeout is the caller's --max-time. Exit = curl's.
download() {
  _du=$1 _do=$2 _dw=$3; shift 3
  curl -fsL --connect-timeout 10 "$@" "$_du" -o "$_do" &
  _dp=$! _d0=$(date +%s) _dn=15
  while kill -0 "$_dp" 2>/dev/null; do
    sleep 0.2 2>/dev/null || sleep 1
    _dt=$(( $(date +%s) - _d0 ))
    if [ "$_dt" -ge "$_dn" ]; then
      _dn=$((_dn + 15))
      _dk=$(( $(wc -c <"$_do" 2>/dev/null || echo 0) / 1024 ))
      say "  还在下载${_dw}… 已 ${_dt} 秒，收到 ${_dk} KB（$(printf '%s' "$_du" | sed 's/?.*//')）"
    fi
  done
  wait "$_dp"
}
# fetch_bundle — the whole client in one download (#2260): <from>/bundle.tar.gz
# → $tmp/b/, SHA-256 checked against the hub's header; a vendor/tmux in it is
# the static tmux for this platform. 1 + BWHY when anything is off.
fetch_bundle() {
  BWHY=''
  _bu="$FROM/bundle.tar.gz?os=$(uname -s)&arch=$(uname -m)"
  download "$_bu" "$tmp/bundle.tgz" '（一个包）' --max-time 90 -D "$tmp/bundle.hdr" || { BWHY='下载失败'; return 1; }
  _bw="$(tr -d '\r' <"$tmp/bundle.hdr" | awk 'tolower($1)=="x-ccquota-sha256:"{print $2}' | tail -n 1)"
  [ -n "$_bw" ] || { BWHY='入口没给校验和'; return 1; }
  [ "$(sha256 "$tmp/bundle.tgz")" = "$_bw" ] || { BWHY='校验不符'; return 1; }
  rm -rf "$tmp/b"; mkdir -p "$tmp/b"
  tar -xzf "$tmp/bundle.tgz" -C "$tmp/b" 2>/dev/null || { BWHY='解不开'; return 1; }
  [ -f "$tmp/b/manifest" ] && [ ! -L "$tmp/b/manifest" ] || { BWHY='包里没有 manifest'; return 1; }
  return 0
}

# drop_in <dir> — what an upgrade deletes from <dir> (issue #4827): only a file
# the fleet installed there (its installed.list, fleet-versions-lib.sh) that
# still holds the listed bytes and that the manifest no longer lists. A file
# the person put in, or one they edited, is theirs and stays. No list ⇒ nothing.
drop_in() {
  command -v fleet_installed_owned >/dev/null 2>&1 && [ -f "$1/installed.list" ] || return 0
  fleet_installed_owned "$1" | while IFS= read -r rel; do
    case " $FILES" in *" $rel "*) ;; *) printf '%s\n' "$rel" ;; esac
  done
}
# mark_get <file> <key> — one `key=value` line of a .client-version
mark_get() { sed -n "s/^$2=//p" "$1" 2>/dev/null | head -n 1; }
# vkey <version> — a version as a directory name (fleet-client-update.sh's)
vkey() { printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_' | cut -c1-80; }
# client_running — the OLD client's tmux server is up (issue #3008: that client is
# gone, but one started before the update may still run from these files): they
# are staged, not switched, and the next `fleet` switches (fleet-client-update.sh
# start). The thin client runs no server: it switches at once.
client_running() {
  _s="${FLEET_SHELL_SESSION:-fleet-shell}"
  case "$_s" in ''|*[!A-Za-z0-9._-]*) _s=fleet-shell ;; esac
  command -v tmux >/dev/null 2>&1 && tmux -L "$_s" has-session -t "=$_s" 2>/dev/null
}

# install_in_place — the downloaded files over the ones in $ROOT, file by file
# (a first install; a home the line did not install, which carries no
# .client-version; an install with no version to name)
install_in_place() {
  mkdir -p "$ROOT"
  # A copy the manifest no longer lists — an earlier install's, still as the
  # fleet installed it — goes (drop_in, read before a byte moves); a file the
  # person put in or edited stays. Never in a full install.
  drop_in "$ROOT" > "$tmp/stale.list"
  for f in $FILES; do
    mkdir -p "$ROOT/$(dirname "$f")"
    mv -f "$tmp/$f" "$ROOT/$f"
  done
  while IFS= read -r rel; do
    rm -f "${ROOT}/${rel}"; say "  去掉了不再发的旧文件 ${rel}"
  done < "$tmp/stale.list"
  # what this install put here (issue #4827): the next upgrade's drop_in reads it
  # shellcheck disable=SC2086  # the manifest's paths are words
  command -v fleet_installed_write >/dev/null 2>&1 && fleet_installed_write "$ROOT" $FILES
  for d in hooks commands skills mod; do
    [ -d "$ROOT/$d" ] && find "$ROOT/$d" -depth -type d -empty -exec rmdir {} \; 2>/dev/null
  done
  # unchanged but for the time → the file is left as it was (a rerun changes nothing)
  if [ "$MARK" = 1 ] && [ "$(grep -v '^at=' "$tmp/client-version" 2>/dev/null)" != "$(grep -v '^at=' "$ROOT/.client-version" 2>/dev/null)" ]; then
    mv -f "$tmp/client-version" "$ROOT/.client-version"
  fi
  return 0
}

# install_versioned — the downloaded client into <home>.versions/<version>/,
# then <home> switched to it (or, with the client running, staged as .next)
install_versioned() {
  VERS="$ROOT.versions"
  # the client in use already is this one, file for file: nothing to do
  _same=1
  for f in $FILES; do cmp -s "$tmp/$f" "$ROOT/$f" || { _same=0; break; }; done
  [ "$_same" = 1 ] && [ -n "$(drop_in "$ROOT")" ] && _same=0
  [ "$(grep -v '^at=' "$tmp/client-version")" = "$(grep -v '^at=' "$ROOT/.client-version" 2>/dev/null)" ] || _same=0
  if [ "$_same" = 1 ]; then
    say "fleet: ${ROOT} 已是这一版，不重装"
    return 0
  fi
  # one stager at a time — the keeper's `stage` takes the same lock
  mkdir -p "${VERS}" || { say "fleet-install: 写不了 ${VERS}"; exit 1; }
  _n=0
  while ! mkdir "$VERS/.lock" 2>/dev/null; do
    if [ "$_n" -ge 120 ] || [ -n "$(find "$VERS/.lock" -maxdepth 0 -mmin +15 2>/dev/null)" ]; then
      rm -rf "$VERS/.lock"
      mkdir "$VERS/.lock" 2>/dev/null && break
      say "fleet-install: 拿不到 ${VERS}/.lock"; exit 1
    fi
    [ "${_n}" = 0 ] && say "fleet: 后台正在取新版，等它取完…"
    _n=$((_n + 1)); sleep 1
  done
  LOCK="$VERS/.lock"
  _cur=$(fleet_versions_current "$ROOT")
  _key=$(vkey "$VER"); [ -n "$_key" ] || _key="install-$(date +%s)"
  # the same version again, but not the same files (a repair): beside it too
  [ "$_key" = "$_cur" ] && _key="$_key-$(date +%s)"
  STG="$VERS/.staging-install.$$"
  rm -rf "$STG"; mkdir -p "$STG"
  for f in $FILES; do
    mkdir -p "$STG/$(dirname "$f")"
    mv -f "$tmp/$f" "$STG/$f"
  done
  mv -f "$tmp/client-version" "$STG/.client-version"
  # shellcheck disable=SC2086  # the manifest's paths are words
  fleet_installed_write "$STG" $FILES
  : > "$STG/.staged"
  rm -rf "${VERS:?}/$_key"
  mv "$STG" "$VERS/$_key"; STG=''
  if client_running; then
    printf '%s\n' "$_key" > "$VERS/.next.tmp" && mv -f "$VERS/.next.tmp" "$VERS/.next"
    say "fleet: 旧客户端还在运行 — 新版装在 ${VERS}/${_key}，下次打开 fleet 时换上（正在用的一个字节不动）"
  else
    # what the person put in the one in use goes along (issue #4827)
    fleet_versions_carry "$ROOT" "$VERS/$_key" | while IFS= read -r rel; do say "  带上了你自己的文件 ${rel}"; done
    _old=$_cur
    if [ -z "$_old" ]; then
      # a home that is still a plain directory becomes a version of its own
      _old=$(vkey "$(mark_get "$ROOT/.client-version" version)"); [ -n "$_old" ] || _old=adopted
      { [ "$_old" != "$_key" ] && [ ! -e "$VERS/$_old" ]; } || _old="$_old-$(date +%s)"
      fleet_versions_adopt "${ROOT}" "${_old}" || { say "fleet-install: ${ROOT} 挪不进 ${VERS}，旧版照旧在用；新版留在 ${VERS}/${_key}"; exit 1; }
    fi
    fleet_versions_point "${ROOT}" "${VERS}/${_key}" || { say "fleet-install: 切不到新版，旧版照旧在用；新版留在 ${VERS}/${_key}"; exit 1; }
    printf '%s\n' "$_old" > "$VERS/.prev"
    rm -f "$VERS/.next"
    fleet_versions_prune "$ROOT" "$_key" "$_old"
    say "fleet: 已整版切到 ${_key}（${VERS}/${_key}）· 上一版 ${_old} 留作 .prev — 退回：ln -sfn ${VERS}/${_old} ${ROOT}"
  fi
  rm -rf "$LOCK"; LOCK=''
  return 0
}

# ── 1 — the part everyone has, into the one directory ─────────────────────
if full; then
  say "fleet: $ROOT 已是完整安装（跟 stable），基础文件不重下"
else
  # which version, and from where (WHICH VERSION above): FROM, the manifest's
  # path under it, and what .client-version says
  VER='' COMPAT='' COMMIT='' MARK=0 MPATH="$MANIFEST_PATH" STABLE='' CURL='' HCOMMIT=''
  if [ "$HUB_ANS" = 1 ]; then
    MARK=1
    curl -fsS --max-time 10 "$HUBURL/version" -o "$tmp/version.json" 2>/dev/null || : > "$tmp/version.json"
    eval "$(python3 - "$tmp/version.json" <<'PYV'
import json, re, shlex, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    d = {}
def s(k):
    v = d.get(k)
    return "" if v is None else str(v)
st = s("stable") if re.match(r"^[0-9a-f]{40}$", s("stable")) else ""
url = s("client_url") if st and re.match(r"^https?://[A-Za-z0-9._~:/@%+-]+$", s("client_url")) else ""
# one release line - issue 4671: a Mac installs stable too
ver = s("client_version")
for k, v in (("VER", ver), ("COMPAT", s("client_compat")), ("HCOMMIT", s("commit")), ("STABLE", st), ("CURL", url)):
    print("%s=%s" % (k, shlex.quote(v)))
PYV
)"
    if [ -n "$CURL" ]; then
      FROM="${CURL%/}" COMMIT=$(printf '%.7s' "$STABLE")
    else
      FROM="$HUBURL/install" MPATH=manifest COMMIT=$HCOMMIT     # the image's client
    fi
  elif [ -n "${FLEET_INSTALL_SRC:-}" ]; then
    FROM="$SRC" VER="${FLEET_INSTALL_VERSION:-}"
    if [ -n "$VER" ]; then MARK=1 COMMIT=$(printf '%.7s' "$VER"); fi
  else
    MARK=1
    STABLE=$(curl -fsS --max-time 10 -H 'Accept: application/vnd.github.sha' "$API" 2>/dev/null | tr -d ' \r\n' | cut -c1-40) || STABLE=''
    if printf '%s' "$STABLE" | grep -Eq '^[0-9a-f]{40}$'; then
      FROM="$RAW/$STABLE" VER=$STABLE COMMIT=$(printf '%.7s' "$STABLE")
    else
      FROM="$RAW/stable"      # GitHub's API out of reach: the tag's tip; `fleet` pins it next time
      say "fleet: 问不到 stable 指向哪个提交，按 stable 当前内容装（下次启动 fleet 时对齐）"
    fi
  fi
  # With a hub, the whole client in ONE download (#2260); a bundle that fails
  # (an older hub, a cut connection) → the manifest, then every file on it,
  # as before. Nothing is installed until all are here.
  BUNDLED=0
  if [ "$HUB_ANS" = 1 ] && [ "${FLEET_INSTALL_BUNDLE:-1}" != 0 ]; then
    say "fleet: 下载中…"
    if fetch_bundle; then
      BUNDLED=1
      mv -f "$tmp/b/manifest" "$tmp/manifest"
    else
      say "fleet: 整包没下成（${BWHY}），改为逐个文件下载…"
    fi
  fi
  # the manifest first (its `installer` line is this very script, not a
  # download), then every file on it
  if [ "$BUNDLED" != 1 ]; then
    fetch manifest "$MPATH"
  fi
  # a `served` line (issue #4826) is the hub's to hand out on first use, never installed
  FILES="$(awk '!/^[[:space:]]*#/ && NF && $2 != "installer" && $2 != "served" { print $1 }' "$tmp/manifest" | tr '\n' ' ')"
  [ -n "${FILES% }" ] || { say "fleet-install: $FROM 的 manifest 里没有文件"; exit 1; }
  for f in $FILES; do
    case "$f" in
      bin/*|conf/*|hooks/*|commands/*|skills/*|mod/*) case "$f" in *..*|*/) say "fleet-install: manifest 里有不认识的路径 $f"; exit 1 ;; esac ;;
      *) say "fleet-install: manifest 里有不认识的路径 $f"; exit 1 ;;
    esac
    if [ "$BUNDLED" = 1 ]; then
      { [ -f "$tmp/b/$f" ] && [ ! -L "$tmp/b/$f" ]; } || { say "fleet-install: 包里少了 $f"; exit 1; }
      mkdir -p "$tmp/$(dirname "$f")"
      mv -f "$tmp/b/$f" "$tmp/$f"
    else
      fetch "$f"
    fi
    # a script or a sourced lib (a comment first; a proxy's HTML page starts with '<')
    case "$f" in bin/*) [ "$(head -c 1 "$tmp/$f")" = '#' ] || { say "fleet-install: $f 不是脚本（入口返回了别的东西）"; exit 1; } ;; esac
  done
  # bin/ is executable; elsewhere a script (a skill's share.sh) keeps its #!
  for f in $FILES; do
    case "$f" in bin/*) chmod 0755 "$tmp/$f" ;; *) if [ "$(head -c 2 "$tmp/$f")" = '#!' ]; then chmod 0755 "$tmp/$f"; else chmod 0644 "$tmp/$f"; fi ;; esac
  done
  # Which client this is (#1722): the hub's /version answer, so `fleet` can
  # tell on its next start whether the hub hands out a newer one. 不接 too
  # (#1805): `fleet` then follows GitHub's stable by itself.
  if [ "$MARK" = 1 ]; then
    _mhub=''; [ "$HUB_ANS" = 1 ] && _mhub=$HUBURL
    printf 'version=%s\ncompat=%s\ncommit=%s\nhub=%s\nat=%s\n' "$VER" "$COMPAT" "$COMMIT" "$_mhub" "$(date +%s)" > "$tmp/client-version"
  fi
  # the downloaded client's own switch and bookkeeping (installed.list, #4827)
  # shellcheck source=fleet-versions-lib.sh
  [ -f "$tmp/bin/fleet-versions-lib.sh" ] && . "$tmp/bin/fleet-versions-lib.sh"
  if [ "$MARK" = 1 ] && [ -f "$ROOT/.client-version" ] && [ -f "$tmp/bin/fleet-versions-lib.sh" ]; then
    # A client the line installed before (issue #1900): the new one goes BESIDE
    # it, whole, into <home>.versions/<version>/, and <home> — a link — is
    # switched in one rename(2) (fleet-versions-lib.sh, the switch the updater
    # and a 承载 machine's install-sync use). The one in use is never written:
    # a run that fails half way leaves it as it was, and the version before
    # stays as .prev. An old client that is RUNNING is not switched under itself
    # — the new one is staged (.next) and the next `fleet` switches to it
    # (fleet-client-update.sh start), as it does one it fetched.
    install_versioned
  else
    install_in_place
  fi
fi

# Two trees on one computer (before #1804): the client's own directory becomes
# a thin shell — a symlink to the one directory — for one version. A running
# client keeps working (its paths resolve into the one directory, which holds
# every file it had); the old files go once nothing runs from them.
if [ -z "${FLEET_INSTALL_HOME:-}" ] && { [ -e "$OLD" ] || [ -L "$OLD" ]; } \
   && [ "$(cd "$OLD" 2>/dev/null && pwd -P)" != "$(cd "$ROOT" && pwd -P)" ]; then
  if [ -L "$OLD" ]; then
    ln -sfn "$ROOT" "$OLD"
  else
    mv "$OLD" "$OLD.old.$$" && ln -s "$ROOT" "$OLD" && retire "$OLD.old.$$"
  fi
  say "fleet: 只留一套 — $OLD 现在指向 ${ROOT}（这层薄壳下个版本删）"
fi
[ -z "${FLEET_INSTALL_HOME:-}" ] && retire "$OLD.versions"

# The `fleet` on PATH: two lines that run the real one — a script, not a
# symlink, because `fleet` finds its siblings in the directory of ITS OWN path.
if [ "$(cd "$BIN" && pwd -P)" != "$(cd "$ROOT/bin" && pwd -P)" ]; then
  printf '#!/bin/sh\n# fleet — installed by the install line (claude-fleet#1486, #1804); the fleet is %s\nexec %s "$@"\n' \
    "$ROOT" "$(sq "$ROOT/bin/fleet")" > "$tmp/fleet"
  chmod 0755 "$tmp/fleet"
  cmp -s "$tmp/fleet" "$BIN/fleet" 2>/dev/null || mv -f "$tmp/fleet" "$BIN/fleet"
  # the #1470 installer put the two helpers flat in $BIN; `fleet` no longer
  # looks there (ours by its header; someone else's file is left alone)
  for old in fleet-login.py fleet-connect.py; do
    if [ -f "$BIN/$old" ] && [ ! -L "$BIN/$old" ] && grep -q 'claude-fleet#' "$BIN/$old" 2>/dev/null; then
      rm -f "$BIN/$old"
    fi
  done
fi

# ── the python fleet runs on (#2878) ──────────────────────────────────────
# macOS: Apple's /usr/bin/python3 verifies TLS against the system keychain; a
# python.org / Homebrew / pyenv python3 first on PATH reads none, and with no
# (or an old) certifi `fleet login` died CERTIFICATE_VERIFY_FAILED on a hub curl
# had just reached. So Apple's is recorded ($CONF/python) and linked as
# $CONF/pybin/python3, which `fleet` puts first on PATH — the launcher and every `#!/usr/bin/env python3` under it then run on it. Only when
# the developer tools are there (else /usr/bin/python3 is a stub that pops an
# install dialog). bin/fleet_tls.py covers any python anyway (its own CA union).
if [ "$(uname -s)" = Darwin ] && [ "${FLEET_INSTALL_PYTHON:-/usr/bin/python3}" != none ]; then
  _py=${FLEET_INSTALL_PYTHON:-/usr/bin/python3}
  if { [ "$_py" != /usr/bin/python3 ] || xcode-select -p >/dev/null 2>&1; } \
     && "$_py" -c 'import ssl' >/dev/null 2>&1; then
    mkdir -p "$CONF/pybin" && ln -sfn "$_py" "$CONF/pybin/python3" && printf '%s\n' "$_py" > "$CONF/python"
  fi
  unset _py
fi

# ── 2 — the hub address: the machine's ONE config file (#1623) ─────────────
if [ "$HUB_ANS" = 1 ]; then
  if fconf migrate --quiet >/dev/null 2>&1 && fconf set-hub "$HUBURL"; then
    :
  else
python3 - "$CONF/hub.json" "$HUBURL" <<'PY'
import json, os, sys
path, hub = sys.argv[1], sys.argv[2]
try:
    with open(path) as f:
        d = json.load(f)
    if not isinstance(d, dict):
        d = {}
except (OSError, ValueError):
    d = {}
d["url"] = hub
tmp = path + ".tmp"
with open(tmp, "w") as f:
    json.dump(d, f, indent=2)
    f.write("\n")
os.chmod(tmp, 0o600)
os.replace(tmp, path)
PY
  fi
elif [ -n "$CUR_HUB" ]; then
  say "入口: 这次选了不接 — fleet.conf 里原来的地址 $CUR_HUB 没删"
fi
# the hub's release key, pinned ONCE (issue #2773): every release install-sync
# takes is checked against it; a key already here is never replaced (that is
# `fleet host trust-release-key`). A hub that keeps no releases has none: nothing.
if [ "$HUB_ANS" = 1 ] && [ ! -s "$CONF/release.pub" ]; then
  if curl -fsS --max-time 10 "$HUBURL/v1/fleet/release/key" -o "$tmp/release.pub" 2>/dev/null \
     && grep -Eq '^ed25519 [A-Za-z0-9+/=_-]{8,}$' "$tmp/release.pub"; then
    head -n 1 "$tmp/release.pub" > "$CONF/release.pub.tmp" && chmod 0644 "$CONF/release.pub.tmp" \
      && mv -f "$CONF/release.pub.tmp" "$CONF/release.pub" \
      && say "入口: 记下了它的发布签名钥匙（指纹 $(awk '{print $2}' "$CONF/release.pub" | python3 -c 'import base64, hashlib, sys; print(hashlib.sha256(base64.b64decode(sys.stdin.read().strip())).hexdigest()[:16])' 2>/dev/null || echo ?)）— 之后只认它"
  fi
fi
# the invitation, for the first `fleet login` (EPIC #2259 C2): 0600, never shown
if [ -n "$INVITE" ]; then
  ( umask 077; printf '%s\n' "$INVITE" > "$CONF/invite.tmp" ) && mv -f "$CONF/invite.tmp" "$CONF/invite"
  if [ "$NEWBIE" = 1 ]; then say "邀请: 已收下，登录时一起带上"; else say "邀请: 已收下，登录时一起交给入口"; fi
fi
# the debug desk's ticket left with it (claude-fleet#4904): an older install's
rm -f "$CONF/debug-ticket" "$CONF/debug-ticket.fp"
# ── 3 — PATH, once ─────────────────────────────────────────────────────────
MARK="# fleet (claude-fleet#1470)"
rc_file() {
  if [ -n "${FLEET_INSTALL_RC:-}" ]; then echo "$FLEET_INSTALL_RC"; return; fi
  case "$(basename "${SHELL:-sh}")" in
    zsh) echo "${ZDOTDIR:-$HOME}/.zshrc" ;;
    bash) if [ "$(uname -s)" = Darwin ]; then echo "$HOME/.bash_profile"; else echo "$HOME/.bashrc"; fi ;;
    *) echo "$HOME/.profile" ;;
  esac
}
RC="$(rc_file)"
path_note=""
case ":$PATH:" in
  *":$BIN:"*) ;;
  *)
    # this terminal's shell reads the rc line only when it starts again: the
    # client says how to get `fleet` here on its way out (fleet-thin.py, #3062)
    FLEET_INSTALL_PATH_NEW=$BIN; export FLEET_INSTALL_PATH_NEW
    if [ -f "$RC" ] && grep -Fq "$MARK" "$RC"; then
      :
    elif [ -f "$RC" ] && grep -q '\.local/bin' "$RC" && [ "$BIN" = "$HOME/.local/bin" ]; then
      :
    else
      { [ -f "$RC" ] && [ -s "$RC" ] && [ "$(tail -c 1 "$RC" | od -An -c | tr -d ' ')" != '\n' ] && echo; } >>"$RC" 2>/dev/null || true
      printf 'export PATH="%s:$PATH"  %s\n' "$BIN" "$MARK" >>"$RC"
      path_note="（已把 $BIN 加进 $RC 的 PATH，新开的终端生效）"
    fi
    ;;
esac

say "✓ 已安装 fleet 到 ${BIN}（fleet 在 ${ROOT}）${path_note}"
if [ "$HUB_ANS" = 1 ] && [ "$NEWBIE" = 1 ]; then
  say "  之后每次只敲：fleet"
elif [ "$HUB_ANS" = 1 ]; then
  say "  入口 $HUBURL · 之后每次只敲：fleet"
else
  say "  没有入口：fleet 读这台电脑自己的 fleet · 之后每次只敲：fleet"
fi

# ── 4 — tmux ≥ 3.2 (fleet-client-lib.sh's check + install, as node join's) ─
# vendor_tmux — tmux's static build for this platform into $VENDOR/bin (#2260):
# the bundle's vendor/tmux, else the archive conf/vendor-tmux.lock pins, its
# SHA-256 checked; it must run and say ≥ 3.2 before it is put in place. 1 = no
# build for this platform, or it would not run (→ Homebrew / apt as before).
VENDOR="${FLEET_INSTALL_VENDOR:-${XDG_DATA_HOME:-$HOME/.local/share}/claude-fleet-vendor}"
vendor_tmux() {
  [ "${FLEET_INSTALL_STATIC_TMUX:-1}" != 0 ] || return 1
  _vt="$tmp/vendor-tmux"
  if [ -f "$tmp/b/vendor/tmux" ] && [ ! -L "$tmp/b/vendor/tmux" ]; then
    mv -f "$tmp/b/vendor/tmux" "$_vt"
  else
    _vp=$(platform); [ -n "$_vp" ] || return 1
    _vl=$(awk -v p="$_vp" '$1 == p { print $2, $3; exit }' "$ROOT/conf/vendor-tmux.lock" 2>/dev/null)
    [ -n "$_vl" ] || return 1
    _vs=${_vl%% *} _vu=${_vl#* }
    say "tmux: 下载 tmux 的静态版（${_vp}）…"
    download "$_vu" "$tmp/vendor-tmux.tgz" ' tmux' --max-time 120 || { say "tmux: 静态版没下成（${_vu}）"; return 1; }
    [ "$(sha256 "$tmp/vendor-tmux.tgz")" = "$_vs" ] || { say "tmux: 静态版校验不符，不用它"; return 1; }
    mkdir -p "$tmp/vx"
    tar -xzf "$tmp/vendor-tmux.tgz" -C "$tmp/vx" tmux 2>/dev/null && [ -f "$tmp/vx/tmux" ] || return 1
    mv -f "$tmp/vx/tmux" "$_vt"
  fi
  chmod 0755 "$_vt"
  _vv=$("$_vt" -V 2>/dev/null) || { say "tmux: 静态版在这台电脑上跑不起来"; return 1; }
  mkdir -p "$VENDOR/bin" || return 1
  mv -f "$_vt" "$VENDOR/bin/tmux" || return 1
  case ":$PATH:" in *":$VENDOR/bin:"*) ;; *) PATH="$VENDOR/bin:$PATH" ;; esac
  [ -n "$_vv" ]
}
if [ "$DEPS" = 0 ]; then
  say "tmux: skipped (--no-deps)"
else
  # shellcheck source=fleet-client-lib.sh
  . "$ROOT/bin/fleet-client-lib.sh"
  # shellcheck disable=SC2034  # FC_LOG / FC_SUDO are read by the lib just sourced
  FC_LOG="$tmp/deps.log"
  # shellcheck disable=SC2034
  if [ -n "${FLEET_INSTALL_SUDO+x}" ]; then FC_SUDO="$FLEET_INSTALL_SUDO"; fi
  # tmux's own static build, from an earlier run, comes first (as `fleet` puts it)
  [ -x "$VENDOR/bin/tmux" ] && PATH="$VENDOR/bin:$PATH"
  if fc_tmux_ok; then
    say "tmux: $FC_TMUX_V 已就绪"
  elif vendor_tmux && fc_tmux_ok; then
    say "tmux: $FC_TMUX_V 已就绪（随包带的，在 $VENDOR/bin — 不用 Homebrew）"
  else
    old="$FC_TMUX_V"
    if [ -n "$old" ]; then say "tmux: $old 低于 3.2，安装新版本…"; else say "tmux: 没有，安装中…"; fi
    if fc_pkg_install tmux && fc_tmux_ok; then
      say "tmux: ok $FC_TMUX_V — fleet 直接进本地壳"
    elif [ -n "$FC_WHY" ]; then
      say "tmux: 没装上 — ${FC_WHY}；现在 fleet 先用直连"
    else
      say "tmux: 装完仍是 ${FC_TMUX_V:-没有}（要 3.2 以上）— 换个来源装新版 tmux；现在 fleet 先用直连"
    fi
  fi
fi

# ── 5 — 承载, or (只看只派 + 接) a node that only coordinates ───────────────
NODE_ENV="$CONF/node.env"
is_node_here() { [ -f "$NODE_ENV" ] && grep -qx "CCQUOTA_HUB_URL=$HUBURL" "$NODE_ENV" && grep -q '^CCQUOTA_TOKEN=.' "$NODE_ENV"; }
if [ "$HOST_ANS" = 1 ]; then
  if [ "$CUR_HOST" = 1 ] && full; then
    say "承载: 已开，不重装"
  elif [ "$HUB_ANS" = 1 ] && ! is_node_here && { [ "${FLEET_INSTALL_NO_NODE:-}" = 1 ] || { [ ! -t 2 ] && [ "${FLEET_INSTALL_NODE_FORCE:-}" != 1 ]; }; }; then
    # the hub half needs a scan nobody can do here: the part that runs sessions now, the join later
    say "承载: 装跑会话的那部分…"
    FLEET_CONF_DIR="$CONF" FLEET_INSTALL_ROOT="$ROOT" "$ROOT/bin/fleet-host-install.sh" </dev/null 2>&1 | sed 's/^/  /' >&2 || :
    say "承载: 入口登记要扫码 — 在终端里敲 fleet host on 补上"
  else
    say "承载: 打开…"
    if FLEET_CONF_DIR="$CONF" FLEET_INSTALL_ROOT="$ROOT" "$ROOT/bin/fleet" host on --yes </dev/null >"$tmp/host.out" 2>&1; then :; else
      say "承载: 有一步没成 — 再跑一次这行，或敲 fleet host on 补上"
    fi
    grep -v '^能力:' "$tmp/host.out" | sed 's/^/  /' >&2 || :   # the 能力 line is step 7's
  fi
elif [ "$CUR_HOST" = 1 ]; then
  say "承载: 已开，这次不动它（要关：fleet host off）"
fi
if [ "$HUB_ANS" = 1 ] && [ "$HOST_ANS" = 0 ] && [ "$CUR_HOST" = 0 ] && [ "${FLEET_INSTALL_NO_NODE:-}" != 1 ]; then
  if is_node_here; then
    say "入口: 这台已登记在 ${HUBURL}（${NODE_ENV}），不重登记"
  else
    # 登录即登记 (issue #2212): no second scan, and no terminal needed — a
    # computer already logged in takes its node pass by the device key now;
    # one not logged in yet is registered by its `fleet login` (the one scan)
    _erc=0
    FLEET_CONF_DIR="$CONF" bash "$ROOT/bin/fleet-node.sh" ensure --hub "$HUBURL" </dev/null >/dev/null 2>&1 || _erc=$?
    if [ "$NEWBIE" = 1 ]; then
      # 登录即登记 is the fleet's business: nothing to read here unless it failed
      [ "$_erc" = 0 ] || [ "$_erc" = 3 ] || say "登记: 这次没成 — fleet 照样能用，登录后会自己补上"
    else case "$_erc" in
      0) say "入口: 已随登录登记这台电脑（不可信 · 只协调：不在本机跑别人派的会话、不借入口的账号）" ;;
      3) say "入口: 登录（fleet login，扫一次码）时自动登记为只协调的节点，不用另外扫码" ;;
      *) say "入口: 这次没登记成 — fleet 照样能用；登录后 fleet run / fleet 会自己补上（或敲 fleet node join）" ;;
    esac; fi
  fi
fi

# ── 6 — the Agent configuration (#1725) is 承载's (issue #4826) ─────────────
# A full install's own setup / sync applies it (fill only); the client
# package carries none — `fleet host on` installs it with the rest of the tree.
# An earlier client wired its own copy into this login: every hook through its
# bin/fleet-hook-run.sh (a personal one through bin/fleet-hook-personal.sh),
# the github / fetch MCP servers at its bin/mcp-*.sh — files this package no
# longer has. So the wiring that names them goes, here (a client's update runs
# this very script): only those entries, the rest of each file byte for byte
# (Codex's config.toml as text), the file before kept beside it once — and
# never where ~/.claude/fleet is the full install, or this computer hosts.
if full; then
  say "Agent 配置: 完整安装的同步装同一份"
elif [ "${FLEET_INSTALL_NO_AGENTS:-}" != 1 ] && [ ! -f "$HOME/.claude/fleet/bin/fleet-up.sh" ] && [ ! -d "$HOME/.claude/fleet/.git" ] \
     && [ "$(fconf host 2>/dev/null || true)" != 1 ]; then
  cat > "$tmp/unwire.py" <<'PYUW'
import json, os, re, sys, time
home, codex = sys.argv[1], sys.argv[2]
SHIM = re.compile(r"/\.claude/fleet/(\./)?bin/fleet-hook-(run|personal)\.sh\b")
MCP = re.compile(r"\.claude/fleet/bin/mcp-(github|fetch)\.sh")
said = []
def keep(path, text):
    bak = path + ".fleet-bak-" + time.strftime("%Y%m%d%H%M%S")
    if not os.path.exists(bak):
        with open(bak, "w") as f:
            f.write(text)
def put(path, text):
    tmp = path + ".fleet-tmp"
    with open(tmp, "w") as f:
        f.write(text)
    os.chmod(tmp, os.stat(path).st_mode & 0o7777)
    os.replace(tmp, path)
# Claude Code's hooks
p = os.path.join(home, ".claude", "settings.json")
try:
    raw = open(p).read(); s = json.loads(raw)
except (OSError, ValueError):
    s = None
if isinstance(s, dict) and isinstance(s.get("hooks"), dict):
    n = 0
    for ev in list(s["hooks"]):
        groups = s["hooks"][ev]
        if not isinstance(groups, list):
            continue
        out = []
        for g in groups:
            hs = g.get("hooks") if isinstance(g, dict) else None
            if isinstance(hs, list):
                left = [h for h in hs if not (isinstance(h, dict) and SHIM.search(str(h.get("command", ""))))]
                n += len(hs) - len(left)
                if not left:
                    continue
                g = dict(g, hooks=left)
            out.append(g)
        if out:
            s["hooks"][ev] = out
        else:
            del s["hooks"][ev]
    if n:
        if not s["hooks"]:
            del s["hooks"]
        keep(p, raw); put(p, json.dumps(s, indent=2, ensure_ascii=False) + "\n")
        said.append("钩子 %d 条" % n)
# Claude Code's MCP servers
p = os.path.join(home, ".claude.json")
try:
    raw = open(p).read(); c = json.loads(raw)
except (OSError, ValueError):
    c = None
if isinstance(c, dict) and isinstance(c.get("mcpServers"), dict):
    gone = [k for k, v in c["mcpServers"].items() if MCP.search(json.dumps(v))]
    if gone:
        for k in gone:
            del c["mcpServers"][k]
        keep(p, raw); put(p, json.dumps(c, indent=2, ensure_ascii=False) + "\n")
        said.append("Claude MCP " + "·".join(sorted(gone)))
# Codex's MCP servers — text: a [mcp_servers.<n>] table naming the script goes
p = os.path.join(codex, "config.toml")
try:
    raw = open(p).read()
except OSError:
    raw = None
if raw is not None:
    lines, out, gone, i = raw.splitlines(True), [], [], 0
    while i < len(lines):
        m = re.match(r"\s*\[mcp_servers\.([A-Za-z0-9_-]+)\]\s*$", lines[i])
        if m:
            j = i + 1
            while j < len(lines) and not re.match(r"\s*\[", lines[j]):
                j += 1
            if MCP.search("".join(lines[i:j])):
                gone.append(m.group(1)); i = j
                continue
        out.append(lines[i]); i += 1
    if gone:
        keep(p, raw); put(p, "".join(out))
        said.append("Codex MCP " + "·".join(gone))
print("、".join(said))
PYUW
  _uw="$(python3 "$tmp/unwire.py" "$HOME" "${CODEX_HOME:-$HOME/.codex}" 2>/dev/null || true)"
  [ -z "$_uw" ] || say "Agent 配置: 撤下了旧客户端接进来的 ${_uw} — 它们指向的文件不再随客户端装（承载的东西，fleet host on 时一起装）"
fi

# no hub + 承载 — the subscription accounts are this computer's own
if [ "$HUB_ANS" = 0 ] && [ "$HOST_ANS" = 1 ]; then
  ACCTS="${FLEET_ACCOUNTS_DIR:-$CONF/accounts}"
  if [ -n "$(ls -A "$ACCTS" 2>/dev/null)" ]; then
    say "账号: $(ls -A "$ACCTS" | tr '\n' ' ')（在 ${ACCTS}）"
  else
    say "账号: 还没有 — 本机加一个：claude setup-token，把打出的 token 存成 $ACCTS/<名字>（chmod 600）；不加就用 claude 自己登录的那个"
  fi
fi

# ── 7 — what this computer does, in the doctor's words (#1806) ─────────────
if [ "$(fconf host 2>/dev/null || true)" = 1 ]; then cap='承载 已开'; else cap='承载 未开'; fi
if [ -n "$(conf_get FLEET_HUB_URL)" ]; then hubw='接'; else hubw='不接'; fi
if [ "$NEWBIE" = 1 ] && [ "$cap" != '承载 已开' ]; then
  :   # the newcomer: nothing was asked, nothing to change yet — no 能力 lines
else
  say "能力: 基础 · $cap · 入口 $hubw"
  if [ "$cap" = '承载 已开' ]; then
    say "  要改答案：再跑一次同一条命令 · 关掉承载：fleet host off"
  elif [ "$HINT_HOST" = 1 ]; then
    say "  要承载：再跑一次本命令，或 fleet host on"
  else
    say "  要在这台跑会话：再跑一次同一条命令选 2，或 fleet host on"
  fi
fi

say "用时 $(( $(date +%s) - T0 )) 秒"
if [ "${FLEET_INSTALL_NO_RUN:-}" = 1 ]; then
  exit 0
fi
export PATH="$BIN:$PATH"
# no terminal (a pipe with no tty, CI): the client cannot open here, and that is
# not a failed install (issue #4074) — say so and end 0
if [ "$TTY" = 0 ]; then
  say "没有终端，跳过打开客户端 — 在终端里敲 fleet 打开"
  exit 0
fi
if [ "$TTY" = 1 ]; then
  # The terminal's own device, not /dev/tty (issue #1901): stdin opened as
  # /dev/tty has ttyname() «/dev/tty», which tmux refuses — `open terminal
  # failed: can't use /dev/tty` was the last line of every `curl | sh`. stderr
  # is that terminal whenever there is one to show this on.
  if [ -t 2 ]; then exec "$BIN/fleet" 0<&2; fi
  exec "$BIN/fleet" </dev/tty
fi
