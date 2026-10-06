#!/bin/sh
# fleet-install.sh — the one line a colleague runs (claude-fleet#1470, #1486):
#
#     curl -fsSL https://<入口>/install | sh
#
# The hub serves this file at /install with the placeholder in HUB= below
# replaced by its own address, so the script already knows where it came from.
# It
#
#   1. fetches the hub's /install/manifest — the list of client files its image
#      was built from (fleetclient/manifest in the repo: `fleet`, what it
#      dispatches to, and the SHELL, #1484) — then each file, SHA-256-checked,
#      into ~/.local/share/claude-fleet in the repo's own bin/ + conf/ layout
#      (so a script's `$BIN/../conf/…` resolves there as in a checkout), and
#      puts a two-line `fleet` in ~/.local/bin that runs the real one — no sudo.
#      A copy the manifest no longer lists is removed, so running the line
#      again IS the update, and the tree is exactly the hub's;
#      `.client-version` beside them records which client it is (#1722) —
#      `fleet` compares it with the hub's /version on start and keeps up;
#   2. writes the hub's URL to ~/.config/claude-fleet/fleet.conf, the machine's
#      one config file (FLEET_HUB_URL, FLEET_ROLE client — issue #1623);
#      hub.json keeps its token;
#   3. puts ~/.local/bin on PATH by appending ONE line to the shell's rc file,
#      once — running the installer again adds nothing;
#   4. tmux (issue #1629): with no tmux ≥ 3.2 here, installs it — macOS
#      `brew install tmux` when Homebrew is there (Homebrew itself is never
#      installed for you), Linux apt-get / dnf / yum / apk as root or through
#      `sudo -n` (never a password prompt). Can't? One line says the command to
#      run and that `fleet` goes the direct way until then. Never fatal.
#      `--no-deps` (`curl … | sh -s -- --no-deps`) or FLEET_INSTALL_NO_DEPS=1
#      skips it;
#   5. runs `fleet`: the first QR appears right here, in this terminal — and
#      with tmux ≥ 3.2 on this computer, `fleet` is the shell.
#
# NO HUB (issue #1712, EPIC #1710 C2) — only the tools, on this one computer:
#
#     curl -fsSL https://raw.githubusercontent.com/verkyyi/claude-fleet/stable/bin/fleet-install.sh | sh -s -- --no-hub
#
# The same script from GitHub's `stable`, with --no-hub (FLEET_INSTALL_NO_HUB=1):
# step 1 takes the manifest and every file from FLEET_INSTALL_SRC (default
# https://raw.githubusercontent.com/verkyyi/claude-fleet/stable — the manifest at
# its repo path, tokenledger/internal/api/fleetclient/manifest; no SHA header
# there, the script check still applies); step 2 writes NO hub address — so
# `fleet` opens the client on this computer, reading its own fleet; and a node
# step installs that fleet: ~/.claude/fleet cloned at stable (FLEET_INSTALL_ROOT,
# FLEET_BOOTSTRAP_GIT_BASE) and its bin/fleet-login-bootstrap.sh run — the hooks,
# commands, daemons and a first fleet, exactly a new login's setup — skipped when
# that checkout is already there (FLEET_INSTALL_NO_NODE=1 skips it outright). Last,
# the subscription accounts, which live on this computer: none yet → one line on
# adding one (`claude setup-token`, saved under ~/.config/claude-fleet/accounts/).
#
# Only what a stock macOS or Linux has: sh, curl, python3 (macOS's own 3.9 is
# enough — the client is standard library only), ssh and ssh-keygen. tmux is
# optional: step 4 gets it where it can, and without it `fleet` goes the
# direct way.
# Windows: run it inside WSL. Piped from curl, stdin is the script itself, so
# anything interactive — the ssh session `fleet` opens — reads from /dev/tty.
#
# Env: FLEET_INSTALL_HOME (the files; default ${XDG_DATA_HOME:-~/.local/share}/
# claude-fleet) · FLEET_INSTALL_BIN (the `fleet` on PATH; default ~/.local/bin)
# · FLEET_INSTALL_NO_RUN=1 installs without running `fleet` · FLEET_INSTALL_RC
# overrides the rc file · FLEET_INSTALL_NO_DEPS=1 = --no-deps · FLEET_INSTALL_SUDO
# (the sudo prefix; default `sudo -n`, empty = none).
# Exit: 0 installed (and `fleet` is running, which replaces this process) ·
# 2 an unsupported system or a missing prerequisite · 1 a download failed.
set -eu

