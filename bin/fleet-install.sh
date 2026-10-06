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
# It asks two things, from the terminal (/dev/tty — so `curl | sh` can ask too):
#
#   ① 这台电脑要做什么？  1 只看、只派（推荐）· 2 也跑会话（承载）
#   ② 接入口吗？          1 接（the default when an address came with the line
#                         or is already in fleet.conf）· 2 不接（单机）
#
# Enter takes the default — on a computer that already answered, the default is
# what it answered, so running the line again changes nothing, and running it
# again with another answer is how the answer changes (only the part that is new
# gets installed; nothing is torn down — 承载 goes off with `fleet host off`).
# 「2 承载」 lists what it will add (git, tmux, the background programs) and asks
# once more. No terminal to ask (automation, CI) → the defaults: the part
# everyone has, and one line on how to add 承载. Automation answers ahead with
# FLEET_INSTALL_HOST=0|1 and FLEET_INSTALL_HUB=0|1 (FLEET_HUB_URL for an address);
# --host / --no-hub (and FLEET_INSTALL_NO_HUB=1) are kept for one version as
# aliases of those answers, out of the docs.
#
# ONE directory, ~/.claude/fleet (FLEET_INSTALL_HOME / FLEET_INSTALL_ROOT):
#
#   1. the part everyone has — the client's manifest (fleetclient/manifest in
#      the repo: `fleet`, what it dispatches to, the SHELL, the Agent package),
#      every file SHA-256-checked, from the hub's /install/<path> (接) or the
#      repo paths on GitHub's stable (不接, FLEET_INSTALL_SRC), in the repo's own
#      layout, no git. A copy the manifest no longer lists goes, so the tree is
#      exactly the manifest's; `.client-version` records which client it is
#      (#1722, with a hub). Already a full install here (a git checkout, or one
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
#      lacks — Homebrew / apt-get / dnf / yum / apk, never a password prompt;
#      `--no-deps` (FLEET_INSTALL_NO_DEPS=1) skips it;
#   5. 承载 — `fleet host on --yes` (fleet-host.sh): fleet-host-install.sh turns
#      ~/.claude/fleet into a checkout of stable in place (git, tmux, a new
#      login's setup: hooks, commands, daemons, a first fleet), then, with a
#      hub, the join + compute on. 只看只派 + 接 — the computer joins the hub
#      as a node that only coordinates (#1719: one scan; no terminal for the QR
#      → the line to run later; already a node of this hub → left alone).
#      --no-node (FLEET_INSTALL_NO_NODE=1) skips the hub registration;
#   6. the Agent configuration (#1725) — hooks · skills · commands · MCP · the
#      mod, fill only (fleet-install-apply.sh --bundle); a full install's own
#      sync applies it there. FLEET_INSTALL_NO_AGENTS=1 skips it;
#   7. one line, 能力 基础 · 承载 已开/未开 · 入口 接/不接, and runs `fleet`.
#
# Only what a stock macOS or Linux has: sh, curl, python3 (macOS's own 3.9 is
# enough), and with a hub ssh + ssh-keygen. Windows: inside WSL.
#
# Env: FLEET_INSTALL_BIN (the `fleet` on PATH; ~/.local/bin) · FLEET_INSTALL_NO_RUN=1
# installs without running `fleet` · FLEET_INSTALL_RC (the rc file) ·
# FLEET_INSTALL_SUDO (the sudo prefix; default `sudo -n`, empty = none) ·
# FLEET_INSTALL_ASK=0 never asks, even with a terminal (the selftests' seam).
# Exit: 0 installed (and `fleet` is running, which replaces this process) ·
# 2 an unsupported system, a missing prerequisite or a bad answer · 1 a download
# failed.
set -eu

DEPS=1
[ "${FLEET_INSTALL_NO_DEPS:-}" = 1 ] && DEPS=0
HOST_ANS="${FLEET_INSTALL_HOST:-}"
HUB_ANS="${FLEET_INSTALL_HUB:-}"
[ "${FLEET_INSTALL_NO_HUB:-}" = 1 ] && HUB_ANS=0
for a in "$@"; do
  case "$a" in
    --no-deps) DEPS=0 ;;
    --host) HOST_ANS=1 ;;      # one version: the answer «2 也跑会话», ahead
    --no-hub) HUB_ANS=0 ;;     # one version: the answer «2 不接», ahead
    --no-node) FLEET_INSTALL_NO_NODE=1 ;;
    *) printf 'fleet-install: 不认识的参数 %s（自动化用 FLEET_INSTALL_HOST=0|1、FLEET_INSTALL_HUB=0|1 预填答案）\n' "$a" >&2; exit 2 ;;
  esac
