#!/bin/bash
# fleet-install-selftest.sh — the one-line install (issues #1470, #1486):
# bin/fleet-install.sh, as the hub serves it at /install, against a fake hub
# (stdlib python3 on 127.0.0.1) that serves /install/manifest and
# /install/<path> for every file the manifest lists, with the SHA-256 header the
# real one sends. HOME is a sandbox; nothing is run after the install
# (FLEET_INSTALL_NO_RUN=1) except in leg E, where `fleet` is driven on purpose.
#
# Legs:
#   A. one copy   every manifest path exists in the repo, its generated block
#                 is current and no copy is committed under fleetclient/
#                 (bin/fleet-client-mirror.sh --check — the shell half of the Go
#                 pin, TestFleetClientMatchesBin, #1803); a pack into a sandbox
#                 copy holds exactly those files, byte for byte; the manifest
#                 ships the shell (fleet-shell.sh, conf/tmux-shell.conf)
#   B. install    `curl … | sh` style (the script on stdin, the hub URL filled
#                 in, nobody to ask): every manifest file lands under
#                 ~/.claude/fleet/<path> (the one directory, #1804), identical,
#                 bin/ executable;
#                 ~/.local/bin/fleet is the two-line runner of the real one and
#                 works; a stale copy (an older install's) is removed; the URL
#                 lands in fleet.conf (FLEET_HUB_URL, FLEET_HOST=0 — the
#                 machine's one config file, issue #1623) and hub.json keeps a
#                 token already there; the rc file gets ONE PATH line
#   C. again      a second run changes nothing: no second PATH line
#   D. refusals   a Windows uname → exit 2 with the WSL note; a download whose
#                 SHA-256 does not match → exit 1, nothing installed
#   E. dispatch   from the clean install: with a (fake) tmux ≥ 3.2 on PATH,
#                 `fleet` runs fleet-shell.sh — the server is started from the
#                 install root's own bin/ and conf/; with no tmux, `fleet` prints
#                 the one install hint and exits 1 — no server, no fleet-connect.py
#                 (the client is the only way in, issue #1628)
#   F. tmux       the install's tmux step (issue #1629), on a PATH holding only
#                 what the installer needs plus fakes: macOS + brew + no tmux →
#                 `brew install tmux` once, then ok; no brew → the brew.sh hint,
#                 nothing called, still exit 0; tmux 3.4 → nothing called;
#                 tmux 3.1 counts as none; Linux + apt-get + passwordless sudo →
#                 `apt-get install tmux` once; no root / sudo → the hint only;
#                 --no-deps → skipped. fleet-node-join.sh's copy of fc_tmux_ok is
#                 byte-identical to fleet-client-lib.sh's
#   G. no hub     (issues #1712, #1804) the stable copy (placeholder unfilled),
#                 FLEET_INSTALL_SRC=file://<repo>, no terminal: every manifest
#                 file installed, NO hub address written anywhere, no git, the
#                 one line on adding 承载; the same with --no-hub (one version's
#                 alias); FLEET_INSTALL_HUB=1 with no address → exit 2
#   H. asked      (issue #1804) the two questions on a pseudo-terminal, against
#                 a fake `stable` (a git repo of this tree with a stub bootstrap
#                 and a fake fleet-node.sh): 只看只派 + 接 (Enter, Enter) →
#                 the base, the address, FLEET_HOST=0, no git; again → no file
#                 changes; the answer changed to 承载 → only the 承载 part:
#                 ~/.claude/fleet becomes the checkout in place, the bootstrap
#                 runs once, join + compute on, FLEET_HOST=1; again → nothing;
#                 承载 + 不接 from the stable copy → the checkout, FLEET_HOST=1,
#                 no address, the account hint; again → nothing; the same
#                 answers given ahead (FLEET_INSTALL_HOST=1 FLEET_INSTALL_HUB=0,
#                 no terminal) → the same computer
#   I. two trees  (issue #1804) a computer with the client's
#                 ~/.local/share/claude-fleet beside a ~/.claude/fleet checkout:
#                 after the line only one remains (the old path a symlink to it),
#                 a process running from the old path keeps running; an old
#                 client-update layout (<old> → <old>.versions/<v>) in use is
#                 kept until nothing runs from it, then goes on the next run
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

