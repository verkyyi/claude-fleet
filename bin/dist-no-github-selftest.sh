#!/bin/bash
# dist-no-github-selftest.sh — GitHub unreachable, and every install still moves
# to the new version (issue #2776, EPIC #2770 C6). BREAK-IT row `dist-no-github`.
#
# CI cannot edit /etc/hosts, so GitHub is made a black hole with the two knobs
# every fetcher here honours, in a sandbox HOME:
#   git   url.http://127.0.0.1:<rec>/<host>/.insteadOf=https://<host>/ (and the
#         ssh form) in $HOME/.gitconfig — every github host, every remote
#   curl  a proxy at 127.0.0.1:<rec> (https_proxy / HTTPS_PROXY / ALL_PROXY and
#         $HOME/.curlrc — a demoted run sees no env, it still reads its HOME),
#         NO_PROXY=127.0.0.1,localhost so the fake hub is reached directly
# The recorder at <rec> answers 502 to everything and writes down who asked:
# a line naming a github host is one GitHub reach (`hits`). A fake hub on
# 127.0.0.1 is the only source that answers: /version, /v1/fleet/release/stable
# (+ /key), /install and /install/stable/<sha>/<path> (the real installer and the
# client manifest's files from this checkout); a fake `ccquota release fetch`
# hands out the hub's signed release (verifying is ccquota's, Go-tested).
#
# The fixture fleet: a repo whose bin/ is this checkout's bin/ by symlink, with
# stubs for apply / doctor / diskguard / fleet-up, and a DIST-MARK file — A, B.
# A is installed; the hub's stable is B. Each leg runs the REAL script:
#   install-sync  bin/fleet-install-sync.sh on a login install at A whose origin
#                 is GitHub (as on every machine today), FLEET_HUB_URL set
#   client        bin/fleet-client-update.sh stage, a client at A, hub = the fake
#   bootstrap     bin/fleet-login-bootstrap.sh in a fresh HOME on a managed
#                 machine (FLEET_NODE_ROOT/current = B), no bootstrap cache
#   node-follow   bin/fleet-node-update.py follow <login> (FLEET_NODE_TEST=1):
#                 the release's install-sync for a managed login at A
# A leg is GREEN when the install reads DIST-MARK=B AND the recorder saw no
# GitHub host while it ran. Otherwise RED, with the hits and the last lines.
#
# Red first (#1786): the members that make a leg green are not merged when this
# lands, so DIST_AWAIT names, per leg, the member it waits for. A RED leg on the
# list prints `AWAIT` and does not fail; a GREEN leg still on the list FAILS
# («drop it from DIST_AWAIT») — the ratchet: the member that greens a leg takes
# it off the list in its own PR, and the list ends empty. --strict ignores the
# list (the batch-end verdict, and the red-first evidence).
#
# Usage: dist-no-github-selftest.sh [--strict] [<leg> …]   (default: every leg)
# Exit 0 = every leg green or awaited · 1 = a leg red (not awaited) or a stale
# await · SKIP (exit 0) without git / python3 / curl. DIST_KEEP=1 keeps $WORK.
set -uo pipefail

# leg:member — the leg is red until that member merges; remove the entry then.
DIST_AWAIT="install-sync:C3#2773 bootstrap:C5#2775 node-follow:C4#2774"

BIN="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$BIN/.." && pwd)"
for t in git python3 curl; do
  command -v "$t" >/dev/null 2>&1 || { printf 'dist-no-github: %s absent — SKIP\n' "$t"; exit 0; }
done
STRICT=0 LEGS=''
for a in "$@"; do
  case "$a" in
    --strict) STRICT=1 ;;
    install-sync|client|bootstrap|node-follow) LEGS="$LEGS $a" ;;
    *) printf 'dist-no-github: unknown arg %s\n' "$a" >&2; exit 2 ;;
  esac
done
[ -n "$LEGS" ] || LEGS="install-sync client bootstrap node-follow"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/dist-nogh.XXXXXX")" || exit 2
WORK="$(cd "$WORK" && pwd -P)"
SRV_PID=''
cleanup() {
  [ -n "$SRV_PID" ] && kill "$SRV_PID" 2>/dev/null
  [ -n "${DIST_KEEP:-}" ] && { printf 'kept %s\n' "$WORK" >&2; return; }
  rm -rf "$WORK"
}
trap cleanup EXIT
trap 'exit 130' INT TERM HUP

export GIT_CONFIG_SYSTEM=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
GH_HOSTS="github.com api.github.com codeload.github.com raw.githubusercontent.com objects.githubusercontent.com"