done
case "$HOST_ANS" in ''|0|1) ;; *) echo "fleet-install: FLEET_INSTALL_HOST 只能是 0 或 1" >&2; exit 2 ;; esac
case "$HUB_ANS" in ''|0|1) ;; *) echo "fleet-install: FLEET_INSTALL_HUB 只能是 0 或 1" >&2; exit 2 ;; esac

PRE_HUB="${FLEET_HUB_URL:-__FLEET_HUB_URL__}"
case "$PRE_HUB" in http://*|https://*) PRE_HUB="${PRE_HUB%/}" ;; *) PRE_HUB='' ;; esac
SRC="${FLEET_INSTALL_SRC:-https://raw.githubusercontent.com/verkyyi/claude-fleet/stable}"
SRC="${SRC%/}"

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
ASK=$TTY
[ "${FLEET_INSTALL_ASK:-}" = 0 ] && ASK=0
ask() { printf '%s\n' "$*" >/dev/tty; }
# choose <default 1|2> → CH: Enter = the default, anything else asks again
choose() {
  while :; do
    printf '回车 = %s › ' "$1" >/dev/tty
    IFS= read -r CH </dev/tty || CH=''
    case "$CH" in '') CH=$1; return 0 ;; 1|2) return 0 ;; esac
    ask "  只有 1 或 2"
  done
}

ASKED_HOST=0
if [ -z "$HOST_ANS" ] && [ "$ASK" = 1 ]; then
  d=1; [ "$CUR_HOST" = 1 ] && d=2
  ask ''
  ask '这台电脑要做什么？'
  ask '  1 只看、只派        推荐 · 会话开在别的机器上'
  ask '  2 也跑会话（承载）  要 tmux、git、后台程序'
  choose "$d"
  HOST_ANS=$((CH - 1)); ASKED_HOST=1
  [ "$CH" = 1 ] && ask '→ 1 只看、只派' || ask '→ 2 也跑会话'
fi
if [ -z "$HUB_ANS" ] && [ "$ASK" = 1 ]; then
  d=2; [ -n "$HUBURL" ] && d=1
  ask ''
  ask '接入口吗？'
  if [ -n "$PRE_HUB" ]; then
    ask "  1 接                推荐 · 命令是从入口复制来的（${PRE_HUB}）"
    ask '  2 不接（单机）'
  else
    if [ -n "$CUR_HUB" ]; then
      ask "  1 接                现在接着 $CUR_HUB"
      ask '  2 不接（单机）      一台电脑就是全部'
    else
      ask '  1 接                看到别的机器上的会话、跨机器派活'
      ask '  2 不接（单机）      推荐 · 一台电脑就是全部'
    fi
  fi
  choose "$d"
  HUB_ANS=$((2 - CH))
  [ "$CH" = 1 ] && ask '→ 1 接' || ask '→ 2 不接'
  if [ "$HUB_ANS" = 1 ] && [ -z "$HUBURL" ]; then
    printf '入口地址（https://…，回车 = 不接）› ' >/dev/tty
    IFS= read -r HUBURL </dev/tty || HUBURL=''
    HUBURL="${HUBURL%/}"
    case "$HUBURL" in http://*|https://*) ;; '') HUB_ANS=0 ;; *) say "fleet-install: 入口地址要以 http:// 或 https:// 开头"; exit 2 ;; esac
  fi
fi
# no terminal (or nothing asked): what was given, else what this computer had,
# else the defaults — the part everyone has; 接 when an address is known
HINT_HOST=0
if [ -z "$HOST_ANS" ]; then HOST_ANS=$CUR_HOST; [ "$CUR_HOST" = 0 ] && HINT_HOST=1; fi
if [ -z "$HUB_ANS" ]; then if [ -n "$HUBURL" ]; then HUB_ANS=1; else HUB_ANS=0; fi; fi
if [ "$HUB_ANS" = 1 ] && [ -z "$HUBURL" ]; then
  say "fleet-install: 要接入口，但不知道地址 — 用入口给的那条命令，或 FLEET_HUB_URL=https://… 预填"; exit 2
fi
# 承载, chosen just now on a computer that does not host yet: say what comes, once more
if [ "$ASKED_HOST" = 1 ] && [ "$HOST_ANS" = 1 ] && [ "$CUR_HOST" = 0 ]; then
  ask ''
  ask '承载要多装这些（已有的跳过）：'
  ask '  · git、tmux'
  ask "  · 跑会话的那部分 fleet：$ROOT 换成跟 stable 的完整安装（同一个目录）"
  ask '  · 后台程序（launchd / systemd），合盖前自动进维护'
  [ "$HUB_ANS" = 1 ] && ask '  · 入口程序：入口开始往这台派会话（个人电脑只派你自己开的）'
  while :; do
    printf '装吗？ [Y/n] › ' >/dev/tty
    IFS= read -r CH </dev/tty || CH=''
    case "$CH" in ''|y|Y|yes|是) break ;; n|N|no|否) HOST_ANS=0; ask '→ 先不承载：只装基础'; break ;; esac
  done