# ── A — one copy: the manifest names repo files, a build packs them ─────────
if out=$(bash "$BIN/fleet-client-mirror.sh" --check 2>&1); then ok "A every manifest path is in the repo, no copy under fleetclient/"
else bad "A fleet-client-mirror.sh --check: $out"; fi
# the pack (#1803), in a sandbox copy of the repo — never the live tree's pack/
SB="$WORK/packrepo"; SBC="$SB/tokenledger/internal/api/fleetclient"
mkdir -p "$SB/bin" "$SBC/pack"
cp "$REPO/bin/fleet-client-pack.sh" "$SB/bin/"; cp "$MANIFEST" "$SBC/manifest"; printf 'package pack\n' > "$SBC/pack/doc.go"
for f in $(awk '!/^[[:space:]]*#/ && NF { print $1 }' "$MANIFEST"); do mkdir -p "$SB/$(dirname "$f")"; cp "$REPO/$f" "$SB/$f"; done
out=$(bash "$SB/bin/fleet-client-pack.sh" --check 2>&1); rc=$?
[ "$rc" = 1 ] && printf '%s\n' "$out" | grep -q '^not packed: bin/fleet ' && ok "A an empty pack is not packed (--check exit 1)" || bad "A empty pack: rc=$rc $out"
bash "$SB/bin/fleet-client-pack.sh" >/dev/null 2>&1; out=$(bash "$SB/bin/fleet-client-pack.sh" --check 2>&1); rc=$?
n=$(cd "$SBC/pack" && find . -type f ! -name doc.go | wc -l | tr -d ' ')
[ "$rc" = 0 ] && [ "$n" = "$(awk '!/^[[:space:]]*#/ && NF' "$MANIFEST" | wc -l | tr -d ' ')" ] && [ -f "$SBC/pack/doc.go" ] \
  && cmp -s "$SB/bin/fleet" "$SBC/pack/bin/fleet" && ok "A pack: exactly the manifest's $n files, byte for byte, doc.go kept" || bad "A pack: rc=$rc n=$n $out"
echo '# edited' >> "$SB/bin/fleet"
out=$(bash "$SB/bin/fleet-client-pack.sh" --check 2>&1) && bad "A an edit after packing passed --check" \
  || { printf '%s\n' "$out" | grep -q '^stale: pack/bin/fleet ' && ok "A an edit after packing is stale (--check)" || bad "A stale: $out"; }
grep -vx 'bin/fleet-lang.sh' "$SBC/manifest" > "$SBC/m.tmp" && mv "$SBC/m.tmp" "$SBC/manifest"
bash "$SB/bin/fleet-client-pack.sh" >/dev/null 2>&1
[ ! -e "$SBC/pack/bin/fleet-lang.sh" ] && bash "$SB/bin/fleet-client-pack.sh" --check >/dev/null 2>&1 \
  && ok "A a file the manifest dropped leaves the pack" || bad "A a dropped file stayed in the pack"
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
export FLEET_INSTALL_ASK=0     # never ask here, even run from a terminal; leg H asks on a pty
unset FLEET_CONF_DIR FLEET_HUB_URL FLEET_INSTALL_BIN FLEET_INSTALL_HOME FLEET_INSTALL_ROOT FLEET_INSTALL_RC XDG_DATA_HOME XDG_CACHE_HOME \
      FLEET_INSTALL_HOST FLEET_INSTALL_HUB FLEET_INSTALL_NO_HUB FLEET_INSTALL_NO_NODE FLEET_BOOTSTRAP_GIT_BASE
ROOT="$HOME/.claude/fleet"
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
    *) # elsewhere (the Agent configuration package, #1725) a script keeps its #!
       if [ "$(head -c 2 "$REPO/$f")" = '#!' ]; then [ -x "$ROOT/$f" ] || missing="$missing $f(not executable)"
       else [ -x "$ROOT/$f" ] && missing="$missing $f(executable)"; fi ;;
  esac
