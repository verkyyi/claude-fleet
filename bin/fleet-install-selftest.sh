#!/bin/bash
# fleet-install-selftest.sh — the one-line install (issues #1470, #1486):
# bin/fleet-install.sh, as the hub serves it at /install, against a fake hub
# (stdlib python3 on 127.0.0.1) that serves /install/manifest and
# /install/<path> for every file the manifest lists, with the SHA-256 header the
# real one sends. HOME is a sandbox; nothing is run after the install
# (FLEET_INSTALL_NO_RUN=1) except in leg E, where `fleet` is driven on purpose.
#
# Legs:
#   A. mirror     tokenledger/internal/api/fleetclient/ is byte-for-byte the
#                 repo's bin/ + conf/ for every manifest path, and nothing
#                 unlisted is there (bin/fleet-client-mirror.sh --check — the
#                 shell half of the Go pin, TestFleetClientMatchesBin); the
#                 manifest ships the shell (fleet-shell.sh, conf/tmux-shell.conf)
#   B. install    `curl … | sh` style (the script on stdin, the hub URL filled
#                 in): every manifest file lands under
#                 ~/.local/share/claude-fleet/<path>, identical, bin/ executable;
#                 ~/.local/bin/fleet is the two-line runner of the real one and
#                 works; a stale copy (an older install's) is removed; hub.json
#                 gets the URL and keeps a token already there; the rc file gets
#                 ONE PATH line
#   C. again      a second run changes nothing: no second PATH line
#   D. refusals   a Windows uname → exit 2 with the WSL note; a download whose
#                 SHA-256 does not match → exit 1, nothing installed
#   E. dispatch   from the clean install: with a (fake) tmux ≥ 3.2 on PATH,
#                 `fleet` runs fleet-shell.sh — the server is started from the
#                 install root's own bin/ and conf/; with no tmux, `fleet` prints
#                 the one install hint and goes to fleet-connect.py (the direct
#                 way), starting no server
#   F. tmux       the install's tmux step (issue #1629), on a PATH holding only
#                 what the installer needs plus fakes: macOS + brew + no tmux →
#                 `brew install tmux` once, then ok; no brew → the brew.sh hint,
#                 nothing called, still exit 0; tmux 3.4 → nothing called;
#                 tmux 3.1 counts as none; Linux + apt-get + passwordless sudo →
#                 `apt-get install tmux` once; no root / sudo → the hint only;
#                 --no-deps → skipped. fleet-node-join.sh's copy of fc_tmux_ok is
#                 byte-identical to fleet-client-lib.sh's
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

