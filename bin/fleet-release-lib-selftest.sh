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
#   H. stale     a ccquota older than `ccquota release` (#3047): the error names
#                it (not usage's last line); fleet_rel_fetch_any takes the
#                release's own ccquota ONLY when its manifest verifies against
#                the pinned key (a real ed25519 signature, fleet-release-verify.py,
#                RFC 8032 vector) and the binary matches; fleet_rel_fp = KeyID
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
            elif p.startswith("/v1/fleet/release/"):
                # <sha> → the manifest, its signature in a header · <sha>/manifest.sig
                sha, _, sub = p[len("/v1/fleet/release/"):].partition("/")
                d = os.path.join(w, "rel", sha, ".release")
                f = os.path.join(d, "manifest.sig" if sub == "manifest.sig" else "manifest.json")
                if sub in ("", "manifest.sig") and os.path.isfile(f):
                    body, code = open(f, "rb").read(), 200
        self.send_response(code)
        if code == 200 and self.path.count("/") == 4 and self.path.startswith("/v1/fleet/release/"):
            sf = os.path.join(w, "rel", self.path.rsplit("/", 1)[1], ".release", "manifest.sig")
            if os.path.isfile(sf) and not os.path.exists(os.path.join(w, "nosigheader")):
                self.send_header("X-Ccquota-Release-Signature", open(sf).read().strip())
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
eq "A: 0644" 644 "$(python3 -c 'import os, sys; print(oct(os.stat(sys.argv[1]).st_mode & 0o777)[2:])' "$C/release.pub")"
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

# --- H. a ccquota older than `ccquota release` (#3047) ------------------------------------
V="$BIN/fleet-release-verify.py"
# RFC 8032 §7.1 TEST 1 — the verifier speaks Go's ed25519
printf 'ed25519 %s\n' "$(python3 -c 'import base64; print(base64.b64encode(bytes.fromhex("d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a")).decode())')" > "$WORK/rfc.pub"
: > "$WORK/rfc.msg"; printf '{}' > "$WORK/rfc.json"
RFCSIG=$(python3 -c 'import base64; print(base64.b64encode(bytes.fromhex("e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e065224901555fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b")).decode())')
python3 -c 'import importlib.util, base64, sys
s = importlib.util.spec_from_file_location("v", sys.argv[1]); v = importlib.util.module_from_spec(s); s.loader.exec_module(v)
pub = bytes.fromhex("d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a")
sig = base64.b64decode(sys.argv[2])
assert v.verify(pub, b"", sig), "RFC 8032 TEST 1 does not verify"
assert not v.verify(pub, b"x", sig), "a changed message verifies"
' "$V" "$RFCSIG" || fail "H: RFC 8032 vector"
N=$((N + 1))
# a signer for the sandbox: RFC 8032 §5.1.6 on the verifier's own curve code
cat > "$H/sign.py" <<'PY'
import base64, hashlib, importlib.util, sys
s = importlib.util.spec_from_file_location("v", sys.argv[1]); v = importlib.util.module_from_spec(s); s.loader.exec_module(v)
def enc(pt):
    zi = v._inv(pt[2]); x, y = pt[0] * zi % v.P, pt[1] * zi % v.P
    return (y | ((x & 1) << 255)).to_bytes(32, "little")
seed = hashlib.sha256(sys.argv[2].encode()).digest(); h = hashlib.sha512(seed).digest()
a = int.from_bytes(h[:32], "little") & ((1 << 254) - 8) | (1 << 254)
A = enc(v._mul(a, v.G))
if sys.argv[3] == "pub":
    print("ed25519", base64.b64encode(A).decode()); sys.exit(0)
msg = open(sys.argv[3], "rb").read()
r = int.from_bytes(hashlib.sha512(h[32:] + msg).digest(), "little") % v.Q
R = enc(v._mul(r, v.G))
k = int.from_bytes(hashlib.sha512(R + A + msg).digest(), "little") % v.Q
print(base64.b64encode(R + ((r + k * a) % v.Q).to_bytes(32, "little")).decode())
PY
C="$WORK/confH"; mkdir -p "$C"
python3 "$H/sign.py" "$V" hub-key pub > "$C/release.pub"
eq "H: fleet_rel_fp is ccquota's KeyID (sha256 of the raw key)" \
  "$(awk '{print $2}' "$C/release.pub" | python3 -c 'import base64, hashlib, sys; print(hashlib.sha256(base64.b64decode(sys.stdin.read().strip())).hexdigest()[:16])')" \
  "$(fleet_rel_fp "$C/release.pub")"