done <<EOT
$FILES
EOT
[ -z "$missing" ] && ok "B all $nfiles manifest files installed under $ROOT, identical, bin/ + scripts executable" || bad "B installed files:$missing"
[ -f "$ROOT/conf/tmux-shell.conf" ] && ok "B conf/tmux-shell.conf beside bin/ (\$BIN/../conf resolves)" || bad "B no conf/tmux-shell.conf under the root"
[ -e "$ROOT/bin/fleet-gone.sh" ] && bad "B a copy the manifest no longer lists survived" || ok "B stale fleet-gone.sh removed"
echo "$out" | grep -q 'fleet-gone.sh' && ok "B the removal is said" || bad "B removal not mentioned: $out"
[ -e "$HOME/.local/bin/fleet-connect.py" ] && bad "B the #1470 flat fleet-connect.py survived" || ok "B old flat fleet-connect.py removed from ~/.local/bin"
[ -e "$HOME/.local/bin/fleet-login.py" ] && ok "B a file without our header is left alone" || bad "B someone else's fleet-login.py was removed"
[ -x "$HOME/.local/bin/fleet" ] && [ ! -L "$HOME/.local/bin/fleet" ] && grep -q "exec '$ROOT/bin/fleet'" "$HOME/.local/bin/fleet" \
  && ok "B ~/.local/bin/fleet runs the real one" || bad "B ~/.local/bin/fleet: $(cat "$HOME/.local/bin/fleet" 2>&1)"
url=$(python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));print(d.get("url",""), d.get("token",""))' "$HOME/.config/claude-fleet/hub.json")
[ "$url" = " keep-me" ] && ok "B hub.json: token kept, no url" || bad "B hub.json: $url"
grep -qx "export FLEET_HUB_URL=\"$HUB\"" "$HOME/.config/claude-fleet/fleet.conf" 2>/dev/null \
  && grep -qx 'FLEET_HOST=0' "$HOME/.config/claude-fleet/fleet.conf" \
  && ! grep -q 'FLEET_ROLE' "$HOME/.config/claude-fleet/fleet.conf" \
  && ok "B fleet.conf: the hub URL + FLEET_HOST=0 (#1806)" || bad "B fleet.conf: $(cat "$HOME/.config/claude-fleet/fleet.conf" 2>&1)"
[ "$(grep -c 'claude-fleet#1470' "$HOME/.zshrc")" = 1 ] && grep -q "$HOME/.local/bin" "$HOME/.zshrc" && ok "B one PATH line in ~/.zshrc" || bad "B zshrc: $(cat "$HOME/.zshrc" 2>&1)"
echo "$out" | grep -q '已安装 fleet' && echo "$out" | grep -q '之后每次只敲：fleet' && ok "B says what to type next" || bad "B output: $out"
echo "$out" | grep -q '能力: 基础 · 承载 未开 · 入口 接' && ok "B says 能力 in one line (#1806, #1804)" || bad "B no 能力 line: $out"
echo "$out" | grep -q '要承载：再跑一次本命令，或 fleet host on' && ok "B no terminal → the base, and the one line on adding 承载" || bad "B no 承载 hint: $out"
[ ! -e "$ROOT/.git" ] && [ ! -e "$HOME/.local/share/claude-fleet" ] && ok "B one directory, no git" || bad "B layout: $(ls -a "$ROOT" "$HOME/.local/share" 2>&1 | head -5)"
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
# The shell above left detached loops (fleet-shell.sh warm …) whose first act is
# a has-session; let the log go quiet first, or a late one lands in this leg's
# log — a race only the start's own speed decided.
q=0; n=-1
while [ "$q" -lt 20 ]; do
  m=$(wc -c < "$WORK/tmux.log"); [ "$m" = "$n" ] && break; n=$m; q=$((q + 1)); sleep 0.5
done
: > "$WORK/tmux.log"
out=$(cd "$HOME" && PATH="$NOTMUX" FLEET_SHELL_NO_ATTACH=1 "$HOME/.local/bin/fleet" 2>&1 </dev/null); rc=$?
echo "$out" | grep -q 'brew install tmux' && ok "E no tmux: the one install hint" || bad "E no tmux hint: $out"
[ "$(printf '%s\n' "$out" | grep -c 'install tmux')" = 1 ] && ok "E the hint is ONE line" || bad "E hint lines: $out"
[ -s "$WORK/tmux.log" ] && bad "E no tmux: a server was asked for anyway: $(cat "$WORK/tmux.log")" || ok "E no tmux: no server started"
[ "$rc" = 1 ] && ok "E no tmux: exit 1, no fallback" || bad "E no tmux: rc=$rc out=$out"
echo "$out" | grep -q 'fleet connect' && bad "E no tmux: it went to connect: $out" || ok "E no tmux: fleet-connect.py never ran"

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