# ------------------------------------------------------------ the fixture fleet
SEED="$WORK/seed"
mkdir -p "$SEED/bin" "$WORK/rel" "$WORK/fakebin"
git init -q -b master "$SEED"
for f in "$BIN"/*; do ln -s "$f" "$SEED/bin/${f##*/}"; done
stub() { rm -f "$SEED/bin/$1"; cat > "$SEED/bin/$1"; chmod +x "$SEED/bin/$1"; }
stub fleet-install-apply.sh <<'EOF'
#!/bin/bash
echo 'apply: ok — dist fixture'
EOF
stub fleet-doctor.sh <<'EOF'
#!/bin/sh
echo '  PASS  gh       ok'
EOF
stub fleet-diskguard.sh <<'EOF'
#!/bin/sh
exit 0
EOF
stub fleet-up.sh <<'EOF'
#!/bin/sh
exit 0
EOF
mark() { printf '%s\n' "$1" > "$SEED/DIST-MARK"; git -C "$SEED" add -A; git -C "$SEED" commit -qm "dist $1"; git -C "$SEED" rev-parse HEAD; }
A=$(mark A); B=$(mark B)
# the hub's release store: <sha>/ as `ccquota release fetch` leaves it
for s in "$A" "$B"; do
  mkdir -p "$WORK/rel/$s/.release"
  git -C "$SEED" archive "$s" | tar -x -C "$WORK/rel/$s"
done
printf '{"schema": 1, "sha": "%s", "prev": "", "seq": 1, "artifacts": []}\n' "$A" > "$WORK/rel/$A/.release/manifest.json"
printf '{"schema": 1, "sha": "%s", "prev": "%s", "seq": 2, "artifacts": []}\n' "$B" "$A" > "$WORK/rel/$B/.release/manifest.json"
printf '%s\n' "$B" > "$WORK/rel/stable"

# ccquota release fetch --hub H --pubkey P [--artifacts] [--platform X] <ref> <dir>
cat > "$WORK/fakebin/ccquota" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$WORK/ccquota.log"
[ "\$1 \$2" = "release fetch" ] || { echo "fake ccquota: only release fetch" >&2; exit 2; }
shift 2; ref='' dir=''
while [ \$# -gt 0 ]; do
  case "\$1" in
    --hub|--pubkey|--platform|--from) shift 2 ;;
    --*) shift ;;
    *) if [ -z "\$ref" ]; then ref=\$1; else dir=\$1; fi; shift ;;
  esac
done
[ "\$ref" = stable ] && ref=\$(cat "$WORK/rel/stable")
[ -d "$WORK/rel/\$ref" ] && [ -n "\$dir" ] || { echo "fake ccquota: no release \$ref" >&2; exit 1; }
mkdir -p "\$dir" && cp -R "$WORK/rel/\$ref/." "\$dir/"
EOF
chmod +x "$WORK/fakebin/ccquota"

# ------------------------------------------------- the recorder + the fake hub
cat > "$WORK/srv.py" <<'PY'
import hashlib, json, os, sys, threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

work, repo = sys.argv[1:3]


def log(name, line):
    with open(os.path.join(work, name), "a") as f:
        f.write(line + "\n")


class Rec(BaseHTTPRequestHandler):
    """The black hole: every request is written down, every answer is 502."""
    def any(self):
        log("hits.log", "%s %s host=%s" % (self.command, self.path, self.headers.get("Host", "")))
        self.send_response(502)
        self.send_header("Content-Length", "0")
        self.end_headers()
    do_GET = do_POST = do_HEAD = do_CONNECT = do_PUT = any

    def log_message(self, *a):
        pass


class Hub(BaseHTTPRequestHandler):
    def send(self, code, body, ctype="application/json", sha=False):
        if isinstance(body, str):
            body = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        if sha:
            self.send_header("X-Ccquota-Sha256", hashlib.sha256(body).hexdigest())
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        log("hub.log", self.path)
        host = "http://%s" % self.headers.get("Host")
        p = self.path.split("?")[0]
        stable = open(os.path.join(work, "rel", "stable")).read().strip()
        if p == "/version":
            return self.send(200, json.dumps({
                "commit": "hub-image", "stable": stable, "client_version": stable,
                "client_compat": 1, "min_client_compat": 0,
                "client_url": "%s/install/stable/%s" % (host, stable)}))
        if p == "/v1/fleet/release/stable":
            return self.send(200, open(os.path.join(work, "rel", stable, ".release", "manifest.json")).read())
        if p == "/v1/fleet/release/key":
            return self.send(200, "ed25519 AAAA-dist-fixture\n", "text/plain")
        if p == "/install":
            return self.send(200, open(os.path.join(repo, "bin", "fleet-install.sh")).read(), "text/plain")
        pre = "/install/stable/%s/" % stable
        if p.startswith(pre):
            rel = p[len(pre):]
            if rel.startswith("bundle"):
                return self.send(404, "")
            # never realpath: the selftest gate's shadow root links bin/ and the
            # rest out of the root (selftest-shadow-root.sh)
            f = os.path.join(repo, rel)
            if rel and not rel.startswith("/") and ".." not in rel.split("/") and os.path.isfile(f):
                return self.send(200, open(f, "rb").read(), "application/octet-stream", sha=True)
        return self.send(404, "")

    def log_message(self, *a):
        pass