# $BIN may be a shadow of symlinks (run-selftests.sh, #660): follow one back to
# the live tree, where tokenledger/ (and the manifest) sits beside bin/.
real="$BIN/fleet-install.sh"
while [ -L "$real" ]; do
  link="$(readlink "$real")"
  case "$link" in /*) real="$link" ;; *) real="$(dirname "$real")/$link" ;; esac
done
REPO="$(cd "$(dirname "$real")/.." && pwd)"
CLIENT="$REPO/tokenledger/internal/api/fleetclient"
MANIFEST="$CLIENT/manifest"
[ -f "$MANIFEST" ] || { echo "FAIL no manifest at $MANIFEST"; exit 1; }
# the download list: every manifest path but the installer's
FILES=$(awk '!/^[[:space:]]*#/ && NF && $2 != "installer" { print $1 }' "$MANIFEST")

# ── A — the embedded copies mirror bin/ + conf/ ─────────────────────────────
if out=$(bash "$BIN/fleet-client-mirror.sh" --check 2>&1); then ok "A fleetclient/ mirrors every manifest file, nothing unlisted"
else bad "A fleet-client-mirror.sh --check: $out"; fi
for must in bin/fleet bin/fleet-login.py bin/fleet-connect.py bin/fleet-shell.sh bin/fleet-sidebar.py bin/tmux-status.sh conf/tmux-shell.conf; do
  printf '%s\n' "$FILES" | grep -qxF "$must" && ok "A manifest lists $must" || bad "A manifest does not list $must"
done
[ "$(awk '!/^[[:space:]]*#/ && $2 == "installer" { print $1 }' "$MANIFEST")" = bin/fleet-install.sh ] \
  && ok "A the manifest's installer is bin/fleet-install.sh" || bad "A installer line: $(grep installer "$MANIFEST")"

# ── the fake hub: /install/manifest + /install/<path> with X-Ccquota-Sha256 ──
cat > "$WORK/hub.py" <<'PYEOF'
import hashlib, os, sys
from http.server import BaseHTTPRequestHandler, HTTPServer
REPO, MAN, W = sys.argv[1], sys.argv[2], sys.argv[3]
names = [l.split()[0] for l in open(MAN) if l.strip() and not l.lstrip().startswith("#")
         and not (len(l.split()) > 1 and l.split()[1] == "installer")]
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        name = self.path[len("/install/"):] if self.path.startswith("/install/") else ""
        if name == "manifest":
            b = open(MAN, "rb").read(); ct = "text/plain"
        elif name in names:
            b = open(os.path.join(REPO, name), "rb").read(); ct = "text/x-shellscript"
        else:
            self.send_response(404); self.end_headers(); return
        sha = hashlib.sha256(b).hexdigest()
        if os.path.exists(os.path.join(W, "corrupt")) and name == "bin/fleet-connect.py":
            b = b"<html>proxy error</html>\n"   # the body changes, the header does not
        self.send_response(200)
        self.send_header("Content-Type", ct)
        self.send_header("X-Ccquota-Sha256", sha)
        self.send_header("Content-Length", str(len(b)))
        self.end_headers(); self.wfile.write(b)
srv = HTTPServer(("127.0.0.1", 0), H)
open(os.path.join(W, "port.tmp"), "w").write(str(srv.server_port)); os.rename(os.path.join(W, "port.tmp"), os.path.join(W, "port"))
srv.serve_forever()
PYEOF
python3 "$WORK/hub.py" "$REPO" "$MANIFEST" "$WORK" & HUB_PID=$!
for _ in $(seq 1 300); do [ -s "$WORK/port" ] && break; sleep 0.1; done
[ -s "$WORK/port" ] || { echo "FAIL fake hub never started"; exit 1; }
HUB="http://127.0.0.1:$(cat "$WORK/port")"

# The script as the hub serves it: the placeholder replaced.
sed "s|__FLEET_HUB_URL__|$HUB|g" "$BIN/fleet-install.sh" > "$WORK/install.sh"
grep -q "$HUB" "$WORK/install.sh" || { bad "placeholder __FLEET_HUB_URL__ missing from fleet-install.sh"; }

export HOME="$WORK/home" XDG_CONFIG_HOME="$WORK/home/.config" SHELL=/bin/zsh
export FLEET_INSTALL_NO_RUN=1 FLEET_INSTALL_NO_DEPS=1   # leg F drives the tmux step
unset FLEET_HUB_URL FLEET_INSTALL_BIN FLEET_INSTALL_HOME FLEET_INSTALL_RC XDG_DATA_HOME XDG_CACHE_HOME
ROOT="$HOME/.local/share/claude-fleet"
mkdir -p "$HOME/.config/claude-fleet" "$ROOT/bin" "$HOME/.local/bin"
echo '{"token": "keep-me"}' > "$HOME/.config/claude-fleet/hub.json"
# leftovers an earlier version left: a copy the manifest no longer lists, and
# the #1470 layout's flat helper in ~/.local/bin (ours by its header)
printf '#!/bin/sh\n# claude-fleet#0000 — gone from the manifest\n' > "$ROOT/bin/fleet-gone.sh"
printf '#!/usr/bin/env python3\n# claude-fleet#1470 flat copy\n' > "$HOME/.local/bin/fleet-connect.py"
printf '#!/bin/sh\necho not ours\n' > "$HOME/.local/bin/fleet-login.py"   # no marker: someone else's, left alone
# A PATH without ~/.local/bin, so the rc line is needed.
SAVED_PATH=$PATH
export PATH="/usr/bin:/bin:/usr/sbin:/sbin"

# ── B — piped install ────────────────────────────────────────────────────────
out=$(sh < "$WORK/install.sh" 2>&1); rc=$?
export PATH=$SAVED_PATH
[ "$rc" = 0 ] && ok "B install exit 0" || bad "B install rc=$rc: $out"
nfiles=0; missing=''
while IFS= read -r f; do
  [ -n "$f" ] || continue
  nfiles=$((nfiles + 1))
  if ! cmp -s "$ROOT/$f" "$REPO/$f"; then missing="$missing $f(differs)"; continue; fi
  case "$f" in
    bin/*) [ -x "$ROOT/$f" ] || missing="$missing $f(not executable)" ;;
    *) [ -x "$ROOT/$f" ] && missing="$missing $f(executable)" ;;
  esac
done <<EOT
$FILES
EOT
[ -z "$missing" ] && ok "B all $nfiles manifest files installed under $ROOT, identical, bin/ executable" || bad "B installed files:$missing"
[ -f "$ROOT/conf/tmux-shell.conf" ] && ok "B conf/tmux-shell.conf beside bin/ (\$BIN/../conf resolves)" || bad "B no conf/tmux-shell.conf under the root"
[ -e "$ROOT/bin/fleet-gone.sh" ] && bad "B a copy the manifest no longer lists survived" || ok "B stale fleet-gone.sh removed"
echo "$out" | grep -q 'fleet-gone.sh' && ok "B the removal is said" || bad "B removal not mentioned: $out"
[ -e "$HOME/.local/bin/fleet-connect.py" ] && bad "B the #1470 flat fleet-connect.py survived" || ok "B old flat fleet-connect.py removed from ~/.local/bin"
[ -e "$HOME/.local/bin/fleet-login.py" ] && ok "B a file without our header is left alone" || bad "B someone else's fleet-login.py was removed"
[ -x "$HOME/.local/bin/fleet" ] && [ ! -L "$HOME/.local/bin/fleet" ] && grep -q "exec '$ROOT/bin/fleet'" "$HOME/.local/bin/fleet" \
  && ok "B ~/.local/bin/fleet runs the real one" || bad "B ~/.local/bin/fleet: $(cat "$HOME/.local/bin/fleet" 2>&1)"
url=$(python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));print(d.get("url",""), d.get("token",""))' "$HOME/.config/claude-fleet/hub.json")
[ "$url" = "$HUB keep-me" ] && ok "B hub.json: url written, token kept" || bad "B hub.json: $url"
[ "$(grep -c 'claude-fleet#1470' "$HOME/.zshrc")" = 1 ] && grep -q "$HOME/.local/bin" "$HOME/.zshrc" && ok "B one PATH line in ~/.zshrc" || bad "B zshrc: $(cat "$HOME/.zshrc" 2>&1)"
echo "$out" | grep -q '已安装 fleet' && echo "$out" | grep -q '之后每次只敲：fleet' && ok "B says what to type next" || bad "B output: $out"
# The installed dispatcher works from the sandbox through the runner.
out2=$("$HOME/.local/bin/fleet" --help 2>&1); rc=$?
[ "$rc" = 0 ] && echo "$out2" | grep -q 'fleet login renew' && ok "B installed fleet --help" || bad "B installed fleet: rc=$rc $out2"

# ── C — a second run adds nothing ───────────────────────────────────────────
export PATH="/usr/bin:/bin:/usr/sbin:/sbin"
out=$(sh < "$WORK/install.sh" 2>&1); rc=$?
export PATH=$SAVED_PATH
[ "$rc" = 0 ] && [ "$(grep -c 'claude-fleet#1470' "$HOME/.zshrc")" = 1 ] && ok "C second run: still one PATH line" || bad "C rc=$rc zshrc: $(cat "$HOME/.zshrc")"
echo "$out" | grep -q '去掉了' && bad "C second run removed something: $out" || ok "C second run removes nothing"
# With ~/.local/bin already on PATH, no rc file is touched at all.
rm -f "$HOME/.zshrc"
PATH="$HOME/.local/bin:$PATH" sh < "$WORK/install.sh" >/dev/null 2>&1; rc=$?
[ "$rc" = 0 ] && [ ! -e "$HOME/.zshrc" ] && ok "C PATH already right: rc file untouched" || bad "C rc=$rc zshrc exists: $(cat "$HOME/.zshrc" 2>&1)"

# ── D — refusals ────────────────────────────────────────────────────────────
mkdir -p "$WORK/shim"
printf '#!/bin/sh\necho MSYS_NT-10.0\n' > "$WORK/shim/uname"; chmod +x "$WORK/shim/uname"
out=$(PATH="$WORK/shim:$PATH" sh < "$WORK/install.sh" 2>&1); rc=$?
[ "$rc" = 2 ] && echo "$out" | grep -q WSL && ok "D Windows → exit 2, says WSL" || bad "D windows rc=$rc: $out"
rm -rf "$HOME/.local/bin" "$ROOT"
touch "$WORK/corrupt"
out=$(sh < "$WORK/install.sh" 2>&1); rc=$?
rm -f "$WORK/corrupt"
[ "$rc" = 1 ] && echo "$out" | grep -q '校验不符' && [ ! -e "$HOME/.local/bin/fleet" ] && [ ! -e "$ROOT/bin/fleet" ] \
  && ok "D bad SHA-256 → exit 1, nothing installed" || bad "D corrupt rc=$rc: $out $(ls -R "$ROOT" 2>&1 | head -3)"

# ── E — dispatch from the clean install: fake tmux → the shell; none → connect ─
export PATH="/usr/bin:/bin:/usr/sbin:/sbin"
sh < "$WORK/install.sh" >/dev/null 2>&1 || bad "E reinstall failed"
export PATH=$SAVED_PATH
# A tmux that records its argv and answers like one would to a server that is
# not there: -V 3.4, has-session no, new-session prints a window id.
TM="$WORK/tmux-shim"; mkdir -p "$TM"
cat > "$TM/tmux" <<EOT
#!/bin/sh
printf '%s\\n' "\$*" >> "$WORK/tmux.log"
case " \$* " in
  *" -V "*) echo 'tmux 3.4' ;;
  *" has-session "*) exit 1 ;;
  *" new-session "*) echo '@0' ;;
esac
exit 0
EOT
chmod +x "$TM/tmux"
: > "$WORK/tmux.log"
# --pick against the fake hub fails (it issues no certificate: POST → 501), so
# the shell opens with no machine picked — exactly what a clean install with a
# dead hub does; the server start is what is asserted.
out=$(cd "$HOME" && PATH="$TM:$PATH" FLEET_SHELL_NO_ATTACH=1 "$HOME/.local/bin/fleet" 2>"$WORK/e.err"); rc=$?
[ "$rc" = 0 ] && [ "$out" = fleet-shell ] && ok "E fake tmux: fleet → fleet-shell.sh started the shell server (exit 0, session printed)" \
  || bad "E fake tmux: rc=$rc out='$out' err=$(tail -3 "$WORK/e.err")"
grep -q 'new-session' "$WORK/tmux.log" && ok "E the shell asked tmux for its session" || bad "E tmux log: $(cat "$WORK/tmux.log")"
grep -q -- "-L fleet-shell" "$WORK/tmux.log" && ok "E on its own socket (-L fleet-shell)" || bad "E socket: $(head -3 "$WORK/tmux.log")"
CACHE="$HOME/.cache/claude-fleet/shell"
[ -L "$CACHE/bin/fleet-sidebar.py" ] && [ "$CACHE/bin/fleet-sidebar.py" -ef "$ROOT/bin/fleet-sidebar.py" ] \
  && ok "E the shell's mirror points at the install root's bin/" || bad "E mirror: $(readlink "$CACHE/bin/fleet-sidebar.py" 2>&1)"
grep -q "$CACHE/bin/tmux-status.sh" "$CACHE/tmux.conf" 2>/dev/null && ok "E tmux.conf written from the root's conf/tmux-shell.conf" \
  || bad "E tmux.conf: $(head -3 "$CACHE/tmux.conf" 2>&1)"
grep -q 'set-environment -g FLEET_SIDEBAR_SOURCE .hub.' "$CACHE/tmux.conf" && ok "E the server gets hub mode" || bad "E env in tmux.conf: $(grep set-environment "$CACHE/tmux.conf" | head -3)"
# no tmux at all: a PATH with only what the dispatcher and connect need
NOTMUX="$WORK/notmux"; mkdir -p "$NOTMUX"
for t in sh sed dirname python3 bash env cat ssh ssh-keygen uname; do p=$(command -v "$t") && ln -sf "$p" "$NOTMUX/$t"; done
: > "$WORK/tmux.log"
out=$(cd "$HOME" && PATH="$NOTMUX" FLEET_SHELL_NO_ATTACH=1 "$HOME/.local/bin/fleet" 2>&1 </dev/null); rc=$?
echo "$out" | grep -q 'brew install tmux' && ok "E no tmux: the one install hint" || bad "E no tmux hint: $out"
[ "$(printf '%s\n' "$out" | grep -c 'install tmux')" = 1 ] && ok "E the hint is ONE line" || bad "E hint lines: $out"
[ -s "$WORK/tmux.log" ] && bad "E no tmux: a server was asked for anyway: $(cat "$WORK/tmux.log")" || ok "E no tmux: no server started"
[ "$rc" != 0 ] && ok "E no tmux: went to fleet-connect.py, which the fake hub refused (rc=$rc)" || bad "E no tmux: connect exited 0 against a hub that issues nothing"

# ── F — the tmux step ───────────────────────────────────────────────────────
fnbody() { awk '/^fc_tmux_ok\(\) \{/{p=1} p{print} p&&/^}/{exit}' "$1"; }
lib_fn=$(fnbody "$BIN/fleet-client-lib.sh")
[ -n "$lib_fn" ] && [ "$lib_fn" = "$(fnbody "$BIN/fleet-node-join.sh")" ] \
  && ok "F fleet-node-join.sh's fc_tmux_ok is fleet-client-lib.sh's, byte for byte" || bad "F fc_tmux_ok copies differ"
F="$WORK/f"; FARM="$F/farm"; mkdir -p "$FARM"
for t in sh bash curl python3 ssh ssh-keygen uname tr awk sed mkdir mktemp rm mv chmod dirname basename head tail cat grep od id env pwd cmp true; do
  p=$(type -P "$t") && ln -sf "$p" "$FARM/$t"   # a path, not a builtin
done
# fakes: brew (logs, `install tmux` puts a tmux 3.5a in its own bin, which its
# shellenv puts on PATH), apt-get (logs; install drops tmux into $F/sys), sudo
# (runs the command), and a pre-installed tmux of a given version
mkfake() {  # <dir> <name> <body>
  mkdir -p "$1"; printf '#!/bin/sh\n%s\n' "$3" > "$1/$2"; chmod +x "$1/$2"
}
mktmux() { mkfake "$1" tmux "case \"\$1\" in -V) echo 'tmux $2' ;; esac"; }
mkfake "$F/brew" brew "case \"\$1\" in
  shellenv) echo 'export PATH=\"$F/brewbin:\$PATH\"' ;;
  install) echo \"\$*\" >> '$F/brew.log'; mkdir -p '$F/brewbin'; printf '#!/bin/sh\\necho \"tmux 3.5a\"\\n' > '$F/brewbin/tmux'; chmod +x '$F/brewbin/tmux' ;;
esac"
mkfake "$F/apt" apt-get "echo \"\$*\" >> '$F/apt.log'
case \" \$* \" in *' install '*) mkdir -p '$F/sys'; printf '#!/bin/sh\\necho \"tmux 3.4\"\\n' > '$F/sys/tmux'; chmod +x '$F/sys/tmux' ;; esac"
mkfake "$F/sudo" sudo 'case "$1" in -n) shift ;; esac; exec "$@"'
frun() {  # <extra PATH dirs> <env…> — one install with the tmux step on; output in $out, rc in $rc
  local dirs="$1"; shift
  rm -rf "$F/brewbin" "$F/sys"; : > "$F/brew.log"; : > "$F/apt.log"
  out=$(env PATH="$dirs:$F/sys:$FARM" FLEET_INSTALL_NO_DEPS= FC_BREW_DIRS= "$@" sh < "$WORK/install.sh" 2>&1); rc=$?
}
frun "$F/brew" FC_OS=darwin
[ "$rc" = 0 ] && [ "$(grep -c '^install tmux$' "$F/brew.log")" = 1 ] && echo "$out" | grep -q '^tmux: ok 3.5a' \
  && ok "F macOS + brew, no tmux → brew install tmux once, then ok" || bad "F brew: rc=$rc log=$(cat "$F/brew.log") out=$out"
mkdir -p "$F/nobrew"
frun "$F/nobrew" FC_OS=darwin
[ "$rc" = 0 ] && [ ! -s "$F/brew.log" ] && echo "$out" | grep '^tmux: ' | grep -q 'brew.sh' && echo "$out" | grep '^tmux: ' | grep -q '直连' \
  && ok "F macOS, no brew → one hint (brew.sh, direct way for now), nothing called, exit 0" || bad "F no brew: rc=$rc out=$out"
mktmux "$F/t34" 3.4
frun "$F/t34:$F/brew" FC_OS=darwin
[ "$rc" = 0 ] && [ ! -s "$F/brew.log" ] && echo "$out" | grep -q '^tmux: 3.4 已就绪' \
  && ok "F tmux 3.4 present → nothing installed" || bad "F tmux 3.4: rc=$rc log=$(cat "$F/brew.log") out=$out"
mktmux "$F/t31" 3.1
frun "$F/t31:$F/brew" FC_OS=darwin
[ "$rc" = 0 ] && [ "$(grep -c '^install tmux$' "$F/brew.log")" = 1 ] && echo "$out" | grep -q '3.1 低于 3.2' \
  && ok "F tmux 3.1 counts as none → brew install tmux" || bad "F tmux 3.1: rc=$rc log=$(cat "$F/brew.log") out=$out"
frun "$F/apt" FC_OS=linux FLEET_INSTALL_SUDO="$F/sudo/sudo -n"
[ "$rc" = 0 ] && [ "$(grep -c 'install -y -qq tmux' "$F/apt.log")" = 1 ] && echo "$out" | grep -q '^tmux: ok 3.4' \
  && ok "F Linux + apt-get + passwordless sudo → apt-get install tmux once, then ok" || bad "F apt: rc=$rc log=$(cat "$F/apt.log") out=$out"
if [ "$(id -u)" != 0 ]; then
  frun "$F/apt" FC_OS=linux FLEET_INSTALL_SUDO=
  [ "$rc" = 0 ] && [ ! -s "$F/apt.log" ] && echo "$out" | grep '^tmux: ' | grep -q 'apt-get install -y tmux' \
    && ok "F Linux, no root / sudo → the command to run, apt-get never called" || bad "F no sudo: rc=$rc log=$(cat "$F/apt.log") out=$out"
fi
frun "$F/brew" FC_OS=darwin FLEET_INSTALL_NO_DEPS=1
[ "$rc" = 0 ] && [ ! -s "$F/brew.log" ] && echo "$out" | grep -q '^tmux: skipped' \
  && ok "F FLEET_INSTALL_NO_DEPS=1 → skipped" || bad "F no-deps env: rc=$rc out=$out"
rm -rf "$F/brewbin"; : > "$F/brew.log"
out=$(env PATH="$F/brew:$FARM" FC_OS=darwin FC_BREW_DIRS= sh -s -- --no-deps < "$WORK/install.sh" 2>&1); rc=$?
[ "$rc" = 0 ] && [ ! -s "$F/brew.log" ] && echo "$out" | grep -q '^tmux: skipped (--no-deps)' \
  && ok "F sh -s -- --no-deps → skipped" || bad "F --no-deps: rc=$rc out=$out"

[ "$fail" = 0 ] && echo "PASS fleet-install-selftest" || echo "FAIL fleet-install-selftest"
exit "$fail"