# ── G — no hub (#1712, #1804): the same script from GitHub's stable ──────────
# The source is this repo over file:// (FLEET_INSTALL_SRC — the raw.githubusercontent
# layout: the manifest at its repo path, each file at its own). Nobody to ask.
SYSPATH="/usr/bin:/bin:/usr/sbin:/sbin:$(dirname "$(command -v git)")"
ginstall() {  # <home> <args…> — the stable copy, no terminal; output in $out, rc in $rc
  local h="$1"; shift
  out=$(env -u FLEET_HUB_URL HOME="$h" XDG_CONFIG_HOME="$h/.config" PATH="$SYSPATH" \
        FLEET_INSTALL_SRC="file://$REPO" FLEET_INSTALL_NO_RUN=1 FLEET_INSTALL_NO_DEPS=1 sh -s -- "$@" < "$BIN/fleet-install.sh" 2>&1); rc=$?
}
GH="$WORK/nohub/home"; mkdir -p "$GH"
ginstall "$GH"
[ "$rc" = 0 ] && ok "G the stable copy (placeholder unfilled), no terminal → exit 0" || bad "G rc=$rc: $out"
GR="$GH/.claude/fleet"; gmiss=''
while IFS= read -r f; do
  [ -n "$f" ] || continue
  cmp -s "$GR/$f" "$REPO/$f" || gmiss="$gmiss $f"
done <<EOT
$FILES
EOT
[ -z "$gmiss" ] && ok "G every manifest file installed from the source, identical" || bad "G files:$gmiss"
gconf="$GH/.config/claude-fleet"
if grep -rqs 'FLEET_HUB_URL\|"url"' "$gconf"; then bad "G a hub address was written: $(grep -rs 'FLEET_HUB_URL\|url' "$gconf")"
else ok "G no hub address anywhere (no fleet.conf FLEET_HUB_URL, no hub.json url)"; fi
[ ! -e "$GR/.git" ] && [ ! -e "$GR/.client-version" ] && ok "G the base: no git, no client version (no hub to ask)" || bad "G layout: $(ls -a "$GR")"
echo "$out" | grep -q '能力: 基础 · 承载 未开 · 入口 不接' && echo "$out" | grep -q '要承载：再跑一次本命令，或 fleet host on' \
  && ok "G says: 能力 基础 · 入口 不接, and how to add 承载" || bad "G output: $out"
GH2="$WORK/nohub2/home"; mkdir -p "$GH2"
ginstall "$GH2" --no-hub
[ "$rc" = 0 ] && [ -f "$GH2/.claude/fleet/bin/fleet" ] && ! grep -rqs FLEET_HUB_URL "$GH2/.config" \
  && ok "G --no-hub (one version's alias of 「不接」) → the same install" || bad "G --no-hub rc=$rc: $out"
GH3="$WORK/nohub3/home"; mkdir -p "$GH3"
out=$(env -u FLEET_HUB_URL HOME="$GH3" XDG_CONFIG_HOME="$GH3/.config" PATH="$SYSPATH" FLEET_INSTALL_HUB=1 FLEET_INSTALL_NO_RUN=1 sh < "$BIN/fleet-install.sh" 2>&1); rc=$?
[ "$rc" = 2 ] && echo "$out" | grep -q 'FLEET_HUB_URL' && [ ! -e "$GH3/.claude/fleet" ] \
  && ok "G 接 asked ahead with no address → exit 2, naming FLEET_HUB_URL, nothing installed" || bad "G hub=1 no url: rc=$rc $out"

# ── H — the two questions, on a pseudo-terminal ─────────────────────────────
# A fake `stable`: this tree's manifest files + bin/fleet-up.sh (the part that
# runs sessions), a bootstrap stub with its own done-marker (as the real one)
# and a fake fleet-node.sh (join → node.env; compute on/off) — so `fleet host on`
# runs for real, against nothing outside the sandbox.
FS="$WORK/fakesrc"; mkdir -p "$FS"
while IFS= read -r f; do
  [ -n "$f" ] || continue; mkdir -p "$FS/$(dirname "$f")"; cp -p "$REPO/$f" "$FS/$f"