rec = ThreadingHTTPServer(("127.0.0.1", 0), Rec)
hub = ThreadingHTTPServer(("127.0.0.1", 0), Hub)
for s in (rec, hub):
    threading.Thread(target=s.serve_forever, daemon=True).start()
with open(os.path.join(work, "ports.tmp"), "w") as f:
    f.write("%d %d\n" % (rec.server_address[1], hub.server_address[1]))
os.rename(os.path.join(work, "ports.tmp"), os.path.join(work, "ports"))
threading.Event().wait()
PY
python3 "$WORK/srv.py" "$WORK" "$REPO" 2>"$WORK/srv.err" &
SRV_PID=$!
for _ in $(seq 1 100); do [ -s "$WORK/ports" ] && break; sleep 0.05; done
[ -s "$WORK/ports" ] || { printf 'dist-no-github: the fake hub did not start: %s\n' "$(tail -2 "$WORK/srv.err")" >&2; exit 1; }
read -r RECP HUBP < "$WORK/ports"
HUB="http://127.0.0.1:$HUBP"
REC="http://127.0.0.1:$RECP"

# blackhole <home> — GitHub is a black hole for git and curl run with this HOME
blackhole() {
  local h="$1" host
  mkdir -p "$h"
  : > "$h/.gitconfig"
  for host in $GH_HOSTS; do
    git config --file "$h/.gitconfig" --add "url.$REC/$host/.insteadOf" "https://$host/"
    git config --file "$h/.gitconfig" --add "url.$REC/$host/.insteadOf" "git@$host:"
  done
  git config --file "$h/.gitconfig" http.proxy "$REC"
  printf 'proxy = "%s"\nnoproxy = "127.0.0.1,localhost"\n' "$REC" > "$h/.curlrc"
}
export https_proxy="$REC" HTTPS_PROXY="$REC" http_proxy="$REC" HTTP_PROXY="$REC" ALL_PROXY="$REC" all_proxy="$REC"
export NO_PROXY=127.0.0.1,localhost no_proxy=127.0.0.1,localhost
blackhole "$WORK/probe"
# the black hole holds: a GitHub clone and a GitHub API call both fail, and are seen
HOME="$WORK/probe" GIT_TERMINAL_PROMPT=0 git ls-remote https://github.com/verkyyi/claude-fleet.git >/dev/null 2>&1 \
  && { printf 'dist-no-github: the black hole leaks — git reached github.com\n' >&2; exit 1; }
HOME="$WORK/probe" curl -fsS --max-time 5 https://api.github.com/ >/dev/null 2>&1 \
  && { printf 'dist-no-github: the black hole leaks — curl reached api.github.com\n' >&2; exit 1; }
[ "$(grep -c 'github' "$WORK/hits.log" 2>/dev/null)" -ge 2 ] \
  || { printf 'dist-no-github: the recorder did not see the probe: [%s]\n' "$(cat "$WORK/hits.log" 2>/dev/null)" >&2; exit 1; }
: > "$WORK/hits.log"

# the tmux shim install-sync's busy check reads: no session, nothing running
cat > "$WORK/fakebin/tmux" <<'EOF'
#!/bin/sh
exit 1
EOF
chmod +x "$WORK/fakebin/tmux"

# gh_hits — the GitHub reaches the recorder saw since the last reset
gh_hits() { grep -E 'github' "$WORK/hits.log" 2>/dev/null | sort | uniq -c | sed 's/^ *//' | tr '\n' ';'; }
mark_of() { cat "$1/DIST-MARK" 2>/dev/null | head -1; }

# ------------------------------------------------------------------- the legs
# Each sets WHY (red) or nothing (green); OUT holds the last lines it printed.