DEPS=1
[ "${FLEET_INSTALL_NO_DEPS:-}" = 1 ] && DEPS=0
NOHUB=0
[ "${FLEET_INSTALL_NO_HUB:-}" = 1 ] && NOHUB=1
for a in "$@"; do
  case "$a" in
    --no-deps) DEPS=0 ;;
    --no-hub) NOHUB=1 ;;
    *) printf 'fleet-install: 不认识的参数 %s（只有 --no-deps / --no-hub）\n' "$a" >&2; exit 2 ;;
  esac
done

if [ "$NOHUB" = 1 ]; then
  # no hub (#1712): the files come from GitHub's stable; no address is written
  HUB=''
  SRC="${FLEET_INSTALL_SRC:-https://raw.githubusercontent.com/verkyyi/claude-fleet/stable}"
  SRC="${SRC%/}"
  FROM="$SRC"
else
  HUB="${FLEET_HUB_URL:-__FLEET_HUB_URL__}"
  case "$HUB" in
    http://*|https://*) ;;
    *) echo "fleet-install: no hub URL (this file is meant to be served by the hub at /install; with no hub at all, run it with --no-hub)" >&2; exit 2 ;;
  esac
  HUB="${HUB%/}"
  FROM="$HUB/install"
fi

say() { printf '%s\n' "$*" >&2; }
sq() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }

case "$(uname -s 2>/dev/null || echo unknown)" in
  Darwin|Linux) ;;
  MINGW*|MSYS*|CYGWIN*|Windows*)
    say "fleet-install: Windows 请在 WSL 里运行这条命令（wsl --install，然后在 WSL 终端里再执行一次）"; exit 2 ;;
  *) say "fleet-install: 不支持的系统 $(uname -s)（支持 macOS 与 Linux；Windows 用 WSL）"; exit 2 ;;
esac

TOOLS="curl python3 ssh ssh-keygen"
[ "$NOHUB" = 1 ] && TOOLS="curl python3 git"     # no hub: no certificate, the node is a git checkout
for tool in $TOOLS; do
  command -v "$tool" >/dev/null 2>&1 || {
    case "$tool" in
      python3) say "fleet-install: 需要 python3 —— macOS 执行 xcode-select --install；Linux 用包管理器安装 python3" ;;
      *) say "fleet-install: 需要 $tool" ;;
    esac
    exit 2
  }
done

BIN="${FLEET_INSTALL_BIN:-$HOME/.local/bin}"
ROOT="${FLEET_INSTALL_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}/claude-fleet}"
CONF_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/claude-fleet"
mkdir -p "$BIN" "$ROOT" "$CONF_DIR"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/fleet-install.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT INT TERM HUP

# fetch <path> [<url>] → $tmp/<path>, from <url> (default $FROM/<path>: the
# hub's /install/<path>, or with --no-hub the repo path on GitHub's stable). Each
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

