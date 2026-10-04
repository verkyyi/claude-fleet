#!/bin/bash
# fleet-install-selftest.sh — the one-line install (issue #1470):
# bin/fleet-install.sh, as the hub serves it at /install, against a fake hub
# (stdlib python3 on 127.0.0.1) that serves /install/<file> with the SHA-256
# header the real one sends. HOME is a sandbox; nothing is run after the
# install (FLEET_INSTALL_NO_RUN=1).
#
# Legs:
#   A. mirror     tokenledger/internal/api/fleetclient/* are byte-for-byte the
#                 bin/ originals (the hub embeds copies: its Docker context is
#                 tokenledger/ alone) — the shell half of the Go pin
#   B. install    `curl … | sh` style (the script on stdin, the hub URL filled
#                 in): fleet, fleet-login.py, fleet-connect.py land in
#                 ~/.local/bin, executable; hub.json gets the URL and keeps a
#                 token already there; the rc file gets ONE PATH line
#   C. again      a second run changes nothing: no second PATH line
#   D. refusals   a Windows uname → exit 2 with the WSL note; a download whose
#                 SHA-256 does not match → exit 1, nothing installed
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/fleet-install-selftest.XXXXXX") || exit 2
HUB_PID=""
cleanup() {
  if [ -n "$HUB_PID" ]; then kill "$HUB_PID" 2>/dev/null; fi
  rm -rf "${WORK:?}"
}
trap cleanup EXIT INT TERM HUP
fail=0
ok()  { echo "ok   $*"; }
bad() { echo "FAIL $*"; fail=1; }