fi
[ "$ASK" = 1 ] && ask ''

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

mkdir -p "$BIN" "$CONF"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/fleet-install.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT INT TERM HUP

# fetch <path> [<url>] → $tmp/<path>, from <url> (default $FROM/<path>). Each
# file's SHA-256 rides in a header from the hub; a download that does not match
# it (a proxy's error page, a cut connection) is refused rather than installed.
fetch() {
  src_url="${2:-$FROM/$1}"
  mkdir -p "$tmp/$(dirname "$1")"
  if ! curl -fsSL -D "$tmp/$1.hdr" "$src_url" -o "$tmp/$1"; then
    say "fleet-install: 下载 $src_url 失败"; exit 1
  fi
  want="$(tr -d '\r' <"$tmp/$1.hdr" | awk 'tolower($1)=="x-ccquota-sha256:"{print $2}')"
  if [ -n "$want" ]; then
    got="$(python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$tmp/$1")"
    [ "$got" = "$want" ] || { say "fleet-install: $1 下载不完整（校验不符）"; exit 1; }
  fi
}

# ── 1 — the part everyone has, into the one directory ─────────────────────
if full; then
  say "fleet: $ROOT 已是完整安装（跟 stable），基础文件不重下"
else
  # the manifest first (its `installer` line is this very script, not a
  # download), then every file on it; nothing is installed until all are here
  if [ "$HUB_ANS" = 1 ]; then fetch manifest; else fetch manifest "$SRC/tokenledger/internal/api/fleetclient/manifest"; fi
  FILES="$(awk '!/^[[:space:]]*#/ && NF && $2 != "installer" { print $1 }' "$tmp/manifest" | tr '\n' ' ')"
  [ -n "${FILES% }" ] || { say "fleet-install: $FROM 的 manifest 里没有文件"; exit 1; }
  for f in $FILES; do
    case "$f" in
      bin/*|conf/*|hooks/*|commands/*|skills/*|mod/*) case "$f" in *..*|*/) say "fleet-install: manifest 里有不认识的路径 $f"; exit 1 ;; esac ;;
      *) say "fleet-install: manifest 里有不认识的路径 $f"; exit 1 ;;
    esac
    fetch "$f"
    # a script or a sourced lib (a comment first; a proxy's HTML page starts with '<')
    case "$f" in bin/*) [ "$(head -c 1 "$tmp/$f")" = '#' ] || { say "fleet-install: $f 不是脚本（入口返回了别的东西）"; exit 1; } ;; esac
  done
  mkdir -p "$ROOT"
  for f in $FILES; do
    mkdir -p "$ROOT/$(dirname "$f")"
    # bin/ is executable; elsewhere a script (a skill's share.sh) keeps its #!
    case "$f" in bin/*) chmod 0755 "$tmp/$f" ;; *) if [ "$(head -c 2 "$tmp/$f")" = '#!' ]; then chmod 0755 "$tmp/$f"; else chmod 0644 "$tmp/$f"; fi ;; esac
    mv -f "$tmp/$f" "$ROOT/$f"
  done
  # A copy the manifest no longer lists — an earlier install's — goes: the tree
  # is the manifest's, file for file (bin/ conf/, and the Agent package's hooks/
  # commands/ skills/ mod/ at all depths, #1725). Never in a full install.
  for d in bin conf; do
    [ -d "$ROOT/$d" ] || continue
    for old in "$ROOT/$d"/*; do
      [ -f "$old" ] || continue
      rel="$d/${old##*/}"
      case " $FILES" in *" $rel "*) ;; *) rm -f "$old"; say "  去掉了不再发的旧文件 $rel" ;; esac
    done
  done
  for d in hooks commands skills mod; do
    [ -d "$ROOT/$d" ] || continue
    find "$ROOT/$d" -type f > "$tmp/have.list" 2>/dev/null || continue
    while IFS= read -r old; do
      rel="${old#"$ROOT"/}"
      case " $FILES" in *" $rel "*) ;; *) rm -f "$old"; say "  去掉了不再发的旧文件 $rel" ;; esac
    done < "$tmp/have.list"
    find "$ROOT/$d" -depth -type d -empty -exec rmdir {} \; 2>/dev/null || true
  done
  # Which client this is (#1722): the hub's /version answer, so `fleet` can
  # tell on its next start whether the hub hands out a newer one. Unchanged
  # but for the time → the file is left as it was (a rerun changes nothing).
  if [ "$HUB_ANS" = 1 ]; then
    curl -fsS --max-time 10 "$HUBURL/version" -o "$tmp/version.json" 2>/dev/null || : > "$tmp/version.json"
    python3 - "$tmp/version.json" "$HUBURL" > "$tmp/client-version" <<'PY' || :
