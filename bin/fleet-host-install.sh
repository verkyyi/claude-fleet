#!/bin/bash
# fleet-host-install.sh — put the 承载 part of the fleet onto this computer
# (issue #1804, EPIC #1813 C2). Run by `fleet host on` (fleet-host.sh) and so by
# the install line's 「2 也跑会话（承载）」 answer; never by hand.
#
# Every computer has ONE fleet directory, ~/.claude/fleet. The install line puts
# the part everyone has there (the client's files, no git); 承载 is the same
# directory as a git checkout of `stable` plus a new login's setup. So this:
#
#   1. tools   git and tmux (≥ 3.2), each skipped when here — the same installer
#              as the install line's tmux step (fleet-client-lib.sh's
#              fc_pkg_install: Homebrew / apt-get / dnf / yum / apk, never a
#              password prompt). FLEET_INSTALL_NO_DEPS=1 skips installing.
#   2. fleet   ~/.claude/fleet → a checkout of `stable`, in place: cloned beside
#              it, then swapped in by rename (a running client keeps the files
#              it has open; every path now resolves into the checkout, which
#              holds every file the base had). Already a checkout → left alone.
#              A base directory the client's updater made a symlink
#              (<root>.versions/<v>) is swapped the same way; the versions it
#              leaves behind go once no process runs from them.
#   3. setup   bin/fleet-login-bootstrap.sh — hooks, commands, daemons, a first
#              fleet (its own marker makes a rerun a no-op); its step lines are
#              printed, the whole run kept in $FLEET_CONF_DIR/host-install.log.
#
# Joining the hub is not this script's business — `fleet host on` joins it and
# opens compute afterwards — but WHERE stable comes from is: with a hub
# (FLEET_HUB_URL, or fleet.conf's) that keeps releases, the hub's signed stable,
# never GitHub (issue #2773). Env: FLEET_INSTALL_ROOT (~/.claude/fleet) ·
# FLEET_BOOTSTRAP_GIT_BASE (https://github.com — the selftests' seam) ·
# FLEET_INSTALL_NO_DEPS · FLEET_CONF_DIR.
# Exit: 0 the part is here · 1 a step failed (one ✗ line says which; rerunning
# redoes only what is missing).
set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd -P)
ROOT="${FLEET_INSTALL_ROOT:-$HOME/.claude/fleet}"
ROOT="${ROOT%/}"
GITBASE="${FLEET_BOOTSTRAP_GIT_BASE:-https://github.com}"  # dist-ok: no hub, or one that keeps no releases (EPIC #2770 共同约定 7)
CONF="${FLEET_CONF_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/claude-fleet}"
LOG="$CONF/host-install.log"
mkdir -p "$CONF" 2>/dev/null

# retire <dir> — an old copy goes once nothing runs from it (a process whose
# command line names it); still in use → kept, and said, for the next run.
retire() {
  [ -e "$1" ] || [ -L "$1" ] || return 0
  if ps -A -ww -o command= 2>/dev/null | grep -F -- "$1/" | grep -vq grep; then
    echo "  · $1 还有程序在用，先留着（下次运行时删）"
    return 0
  fi
  rm -rf "$1"
}

