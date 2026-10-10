#!/bin/bash
# fleet-release-lib-selftest.sh — a login takes its versions from the hub's
# signed release only (issue #2773, EPIC #2770 C3): bin/fleet-release-lib.sh,
# bin/fleet-release-key.sh (`fleet host trust-release-key`) and the hub road of
# bin/fleet-host-install.sh, against a sandbox hub on 127.0.0.1. (The
# install-sync tick itself is install-sync-selftest.sh's leg U.)
#
#   A. key       the hub's key is pinned once (0644) and never replaced by
#                itself; a hub with no store (404) pins nothing
#   B. stable    200 → sha + seq · 404 → rc 3 (no store: the git road) · no
#                answer → rc 1 (入口不可达)
#   C. import    a tree becomes ONE commit `fleet-release: <sha> seq=<n>` on the
#                given parent, refs/fleet/rel/<sha>, .release/ left out;
#                fleet_rel_of reads it back, a hand commit on top is
#                fleet_rel_below's
#   D. ccquota   a computer with none takes the hub's ccquota-<os>-<arch> only
#                when it matches the sha256 its release names
#   E. trust     fleet-release-key.sh: same key → 0; another → status 1, `trust`
#                without a terminal or --yes takes nothing, --yes takes it
#   F. host      fleet-host-install.sh with a hub: the checkout is the hub's
#                signed stable (an imported commit, no remote, the key pinned,
#                ccquota fetched from the hub) — git never asked for GitHub
#   G. origin    drop → the remote gone, its URL kept; restore → back
# Exit 0 = pass.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
command -v git >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1 || { echo 'fleet-release-lib-selftest SKIP (git / python3)'; exit 0; }
WORK=$(mktemp -d "${TMPDIR:-/tmp}/fleet-release-lib.XXXXXX") || exit 2
WORK=$(cd "$WORK" && pwd -P)
SRV=''
trap '[ -n "$SRV" ] && kill "$SRV" 2>/dev/null; rm -rf "$WORK"' EXIT INT TERM HUP
N=0
fail() { printf 'selftest FAIL: %s\n' "$1" >&2; exit 1; }
eq() { N=$((N + 1)); [ "$2" = "$3" ] || fail "$1 — expected [$2], got [$3]"; }
has() { N=$((N + 1)); case "$2" in *"$3"*) ;; *) fail "$1 — [$2] lacks [$3]" ;; esac; }
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export HOME="$WORK/home" TMPDIR="$WORK"
mkdir -p "$HOME"
sha() { { shasum -a 256 2>/dev/null || sha256sum; } < "$1" | awk '{print $1}'; }