done <<EOT
$FILES
EOT
printf '#!/bin/sh\n# the part that runs sessions (fake)\n' > "$FS/bin/fleet-up.sh"
cat > "$FS/bin/fleet-login-bootstrap.sh" <<'EOF'
#!/bin/sh
# fake bootstrap: once, then its marker says so (as the real one's global/bootstrapped)
g="${FLEET_CONF_DIR:-$HOME/.config/claude-fleet}/global"; mkdir -p "$g"
if [ -f "$g/bootstrapped" ]; then echo "fleet-login-bootstrap: already bootstrapped — nothing to do"; exit 0; fi
echo ran >> "$HOME/boot.log"; echo stub > "$g/bootstrapped"
echo "fleet-login-bootstrap: apply: ok — 后台程序 6/6 (fake)"
EOF
cat > "$FS/bin/fleet-node.sh" <<'EOF'
#!/bin/bash
# fake `fleet node` — records each call; join = node.env
CONF="${FLEET_CONF_DIR:-$HOME/.config/claude-fleet}"; ENVF="$CONF/node.env"
echo "$*" >> "$HOME/node-calls"
case "$1 ${2:-}" in
  "join "*) printf 'CCQUOTA_HUB_URL=%s\nCCQUOTA_TOKEN=pass\nCCQUOTA_FLEET_COMPUTE=0\n' "$FAKE_HUB" > "$ENVF"; chmod 600 "$ENVF"; echo "✓ 已上线（fake）" ;;
  "compute on") sed -i.x 's/^CCQUOTA_FLEET_COMPUTE=.*/CCQUOTA_FLEET_COMPUTE=1/' "$ENVF"; rm -f "$ENVF.x"; echo "✓ 已打开（fake）" ;;
  "compute status") echo "已打开" ;;
esac
EOF
chmod +x "$FS/bin/fleet-up.sh" "$FS/bin/fleet-login-bootstrap.sh" "$FS/bin/fleet-node.sh"
GB="$WORK/gitbase/verkyyi"; mkdir -p "$GB"
( cd "$FS" && git init -q && git add -A && git -c user.name=t -c user.email=t@t commit -qm stable && git tag stable \
  && git clone -q --bare "$FS" "$GB/claude-fleet.git" ) || bad "H the fake stable repo"
# a tmux the host step finds (≥ 3.2), and nothing else faked
FT="$WORK/faketmux"; mkdir -p "$FT"; printf '#!/bin/sh\necho "tmux 3.4"\n' > "$FT/tmux"; chmod +x "$FT/tmux"
cat > "$WORK/ptydrive.py" <<'PYEOF'
# ptydrive.py <answers> <script> [args…] — `cat <script> | sh -s -- args` with a
# pseudo-terminal as its /dev/tty; each prompt (ends «› ») gets the next answer
# ('' = Enter). Answers are comma-separated, '-' = none. A prompt with no answer
# left fails the run. Prints the whole transcript; exits with the child's code.
import os, pty, select, sys, time
ans = [] if sys.argv[1] == "-" else sys.argv[1].split(",")
pid, fd = pty.fork()
if pid == 0:
    os.execvp("sh", ["sh", "-c", 'cat "$0" | sh -s -- "$@"'] + sys.argv[2:])
buf, sent, end = b"", 0, time.time() + 180
while time.time() < end:
    r, _, _ = select.select([fd], [], [], 0.2)
    if r:
        try:
            d = os.read(fd, 4096)
        except OSError:
            break
        if not d:
            break
        buf += d
        n = buf.count("› ".encode())
        while sent < n:
            if sent >= len(ans):
                sys.stdout.write(buf.decode("utf-8", "replace") + "\n[pty: a prompt with no answer left]\n")
                os.kill(pid, 9); os.waitpid(pid, 0); sys.exit(99)
            os.write(fd, (ans[sent] + "\r").encode()); sent += 1
_, st = os.waitpid(pid, 0)
sys.stdout.write(buf.decode("utf-8", "replace").replace("\r\n", "\n"))
if sent < len(ans):
    sys.stdout.write("\n[pty: %d answer(s) never asked for]\n" % (len(ans) - sent)); sys.exit(98)