signH() { python3 "$H/sign.py" "$V" "$1" "$H/rel/$S2/.release/manifest.json" > "$H/rel/$S2/.release/manifest.sig"; }
publish "$S2" 3 "$(sha "$H/art/ccquota-$OS-$AR")"; signH hub-key
python3 "$V" "$C/release.pub" "$H/rel/$S2/.release/manifest.json" "@$H/rel/$S2/.release/manifest.sig" >/dev/null
eq "H: the sandbox's own signature verifies" 0 "$?"
OLD="$WORK/old"; mkdir -p "$OLD"
cat > "$OLD/ccquota" <<'EOF2'
#!/bin/sh
case "$1" in version) echo "ccquota prod-old"; exit 0 ;; esac
printf 'ccquota: unknown command "%s"\n\nUsage:\n  ccquota version           Print the version\n\nRun any subcommand with -h for its flags.\n' "$1" >&2
exit 2
EOF2
chmod +x "$OLD/ccquota"
fleet_rel_fetch "$OLD/ccquota" "$HUB" "$C/release.pub" "$S2" "$WORK/stageH0"; eq "H: an old ccquota cannot fetch" 1 "$?"
eq "H: …REL_STALE" 1 "$REL_STALE"
has "H: …the error names the old ccquota" "$REL_ERR" "prod-old) has no \`ccquota release\`"
case "$REL_ERR" in *"Run any subcommand"*) fail "H: the error is still usage's last line [$REL_ERR]" ;; esac
: > "$H/ccquota.log"
fleet_rel_fetch_any "$OLD/ccquota" "$HUB" "$C/release.pub" "$S2" "$WORK/stageH" "$WORK/toolsH" 5
eq "H: fetch_any takes the release's own ccquota [$REL_ERR]" 0 "$?"
eq "H: …REL_CCQ" "$WORK/toolsH/ccquota" "$REL_CCQ"
eq "H: …the release arrived" two "$(cat "$WORK/stageH/f" 2>/dev/null)"
has "H: …checked by it against the pinned key" "$(cat "$H/ccquota.log")" "--pubkey $C/release.pub $S2"
# signed by ANOTHER key: no ccquota taken, nothing fetched
signH other-key
fleet_rel_fetch_any "$OLD/ccquota" "$HUB" "$C/release.pub" "$S2" "$WORK/stageH2" "$WORK/toolsH2" 5
eq "H: a release not signed by the pinned key vouches for nothing" 1 "$?"
has "H: …says so" "$REL_ERR" "does not match the pinned key"
[ -e "$WORK/toolsH2/ccquota" ] && fail "H: a ccquota was taken on a bad signature"
[ -e "$WORK/stageH2" ] && fail "H: a release was fetched on a bad signature"
# the right signature, but the binary is not the one it names
signH hub-key; cp "$H/art/ccquota-$OS-$AR" "$WORK/art.keep"; printf '\n# tampered\n' >> "$H/art/ccquota-$OS-$AR"
fleet_rel_fetch_any "$OLD/ccquota" "$HUB" "$C/release.pub" "$S2" "$WORK/stageH3" "$WORK/toolsH3" 5
eq "H: a binary off the signed sha256 is refused" 1 "$?"
has "H: …says so" "$REL_ERR" "does not match the sha256 its signed release names"
[ -e "$WORK/toolsH3/ccquota" ] && fail "H: a tampered ccquota was kept"
cp "$WORK/art.keep" "$H/art/ccquota-$OS-$AR"
# no signature header: manifest.sig is read instead
touch "$H/nosigheader"
fleet_rel_fetch_any "$OLD/ccquota" "$HUB" "$C/release.pub" "$S2" "$WORK/stageH4" "$WORK/toolsH4" 5
eq "H: manifest.sig when the header is missing [$REL_ERR]" 0 "$?"
rm -f "$H/nosigheader"
# a new enough ccquota is used as it is — no second fetch
q=$(fleet_rel_ccquota_get "$HUB" "$WORK/toolsH5" 5)
fleet_rel_fetch_any "$q" "$HUB" "$C/release.pub" "$S2" "$WORK/stageH5" "$WORK/toolsH6" 5
eq "H: a ccquota that knows release is used as is" "$q" "$REL_CCQ"
[ -e "$WORK/toolsH6/ccquota" ] && fail "H: a ccquota was fetched although the login's knew release"
rm -f "$H/rel/$S2/.release/manifest.sig"

printf 'fleet-release-lib-selftest OK (%d checks)\n' "$N"
