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
#   2. writes the hub's URL to ~/.config/claude-fleet/hub.json (any other key
#      there, a token say, is kept);
#   3. puts ~/.local/bin on PATH by appending ONE line to the shell's rc file,
#      once — running the installer again adds nothing;
#   4. runs `fleet`: the first QR appears right here, in this terminal — and
#      with tmux ≥ 3.2 on this computer, `fleet` is the shell.
#
# Only what a stock macOS or Linux has: sh, curl, python3 (macOS's own 3.9 is
# enough — the client is standard library only), ssh and ssh-keygen. tmux is
# optional: without it `fleet` says how to get it and goes the direct way.
# Windows: run it inside WSL. Piped from curl, stdin is the script itself, so
# anything interactive — the ssh session `fleet` opens — reads from /dev/tty.
#
# Env: FLEET_INSTALL_HOME (the files; default ${XDG_DATA_HOME:-~/.local/share}/
# claude-fleet) · FLEET_INSTALL_BIN (the `fleet` on PATH; default ~/.local/bin)
# · FLEET_INSTALL_NO_RUN=1 installs without running `fleet` · FLEET_INSTALL_RC
# overrides the rc file.
# Exit: 0 installed (and `fleet` is running, which replaces this process) ·
# 2 an unsupported system or a missing prerequisite · 1 a download failed.
set -eu

HUB="${FLEET_HUB_URL:-__FLEET_HUB_URL__}"
case "$HUB" in
  http://*|https://*) ;;
  *) echo "fleet-install: no hub URL (this file is meant to be served by the hub at /install)" >&2; exit 2 ;;
esac
HUB="${HUB%/}"

say() { printf '%s\n' "$*" >&2; }
sq() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }

case "$(uname -s 2>/dev/null || echo unknown)" in
  Darwin|Linux) ;;
  MINGW*|MSYS*|CYGWIN*|Windows*)
    say "fleet-install: Windows 请在 WSL 里运行这条命令（wsl --install，然后在 WSL 终端里再执行一次）"; exit 2 ;;
  *) say "fleet-install: 不支持的系统 $(uname -s)（支持 macOS 与 Linux；Windows 用 WSL）"; exit 2 ;;
esac

for tool in curl python3 ssh ssh-keygen; do
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

# fetch <path> → $tmp/<path>. Each file's SHA-256 rides in a header; a download
# that does not match it (a proxy's error page, a cut connection) is refused
# rather than installed.
fetch() {
  mkdir -p "$tmp/$(dirname "$1")"
  if ! curl -fsSL -D "$tmp/$1.hdr" "$HUB/install/$1" -o "$tmp/$1"; then
    say "fleet-install: 下载 $HUB/install/$1 失败"; exit 1
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
fetch manifest
FILES="$(awk '!/^[[:space:]]*#/ && NF && $2 != "installer" { print $1 }' "$tmp/manifest" | tr '\n' ' ')"
[ -n "${FILES% }" ] || { say "fleet-install: 入口的 /install/manifest 里没有文件"; exit 1; }
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
# The `fleet` on PATH: two lines that run the real one — a script, not a
# symlink, because `fleet` finds its siblings in the directory of ITS OWN path
# and a directory of symlinks relies on that (fleet-shell.sh's conf-free mirror,
# bin/selftest-shadow-root.sh). Nothing to do when $BIN is the root's own bin/.
if [ "$(cd "$BIN" && pwd -P)" != "$(cd "$ROOT/bin" && pwd -P)" ]; then
  printf '#!/bin/sh\n# fleet — installed by `curl -fsSL %s/install | sh` (claude-fleet#1486); the client is %s\nexec %s "$@"\n' \
    "$HUB" "$ROOT/bin" "$(sq "$ROOT/bin/fleet")" > "$tmp/fleet"
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
if [ -f "$ROOT/bin/fleet-conf.sh" ] \
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
say "  入口 $HUB · 之后每次只敲：fleet"

# 4 — the first `fleet`, right here.
if [ "${FLEET_INSTALL_NO_RUN:-}" = 1 ]; then
  exit 0
fi
export PATH="$BIN:$PATH"
if [ -r /dev/tty ]; then
  exec "$BIN/fleet" </dev/tty
fi
exec "$BIN/fleet"