leg_install_sync() {
  local h="$WORK/is" co conf
  blackhole "$h"; conf="$h/.config/claude-fleet"
  mkdir -p "$conf/fleets/f1" "$h/.claude"
  printf 'FLEET_REPO=o/r\n' > "$conf/fleets/f1/conf"
  printf 'ed25519 AAAA-dist-fixture\n' > "$conf/release.pub"
  co="$h/.claude/fleet"
  git clone -q "$SEED" "$co" && git -C "$co" reset -q --hard "$A" \
    && git -C "$co" remote set-url origin https://github.com/verkyyi/claude-fleet.git \
    || { WHY="fixture: cannot clone the seed"; return; }
  OUT=$(HOME="$h" FLEET_CONF_DIR="$conf" TMPDIR="$WORK" PATH="$WORK/fakebin:$PATH" \
    FLEET_HUB_URL="$HUB" FLEET_SKIP_GLOBAL_CONF=1 FLEET_INSTALL_SYNC_HOST=1 FLEET_NODE_FOLLOW=0 \
    GIT_TERMINAL_PROMPT=0 bash "$BIN/fleet-install-sync.sh" --root "$co" 2>&1 | tail -3)
  [ "$(mark_of "$co")" = B ] || WHY="the install reads $(mark_of "$co") — $(sed -n 's/^result: //p;s/^reason: //p' "$conf/global/install-sync.state" 2>/dev/null | tr '\n' ' ')"
}

leg_client() {
  local h="$WORK/cl" root conf v
  blackhole "$h"; conf="$h/.config/claude-fleet"; root="$h/.local/share/claude-fleet"
  mkdir -p "$conf" "$root/bin"
  cp "$BIN/fleet-client-update.sh" "$BIN/fleet-versions-lib.sh" "$root/bin/"
  printf '#!/bin/sh\necho client A\n' > "$root/bin/fleet"; chmod +x "$root/bin/fleet"
  printf 'version=%s\ncompat=1\ncommit=%.7s\nhub=%s\nat=1\n' "$A" "$A" "$HUB" > "$root/.client-version"
  printf 'A\n' > "$root/DIST-MARK"
  OUT=$(HOME="$h" XDG_CONFIG_HOME="$h/.config" XDG_CACHE_HOME="$h/.cache" XDG_DATA_HOME="$h/.local/share" \
    FLEET_CONF_DIR="$conf" TMPDIR="$WORK" FLEET_HUB_URL="$HUB" FLEET_CLIENT_ROOT="$root" \
    bash "$root/bin/fleet-client-update.sh" stage "$B" 2>&1 | tail -3)
  v=$(cat "$root.versions/.next" 2>/dev/null)
  if [ -z "$v" ] || [ ! -f "$root.versions/$v/bin/fleet" ]; then
    WHY="nothing staged ($(printf '%s' "$OUT" | tail -1))"
  elif ! grep -q "^version=$B" "$root.versions/$v/.client-version" 2>/dev/null; then
    WHY="staged $(sed -n 's/^version=//p' "$root.versions/$v/.client-version" 2>/dev/null), not $B"
  fi
}

leg_bootstrap() {
  local h="$WORK/bs" conf nroot
  blackhole "$h"; conf="$h/.config/claude-fleet"; nroot="$WORK/node-bs"
  mkdir -p "$nroot" "$WORK/fakebin-bs"
  cp -R "$WORK/rel/$B" "$nroot/$B"; ln -s "$nroot/$B" "$nroot/current"
  printf '#!/bin/sh\necho "2.1.1 (Claude Code)"\n' > "$WORK/fakebin-bs/claude"; chmod +x "$WORK/fakebin-bs/claude"
  OUT=$(HOME="$h" FLEET_CONF_DIR="$conf" TMPDIR="$WORK" PATH="$WORK/fakebin-bs:$WORK/fakebin:$PATH" \
    FLEET_HUB_URL="$HUB" FLEET_SKIP_GLOBAL_CONF=1 FLEET_NODE_ROOT="$nroot" FLEET_NODE_RUNTIME="$nroot/current" \
    FLEET_BOOTSTRAP_CACHE=off FLEET_CLAUDE_INSTALL_CMD=true FLEET_INSTALL_PLATFORM=none \
    GIT_TERMINAL_PROMPT=0 bash "$BIN/fleet-login-bootstrap.sh" 2>&1 | grep -E 'install|FAIL' | tail -3)
  [ "$(mark_of "$h/.claude/fleet")" = B ] || WHY="the new login's install reads [$(mark_of "$h/.claude/fleet")]: $(printf '%s' "$OUT" | grep -m1 'install')"
}