# --- the sandbox hub: <w>/rel/<sha>/ as ccquota leaves it, <w>/art/<name> -----
H="$WORK/hub"; mkdir -p "$H/rel" "$H/art"
printf 'ed25519 AAAAhubkey000000001\n' > "$H/key"
OS=$(uname -s | tr 'A-Z' 'a-z'); case "$(uname -m)" in arm64|aarch64) AR=arm64 ;; *) AR=amd64 ;; esac
# the hub's ccquota: copies <rel>/<sha>/ out; refuses with $H/badsig
cat > "$H/art/ccquota-$OS-$AR" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$H/ccquota.log"
shift 2; ref='' dir=''
while [ \$# -gt 0 ]; do case "\$1" in --hub|--pubkey) shift 2 ;; --*) shift ;; *) if [ -z "\$ref" ]; then ref=\$1; else dir=\$1; fi; shift ;; esac; done
[ -f "$H/badsig" ] && { echo "signature does not verify" >&2; exit 1; }
[ "\$ref" = stable ] && ref=\$(cat "$H/rel/stable")
mkdir -p "\$dir" && cp -R "$H/rel/\$ref/." "\$dir/"
EOF
chmod +x "$H/art/ccquota-$OS-$AR"
SEED="$WORK/seed"; mkdir -p "$SEED/bin"
git init -q -b master "$SEED"
printf '#!/bin/sh\necho "fleet-login-bootstrap: stub ok"\n' > "$SEED/bin/fleet-login-bootstrap.sh"
printf '#!/bin/sh\nexit 0\n' > "$SEED/bin/fleet-up.sh"; chmod +x "$SEED"/bin/*
printf 'one\n' > "$SEED/f"; git -C "$SEED" add -A; git -C "$SEED" commit -qm one; S1=$(git -C "$SEED" rev-parse HEAD)
printf 'two\n' > "$SEED/f"; git -C "$SEED" commit -qam two; S2=$(git -C "$SEED" rev-parse HEAD)
publish() { # <sha> <seq> <ccquota sha256>
  rm -rf "$H/rel/$1"; mkdir -p "$H/rel/$1/.release"
  git -C "$SEED" archive "$1" | tar -x -C "$H/rel/$1"
  printf '{"schema":1,"sha":"%s","seq":%s,"prev":"","artifacts":[{"name":"ccquota-%s-%s","sha256":"%s","size":1}]}\n' \
    "$1" "$2" "$OS" "$AR" "$3" > "$H/rel/$1/.release/manifest.json"
  printf '%s\n' "$1" > "$H/rel/stable"
}
publish "$S2" 3 "$(sha "$H/art/ccquota-$OS-$AR")"
cat > "$H/srv.py" <<'PY'
import os, signal, sys, threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
signal.alarm(300)
w = sys.argv[1]
class Hd(BaseHTTPRequestHandler):
    def do_GET(self):
        body, code = b"", 404
        p = self.path
        if not os.path.exists(os.path.join(w, "nostore")):
            if p == "/v1/fleet/release/key":
                body, code = open(os.path.join(w, "key"), "rb").read(), 200
            elif p == "/v1/fleet/release/stable":
                st = open(os.path.join(w, "rel", "stable")).read().strip()
                body, code = open(os.path.join(w, "rel", st, ".release", "manifest.json"), "rb").read(), 200
            elif "/artifacts/" in p:
                f = os.path.join(w, "art", p.rsplit("/", 1)[1])
                if os.path.isfile(f):
                    body, code = open(f, "rb").read(), 200
        self.send_response(code)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *a):
        pass
s = ThreadingHTTPServer(("127.0.0.1", 0), Hd)
threading.Thread(target=s.serve_forever, daemon=True).start()
open(os.path.join(w, "port.tmp"), "w").write(str(s.server_address[1]))
os.rename(os.path.join(w, "port.tmp"), os.path.join(w, "port"))
threading.Event().wait()
PY
python3 "$H/srv.py" "$H" 2>"$H/srv.err" & SRV=$!
for _ in $(seq 1 100); do [ -s "$H/port" ] && break; sleep 0.05; done
[ -s "$H/port" ] || fail "the sandbox hub did not start: $(cat "$H/srv.err")"
HUB="http://127.0.0.1:$(cat "$H/port")"
# shellcheck source=fleet-release-lib.sh
. "$BIN/fleet-release-lib.sh"

# --- A. key -------------------------------------------------------------------
C="$WORK/confA"
p=$(fleet_rel_pubkey "$C" "$HUB" 5 2>"$WORK/err"); eq "A: pinned → its path" "$C/release.pub" "$p"
eq "A: the hub's key" "$(cat "$H/key")" "$(cat "$C/release.pub")"
eq "A: 0644" 644 "$(stat -f %Lp "$C/release.pub" 2>/dev/null || stat -c %a "$C/release.pub")"  # portable-ok: both ways
has "A: said with its fingerprint" "$(cat "$WORK/err")" "pinned the hub's release key"
printf 'ed25519 AAAAotherkey00000002\n' > "$H/key"
fleet_rel_pubkey "$C" "$HUB" 5 >/dev/null 2>&1
eq "A: never replaced by itself" "ed25519 AAAAhubkey000000001" "$(cat "$C/release.pub")"
touch "$H/nostore"
fleet_rel_pubkey "$WORK/confA2" "$HUB" 5 >/dev/null 2>&1; eq "A: no store → no key (rc 1)" 1 "$?"
[ -e "$WORK/confA2/release.pub" ] && fail "A: a key file was written for a hub with no store"
rm -f "$H/nostore"

# --- B. stable ------------------------------------------------------------------
fleet_rel_stable "$HUB" 5; eq "B: rc 0" 0 "$?"; eq "B: sha" "$S2" "$REL_SHA"; eq "B: seq" 3 "$REL_SEQ"
touch "$H/nostore"; fleet_rel_stable "$HUB" 5; eq "B: no store → rc 3" 3 "$?"; rm -f "$H/nostore"
fleet_rel_stable http://127.0.0.1:9 3; eq "B: no answer → rc 1" 1 "$?"; has "B: …says no answer" "$REL_ERR" "no answer"

# --- C. import --------------------------------------------------------------------
R="$WORK/repo"; git init -q -b master "$R"; git -C "$R" fetch -q "$SEED" master; git -C "$R" reset -q --hard "$S1"
T="$WORK/tree"; mkdir -p "$T/.release"; git -C "$SEED" archive "$S2" | tar -x -C "$T"; echo '{}' > "$T/.release/manifest.json"
c=$(fleet_rel_import "$R" "$T" "$S1" "$S2" 3); eq "C: imported" 0 "$?"
eq "C: subject" "fleet-release: $S2 seq=3" "$(git -C "$R" log -1 --format=%s "$c")"
eq "C: on the parent" "$S1" "$(git -C "$R" rev-parse "$c^")"
eq "C: the upstream tree, .release/ left out" "$(git -C "$R" rev-parse "$S2^{tree}" 2>/dev/null || git -C "$SEED" rev-parse "$S2^{tree}")" "$(git -C "$R" rev-parse "$c^{tree}")"
eq "C: refs/fleet/rel/<sha>" "$c" "$(git -C "$R" rev-parse "refs/fleet/rel/$S2")"
eq "C: fleet_rel_of" "$S2 3" "$(fleet_rel_of "$R" "$c")"
fleet_rel_of "$R" "$S1" >/dev/null; eq "C: a plain commit is not one" 1 "$?"
git -C "$R" reset -q --hard "$c"; git -C "$R" commit -q --allow-empty -m hand
fleet_rel_below "$R" HEAD; eq "C: a hand commit sits on a release" 0 "$?"
fleet_rel_below "$R" "$S1"; eq "C: …a plain history has none" 1 "$?"

# --- D. ccquota from the hub ---------------------------------------------------------
q=$(fleet_rel_ccquota_get "$HUB" "$WORK/toolsD" 5); eq "D: fetched" "$WORK/toolsD/ccquota" "$q"
[ -x "$q" ] || fail "D: not executable"
publish "$S2" 3 0000000000000000000000000000000000000000000000000000000000000000
fleet_rel_ccquota_get "$HUB" "$WORK/toolsD2" 5 >/dev/null; eq "D: a sha256 mismatch is refused" 1 "$?"
has "D: …says so" "$REL_ERR" "does not match"
[ -e "$WORK/toolsD2/ccquota" ] && fail "D: a mismatched binary was kept"
publish "$S2" 3 "$(sha "$H/art/ccquota-$OS-$AR")"

# --- E. trust-release-key ---------------------------------------------------------------
C="$WORK/confE"; mkdir -p "$C"; cp "$H/key" "$C/release.pub"
out=$(FLEET_CONF_DIR="$C" FLEET_HUB_URL="$HUB" bash "$BIN/fleet-release-key.sh" status </dev/null 2>&1); eq "E: same key → 0" 0 "$?"
printf 'ed25519 AAAAoldpinned0000003\n' > "$C/release.pub"
out=$(FLEET_CONF_DIR="$C" FLEET_HUB_URL="$HUB" bash "$BIN/fleet-release-key.sh" status </dev/null 2>&1); eq "E: another → status 1" 1 "$?"
has "E: …names the command" "$out" "fleet host trust-release-key"
FLEET_CONF_DIR="$C" FLEET_HUB_URL="$HUB" bash "$BIN/fleet-release-key.sh" trust </dev/null >/dev/null 2>&1 </dev/null
eq "E: no --yes, no answer → not taken" "ed25519 AAAAoldpinned0000003" "$(cat "$C/release.pub")"
out=$(FLEET_CONF_DIR="$C" FLEET_HUB_URL="$HUB" bash "$BIN/fleet-release-key.sh" trust --yes </dev/null 2>&1); eq "E: --yes → 0" 0 "$?"
eq "E: …taken" "$(cat "$H/key")" "$(cat "$C/release.pub")"
has "E: …both fingerprints printed" "$out" "现在认的"

# --- F. fleet-host-install.sh from the hub -------------------------------------------------
FH="$WORK/hostF"; mkdir -p "$FH/shim" "$FH/conf"
printf '#!/bin/sh\n[ "$1" = -V ] && echo "tmux 3.4"\nexit 0\n' > "$FH/shim/tmux"; chmod +x "$FH/shim/tmux"
: > "$H/ccquota.log"
out=$(env HOME="$FH" PATH="$FH/shim:/usr/bin:/bin:/usr/sbin:/sbin" FLEET_CONF_DIR="$FH/conf" FLEET_HUB_URL="$HUB" \
  FLEET_INSTALL_ROOT="$FH/.claude/fleet" FLEET_INSTALL_NO_DEPS=1 FLEET_BOOTSTRAP_GIT_BASE="$WORK/no-such-github" \
  bash "$BIN/fleet-host-install.sh" </dev/null 2>&1); rc=$?
eq "F: host install exits 0 [$out]" 0 "$rc"
has "F: says it came from the hub" "$out" "从入口取 stable"
eq "F: the checkout is the imported release" "fleet-release: $S2 seq=3" "$(git -C "$FH/.claude/fleet" log -1 --format=%s 2>/dev/null)"
eq "F: …its files" two "$(cat "$FH/.claude/fleet/f" 2>/dev/null)"
eq "F: no remote" "" "$(git -C "$FH/.claude/fleet" remote 2>/dev/null)"
eq "F: the key pinned" "$(cat "$H/key")" "$(cat "$FH/conf/release.pub" 2>/dev/null)"
has "F: checked by the hub's ccquota against that key" "$(cat "$H/ccquota.log")" "--pubkey $FH/conf/release.pub $S2"
# a release that does not verify: nothing installed
FH2="$WORK/hostF2"; mkdir -p "$FH2/conf"; touch "$H/badsig"
out=$(env HOME="$FH2" PATH="$FH/shim:/usr/bin:/bin:/usr/sbin:/sbin" FLEET_CONF_DIR="$FH2/conf" FLEET_HUB_URL="$HUB" \
  FLEET_INSTALL_ROOT="$FH2/.claude/fleet" FLEET_INSTALL_NO_DEPS=1 FLEET_BOOTSTRAP_GIT_BASE="$WORK/no-such-github" \
  bash "$BIN/fleet-host-install.sh" </dev/null 2>&1); rc=$?
rm -f "$H/badsig"
eq "F: a bad signature fails the install" 1 "$rc"
has "F: …says it did not verify" "$out" "没验过章"
[ -e "$FH2/.claude/fleet" ] && fail "F: something was installed from a release that did not verify"

# --- G. origin ------------------------------------------------------------------------------
git -C "$R" remote add origin https://example.invalid/r.git
fleet_rel_drop_origin "$R" origin "$WORK/bak" 2>/dev/null
eq "G: dropped" "" "$(git -C "$R" remote)"; eq "G: kept" "origin https://example.invalid/r.git" "$(cat "$WORK/bak")"
fleet_rel_restore_origin "$R" origin "$WORK/bak" 2>/dev/null
eq "G: restored" "https://example.invalid/r.git" "$(git -C "$R" remote get-url origin)"

printf 'fleet-release-lib-selftest OK (%d checks)\n' "$N"