# 1 — the client, from the hub: the manifest first (the list this hub's image
# embeds — its `installer` line is this very script, not a download), then every
# file on it. Nothing is installed until all of them are here and checked.
if [ "$NOHUB" = 1 ]; then fetch manifest "$SRC/tokenledger/internal/api/fleetclient/manifest"; else fetch manifest; fi
FILES="$(awk '!/^[[:space:]]*#/ && NF && $2 != "installer" { print $1 }' "$tmp/manifest" | tr '\n' ' ')"
[ -n "${FILES% }" ] || { say "fleet-install: $FROM 的 manifest 里没有文件"; exit 1; }
for f in $FILES; do
  case "$f" in
    bin/*|conf/*) case "$f" in *..*|*/) say "fleet-install: manifest 里有不认识的路径 $f"; exit 1 ;; esac ;;
    *) say "fleet-install: manifest 里有不认识的路径 $f"; exit 1 ;;
  esac
  fetch "$f"
  # a script or a sourced lib (a comment first; a proxy's HTML page starts with '<')
  case "$f" in bin/*) [ "$(head -c 1 "$tmp/$f")" = '#' ] || { say "fleet-install: $f 不是脚本（入口返回了别的东西）"; exit 1; } ;; esac
done
for f in $FILES; do
  mkdir -p "$ROOT/$(dirname "$f")"
  case "$f" in bin/*) chmod 0755 "$tmp/$f" ;; *) chmod 0644 "$tmp/$f" ;; esac
  mv -f "$tmp/$f" "$ROOT/$f"
done
# A copy the manifest no longer lists — an earlier install's — goes: the tree
# under $ROOT/bin and $ROOT/conf is the hub's, file for file.
for d in bin conf; do
  [ -d "$ROOT/$d" ] || continue
  for old in "$ROOT/$d"/*; do
    [ -f "$old" ] || continue
    rel="$d/${old##*/}"
    case " $FILES" in *" $rel "*) ;; *) rm -f "$old"; say "  去掉了入口不再发的旧文件 $rel" ;; esac
  done
done
# Which client this is (issue #1722): the hub's /version answer for it, so
# `fleet` can tell on its next start whether the hub hands out a newer one
# (bin/fleet-client-update.sh). Written with the hub only; a hub that does not
# say leaves the fields empty — still the mark of an installed client.
if [ "$NOHUB" = 0 ]; then
  curl -fsS --max-time 10 "$HUB/version" -o "$tmp/version.json" 2>/dev/null || : > "$tmp/version.json"
  python3 - "$tmp/version.json" "$HUB" > "$ROOT/.client-version" <<'PY' || :
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
fi
# The `fleet` on PATH: two lines that run the real one — a script, not a
# symlink, because `fleet` finds its siblings in the directory of ITS OWN path
# and a directory of symlinks relies on that (fleet-shell.sh's conf-free mirror,
# bin/selftest-shadow-root.sh). Nothing to do when $BIN is the root's own bin/.
if [ "$(cd "$BIN" && pwd -P)" != "$(cd "$ROOT/bin" && pwd -P)" ]; then
  printf '#!/bin/sh\n# fleet — installed from %s (claude-fleet#1486, #1712); the client is %s\nexec %s "$@"\n' \
    "$FROM" "$ROOT/bin" "$(sq "$ROOT/bin/fleet")" > "$tmp/fleet"
  chmod 0755 "$tmp/fleet"
  mv -f "$tmp/fleet" "$BIN/fleet"
  # the #1470 installer put the two helpers flat in $BIN; `fleet` no longer
  # looks there, so an old copy is only clutter (ours by its header; a file of
  # someone else's with that name is left alone)
  for old in fleet-login.py fleet-connect.py; do
    if [ -f "$BIN/$old" ] && [ ! -L "$BIN/$old" ] && grep -q 'claude-fleet#' "$BIN/$old" 2>/dev/null; then
      rm -f "$BIN/$old"
    fi
  done
fi

# 2 — the hub address goes to the machine's ONE config file (issue #1623):
# fleet.conf's [common] gets FLEET_HUB_URL and FLEET_ROLE gains `client`; an
# older client's files (shell.conf, hub.json's url) are folded in first, each
# kept as .bak. hub.json is left to its token. Without the tool (a manifest
# that predates it), hub.json gets the URL as before.
if [ "$NOHUB" = 1 ]; then
  :   # no hub (#1712): no address anywhere — `fleet` reads this computer