leg_node_follow() {
  local d="$WORK/nf" home co me
  me=$(id -un)
  home="$d/Users/$me"; co="$home/.claude/fleet"
  mkdir -p "$d/root" "$d/db" "$d/log" "$d/LaunchDaemons"
  blackhole "$home"
  cp -R "$WORK/rel/$B" "$d/root/$B"; ln -s "$d/root/$B" "$d/root/current"
  mkdir -p "$home/.config/claude-fleet/fleets/f1"
  printf 'FLEET_REPO=o/r\n' > "$home/.config/claude-fleet/fleets/f1/conf"
  printf 'ed25519 AAAA-dist-fixture\n' > "$d/db/release.pub"
  printf 'CCQUOTA_HUB_URL=%s\n' "$HUB" > "$d/db/machine.env"
  printf '{"%s": {"managed": true, "since": 1}}\n' "$me" > "$d/db/accounts.json"
  printf '{"%s": {"uid": %s, "gid": %s, "home": "%s"}}\n' "$me" "$(id -u)" "$(id -g)" "$home" > "$d/passwd.json"
  printf '{"children": [], "tasks": []}\n' > "$d/table.json"
  mkdir -p "$d/root/$B/tools/bin"; cp "$WORK/fakebin/ccquota" "$WORK/fakebin/tmux" "$d/root/$B/tools/bin/"
  git clone -q "$SEED" "$co" && git -C "$co" reset -q --hard "$A" \
    && git -C "$co" remote set-url origin https://github.com/verkyyi/claude-fleet.git \
    || { WHY="fixture: cannot clone the seed"; return; }
  OUT=$(env -i HOME="$home" PATH="$PATH" TMPDIR="$WORK" LANG=en_US.UTF-8 \
    FLEET_NODE_TEST=1 FLEET_NODE_STATE="$d/db" FLEET_NODE_LOG="$d/log" FLEET_NODE_ROOT="$d/root" \
    FLEET_NODE_RUNTIME="$d/root/current" FLEET_NODE_USERS="$d/Users" FLEET_NODE_PASSWD="$d/passwd.json" \
    FLEET_NODE_TABLE="$d/table.json" FLEET_NODE_DAEMON_DIR="$d/LaunchDaemons" FLEET_NODE_LAUNCHCTL='' \
    FLEET_NODE_CCQUOTA="$WORK/fakebin/ccquota" FLEET_NODE_UPDATE_LIB="$d/no-lib.sh" \
    https_proxy="$REC" HTTPS_PROXY="$REC" ALL_PROXY="$REC" NO_PROXY=127.0.0.1,localhost \
    python3 "$BIN/fleet-node-update.py" follow "$me" 2>&1 | tail -3)
  [ "$(mark_of "$co")" = B ] || WHY="the managed login's install reads $(mark_of "$co"): $(grep "install $me" "$d/log/update.log" 2>/dev/null | tail -1 | cut -c1-200)"
}

# ------------------------------------------------------------------- the run
FAILS=0 GREEN=0 AWAITED=0
for leg in $LEGS; do
  : > "$WORK/hits.log"
  WHY='' OUT=''
  "leg_${leg//-/_}"
  hits=$(gh_hits)
  [ -z "$hits" ] || WHY="${WHY:+$WHY · }GitHub reached: $hits"
  wait_for=''
  [ "$STRICT" = 1 ] || for w in $DIST_AWAIT; do [ "${w%%:*}" = "$leg" ] && wait_for=${w#*:}; done
  if [ -z "$WHY" ]; then
    if [ -n "$wait_for" ]; then
      FAILS=$((FAILS + 1))
      printf 'FAIL   %-12s green now — drop `%s:%s` from DIST_AWAIT in %s\n' "$leg" "$leg" "$wait_for" "${0##*/}"
    else
      GREEN=$((GREEN + 1))
      printf 'GREEN  %-12s at B (%.7s), no GitHub reach\n' "$leg" "$B"
    fi
  elif [ -n "$wait_for" ]; then
    AWAITED=$((AWAITED + 1))
    printf 'AWAIT  %-12s red until %s: %s\n' "$leg" "$wait_for" "$WHY"
  else
    FAILS=$((FAILS + 1))
    printf 'RED    %-12s %s\n' "$leg" "$WHY"
    [ -z "$OUT" ] || printf '%s\n' "$OUT" | sed 's/^/         | /'
  fi
done
printf 'dist-no-github: %d green · %d awaited · %d failed\n' "$GREEN" "$AWAITED" "$FAILS"
[ "$FAILS" = 0 ]