# ── A — the embedded copies mirror bin/ ─────────────────────────────────────
# $BIN may be a shadow of symlinks (run-selftests.sh, #660): follow one back to
# the live tree to find tokenledger/ beside it.
real="$BIN/fleet-install.sh"
while [ -L "$real" ]; do
  link="$(readlink "$real")"
  case "$link" in /*) real="$link" ;; *) real="$(dirname "$real")/$link" ;; esac
done
REPO="$(cd "$(dirname "$real")/.." && pwd)"
CLIENT="$REPO/tokenledger/internal/api/fleetclient"
if [ -d "$CLIENT" ]; then
  for f in fleet fleet-login.py fleet-connect.py fleet-install.sh; do
    if cmp -s "$REPO/bin/$f" "$CLIENT/$f"; then ok "A $f mirrored into fleetclient/"
    else bad "A $CLIENT/$f differs from bin/$f — cp bin/$f tokenledger/internal/api/fleetclient/"; fi
  done
else
  echo "skip A: no tokenledger/ beside bin/ ($REPO)"
fi

# ── the fake hub: /install/<file> with X-Ccquota-Sha256 ─────────────────────
cat > "$WORK/hub.py" <<'EOF'
import hashlib, json, os, sys
from http.server import BaseHTTPRequestHandler, HTTPServer
BIN, W = sys.argv[1], sys.argv[2]
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        name = self.path.rsplit("/", 1)[-1]
        if not self.path.startswith("/install/") or name not in ("fleet", "fleet-login.py", "fleet-connect.py"):
            self.send_response(404); self.end_headers(); return
        b = open(os.path.join(BIN, name), "rb").read()
        sha = hashlib.sha256(b).hexdigest()
        if os.path.exists(os.path.join(W, "corrupt")) and name == "fleet-connect.py":
            b = b"<html>proxy error</html>\n"   # the body changes, the header does not
        self.send_response(200)
        self.send_header("Content-Type", "text/x-python")
        self.send_header("X-Ccquota-Sha256", sha)
        self.send_header("Content-Length", str(len(b)))
        self.end_headers(); self.wfile.write(b)
srv = HTTPServer(("127.0.0.1", 0), H)
open(os.path.join(W, "port.tmp"), "w").write(str(srv.server_port)); os.rename(os.path.join(W, "port.tmp"), os.path.join(W, "port"))
srv.serve_forever()
EOF
python3 "$WORK/hub.py" "$BIN" "$WORK" & HUB_PID=$!
for _ in $(seq 1 300); do [ -s "$WORK/port" ] && break; sleep 0.1; done
[ -s "$WORK/port" ] || { echo "FAIL fake hub never started"; exit 1; }
HUB="http://127.0.0.1:$(cat "$WORK/port")"

# The script as the hub serves it: the placeholder replaced.
sed "s|__FLEET_HUB_URL__|$HUB|g" "$BIN/fleet-install.sh" > "$WORK/install.sh"
grep -q "$HUB" "$WORK/install.sh" || { bad "placeholder __FLEET_HUB_URL__ missing from fleet-install.sh"; }

export HOME="$WORK/home" XDG_CONFIG_HOME="$WORK/home/.config" SHELL=/bin/zsh
export FLEET_INSTALL_NO_RUN=1
unset FLEET_HUB_URL FLEET_INSTALL_BIN FLEET_INSTALL_RC
mkdir -p "$HOME/.config/claude-fleet"
echo '{"token": "keep-me"}' > "$HOME/.config/claude-fleet/hub.json"
# A PATH without ~/.local/bin, so the rc line is needed.
SAVED_PATH=$PATH
export PATH="/usr/bin:/bin:/usr/sbin:/sbin"

# ── B — piped install ────────────────────────────────────────────────────────
out=$(sh < "$WORK/install.sh" 2>&1); rc=$?
export PATH=$SAVED_PATH
[ "$rc" = 0 ] && ok "B install exit 0" || bad "B install rc=$rc: $out"
for f in fleet fleet-login.py fleet-connect.py; do
  [ -x "$HOME/.local/bin/$f" ] && cmp -s "$HOME/.local/bin/$f" "$BIN/$f" && ok "B $f installed, executable, identical" || bad "B $f missing/different"
done
url=$(python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));print(d.get("url",""), d.get("token",""))' "$HOME/.config/claude-fleet/hub.json")
[ "$url" = "$HUB keep-me" ] && ok "B hub.json: url written, token kept" || bad "B hub.json: $url"
[ "$(grep -c 'claude-fleet#1470' "$HOME/.zshrc")" = 1 ] && grep -q "$HOME/.local/bin" "$HOME/.zshrc" && ok "B one PATH line in ~/.zshrc" || bad "B zshrc: $(cat "$HOME/.zshrc" 2>&1)"
echo "$out" | grep -q '已安装 fleet' && echo "$out" | grep -q '之后每次只敲：fleet' && ok "B says what to type next" || bad "B output: $out"
# The installed dispatcher works from the sandbox (no hub reachable → usage error names the installer).
out2=$("$HOME/.local/bin/fleet" --help 2>&1); rc=$?
[ "$rc" = 0 ] && echo "$out2" | grep -q 'fleet login renew' && ok "B installed fleet --help" || bad "B installed fleet: rc=$rc $out2"

# ── C — a second run adds nothing ───────────────────────────────────────────
export PATH="/usr/bin:/bin:/usr/sbin:/sbin"
sh < "$WORK/install.sh" >/dev/null 2>&1; rc=$?
export PATH=$SAVED_PATH
[ "$rc" = 0 ] && [ "$(grep -c 'claude-fleet#1470' "$HOME/.zshrc")" = 1 ] && ok "C second run: still one PATH line" || bad "C rc=$rc zshrc: $(cat "$HOME/.zshrc")"
# With ~/.local/bin already on PATH, no rc file is touched at all.
rm -f "$HOME/.zshrc"
PATH="$HOME/.local/bin:$PATH" sh < "$WORK/install.sh" >/dev/null 2>&1; rc=$?
[ "$rc" = 0 ] && [ ! -e "$HOME/.zshrc" ] && ok "C PATH already right: rc file untouched" || bad "C rc=$rc zshrc exists: $(cat "$HOME/.zshrc" 2>&1)"

# ── D — refusals ────────────────────────────────────────────────────────────
mkdir -p "$WORK/shim"
printf '#!/bin/sh\necho MSYS_NT-10.0\n' > "$WORK/shim/uname"; chmod +x "$WORK/shim/uname"
out=$(PATH="$WORK/shim:$PATH" sh < "$WORK/install.sh" 2>&1); rc=$?
[ "$rc" = 2 ] && echo "$out" | grep -q WSL && ok "D Windows → exit 2, says WSL" || bad "D windows rc=$rc: $out"
rm -rf "$HOME/.local/bin"
touch "$WORK/corrupt"
out=$(sh < "$WORK/install.sh" 2>&1); rc=$?
rm -f "$WORK/corrupt"
[ "$rc" = 1 ] && echo "$out" | grep -q '校验不符' && [ ! -e "$HOME/.local/bin/fleet" ] && ok "D bad SHA-256 → exit 1, nothing installed" || bad "D corrupt rc=$rc: $out"

[ "$fail" = 0 ] && echo "PASS fleet-install-selftest" || echo "FAIL fleet-install-selftest"
exit "$fail"