sys.exit(os.WEXITSTATUS(st) if os.WIFEXITED(st) else 97)
PYEOF
# hinstall <home> <answers> <script> [env…] — one install on the pty; $out, $rc
hinstall() {
  local h="$1" a="$2" sc="$3"; shift 3
  out=$(env -i HOME="$h" PATH="$FT:$SYSPATH" SHELL=/bin/zsh TMPDIR="$WORK" FAKE_HUB="$HUB" \
        FLEET_INSTALL_SRC="file://$REPO" FLEET_BOOTSTRAP_GIT_BASE="file://$WORK/gitbase" \
        FLEET_INSTALL_NO_RUN=1 FLEET_INSTALL_NO_DEPS=1 FLEET_INSTALL_NO_AGENTS=1 "$@" \
        python3 -I "$WORK/ptydrive.py" "$a" "$sc" 2>&1); rc=$?
}
# hsnap <home> — every file but the git internals, with its checksum
hsnap() { (cd "$1" && find . -path ./.claude/fleet/.git -prune -o -type f -print | LC_ALL=C sort | while IFS= read -r f; do printf '%s %s\n' "$(cksum < "$f")" "$f"; done); }
hval() { sed -n "s/^[[:space:]]*\(export[[:space:]]\{1,\}\)\{0,1\}$2=//p" "$1/.config/claude-fleet/fleet.conf" 2>/dev/null | tail -n 1 | tr -d "\"' "; }

# H1 只看只派 + 接: Enter, Enter (the hub's copy: 接 is the default)
H1="$WORK/h1/home"; mkdir -p "$H1"
hinstall "$H1" "," "$WORK/install.sh" FLEET_INSTALL_NO_NODE=1
[ "$rc" = 0 ] && ok "H1 view + hub on a pty → exit 0" || bad "H1 rc=$rc: $out"
echo "$out" | grep -q '这台电脑要做什么？' && echo "$out" | grep -q '1 只看、只派 *推荐' && echo "$out" | grep -q '接入口吗？' \
  && echo "$out" | grep -q "命令是从入口复制来的" && ok "H1 both questions asked, 只看只派 recommended, 接 because the line came from the hub" || bad "H1 prompts: $out"
[ -f "$H1/.claude/fleet/bin/fleet" ] && [ ! -e "$H1/.claude/fleet/.git" ] && [ "$(hval "$H1" FLEET_HUB_URL)" = "$HUB" ] && [ "$(hval "$H1" FLEET_HOST)" = 0 ] \
  && ok "H1 the base in ~/.claude/fleet, the address written, FLEET_HOST=0" || bad "H1 state: host=$(hval "$H1" FLEET_HOST) hub=$(hval "$H1" FLEET_HUB_URL) $(ls -a "$H1/.claude/fleet" | head -3)"
before=$(hsnap "$H1"); hinstall "$H1" "," "$WORK/install.sh" FLEET_INSTALL_NO_NODE=1
[ "$rc" = 0 ] && [ "$before" = "$(hsnap "$H1")" ] && ok "H1 again (Enter, Enter) → not one file changes" \
  || bad "H1 again rc=$rc: $(diff <(printf '%s\n' "$before") <(hsnap "$H1") | head -5) $out"
# H2 the answer changed: 承载 (2, confirm, Enter = 接)
hinstall "$H1" "2,," "$WORK/install.sh"
[ "$rc" = 0 ] && ok "H2 view → 承载 on a pty → exit 0" || bad "H2 rc=$rc: $out"
echo "$out" | grep -q '承载要多装这些' && echo "$out" | grep -q 'git、tmux' && echo "$out" | grep -q '后台程序' \
  && ok "H2 承载 lists what it adds (git, tmux, 后台程序) and asks once more" || bad "H2 plan: $out"
[ -d "$H1/.claude/fleet/.git" ] && [ -f "$H1/.claude/fleet/bin/fleet-up.sh" ] && [ ! -e "$H1/.local/share/claude-fleet" ] \
  && [ -z "$(ls -d "$H1/.claude/fleet".* 2>/dev/null)" ] \
  && ok "H2 ~/.claude/fleet became the stable checkout in place — still one directory" || bad "H2 layout: $(ls -a "$H1/.claude" "$H1/.local/share" 2>&1)"
[ "$(cat "$H1/boot.log" 2>/dev/null)" = ran ] && [ "$(tr '\n' '|' < "$H1/node-calls" 2>/dev/null)" = "join|compute on|" ] \
  && [ "$(hval "$H1" FLEET_HOST)" = 1 ] && [ "$(hval "$H1" FLEET_HUB_URL)" = "$HUB" ] \
  && ok "H2 only the 承载 part: the setup once, join + compute on, FLEET_HOST=1, the address kept" \
  || bad "H2 boot=$(cat "$H1/boot.log" 2>&1) calls=$(cat "$H1/node-calls" 2>&1) host=$(hval "$H1" FLEET_HOST): $out"