import json, sys, time
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    d = {}
def s(k):
    v = d.get(k)
    return "" if v is None else str(v)
print("version=%s\ncompat=%s\ncommit=%s\nhub=%s\nat=%d" % (s("client_version"), s("client_compat"), s("commit"), sys.argv[2], time.time()))
PY
    if [ "$(grep -v '^at=' "$tmp/client-version" 2>/dev/null)" != "$(grep -v '^at=' "$ROOT/.client-version" 2>/dev/null)" ]; then
      mv -f "$tmp/client-version" "$ROOT/.client-version"
    fi
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
if [ "$HUB_ANS" = 1 ]; then
  say "  入口 $HUBURL · 之后每次只敲：fleet"
else
  say "  没有入口：fleet 读这台电脑自己的 fleet · 之后每次只敲：fleet"
fi

# ── 4 — tmux ≥ 3.2 (fleet-client-lib.sh's check + install, as node join's) ─
if [ "$DEPS" = 0 ]; then
  say "tmux: skipped (--no-deps)"
else
  # shellcheck source=fleet-client-lib.sh
  . "$ROOT/bin/fleet-client-lib.sh"
  # shellcheck disable=SC2034  # FC_LOG / FC_SUDO are read by the lib just sourced
  FC_LOG="$tmp/deps.log"
  # shellcheck disable=SC2034
  if [ -n "${FLEET_INSTALL_SUDO+x}" ]; then FC_SUDO="$FLEET_INSTALL_SUDO"; fi
  if fc_tmux_ok; then
    say "tmux: $FC_TMUX_V 已就绪"
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
  elif [ ! -t 2 ] && [ "${FLEET_INSTALL_NODE_FORCE:-}" != 1 ]; then
    say "入口: 这里没有终端可显示二维码，先不登记 — 在终端里敲 fleet node join 补上"
  else
    say "入口: 登记这台电脑（只看只派：不在本机跑别人派的会话、不借入口的账号）…"
    if FLEET_CONF_DIR="$CONF" "$ROOT/bin/fleet" node join --no-fleet --no-deps --no-admin </dev/null >&2; then
      :
    else
      say "入口: 没登记成（上面一行说了哪步）— fleet 照样能用；再跑一次这行，或敲 fleet node join 补上"
    fi
  fi
fi

# ── 6 — the Agent configuration (#1725), on the base only ──────────────────
# A full install's own setup / sync applies the same package (fill only).
if [ "${FLEET_INSTALL_NO_AGENTS:-}" != 1 ] && ! full && [ -f "$ROOT/bin/fleet-agent-bundle.py" ] && [ -f "$ROOT/bin/fleet-install-apply.sh" ]; then
  if aout="$(FLEET_CONF_DIR="$CONF" bash "$ROOT/bin/fleet-install-apply.sh" --bundle --root "$ROOT" 2>&1)"; then
    case "$aout" in
      *'bundle: skip'*) say "Agent 配置: 这台电脑有完整安装，由它的同步装同一份" ;;
      *) say "Agent 配置: 已装 — 钩子·技能·MCP·Mod（$(printf '%s\n' "$aout" | sed -n 's/^apply: ok — //p')；只补不删，本机覆盖文件里列的不动）" ;;
    esac
  else
    say "Agent 配置: 有一步没成 — $(printf '%s\n' "$aout" | grep ': FAIL' | head -1)；再跑一次这行会只补缺的"
  fi
elif full; then
  say "Agent 配置: 完整安装的同步装同一份"
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
say "能力: 基础 · $cap · 入口 $hubw"
if [ "$cap" = '承载 已开' ]; then
  say "  要改答案：再跑一次同一条命令 · 关掉承载：fleet host off"
elif [ "$HINT_HOST" = 1 ]; then
  say "  要承载：再跑一次本命令，或 fleet host on"
else
  say "  要在这台跑会话：再跑一次同一条命令选 2，或 fleet host on"
fi

if [ "${FLEET_INSTALL_NO_RUN:-}" = 1 ]; then
  exit 0
fi
export PATH="$BIN:$PATH"
if [ "$TTY" = 1 ]; then
  exec "$BIN/fleet" </dev/tty
fi
exec "$BIN/fleet"
