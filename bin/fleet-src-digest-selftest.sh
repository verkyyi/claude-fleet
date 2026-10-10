#!/bin/bash
# fleet-src-digest-selftest.sh — bin/fleet-src-digest.py (git) and
# tokenledger/internal/release/srcdigest.go (the hub, the Dockerfile) compute ONE
# digest of the Go source a ccquota is built from (issue #2930). The Go test's
# vector (sourceDigestVector / sourceDigestWant in srcdigest_test.go) is
# committed into a sandbox repo here and the python must print the same value —
# so the two can never drift apart without one side going red. No Go needed.
set -u
BIN=$(cd "$(dirname "$0")" && pwd); ROOT=$(cd "$BIN/.." && pwd)
T="$ROOT/tokenledger/internal/release/srcdigest_test.go"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/srcdig.XXXXXX"); trap 'rm -rf "$WORK"' EXIT
fail=0
ok()  { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1"; fail=1; }

want=$(sed -n 's/^const sourceDigestWant = "\([0-9a-f]*\)"$/\1/p' "$T")
[ "${#want}" = 64 ] || { echo "FAIL no sourceDigestWant in ${T#$ROOT/}"; exit 1; }
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

got=$(python3 "$BIN/fleet-src-digest.py" "$WORK/r" HEAD)
[ "$got" = "$want" ] && ok "git digest = the Go vector's ($want)" || bad "fleet-src-digest.py printed '$got', srcdigest_test.go wants $want"

# a test, a doc or the client manifest moves nothing; one byte of Go does
printf 'x\n' >> "$WORK/r/tokenledger/internal/store/store_test.go"
printf 'y\n' >> "$WORK/r/tokenledger/internal/api/fleetclient/manifest"
git -C "$WORK/r" commit -qam noise
[ "$(python3 "$BIN/fleet-src-digest.py" "$WORK/r" HEAD)" = "$want" ] && ok "tests / the client manifest are not inputs" || bad "a non-input moved the digest"
printf '// edit\n' >> "$WORK/r/tokenledger/cmd/ccquota/main.go"
git -C "$WORK/r" commit -qam go
[ "$(python3 "$BIN/fleet-src-digest.py" "$WORK/r" HEAD)" != "$want" ] && ok "a Go edit moves it" || bad "a Go edit did not move the digest"

# no Go source: empty, exit 0; an unknown rev: exit 2
git -C "$WORK/r" rm -rq tokenledger && git -C "$WORK/r" commit -qm gone
out=$(python3 "$BIN/fleet-src-digest.py" "$WORK/r" HEAD); rc=$?
[ "$rc" = 0 ] && [ -z "$out" ] && ok "a commit with no Go source: empty" || bad "no Go source: rc $rc '$out'"
python3 "$BIN/fleet-src-digest.py" "$WORK/r" deadbeef >/dev/null 2>&1; rc=$?
[ "$rc" = 2 ] && ok "an unreadable rev: exit 2" || bad "an unreadable rev exited $rc"

[ "$fail" = 0 ] && echo "fleet-src-digest selftest: OK" || { echo "fleet-src-digest selftest: FAILED"; exit 1; }
