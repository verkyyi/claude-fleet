#!/bin/sh
# fleet-install.sh — the one line a colleague runs (claude-fleet#1470):
#
#     curl -fsSL https://<入口>/install | sh
#
# The hub serves this file at /install with the placeholder in HUB= below
# replaced by its own address, so the script already knows where it came from.
# It
#
#   1. downloads bin/fleet, fleet-login.py and fleet-connect.py from the hub
#      (the versions its image was built from) into ~/.local/bin — no sudo;
#   2. writes the hub's URL to ~/.config/claude-fleet/hub.json (any other key
#      there, a token say, is kept);
#   3. puts ~/.local/bin on PATH by appending ONE line to the shell's rc file,
#      once — running the installer again adds nothing;
#   4. runs `fleet`: the first QR appears right here, in this terminal.
#
# Only what a stock macOS or Linux has: sh, curl, python3 (macOS's own 3.9 is
# enough — the client is standard library only), ssh and ssh-keygen. Windows:
# run it inside WSL. Piped from curl, stdin is the script itself, so anything
# interactive — the ssh session `fleet` opens — reads from /dev/tty.
#
# Env: FLEET_INSTALL_BIN (default ~/.local/bin) · FLEET_INSTALL_NO_RUN=1
# installs without running `fleet` · FLEET_INSTALL_RC overrides the rc file.
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
CONF_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/claude-fleet"
mkdir -p "$BIN" "$CONF_DIR"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/fleet-install.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT INT TERM HUP

# 1 — the client, from the hub. Each file's SHA-256 rides in a header; a
# download that does not match it (a proxy's error page, a cut connection) is
# refused rather than installed.
for f in fleet fleet-login.py fleet-connect.py; do
  if ! curl -fsSL -D "$tmp/$f.hdr" "$HUB/install/$f" -o "$tmp/$f"; then
    say "fleet-install: 下载 $HUB/install/$f 失败"; exit 1
  fi
  want="$(tr -d '\r' <"$tmp/$f.hdr" | awk 'tolower($1)=="x-ccquota-sha256:"{print $2}')"
  if [ -n "$want" ]; then
    got="$(python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$tmp/$f")"
    [ "$got" = "$want" ] || { say "fleet-install: $f 下载不完整（校验不符）"; exit 1; }
  fi
  head -c 2 "$tmp/$f" | grep -q '^#!' || { say "fleet-install: $f 不是脚本（入口返回了别的东西）"; exit 1; }
done
for f in fleet fleet-login.py fleet-connect.py; do
  chmod 0755 "$tmp/$f"
  mv -f "$tmp/$f" "$BIN/$f"
done

# 2 — hub.json: the URL, everything else kept.
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

say "✓ 已安装 fleet 到 $BIN $path_note"
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
