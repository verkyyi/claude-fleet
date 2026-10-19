#!/bin/bash
# fleet-src-digest-selftest.sh — bin/fleet-src-digest.py (git) and
# tokenledger/shared/release/srcdigest.go (the hub, the Dockerfile) compute ONE
# digest of the Go source a ccquota is built from (issue #2930). The Go test's
# vector (sourceDigestVector / sourceDigestWant in srcdigest_test.go) is
# committed into a sandbox repo here and the python must print the same value —
# so the two can never drift apart without one side going red. Both digests
# (issue #4813): the node's (default, sourceDigestWant) and the hub image's
# (--image, imageSourceDigestWant). No Go needed.
set -u
BIN=$(cd "$(dirname "$0")" && pwd); ROOT=$(cd "$BIN/.." && pwd)
T="$ROOT/tokenledger/shared/release/srcdigest_test.go"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/srcdig.XXXXXX"); trap 'rm -rf "$WORK"' EXIT
fail=0
ok()  { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1"; fail=1; }

want=$(sed -n 's/^const sourceDigestWant = "\([0-9a-f]*\)"$/\1/p' "$T")
[ "${#want}" = 64 ] || { echo "FAIL no sourceDigestWant in ${T#$ROOT/}"; exit 1; }
iwant=$(sed -n 's/^const imageSourceDigestWant = "\([0-9a-f]*\)"$/\1/p' "$T")
[ "${#iwant}" = 64 ] || { echo "FAIL no imageSourceDigestWant in ${T#$ROOT/}"; exit 1; }
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
git init -q "$WORK/r" || exit 1
# the vector: `"<path>": "<body>",` lines between the map's braces (Go escapes: \n only)
python3 - "$T" "$WORK/r" <<'PY' || { echo "FAIL could not lay out the vector"; exit 1; }
import os, re, sys
src = open(sys.argv[1]).read()
block = src.split("var sourceDigestVector = map[string]string{", 1)[1].split("\n}", 1)[0]
n = 0
for path, body in re.findall(r'^\s*"([^"]+)":\s*"((?:[^"\\]|\\.)*)",\s*$', block, re.M):
    f = os.path.join(sys.argv[2], path)
    os.makedirs(os.path.dirname(f), exist_ok=True)
    open(f, "w").write(body.encode().decode("unicode_escape"))
    n += 1
sys.exit(0 if n >= 10 else 1)
PY
# a symlink is no input (git mode 120000), as in the Go walk
ln -s main.go "$WORK/r/tokenledger/cmd/ccquota/link.go"
git -C "$WORK/r" add -A && git -C "$WORK/r" commit -qm v || exit 1

sd()  { python3 "$BIN/fleet-src-digest.py" "$WORK/r" HEAD; }
isd() { python3 "$BIN/fleet-src-digest.py" --image "$WORK/r" HEAD; }
got=$(sd)
[ "$got" = "$want" ] && ok "git digest = the Go vector's ($want)" || bad "fleet-src-digest.py printed '$got', srcdigest_test.go wants $want"
got=$(isd)
[ "$got" = "$iwant" ] && ok "git --image digest = the Go vector's ($iwant)" || bad "fleet-src-digest.py --image printed '$got', srcdigest_test.go wants $iwant"

# a test, a doc or the client manifest moves nothing; one byte of Go does
printf 'x\n' >> "$WORK/r/tokenledger/internal/store/store_test.go"
printf 'y\n' >> "$WORK/r/tokenledger/internal/api/fleetclient/manifest"
printf 'x\n' >> "$WORK/r/tokenledger/shared/release/r_test.go"
git -C "$WORK/r" commit -qam noise
[ "$(sd)" = "$want" ] && [ "$(isd)" = "$iwant" ] && ok "tests / the client manifest are not inputs" || bad "a non-input moved a digest"
printf 'z\n' >> "$WORK/r/tokenledger/go.work"
git -C "$WORK/r" commit -qam work
[ "$(sd)" = "$want" ] && [ "$(isd)" = "$iwant" ] && ok "go.work is not an input (the image builds GOWORK=off)" || bad "go.work moved a digest"
# a hub-only edit (the root module, #4813): the image's moves, the node's does not
printf '// edit\n' >> "$WORK/r/tokenledger/cmd/ccquota/main.go"
printf 'require y v0\n' >> "$WORK/r/tokenledger/go.mod"
git -C "$WORK/r" commit -qam hub
[ "$(sd)" = "$want" ] && ok "a hub-only edit (cmd/, the root go.mod) leaves the node's digest" || bad "a hub-only edit moved the node's digest"
[ "$(isd)" != "$iwant" ] && ok "…and moves the image's (the train redeploys the hub)" || bad "a hub-only edit did not move the image's digest"
# the shared module both the hub and the node build in counts (#4811)
iprev=$(isd)
printf '// edit\n' >> "$WORK/r/tokenledger/shared/release/r.go"
git -C "$WORK/r" commit -qam shared
[ "$(sd)" != "$want" ] && [ "$(isd)" != "$iprev" ] && ok "a shared/ edit moves both" || bad "an edit under shared/ did not move both digests"
# …and the node's own module (#4812)
prev=$(sd); iprev=$(isd)
printf '// edit\n' >> "$WORK/r/tokenledger/agent/cli/run.go"
git -C "$WORK/r" commit -qam agent
[ "$(sd)" != "$prev" ] && [ "$(isd)" != "$iprev" ] && ok "an agent/ edit moves both" || bad "an edit under agent/ did not move both digests"

# the hub as its own module (#4814): hub/ is the image's input — not hub/web/,
# hub/apitest/ (no build links it), the client pack, nor e2e/ — and never the node's
mkdir -p "$WORK/r/tokenledger/hub/api/fleetclient" "$WORK/r/tokenledger/hub/web" "$WORK/r/tokenledger/hub/apitest" "$WORK/r/tokenledger/e2e"
printf 'module h\n' > "$WORK/r/tokenledger/hub/go.mod"; printf 'package api\n' > "$WORK/r/tokenledger/hub/api/a.go"
git -C "$WORK/r" add -A && git -C "$WORK/r" commit -qm hubmod
prev=$(sd); iprev=$(isd)
printf 'package web\n' > "$WORK/r/tokenledger/hub/web/embed.go"; printf 'package apitest\n' > "$WORK/r/tokenledger/hub/apitest/a.go"
printf 'bin/x\n' > "$WORK/r/tokenledger/hub/api/fleetclient/manifest"; printf 'module e\n' > "$WORK/r/tokenledger/e2e/go.mod"
git -C "$WORK/r" add -A && git -C "$WORK/r" commit -qm hubnoise
[ "$(sd)" = "$prev" ] && [ "$(isd)" = "$iprev" ] && ok "hub/web, hub/apitest, the client manifest and e2e/ are not inputs" || bad "a hub/ non-input moved a digest"
printf '// edit\n' >> "$WORK/r/tokenledger/hub/api/a.go"
git -C "$WORK/r" commit -qam hubedit
[ "$(sd)" = "$prev" ] && [ "$(isd)" != "$iprev" ] && ok "a hub/ edit moves the image's digest, not the node's" || bad "a hub/ edit: node ${prev}→$(sd), image ${iprev}→$(isd)"

# no Go source: empty, exit 0; an unknown rev: exit 2
git -C "$WORK/r" rm -rq tokenledger/shared tokenledger/agent && git -C "$WORK/r" commit -qm node-gone
out=$(sd); rc=$?
[ "$rc" = 0 ] && [ -z "$out" ] && [ -n "$(isd)" ] && ok "no node source: the node's is empty, the image's is not" || bad "no node source: rc $rc '$out'"
git -C "$WORK/r" rm -rq tokenledger && git -C "$WORK/r" commit -qm gone
out=$(isd); rc=$?
[ "$rc" = 0 ] && [ -z "$out" ] && ok "a commit with no Go source: empty" || bad "no Go source: rc $rc '$out'"
python3 "$BIN/fleet-src-digest.py" "$WORK/r" deadbeef >/dev/null 2>&1; rc=$?
[ "$rc" = 2 ] && ok "an unreadable rev: exit 2" || bad "an unreadable rev exited $rc"

[ "$fail" = 0 ] && echo "fleet-src-digest selftest: OK" || { echo "fleet-src-digest selftest: FAILED"; exit 1; }