# ---- 1 tools ------------------------------------------------------------------
lib="$here/fleet-client-lib.sh"
[ -f "$lib" ] || lib="$ROOT/bin/fleet-client-lib.sh"
# shellcheck source=fleet-client-lib.sh
. "$lib" || { echo "✗ 找不到 fleet-client-lib.sh"; exit 1; }
rlib="$here/fleet-release-lib.sh"
[ -f "$rlib" ] || rlib="$ROOT/bin/fleet-release-lib.sh"
# shellcheck source=fleet-release-lib.sh
if [ -f "$rlib" ]; then . "$rlib"; else fleet_rel_first_checkout() { return 3; }; fi
# shellcheck disable=SC2034  # FC_LOG / FC_SUDO are read by the lib just sourced
FC_LOG="$LOG"
# shellcheck disable=SC2034
if [ -n "${FLEET_INSTALL_SUDO+x}" ]; then FC_SUDO="$FLEET_INSTALL_SUDO"; fi
need() {  # <tool> <ok-test> — present, or installed, or one ✗ line
  if eval "$2"; then return 0; fi
  if [ "${FLEET_INSTALL_NO_DEPS:-}" = 1 ]; then echo "✗ 没有 $1（这次不装依赖）"; return 1; fi
  if fc_pkg_install "$1" && eval "$2"; then return 0; fi
  echo "✗ 没装上 $1 — ${FC_WHY:-装完仍不可用}"
  return 1
}
need git 'command -v git >/dev/null 2>&1' || exit 1
need tmux fc_tmux_ok || exit 1
gv=$(git --version 2>/dev/null); gv=${gv#git version }; gv=${gv%% *}
echo "✓ git $gv  ✓ tmux $FC_TMUX_V"

# ---- 2 fleet: the one directory becomes a checkout of stable --------------------
# With a hub that keeps releases (issue #2773) the checkout is the hub's signed
# stable — the key pinned now (fleet-release-lib.sh), the tree verified by
# ccquota (the hub's own, by its release's sha256, when this computer has none
# yet), imported as one local commit; no remote, never GitHub. No hub, or one
# that keeps none (404): `git clone` of stable, as before.
# hub_checkout <dir> — rc 0 made · 3 the hub keeps no releases · 1 failed (says why)
hub_checkout() {
  fleet_rel_first_checkout "$1" "$CONF" 30 "$LOG"
  case $? in
    0) echo "  · 从入口取 stable $(printf '%.7s' "$REL_SHA")（验过章 ${REL_FPR}，不经 GitHub）" ;;
    3) return 3 ;;
    *) case "$REL_STAGE" in
         unreachable) echo "✗ 入口不可达（${REL_HUB}）：${REL_ERR} — 什么都没动；再跑一次即可" ;;
         key)         echo "✗ 入口没给发布签名钥匙（${REL_ERR}）— 什么都没动" ;;
         ccquota)     echo "✗ 没有 ccquota 来验入口的章（${REL_ERR}）— 什么都没动" ;;
         fetch)       echo "✗ 入口的 stable 没验过章或没取到（${REL_ERR}）— 什么都没动" ;;
         *)           echo "✗ 入口的 stable 验过了，但放不进 $1 — 什么都没动" ;;
       esac
       return 1 ;;
  esac
}
if [ -d "$ROOT/.git" ]; then
  echo "✓ $ROOT 已是完整安装（跟 stable），不重装"
else
  url="$GITBASE/verkyyi/claude-fleet.git"
  new="$ROOT.new.$$"
  rm -rf "$new"; mkdir -p "$(dirname "$ROOT")"
  hub_checkout "$new"; hrc=$?
  [ "$hrc" = 1 ] && { rm -rf "$new"; exit 1; }
  if [ "$hrc" = 3 ] && ! git clone -q -b stable "$url" "$new" >>"$LOG" 2>&1; then
    rm -rf "$new"
    echo "✗ 取 stable 失败（git clone ${url}，离线？）— 什么都没动；再跑一次即可"
    exit 1
  fi
  if [ -L "$ROOT" ]; then
    rm -f "$ROOT"
  elif [ -e "$ROOT" ]; then
    mv "$ROOT" "$ROOT.base.$$" || { rm -rf "$new"; echo "✗ 挪不开 $ROOT"; exit 1; }
  fi
  mv "$new" "$ROOT" || { echo "✗ 换不进 ${ROOT}（原目录在 $ROOT.base.$$）"; exit 1; }
  retire "$ROOT.base.$$"
  echo "✓ $ROOT 换成了 stable 的完整安装（同一个目录）"
fi
# the client's staged versions are no longer this directory's (a checkout
# follows stable through install-sync)
retire "$ROOT.versions"

# ---- 3 setup: a new login's bootstrap ------------------------------------------
boot="$ROOT/bin/fleet-login-bootstrap.sh"
[ -x "$boot" ] || { echo "✗ $boot 不在 — 完整安装不对"; exit 1; }
{ printf '\n== %s fleet-login-bootstrap ==\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"; } >>"$LOG"
FLEET_INSTALL_ROOT="$ROOT" "$boot" </dev/null >>"$LOG.run" 2>&1; rc=$?
cat "$LOG.run" >>"$LOG"
sed -n 's/^fleet-login-bootstrap: /  · /p' "$LOG.run"
rm -f "$LOG.run"
if [ "$rc" != 0 ]; then
  echo "✗ 本机设置有一步没成（上面几行说了哪步；全文 ${LOG}）— 再跑一次只补缺的"
  exit 1
fi
echo "✓ 跑会话的那部分已就绪"
