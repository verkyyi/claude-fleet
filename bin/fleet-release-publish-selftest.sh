#!/bin/bash
# fleet-release-publish-selftest.sh — bin/fleet-release-publish.sh, the CI half of
# «stable is pushed to the hub» (issue #2772, EPIC #2770 C2). The hub half —
# hashing the archive into the commit's tree, the OIDC check, forward only — is
# Go's (tokenledger internal/api fleet_publish_test.go); this pins what is SENT.
#
# Pinned, against a fake hub on 127.0.0.1 that records each POST:
#   A. the first publish (the hub has no stable: 404): prev empty, the commits
#      part is `git cat-file --batch` of the sha alone, the tree part gunzips to
#      exactly `git archive --format=tar <sha>`, the run URL rides along;
#   B. the next one: prev = the hub's stable, the chain is every first-parent
#      commit from it to the sha, newest first;
#   C. the identity: FLEET_PUBLISH_TOKEN goes as a Bearer header and never on
#      curl's argv; in Actions the runtime's OIDC token (audience
#      ccquota-fleet-release) is fetched and sent instead; neither → exit 2;
#   D. the hub's answer: 409 → exit 1 with its words, 200 → exit 0; the same sha
#      as the hub's stable sends an empty chain; --dry-run POSTs nothing.
# Hermetic: a sandbox repo, a loopback hub. Exit 0 = pass.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
PUB="$BIN/fleet-release-publish.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/publish-selftest.XXXXXX")" || exit 2
WORK="$(cd "$WORK" && pwd -P)"
HUBPID=""
trap '[ -z "$HUBPID" ] || { kill "$HUBPID"; wait "$HUBPID"; } 2>/dev/null; rm -rf "$WORK"' EXIT
N=0 BAD=0
ok() { N=$((N + 1)); }
bad() { N=$((N + 1)); BAD=$((BAD + 1)); printf 'FAIL: %s\n' "$1" >&2; }
has() { case "$2" in *"$3"*) ok ;; *) bad "$1 — wanted «$3» in:
$2" ;; esac; }
hasnt() { case "$2" in *"$3"*) bad "$1 — «$3» should not be in:
$2" ;; *) ok ;; esac; }
eq() { [ "$2" = "$3" ] && ok || bad "$1 — wanted «$2», got «$3»"; }
command -v python3 >/dev/null 2>&1 || { echo "fleet-release-publish-selftest: SKIP (no python3)"; exit 0; }

unset FLEET_PUBLISH_TOKEN ACTIONS_ID_TOKEN_REQUEST_URL ACTIONS_ID_TOKEN_REQUEST_TOKEN GITHUB_RUN_ID GITHUB_REPOSITORY GITHUB_SERVER_URL FLEET_HUB_URL CCQUOTA_HUB_URL
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t GIT_CONFIG_GLOBAL=/dev/null

REPO="$WORK/repo"
git init -q -b master "$REPO"
commit() { echo "$1" >> "$REPO/f"; mkdir -p "$REPO/bin"; printf '#!/bin/sh\necho %s\n' "$1" > "$REPO/bin/x"; chmod +x "$REPO/bin/x"
  git -C "$REPO" add -A; git -C "$REPO" commit -qm "$1"; git -C "$REPO" rev-parse HEAD; }
A=$(commit one); B=$(commit two); C=$(commit three)

# the fake hub: GET …/stable → $WORK/stable (404 when absent); GET /oidc → a token
# for the audience asked; POST …/publish → each part saved under $WORK/post/<n>/,
# the Authorization header beside them; answers $WORK/code (default 200).
cat > "$WORK/hub.py" <<'PY'
import email.parser, email.policy, http.server, os, sys, urllib.parse
W = sys.argv[1]
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def answer(self, code, body):
        b = body.encode()
        self.send_response(code); self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
    def do_GET(self):
        u = urllib.parse.urlparse(self.path)
        if u.path == "/v1/fleet/release/stable":
            p = os.path.join(W, "stable")
            if os.path.exists(p):
                return self.answer(200, '{\n  "schema": 1,\n  "sha": "%s",\n  "files": [{"sha256": "%s"}]\n}\n' % (open(p).read().strip(), "f" * 64))
            return self.answer(404, "404 page not found\n")
        if u.path == "/oidc":
            q = urllib.parse.parse_qs(u.query)
            if self.headers.get("Authorization") != "bearer RUNTIME-REQ":
                return self.answer(403, "no")
            return self.answer(200, '{"count":1,"value":"OIDC.%s.TOKEN"}' % q.get("audience", [""])[0])
        self.answer(404, "")
    def do_POST(self):
        n = len(os.listdir(os.path.join(W, "post")))
        d = os.path.join(W, "post", str(n)); os.makedirs(d)
        open(os.path.join(d, "auth"), "w").write(self.headers.get("Authorization", ""))
        body = self.rfile.read(int(self.headers["Content-Length"]))
        msg = email.parser.BytesParser(policy=email.policy.default).parsebytes(
            b"Content-Type: " + self.headers["Content-Type"].encode() + b"\r\n\r\n" + body)
        for part in msg.iter_parts():
            name = part.get_param("name", header="content-disposition")
            open(os.path.join(d, name), "wb").write(part.get_payload(decode=True) or b"")
        code = int(open(os.path.join(W, "code")).read()) if os.path.exists(os.path.join(W, "code")) else 200
        self.answer(code, '{"status":"published"}' if code == 200 else '{"error":"this hub\'s stable is %s"}' % ("9" * 40))
s = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
open(os.path.join(W, "port"), "w").write(str(s.server_address[1]))
s.serve_forever()
PY
mkdir -p "$WORK/post"
python3 -W ignore "$WORK/hub.py" "$WORK" & HUBPID=$!
for _ in $(seq 1 50); do [ -s "$WORK/port" ] && break; sleep 0.1; done
HUB="http://127.0.0.1:$(cat "$WORK/port")"
# the hub numbers the posts 0, 1, 2 …
posts() { local n=0 d; for d in "$WORK"/post/*/; do [ -d "$d" ] && n=$((n + 1)); done; echo "$n"; }
part() { cat "$WORK/post/$(($(posts) - 1))/$1" 2>/dev/null; }

# a curl shim that keeps every argv, so a credential on it is caught
mkdir -p "$WORK/shim"
REALCURL=$(command -v curl)
cat > "$WORK/shim/curl" <<SH
#!/bin/sh
printf '%s\n' "\$*" >> "$WORK/argv"
exec "$REALCURL" "\$@"
SH
chmod +x "$WORK/shim/curl"
run() { OUT=$(PATH="$WORK/shim:$PATH" "$@" 2>&1); RC=$?; }

# --- A. first publish -----------------------------------------------------------
run env FLEET_PUBLISH_TOKEN=s3cret-publish GITHUB_RUN_ID=77 GITHUB_REPOSITORY=o/r "$PUB" "$A" --hub "$HUB" --dir "$REPO"
eq "A: exit 0" 0 "$RC"; has "A: says published" "$OUT" "published:"
eq "A: one POST" 1 "$(posts)"
eq "A: sha" "$A" "$(part sha)"; eq "A: prev empty" "" "$(part prev)"
has "A: run URL" "$(part run)" "/o/r/actions/runs/77"
eq "A: commits = cat-file of the sha" "$(printf '%s\n' "$A" | git -C "$REPO" cat-file --batch | cksum)" "$(part commits | cksum)"
eq "A: tree = git archive" "$(git -C "$REPO" archive --format=tar "$A" | cksum)" "$(part tree | gunzip | cksum)"

# --- B. the next one, two commits on --------------------------------------------
echo "$A" > "$WORK/stable"
run env FLEET_PUBLISH_TOKEN=s3cret-publish "$PUB" "$C" --hub "$HUB" --dir "$REPO"
eq "B: exit 0" 0 "$RC"; eq "B: prev = the hub's stable" "$A" "$(part prev)"
eq "B: the chain, newest first" "$C $B" "$(part commits | awk '/ commit [0-9]+$/ { printf "%s%s", s, $1; s=" " }')"
eq "B: tree = git archive of C" "$(git -C "$REPO" archive --format=tar "$C" | cksum)" "$(part tree | gunzip | cksum)"

# --- C. identity -------------------------------------------------------------------
eq "C: the bearer sent" "Bearer s3cret-publish" "$(part auth)"
hasnt "C: the token never on curl's argv" "$(cat "$WORK/argv")" "s3cret-publish"
: > "$WORK/argv"
run env ACTIONS_ID_TOKEN_REQUEST_URL="$HUB/oidc?api-version=2.0" ACTIONS_ID_TOKEN_REQUEST_TOKEN=RUNTIME-REQ "$PUB" "$C" --hub "$HUB" --dir "$REPO"
eq "C: OIDC publish exit 0" 0 "$RC"
eq "C: the run's OIDC token, our audience" "Bearer OIDC.ccquota-fleet-release.TOKEN" "$(part auth)"
hasnt "C: the runtime's request token never on argv" "$(cat "$WORK/argv")" "RUNTIME-REQ"
hasnt "C: the OIDC token never on argv" "$(cat "$WORK/argv")" "OIDC."
before=$(posts)
run "$PUB" "$C" --hub "$HUB" --dir "$REPO"
eq "C: no identity → exit 2" 2 "$RC"; has "C: says so" "$OUT" "no identity"; eq "C: nothing POSTed" "$before" "$(posts)"

# --- D. answers ------------------------------------------------------------------------
echo 409 > "$WORK/code"
run env FLEET_PUBLISH_TOKEN=x "$PUB" "$C" --hub "$HUB" --dir "$REPO"
eq "D: 409 → exit 1" 1 "$RC"; has "D: the hub's words" "$OUT" "answered 409"
rm -f "$WORK/code"; echo "$C" > "$WORK/stable"
run env FLEET_PUBLISH_TOKEN=x "$PUB" "$C" --hub "$HUB" --dir "$REPO"
eq "D: already stable → exit 0" 0 "$RC"; eq "D: an empty chain" "" "$(part commits)"; eq "D: prev = sha" "$C" "$(part prev)"
before=$(posts)
run env FLEET_PUBLISH_TOKEN=x "$PUB" "$C" --hub "$HUB" --dir "$REPO" --dry-run
eq "D: dry-run exit 0" 0 "$RC"; eq "D: dry-run POSTs nothing" "$before" "$(posts)"

printf 'fleet-release-publish-selftest: %d checks, %d failed\n' "$N" "$BAD"
[ "$BAD" -eq 0 ]
