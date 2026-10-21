#!/bin/bash
# xssh-sync-selftest.sh — the door's copy of golang.org/x/crypto/ssh
# (tokenledger/agent/internal/xssh, A5SQ) is exactly the x/crypto version
# tokenledger/agent/go.mod requires + fleet.patch: bin/xssh-sync.sh --check.
# BREAK-IT door-xssh-drift. No go toolchain or no module cache here: the Go
# gate builds the copy; this says so and passes.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
out=$(bash "$ROOT/bin/xssh-sync.sh" --check 2>&1); rc=$?
case $rc in
  0) echo "ok   $out" ;;
  3) echo "skip no go toolchain here — the Go gate builds tokenledger/agent/internal/xssh"; rc=0 ;;
  *) case $out in
       *'not in the module cache'*) echo "skip $out"; rc=0 ;;
       *) echo "FAIL $out"; echo "     fix: bin/xssh-sync.sh (tokenledger/agent/internal/xssh/README.md)" ;;
     esac ;;
esac
# the patch is the only difference, and it is marked
grep -q 'xssh-patch begin' "$ROOT/tokenledger/agent/internal/xssh/server.go" || { echo "FAIL server.go carries no xssh-patch hunk"; rc=1; }
grep -q 'SignedPublicKeyCallback' "$ROOT/tokenledger/agent/door/door.go" || { echo "FAIL agent/door no longer uses the patch"; rc=1; }
[ "$rc" = 0 ] && echo "xssh-sync selftest: OK" || echo "xssh-sync selftest: FAILED"
exit "$rc"