elif [ -f "$ROOT/bin/fleet-conf.sh" ] \
   && FLEET_CONF_DIR="${FLEET_CONF_DIR:-$CONF_DIR}" bash "$ROOT/bin/fleet-conf.sh" migrate --quiet >/dev/null 2>&1 \
   && FLEET_CONF_DIR="${FLEET_CONF_DIR:-$CONF_DIR}" bash "$ROOT/bin/fleet-conf.sh" set-hub "$HUB" --role client; then
  :
else
python3 - "$CONF_DIR/hub.json" "$HUB" <<'PY'
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

# 3 — PATH, once. The marker is what makes a second run a no-op; an rc file
# that already puts $BIN on PATH some other way is left alone too.
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

say "✓ 已安装 fleet 到 ${BIN}（文件在 ${ROOT}）${path_note}"
if [ "$NOHUB" = 1 ]; then
  say "  没有入口：fleet 读这台电脑自己的 fleet · 之后每次只敲：fleet"
else
  say "  入口 $HUB · 之后每次只敲：fleet"
fi

# no hub (#1712) — the fleet itself lives here: ~/.claude/fleet at stable and a
# new login's setup (fleet-login-bootstrap.sh: hooks, commands, daemons, a first
# fleet). Already a checkout → left alone. A failure is said, never fatal: the
# client still opens, and running this line again retries.
if [ "$NOHUB" = 1 ] && [ "${FLEET_INSTALL_NO_NODE:-}" != 1 ]; then
  NODE_ROOT="${FLEET_INSTALL_ROOT:-$HOME/.claude/fleet}"
  if [ -d "$NODE_ROOT/.git" ]; then
    say "fleet: $NODE_ROOT 已经在了，不动它"
  else
    mkdir -p "$(dirname "$NODE_ROOT")"
    if git clone -q -b stable "${FLEET_BOOTSTRAP_GIT_BASE:-https://github.com}/verkyyi/claude-fleet.git" "$NODE_ROOT" 2>/dev/null; then
      say "fleet: 已取 stable → $NODE_ROOT"
    else
      say "fleet: git clone 失败（离线？）— 客户端照样能开，再跑一次这行补上"
    fi
  fi
  if [ -x "$NODE_ROOT/bin/fleet-login-bootstrap.sh" ]; then
    FLEET_INSTALL_ROOT="$NODE_ROOT" "$NODE_ROOT/bin/fleet-login-bootstrap.sh" </dev/null >&2 \
      || say "fleet: 本机设置有一步没成（上面几行说了哪步）— 再跑一次这行会只补缺的"
  fi
fi
# no hub — the subscription accounts are this computer's own
if [ "$NOHUB" = 1 ]; then
  ACCTS="${FLEET_ACCOUNTS_DIR:-${FLEET_CONF_DIR:-$CONF_DIR}/accounts}"
  if [ -n "$(ls -A "$ACCTS" 2>/dev/null)" ]; then
    say "账号: $(ls -A "$ACCTS" | tr '\n' ' ')（在 $ACCTS）"
  else
    say "账号: 还没有 — 本机加一个：claude setup-token，把打出的 token 存成 $ACCTS/<名字>（chmod 600）；不加就用 claude 自己登录的那个"
  fi
fi

# 4 — tmux ≥ 3.2, the one thing the shell needs that a stock system lacks. The
# check and the install are fleet-client-lib.sh's (shared with
# fleet-node-join.sh's deps step); one `tmux: …` line, like node join's steps.
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

# 5 — the first `fleet`, right here.
if [ "${FLEET_INSTALL_NO_RUN:-}" = 1 ]; then
  exit 0
fi
export PATH="$BIN:$PATH"
if [ -r /dev/tty ]; then
  exec "$BIN/fleet" </dev/tty
fi
exec "$BIN/fleet"