echo "$out" | grep -q '去掉了' && bad "H2 something was removed: $out" || ok "H2 nothing removed"
echo "$out" | grep -q '能力: 基础 · 承载 已开 · 入口 接' && ok "H2 says 能力 基础 · 承载 已开 · 入口 接" || bad "H2 能力: $out"
before=$(hsnap "$H1"); hinstall "$H1" "," "$WORK/install.sh"
[ "$rc" = 0 ] && [ "$before" = "$(hsnap "$H1")" ] && echo "$out" | grep -q '承载: 已开，不重装' \
  && ok "H2 again (Enter = what it answered) → nothing changes, no setup, no join" \
  || bad "H2 again rc=$rc: $(diff <(printf '%s\n' "$before") <(hsnap "$H1") | head -5) $out"
# H3 承载 + 不接, from the stable copy (no address: 不接 is the default)
H3="$WORK/h3/home"; mkdir -p "$H3"
hinstall "$H3" "2,2," "$BIN/fleet-install.sh"
[ "$rc" = 0 ] && [ -d "$H3/.claude/fleet/.git" ] && [ "$(hval "$H3" FLEET_HOST)" = 1 ] && [ -z "$(hval "$H3" FLEET_HUB_URL)" ] \
  && [ "$(cat "$H3/boot.log" 2>/dev/null)" = ran ] && [ ! -e "$H3/node-calls" ] \
  && ok "H3 承载 + 不接 → the checkout, the setup once, FLEET_HOST=1, no address, no hub call" \
  || bad "H3 rc=$rc host=$(hval "$H3" FLEET_HOST) hub=$(hval "$H3" FLEET_HUB_URL): $out"
echo "$out" | grep -q '2 不接（单机） *推荐' && echo "$out" | grep -q 'claude setup-token' && echo "$out" | grep -q '能力: 基础 · 承载 已开 · 入口 不接' \
  && ok "H3 不接 recommended with no address; the account hint; 能力 says so" || bad "H3 output: $out"
before=$(hsnap "$H3"); hinstall "$H3" "," "$BIN/fleet-install.sh"
[ "$rc" = 0 ] && [ "$before" = "$(hsnap "$H3")" ] && ok "H3 again → nothing changes" \
  || bad "H3 again rc=$rc: $(diff <(printf '%s\n' "$before") <(hsnap "$H3") | head -5) $out"
# H4 the same answers given ahead, no terminal → the same computer
H4="$WORK/h4/home"; mkdir -p "$H4"
out=$(env -i HOME="$H4" PATH="$FT:$SYSPATH" SHELL=/bin/zsh TMPDIR="$WORK" FLEET_INSTALL_SRC="file://$REPO" \
      FLEET_BOOTSTRAP_GIT_BASE="file://$WORK/gitbase" FLEET_INSTALL_NO_RUN=1 FLEET_INSTALL_NO_DEPS=1 FLEET_INSTALL_NO_AGENTS=1 \
      FLEET_INSTALL_HOST=1 FLEET_INSTALL_HUB=0 sh < "$BIN/fleet-install.sh" 2>&1); rc=$?
layout() { (cd "$1" && find . -path ./.claude/fleet/.git -prune -o -type f -print | grep -v -e '/host-install.log$' | LC_ALL=C sort); }
[ "$rc" = 0 ] && [ "$(layout "$H4")" = "$(layout "$H3")" ] && [ "$(hval "$H4" FLEET_HOST)" = 1 ] && [ -z "$(hval "$H4" FLEET_HUB_URL)" ] \
  && ok "H4 FLEET_INSTALL_HOST=1 FLEET_INSTALL_HUB=0 → the computer H3's answers made" \
  || bad "H4 rc=$rc: $(diff <(layout "$H3") <(layout "$H4") | head -5) $out"

# ── I — two trees on one computer → one ─────────────────────────────────────
I1="$WORK/i1/home"; mkdir -p "$I1/.claude"
git clone -q "$WORK/gitbase/verkyyi/claude-fleet.git" "$I1/.claude/fleet" 2>/dev/null || bad "I the checkout"
OLDT="$I1/.local/share/claude-fleet"
env -i HOME="$I1" PATH="$SYSPATH" SHELL=/bin/zsh TMPDIR="$WORK" FLEET_INSTALL_HOME="$OLDT" FLEET_INSTALL_NO_RUN=1 FLEET_INSTALL_ASK=0 \
  FLEET_INSTALL_NO_DEPS=1 FLEET_INSTALL_NO_AGENTS=1 FLEET_INSTALL_NO_NODE=1 sh < "$WORK/install.sh" >/dev/null 2>&1 || bad "I the old client tree"
# a client running from the old tree: a script there that keeps using a sibling by path
printf '#!/bin/sh\nwhile :; do [ -f "%s/bin/fleet" ] || exit 1; sleep 0.1; done\n' "$OLDT" > "$OLDT/bin/zz-running.sh"
sh "$OLDT/bin/zz-running.sh" & RUNPID=$!
sleep 0.3
out=$(env -i HOME="$I1" PATH="$SYSPATH" SHELL=/bin/zsh TMPDIR="$WORK" FLEET_INSTALL_NO_RUN=1 FLEET_INSTALL_NO_DEPS=1 \
      FLEET_INSTALL_NO_AGENTS=1 FLEET_INSTALL_NO_NODE=1 FLEET_INSTALL_ASK=0 sh < "$WORK/install.sh" 2>&1); rc=$?
sleep 0.5
[ "$rc" = 0 ] && [ -L "$OLDT" ] && [ "$OLDT" -ef "$I1/.claude/fleet" ] && [ -z "$(ls -d "$OLDT".* 2>/dev/null)" ] \
  && ok "I one tree left: the old path is a symlink to ~/.claude/fleet, its files gone" || bad "I rc=$rc: $(ls -la "$I1/.local/share" 2>&1) $out"
kill -0 "$RUNPID" 2>/dev/null && ok "I a process running from the old path keeps running" || bad "I the running client died"
kill "$RUNPID" 2>/dev/null; wait "$RUNPID" 2>/dev/null
[ -d "$I1/.claude/fleet/.git" ] && echo "$out" | grep -q '已是完整安装' && ! echo "$out" | grep -q '去掉了' \
  && ok "I the checkout is left as it is (nothing downloaded over it, nothing removed)" || bad "I checkout: $out"
grep -q "exec '$I1/.claude/fleet/bin/fleet'" "$I1/.local/bin/fleet" && ok "I ~/.local/bin/fleet runs the one directory's" || bad "I runner: $(cat "$I1/.local/bin/fleet")"
# the client-update layout: <old> → <old>.versions/<v>, still in use
rm -f "$OLDT"; mkdir -p "$OLDT.versions/v1/bin"; cp "$REPO/bin/fleet" "$OLDT.versions/v1/bin/"; ln -s "$OLDT.versions/v1" "$OLDT"
sh -c 'sleep 30; :' "$OLDT.versions/v1/bin/x" & RUNPID=$!   # `; :` — no exec: the path stays in its argv
sleep 0.3
out=$(env -i HOME="$I1" PATH="$SYSPATH" SHELL=/bin/zsh TMPDIR="$WORK" FLEET_INSTALL_NO_RUN=1 FLEET_INSTALL_NO_DEPS=1 \
      FLEET_INSTALL_NO_AGENTS=1 FLEET_INSTALL_NO_NODE=1 FLEET_INSTALL_ASK=0 sh < "$WORK/install.sh" 2>&1); rc=$?
[ "$rc" = 0 ] && [ "$OLDT" -ef "$I1/.claude/fleet" ] && [ -d "$OLDT.versions/v1" ] && echo "$out" | grep -q '还有程序在用' \
  && ok "I old versions still in use → the link moves, the versions are kept and said" || bad "I versions in use rc=$rc: $out"
kill "$RUNPID" 2>/dev/null; wait "$RUNPID" 2>/dev/null
out=$(env -i HOME="$I1" PATH="$SYSPATH" SHELL=/bin/zsh TMPDIR="$WORK" FLEET_INSTALL_NO_RUN=1 FLEET_INSTALL_NO_DEPS=1 \
      FLEET_INSTALL_NO_AGENTS=1 FLEET_INSTALL_NO_NODE=1 FLEET_INSTALL_ASK=0 sh < "$WORK/install.sh" 2>&1); rc=$?
[ "$rc" = 0 ] && [ ! -e "$OLDT.versions" ] && ok "I …and go on the next run once nothing runs from them" || bad "I versions left: rc=$rc $(ls "$I1/.local/share") $out"

[ "$fail" = 0 ] && echo "PASS fleet-install-selftest" || echo "FAIL fleet-install-selftest"
exit "$fail"
